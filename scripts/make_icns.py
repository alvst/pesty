#!/usr/bin/env python3
"""Build an ICNS container from a complete PNG iconset."""

from __future__ import annotations

import argparse
import struct
from pathlib import Path


ICON_ENTRIES = (
    ("ic04", "icon_16x16.png", 16),
    ("ic11", "icon_16x16@2x.png", 32),
    ("ic05", "icon_32x32.png", 32),
    ("ic12", "icon_32x32@2x.png", 64),
    ("ic07", "icon_128x128.png", 128),
    ("ic13", "icon_128x128@2x.png", 256),
    ("ic08", "icon_256x256.png", 256),
    ("ic14", "icon_256x256@2x.png", 512),
    ("ic09", "icon_512x512.png", 512),
    ("ic10", "icon_512x512@2x.png", 1024),
)


def png_size(data: bytes) -> tuple[int, int]:
    if data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise ValueError("not a PNG image")
    return struct.unpack(">II", data[16:24])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("iconset", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    chunks: list[bytes] = []
    for kind, filename, expected_size in ICON_ENTRIES:
        path = args.iconset / filename
        data = path.read_bytes()
        size = png_size(data)
        if size != (expected_size, expected_size):
            raise ValueError(
                f"{path} is {size[0]}x{size[1]}; expected "
                f"{expected_size}x{expected_size}"
            )
        chunks.append(kind.encode("ascii") + struct.pack(">I", len(data) + 8) + data)

    body = b"".join(chunks)
    output = b"icns" + struct.pack(">I", len(body) + 8) + body
    args.output.write_bytes(output)


if __name__ == "__main__":
    main()
