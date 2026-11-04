# BlackTip DPV Development Documentation

## lispBM Runtime Architecture Overview

The BlackTip DPV lispBM runtime is organized as a set of cooperative threads and event-driven state machines, designed for reliability and clarity on resource-constrained VESC hardware. Key architectural components:

* **State Machine:**
  * Manages button presses, clicks, long holds, and transitions between operational states (off, running, Smart Cruise, etc.).
  * Implements logic for Smart Cruise activation, speed changes, and safety features.
* **Display Update Loop:**
  * Periodically updates the OLED display with speed, battery, Smart Cruise status, error codes, and timer bar.
  * Uses a lookup table for LED timer bar mapping (left-to-right countdown).
    * Loads display frames from a binary file generated from a CSV asset.
* **Smart Cruise Logic:**
  * Allows hands-free operation with configurable timeout and auto-engage.
  * Visual feedback via display and 8-LED timer bar; warning mode triggers slowdown and beep.
  * Speed changes require a long hold before tap, preventing accidental adjustments.
* **Peripheral Loops:**
  * Separate threads for motor control, trigger/button polling, battery monitoring, and Smart Cruise background checks.
  * Each loop uses minimal stack and sleep intervals to conserve memory and CPU.
* **Startup Audio Arbitration:**
   * The startup tune and battery indication use synchronous `foc-beep`, which temporarily owns the FOC path.
   * A motor start sets `startup_tune_cancelled` and clears deferred battery beeps. The tune observes cancellation between notes, allowing an active note to complete without later notes reclaiming motor control.
* **Logging and Debugging:**
  * Conditional debug logging via `debug_log` and `when-debug` macros to minimize memory usage.
    * Debug output can be enabled for troubleshooting in VESC Tool.
* **Configuration and EEPROM:**
  * Settings are stored in EEPROM and loaded at startup; configuration is managed via QML UI in VESC Tool.
  * Battery calculation supports voltage-based or ampere-hour-based methods.
* **Battery Imbalance Detection:**
  * Dedicated balance-wire thread monitors the midpoint between the two series battery packs.
  * At-rest-only sampling with a settle window, EMA smoothing, latched warnings, and SOC scaling — see [Battery Imbalance Detection](#battery-imbalance-detection) below for the algorithm.
* **Performance Log (specified, not yet implemented):**
  * Opt-in, off-by-default aggregate statistics kept in EEPROM slots 64 to 126, flushed only at rest; see [Performance Log (on-device)](#performance-log-on-device) below for the contract.

For more details, see the sections below and refer to `blacktip_dpv.lisp` for implementation specifics.

This document contains information for developers working on the BlackTip DPV VESC package.

## VESC 7.00 Compatibility

### Flash / Heap Layout Strategy

VESC firmware 7.00 introduced a persistent flash heap using `@const-start` / `@const-end` blocks that replaces the older `move-to-flash` pattern. The runtime is structured as two const blocks with mutable state defined between them:

```lisp
@const-start       ; Block 1: constants and the debug-logging macro (flashed, immutable)
  (define SLEEP_STATE_MACHINE …)
  …
  (define debug_log_format …)
@const-end

; MUTABLE GLOBAL STATE — heap-resident (NOT flashed), so setvar/set works at runtime.
(define sw_state 0)
…

(import "generated/display_lut.bin" 'display_lut_bin)

@const-start       ; Block 2: all functions (flashed, immutable)
  (defun eeprom_store_i_if_changed …)
  …
@const-end

; Boot sequence: init, then (progn (image-save) (main)) as a single top-level form.
(init)
(progn
    (image-save)
    (main))
```

**Rules that govern this layout:**

**(a) Mutable globals must live outside the const blocks.**
Flashed bindings are immutable. Every variable written at runtime via `setvar` or `set` must be defined on the working heap, between the two const blocks. These heap globals are pre-defined at the top level so their initialisers can reference already-flashed constants.

**(b) Const-block initialisers are evaluated in source order.**
A constant that references an earlier constant (e.g. `SOFT_START_DURATION` referencing `SAFE_START_TIMEOUT`) must come after it in the file. Function bodies have no such ordering constraint; LispBM resolves symbols at call time, not at definition time.

**(c) Hardware init runs on every boot.**
`image-save` does not restore external hardware state. All hardware initialisation (`i2c-start`, `gpio-configure`, oscillator setup) must live in the `init` / `main` call path so it re-executes on each cold boot.

**(d) `import` must be a top-level form, not inside a flashed function.**
When an `import` lives inside a flashed const-block function, the binding action is lost on subsequent boots; the imported symbol resolves to `nil`, causing `bufget-u32` type errors at runtime. The `import` for `display_lut.bin` is therefore placed as a top-level form between the two const blocks, where it runs once each time the package source is evaluated.

**(e) `image-save` and `main` must be wrapped in a single `(progn …)` form.**
`image-save` relocates the heap and serialises the environment, which invalidates the reader's source channel. If `image-save` and `main` are separate top-level forms, the reader tries to read `main` from the channel after `image-save` has run and fails with `read_error / ~CHANNEL~`. Wrapping both in one `(progn …)` means the entire form is parsed first, then `image-save` and `main` execute back-to-back with no intervening read.

**(f) On subsequent boots the saved image is loaded and `main` is auto-invoked.**
Only `init` runs from source on the very first boot after a fresh package upload. From the second boot onwards, the saved image is restored and `main` is invoked directly, bypassing the reader entirely.

### VESC 7.00 Known Bugs and Workarounds

#### I2C First-Message Bug

On VESC firmware 7.00, the first `i2c-tx-rx` call issued after `i2c-start` — i.e. the first transaction on a freshly muxed bus, which happens on every cold boot — is silently swallowed and never reaches the I2C device.

**Effect on cold boot:** The HT16K33 display controller's oscillator-enable command (`0x21`) was dropped on every cold boot. The oscillator never started, so the display chip stayed dormant and the screen remained dark. On firmware 6.06 the same single `0x21` was delivered correctly and the panel lit up.

**Workaround:** Send the oscillator-enable command twice. The first write is sacrificial (absorbed by the firmware bug); the second is delivered to the controller.

```lisp
(i2c-tx-rx 0x70 (list 0x21)) ; sacrificial — absorbs the dropped first transaction
(i2c-tx-rx 0x70 (list 0x21)) ; real oscillator-enable, reaches the HT16K33
(i2c-tx-rx 0x70 (list 0x81)) ; display ON, blink off
```

This bug only affects the first transaction on a freshly muxed bus. Subsequent commands on the same bus configuration are delivered normally. The second display controller (`0x71` on CudaX) does not need the doubled command because by the time it is initialised the bus is already exercised by the `0x70` sequence.

## Battery Imbalance Detection

The runtime monitors the midpoint balance wire (ADC1, exposed as `(get-adc 0)`) and warns when one of the two series battery packs becomes significantly more depleted than the other. The detection logic is implemented in `blacktip_dpv.lisp` as a small set of helpers (`update_lower_voltage_smooth`, `update_imbalance_latch`, `get_battery_imbalance_warning`, `log_balance_voltages_throttled`) driven by a dedicated balance loop thread.

### Hardware Path

* The balance wire is brought out through a resistor divider (default 141k / 10k → 15.0x). With the stock ADC reference this gives a calibrated multiplier of **16.2x** (`ADC_BAL_MULT_X10_DEFAULT = 162`), measured empirically on a reference Blacktip.
* `get-adc 0` returns the raw pin voltage (0 – 3.3 V); the lower-pack voltage is `pin × multiplier`.
* The multiplier is user-tunable from the UI in 0.1x steps (`5.0` – `25.5x`) to compensate for resistor tolerances; the periodic balance log (see below) emits the running readings so the user can dial it in against a multimeter.

### At-Rest-Only Sampling

The midpoint balance-wire reading is **skewed HIGH under load**. The IR drop across the pack and wiring lifts the measured midpoint, so the lower-pack reading runs ~1.3 V above its true resting value while the motor is running (observed ~21.2 – 21.8 V under load vs a true resting ~19.9 V). This offset is a permanent property of running, not a transient that settles — confirmed by swapping the two batteries between slots and observing the skew stay in the SAME direction (lower-slot reads high) regardless of which physical battery is where.

Consequently, **live imbalance readings while running are meaningless** and must never be fed into the EMA. The runtime enforces this with two mechanisms:

1. **Hold while running.** `update_lower_voltage_smooth` evaluates "running" as `(commanded speed != OFF)` OR `(|measured duty| > DUTY_AT_REST_THRESHOLD)`. A `nil` duty (very early boot) is treated as running so the EMA cannot be poisoned with garbage. While running, the smoothing is held — the EMA retains its last good at-rest value.
2. **Post-stop settle window.** After the motor stops, the hold is extended for `BALANCE_SETTLE_SAMPLES` (32 samples × 0.25 s = 8 s) so the post-stop recovery transient is skipped. The settle counter is re-armed every iteration while running, so the quiet-down period only starts after the motor has actually been at rest.

At-rest readings feed an EMA with `alpha = 0.05` (~5 s time constant at the 4 Hz balance-loop rate). Both `lower_voltage_smooth` and `total_voltage_smooth` are tracked so the imbalance can be derived consistently from smoothed values, preventing motor sag (which hits `get-vin` instantly but `lower_voltage_smooth` only slowly) from flipping the sign or inflating the magnitude.

### Latch Hysteresis

Because the imbalance can only be measured reliably at rest, it is sampled on every stop and then **latched** (`battery_imbalance_latched`). Once a warning is detected, it keeps showing even if the user sets off again and stops once more — a depleting pack cannot be "driven away from" unnoticed.

The latch state machine in `update_imbalance_latch`:

* Acts only on a settled, at-rest reading (`balance_smoothing_held = 0` and the EMA initialised), so a load-corrupted or transient sample can never latch.
* **Set / refresh:** a settled reading over the warn threshold latches the warning. If the imbalance direction flips (e.g. `PACK_1` → `PACK_2`), the latch is updated.
* **Clear (hysteresis):** the latch only releases once a settled reading shows `|imbalance|` below `BATTERY_IMBALANCE_CLEAR_FRACTION` (currently `0.5`) of the warn threshold — i.e. the pack has actually been re-balanced or charged, not just nudged under the boundary. The gap between clear and warn thresholds also debounces the boundary.

Direction convention: `imbalance = upper_smooth − lower_smooth` (upper = slot 1 top pack, lower = slot 2 / ADC pack). Positive imbalance → slot 2 depleted → `BATTERY_IMBALANCE_WARN_PACK_2`. Negative imbalance → slot 1 depleted → `BATTERY_IMBALANCE_WARN_PACK_1`.

### Display Integration

The imbalance warning replaces only the `DISPLAY_SENTINEL` (idle) frame, so it appears AFTER any user-triggered frame (speed indicator, battery bar, smart-cruise bar) has completed its normal timer duration. The displayed warning comes from `battery_imbalance_latched`, NOT the live reading, so it persists across motor restarts.

* **At rest** (`speed = SPEED_OFF`): the warning is shown continuously.
* **While running:** the warning flashes on for `IMBALANCE_RUN_FLASH_ON` (1 s) out of every `IMBALANCE_RUN_FLASH_PERIOD` (5 s). This keeps reminding the rider mid-ride without permanently clobbering the smart-cruise timer bar / speed display.

The warning uses the `BATTERY_IMBALANCE_DISPLAY_PACK_1` and `BATTERY_IMBALANCE_DISPLAY_PACK_2` display identifiers. The `Display Battery 1 Low` and `Display Battery 2 Low` entries in `assets/display_lut.csv`, each with four rotation variants, provide the artwork. The CudaX timeout-recovery path also explicitly resets to the cached battery frame when one of these warning frames is currently shown, so the warning cannot persist past its window.

### SOC Correction

`calculate_corrected_battery` scales the raw battery percentage by `display_pack_voltage / total_voltage` (where `display_pack_voltage = 2 × lower_voltage_smooth`) when imbalance detection is active. The result is clamped to `[0.0, 1.0]`. This makes the displayed SOC, the bar graph, and the capacity beeps track the weaker pack rather than the pack average — so an imbalanced scooter does not over-report remaining capacity. When detection is disabled (`battery_imbalance_threshold_centi = 0`), the scaling is skipped and behaviour matches the pre-1.4.0 voltage-based calculation.

### Dedicated Thread

`start_balance_loop` runs `update_lower_voltage_smooth`, `update_imbalance_latch`, and `log_balance_voltages_throttled` at 4 Hz on a dedicated thread (`THREAD_STACK_BALANCE = 100` words). Keeping the balance work off the display thread isolates any fault in the balance code (or the periodic `puts` of a long log string) from the screen update loop. Each helper is invoked through `trap` so early-boot nils from `get-duty` / `get-adc` cannot kill the thread.

### Tuning Aid: Periodic Balance Log

`log_balance_voltages_throttled` emits a `Balance:` line every ~15 s when `debug_enabled = 1`, showing `total`, `upper(slot1)`, `lower(slot2)`, the active multiplier, and whether the EMA is currently held. The string is gated by the `when-debug` macro, so when debug is off there is no string-building work and no allocation. This is the primary tool for verifying or fine-tuning the balance-wire ADC multiplier in the field.

### EEPROM Schema (v3)

The v2 balance-detection feature added slots 30 and 31 and raised `EEPROM_SETTINGS_COUNT` from 30 to 32. Schema v3 adds the opt-in shutdown setting in slot 32 and raises the count to 33. The migrations in `eeprom_set_defaults` remain layered on the existing v1 (1.0.0) baseline:

| Slot | Setting | Default | Notes |
|------|---------|---------|-------|
| 30 | `battery_imbalance_threshold_centi` | `200` | Threshold in 0.01 V units (200 = 2.00 V). `0` disables imbalance detection entirely. |
| 31 | `adc_balance_wire_multiplier_x10` | `162` (`ADC_BAL_MULT_X10_DEFAULT`) | Balance-wire multiplier × 10 (162 = 16.2x). Bounded `ADC_BAL_MULT_X10_MIN..MAX` (`50..255`, i.e. 5.0x – 25.5x). |
| 32 | `enable_five_click_shutdown` | `0` | Opt-in MK5 hardware shutdown. Only `1` enables it; runtime hardware, firmware and stopped-state guards remain authoritative. |
| 127 | Schema version marker | `3` | Advanced once at the end of the migration so each block is idempotent. |

The migration uses `(< stored_version N)` rather than `(not-eq stored_version N)` so that older blocks do not re-fire after a later block has run. A fresh install on a Poseidon-era device (marker `150` in slot 127) is collapsed to `0` so the 1.0.0 block adds slots 25 – 29 without overwriting the user's existing slots 0 – 24, the 1.1.0 block adds slots 30 – 31, and the v3 block initializes only slot 32 before advancing the marker to `3`.

Current settings messages are 33 bytes. On upgrade, the v3 migration writes only the new slot 32 default and preserves all settings known to the previous schema. The UI write and both reset-default paths send 33 bytes and explicitly include slot 32.

## Five-click Deep Shutdown

The feature decision is isolated in `five_click_shutdown_rejection_reason`. It requires the persisted opt-in, actual `(sysinfo 'hw-name)` equal to `60_MK5`, supported firmware, and commanded speed off. `request_five_click_shutdown` then runs the short confirmation sequence before calling `(shutdown true)`. Prop coast-down is effectively instantaneous once the motor is off, so RPM/duty telemetry and a delayed second validation stage are unnecessary.

Firmware exposes its beta/test build number as the third member of `(sysinfo 'fw-ver)` and as `isTestFw` in `FwRxParams`. Zero denotes a stable release, so stable 7.00 is `(7 0 0)` and is supported; `(7 0 2)` denotes 7.00 beta 2. Beta 1 is rejected, while beta 2+, stable 7.00, and later releases are accepted. There is no separate safe LispBM extension-introspection API on the older builds, so version gating is used for feature detection. The backend check is independent of QML, so a manually written or corrupted enabled setting cannot bypass it.

Before calling the VESC hardware shutdown path, the request selects the existing `DISPLAY_OFF` power-symbol frame, allows the 4 Hz display loop to render it, and plays four descending tones (700, 575, 450 and 325 Hz) at the configured beep volume. This gives a clear acknowledgement of an accidental as well as an intentional five-click command; when volume is zero, the display remains the confirmation. Success does not return. A returned `nil` is logged as failure/unsupported/held input and is not retried. This feature does not use `shutdown-hold`, alter `OFF_AFTER`, or add another idle timer.

## Performance Log (on-device)

Status: specification. Nothing in this section is implemented yet; it is the contract that the sampler, the storage writer, the extraction opcodes and the host tooling are built against. A change that departs from it must update this section in the same commit.

The log is an opt-in, off-by-default record of aggregate performance statistics (how hard the drive is worked at each speed setting, supply sag, saturation, faults) kept on the controller, so that owners can see how the scooter behaves with their own battery packs. Blacktip is the validation target. Nothing in the layout is Blacktip-specific (the speed indices and getters are common to both scooter types), so CudaX support is not precluded, but it is not designed for or validated here.

### Safety statement

The logging-only phase changes no motor-control behaviour and no configuration:

* It never calls `set-duty`, `set-rpm`, `set-current`, `conf-set` or any other actuator, and it does not alter any existing global used by the motor, state-machine or display paths.
* It reads telemetry through getters only. The single touch point in existing code is one RAM-only counter increment inside `safe_start_abort_with_reason`; it adds no EEPROM write and no control-flow change.
* It writes only EEPROM slots 64 to 126. Settings slots 0 to 32, the free slots 33 to 63, the schema marker in slot 127 and `EEPROM_SETTINGS_COUNT` are untouched, and the settings migration is unchanged.
* While the log is disabled (the default) it performs no EEPROM writes at all.
* The only motor-visible effect of an enabled log is the controller-side behaviour of an EEPROM write (see [Flash write behaviour](#flash-write-behaviour)). Writes happen only under the [flush gate](#flush-gate), which requires the motor to be at rest.

### Storage

* Storage is the LispBM emulated EEPROM only. The ESC has no file system or SD card, and the Blacktip Bluetooth add-on is a Flipsky NRF module, not a VESC Express, so there is no other persistent store the package can use.
* Reserved range: slots 64 to 126 (63 slots of 32 bits, 252 bytes). Slots 33 to 63 stay free for future settings (the test-fixture branch already uses 33 to 35). Slot 127 is the settings schema marker and is not touched.
* The vendored bldc 7.00 source defines `EEPROM_VARS_CUSTOM` as 256, so slots above 127 exist, but the package supports firmware 7.00 only and deliberately stays below 127.
* The log has its own header (magic and layout version) and is independent of the settings schema version. The settings paths (UI write, both reset-default paths, migrations) loop over slots `0..EEPROM_SETTINGS_COUNT-1` only and must never be extended to touch 64 to 126. In particular, Reset Defaults does not clear the log.
* The vendored LispBM documentation states that the emulated EEPROM survives power cycles and configuration changes, but not firmware updates. Uploading a new package does not clear it. The log is lost on a firmware update, so export it first.
* Ownership of the range: the log owns 64 to 126 by contract. If the header magic is absent (slot 66 never written), the range is "empty". If the magic is present but differs from the expected value, the range holds foreign data (for example leftovers from a bench probe); it is reported as such, never overwritten implicitly, and is claimed only by an explicit `clear-log` or by `set-enabled` followed by an initial clear. A known magic with an unknown layout version is reported and left untouched.

### Encodings and number handling

Every slot value is a non-negative 31-bit integer (bit 31 is always 0). This removes every sign problem: `eeprom-read-i` returns an i32, `eeprom-store-i` takes an i32, and a value below 2^31 never goes negative through packing, shifting or masking. Three slot types are used:

* **U31**: one value, 0 to 2147483647 (`0x7FFFFFFF`).
* **P15(A, B)**: two fields packed as `A × 32768 + B`, each 0 to 32767 (A in bits 15 to 29, B in bits 0 to 14; bits 30 and 31 are 0). Pack with `(bitwise-or (shl a 15) b)` after clamping both fields to 0..32767. Unpack with `(bitwise-and (shr v 15) 0x7FFF)` and `(bitwise-and v 0x7FFF)`. Because `v` is non-negative the arithmetic and logical shifts agree.
* **CHECK**: the CRC slot (see [Integrity](#commit-protocol-and-integrity)) holds the CRC32 masked to its low 31 bits.

Rules:

* **Saturate, never wrap.** Every counter, integral and field is added with `min(max_value, old + delta)`. A saturated value stays at the maximum and is reported as saturated by the host (value equals the maximum). `commit_seq` is the one exception: it is not a statistic, and it advances modulo 2^31, which preserves parity because 2^31 is even.
* **Deltas are non-negative.** Negative or non-finite (`nil`, NaN) readings are skipped for that sample, never added.
* **Lifetime values are integers.** A 32-bit float has a 24-bit mantissa and cannot hold increments once a total exceeds about 16.7 million. Lifetime totals therefore live in integer RAM mirror slots. Only the small per-flush deltas ("pending") are floating point, and a flush folds them in as `n = floor(pending)`, `stored = min(max, stored + n)`, `pending = pending - n`, carrying the fraction so that rounding never loses time.
* **Instantaneous values** (temperature, supply voltage) are rounded half up: `floor(x + 0.5)`.
* **Offset-binary temperature**: `encoded = clamp(floor(T × 10 + 0.5) + 1000, 0, 32767)` in 0.1 °C units, so the range is -100.0 °C to 2276.7 °C and 0 means "no sample".
* **Minimum supply voltage** is in 0.01 V units; 32767 means "no sample yet". Minima are initialised to that sentinel by the initial clear.
* The raw slot values are what the export carries (see [Export format](#export-format)); decoding is repeated on the host so a decoder bug can be fixed without losing data.

### Units and getters

| Quantity | Getter | Unit |
|---|---|---|
| eRPM | `(get-rpm)`, `(get-rpm-set)` | electrical RPM; negative is reverse; `get-rpm-set` is the PID speed setpoint |
| Duty | `(get-duty)` | -1.0 to 1.0 |
| Motor current | `(get-current)` | A; sign indicates direction |
| Input current | `(get-current-in)` | A; positive when drawing from the battery |
| Supply voltage | `(get-vin)` | V |
| Temperatures | `(get-temp-fet)`, `(get-temp-mot)` | °C (hottest MOSFET sensor, motor sensor) |
| Charge and energy | `(get-ah)`, `(get-wh)` | amp hours and watt hours consumed since controller start (RAM counters; a reset makes the value drop) |
| Fault | `(get-fault)` | `mc_fault_code` number, 0 is none |
| Input current limit | `(conf-get 'l-in-current-max)` | A, the configured limit currently in force |

The package already reads `get-rpm`, `get-duty` and `get-current` in the safe-start path, so they are safe to call from another thread at this rate. If a reading is `nil` or NaN the sample skips that metric.

The package limits are `MAX_CURRENT_BLACKTIP` 22.8 A and `MAX_CURRENT_CUDAX` 46 A. During the first part of a start (`SOFT_START_DURATION`, 0.5 s) the package lowers `l-in-current-max` to `MIN_CURRENT_BLACKTIP` (1.7 A) or `MIN_CURRENT_CUDAX` (0.35 A) and then raises it to the maximum, so samples taken while `soft_start_active` is 1 are excluded from the limit and tracking metrics (below). The configured limit is not thermally derated, so "time at limit" means the configured limit, not the effective limit.

### Speed indices

The package uses 10 speed indices, 0 to 9 (verified in `speed_set` and `update_settings_from_eeprom`): index 0 is reverse 2, index 1 is untangle (reverse 1), and indices 2 to 9 are the user speeds 1 to 8 (the UI adds 1 to convert a user speed to an index). `SPEED_OFF` is 99 and is never an index. The sampler attributes a sample to `speed` when it lies in 0..9 and ignores any other value.

### Slot map

Header and integrity first, then data. Slots 66 to 126 (61 slots, 244 bytes) are the CRC-covered image. "ds" is a decisecond (0.1 s).

| Slot | Name | Type | Unit and notes |
|---|---|---|---|
| 64 | `commit_seq` | U31 | Odd while a flush is in progress, even when committed. Not CRC-covered. |
| 65 | `crc` | CHECK | `crc32(slots 66..126) & 0x7FFFFFFF`. Not CRC-covered. |
| 66 | `magic` | U31 | `0x42544C47` ("BTLG"), decimal 1112820807. |
| 67 | `layout_flags` | U31 | Bit 0: logging enabled. Bits 8 to 15: layout version (1). Other bits 0. Enabled v1 is 257, disabled is 256. |
| 68 | `sessions` | U31 | Sessions with motor use (a session is one controller start in which `speed` left `SPEED_OFF` at least once). |
| 69 | `motor_starts` | U31 | `SPEED_OFF` to not-off transitions seen by the sampler (a lower bound, see [Sampling](#sampling)). |
| 70 | `abort_invalid_telemetry`, `abort_timeout` | P15(A, B) | Safe-start aborts, one count per call of `safe_start_abort_with_reason` with that reason. |
| 71 | `abort_high_current_stall`, `stops_retries_exhausted` | P15(A, B) | The second field counts aborts that exhausted `SAFE_START_MAX_RETRIES` and stopped the motor. |
| 72 | `motor_on` | U31 | ds with `speed != SPEED_OFF`. |
| 73 | `mah_used` | U31 | mAh (`get-ah` × 1000). |
| 74 | `wh_used_x10` | U31 | Wh × 10 (`get-wh` × 10). |
| 75 | `max_fet_temp`, `max_motor_temp` | P15(A, B) | Offset-binary 0.1 °C, running samples. |
| 76 | `max_motor_current`, `max_input_current` | P15(A, B) | 0.1 A, absolute value, running samples. |
| 77 | `max_abs_erpm`, `min_vin_running` | P15(A, B) | A: eRPM (saturates at 32767). B: 0.01 V, 32767 means none. |
| 78 to 107 | per-speed index blocks | U31 × 3 each | Index `i` uses slots `78 + 3i` (`on`), `79 + 3i` (`cur`), `80 + 3i` (`def`). See below. |
| 108 to 112 | `at_limit` | P15(A, B) | Seconds at the input current limit. Slot `108 + floor(i / 2)`; A holds even index `i`, B holds odd index `i`. |
| 113 | `duty_ge_095` | U31 | Total ds with `\|duty\| >= 0.95`, across all speed indices. |
| 114 | `duty_090_095` | U31 | Total ds with `0.90 <= \|duty\| < 0.95`. |
| 115 | `duty_080_090` | U31 | Total ds with `0.80 <= \|duty\| < 0.90`. |
| 116 | `fault_1`, `fault_2` | P15(A, B) | Event counts, fault codes 1 and 2. |
| 117 | `fault_3`, `fault_4` | P15(A, B) | |
| 118 | `fault_5`, `fault_6` | P15(A, B) | |
| 119 | `fault_7`, `fault_8` | P15(A, B) | |
| 120 | `fault_9`, `fault_10` | P15(A, B) | |
| 121 | `fault_other`, `integrity_events` | P15(A, B) | A: fault codes 11 and above, combined. B: loads that found an unverified image (below). |
| 122 | `last_motor_on` | U31 | Last-session motor-on ds. |
| 123 | `last_ah`, `last_wh` | P15(A, B) | A: mAh (saturates at 32.767 Ah). B: Wh × 10 (saturates at 3276.7 Wh). |
| 124 | `last_max_fet_temp`, `last_min_vin` | P15(A, B) | Offset-binary 0.1 °C; 0.01 V (32767 means none). |
| 125 | `last_max_input_current`, `last_max_erpm` | P15(A, B) | 0.1 A; eRPM. |
| 126 | `longest_write_ms`, `aborted_flushes` | P15(A, B) | Flush diagnostics: longest single `eeprom-store-i` in ms, and flushes aborted by the re-checks. |

The fault codes are the vendored 7.00 `mc_fault_code` numbers: 1 over-voltage, 2 under-voltage, 3 DRV, 4 absolute over-current, 5 FET over-temperature, 6 motor over-temperature, 7 gate-driver over-voltage, 8 gate-driver under-voltage, 9 MCU under-voltage, 10 booting from watchdog reset. Codes 11 and above (encoders, resolver, flash, and so on) are summed in `fault_other`.

#### Per-speed index blocks

For each index `i` the three U31 slots hold:

* `on`: ds spent at that index (steady running samples, see [Sampling](#sampling)).
* `cur`: the integral of positive input current, in 0.01 A·s. Mean input current in A is `cur / (10 × on)`.
* `def`: the integral of the RPM tracking deficit, in eRPM·s, where the deficit is `max(0, |get-rpm-set| - |get-rpm|)`. Mean deficit in eRPM is `10 × def / on`.

The time at the input current limit is in `at_limit` as whole seconds (saturating at 32767 s, about 9.1 hours per index).

#### How the slots are used after the duty change

The duty-saturation time (`|duty| >= 0.95`, the voltage-headroom failure signature) is one total counter across all speed indices, in slot 113, instead of one counter per index. That freed slots that would otherwise have held nine more per-index duty counters. They are used as follows:

* Slots 114 and 115 are two coarse total duty bands (0.90 to 0.95, 0.80 to 0.90) that show how close to the headroom limit a pack and setup operate before it saturates. They are totals, not per index.
* Slot 126 holds flush diagnostics (longest write time, aborted flushes). They turn the unmeasured MK5 write timing and the unobserved erase-stall question into data collected in the field.
* Slot 121 field B counts integrity events, so a damaged image is recorded rather than silently repaired.
* Slots 116 to 120 give individual counters for fault codes 1 to 10 (including watchdog resets), with the rest combined.

Nothing was dropped from the required list. Packing: all counters that are small by nature (safe-start aborts, faults, extremes, last-session values, time at limit) are P15 pairs, and the time-at-limit seconds saturate at about 9.1 hours per index. There are no reserved slots left in 64 to 126; a later layout version that needs more room must re-pack rather than extend the range.

### Sampling

* One dedicated thread samples and also performs flushes, so there is exactly one writer of slots 64 to 126 and no race between accumulation and a flush. The thread is started only when logging is enabled. LispBM has no thread priorities: "low priority" means it sleeps 0.2 s between iterations (about 5 Hz, `LOG_SAMPLE_PERIOD`), does a fixed small amount of work per iteration, and yields. A flush pauses sampling, which is acceptable because flushes happen only at rest.
* The thread calls read-only getters only, each inside `trap` (the idiom used by the balance thread), so early-boot `nil` results cannot kill it.
* State lives in preallocated byte arrays created before the loop starts: a mirror of the 63 slots (252 bytes, accessed with `bufget-u32` and `bufset-u32`) and a float buffer for the per-flush pending deltas (`bufget-f32` and `bufset-f32`). The loop creates no arrays or lists. LispBM boxes large integers and floats, so transient values from arithmetic are unavoidable; they are reclaimed by the garbage collector and an implementation must show no heap growth in a long soak.
* The elapsed time of a sample is measured (`secs-since` the previous sample) and clamped to 0.5 s (`LOG_DT_MAX`), so a starved thread or a flush never credits a long time to one reading.
* The event-data handler never writes the log. It posts a request into one RAM mailbox that the sampler thread executes, and a second request while one is pending is answered "busy".

Predicates evaluated per sample:

* `running`: `speed != SPEED_OFF`.
* `steady`: `running` and `soft_start_active = 0`.

Per sample (`dt` is the clamped elapsed time):

| Update | Condition |
|---|---|
| Lifetime and session `motor_on` += `dt × 10` | `running` |
| `max_fet_temp`, `max_motor_temp`, `max_motor_current`, `max_input_current`, `max_abs_erpm`, `min_vin_running`, and the matching last-session values | `running` |
| `on[speed]` += `dt × 10` | `steady` |
| `cur[speed]` += `max(0, i_in) × dt × 100` | `steady` |
| `def[speed]` += `max(0, \|rpm_set\| - \|rpm\|) × dt` | `steady` |
| `at_limit[speed]` += `dt` | `steady` and `limit > 0` and `i_in >= 0.95 × limit` (`LOG_LIMIT_FRACTION`) |
| `duty_ge_095` += `dt × 10` | `steady` and `\|duty\| >= 0.95` (`LOG_DUTY_SATURATED`) |
| `duty_090_095`, `duty_080_090` += `dt × 10` | `steady` and the duty is in that band |
| `mah_used` += `Δget-ah × 1000`, `wh_used_x10` += `Δget-wh × 10` | Always, as a delta against the previous sample. A negative delta (counter reset) is discarded and the baseline re-taken. |
| `motor_starts` += 1 | `speed` changed from `SPEED_OFF` to another value since the previous sample |
| `sessions` += 1 and the last-session slots reset | The first `running` sample after controller start |
| `fault_c` += 1 | `get-fault` returned code `c != 0` and `c` differs from the previous sample's code |
| `abort_*` += 1 and `stops_retries_exhausted` += 1 | Incremented by the single hook in `safe_start_abort_with_reason`, which sets a RAM counter the sampler folds in |

Notes and limits of the method:

* At 5 Hz the sampler can miss anything shorter than 0.2 s: very short faults, brief maxima, and a start and stop inside one period. The maxima, fault counts and `motor_starts` are therefore lower bounds. The fault counters count events, not duration.
* The tracking deficit includes the transient after a speed change, when the setpoint steps and the speed follows; it is a mean over everything at that index, not a steady-state figure.
* The accumulators only credit running time while the sampler runs. A reset or power loss between flushes loses the unflushed part.
* "Dirty" means a running sample, start, abort or fault has changed a stored slot or pending delta since the last flush. Ah and Wh drift while the scooter idles is carried into the next flush but does not by itself make the log dirty.

### Commit protocol and integrity

The writer does the following, only after the [flush gate](#flush-gate) has passed:

1. Fold the pending deltas into the mirror (saturating, carrying fractions), compute `crc` over the mirror image of slots 66 to 126, and write `commit_seq = seq + 1` (odd, "in progress") to slot 64.
2. Write each changed data slot (66 to 126) with `eeprom-store-i`, only if it differs from the stored value. Read each slot back and compare; on a mismatch, abort. Between slot writes, re-check the gate (see [Flush gate](#flush-gate)) and yield for at least 1 ms so other threads run.
3. Write `crc` to slot 65, then read it back.
4. Write `commit_seq = seq + 2` (even, committed) to slot 64.

If the flush aborts at any point, `commit_seq` stays odd until a later flush commits. The reader reports that state; it is accurate (the stored image has not been verified).

**CRC definition.** The CRC covers the 61 slots 66 to 126 in ascending slot order. Each slot contributes four bytes, its non-negative 31-bit value as an unsigned 32-bit integer in big-endian order (most significant byte first, so the first byte of every slot is below `0x80`). That is exactly what `(bufset-u32 buf offset value)` writes by default (the vendored LispBM documentation states that multi-byte `bufset` variants default to big-endian), so the byte array to checksum is the RAM mirror with its first two slots (64 and 65) left out. The CRC is the standard CRC-32 (polynomial `0x04C11DB7`, reflected form `0xEDB88320`, final XOR `0xFFFFFFFF`) with `crc32` called with `init = 0`.

**`crc32` builtin semantics** (vendored bldc `release_7_00` and its LispBM documentation, firmware 6.05 and newer):

* Form: `(crc32 array init optLen)`. The first argument must be a byte array and the second a number, otherwise a type error is returned. `optLen` limits the number of bytes used and is clamped to the array size.
* `crc32_with_init(buf, len, init)` inverts `init` on entry and inverts the result on exit, so `init = 0` yields the standard CRC-32 and `(crc32 b (crc32 a 0))` equals the CRC of `a` followed by `b`. The writer may therefore checksum slot by slot or in one call.
* The result is an unsigned 32-bit value. Store `(bitwise-and crc 0x7FFFFFFF)` in slot 65 and compare against the masked value, so the stored check is always non-negative. Masking drops one bit of CRC strength, which is acceptable for a torn-write check.
* The standard check value is `crc32("123456789") = 0xCBF43926`; use it to confirm the builtin on the target.

**Reader states.** A reader (the package at start, the host on export) classifies the stored image:

| State | Condition |
|---|---|
| `empty` | Slot 66 reads `nil` (never written). |
| `foreign` | Slot 66 is present and not the magic. |
| `unknown_layout` | Magic matches, layout version is not 1. |
| `in_progress` | `commit_seq` is odd. |
| `crc_mismatch` | `commit_seq` is even and the recomputed masked CRC differs from slot 65. |
| `ok` | `commit_seq` is even and the CRC matches. |

`in_progress` and `crc_mismatch` are reported as "torn or unverified". The reader never silently discards or resets the data. At start the package loads the values it finds into the mirror, increments `integrity_events` in its next flush (so the event is recorded in the log itself), and carries on. The raw slots are always exported so an analyst can inspect a damaged image.

**Cost and risk assessment (why there is no double buffering).** A torn log needs a power loss in the few milliseconds of a flush. The package writes only at rest, and a flush runs at most every 60 seconds and takes tens of milliseconds (about 0.05 % of at-rest time at most, taking 32 ms per 60 s), so the exposure is very small. A power loss inside that window would need the supply to disappear within seconds of the trigger being released: a broken supply connection, or removal of the battery. The battery cover is normally in place and removing it takes about a minute, and even with it off a user needs a few seconds from releasing the trigger to power off. This is considered extremely unlikely, and the consequence is bounded (see the measurements below: only the slot in flight was damaged, the damage is detected by the CRC, and the settings were never affected). The design therefore keeps the cheap integrity check (an odd/even sequence and a CRC, plus a read-back) and adds no costly mitigation: no double-buffered banks and no extra copies.

Bench findings that support this (HW 60 non-MK5 test controller, no Bluetooth, firmware 7.0.0 `release_7_00`, git `1fee61fb7ebc79745a359a0ee0c056cfce39a043`; bench measurements, 4 Nov 2026; see the table in [Measured behaviour](#measured-behaviour)): power was cut 17 times while 60 slots were rewritten back to back at 5 ms pacing; 3 of the 17 cuts tore the slot being written (new high 16 bits, old low 16 bits); no slot other than the one in flight was ever damaged, the EEPROM stayed readable after every cut, and settings 0 to 35 and slot 127 were unchanged in every case. A real flush is far shorter and rarer than that test.

### Flash write behaviour

Facts from the vendored 7.00 source at the bench firmware's git hash (source reading, not hardware tests):

* `eeprom-store-i` writes the value as two 16-bit halves, high half first, each as a 4-byte record (16-bit data plus 16-bit address) appended to the active 16 KiB page. `EE_WriteVariable` first reads the old half and returns without programming if it already equals the new value, so a store whose high half is unchanged programs only one record.
* Before programming, the controller calls `mc_interface_ignore_input_both(5000)` and `mc_interface_release_motor_override_both()`, then waits up to 3.0 s for the motor to reach the off state. Release sets the FOC control mode to current control at zero current. After programming it calls `mc_interface_ignore_input_both(100)`. While the ignore counter is non-zero, motor commands such as `set-duty` and `set-rpm` are dropped, not queued.
* If the motor does not reach the off state within 3.0 s, `store_eeprom_var` executes `return 100` in a function returning `bool`, which is true: `eeprom-store-i` then returns `t` although nothing was written. This is why the writer reads every slot back.
* A page holds fewer than 4096 records. When it is full, the next write triggers a page transfer: the live variables are copied to the other page and the old 16 KiB sector is erased. The emulated EEPROM also stores the VESC motor and app configuration (`NB_OF_VAR` includes them), so a page transfer is shared with those variables, and the log's flushes make page fills more frequent than they were before.
* The flash datasheet (STM32F405/407, Doc ID 022152 Rev 2) lists a 16 KB sector erase at 250 ms typical and 500 ms maximum at x32 programming parallelism (300 and 600 ms at x16), and a minimum endurance of 10 000 erase cycles per sector. The parallelism used by the firmware has not been checked, so the planning bound is 600 ms.
* The existing helper `eeprom_store_i_if_changed` returns `nil` when the value is unchanged, so its result cannot distinguish "unchanged" from "failed". The log writer needs its own helper that reports unchanged and stored as success and a failed store or read-back as failure.
* Assumed, not verified: while a store runs, no LispBM thread executes, and during a sector erase the controller can stall for the full erase time. These assumptions are why writes must never happen while running.

An estimate of wear (inputs unverified: the live-variable count that consumes part of each page, and the real flush rate): a flush programs at most 128 records. At the minimum interval of 60 s with every slot changing at every flush, a page fills every few tens of flushes; with two 16 KiB sectors alternating at 10 000 cycles each this is about 5000 hours of non-stop worst-case activity. Realistic use is orders of magnitude lower, because a flush happens only after running activity and an at-rest settle.

### Flush gate

A flush starts only when all of the following hold, and `LOG_*` names are the constants the implementation should define (values are initial and will be tuned after MK5 measurement):

1. Logging is enabled.
2. `speed == SPEED_OFF` continuously for `LOG_SETTLE_S` (10 s). The timer restarts whenever any condition below fails at a sample.
3. At every sample of that period: `|get-rpm| < LOG_REST_ERPM_MAX` (25.0 eRPM) and `|get-duty| < LOG_REST_DUTY_MAX` (0.02, the existing `DUTY_AT_REST_THRESHOLD`). A `nil` or NaN reading counts as not at rest, consistent with the battery-imbalance gating.
4. The trigger is not pressed: read `(gpio-read 'pin-ppm)` directly (1 is pressed) rather than the 25 Hz `sw_pressed` copy.
5. `startup_tune_active` is 0. The other beeper paths (battery indication, click tones, the abort tone and the five-click confirmation) also use `foc-beep` or `foc-play-tone` on the FOC path; if the implementation can detect them cheaply it defers while one is active. Otherwise the settle period and "speed off" are the protection (a write racing a tone is expected to cut it short; this is an inference, not tested).
6. The log is dirty.
7. At least `LOG_MIN_FLUSH_INTERVAL_S` (60 s) have passed since the previous flush completed.

**Re-checks during the flush.** Before each slot write, read the trigger pin directly and `speed` again. If the trigger is pressed or `speed != SPEED_OFF`, stop immediately, leave `commit_seq` odd, increment `aborted_flushes` in the mirror (it is written by the next flush), and do not retry until the whole gate passes again. Yield for at least 1 ms between writes so the GPIO and state-machine threads can run; a burst with no yield cannot see a press (the bench burst of 60 writes took about 28 ms). At the start of a flush the at-rest thresholds are checked once more; they are not checked between writes, because the controller-side release and zero current cover that window.

**At-rest thresholds (to be confirmed on the MK5 DPV).** The bench probe used `|rpm| < 5.0` and `|duty| < 0.005`, and that guard aborted the run in nine of about ten sessions; the cause is unresolved (noise, supply droop while power was failing, or the printed readings being a second read). The readings it printed were as large as |rpm| 3.36 and |duty| 0.0075, while readings that passed were at most |rpm| 1.53 and |duty| 0.0028. The probe thresholds were therefore within about 1.5 times of the noise, so they are not reused. The flush gate uses a duty limit of 0.02, the value the package already uses for at-rest detection in the battery-imbalance feature, which is more than 2.5 times the largest recorded reading, and an eRPM limit of 25, which is more than 7 times the largest recorded reading and far below `SAFE_START_MIN_RPM` (350). The settle period is continuous, so a threshold set too tight only delays the flush; it can never write while moving. Whether a prop or motor was attached during the bench readings was not recorded, so these thresholds are a reasoned choice, not a measurement, and must be confirmed on the MK5 DPV.

**Shutdown paths.** The package has no idle power-off timer of its own (the controller's own idle shutdown is outside it and gives no warning), so the idle case is covered by the settle and interval rules above. For the deliberate five-click shutdown, `request_five_click_shutdown` makes one flush attempt after the confirmation tones and just before the `(shutdown true)` call, only if the motor is already at rest (`speed == SPEED_OFF` and conditions 1, 3, 4, 5 and 6). The settle period and minimum interval are waived (the user has just asked to power off, and `five_click_shutdown_rejection_reason` already requires `speed == SPEED_OFF`). A refused, failed or aborted flush never blocks the shutdown. The last ride's data is lost if the supply is removed before the next successful flush (up to the settle period plus the minimum interval); users who want it recorded should wait about 15 seconds at rest, or use the five-click shutdown.

**Worst-case latency.** The sampler flushes only at rest, so a rider normally never sees a flush. For a press during a flush:

* Number of stores: a full image is 61 data slots plus `commit_seq` twice and `crc`, at most 64 stores (the first flush after an initial clear); a typical flush after a ride changes about 25 to 35 slots.
* Per-store time on the bench (see below): 0.1 to 0.3 ms (0.175 ms average over 20 writes) when single, about 0.47 ms in a 60-write burst, about 0.54 ms per write including loop overhead, and 2.5 ms for the slowest of 8400 writes. At 0.2 to 0.5 ms per store a full 64-store flush takes about 13 to 32 ms; at 2.5 ms for every store it would take 160 ms, which is a pessimistic bound for what was observed. With the 1 ms yield between writes add about 64 ms.
* The abort check runs before each write, so a press stops the flush after the store in flight. The controller then ignores motor commands for about 100 ms. The earliest motor command after a press comes from the state machine after `TIMER_CLICK_WINDOW` (0.3 s), so for stores in the observed range the added start delay is hidden by the click window and is expected to be zero.
* If a page transfer were to stall a store for the datasheet bound (600 ms, never observed), the start could be late by up to about 0.4 s, and a motor command issued inside the 100 ms ignore window would be dropped and fall back on the package's existing safe-start timeout and retry handling. The accepted tolerance is about a second.
* No end-to-end start latency has been measured; the figures above are derived from the per-write measurements and the source. Measure it on the MK5 DPV before release.

### Measured behaviour

Rig: HW 60 non-MK5 test controller, no Bluetooth, firmware 7.0.0 (`release_7_00`, git `1fee61fb7ebc79745a359a0ee0c056cfce39a043`). Bench measurements, 4 Nov 2026. Not yet measured on the HW 60 MK5 DPV. The measurement script and the full record are in `tools/nv_write_probe.lisp` and `tools/nv_write_probe_results.md`.

| Item | Result |
|---|---|
| Single write, 20 writes to one slot | 0.1 to 0.3 ms each, average 0.175 ms |
| Burst of 60 writes | 27.7 to 28.4 ms total (about 0.47 ms per write) |
| Slowest write per burst | 0.5 to 0.6 ms, except one burst at 2.1 ms |
| Long run of 8400 timed writes | Slowest 2.5 ms (then 2.4 and 2.4 ms); none over 20 ms; 0 store failures; average about 0.54 ms per write including loop overhead; elapsed 4.544 s |
| Page transfer | None observed. The earlier estimate of one within about 4095 writes was not supported, cause unknown. Treat a stall of up to the datasheet maximum as possible but unobserved. |
| Unused slots | Slots 36 to 126 read `nil` before probing; settings 0 to 35 (checksum 17532) and slot 127 (value 6) unchanged through all writes and power cuts |
| Power cuts | 17 genuine cuts (1 in one session, 16 in another, 5 ms pacing). 3 tore a 32-bit slot: new high 16 bits with old low 16 bits (raw 577 at slot 113, raw 130630 at slot 94, raw 130652 at slot 116). Only the slot in flight was damaged. The EEPROM stayed readable after every cut. Small sample; the rate is not generalised. |
| MK5 | Not measured |

Unverified design option, not relied on: because the high half is written first and a half whose value is unchanged is not programmed, a stored value whose high half never changes would need only one 16-bit record per store, so a power loss could not leave two mismatched halves. This comes from source reading and is untested on hardware.

### Extraction

The log is read and managed over the existing `event-data-rx` channel (`send-data` in the other direction). The current protocol uses `HANDSHAKE_CODE` (255) as a single byte and treats every other message as a settings write of at least `EEPROM_SETTINGS_COUNT` bytes (33 today, 36 on the test-fixture branch; 30 in the first release), logging and dropping anything shorter. The new messages use that gap.

* Opcodes are the first byte of a request: `0xA1` read-log, `0xA2` clear-log, `0xA3` set-enabled. They are distinct from `HANDSHAKE_CODE` and from every valid settings byte 0 (reverse speed is 20 to 50).
* A request is recognised as an opcode only when its length is at most 8 bytes (they are 2 or 3 bytes), always far below the smallest settings write ever shipped, so an older package ignores them (it logs "buffer too small") and can never mistake them for a settings write.
* Requests:

  | Opcode | Bytes | Meaning |
  |---|---|---|
  | `0xA1` | `[A1, req_id]` | Read the stored image (and status flags). |
  | `0xA2` | `[A2, C5, req_id]` | Clear: reinitialise slots 64 to 126 (header, zeroed data, minima at their sentinel), keep the enabled flag. `C5` is a confirmation byte. |
  | `0xA3` | `[A3, value, req_id]` | Set enabled: `value` 0 or 1. Enabling an `empty` or `foreign` range first performs a clear. |

* `req_id` is a host-chosen byte echoed in every response; the host ignores responses with another id. A new read-log abandons any earlier stream.
* Response chunk, tag `0xB1`, at most 30 bytes in total: `[B1, req_id, kind, flags, chunk_index, chunk_count, payload...]`.
  * `kind` 0x01 is a data chunk. The payload is up to six stored slot values as big-endian 32-bit integers, starting at slot `64 + 6 × chunk_index`. A full read is 11 chunks (the last holds three slots, slots 124 to 126). A slot that reads `nil` is sent as `0xFFFFFFFF`, which is never a valid value. The slots are what is stored, not what is pending in RAM.
  * `kind` 0x02 is a command result with one payload byte: 0 ok, 1 not at rest, 2 store or read-back failed, 3 bad argument, 4 busy. `chunk_index` is 0 and `chunk_count` is 1.
  * `flags`: bit 0 logging is enabled, bit 1 unflushed (dirty) data is pending in RAM, bit 2 a flush is in progress, bit 3 the image loaded at start was unverified.
* Chunks of 30 bytes or fewer are deliberate. The ceiling for a chunk is 128 bytes per `send-data`, but the existing settings UI (`onCustomAppDataReceived` in `ui.qml`) treats any incoming payload of 31 bytes or more as a settings message and applies it to the controls, and ignores shorter ones with a console warning. A chunk kept at 30 bytes or fewer cannot be mistaken for settings by the unmodified UI. The extraction work should also make that handler ignore payloads whose first byte is `0xB1`.
* Chunks are paced (initially 10 ms apart, to be confirmed on a Bluetooth link) so the comm buffers are not overrun.
* `read-log` is read-only and allowed at any time, including while running. It reads flash and does not release the motor. A read that overlaps a flush returns a coherent but `in_progress` image.
* `clear-log` and `set-enabled` write EEPROM, so they run only at rest: `speed == SPEED_OFF` and conditions 3, 4 and 5 of the flush gate, with no settle period, no dirty requirement and no minimum interval. Otherwise the result is 1 (not at rest), nothing is written, and the host may retry. They are executed by the sampler thread through the mailbox, so the single-writer rule holds.
* The package never sends the log unprompted.

### Export format

The host tool turns the chunks into a versioned JSON file for the analysis tool. The raw slot values are always included, with the decoded fields beside them; fields that are not readable are `null`.

```json
{
  "schema": "blacktip-perf-log-export",
  "schema_version": 1,
  "exported_at": "2026-11-04T16:52:00+13:00",
  "package": { "name": "Blacktip DPV", "version": "1.6.1", "log_layout_version": 1 },
  "device": {
    "fw_ver": [7, 0, 0],
    "hw_name": "60_MK5",
    "scooter_type": "blacktip",
    "hardware_configuration": 0
  },
  "limits": {
    "l_in_current_max_a": 22.8,
    "l_current_max_a": null,
    "max_speed_index": 9,
    "speed_percent": [45, 20, 30, 38, 46, 54, 62, 70, 78, 100]
  },
  "integrity": {
    "state": "ok",
    "enabled": true,
    "commit_seq": 6,
    "crc_stored": 748037813,
    "crc_computed": 748037813,
    "unflushed_pending": false,
    "flush_in_progress": false,
    "unverified_at_load": false
  },
  "first_slot": 64,
  "raw_slots": [6, 748037813, 1112820807, 257, 12, 47, 32771, 1, 123000, 12345, 2764, 48268582, 8323293, 131468403, 0, 0, 0, 0, 0, 0, 3000, 90000, 0, 6000, 240000, 300, 36000, 1512000, 7200, 54000, 3240000, 67500, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9000, 1890000, 72000, 0, 0, 12, 0, 95, 420, 1350, 5100, 1, 0, 65536, 0, 0, 1, 21000, 102236506, 46271721, 6491664, 98306],
  "decoded": {
    "lifetime": {
      "sessions_with_motor_use": 12, "motor_starts": 47,
      "safe_start_aborts": { "invalid_telemetry": 1, "timeout": 3, "high_current_stall": 0 },
      "safe_start_retries_exhausted": 1,
      "motor_on_s": 12300.0, "ah_used": 12.345, "wh_used": 276.4
    },
    "extremes": {
      "max_fet_temp_c": 47.3, "max_motor_temp_c": 31.8,
      "max_motor_current_a": 25.4, "max_input_current_a": 22.1,
      "max_abs_erpm": 4012, "min_vin_running_v": 31.87
    },
    "per_speed_index": [
      { "index": 2, "label": "speed 1", "on_s": 300.0, "mean_input_current_a": 3.0, "at_input_limit_s": 0, "mean_rpm_deficit_erpm": 0.0 },
      { "index": 9, "label": "speed 8", "on_s": 900.0, "mean_input_current_a": 21.0, "at_input_limit_s": 95, "mean_rpm_deficit_erpm": 80.0 }
    ],
    "duty": { "abs_ge_0_95_s": 42.0, "abs_0_90_to_0_95_s": 135.0, "abs_0_80_to_0_90_s": 510.0 },
    "faults": {
      "over_voltage": 0, "under_voltage": 1, "drv": 0, "abs_over_current": 0,
      "over_temp_fet": 2, "over_temp_motor": 0, "gate_driver_over_voltage": 0,
      "gate_driver_under_voltage": 0, "mcu_under_voltage": 0, "watchdog_reset": 0, "other": 0
    },
    "integrity_events": 1,
    "last_session": {
      "motor_on_s": 2100.0, "ah_used": 3.12, "wh_used": 34.6,
      "max_fet_temp_c": 41.2, "min_vin_running_v": 33.05,
      "max_input_current_a": 19.8, "max_abs_erpm": 3600
    },
    "diagnostics": { "longest_write_ms": 3, "aborted_flushes": 2 }
  }
}
```

The example is abbreviated: a real export lists all ten `per_speed_index` entries (indices 0 to 9, labels `reverse 2`, `untangle (reverse 1)`, `speed 1` to `speed 8`). `integrity.state` is one of the reader states above. A decoded field is `null` for a sentinel (for example `min_vin_running_v` when slot 77 field B is 32767) and a decoded value that equals a saturation maximum is flagged by the tool as saturated. `exported_at` is the host's timestamp. `package.version`, `device.fw_ver` and `device.hw_name` come from the host (the UI knows the package version, and the connection reports firmware and hardware). `scooter_type` and the speed settings come from the existing settings read. `limits` holds the configured controller limits where the host can read them, and `null` otherwise.

### Defaults and data handling

* Logging is disabled by default, and a fresh install or an upgrade does not enable it. Enabling is explicit and persistent (bit 0 of slot 67), and is done through `set-enabled`.
* The data stays on the controller and in exports the user starts. The package never transmits the log, and the log is out of scope for any separate opt-in telemetry design.
* The log holds aggregates only (counts, sums, maxima), no time series, no position and no identifier. It can be cleared at any time with `clear-log`, and it is lost on a firmware update.

### Test vectors

These are for the unit tests of the later implementation (pure functions: packing, saturating add, framing and CRC). All were computed with Python (`zlib.crc32`, `struct.pack(">I", ...)`) and checked against a direct port of `crc32_with_init`.

**CRC builtin.**

| Input | Result |
|---|---|
| `crc32` of the ASCII bytes `123456789`, init 0 | `0xCBF43926` |
| `crc32("ghijkl", crc32("abcdef", 0))` | `0xF6781B24`, equal to `crc32("abcdefghijkl", 0)` |

**Packing and saturation.**

| Operation | Result |
|---|---|
| `P15(1, 3)` | 32771 |
| `P15(1473, 1318)` | 48268582 (unpacks to 1473 and 1318) |
| `P15(32767, 32767)` | 1073741823 |
| temperature -5.3 °C encoded | 947 |
| temperature 85.0 °C encoded | 1850 |
| temperature 47.3 °C encoded | 1473 |
| supply 31.874 V encoded (0.01 V units) | 3187 |
| supply 31.876 V encoded | 3188 |
| `min(2147483647, 2147483000 + 1000)` | 2147483647 |
| P15 field `32760 + 100` saturated | 32767 |
| fold pending 3.6 into a stored value | adds 3, pending becomes 0.6 |
| fold pending 0.6 + 0.5 | adds 1, pending becomes 0.1 |

**Sample accumulation** (`dt` = 0.2 s, `limit` = 22.8 A so the at-limit threshold is 21.66 A, `steady` true unless stated):

| Sample | Updates |
|---|---|
| index 5, `i_in` 14.0 A, `rpm_set` 3000, `rpm` 2950, `\|duty\|` 0.96 | `on[5]` += 2.0 ds, `cur[5]` += 280.0, `def[5]` += 10.0, `at_limit[5]` += 0, `duty_ge_095` += 2.0 ds |
| index 9, `i_in` 21.7 A, `rpm_set` 4000, `rpm` 4000, `\|duty\|` 0.92 | `on[9]` += 2.0 ds, `cur[9]` += 434.0, `def[9]` += 0, `at_limit[9]` += 0.2 s, `duty_090_095` += 2.0 ds |
| `soft_start_active` 1, index 5 | only `motor_on` and the running-sample maxima change; no per-speed slot, no duty band |
| `speed` 99 | no accumulation except the Ah and Wh deltas |

**Decoded example image.** The 63 raw slot values for slots 64 to 126 are the `raw_slots` list in the export example above. It decodes as shown there; in particular index 4 (speed 3) has `on` = 36000 ds, `cur` = 1512000 (mean 1512000 / (10 × 36000) = 4.2 A) and `def` = 7200 (mean 10 × 7200 / 36000 = 2.0 eRPM), index 5 (speed 4) has `on` = 54000, `cur` = 3240000 (mean 6.0 A), `def` = 67500 (mean 12.5 eRPM), and slot 118 (value 65536) is `fault_5` = 2 and `fault_6` = 0.

| Check | Value |
|---|---|
| CRC input | slots 66 to 126, 244 bytes, big-endian; begins `42 54 4C 47 00 00 01 01 00 00 00 0C 00 00 00 2F` |
| CRC32 of the populated image | `0x2C9626B5` |
| Stored slot 65 (masked) | 748037813 (`0x2C9626B5`) |
| Cleared image (slot 66 = magic, slot 67 = 257, slots 77 and 124 = 32767, all other slots 0), CRC32 | `0x6178A90A`; stored slot 65 is 1635297546 (`0x6178A90A`) |
| Populated image with slot 100 changed to 70196 (`0x00011234`, a hybrid of two values) | CRC32 `0x7000419C`, masked 1879064988, which differs from the stored 748037813: state `crc_mismatch` |
| Populated image with `commit_seq` 7 and an unchanged, matching CRC | state `in_progress` |

Mean-value formulas use the units above (`on` in ds, `cur` in 0.01 A·s, `def` in eRPM·s); a block with `on` = 0 has no mean (`null`).

### Open points and verification still needed

* On the MK5 DPV: per-store time, flush duration and the start-latency effect of a press during a flush; the at-rest readings behind the thresholds; whether a prop or motor connected changes them.
* Whether a page transfer occurs and how long it takes (none observed on the rig; cause of the earlier estimate failing is unknown).
* The `LOG_*` constants, the stack size of the sampler thread (start at the `THREAD_STACK_MOTOR` value of 150 words and measure) and the chunk pacing over Bluetooth.
* The untested single-record design option above.
* CudaX behaviour.

## Build System

The project uses GNU Make for building the VESC package:

```text
make              # Build blacktip_dpv.vescpkg
make clean        # Remove generated files
make test         # Run code quality checks and smoke tests
make smoke-tests  # Run unit-style smoke tests only
make binary       # Generate binary LUT files only
```

### Version Management

The build system automatically generates version information for the package:

* **Version source**: Base version (e.g., `1.0.0`) is stored in `README.md` in the line `**Version:** 1.0.0`
* **Version format:**
  * On `main` branch: `<version>-<yyyymmdd>-<git-hash>` (e.g., `1.0.0-20251013-120605-2eacfa2`)
  * On other branches: `<version>-<branch-name>-<git-hash>` (e.g., `1.0.0-feature-xyz-2eacfa2`)
* **Distribution**: During build, `tools/update_version.sh` creates `README.dist.md` with the full version and build timestamp
* **Distribution**: During build, `tools/update_version.sh` creates `ui.dist.qml` with the full version and build timestamp
* **Package**: The `.vescpkg` includes `README.dist.md` and `ui.dist.qml` (referenced in `pkgdesc.qml`) so users see the detailed version info
* **Repository**: The `README.md` in the repository shows only the base version for simplicity
* **Rebuild behavior**: The package is only rebuilt when source files change (`blacktip_dpv.lisp`, `ui.qml`, `pkgdesc.qml`, `README.md`)

To update the version:

1. Edit the version line in `README.md`: `**Version:** 1.1.0`
1. Run `make` - the distribution file will be generated automatically with a new timestamp

**Note**: `README.dist.md` and `ui.dist.qml` are generated during build and should not be committed to git.

### Test Suite

The project includes smoke tests for pure functions to catch regressions before flashing hardware:

```text
make smoke-tests  # Run 30+ unit tests for pure functions
```

**Tested functions:**

* `clamp` - Value clamping (7 tests)
* `validate_boolean` - Boolean validation (5 tests)
* `state_name_for` - State name mapping (6 tests)
* `speed_percentage_at` - Speed percentage lookup (5 tests)
* `calculate_rpm` - RPM calculation (7 tests)

Tests are implemented in Python (`tests/run_tests.py`) to mirror the LispBM implementations and verify correctness without needing hardware.

## Project Structure

    blacktip_dpv/
    ├── assets/                          // Source data files
    │   └── display_lut.csv             // Display artwork, with four rotation variants per named display
    ├── tools/                           // Build and development tools
    │   ├── generate_lut_binary.py      // Generates binary files from CSV
    │   └── preview_display.py          // ASCII/PGM visualization tool
    ├── generated/                       // Auto-generated files (not in git)
    │   └── display_lut.bin             // Generated binary display data
    ├── blacktip_dpv.lisp               // Main lispBM runtime source
    ├── ui.qml                           // User interface
    ├── pkgdesc.qml                     // Package descriptor
    └── README.md                        // User-facing documentation

## Display Assets and Tooling

### Asset Files

The OLED screen artwork lives in `assets/display_lut.csv` as a CSV file:

* **`display_lut.csv`** — Pre-rotated display artwork, with one row for each named display and rotation variant

This CSV file is the source of truth. The build system automatically generates the binary display LUT from it.

### Preview Tool

Visualize and verify display artwork before building:

```text
// List all available screens
python tools/preview_display.py --list
// Preview a specific frame by index
python tools/preview_display.py --index 0
// Preview by name and rotation
python tools/preview_display.py --name "Display Battery 4 Bars" --rotation 0
// Show all screens for a given rotation
python tools/preview_display.py --show-all-rotation 0
// Export as PGM image
python tools/preview_display.py --index 0 --output preview.pgm
```

The preview tool applies a fixed hardware-orientation transform to match the physical display. This transform is independent of the configured frame rotation: in the physical preview, rotation 1 is 90° clockwise from rotation 0, rotation 2 is 180° clockwise, and rotation 3 is 270° clockwise.

### Binary File Format

The lispBM runtime loads display data from a binary file at runtime using LispBM's `import` statement. This file is automatically generated from the CSV asset during the build process.

**Display LUT** (`generated/display_lut.bin`):

* Header (8 bytes):
  * Magic number: 0x4C555444 ("LUTD" in ASCII)
  * Version: u16 (currently 1)
  * Frame count: u16
* Frame data: a sequence of 16-byte interleaved frames

## Development Workflow

### Editing Display Artwork

1. Edit `assets/display_lut.csv` (modify existing frames or add new ones)
1. Preview your changes: `python tools/preview_display.py --index N`
1. Build package: `make`

The binary files will be automatically regenerated from the CSV.

### Adding New Displays

1. Add four rows to `display_lut.csv` (one per rotation 0-3). The `index` field must be sequential and unique. Each row has 16 byte fields (`b0` through `b15`) representing the 8×8 pixel matrix as interleaved low/high column bytes.

## Display Orientation

The display hardware has a fixed orientation transform relative to the natural orientation. The preview tool applies that transform for its physical view. The LispBM runtime does not transform frame pixels: it selects each pre-rotated 16-byte asset using `display * 64 + rotation * 16`, where increasing configured rotation is clockwise in the physical view.

Each display frame consists of:

* 8 columns × 8 rows = 64 pixels
* Stored as 16 bytes (8 column pairs, each pair = low byte + high byte)
* Bit 7 (MSB) = top pixel, Bit 0 (LSB) = bottom pixel in each column

## Code Quality

### Testing

```text
make test  # Runs whitespace checks
```

### Code Style

* Use snake\_case for LispBM variable and function names
* Use 4 spaces for indentation (not tabs)
* No trailing whitespace
* Brace style: 1TBS (One True Brace Style)
* See `.github/instructions/copilot-instructions.md` for full style guide

## Logging Hygiene

The lispBM runtime uses conditional debug logging to minimize memory pressure on the resource-constrained VESC hardware.

### Debug Logging Functions

Two mechanisms are available for debug logging:

**`debug_log` function** - For static strings:

```lisp
(debug_log "Motor: Stopping motor")
```

**`debug_log_format` macro** - For dynamic strings with expensive operations:

```lisp
(debug_log_format (str-merge "Speed: Set to " (to-str clamped_speed)))
```

### When to Use `debug_log_format`

Use the `debug_log_format` macro when logging requires:

* String concatenation (`str-merge`)
* Number-to-string conversion (`to-str`)
* Any other expensive operations

The macro only evaluates these expressions when `debug_enabled` is 1, preventing unnecessary memory allocation and CPU cycles in hot paths.

### Hot Paths Requiring `debug_log_format`

* `set_speed_safe` - Called every speed change (multiple times per second)
* Motor control loop - Runs continuously
* State machine handlers - Active during user interactions
* Click action handlers - Called on every button press

### Example

**Bad** (evaluates `str-merge` even when debug is off):

```lisp
(debug_log (str-merge "Speed: Set to " (to-str speed)))
```

**Good** (only evaluates when debug is enabled):

```lisp
(debug_log_format (str-merge "Speed: Set to " (to-str speed)))
```

## Testing Best Practices

### Adding Tests for Pure Functions

When adding new pure functions (functions without side effects), add corresponding tests to `tests/run_tests.py`:

1. **Identify pure functions** - Functions that always return the same output for the same input, with no side effects (no I/O, no state modification)
2. **Implement Python equivalent** - Create a Python version that mirrors the LispBM logic exactly
3. **Write test cases** - Cover:

* Normal/expected inputs
* Boundary conditions (min, max, zero)
* Edge cases (negative, overflow, empty)
* Error conditions

4. **Run tests before committing**:

```text
make test
```

### What to Test

✅ **Pure functions** - Calculations, validation, state mappings
✅ **Boundary conditions** - Min/max values, thresholds
✅ **Edge cases** - Empty lists, negative values, overflow
❌ **Hardware I/O** - Not feasible without full simulation
❌ **State machines** - Complex runtime behavior, test manually

### Test Structure

Each test function should:

* Have a descriptive name (`test_function_name`)
* Print a section header
* Use `assert_eq` or `assert_near` for validation
* Include descriptive test names explaining what's being tested

Example:

```text
def test_new_function():
    print("\n=== Testing new_function ===")
    assert_eq(new_function(5), 10, "new_function: basic case")
    assert_eq(new_function(0), 0, "new_function: zero input")
    assert_eq(new_function(-1), 0, "new_function: negative clamped")
```

## Binary Loading Implementation

The runtime uses LispBM's `import` statement to load binary data at runtime:

```lisp
; Import binary file as a top-level form (NOT inside a flashed function — see VESC 7.00 notes)
(import "generated/display_lut.bin" 'display_lut_bin)
; Validate headers
(defun validate_lut_header (data magic expected_version) { … })
; Access display data (offset by 8-byte header)
(bufcpy pixbuf 0 display_lut_bin (+ 8 start_pos) 16)
```

### Why `pixbuf` is Required

The `pixbuf` variable is a 16-byte working buffer that is essential to the display system and **cannot be removed**:

```lisp
(let ((start_pos 0)
         (pixbuf (array-create 16))) {  // Temporary 16-byte buffer
      …
      // Copy 16 bytes from binary file to pixbuf
      (bufcpy pixbuf 0 display_lut_bin (+ 8 start_pos) 16)

      // Send pixbuf to display via I2C
      (i2c-tx-rx mpu-addr pixbuf)
})
```

**Why it's needed:**

1. The `i2c-tx-rx` function requires a buffer to send data
2. We cannot send data directly from the binary file to I2C
3. The buffer extracts the specific 16-byte frame we need from the larger binary file
4. It's a small (16 bytes) stack-allocated array with negligible overhead

## Build Dependencies

* Python 3.x (for build tools)
* VESC Tool (for building .vescpkg files)
* Standard Unix tools (make, grep, etc.)

## Repository

<https://github.com/vedderb/vesc_pkg>
