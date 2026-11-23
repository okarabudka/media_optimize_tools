"""Find files with identical content below a directory.

Files are grouped by size first, so only same-size candidates are hashed.
Output (stdout):
    line 1:  STATS<TAB><groups><TAB><redundant files><TAB><redundant bytes>
    line 2+: paths of redundant files; the alphabetically first file of each
             group is the one to keep and is not listed.
"""

import collections
import hashlib
import os
import sys

CHUNK = 1 << 20


def file_hash(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(CHUNK), b""):
            h.update(chunk)
    return h.hexdigest()


def main(target):
    by_size = collections.defaultdict(list)
    for root, dirs, files in os.walk(target):
        dirs.sort()
        for name in sorted(files):
            path = os.path.join(root, name)
            if os.path.islink(path):
                continue
            by_size[os.path.getsize(path)].append(path)

    by_hash = collections.defaultdict(list)
    for size, paths in by_size.items():
        if len(paths) < 2:
            continue
        for path in paths:
            by_hash[(size, file_hash(path))].append(path)

    groups = 0
    redundant = []
    for key in sorted(by_hash):
        paths = by_hash[key]
        if len(paths) < 2:
            continue
        groups += 1
        redundant.extend((key[0], p) for p in sorted(paths)[1:])

    print("STATS\t{}\t{}\t{}".format(groups, len(redundant), sum(s for s, _ in redundant)))
    for _, path in redundant:
        print(path)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: find_dupes.py DIR")
    main(sys.argv[1])
