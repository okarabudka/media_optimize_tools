"""Insert a minimal EXIF block (Make, DateTimeOriginal) into a JPEG file in place.

Test fixture helper: ImageMagick cannot write EXIF tags, so the APP1 segment is
built by hand. Usage: add_exif.py FILE.jpg "YYYY:MM:DD HH:MM:SS"
"""

import struct
import sys


def exif_segment(date):
    make = b"TestCam\x00"
    when = date.encode() + b"\x00"
    ifd0 = 8
    exif_ifd = ifd0 + 2 + 2 * 12 + 4
    data = exif_ifd + 2 + 12 + 4
    tiff = b"II*\x00" + struct.pack("<I", ifd0)
    tiff += struct.pack("<H", 2)
    tiff += struct.pack("<HHII", 0x010F, 2, len(make), data)  # Make
    tiff += struct.pack("<HHII", 0x8769, 4, 1, exif_ifd)  # pointer to the Exif IFD
    tiff += struct.pack("<I", 0)
    tiff += struct.pack("<H", 1)
    tiff += struct.pack("<HHII", 0x9003, 2, len(when), data + len(make))  # DateTimeOriginal
    tiff += struct.pack("<I", 0)
    tiff += make + when
    payload = b"Exif\x00\x00" + tiff
    return b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload


def main(path, date):
    with open(path, "rb") as f:
        jpeg = f.read()
    if jpeg[:2] != b"\xff\xd8":
        sys.exit(f"{path}: not a JPEG file")
    with open(path, "wb") as f:
        f.write(jpeg[:2] + exif_segment(date) + jpeg[2:])


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
