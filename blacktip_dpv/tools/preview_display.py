#!/usr/bin/env python3
"""Preview or export display frames from ``assets/display_lut.csv``.

Examples
--------
List the available display names::

    python tools/preview_display.py --list

Preview the first frame (index 0) in the terminal::

    python tools/preview_display.py --index 0

Export the "Display Battery" frame with rotation 2 to ``battery.pgm``::

    python tools/preview_display.py --name "Display Battery" --rotation 2 --output battery.pgm

The exported file uses the simple ASCII Portable Gray Map (PGM) format so it can
be opened by most image viewers or further processed in scripts without extra
Python dependencies.
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List

REPO_ROOT = Path(__file__).resolve().parents[1]
ASSET_PATH = REPO_ROOT / "assets" / "display_lut.csv"


@dataclass
class DisplayFrame:
    index: int
    name: str
    rotation: int
    bytes: List[int]

    @classmethod
    def from_row(cls, row: dict[str, str]) -> "DisplayFrame":
        data = [int(row[f"b{i}"], 10) for i in range(16)]
        return cls(index=int(row["index"], 10),
                   name=row["name"].strip(),
                   rotation=int(row["rotation"], 10),
                   bytes=data)

    def columns(self) -> List[int]:
        """Return the high-byte of each column (odd-indexed entries).

        The firmware stores display data as interleaved low/high bytes. Only the
        high byte carries the 8 pixel rows we need for visualization, so we read
        positions 1, 3, ..., 15 as columns.
        """
        return [self.bytes[i] for i in range(1, 16, 2)]

    def render_rows(self) -> List[str]:
        cols = self.columns()
        rows: List[str] = []
        for bit in range(7, -1, -1):
            row = ''.join('#' if (col >> bit) & 1 else '.' for col in cols)
            rows.append(row)
        return rows


def load_frames(path: Path) -> List[DisplayFrame]:
    frames: List[DisplayFrame] = []
    with path.open(newline="") as f:
        reader = csv.DictReader(f)
        required = {"index", "name", "rotation"} | {f"b{i}" for i in range(16)}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise ValueError(f"CSV file is missing columns: {sorted(missing)}")
        for row in reader:
            frames.append(DisplayFrame.from_row(row))
    return frames


def list_names(frames: Iterable[DisplayFrame]) -> None:
    by_name: dict[str, set[int]] = {}
    for frame in frames:
        by_name.setdefault(frame.name, set()).add(frame.rotation)
    for name in sorted(by_name):
        rotations = ', '.join(str(r) for r in sorted(by_name[name]))
        print(f"{name} (rotations: {rotations})")


def select_frame(frames: Iterable[DisplayFrame], *, index: int | None, name: str | None,
                 rotation: int | None) -> DisplayFrame:
    if index is not None:
        for frame in frames:
            if frame.index == index:
                return frame
        raise SystemExit(f"No frame with index {index} found")
    if name is None:
        raise SystemExit("Either --index or --name must be provided")
    candidates = [frame for frame in frames if frame.name.lower() == name.lower()]
    if not candidates:
        raise SystemExit(f"No frame found with name '{name}'")
    if rotation is None:
        if len({frame.rotation for frame in candidates}) > 1:
            raise SystemExit("Multiple rotations available. Please specify --rotation.")
        return candidates[0]
    for frame in candidates:
        if frame.rotation == rotation:
            return frame
    available = ', '.join(str(frame.rotation) for frame in candidates)
    raise SystemExit(f"No rotation {rotation} for '{name}'. Available: {available}")


def export_pgm(rows: List[str], path: Path) -> None:
    width = len(rows[0]) if rows else 0
    height = len(rows)
    with path.open('w') as f:
        f.write("P2\n")
        f.write(f"{width} {height}\n")
        f.write("1\n")
        for row in rows:
            f.write(' '.join('1' if ch == '#' else '0' for ch in row))
            f.write('\n')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--index', type=int, help='Select frame by absolute index')
    parser.add_argument('--name', help='Select frame by label (case-insensitive)')
    parser.add_argument('--rotation', type=int, help='Rotation number when selecting by name')
    parser.add_argument('--output', type=Path, help='Optional PGM output path')
    parser.add_argument('--list', action='store_true', help='List available display names and rotations')
    args = parser.parse_args()

    frames = load_frames(ASSET_PATH)

    if args.list:
        list_names(frames)
        return

    frame = select_frame(frames, index=args.index, name=args.name, rotation=args.rotation)
    rows = frame.render_rows()

    print(f"Frame index: {frame.index}")
    print(f"Name: {frame.name}")
    print(f"Rotation: {frame.rotation}")
    print()
    for row in rows:
        print(row)

    if args.output:
        export_pgm(rows, args.output)
        print(f"\nSaved preview to {args.output}")


if __name__ == '__main__':  # pragma: no cover - CLI entry point
    main()
