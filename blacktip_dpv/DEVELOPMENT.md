# BlackTip DPV Development Documentation

This document contains information for developers working on the BlackTip DPV firmware.

## Build System

The project uses GNU Make for building the VESC package:

```bash
make              # Build blacktip_dpv.vescpkg
make clean        # Remove generated files
make test         # Run code quality checks and smoke tests
make smoke-tests  # Run unit-style smoke tests only
make binary       # Generate binary LUT files only
```

### Version Management

The build system automatically generates version information for the package:

- **Version source**: Base version (e.g., `1.0.0`) is stored in `README.md` in the line `**Version:** 1.0.0`
- **Version format**:
  - On `main` branch: `<version>-<yyyymmdd>-<git-hash>` (e.g., `1.0.0-20251013-120605-2eacfa2`)
  - On other branches: `<version>-<branch-name>-<git-hash>` (e.g., `1.0.0-feature-xyz-2eacfa2`)
- **Distribution**: During build, `tools/update_version.sh` creates `README.dist.md` with the full version and build timestamp
- **Package**: The `.vescpkg` includes `README.dist.md` (referenced in `pkgdesc.qml`) so users see the detailed version info
- **Repository**: The `README.md` in the repository shows only the base version for simplicity
- **Rebuild behavior**: The package is only rebuilt when source files change (`blacktip_dpv.lisp`, `ui.qml`, `pkgdesc.qml`, `README.md`)

To update the version:

1. Edit the version line in `README.md`: `**Version:** 1.1.0`
2. Run `make` - the distribution file will be generated automatically with a new timestamp

**Note**: `README.dist.md` is generated during build and should not be committed to git.

### Test Suite

The project includes smoke tests for pure functions to catch regressions before
flashing hardware:

```bash
make smoke-tests  # Run 30+ unit tests for pure functions
```

**Tested functions:**
- `clamp` - Value clamping (7 tests)
- `validate_boolean` - Boolean validation (5 tests)
- `state_name_for` - State name mapping (6 tests)
- `speed_percentage_at` - Speed percentage lookup (5 tests)
- `calculate_rpm` - RPM calculation (7 tests)

Tests are implemented in Python (`tests/run_tests.py`) to mirror the LispBM
implementations and verify correctness without needing hardware.

## Project Structure

```text
blacktip_dpv/
├── assets/                          # Source data files
│   ├── display_lut.csv             # Display frames (124 frames × 4 rotations)
│   └── brightness_levels.csv       # Brightness levels (6 levels)
├── tools/                           # Build and development tools
│   ├── generate_lut_binary.py      # Generates binary files from CSV
│   └── preview_display.py          # ASCII/PGM visualization tool
├── generated/                       # Auto-generated files (not in git)
│   ├── display_lut.bin             # Binary display data (1992 bytes)
│   └── brightness_lut.bin          # Binary brightness data (14 bytes)
├── blacktip_dpv.lisp               # Main firmware source
├── ui.qml                           # User interface
├── pkgdesc.qml                     # Package descriptor
└── README.md                        # User-facing documentation

## Display Assets and Tooling

### Asset Files

The OLED screen artwork and brightness tables live in `assets/` as CSV files:

- **`display_lut.csv`** — All display frames (124 rows, one per screen/rotation)
- **`brightness_levels.csv`** — Brightness command bytes (6 levels)

These CSV files are the source of truth. The build system automatically generates
binary files from them.

### Preview Tool

Visualize and verify display artwork before building:

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

The preview tool applies the correct 90° clockwise rotation and vertical flip to
match the physical hardware orientation.

### Binary File Format

The firmware loads display and brightness data from binary files at runtime using
LispBM's `import` statement. These files are automatically generated from the CSV
assets during the build process.

**Display LUT** (`generated/display_lut.bin`):
- Header (8 bytes):
  - Magic number: 0x4C555444 ("LUTD" in ASCII)
  - Version: u16 (currently 1)
  - Frame count: u16 (currently 124)
- Frame data: 124 frames × 4 rotations × 16 bytes per frame = 1984 bytes
- Total size: 1992 bytes

**Brightness LUT** (`generated/brightness_lut.bin`):
- Header (8 bytes):
  - Magic number: 0x4C555442 ("LUTB" in ASCII)
  - Version: u16 (currently 1)
  - Level count: u16 (currently 6)
- Level data: 6 brightness levels × 1 byte = 6 bytes
- Total size: 14 bytes

The firmware validates the magic numbers and versions at startup to ensure data
integrity.

## Development Workflow

### Editing Display Artwork

1. Edit `assets/display_lut.csv` (modify existing frames or add new ones)
2. Preview your changes: `python tools/preview_display.py --index N`
3. Build package: `make`

The binary files will be automatically regenerated from the CSV.

### Adding New Displays

Add four rows to `display_lut.csv` (one per rotation 0-3). The `index` field must
be sequential and unique. Each row has 16 byte fields (`b0` through `b15`)
representing the 8×8 pixel matrix as interleaved low/high column bytes.

### Changing Brightness Levels

Edit `assets/brightness_levels.csv` to modify the I2C command bytes for each
brightness level (0-5). The binary file will be regenerated on next build.

## Display Orientation

The display hardware is rotated 90° clockwise relative to the natural orientation.
The preview tool and firmware both handle this transformation automatically.

Each display frame consists of:
- 8 columns × 8 rows = 64 pixels
- Stored as 16 bytes (8 column pairs, each pair = low byte + high byte)
- Bit 7 (MSB) = top pixel, Bit 0 (LSB) = bottom pixel in each column

## Code Quality

### Testing

```bash
make test  # Runs whitespace checks
```

### Code Style

- Use snake_case for LispBM variable and function names
- Use 4 spaces for indentation (not tabs)
- No trailing whitespace
- Brace style: 1TBS (One True Brace Style)
- See `.github/instructions/copilot-instructions.md` for full style guide

## Logging Hygiene

The firmware uses conditional debug logging to minimize memory pressure on the
resource-constrained VESC hardware.

### Debug Logging Functions

Two mechanisms are available for debug logging:

**`debug_log` function** - For static strings:
```lisp
(debug_log "Motor: Stopping motor")
```

**`when-debug` macro** - For dynamic strings with expensive operations:
```lisp
(when-debug (str-merge "Speed: Set to " (to-str clamped_speed)))
```

### When to Use `when-debug`

Use the `when-debug` macro when logging requires:
- String concatenation (`str-merge`)
- Number-to-string conversion (`to-str`)
- Any other expensive operations

The macro only evaluates these expressions when `debug_enabled` is 1, preventing
unnecessary memory allocation and CPU cycles in hot paths.

### Hot Paths Requiring `when-debug`

- `set_speed_safe` - Called every speed change (multiple times per second)
- Motor control loop - Runs continuously
- State machine handlers - Active during user interactions
- Click action handlers - Called on every button press

### Example

**Bad** (evaluates `str-merge` even when debug is off):
```lisp
(debug_log (str-merge "Speed: Set to " (to-str speed)))
```

**Good** (only evaluates when debug is enabled):
```lisp
(when-debug (str-merge "Speed: Set to " (to-str speed)))
```

## Testing Best Practices

### Adding Tests for Pure Functions

When adding new pure functions (functions without side effects), add corresponding
tests to `tests/run_tests.py`:

1. **Identify pure functions** - Functions that always return the same output for
   the same input, with no side effects (no I/O, no state modification)

2. **Implement Python equivalent** - Create a Python version that mirrors the
   LispBM logic exactly

3. **Write test cases** - Cover:
   - Normal/expected inputs
   - Boundary conditions (min, max, zero)
   - Edge cases (negative, overflow, empty)
   - Error conditions

4. **Run tests before committing**:
   ```bash
   make test  # Runs whitespace checks + smoke tests
   ```

### What to Test

✅ **Pure functions** - Calculations, validation, state mappings  
✅ **Boundary conditions** - Min/max values, thresholds  
✅ **Edge cases** - Empty lists, negative values, overflow  
❌ **Hardware I/O** - Not feasible without full simulation  
❌ **State machines** - Complex runtime behavior, test manually

### Test Structure

Each test function should:
- Have a descriptive name (`test_function_name`)
- Print a section header
- Use `assert_eq` or `assert_near` for validation
- Include descriptive test names explaining what's being tested

Example:
```python
def test_new_function():
    print("\n=== Testing new_function ===")
    assert_eq(new_function(5), 10, "new_function: basic case")
    assert_eq(new_function(0), 0, "new_function: zero input")
    assert_eq(new_function(-1), 0, "new_function: negative clamped")
```

## Binary Loading Implementation

The firmware uses LispBM's `import` statement to load binary data at runtime:

```lisp
; Import binary files
(import "generated/display_lut.bin" 'display-lut-bin)
(import "generated/brightness_lut.bin" 'brightness-lut-bin)

; Validate headers
(defun validate-lut-header (data magic expected-version) { ... })

; Access display data (offset by 8-byte header)
(bufcpy pixbuf 0 display-lut-bin (+ 8 start_pos) 16)

; Access brightness data (offset by 8-byte header)
(bufget-u8 brightness-lut-bin (+ 8 brightness_index))
```

### Why `pixbuf` is Required

The `pixbuf` variable is a 16-byte working buffer that is essential to the display
system and **cannot be removed**:

```lisp
(let ((start_pos 0)
      (pixbuf (array-create 16))) {  ; ← Temporary 16-byte buffer
    ...
    ; Copy 16 bytes from binary file to pixbuf
    (bufcpy pixbuf 0 display-lut-bin (+ 8 start_pos) 16)

    ; Send pixbuf to display via I2C
    (i2c-tx-rx mpu-addr pixbuf)
})
```

**Why it's needed:**
1. The `i2c-tx-rx` function requires a buffer to send data
2. We cannot send data directly from the binary file to I2C
3. The buffer extracts the specific 16-byte frame we need from the larger binary file
4. It's a small (16 bytes) stack-allocated array with negligible overhead

## Build Dependencies

- Python 3.x (for build tools)
- VESC Tool (for building .vescpkg files)
- Standard Unix tools (make, grep, etc.)

## Repository

<https://github.com/mikeller/vesc_pkg>
