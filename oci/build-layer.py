#!/usr/bin/env python3

from argparse import ArgumentParser
from datetime import datetime, timezone
from pathlib import PurePosixPath, PosixPath
import io
import json
import os
import re
import stat
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
        return f'./{path}'


number_regex = re.compile('[0-9]+')
mode_regex = re.compile('[0-9]{4}')


def parse_mode(mode, umask=0):
    if mode == None:
        return ModeSet(None)
    elif mode_regex.fullmatch(mode):
        return ModeSet(int(mode, 8))
    elif number_regex.fullmatch(mode):
        raise Exception(
            f'Invalid mode: {mode}, please specify numeric modes as 4-digit octal'
        )
    else:
        return ModeChange(mode, umask)


def assert_number(num):
    if isinstance(num, int):
        return num
    else:
        raise Exception(f"Got {num}, but should be an int")


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

    def __init__(self, change, umask):
        self.change = change
        self.umask = umask
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
                mask = ~self.umask

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
                raise Exception(f'Invalid mode string: {mode_part}')

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

    def do_copy(self):
        parent_uid = assert_number(self.info.get('uid', 0))
        parent_gid = assert_number(self.info.get('gid', 0))

        # copy in reverse order so that later sources take priority
        for source in reversed(self.info['sources']):
            uid = assert_number(source.get('uid', parent_uid))
            gid = assert_number(source.get('gid', parent_gid))
            mode = parse_mode(source.get('mode'), self.layer.umask)

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
                self.layer.add_entry(tarinfo, f)
        elif tarinfo.isdir():
            self.layer.add_entry(tarinfo, None)
            for f in sorted(os.listdir(source)):
                self.add(os.path.join(source, f), os.path.join(arcname, f),
                         modifier)
        else:
            self.layer.add_entry(tarinfo, None)


class Layer:
    def __init__(self, out_path, umask, fixed_time):
        self.umask = umask
        self.file_mode = 0o666 & ~umask
        self.dir_mode = 0o777 & ~umask
        self.fixed_time = fixed_time

        self.entries = set()
        if os.path.exists(out_path):
            if tarfile.is_tarfile(out_path):
                with tarfile.open(out_path, 'r') as t:
                    self.entries = set(map(parse_path, t.getnames()))
            else:
                print('{out_path} is not a tar file')
                sys.exit(1)

        self.tar = tarfile.open(out_path, 'a')
        self.directory_copiers = list()

    def add(self, path, info):
        parent = os.path.dirname(path)
        # a parent of '' means it's the "root"
        if parent != '' and parent not in self.entries:
            # recursively add parent directories as needed
            self.add(parent, dict(type='directory'))

        tarinfo = tarfile.TarInfo(path)
        tarinfo.mtime = self.fixed_time
        tarinfo.uid = assert_number(info.get('uid', 0))
        tarinfo.gid = assert_number(info.get('gid', 0))

        mode = parse_mode(info.get('mode'), self.umask)

        if info['type'] == 'file':
            if 'source' in info:
                stat = os.stat(info['source'])
                tarinfo.mode = mode.apply(stat.st_mode)
                tarinfo.size = stat.st_size
                with open(info['source'], 'rb') as f:
                    self.add_entry(tarinfo, f)
            else:
                text = bytes(info['text'], 'utf-8')
                tarinfo.mode = mode.apply(self.file_mode)
                tarinfo.size = len(text)
                with io.BytesIO(text) as f:
                    self.add_entry(tarinfo, f)

        elif info['type'] == 'link':
            tarinfo.type = tarfile.SYMTYPE
            tarinfo.mode = 0o777
            tarinfo.linkname = info['target']
            self.add_entry(tarinfo)

        elif info['type'] == 'directory':
            tarinfo.type = tarfile.DIRTYPE
            tarinfo.mode = mode.apply(self.dir_mode)
            self.add_entry(tarinfo)

            if 'sources' in info:
                copier = CopyFromSources(self, path, info)

                # we defer the actual copying so that later entries can be
                # added to the layer, and these will be ignored by the bulk
                # copy
                self.directory_copiers.append(copier)

        else:
            raise Exception(f"Unknown type for {path}: {info['type']}")

    def add_entry(self, tarinfo, fileobj=None):
        if tarinfo.name in self.entries:
            if not tarinfo.isdir():
                print(f"Warning: {tarinfo.name} already exists, skipping")
            return
        self.tar.addfile(tarinfo, fileobj)
        self.entries.add(tarinfo.name)

    def close(self):
        # actually do the directory copy so that all non-copy entries have been
        # added to the copier's blocklist
        for copier in self.directory_copiers:
            copier.do_copy()
        self.tar.close()


if __name__ == '__main__':
    parser = ArgumentParser(description='Add nix store paths to layer')
    parser.add_argument('--mtime', type=int, default=0)
    parser.add_argument('--umask', default='0022')
    parser.add_argument('--entries')
    parser.add_argument('--includes')
    parser.add_argument('--excludes')
    parser.add_argument('--out', required=True)
    opts = parser.parse_args()

    spec = dict()
    if opts.entries != None:
        with open(opts.entries) as f:
            spec = json.loads(f.read())

    normalized_spec = list(
        map(lambda entry: (parse_path(entry[0]), entry[1]), spec.items()))
    normalized_spec.sort(key=lambda x: x[0])

    additional_paths = set()
    if opts.includes != None:
        with open(opts.includes) as f:
            for line in f:
                additional_paths.add(line.rstrip("\n"))

    if opts.excludes != None:
        with open(opts.excludes) as f:
            for line in f:
                additional_paths.discard(line.rstrip("\n"))

    # we keep this separate from normalized_spec to ensure precedence
    additional_spec = []
    for path in additional_paths:
        stmd = os.stat(path, follow_symlinks=False).st_mode
        info = dict(uid=0, gid=0)
        if stat.S_ISDIR(stmd):
            info['type'] = 'directory'
            info['sources'] = [dict(path=path)]
        elif stat.S_ISLNK(stmd):
            info['type'] = 'link'
            info['target'] = os.readlink(path)
        elif stat.S_ISREG(stmd):
            info['type'] = 'file'
            info['source'] = path
        else:
            raise Exception(f'Unsupported file: {path}')

        additional_spec.append((parse_path(path), info))
    additional_spec.sort(key=lambda x: x[0])

    full_spec = normalized_spec + additional_spec

    if len(full_spec) > 0:
        umask = parse_mode(opts.umask).apply(0)
        layer = Layer(opts.out, umask, opts.mtime)

        for path, info in full_spec:
            print(f"Adding to layer '{path}'")
            layer.add(path, info)

        layer.close()
