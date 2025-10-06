#!/usr/bin/env python3
"""Generate binary file from display lookup table for efficient import.

The binary format is optimized for direct memory access without parsing.
It can be imported using the `import` statement and then loaded as a byte array.

Format:
    Header (8 bytes):
        magic: 0x4C555444 (ASCII "LUTD")
        version: u16 (1)
        num_frames: u16

    Frame data (num_frames * 16 bytes):
        Each frame is 16 bytes (8 column pairs of low/high bytes)

Usage::
    python tools/generate_lut_binary.py
"""
from __future__ import annotations

import csv
import struct
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
ASSET_DIR = REPO_ROOT / "assets"
GENERATED_DIR = REPO_ROOT / "generated"
DISPLAY_CSV = ASSET_DIR / "display_lut.csv"
BRIGHTNESS_CSV = ASSET_DIR / "brightness_levels.csv"
DISPLAY_BIN = GENERATED_DIR / "display_lut.bin"
BRIGHTNESS_BIN = GENERATED_DIR / "brightness_lut.bin"

# Magic number for display LUT binary file
MAGIC_DISPLAY = 0x4C555444  # ASCII "LUTD"
MAGIC_BRIGHTNESS = 0x4C555442  # ASCII "LUTB"
VERSION = 1


def generate_display_binary() -> None:
    """Generate binary file from display LUT CSV."""
    # Read all frames from CSV
    frames: list[tuple[int, list[int]]] = []
    with DISPLAY_CSV.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Extract 16 bytes per frame
            index = int(row["index"])
            frame_bytes = [int(row[f"b{i}"]) for i in range(16)]
            frames.append((index, frame_bytes))

    # Sort by index to ensure correct order
    # (CSV should already be sorted, but let's be explicit)
    frames.sort(key=lambda item: item[0])

    # Write binary file
    GENERATED_DIR.mkdir(exist_ok=True)
    with DISPLAY_BIN.open('wb') as f:
        # Write header
        f.write(struct.pack('<I', MAGIC_DISPLAY))  # magic (little-endian u32)
        f.write(struct.pack('<H', VERSION))        # version (little-endian u16)
        f.write(struct.pack('<H', len(frames)))    # num_frames (little-endian u16)

        # Write frame data
        for _, frame_bytes in frames:
            f.write(bytes(frame_bytes))

    print(f"Generated {DISPLAY_BIN}")
    print(f"  Size: {DISPLAY_BIN.stat().st_size} bytes")
    print(f"  Frames: {len(frames)}")


def generate_brightness_binary() -> None:
    """Generate binary file from brightness levels CSV."""
    # Read all levels from CSV
    levels = []
    with BRIGHTNESS_CSV.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            value = int(row["value"])
            levels.append(value)

    # Write binary file
    GENERATED_DIR.mkdir(exist_ok=True)
    with BRIGHTNESS_BIN.open('wb') as f:
        # Write header
        f.write(struct.pack('<I', MAGIC_BRIGHTNESS))  # magic (little-endian u32)
        f.write(struct.pack('<H', VERSION))           # version (little-endian u16)
        f.write(struct.pack('<H', len(levels)))       # num_levels (little-endian u16)

        # Write level data (each level is 1 byte)
        f.write(bytes(levels))

    print(f"Generated {BRIGHTNESS_BIN}")
    print(f"  Size: {BRIGHTNESS_BIN.stat().st_size} bytes")
    print(f"  Levels: {len(levels)}")


def main() -> None:
    """Generate both binary files."""
    generate_display_binary()
    generate_brightness_binary()


if __name__ == "__main__":
    main()
