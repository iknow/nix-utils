#!/usr/bin/env python3

from datetime import datetime, timezone
from pathlib import PurePosixPath, PosixPath
import io
import json
import os
import re
import subprocess
import sys
import tarfile


def parse_path(name):
    path = PurePosixPath(name)
    if path.is_absolute():
        path = path.relative_to('/')

    if path.as_posix() == '.':
        return '.'
    else:
        return './{}'.format(path)


number_regex = re.compile('[0-9]+')
mode_regex = re.compile('[0-9]{4}')


def parse_mode(mode):
    if mode == None:
        return ModeSet(None)
    elif mode_regex.fullmatch(mode):
        return ModeSet(int(mode, 8))
    elif number_regex.fullmatch(mode):
        raise Exception(
            "Invalid mode: {}, please specify numeric modes as 4-digit octal".
            format(mode))
    else:
        return ModeChange(mode)


def assert_number(num):
    if isinstance(num, int):
        return num
    else:
        raise Exception("Got {}, but should be an int")


class ModeSet:
    def __init__(self, mode):
        self.mode = mode

    def apply(self, mode, is_dir=False):
        if self.mode == None:
            return mode
        else:
            return self.mode


# Support symbolic mode changes
class ModeChange:
    change_regex = re.compile('(?P<op>[-+=])(?P<change>[ugo]|[rwxXst]*)')

    def __init__(self, change):
        self.change = change
        self.cache = dict()

    def apply(self, mode, is_dir=False):
        key = (mode, is_dir)
        cached = self.cache.get(key)
        if cached != None:
            return cached

        mode_parts = self.change.split(',')

        new_mode = mode
        for mode_part in mode_parts:
            index = 0
            mask = 0
            for c in mode_part:
                if c == 'u':
                    mask |= 0o700
                elif c == 'g':
                    mask |= 0o070
                elif c == 'o':
                    mask |= 0o007
                elif c == 'a':
                    mask |= 0o777
                else:
                    break
                index += 1

            if index == 0:
                mask = 0o777

            while m := self.change_regex.match(mode_part, index):
                index = m.end()
                op = m.group('op')
                change_str = m.group('change')

                change = 0
                for c in change_str:
                    if c == 'r':
                        change |= 0o444
                    elif c == 'w':
                        change |= 0o222
                    elif c == 'x':
                        change |= 0o111
                    elif c == 'X':
                        if is_dir or new_mode & 0o111 > 0:
                            change |= 0o111
                    elif c == 's':
                        mask |= 0o7000
                        change |= 0o4000 | 0o2000
                    elif c == 't':
                        mask |= 0o7000
                        change |= 0o1000
                    elif c == 'u':
                        umode = new_mode & 0o700
                        change = umode | umode >> 3 | umode >> 6
                    elif c == 'g':
                        gmode = new_mode & 0o070
                        change = gmode << 3 | gmode | gmode >> 3
                    elif c == 'o':
                        omode = new_mode & 0o007
                        change = omode << 6 | omode << 3 | omode

                if op == '+':
                    new_mode = new_mode | (mask & change)
                elif op == '-':
                    new_mode = new_mode & ~(mask & change)
                else:
                    new_mode = (new_mode & ~mask) | (mask & change)

            if index != len(mode_part):
                raise Exception('Invalid mode string: {}'.format(mode_part))

        self.cache[key] = new_mode
        return new_mode


# This class assists with avoiding duplicate entries when copying in
# directories into the layer. OCI layers disallow having duplicate entries in
# the tar.
class CopyFromSources:
    def __init__(self, layer, path, info):
        self.layer = layer
        self.path = path
        self.info = info
        self.entries = set()

    def add_external_entry(self, path):
        self.entries.add(path)

    def do_copy(self):
        parent_uid = assert_number(self.info.get('uid', 0))
        parent_gid = assert_number(self.info.get('gid', 0))

        # copy in reverse order so that later sources take priority
        for source in reversed(self.info['sources']):
            uid = assert_number(source.get('uid', parent_uid))
            gid = assert_number(source.get('gid', parent_gid))
            mode = parse_mode(source.get('mode'))

            def modifier(tarinfo):
                tarinfo.mtime = self.layer.fixed_time
                tarinfo.uid = uid
                tarinfo.gid = gid
                tarinfo.uname = str(uid)
                tarinfo.gname = str(gid)
                tarinfo.mode = mode.apply(tarinfo.mode, tarinfo.isdir())

            self.add(source['path'], self.path, modifier)

    def add(self, source, arcname, modifier):
        tarinfo = self.layer.tar.gettarinfo(source, arcname)

        if tarinfo is None:
            return

        modifier(tarinfo)

        if tarinfo.isreg():
            with open(source, 'rb') as f:
                self.add_file(tarinfo, f)
        elif tarinfo.isdir():
            self.add_file(tarinfo, None)
            for f in sorted(os.listdir(source)):
                self.add(os.path.join(source, f), os.path.join(arcname, f),
                         modifier)
        else:
            self.add_file(tarinfo, None)

    def add_file(self, tarinfo, fileobj):
        if tarinfo.name in self.entries:
            if tarinfo.name != self.path:
                print("Warning: {} already exists, skipping".format(
                    tarinfo.name))
            return
        self.layer.tar.addfile(tarinfo, fileobj)
        self.entries.add(tarinfo.name)


class Layer:
    def __init__(self, out_path, umask, fixed_time):
        self.file_mode = 0o666 & ~umask
        self.dir_mode = 0o777 & ~umask
        self.fixed_time = fixed_time

        self.tar = tarfile.open(out_path, 'w')
        self.directories = set()
        self.directory_copiers = dict()

    def add_entry(self, path, info):
        parent = os.path.dirname(path)
        # a parent of '' means it's the "root"
        if parent != '' and parent not in self.directories:
            # recursively add parent directories as needed
            self.add_entry(parent, dict(type='directory'))

        tarinfo = tarfile.TarInfo(path)
        tarinfo.mtime = self.fixed_time
        tarinfo.uid = assert_number(info.get('uid', 0))
        tarinfo.gid = assert_number(info.get('gid', 0))

        # if we're under a directory that will be copied later, add ourselves
        # to the blocklist to avoid duplicates
        for key in self.directory_copiers:
            if path.startswith(key):
                self.directory_copiers[key].add_external_entry(path)

        if info['type'] == 'file':
            if 'source' in info:
                mode = parse_mode(info.get('mode'))
                stat = os.stat(info['source'])
                tarinfo.mode = mode.apply(stat.st_mode)
                tarinfo.size = stat.st_size
                with open(info['source'], 'rb') as f:
                    self.tar.addfile(tarinfo, f)
            else:
                text = bytes(info['text'], 'utf-8')
                tarinfo.mode = parse_mode(info.get('mode')).apply(
                    self.file_mode)
                tarinfo.size = len(text)
                with io.BytesIO(text) as f:
                    self.tar.addfile(tarinfo, f)

        elif info['type'] == 'link':
            tarinfo.type = tarfile.SYMTYPE
            tarinfo.mode = 0o777
            tarinfo.linkname = info['target']
            self.tar.addfile(tarinfo)

        elif info['type'] == 'directory':
            tarinfo.type = tarfile.DIRTYPE
            tarinfo.mode = parse_mode(info.get('mode')).apply(self.dir_mode)
            self.tar.addfile(tarinfo)

            if 'sources' in info:
                copier = CopyFromSources(self, path, info)
                copier.add_external_entry(path)

                # we defer the actual copying so that later entries can be
                # added to the layer, and these will be ignored by the bulk
                # copy
                self.directory_copiers[path] = copier

            self.directories.add(path)

        else:
            raise Exception('Unknown type: {}'.format(info['type']))

    def close(self):
        # actually do the directory copy so that all non-copy entries have been
        # added to the copier's blocklist
        for copier in self.directory_copiers.values():
            copier.do_copy()
        self.tar.close()


if __name__ == '__main__':
    out_dir = sys.argv[1]
    out_path = os.path.join(out_dir, 'layer.tar')
    umask = parse_mode(sys.argv[2]).apply(0)
    fixed_time = int(sys.argv[3])

    spec = json.loads(sys.stdin.read())

    if len(spec) > 0:
        normalized_spec = list(
            map(lambda entry: (parse_path(entry[0]), entry[1]), spec.items()))
        normalized_spec.sort(key=lambda x: x[0])

        layer = Layer(out_path, umask, fixed_time)

        for path, info in normalized_spec:
            layer.add_entry(path, info)

        layer.close()
