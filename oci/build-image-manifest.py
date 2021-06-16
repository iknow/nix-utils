#!/usr/bin/env python3

from argparse import ArgumentParser
import hashlib
import json
import os
import shutil


def hash(data):
    m = hashlib.sha256()
    m.update(bytes(data, 'utf-8'))
    return m.hexdigest()


if __name__ == '__main__':
    parser = ArgumentParser(description='Build image manifest')
    parser.add_argument('layers', nargs='+')
    parser.add_argument('--config', required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--architecture', required=True)
    parser.add_argument('--os', required=True)
    parser.add_argument('--out', required=True)
    opts = parser.parse_args()

    non_empty_layers = []
    for layer in opts.layers:
        if os.path.exists(os.path.join(layer, 'layer.tar')):
            with open(os.path.join(layer, 'metadata.json')) as f:
                non_empty_layers.append((layer, json.load(f)))

    with open(opts.config) as f:
        container_config = json.load(f)

    config = json.dumps({
        'created': '1970-01-01T00:00:00Z',
        'rootfs': {
            'type': 'layers',
            'diff_ids': list(map(lambda x: x[1]['digest'], non_empty_layers))
        },
        'config': container_config,
        'architecture': opts.architecture,
        'os': opts.os,
    })

    config_hash = hash(config)

    manifest = json.dumps({
        'schemaVersion': 2,
        'config': {
            'mediaType': 'application/vnd.oci.image.config.v1+json',
            'size': len(config),
            'digest': 'sha256:{}'.format(config_hash)
        },
        'layers': list(map(lambda x: x[1], non_empty_layers))
    })

    manifest_hash = hash(manifest)

    metadata_dict = {
        'mediaType': 'application/vnd.oci.image.manifest.v1+json',
        'size': len(manifest),
        'digest': 'sha256:{}'.format(manifest_hash),
        'platform': {
            'architecture': opts.architecture,
            'os': opts.os,
        }
    }

    if opts.tag != '':
        metadata_dict['annotations'] = {
            'org.opencontainers.image.ref.name': opts.tag
        }

    blobs_path = os.path.join(opts.out, 'blobs', 'sha256')
    os.makedirs(blobs_path)

    def open_file(name):
        return open(os.path.join(opts.out, name), 'w', encoding='utf-8')

    with open_file('config.json') as f:
        f.write(config)
        os.symlink(f.name, os.path.join(blobs_path, config_hash))

    with open_file('manifest.json') as f:
        f.write(manifest)
        os.symlink(f.name, os.path.join(blobs_path, manifest_hash))

    with open_file('metadata.json') as f:
        json.dump(metadata_dict, f)

    for layer in non_empty_layers:
        layer_blobs_path = os.path.join(layer[0], 'blobs', 'sha256')
        for path in os.listdir(layer_blobs_path):
            shutil.copyfile(os.path.join(layer_blobs_path, path),
                            os.path.join(blobs_path, path),
                            follow_symlinks=False)
