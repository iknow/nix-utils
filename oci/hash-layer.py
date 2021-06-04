#!/usr/bin/env python3

import hashlib
import json
import os
import sys

if __name__ == '__main__':
    out_dir = sys.argv[1]
    out_path = os.path.join(out_dir, 'layer.tar')
    metadata_path = os.path.join(out_dir, 'metadata.json')
    blobs_path = os.path.join(out_dir, 'blobs', 'sha256')

    stat = os.stat(out_path)
    size = stat.st_size

    m = hashlib.sha256()
    with open(out_path, 'rb') as f:
        read_bytes = 0
        while read_bytes < size:
            buf = f.read(65536)
            m.update(buf)
            read_bytes += len(buf)
    sha256 = m.hexdigest()

    metadata = dict(mediaType='application/vnd.oci.image.layer.v1.tar',
                    size=size,
                    digest="sha256:{}".format(sha256))

    with open(metadata_path, 'w') as f:
        f.write(json.dumps(metadata))

    # create the blobs structure for consolidation later
    os.makedirs(blobs_path)
    os.symlink(out_path, os.path.join(blobs_path, sha256))
