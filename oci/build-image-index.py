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


def load_image_metadata(image):
    with open(os.path.join(image, 'metadata.json')) as f:
        return json.loads(f.read())


if __name__ == '__main__':
    parser = ArgumentParser(description='Build image index')
    parser.add_argument('images', nargs='+')
    parser.add_argument('--out', required=True)
    opts = parser.parse_args()

    image_metadatas = [load_image_metadata(i) for i in opts.images]

    manifest = json.dumps({
        'schemaVersion': 2,
        'mediaType': 'application/vnd.oci.image.index.v1+json',
        'manifests': image_metadatas,
    })

    manifest_hash = hash(manifest)

    metadata_dict = {
        'mediaType': 'application/vnd.oci.image.index.v1+json',
        'size': len(manifest),
        'digest': 'sha256:{}'.format(manifest_hash),
    }

    blobs_path = os.path.join(opts.out, 'blobs', 'sha256')
    os.makedirs(blobs_path)

    def open_file(name):
        return open(os.path.join(opts.out, name), 'w', encoding='utf-8')

    with open_file('manifest.json') as f:
        f.write(manifest)
        os.symlink(f.name, os.path.join(blobs_path, manifest_hash))

    with open_file('metadata.json') as f:
        json.dump(metadata_dict, f)

    for image in opts.images:
        layer_blobs_path = os.path.join(image, 'blobs', 'sha256')
        for path in os.listdir(layer_blobs_path):
            shutil.copyfile(os.path.join(layer_blobs_path, path),
                            os.path.join(blobs_path, path),
                            follow_symlinks=False)
