# Display Lookup Table Management

This directory contains tools and assets for managing the OLED display artwork.

## Asset Files

- **`assets/display_lut.csv`** — All display frames (124 rows, one per screen/rotation)
- **`assets/brightness_levels.csv`** — Brightness command bytes (6 levels)

## Tools

### `update_display_tables.py`
Regenerates the embedded lookup table sections in `blacktip_dpv.lisp` from the CSV assets.

```bash
python tools/update_display_tables.py        # Update lisp file
python tools/update_display_tables.py --check # Verify no changes needed (CI mode)
```

The Makefile runs this automatically before building the package.

### `generate_lut_resource.py`
Creates a standalone LispBM resource file (`generated/display_lut_data.lisp`) that can be imported at runtime instead of embedding data in the main source.

```bash
python tools/generate_lut_resource.py
# or
make resource
```

This is an alternative approach for those who prefer cleaner source files.

### `preview_display.py`
ASCII/PGM visualization tool for exploring and verifying display artwork.

```bash
# List all available screens
python tools/preview_display.py --list

# Preview a specific frame by index
python tools/preview_display.py --index 0

# Preview by name and rotation
python tools/preview_display.py --name "Display Battery 4 Bars" --rotation 0

# Show all screens for a given rotation
python tools/preview_display.py --show-all-rotation 0

# Export as PGM image
python tools/preview_display.py --index 0 --output preview.pgm
```

## Display Orientation

The preview tool applies the correct 90° clockwise rotation and vertical flip to match the physical hardware orientation. What you see in the ASCII preview is what appears on the actual screen.

## Workflow

### Editing Display Artwork

1. Edit `assets/display_lut.csv` (modify existing frames or add new ones)
2. Preview your changes: `python tools/preview_display.py --index N`
3. Regenerate embedded code: `python tools/update_display_tables.py`
4. Build package: `make`

### Adding New Displays

Add four rows to `display_lut.csv` (one per rotation 0-3). The `index` field must be sequential and unique. Each row has 16 byte fields (`b0` through `b15`) representing the 8×8 pixel matrix as interleaved low/high column bytes.

### Changing Brightness Levels

Edit `assets/brightness_levels.csv` to modify the I2C command bytes for each brightness level (0-5). Then regenerate with `python tools/update_display_tables.py`.

## Testing

```bash
make test  # Runs whitespace and display table checks
```

The `check-display-tables` target verifies that `blacktip_dpv.lisp` matches the current CSV data, failing the build if manual edits are needed.
