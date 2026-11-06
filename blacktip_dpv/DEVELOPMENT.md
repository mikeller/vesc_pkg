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
  * Opt-in, off-by-default aggregate statistics kept in EEPROM slots 64 to 126 (block A), with an optional extended record in slots 128 to 191 (block B), flushed only at rest; see [Performance Log (on-device)](#performance-log-on-device) below for the contract.

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

Before calling the VESC hardware shutdown path, the request selects the existing `DISPLAY_OFF` power-symbol frame, allows the 4 Hz display loop to render it, and plays four descending tones (700, 575, 450 and 325 Hz) at the configured beep volume. This gives a clear acknowledgement of an accidental as well as an intentional five-click command; when volume is zero, the display remains the confirmation. Success does not return. A returned `nil` is logged as failure/unsupported/held input and is not retried. This feature does not use `shutdown-hold`, alter `OFF_AFTER`, or add another idle timer. The [performance log](#performance-log-on-device) specification adds one bounded flush attempt before the `(shutdown true)` call (not implemented yet; see [Power-off paths](#power-off-paths-and-idle-auto-off)); that attempt never blocks the shutdown.

## Performance Log (on-device)

Status: block A RAM collector only; boot load, storage writer, block B, extraction and host tooling remain unimplemented. The following contract covers the complete feature.

**Implementation decisions for the RAM collector.** A failed, nil or non-number getter skips only the metric that needs it, not the other signals in that sample. The Ah and Wh baselines advance only on running samples: idle drift is captured in the first running delta, and an idle unit changes no slots. Their accumulator rows are quiet: increments are kept in RAM without setting dirty; they reach EEPROM only on a later flush triggered by a non-quiet change. Dirty denotes a non-quiet slot value changing since the last flush. No storage writer exists in this phase.

**Collector simulation.** With `LBM_REPL` set to a native `release_7_00` LispBM REPL, `make test` also executes the real RAM collector and its rule table using mocked telemetry and elapsed time (`tests/perf_log_native.py`). Only the getter calls and elapsed-time source are substituted; it tests specification sample vectors, nil and trapped getter errors, idle and soft-start behaviour, saturation, a spawned 160-word sample, and GC-reclaimed heap stability. Without `LBM_REPL` that optional suite is skipped. This simulation cannot measure hardware stack high-water, motor behaviour, real idle auto-off or controller heap headroom.

The section was amended on 5 Nov 2026 after the owner's decisions of 4 and 5 Nov 2026 and the rig measurements described in [Flash write behaviour](#flash-write-behaviour). It is now the binding contract for block A and [block B](#block-b-extended-log-layout-v1) together: timing ([Flush gate](#flush-gate)), the firmware gate ([Firmware gate and slot capacity](#firmware-gate-and-slot-capacity)), power-off paths and the idle auto-off non-interference rule ([Power-off paths](#power-off-paths-and-idle-auto-off)), the extraction protocol ([Extraction](#extraction)), the export schema ([Export format](#export-format)) and the block B flag and reference rules. Where an amendment corrects an earlier statement, the correction is stated in place.

**Evidence labels.** Every duration or latency figure that describes the hardware is labelled with one of three tags:

* **[rig-measured]**: a measurement on the plain HW 60 test rig (not an MK5), firmware 7.0.0 `release_7_00`, timed with a human stopwatch (jitter about 0.5 s). The MK5 is unmeasured. The evidence is cited as "bench measurements of 5 Nov 2026"; the parts recorded in `tools/nv_write_probe_results.md` are cited by that path, and the rest is bench-reported and not yet in that file.
* **[arithmetic]**: computed from a [rig-measured] figure.
* **[estimate]**: a reasoned figure with no measurement behind it.

Design constants (for example `LOG_SETTLE_S`) are chosen values, not measurements, and carry no label. A duration measured with `systime` carries the extra warning in [Flash write behaviour](#flash-write-behaviour): it is a lower bound.

The log is an opt-in, off-by-default record of aggregate performance statistics (how hard the drive is worked at each speed setting, supply sag, saturation, faults) kept on the controller, so that owners can see how the scooter behaves with their own battery packs. Blacktip is the validation target. Nothing in the layout is Blacktip-specific (the speed indices and getters are common to both scooter types), so CudaX support is not precluded, but it is not designed for or validated here.

### Safety statement

The logging-only phase changes no motor-control behaviour and no configuration:

* It never calls `set-duty`, `set-rpm`, `set-current`, `conf-set` or any other actuator, and it does not alter any existing global used by the motor, state-machine or display paths.
* It reads telemetry through getters only. The single touch point in existing code is one RAM-only counter increment inside `safe_start_abort_with_reason`; it adds no EEPROM write and no control-flow change.
* Block A writes only EEPROM slots 64 to 126, and the optional [block B](#block-b-extended-log-layout-v1) writes only slots 128 to 191. Settings slots 0 to 32, the free slots 33 to 63, the schema marker in slot 127 and `EEPROM_SETTINGS_COUNT` are untouched, and the settings migration is unchanged.
* While both blocks are disabled (the default) the log performs no EEPROM writes at all and the sampler thread does not run.
* The log never prevents, delays or defeats the firmware's idle auto-off (see the [non-interference rule](#non-interference-rule-binding)): it issues no motor command, uses no `shutdown-hold` and registers no `event-shutdown` handler.
* The only motor-visible effect of an enabled log is the controller-side behaviour of an EEPROM write (see [Flash write behaviour](#flash-write-behaviour)). Writes happen only under the [flush gate](#flush-gate), which requires the motor to be at rest.

### Storage

* Storage is the LispBM emulated EEPROM only. The ESC has no file system or SD card, and the Blacktip Bluetooth add-on is a Flipsky NRF module, not a VESC Express, so there is no other persistent store the package can use.
* Reserved range: slots 64 to 126 (63 slots of 32 bits, 252 bytes). Slots 33 to 63 stay free for future settings (the test-fixture branch already uses 33 to 35). Slot 127 is the settings schema marker and is not touched.
* The firmware provides 256 LispBM EEPROM slots (0 to 255) on firmware 7.00; see [Firmware gate and slot capacity](#firmware-gate-and-slot-capacity), which corrects the "up to 128" figure of the LispBM documentation. Block A deliberately stays below 127. The optional [block B](#block-b-extended-log-layout-v1) uses slots 128 to 191.
* The log has its own header (magic and layout version) and is independent of the settings schema version. The settings paths (UI write, both reset-default paths, migrations) loop over slots `0..EEPROM_SETTINGS_COUNT-1` only and must never be extended to touch 64 to 126. In particular, Reset Defaults does not clear the log.
* The vendored LispBM documentation states that the emulated EEPROM survives power cycles and configuration changes, but not firmware updates. Uploading a new package does not clear it. The log is lost on a firmware update, so export it first.
* Ownership of the range: the log owns 64 to 126 by contract. If the four header slots 64 to 67 are all `nil` (never written), the range is "empty". If any header slot is present but the magic (slot 66) differs from the expected value, the range holds foreign data (for example leftovers from a bench probe); it is reported as such, never overwritten implicitly, and is claimed only by an explicit `clear-log` or by `set-enabled` followed by an initial clear. A known magic with an unknown layout version is reported and left untouched. The same rules govern block B for slots 128 to 131; see [Block states](#block-states).

### Firmware gate and slot capacity

**Correction (5 Nov 2026).** The firmware has 256 LispBM EEPROM slots (0 to 255) on HW 60, 60_MK5 and 410 in firmware 7.00, not 128. `EEPROM_VARS_CUSTOM` is 256 in the common `datatypes.h` (line 1417 at the bench firmware hash `1fee61fb7ebc79745a359a0ee0c056cfce39a043` and at the `release_7_00` tip `9483d8cf6ec97b92ddd203c372745ba518a3b12f`), so it does not depend on the hardware. `check_eeprom_addr` in `lispBM/lispif_vesc_extensions.c` (line 1512 at the tip) rejects an address below 0 or at or above 256, and `eeprom-store-i`, `eeprom-read-i` and the float variants then return the `eval_error` symbol, which is an error, not `nil`; `conf_general.c` (`:231` and `:269`) repeats the check. The LispBM README ("up to 128", "Addr range: 0 to 127") is out of date. The upstream tags `release_6_05` (128) and `release_6_06` (256) show that the 256 slots apply from 6.06 (the two `datatypes.h` files were read on 5 Nov 2026).

* Slots 128 to 255 collide with nothing: they are not reserved by the firmware, they are independent of the 32 hardware-specific variables (`EEPROM_VARS_HW`), they survive page transfers like any written variable, and they read `nil` by source until written.
* Hardware confirmation, bench measurements of 5 Nov 2026 (plain HW 60 rig, firmware 7.0.0, rig only; the production DPV was not read): slot 255 reads `nil`, slot 256 raises an eval error (both recorded in `tools/nv_write_probe_results.md` on the probe branch, not in the copy of the file next to this document), and slots 128 to 255 are all `nil` on the rig (bench-reported; the sweep is not yet in the results file).

**Firmware gate, no probe, no fallback.** The package installs only on exactly firmware 7.00 (`pkgdesc.qml` `isCompatible`: major 7, minor 0, hardware 410, 60 or 60_MK5), which has 256 slots, so that gate is sufficient. The log therefore adds no runtime capacity probe, no fallback layout and no test path for firmware with only 128 slots. All log-thread work is wrapped in `trap`, so an out-of-range store would end or disable the log thread without affecting motor control. If `isCompatible` is ever widened, the slot count must be re-checked then. A foreign (non-matching, non-nil) header in slots 64 to 67 or 128 to 131 is never overwritten silently (see [Block states](#block-states)).

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
| 126 | `longest_store_ms`, `aborted_flushes` | P15(A, B) | Flush diagnostics (see [Flush diagnostics and clocks](#flush-diagnostics-and-clocks)). A: advisory duration, the longest single `eeprom-store-i` in ms, measured with `systime`, therefore a lower bound (0 when unavailable); never used in a gate or decision. B: flushes aborted by the re-checks, a count. The field position is unchanged from the first draft, where A was named `longest_write_ms`. |

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
* Slot 126 holds flush diagnostics (an advisory longest store time and the count of aborted flushes). The count is the primary content; the duration is a `systime` lower bound (see [Flush diagnostics and clocks](#flush-diagnostics-and-clocks)), so it informs the MK5 write-timing question but cannot settle it.
* Slot 121 field B counts integrity events, so a damaged image is recorded rather than silently repaired.
* Slots 116 to 120 give individual counters for fault codes 1 to 10 (including watchdog resets), with the rest combined.

Nothing was dropped from the required list. Packing: all counters that are small by nature (safe-start aborts, faults, extremes, last-session values, time at limit) are P15 pairs, and the time-at-limit seconds saturate at about 9.1 hours per index. There are no reserved slots left in 64 to 126; a later layout version that needs more room must re-pack rather than extend the range.

### Sampling

* One dedicated thread samples and also performs flushes, so there is exactly one writer of slots 64 to 126 and no race between accumulation and a flush. The thread is started only when at least one block is enabled. LispBM has no thread priorities: "low priority" means it sleeps 0.2 s between iterations (about 5 Hz, `LOG_SAMPLE_PERIOD`), does a fixed small amount of work per iteration, and yields. A flush pauses sampling, which is acceptable because flushes happen only at rest.
* The thread calls read-only getters only, each inside `trap` (the idiom used by the balance thread), so early-boot `nil` results cannot kill it. It never issues a motor command or any call that resets the firmware's inactivity timer (see the [non-interference rule](#non-interference-rule-binding)).
* State lives in preallocated byte arrays created before the loop starts: a mirror of the 63 slots (252 bytes, accessed with `bufget-u32` and `bufset-u32`) and a float buffer for the per-flush pending deltas (`bufget-f32` and `bufset-f32`). The loop creates no arrays or lists. LispBM boxes large integers and floats, so transient values from arithmetic are unavoidable; they are reclaimed by the garbage collector and an implementation must show no heap growth in a long soak.
* The elapsed time of a sample is measured (`secs-since` the previous sample) and clamped to 0.5 s (`LOG_DT_MAX`), so a starved thread or a flush never credits a long time to one reading.
* The event-data handler never writes the log. It posts a request into one RAM mailbox that the sampler thread executes, and a second request while one is pending is dropped without a response (the panel times out and retries; see [Extraction](#extraction)).

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

The writer does the following for one block (slots 66 to 126 for block A, 130 to 191 and header slots 128 to 129 for block B), only after the [flush gate](#flush-gate) has passed. With both blocks enabled it runs the sequence for block A and then for block B, each completed before the next starts (see [Flush ordering](#flush-ordering)):

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

**Reader states.** A reader (the package at start, the host on export) classifies the stored image. The same states, with the header slots 128 to 131, magic slot 130 and CRC slot 129, classify block B; see [Block states](#block-states).

| State | Condition |
|---|---|
| `empty` | Header slots 64 to 67 all read `nil` (never written). |
| `foreign` | At least one header slot is present and slot 66 is not the magic. |
| `unknown_layout` | Magic matches, layout version is not 1. |
| `in_progress` | `commit_seq` is odd. |
| `crc_mismatch` | `commit_seq` is even and the recomputed masked CRC differs from slot 65. |
| `ok` | `commit_seq` is even and the CRC matches. |

`in_progress` and `crc_mismatch` are reported as "torn or unverified". The reader never silently discards or resets the data. At start the package loads the values it finds into the mirror, increments `integrity_events` in its next flush (so the event is recorded in the log itself), and carries on. The raw slots are always exported so an analyst can inspect a damaged image.

**Cost and risk assessment (why there is no double buffering).** A torn log needs a power loss during a flush. The package writes only at rest, and a flush runs at most every 60 seconds (`LOG_MIN_FLUSH_INTERVAL_S`) and takes about 135 ms (typical, both blocks) to about 290 ms (a full image of both blocks) including the yields between stores [arithmetic on the rig-measured per-store cost, see [Timing figures](#timing-figures)], that is about 0.2 % of at-rest time for a typical flush and at most about 0.5 % for a full image, so the exposure is small. A power loss inside that window would need the supply to disappear within about a minute of the trigger being released (the flush starts at the earliest `LOG_SETTLE_S` after release): a broken supply connection, a power system failure, or removal of the battery. In the main use (under water) batteries are removed only after the user has left the water and removed dive gear, minutes later, so this is considered unlikely, and the consequence is bounded (see the measurements below: only the slot in flight was damaged, the damage is detected by the CRC, and the settings were never affected). The design therefore keeps the cheap integrity check (an odd/even sequence and a CRC, plus a read-back) and adds no costly mitigation: no double-buffered banks and no extra copies.

Bench findings that support this (HW 60 non-MK5 test controller, no Bluetooth, firmware 7.0.0 `release_7_00`, git `1fee61fb7ebc79745a359a0ee0c056cfce39a043`; bench measurements, 4 Nov 2026; see the table in [Measured behaviour](#measured-behaviour)): power was cut 17 times while 60 slots were rewritten back to back at 5 ms pacing; 3 of the 17 cuts tore the slot being written (new high 16 bits, old low 16 bits); no slot other than the one in flight was ever damaged, the EEPROM stayed readable after every cut, and settings 0 to 35 and slot 127 were unchanged in every case. A real flush is far shorter and rarer than that test.

### Flash write behaviour

Facts from the vendored 7.00 source at the bench firmware's git hash and, where stated, the `release_7_00` tip (source reading, not hardware tests):

* `eeprom-store-i` writes the value as two 16-bit halves, high half first, each as a 4-byte record (16-bit data plus 16-bit address) appended to the active 16 KiB page. `EE_WriteVariable` first reads the old half and returns without programming if it already equals the new value, so a store whose high half is unchanged programs only one record.
* Before programming, the controller calls `mc_interface_ignore_input_both(5000)` and `mc_interface_release_motor_override_both()`, then waits up to 3.0 s for the motor to reach the off state. Release sets the FOC control mode to current control at zero current. After programming it calls `mc_interface_ignore_input_both(100)`. While the ignore counter is non-zero, motor commands such as `set-duty` and `set-rpm` are dropped, not queued.
* If the motor does not reach the off state within 3.0 s, `store_eeprom_var` executes `return 100` in a function returning `bool`, which is true: `eeprom-store-i` then returns `t` although nothing was written. This is why the writer reads every slot back. (`eeprom_store_i_if_changed` returns `nil` for an unchanged value, see below.)
* A page holds fewer than 4096 records. When it is full, the next write triggers a page transfer: the live variables are copied to the other page and the old 16 KiB sector is erased. The emulated EEPROM also stores the VESC motor and app configuration (`NB_OF_VAR` includes them), so a page transfer moves those variables too, and the log's flushes bring page transfers forward (see [Page transfers and wear](#page-transfers-and-wear)).
* The flash datasheet (STM32F405/407, Doc ID 022152 Rev 2, Table 36) lists a 16 KB sector erase at 250 ms typical and 500 ms maximum at x32 programming parallelism (300 and 600 ms at x16, 400 and 800 ms at x8), and a minimum endurance of 10 000 erase cycles per sector. The parallelism used by the firmware has not been checked, so the planning bound is 600 ms (800 ms if the firmware programs at x8). These are datasheet figures for the sector erase alone.
* The existing helper `eeprom_store_i_if_changed` returns `nil` when the value is unchanged, so its result does not separate "unchanged" from "failed". The log writer needs its own helper that reports unchanged and stored as success and a failed store or read-back as failure.
* `store_eeprom_var` holds `utils_sys_lock_cnt()` (a counted `chSysLock`) around the programming, so by source reading no other thread runs during a store. Assumed, not verified: during a sector erase the controller can stall for the full erase time. This is why writes must never happen while running.

#### Timing figures

**Standing fact: `systime` is a lower bound across a store.** Every store runs under a kernel lock (`utils_sys_lock_cnt`, above), and `systime` is driven by the SysTick, which that lock can mask, so ticks are lost while a store runs and `systime` under-reports real time across `eeprom-store-i`. Every duration that was measured with `systime` is therefore a LOWER BOUND, not a real duration: the 0.1 to 0.3 ms per store, the 28 ms per 60-store burst, the "no write slower than 20 ms in 8400 writes", the 2.1 ms outlier and any CRC time. The earlier statement "no page transfer seen in 8400 writes" is NOT supported, because a transfer would not necessarily show in `systime`. Do not quote a `systime` duration as a real duration anywhere, and do not use one in a gate or decision.

**Rig measurements, wall clock [rig-measured].** Bench measurements of 5 Nov 2026 on the plain HW 60 rig (not an MK5; firmware 7.0.0 `release_7_00`; human stopwatch, jitter about 0.5 s; rig only, MK5 unmeasured). The probe is `probe-wallclock` in `tools/nv_write_probe.lisp` on the probe branch (it is not in the copy of the tool next to this document): one-record stores to one slot (the high half stays constant, so each store programs one record), timed with `systime` (printed) and with a stopwatch. The printed 1.5418 s of the first run is in `tools/nv_write_probe_results.md` on the probe branch (not in the copy of the file next to this document); the stopwatch values and the five 2000-store runs are bench-reported and not yet in that file. Six runs of 2000 stores were executed (12 000 stores); the sixth was not timed, and five were timed and analysed.

| Run | Stores | Printed (`systime`) | Stopwatch | Excess = stopwatch - bias - printed |
|---|---|---|---|---|
| 1 | 5000 | 1.5418 s | 6.58 s | bias 0.3 s (control): real about 6.28 s, so 4.74 s unaccounted |
| 2 to 6 (five timed) | 2000 each | 0.6186, 0.6048, 0.6065, 0.6200, 0.6208 s | 3.14, 3.69, 2.84, 2.99, 2.46 s | 2.13, 2.70, 1.84, 1.98, 1.45 s |

Every run reported `failed 0`. For the 2000-store runs the stopwatch bias is d0 = 0.39 s (two controls of 3.0001 s printed, each 3.39 s on the stopwatch). Excess over the five runs [arithmetic]: mean about 2.02 s, median 1.98 s, standard deviation about 0.45 s, which is the order of the stopwatch jitter. The 5000-store run predicts about 1.9 s for 2000 stores under a uniform per-store loss, and the observed mean is 2.02 s. Pooled over the five runs: 13.17 s real for 10 000 stores, about 1.32 ms per store, against about 0.31 ms per store printed (real time about 4.3 times the printed time).

Conclusion [inference]: the missing time is a roughly uniform per-store loss of about 1 ms (ticks lost while a store runs), not a few long stalls. The largest excess is only 0.72 s above the median, which is inside the jitter, and no run lacked the steady excess.

**Figures to use** (these replace the earlier 0.54 ms per store and the 90 ms and 200 ms flush estimates):

| Figure | Value | Label |
|---|---|---|
| Cost of one store of one record, including loop overhead | about 1.3 ms real | [rig-measured]: 1.26 ms from the 5000-store run, 1.32 ms pooled over five 2000-store runs; rig only, HW 60 non-MK5, stopwatch jitter about 0.5 s, MK5 unmeasured |
| Yield between stores in the flush loop | 1 ms nominal; its real cost is not measured | design constant (`LOG_STORE_YIELD_MS`) |
| A store that changes both 16-bit halves (two records) | up to about twice the single-record cost | [inference, not measured]: the probe loop keeps the high half constant |
| A 64-store flush | about 85 ms of store time, about 150 ms with the yields | [arithmetic] on 1.3 ms |
| A typical flush with both blocks (about 57 to 60 changed slots) | about 75 ms, about 135 ms with the yields | [arithmetic] on 1.3 ms |
| A full first-enable or clear image: 127 slots (63 in block A and 64 in block B; the second `commit_seq` store of each block adds two stores, inside the rounding) | about 165 ms, about 290 ms with the yields; up to about twice that if every slot changes both halves | [arithmetic] on 1.3 ms |
| CRC over about 256 B per block | 0.1 to 0.3 ms | [estimate], itself tick-timed so a lower bound |
| Motor commands dropped after any store | about 100 ms (`mc_interface_ignore_input_both(100)`) | source reading |

**Page-transfer stall [rig-measured, bounded].** No multi-second stall was seen in the five timed runs (about 10 000 stores, about 3 expected page-transfer opportunities [estimate, from the page model below]); it is not known whether any transfer occurred. The sixth run of 2000 stores was not timed, so a transfer in it would not have been observed. A stall below about 1 s cannot be excluded with this stopwatch method (jitter about 0.5 s; the datasheet sector erase is 250 to 500 ms typical to maximum at x32, cited above). State exactly: **no multi-second stall seen on the rig; a stall up to about 1 s is not excluded; MK5 unmeasured.** The rig test wrote 12 000 further records, which is 2 to 4 sector erases [estimate]; wear is not a design constraint.

**Start-delay acceptance and the forward rule.** The owner accepts about 1 s of added start delay if the trigger is pressed during a write (4 Nov 2026). On the rig figures that delay is not shown to be at risk, and the 5 s settle and 60 s minimum interval stay unchanged. No design change is made, and the earlier condition (revisit the design if multi-second stalls appear) is resolved for the rig. Forward rule: if a later measurement (the MK5 confirmation or the start-latency validation) shows an added start delay of about 1 s or more, the planner revisits the design. The options to consider are avoiding a flush when a trigger press is likely, more aggressive coalescing, and fewer slots written per flush. The MK5 confirmation of the rig figures is a validation step, not part of this specification.

#### Page transfers and wear

The following is a model, not a measurement [estimate]. The emulated EEPROM is two 16 KiB flash pages of 4-byte records, 4095 records per page. Each 32-bit slot is two 16-bit records, and an unchanged half is skipped (see the first bullet above).

* Live records copied at a transfer: about 872 (the motor and app configuration backup) + 68 (the package settings, slots 0 to 32 and 127) + 2 per log slot.
* Free records after a transfer: about 3029 with block A only (63 slots, 126 records), about 2901 with both blocks (127 slots, 254 records).
* Records written per flush are about the number of CHANGED slots: about 37 for block A, about 57 for A plus B. Flushes per page transfer therefore fall from about 82 to about 51, so transfers become about 1.6 times more frequent.
* An allocated slot that never changes costs only its 2 records of free space. Reserving slots 192 to 255 would cost 128 records (about 4 % of the free space), which is why they stay unassigned for now (headroom; the timing figures are rig-measured and the MK5 is unmeasured).
* A transfer also moves the VESC motor and app configuration, so log flushes bring those transfers forward. As an order of magnitude [estimate], about 1 transfer per day on a heavy dive day; nothing more is claimed.
* Wear is not a design constraint: with two sectors alternating at 10 000 erase cycles each, one transfer per 51 flushes allows about a million flushes [arithmetic], and no realistic use comes near it. The earlier estimate of "about 5000 hours of non-stop worst-case activity" is superseded by this model.

#### Flush diagnostics and clocks

`systime` is tick-driven and the ticks are lost while a store runs, so any duration measured with `systime` across `eeprom-store-i` is only a lower bound. The flush diagnostics are therefore defined with COUNTS as the primary content: stores per flush, flushes completed, aborted flushes, and the largest stores-in-one-flush. A `systime` duration is an advisory lower bound only and is never used in a gate or decision. Slot 126 keeps its layout: field A holds the advisory longest store time in ms (a lower bound, 0 when unavailable) and field B counts aborted flushes. Block A is frozen and has no free slot, so layout version 1 stores only the aborted-flush count and the advisory duration; the other counts are RAM values of the sampler thread (for example for a bench build to print), and promoting any of them to a stored slot needs a layout decision. If the flush implementation finds a time source that the kernel lock does not mask, this section may name it; none is assumed to exist.

### Flush gate

A flush starts only when all of the following hold. The `LOG_*` names are the constants the implementation defines; the values below are decided (owner decision, 4 Nov 2026) and both timing constants stay named and easy to change.

| Constant | Value | Meaning |
|---|---|---|
| `LOG_SETTLE_S` | 5 s | Continuous rest required before a flush (was 10 s). It only has to cover trigger pauses and the stopping of the propeller. |
| `LOG_MIN_FLUSH_INTERVAL_S` | 60 s | Minimum time between the end of one flush and the start of the next (stays 60 s; the planner's earlier proposal of 30 s is withdrawn). |
| `LOG_STORE_YIELD_MS` | 1 ms | Yield between two stores in the flush loop. |
| `LOG_REST_ERPM_MAX` | 25.0 eRPM | At-rest threshold. |
| `LOG_REST_DUTY_MAX` | 0.02 | At-rest threshold (`DUTY_AT_REST_THRESHOLD`). |

The rationale for 60 s is the main use of the DPV, which is under water: apart from a five-click shutdown (covered by the pre-shutdown flush) or a power system failure, batteries are removed only after the user has left the water and removed dive gear, minutes later, so a worst-case commit delay of about a minute is acceptable.

1. At least one block is enabled.
2. `speed == SPEED_OFF` continuously for `LOG_SETTLE_S` (5 s). The timer restarts whenever any condition below fails at a sample.
3. At every sample of that period: `|get-rpm| < LOG_REST_ERPM_MAX` (25.0 eRPM) and `|get-duty| < LOG_REST_DUTY_MAX` (0.02, the existing `DUTY_AT_REST_THRESHOLD`). A `nil` or NaN reading counts as not at rest, consistent with the battery-imbalance gating.
4. The trigger is not pressed: read `(gpio-read 'pin-ppm)` directly (1 is pressed) rather than the 25 Hz `sw_pressed` copy.
5. `startup_tune_active` is 0. The other beeper paths (battery indication, click tones, the abort tone and the five-click confirmation) also use `foc-beep` or `foc-play-tone` on the FOC path; if the implementation can detect them cheaply it defers while one is active. Otherwise the settle period and "speed off" are the protection (a write racing a tone is expected to cut it short; this is an inference, not tested).
6. At least one enabled block is dirty.
7. At least `LOG_MIN_FLUSH_INTERVAL_S` (60 s) have passed since the previous flush completed.

A flush on the five-click path waives conditions 2 and 7 (settle and interval) and never any other condition (see [Power-off paths](#power-off-paths-and-idle-auto-off)).

#### Flush ordering

Both blocks are flushed under this one gate by the one sampler thread: block A first, then block B, and only the blocks that are dirty. Each block is fully committed (odd `commit_seq`, the changed slots, the CRC, even `commit_seq`; see [Commit protocol](#commit-protocol-and-integrity)) before the next block starts. An abort (below) leaves the later block dirty for the next flush; the aborted block keeps its odd `commit_seq` until a later flush commits it, and stays dirty. A flush of one block never rewrites a slot of the other.

#### Re-checks and aborts

Before each store, read the trigger pin directly and `speed` again, as for a single block. If the trigger is pressed or `speed != SPEED_OFF`, stop immediately, leave `commit_seq` odd, increment `aborted_flushes` in the mirror (it is written by the next flush), and do not retry until the whole gate passes again. Yield for `LOG_STORE_YIELD_MS` between stores so the GPIO and state-machine threads can run; a burst with no yield cannot see a press (60 stores take about 80 ms real [arithmetic on the rig-measured 1.3 ms per store], while the bench burst printed 28 ms, which is a `systime` lower bound). At the start of a flush the at-rest thresholds are checked once more; they are not checked between stores, because the controller-side release and zero current cover that window.

#### User-facing worst case

Data is safely stored after `max(LOG_SETTLE_S, LOG_MIN_FLUSH_INTERVAL_S - time since the last flush)` of rest, where the time since the last flush is taken at the moment the trigger is released. That is between about 5 s and at most about 60 s: normally near 5 s when the previous flush is more than a minute old, and the 60 s worst case applies when a flush happened shortly before the last run. This replaces the earlier "wait about 15 s at rest" statement, which no longer holds. The flush itself then takes about 135 to 290 ms including the yields [arithmetic, see [Timing figures](#timing-figures)].

**At-rest thresholds (to be confirmed on the MK5 DPV).** The bench probe used `|rpm| < 5.0` and `|duty| < 0.005`, and that guard aborted the run in nine of about ten sessions; the cause is unresolved (noise, supply droop while power was failing, or the printed readings being a second read). The readings it printed were as large as |rpm| 3.36 and |duty| 0.0075, while readings that passed were at most |rpm| 1.53 and |duty| 0.0028. The probe thresholds were therefore within about 1.5 times of the noise, so they are not reused. The flush gate uses a duty limit of 0.02, the value the package already uses for at-rest detection in the battery-imbalance feature, which is more than 2.5 times the largest recorded reading, and an eRPM limit of 25, which is more than 7 times the largest recorded reading and far below `SAFE_START_MIN_RPM` (350). The settle period is continuous, so a threshold set too tight only delays the flush; it can never write while moving. Whether a prop or motor was attached during the bench readings was not recorded, so these thresholds (`|eRPM| < 25` and `|duty| < 0.02`) are a reasoned choice, not a measurement, and must be confirmed on the MK5 DPV.

### Power-off paths and idle auto-off

**Correction (5 Nov 2026).** The first draft said "the package gets no warning before shutdown". That is wrong for hardware with a power switch (HW 60 MK3 and newer, including the MK5; only the MK5 hardware file `hwconf/flipsky_official/flipsky_v6/hw_flipsky_60_core.h`, which defines `HW_SHUTDOWN_HOLD_ON`, was checked against source): the firmware sends `event-shutdown` before a shutdown (`shutdown_save_and_hold` calls `lispif_process_shutdown`, which posts the event only if a handler enabled it), and a handler can call `(shutdown-hold t)`, flush, then release. The package currently handles no `event-shutdown`; it handles `event-data-rx` only. The five-click path gets its own bounded flush hook (below), so **no `event-shutdown` handler is part of the design, and none is needed**: a handler would sit on the idle auto-off path as well, which the package must not touch (see the non-interference rule).

**Five-click shutdown (modified MK5 only, opt-in).** `request_five_click_shutdown` makes ONE flush attempt after the rejection checks and the confirmation tones and before the `(shutdown true)` call, only when `speed == SPEED_OFF` and the at-rest thresholds hold (gate conditions 1, 3, 4, 5 and 6), waiving the settle period and the minimum interval. The attempt is bounded: it runs the normal [flush](#flush-ordering) once, with its re-checks and abort rules, and never retries or waits. A refused, failed or aborted flush never blocks the shutdown. The five-click shutdown is kept (the owner also uses it when staging the DPV).

* Requirements of the five-click shutdown (see [Five-click Deep Shutdown](#five-click-deep-shutdown) and `DEEP_SLEEP.md`): hardware `60_MK5`, the opt-in `enable_five_click_shutdown` (default off, EEPROM slot 32), firmware 7.00, and the phantom-button jumper.
* Shutdown availability by firmware: the vendored source at the bench rig's git hash `1fee61fb7ebc79745a359a0ee0c056cfce39a043` has no `(shutdown true)`, only `shutdown-hold`; `shutdown` and `shutdown-btn-read` appear on the `release_7_00` tip (`9483d8cf`). The package's `firmware_supports_shutdown` checks only `fw-ver`, so it cannot detect a 7.00-labelled build without the extension; no package code is changed here.
* **The test rig (a plain HW 60 without the power switch) has no five-click shutdown and no idle auto-off, so the rig cannot exercise this path.** It needs a human validation step on an MK5 (with the jumper and the opt-in set): confirm that the flush completes before the controller powers off and that the log survives the shutdown.

**Firmware idle auto-off** (`hwconf/shutdown.c`, `release_7_00` tip; corrected 4 Nov 2026, the earlier text over-generalised). Mechanism [source]: for `shutdown_mode >= OFF_AFTER_10S` the shutdown thread powers the unit off when the inactivity time is at least the timeout AND the shutdown input reads pressed (the input is sampled over 0.7 s windows); `do_shutdown(false)` does not re-sample. The inactivity timer is reset only by `mc_interface` set-duty, set-current, brake, handbrake, open-loop and set-speed style commands whose magnitude is above 0.001 (`SHUTDOWN_RESET` in `motor/mc_interface.c` from line 560, in `mc_interface_set_duty` and the other `set_*` functions; `mc_interface_set_pid_pos` and `mc_interface_brake_now`, line 916, reset it unconditionally), and not by getters or by the EEPROM store path. The shutdown sequence is: `event-shutdown` (only if a handler is enabled; the package has none), `conf_general_store_backup_data`, 100 ms, then it waits while `shutdown-hold` is set (no firmware timeout), then it disables the gates. Mode numbers: 3 = 10 s, 4 = 1 min, 5 = 5 min, 6 = 10 min, 7 = 30 min, 8 = 1 h, 9 = 5 h.

Hardware cases (the spec states them explicitly; idle auto-off is never described as impossible without the qualifier "stock, unmodified"):

1. **STOCK, unmodified MK5.** The button connector is open (human-confirmed 4 Nov 2026; not yet measured with `(shutdown-btn-read)`), so the input never reads pressed and idle auto-off never fires. The factory `shutdown_mode` 9 (`OFF_AFTER_5H`) has no effect there.
2. **The owner's MODIFIED MK5** (phantom-button jumper between BLACK and YELLOW, `enable_five_click_shutdown` on). Idle auto-off DOES work (human-confirmed 4 Nov 2026) and must keep working: it is the deep-discharge fallback that prevents battery damage when the unit is left on (`DEEP_SLEEP.md`: `OFF_AFTER_5H` remains the fallback when manual shutdown is forgotten). The package's factory `shutdown_mode` is 9 (`OFF_AFTER_5H`, `ui.qml` `apply_defaults_blacktip`), so it is NOT inert on modified hardware.
3. **The test fixture** (`shutdown_mode` 7, `OFF_AFTER_30M`, in the test-fixture defaults on the fixture branch) is inert only because the rig is a plain HW 60 without the power switch: the firmware's no-power-switch branch only stores backup data and never shuts down.

The package runs no code on the idle auto-off path (no `event-shutdown` handler, no `shutdown-hold`) and must not add any. The only ways the unit loses power are therefore: five-click shutdown (modified MK5, opt-in), idle auto-off (modified MK5 only), battery removal, flat battery or BMS cut-off.

#### Non-interference rule (binding)

The log must never prevent, delay or defeat the firmware idle auto-off.

1. The sampling thread uses read-only getters only and never issues a motor command or any call that resets the inactivity timer.
2. A flush runs only when data is dirty and at most once per `LOG_MIN_FLUSH_INTERVAL_S`. At rest nothing changes, so an idle unit performs no further flushes and a flush cannot keep it awake.
3. The EEPROM store path (`conf_general.c` `store_eeprom_var`, lines 290 to 326 at the `release_7_00` tip) calls `mc_interface_ignore_input_both(5000)`, `mc_interface_release_motor_override_both()`, `mc_interface_wait_for_motor_release_both(3.0)` and later `mc_interface_ignore_input_both(100)`. Result of the planner's reading, repeated on 5 Nov 2026 for this specification: none of those functions contains `SHUTDOWN_RESET` (it occurs only in the `mc_interface_set_*` functions and `mc_interface_brake_now`, and in three places in `comm/commands.c`), so the store path does not reset the timer. The flush implementation re-verifies this against the source it is built on and states the result.
4. The package uses no `shutdown-hold` and no `event-shutdown` handler for logging, so a flush can delay a firmware auto-off only by the duration of one store (the firmware's own lock and wait semantics). An auto-off that interrupts a flush leaves a torn block, which the commit protocol detects.

#### Data loss by power-off style

Evidence labels as above. The 5 s settle and 60 s interval rest on the main use under water: apart from a five-click shutdown (covered by the pre-shutdown flush) or a power system failure, batteries are removed only after the user has left the water, minutes later; the factory 5 h auto-off is far beyond them; short auto-off timeouts (10 s, 1 min) are test settings only; the settle stays at 5 s because it only has to cover trigger pauses and the stopping of the propeller.

| Power-off style | What is lost |
|---|---|
| Five-click shutdown (modified MK5 with jumper, opt-in) | Nothing, if the gate passes: the flush runs before the shutdown. If it is refused or aborted (for example a still-turning propeller or a held trigger), the data since the last flush is lost. |
| Idle auto-off, modified MK5 (jumper), factory 5 h timeout | Nothing: the periodic flush (5 s settle, 60 s minimum interval) ran long before, and at rest nothing changes, so nothing is pending. |
| Idle auto-off, modified MK5, a short `shutdown_mode` (`DEEP_SLEEP.md` suggests `OFF_AFTER_1M` for testing; 10 s, 1 min and 5 min are the short settings) | The timer counts from the last non-zero motor command and the flush needs `max(settle, interval - time since last flush)` of rest (at most about 60 s). See the arithmetic below. |
| Idle auto-off, STOCK unmodified MK5 | Never fires (button input open, human-confirmed 4 Nov 2026), so no row applies. |
| Trigger released, then the battery pulled within the settle/interval window (up to about 60 s) | Everything since the last flush. In the main use under water this is rare, because batteries are removed minutes after leaving the water. |
| Unit left on | Nothing, after the flush. |
| BMS cut-off or flat battery mid-ride | The segment since the last flush. This is the most informative case and the least protected; there is no cheap fix, and it is documented rather than mitigated. |

Arithmetic for the short auto-off timeouts [inference, to be checked on a unit]: after a motor run the flush is eligible at `max(release + 5 s, last flush + 60 s)`, while a 1 min timeout powers the unit off at about `release + 60 s`. The last flush precedes the run it follows, so the flush is eligible before the power-off by `min(55 s, time from the last flush to the release)`, and the time from the last flush to the release is at least the run's duration. A 1 min timeout therefore normally still gets its flush, with a thin margin after a very short run soon after a previous flush (and the flush itself takes about 135 to 290 ms with the yields). A 10 s timeout can race the settle and the interval and lose the unflushed segment or leave a torn block (detected, not silent). Without motor use there is no such margin: if the timer started before the last flush and a datum becomes dirty within 60 s of that flush (for example a pack-tag change), it can be lost at a short timeout. This is expected and not a failure.

### Worst-case latency

The sampler flushes only at rest, so a rider normally never sees a flush. For a press during a flush:

* Number of stores: a full image of one block is at most 64 stores for block A (61 covered slots plus `commit_seq` twice and `crc`) and 65 for block B (62 covered slots plus the same three); a full first-enable or clear image of both blocks is 127 slots; a typical flush after a ride changes about 57 to 60 slots across both blocks. Figures in [Timing figures](#timing-figures).
* Per-store cost: about 1.3 ms real per one-record store [rig-measured, rig only, HW 60 non-MK5, stopwatch jitter about 0.5 s, MK5 unmeasured], plus the 1 ms yield. A typical flush with both blocks takes about 75 ms of store time, about 135 ms with the yields; a full image of both blocks about 165 ms, about 290 ms with the yields [arithmetic].
* The abort check runs before each store, so a press stops the flush after the store in flight. The controller then ignores motor commands for about 100 ms after any store. The earliest motor command after a press comes from the state machine after `TIMER_CLICK_WINDOW` (0.3 s), so for these store times the added start delay is expected to be small or zero [inference from the figures above; not measured end to end].
* Page-transfer stall: no multi-second stall seen on the rig; a stall up to about 1 s is not excluded; MK5 unmeasured. A motor command issued inside the 100 ms ignore window would be dropped and fall back on the package's existing safe-start timeout and retry handling. The accepted tolerance is about 1 s of added start delay (owner decision, 4 Nov 2026); the forward rule is in [Timing figures](#timing-figures).
* No end-to-end start latency has been measured. Measure it on the MK5 DPV before release.

### Measured behaviour

Rig: HW 60 non-MK5 test controller, no Bluetooth, firmware 7.0.0 (`release_7_00`, git `1fee61fb7ebc79745a359a0ee0c056cfce39a043`). Bench measurements, 4 Nov 2026, and the wall-clock runs of 5 Nov 2026 (see [Timing figures](#timing-figures)). Not yet measured on the HW 60 MK5 DPV. The measurement script and the full record are in `tools/nv_write_probe.lisp` and `tools/nv_write_probe_results.md`.

**Every duration in the first rows below was measured with `systime`, which under-reports real time across a store (the SysTick is masked while the kernel lock is held). Each is a LOWER BOUND, not a real duration**; the real cost is about 1.3 ms per one-record store [rig-measured, wall clock].

| Item | Result (`systime`, lower bound) |
|---|---|
| Single write, 20 writes to one slot | 0.1 to 0.3 ms each, average 0.175 ms (lower bound) |
| Burst of 60 writes | 27.7 to 28.4 ms total (about 0.47 ms per write; lower bound) |
| Slowest write per burst | 0.5 to 0.6 ms, except one burst at 2.1 ms (lower bounds) |
| Long run of 8400 timed writes | Slowest 2.5 ms (then 2.4 and 2.4 ms); none over 20 ms; 0 store failures; average about 0.54 ms per write including loop overhead; elapsed 4.544 s (all lower bounds; a slow store would not necessarily show) |
| Page transfer | Not shown either way by these runs. The earlier statement "no page transfer seen in 8400 writes" is not supported, because `systime` does not see time lost under the kernel lock, and the earlier estimate of one within about 4095 writes was not supported, cause unknown. The wall-clock runs of 5 Nov 2026 saw no multi-second stall (about 10 000 stores, five timed runs): no multi-second stall seen on the rig; a stall up to about 1 s is not excluded; MK5 unmeasured. |
| Wall clock, stopwatch (5 Nov 2026) | About 1.3 ms real per one-record store (1.26 ms from one 5000-store run, 1.32 ms pooled over five 2000-store runs), about 4.3 times the printed `systime` figure [rig-measured; stopwatch jitter about 0.5 s; rig only, HW 60 non-MK5, MK5 unmeasured] |
| Unused slots | Slots 36 to 126 read `nil` before probing; settings 0 to 35 (checksum 17532) and slot 127 (value 6) unchanged through all writes and power cuts |
| Power cuts | 17 genuine cuts (1 in one session, 16 in another, 5 ms pacing). 3 tore a 32-bit slot: new high 16 bits with old low 16 bits (raw 577 at slot 113, raw 130630 at slot 94, raw 130652 at slot 116). Only the slot in flight was damaged. The EEPROM stayed readable after every cut. Small sample; the rate is not generalised. |
| MK5 | Not measured |

Unverified design option, not relied on: because the high half is written first and a half whose value is unchanged is not programmed, a stored value whose high half never changes would need only one 16-bit record per store, so a power loss could not leave two mismatched halves. This comes from source reading and is untested on hardware.

### Extraction

This section replaces the first block-A-only draft of the protocol (which used a request id and a `kind` byte); nothing had shipped, so there is no migration.

**Transport.** The production DPV (HW 60 MK5 with the Bluetooth module) has no accessible USB without disassembly. On that unit the log is read, exported, cleared and enabled through VESC Tool over the Bluetooth link; USB applies only to units that expose it (for example the plain HW 60 test rig, which has no Bluetooth). There is no Bluetooth under water, so extraction is always after the dive and no live in-water read is specified (`read-log` is nonetheless safe at any time, see below).

The log is read and managed over the existing `event-data-rx` channel (`send-data` in the other direction). The current protocol uses `HANDSHAKE_CODE` (255) as a single byte and treats every other message as a settings write of at least `EEPROM_SETTINGS_COUNT` bytes (33 today, 36 on the test-fixture branch; 30 in the first release), logging and dropping anything shorter. The new messages use that gap.

* Block ids: 0 = block A, 1 = block B.
* Opcodes are the first byte of a request: `0xA1` read-log, `0xA2` clear-log, `0xA3` set-enabled, `0xA4` set-pack-tag. They are distinct from `HANDSHAKE_CODE` (255) and from every valid settings byte 0 (reverse speed is 20 to 50).
* A request is recognised as an opcode only when its length is at most 8 bytes (they are 3 or 4 bytes, and always shorter than `EEPROM_SETTINGS_COUNT`), far below the smallest settings write ever shipped, so an older package ignores them (it logs "buffer too small") and can never mistake them for a settings write.
* Responses are at most 30 bytes (a 6-byte header plus at most 24 data bytes). The ceiling for a message is 128 bytes per `send-data`, but the existing settings UI (`onCustomAppDataReceived` in `ui.qml`) treats any incoming payload of 31 bytes or more as a settings write and applies it to the controls (it ignores shorter ones with a console warning). A response of 30 bytes or fewer cannot be mistaken for settings by the unmodified UI. `ui.qml` must additionally ignore payloads whose first byte is `0xB1` or `0xB2` (response tags), so log traffic never reaches the settings code or the console warning.

**Requests**

| Opcode | Bytes | Meaning |
|---|---|---|
| `0xA1` read-log | `[A1, block, part]` or `[A1, block, part, pace_ms]` | `part` 0 is the stored image and the header state; `part` 1 is the live RAM image (unflushed). Optional `pace_ms` overrides the chunk pacing (below). Read-only; allowed at any time. |
| `0xA2` clear-log | `[A2, block, 5A]` | At rest only. Keeps the enabled flag and writes a cleared image with a proper commit. For block B it re-reads the references and sets flag bit 1 from that read (see [Bin edges](#bin-edges-binding)). `5A` is a confirmation byte. |
| `0xA3` set-enabled | `[A3, block, value]` | `value` 0 or 1. At rest only. Initialises an `empty` block (a full image write) and sets the enabled flag last; refuses a `foreign` block and an `unknown_layout` block. Blocks are enabled independently (block B may be on without block A). Default: both disabled. The sampler and flush thread runs if at least one block is enabled. |
| `0xA4` set-pack-tag | `[A4, hi, lo]` | The pack tag is `hi × 256 + lo`, 0 to 32767 (0 means unset). At rest only. Refused unless block B is valid and enabled. Marks block B dirty. |

Write opcodes (`0xA2`, `0xA3`, `0xA4`) write EEPROM, so they run only at rest: `speed == SPEED_OFF` and conditions 3, 4 and 5 of the [flush gate](#flush-gate), with no settle period, no dirty requirement and no minimum interval. They are executed by the sampler thread through the one RAM mailbox, so the single-writer rule holds; the event-data handler never writes the log. `clear-log` also claims a `foreign` block explicitly (that is the only way to claim one; `set-enabled` refuses it); it refuses an `unknown_layout` block. Checks run in this order: bad argument, not at rest, block state.

**Read response, tag `0xB1`**, at most 30 bytes: `[B1, block, part, chunk_index, chunk_count, state_byte] + up to 24 data bytes`. The state byte is the block state in the first chunk (`chunk_index` 0) and 0 in every other chunk. The data bytes are slot values as big-endian 32-bit integers, six slots per chunk, in slot order from the first slot of the block (64 for block A, 128 for block B). A slot that reads `nil` is sent as `0xFFFFFFFF`, which is never a valid value, and the panel maps it to `null`. Part 1 of a block whose collector is not running (no RAM image) is sent with every slot `0xFFFFFFFF`; in part 1 the header slots (`commit_seq`, CRC) are the mirror's copies of the last stored values.

| Block | Image | Chunks per part | Chunk `i` carries | Last chunk |
|---|---|---|---|---|
| A (252 B, 63 slots) | slots 64 to 126 | 11 | slots `64 + 6i` to `69 + 6i` for `i` 0 to 9 (24 B, message 30 B) | `i` = 10: slots 124 to 126 (12 B, message 18 B) |
| B (256 B, 64 slots) | slots 128 to 191 | 11 | slots `128 + 6i` to `133 + 6i` for `i` 0 to 9 (24 B, message 30 B) | `i` = 10: slots 188 to 191 (16 B, message 22 B) |

**State byte**: bits 0 to 2 are the state code, bit 3 is the enabled flag as stored in the header (0 when the header is not readable); bits 4 to 7 are 0.

| Code | State | Reader state name |
|---|---|---|
| 0 | uninitialised | `empty` |
| 1 | valid (enabled) | `ok` |
| 2 | valid-disabled | `ok` |
| 3 | torn | `in_progress`, `crc_mismatch` |
| 4 | unknown version | `unknown_layout` |
| 5 | foreign | `foreign` |

For example a valid, enabled block has state byte `0x09` (code 1, enabled bit 8), a valid-disabled block `0x02`, a torn block that was enabled `0x0B`, a foreign block `0x05`, an uninitialised block `0x00`.

**Acknowledgement, tag `0xB2`**: `[B2, opcode, status, block]` (4 bytes), sent for every write opcode, and for a read request that is invalid. `block` echoes the request (always 1 for `0xA4`). Status: 0 ok, 1 refused: not at rest, 2 refused: block state, 3 bad argument (unknown block id, `part` other than 0 or 1, `value` other than 0 or 1, a `0xA2` confirmation byte other than `5A`, a pack tag above 32767). A valid read request has no acknowledgement; the `0xB1` stream is the answer.

**Pacing and serving (BLE; provisional until measured on the DPV).** The production DPV is reachable over Bluetooth only. The sender waits `LOG_CHUNK_PACE_MS` between chunk messages (a named constant; the provisional default is 10 ms, to be tuned by the on-DPV Bluetooth read test). The optional fourth request byte overrides it in ms: 0 or absent means the default, and values above 250 clamp to 250; the request stays at most 8 bytes and the 3-byte form stays valid. Reads are served one at a time: a read request that arrives while another is still being sent is dropped (no response) and the panel retries after its timeout. The same holds for a write request that arrives while another is pending. A full read of both blocks and both parts is 44 messages of at most 30 bytes (4 parts of 11 chunks; 1280 bytes in all [arithmetic], 318 B per part for block A and 322 B for block B); at the default pace the pacing alone takes about 0.44 s [arithmetic] plus the link's own latency, which is not measured.

**Receiver rule (binding on the panel).** The panel detects missing or duplicate chunk indices (using `chunk_count` from the header), retries the part up to 3 times with a doubled pace (twice the pace of the first attempt, clamped at 250 ms), and then reports the read as incomplete. An incomplete read is never exported as if it were complete. The panel's per-part timeout is set from the on-DPV Bluetooth test.

`read-log` is read-only and allowed at any time, including while running. It reads flash (part 0) or the RAM image (part 1) and does not release the motor. A read that overlaps a flush returns a coherent but `in_progress` stored image; part 1 is read slot by slot while the sampler may still be accumulating, so it is advisory, and the stored image is authoritative. The package never sends the log unprompted.

#### Worked examples and protocol test vectors

Hand-computed, and asserted by the script at the end of [Block B test vectors](#block-b-test-vectors), which builds the frames and compares the literals below. Block A is the populated image of the [Export format](#export-format) example (slots 64 to 126); block B is the populated block B image (slots 128 to 191, commit sequence 6, flags 279).

| Case | Bytes |
|---|---|
| Read block A, stored image, default pace: request | `A1 00 00` |
| Response chunk 0 (30 B; state `0x09`; slots 64 to 69 = 6, 748037813, `0x42544C47`, 257, 12, 47) | `B1 00 00 00 0B 09 · 00 00 00 06 · 2C 96 26 B5 · 42 54 4C 47 · 00 00 01 01 · 00 00 00 0C · 00 00 00 2F` |
| Response chunk 10 (18 B; slots 124 to 126 = 46271721, 6491664, 98306) | `B1 00 00 0A 0B 00 · 02 C2 0C E9 · 00 63 0E 10 · 00 01 80 02` |
| Read block B, live RAM image, pace 25 ms: request | `A1 01 01 19` |
| Response chunk 0 (30 B; state `0x09`; slots 128 to 133 = 6, 2019938442, `0x42544C48`, 279, 5, 229376) | `B1 01 01 00 0B 09 · 00 00 00 06 · 78 65 D0 8A · 42 54 4C 48 · 00 00 01 17 · 00 00 00 05 · 00 03 80 00` |
| Response chunk 10 (22 B; slots 188 to 191 = 363, 7471954, 52428800, 0) | `B1 01 01 0A 0B 00 · 00 00 01 6B · 00 72 03 52 · 03 20 00 00 · 00 00 00 00` |
| Invalid block id 2: request, acknowledgement | `A1 02 00`, `B2 A1 03 02` |
| Clear block B: request, ok | `A2 01 5A`, `B2 A2 00 01` |
| Clear block B while not at rest | `B2 A2 01 01` |
| Clear with confirmation byte 0: request, bad argument | `A2 01 00`, `B2 A2 03 01` |
| Clear an `unknown_layout` block A | `A2 00 5A`, `B2 A2 02 00` |
| Set block A enabled: request, ok | `A3 00 01`, `B2 A3 00 00` |
| Enable a `foreign` block B | `A3 01 01`, `B2 A3 02 01` |
| Enable with value 2 | `A3 00 02`, `B2 A3 03 00` |
| Pack tag 7: request, ok | `A4 00 07`, `B2 A4 00 01` |
| Pack tag 32767 (`0x7FFF`): request | `A4 7F FF` (accepted) |
| Pack tag 32768 (`0x8000`): request, bad argument | `A4 80 00`, `B2 A4 03 01` |
| Pack tag 7 while block B is disabled, or not at rest | `B2 A4 02 01`, `B2 A4 01 01` |

Pace byte: `A1 00 00` and `A1 00 00 00` use the default (10 ms); `A1 00 00 0A` is 10 ms; `A1 00 00 19` is 25 ms; `A1 00 00 FA` is 250 ms and `A1 00 00 FF` clamps to 250 ms. The first retry uses twice the first attempt's pace: 10 ms gives 20 ms, 25 ms gives 50 ms, 100 ms gives 200 ms, and 200 ms or more gives 250 ms.

### Export format

The VESC Tool panel turns the chunks into one versioned JSON document for the analysis tool (schema version 1). Nothing had shipped, so there is no migration from the earlier single-block draft. Raw slot values are authoritative: the Python tool re-decodes them and ignores the advisory `decoded` objects, `limits` and `notes`, so a decoder bug can be fixed without losing data.

| Key | Content |
|---|---|
| `schema`, `schema_version` | `"blacktip-perf-log-export"` and 1. |
| `host_timestamp` | The host's time of the export. |
| `package_version`, `fw_ver`, `hw_name`, `scooter_type` | From the host: the panel knows the package version and the connection reports firmware and hardware; `scooter_type` comes from the existing settings read. |
| `limits` | Optional and advisory. Read at export time by the QML panel from the live configuration objects (`mMcConf`, `mAppConf`) and the package constants, where readable (see below). |
| `notes` | Optional advisory array of strings (below). The decoder ignores it. |
| `blocks` | An array with one object per block read. |

Each `blocks` object has: `id` (`"A"` or `"B"`), `state` (a reader state name: `empty`, `foreign`, `unknown_layout`, `in_progress`, `crc_mismatch`, `ok`), `layout_version`, `enabled`, `commit_seq`, `crc_stored`, `crc_computed` (computed by the panel from the stored slots), `slots_stored` (a raw map from slot number to value, the stored image of part 0), `slots_live` (a raw map of the unflushed RAM image of part 1) and, optionally, `decoded` (advisory). A slot that read `nil` (`0xFFFFFFFF` on the wire) is `null`. A disabled, uninitialised or foreign block is still exported with its state and whatever slots were readable. A block whose read was incomplete is never exported as complete (see the receiver rule in [Extraction](#extraction)).

**`limits` keys** (all optional; omitted when unreadable):

* `l_in_current_max_live_a`: the LIVE value of `l-in-current-max`. The package `conf-set`s it at run time (1.7 A during soft start, 22.8 A afterwards), so it is neither the stored factory value nor the effective cap.
* `package_current_cap_a`: the effective package cap, `MAX_CURRENT_BLACKTIP` or `MAX_CURRENT_CUDAX`.
* `l_temp_fet_start_c`: read by the QML panel from the VESC Tool configuration object (where readable), not through Lisp `conf-get` (which does not support it on 7.00). Advisory only and never used for decoding (the decoder uses slots 189 and 190). The panel and the report may compare it with the fixed 85 deg C and warn when it differs. Nothing in this specification assumes that the package can read a FET limit.
* `l_temp_motor_start_c`, `l_max_duty`, `l_battery_cut_start_v`, `l_battery_cut_end_v`, `max_erpm` (`MAX_ERPM_BLACKTIP` or `MAX_ERPM_CUDAX`), `imbalance_threshold_v` (`battery_imbalance_threshold_centi / 100`) and `si_battery_ah` (read from the configuration as `ui.qml` already does for `si_battery_ah`).
* `controller_id`: exported as read, without interpretation (its meaning is unexplained here). It is cheap to read: `conf-get 'controller-id` is supported on 7.00 (`lispBM/lispif_vesc_extensions.c` at both the bench hash and the `release_7_00` tip, listed in the LispBM README), and the panel can read `controller_id` from `mAppConf`.

The authoritative edge references of block B are the raw slots 189 and 190, which are exported with the slots.

**`notes`** (advisory strings the panel adds): block B keeps the bin edges it was started with, so export and clear block B before changing the package current cap or the motor temperature limit (the FET limit is not detectable; see [Bin edges](#bin-edges-binding)); logs recorded on the bench or in air are unlikely to be representative of real dive use, so clear both blocks before the first real dive.

The example below is the one used by the [protocol vectors](#worked-examples-and-protocol-test-vectors) and the [test vectors](#test-vectors); its values are illustrative (`limits` in particular). The `decoded` objects are abbreviated: a real export of block A lists all ten `per_speed_index` entries (indices 0 to 9, labels `reverse 2`, `untangle (reverse 1)`, `speed 1` to `speed 8`). A decoded field is `null` for a sentinel (for example `min_vin_running_v` when slot 77 field B is 32767), and a decoded value that equals a saturation maximum is flagged by the tool as saturated.

```json
{
  "schema": "blacktip-perf-log-export",
  "schema_version": 1,
  "host_timestamp": "2026-11-04T16:52:00+13:00",
  "package_version": "1.6.1",
  "fw_ver": [7, 0, 0],
  "hw_name": "60_MK5",
  "scooter_type": "blacktip",
  "limits": {
    "l_in_current_max_live_a": 22.8,
    "package_current_cap_a": 22.8,
    "l_temp_fet_start_c": 85.0,
    "l_temp_motor_start_c": 160.0,
    "l_max_duty": 0.95,
    "l_battery_cut_start_v": 32.0,
    "l_battery_cut_end_v": 30.0,
    "max_erpm": 4100,
    "imbalance_threshold_v": 0.3,
    "si_battery_ah": 20.0,
    "controller_id": 0
  },
  "notes": [
    "Block B keeps the bin edges it was started with: export and clear block B before changing the package current cap or the motor temperature limit.",
    "Logs recorded on the bench or in air are unlikely to be representative of real dive use: clear both blocks before the first real dive.",
    "A changed FET temperature limit is not detected by the package: block B stays referenced to 85 deg C until it is cleared."
  ],
  "blocks": [
    {
      "id": "A",
      "state": "ok",
      "layout_version": 1,
      "enabled": true,
      "commit_seq": 6,
      "crc_stored": 748037813,
      "crc_computed": 748037813,
      "slots_stored": {
          "64": 6, "65": 748037813, "66": 1112820807, "67": 257, "68": 12, "69": 47, "70": 32771, "71": 1,
          "72": 123000, "73": 12345, "74": 2764, "75": 48268582, "76": 8323293, "77": 131468403, "78": 0,
          "79": 0, "80": 0, "81": 0, "82": 0, "83": 0, "84": 3000, "85": 90000, "86": 0, "87": 6000,
          "88": 240000, "89": 300, "90": 36000, "91": 1512000, "92": 7200, "93": 54000, "94": 3240000,
          "95": 67500, "96": 0, "97": 0, "98": 0, "99": 0, "100": 0, "101": 0, "102": 0, "103": 0, "104": 0,
          "105": 9000, "106": 1890000, "107": 72000, "108": 0, "109": 0, "110": 12, "111": 0, "112": 95,
          "113": 420, "114": 1350, "115": 5100, "116": 1, "117": 0, "118": 65536, "119": 0, "120": 0, "121": 1,
          "122": 21000, "123": 102236506, "124": 46271721, "125": 6491664, "126": 98306
        },
      "slots_live": {
          "64": 6, "65": 748037813, "66": 1112820807, "67": 257, "68": 12, "69": 47, "70": 32771, "71": 1,
          "72": 123450, "73": 12400, "74": 2764, "75": 48268582, "76": 8323293, "77": 131468403, "78": 0,
          "79": 0, "80": 0, "81": 0, "82": 0, "83": 0, "84": 3000, "85": 90000, "86": 0, "87": 6000,
          "88": 240000, "89": 300, "90": 36000, "91": 1512000, "92": 7200, "93": 54000, "94": 3240000,
          "95": 67500, "96": 0, "97": 0, "98": 0, "99": 0, "100": 0, "101": 0, "102": 0, "103": 0, "104": 0,
          "105": 9000, "106": 1890000, "107": 72000, "108": 0, "109": 0, "110": 12, "111": 0, "112": 95,
          "113": 420, "114": 1350, "115": 5100, "116": 1, "117": 0, "118": 65536, "119": 0, "120": 0, "121": 1,
          "122": 21000, "123": 102236506, "124": 46271721, "125": 6491664, "126": 98306
        },
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
          "diagnostics": { "longest_store_ms_lower_bound": 3, "aborted_flushes": 2 }
        }
    },
    {
      "id": "B",
      "state": "ok",
      "layout_version": 1,
      "enabled": true,
      "commit_seq": 6,
      "crc_stored": 2019938442,
      "crc_computed": 2019938442,
      "slots_stored": {
          "128": 6, "129": 2019938442, "130": 1112820808, "131": 279, "132": 5, "133": 229376, "134": 40,
          "135": 1073741704, "136": 1200, "137": 1073749024, "138": 3000, "139": 1073768824, "140": 2500,
          "141": 1073776824, "142": 1800, "143": 1073777824, "144": 900, "145": 1073764324, "146": 600,
          "147": 1073759824, "148": 350, "149": 1073754074, "150": 0, "151": 0, "152": 3, "153": 12,
          "154": 1146970, "155": 400, "156": 5200, "157": 9100, "158": 7000, "159": 30000, "160": 9000,
          "161": 2500, "162": 300, "163": 12, "164": 12, "165": 0, "166": 2, "167": 7045158, "168": 40,
          "169": 2100, "170": 102236506, "171": 46268746, "172": 6491664, "173": 229740, "174": 1800,
          "175": 86835491, "176": 45482319, "177": 6721250, "178": 229738, "179": 2400, "180": 131400122,
          "181": 47677761, "182": 7475116, "183": 229742, "184": 900, "185": 42598540, "186": 44630357,
          "187": 5770468, "188": 363, "189": 7471954, "190": 52428800, "191": 0
        },
      "slots_live": {
          "128": 6, "129": 2019938442, "130": 1112820808, "131": 279, "132": 5, "133": 229376, "134": 40,
          "135": 1073741704, "136": 1200, "137": 1073749024, "138": 3000, "139": 1073768824, "140": 2500,
          "141": 1073776824, "142": 1800, "143": 1073777824, "144": 900, "145": 1073764324, "146": 600,
          "147": 1073759824, "148": 350, "149": 1073754074, "150": 0, "151": 0, "152": 3, "153": 12,
          "154": 1146970, "155": 417, "156": 5200, "157": 9100, "158": 7000, "159": 30000, "160": 9000,
          "161": 2500, "162": 300, "163": 12, "164": 12, "165": 0, "166": 2, "167": 7045158, "168": 40,
          "169": 2100, "170": 102236506, "171": 46268746, "172": 6491664, "173": 229740, "174": 1800,
          "175": 86835491, "176": 45482319, "177": 6721250, "178": 229738, "179": 2400, "180": 131400122,
          "181": 47677761, "182": 7475116, "183": 229742, "184": 900, "185": 42598540, "186": 44630357,
          "187": 5770468, "188": 363, "189": 7471954, "190": 52428800, "191": 0
        },
      "decoded": {
          "references": { "i_ref_a": 22.8, "t_fet_ref_c": 85.0, "t_mot_ref_c": 160.0 },
          "flags": { "enabled": true, "motor_reference_read": true, "imbalance_configured": true, "fresh_differs": false, "fallback_reference_present": true, "unknown_bits": 0 },
          "counter_164": { "value": 12, "label": "assumed 85 deg C limit" },
          "counter_165": { "value": 0, "label": "limit read from configuration (value in slot 190)", "limit_c": 160.0 },
          "pack_tag": 7, "session_seq": 5
        }
    }
  ]
}
```

### Defaults and data handling

* Logging is disabled by default for both blocks, and a fresh install or an upgrade does not enable either. Enabling is explicit and persistent (bit 0 of slot 67 for block A, bit 0 of slot 131 for block B), and is done through `set-enabled` per block.
* The data stays on the controller and in exports the user starts. The package never transmits the log, and the log is out of scope for any separate opt-in telemetry design.
* The log holds aggregates only (counts, sums, maxima), no time series, no position and no device identifier (the optional pack tag is a number the owner chooses). It can be cleared at any time with `clear-log`, and it is lost on a firmware update.

### User-facing statements

These are the statements the panel, the README and the report must carry (the README text is written later and must not contradict them).

* **When data is safe.** After `max(settle, interval - time since the last flush)` of rest, that is between about 5 s and at most about 60 s (normally near 5 s when the previous flush is more than a minute old; the 60 s worst case applies when a flush happened shortly before the last run). A five-click shutdown flushes first. See [Data loss by power-off style](#data-loss-by-power-off-style) for the other cases (the idle auto-off of a modified MK5, battery removal and a BMS cut-off).
* **Transport.** On the production DPV the log is read, exported, cleared and enabled through VESC Tool over Bluetooth; USB applies only to units that expose it. Extraction is after the dive. Bluetooth throughput facts and the pacing and retry rules are in [Extraction](#extraction) and are provisional until measured on the DPV.
* **Bench and in-air data.** Logs recorded while the unit is run on the bench or in air are unlikely to be representative of real dive use, so both blocks should be cleared (`clear-log`) before the first real dive. (This is a data-quality remark only.)
* **Stored references.** Block B keeps the bin edges it was started with. Export and clear block B before any trial that changes the package current cap (`I_REF`) or the motor temperature limit (`T_MOT_REF`), which the package can see (flag bit 3 shows a difference at boot). This does NOT apply to the FET temperature limit, which the package can neither read nor detect: changing `l-temp-fet-start` leaves block B's FET bins and counter 164 referenced to 85 deg C, and remembering that is the user's discipline. The panel and the report may warn when the configured FET limit differs from 85 deg C.
* **Defaults.** Both blocks are off by default.

### Test vectors

These are for the unit tests of the later implementation (pure functions: packing, saturating add, framing and CRC). All were computed with Python (`zlib.crc32`, `struct.pack(">I", ...)`) and checked against a direct port of `crc32_with_init`; the block A images are also asserted by the script at the end of [Block B test vectors](#block-b-test-vectors).

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

**Decoded example image.** The 63 raw slot values for slots 64 to 126 are the block A `slots_stored` map in the export example above. It decodes as shown there (block A is unchanged by the amendments of 5 Nov 2026, and its vectors below are unchanged); in particular index 4 (speed 3) has `on` = 36000 ds, `cur` = 1512000 (mean 1512000 / (10 × 36000) = 4.2 A) and `def` = 7200 (mean 10 × 7200 / 36000 = 2.0 eRPM), index 5 (speed 4) has `on` = 54000, `cur` = 3240000 (mean 6.0 A), `def` = 67500 (mean 12.5 eRPM), and slot 118 (value 65536) is `fault_5` = 2 and `fault_6` = 0.

| Check | Value |
|---|---|
| CRC input | slots 66 to 126, 244 bytes, big-endian; begins `42 54 4C 47 00 00 01 01 00 00 00 0C 00 00 00 2F` |
| CRC32 of the populated image | `0x2C9626B5` |
| Stored slot 65 (masked) | 748037813 (`0x2C9626B5`) |
| Cleared image (slot 66 = magic, slot 67 = 257, slots 77 and 124 = 32767, all other slots 0), CRC32 | `0x6178A90A`; stored slot 65 is 1635297546 (`0x6178A90A`) |
| Populated image with slot 100 changed to 70196 (`0x00011234`, a hybrid of two values) | CRC32 `0x7000419C`, masked 1879064988, which differs from the stored 748037813: state `crc_mismatch` |
| Populated image with `commit_seq` 7 and an unchanged, matching CRC | state `in_progress` |

Mean-value formulas use the units above (`on` in ds, `cur` in 0.01 A·s, `def` in eRPM·s); a block with `on` = 0 has no mean (`null`).

### Block B: extended log (layout v1)

Status: specification, like the rest of this section. Block B is a second, optional record that carries detail the frozen block A has no room for: a supply-current histogram with supply sag per bin, per-speed-index time at the duty ceiling, duty and FET temperature histograms, derating exposure, battery-imbalance events at rest, and a ring of the last four sessions. It uses EEPROM slots 128 to 191.

#### Independence and scope

* Block A (slots 64 to 126, layout v1) is frozen. Its slot map is unchanged. The only edits to block A text made when block B was added are the block-state rules ([Reader states](#commit-protocol-and-integrity)) and cross-references.
* Block B is independently valid. It has its own header (`commit_seq`, CRC, magic, layout version and flags) and its own commit. A valid block A never depends on block B, and block B never depends on block A. Block B may be enabled without block A, and a flush of one block never rewrites a slot of the other.
* Both blocks are written only by the one sampler thread under the one [flush gate](#flush-gate), so slots 64 to 126 and 128 to 191 each still have exactly one writer. Within one flush block A is committed first and then block B, each completely before the next starts (see [Flush ordering](#flush-ordering)).
* The [safety statement](#safety-statement) applies to block B unchanged, with one addition to its list of reads: block B reads the existing balance-wire globals by polling (see [Imbalance counters](#imbalance-counters)). It adds no hook into the balance code and no further hook anywhere else. While block B is disabled (the default) it performs no EEPROM writes.
* Reset Defaults, the settings migrations and the settings UI write path never touch slots 128 to 191, exactly as for block A.
* Extraction (read, clear, enable and pack-tag opcodes) and the export schema cover both blocks and are specified in [Extraction](#extraction) and [Export format](#export-format).

#### Storage and ownership

* Block B owns slots 128 to 191 (64 slots, 256 bytes) by contract. Slots 192 to 255 are unassigned and reserved: not read and not written. Slots 0 to 63 and 127 are untouched.
* Firmware 7.00 provides 256 custom slots (0 to 255); the source citations, the hardware confirmation on the rig (slot 255 reads `nil`, slot 256 raises an eval error, slots 128 to 255 all `nil`; the sweep is bench-reported, 5 Nov 2026, rig only) and the firmware gate are in [Firmware gate and slot capacity](#firmware-gate-and-slot-capacity). The production HW 60 MK5 DPV has not been read, so its slots 128 to 255 are unverified; the block state rules below (foreign data is never overwritten silently) cover that case.
* Blocks A and B together are 127 log slots, which is 254 EEPROM records of live data (each 32-bit slot is stored as two 16-bit records). The consequence for page-transfer frequency (about 51 flushes per transfer instead of about 82) and for flush time is in [Page transfers and wear](#page-transfers-and-wear) and [Timing figures](#timing-figures).

#### Block B slot map

Header and integrity first, then data. Slots 130 to 191 (62 slots, 248 bytes) are the CRC-covered image. Encodings are those of block A (see [Encodings and number handling](#encodings-and-number-handling)): U31 is a non-negative 31-bit value, P15(A, B) is two 15-bit fields in one slot, and every add saturates and none wraps. "Sample" means one 5 Hz sampler iteration that satisfied the stated condition.

| Slot | Name | Type | Unit and notes |
|---|---|---|---|
| 128 | `b_commit_seq` | U31 | Odd while a flush is in progress, even when committed. Not CRC-covered. Advances modulo 2^31 as for block A. |
| 129 | `b_crc` | CHECK | `crc32(slots 130..191) & 0x7FFFFFFF`. Not CRC-covered. |
| 130 | `b_magic` | U31 | `0x42544C48` ("BTLH"), decimal 1112820808. Block A's magic is `0x42544C47` ("BTLG"). |
| 131 | `b_layout_flags` | U31 | Bits 8 to 15: layout version (1). Bits 0 to 4: flags (below). Bits 5 to 7 are reserved and written 0. Other bits 0. |
| 132 | `session_seq` | U31 | Count of controller sessions with motor use, as seen by block B. |
| 133 | `pack_tag`, reserved | P15(A, B) | A: pack tag, 0 is unset. B: reserved, written 0. |
| 134 to 149 | current and sag table | U31 × 2 per bin | 8 bins. Bin `b` uses slot `134 + 2b` (`n`) and `135 + 2b` (`sag_sum`). `n` is the number of samples. `sag_sum` is offset-binary (bias 2^30) in 0.1 V × samples, where sag is `v_ref - v_in`, signed. Both saturate; `sag_sum` saturates at both ends. |
| 150 to 154 | `duty_ge_095_by_index` | P15(A, B) | Seconds with `\|duty\| >= 0.95` per speed index. Slot `150 + floor(i / 2)`; A holds even index `i`, B holds odd index `i` (the block A `at_limit` convention). Saturates at 32767 s per index (about 9.1 hours). |
| 155 to 158 | `duty_hist` | U31 × 4 | Samples with `\|duty\| < 0.8`, bins `[0, 0.2)`, `[0.2, 0.4)`, `[0.4, 0.6)`, `[0.6, 0.8)`. Duty at or above 0.8 is covered by block A's slots 113 to 115. |
| 159 to 163 | `fet_hist` | U31 × 5 | Samples per FET temperature bin 0 to 4 (edges derived from slot 189, see [Bin edges](#bin-edges-binding)). |
| 164 | `derate_fet` | U31 | Samples with FET temperature at or above the FET reference `T_FET_REF`, which is the fixed constant 85 °C on 7.00 (the package never reads a FET limit). An ASSUMED-LIMIT counter: it is the time at or above 85 °C, not the time in derating if the configured FET start differs. Always equals slot 163. Decoder label (binding, never depends on a flag): "assumed 85 deg C limit". |
| 165 | `derate_motor` | U31 | Samples with motor temperature at or above `T_MOT_REF` (slot 190). Decoder label (binding on the decoder, the panel and the report), from flag bit 1 of slot 131: bit 1 = 1: "limit read from configuration (value in slot 190)"; bit 1 = 0: "assumed 160 deg C factory fallback, configured limit unknown". |
| 166 | `imb_latch_events` | U31 | Imbalance latch-set events (below). |
| 167 | `imb_max`, `imb_last` | P15(A, B) | A: largest settled `\|imbalance\|`, 0.01 V. B: the most recent settled `\|imbalance\|`, 0.01 V. |
| 168 | `imb_over_warn` | U31 | Settled readings with `\|imbalance\|` over the warning threshold. |
| 169 to 188 | session ring | 4 records × 5 slots | Record `r` starts at slot `169 + 5r`, `r = (session_seq - 1) mod 4`. See [Session ring](#session-ring). |
| 189 | `ref_1` | P15(A, B) | A: `I_REF`, 0.1 A. B: `T_FET_REF`, 0.1 °C, the fixed constant 850 on 7.00. Zero is unset. |
| 190 | `ref_2` | P15(A, B) | A: `T_MOT_REF`, 0.1 °C (read from the configuration, or the fallback 1600; flag bit 1 says which). B: reserved, written 0. |
| 191 | reserved | U31 | Written 0. Slots 189 to 191 are all CRC-covered. |

The block has 64 slots: 4 header slots (128 to 131) and 60 data slots (132 to 191).

##### Flags (slot 131, bits 0 to 4)

Redefined on 5 Nov 2026 (owner decision; layout version stays 1, nothing had shipped, so no migration). This replaces the first block B wording, in which bit 1 covered both derating limits and bit 4 could be taken as a motor-reference status.

| Bit | Meaning |
|---|---|
| 0 | Block B enabled. |
| 1 | The motor derating start reference `T_MOT_REF` (slot 190) was obtained by a successful `conf-get 'l-temp-motor-start` inside `trap` (a number in 30.0 to 250.0 °C), not the 1600 fallback. It says nothing about the FET reference, which is never read on 7.00 because `conf-get` of a FET limit does not exist there. |
| 2 | Imbalance detection was configured (`battery_imbalance_threshold_centi > 0`) when the block was last written. |
| 3 | A fresh read or derivation of `I_REF` or `T_MOT_REF` in this run differs from the stored references (see [Bin edges](#bin-edges-binding)). It compares only `I_REF` and `T_MOT_REF` on 7.00. |
| 4 | At least one edge reference is a fallback constant. On 7.00 it is ALWAYS 1, because `T_FET_REF` is the fixed constant 850, so it carries no information about the motor reference: decoders, the panel and the report use bit 1 for that and never bit 4. |

Bits 5 to 7 are reserved and written 0. A decoder that finds one of them set decodes the block normally (the layout version still says 1), reports the state as usual and adds a note that unknown flag bits are set; it does not interpret them.

Enabled layout-1 value with no other flag is 257. The realistic 7.00 pattern, with the motor reference read successfully, is bit 0, bit 1 and bit 4 (275, or 279 with imbalance detection configured); with the motor read failed it is 273 (277 with imbalance). Bit 1 is set or cleared as follows:

* At every fresh motor-reference read (sampler thread start with no stored references, `set-enabled`, `clear-log`) bit 1 is set to 1 when the read succeeded and was accepted, and to 0 when it failed (a trap error, `nil`, a non-number, a value below 30.0 or above 250.0 °C, so the fallback 1600 was used).
* At boot, when block B is valid and its stored references are non-zero, the stored-reference-wins rule applies to the flag too: bit 1 (like bit 4) is CARRIED from the stored header, so it keeps describing how the stored reference was obtained. It is not recomputed from the fresh read. Bit 3 covers any difference between the fresh read and the stored `I_REF` or `T_MOT_REF`, as before.
* With zero stored references, the fresh read and its status are used.
* Consequence: a stored 1600 that came from the fallback (bit 1 = 0) stays labelled "assumed" even if a later fresh read succeeds with exactly 160.0 (the values are equal, so bit 3 is clear), until the user exports and clears block B (`clear-log` re-reads and sets bit 1 from that read).
* Because bit 1 now records the motor read separately, layout v1 does distinguish a successful read of exactly 160.0 °C (slot 190 = 1600, bit 1 = 1) from the fallback (slot 190 = 1600, bit 1 = 0).

On firmware 7.00 the FET reference cannot be read at all (see [Derating limits and conf-get names](#derating-limits-and-conf-get-names)); counter 164 is therefore always labelled "assumed 85 deg C limit". Counter 165 is labelled from bit 1 as in the slot table, with the motor limit value from slot 190.

##### Sag table

* Counted only while the motor is loaded: `speed != SPEED_OFF`, `soft_start_active = 0`, `safe_start_status` is not `'running`, and `|duty| >= DUTY_AT_REST_THRESHOLD` (0.02).
* Bin `b = min(7, floor(|I10| / step))`, where `I10` is the absolute input current in 0.1 A (rounded half up) and `step` is derived from `I_REF` (see [Bin edges](#bin-edges-binding)). The last bin is open ended.
* `v_ref` is the most recent at-rest supply voltage: a `(get-vin)` sample taken while `speed == SPEED_OFF` has held continuously for at least `LOG_VREF_IDLE_S` (2 s) with `|get-rpm| < LOG_REST_ERPM_MAX` and `|get-duty| < LOG_REST_DUTY_MAX`. That approximates the open-circuit voltage. Until such a sample exists in a controller session, `v_ref` is the first valid `get-vin` reading of the session.
* Sag is computed in integer 0.1 V units: `sag = vref10 - vin10`, both rounded half up. Each loaded sample does `n += 1` and `sag_sum += sag` in the bin.
* Rationale: the bins give the current histogram; sag per bin gives a V-I curve, and a pack resistance estimate from the slope between bins, comparable across packs and independent of the speed mapping; subtracting `v_ref` removes most state-of-charge drift.
* Saturation: `n` is U31 (about 13.6 years at 5 Hz). `sag_sum` stores `clamp(total + 2^30, 0, 2^31 - 1)`, so the representable total is -1073741824 to +1073741823; decoding is `stored - 2^30`. A cleared bin has `n = 0` and `sag_sum` stored as 1073741824. Mean sag in V is `(stored - 2^30) / (10 × n)`; a bin with `n = 0` has no mean.

##### Derating exposure

Counters 164 and 165 count samples with the running motor (`speed != SPEED_OFF`) where the FET temperature is at or above `T_FET_REF / 10` (the fixed 85 °C on 7.00, so counter 164 counts time at or above an ASSUMED limit) and the motor temperature at or above `T_MOT_REF / 10`. Both use the stored references of slots 189 and 190, not a fresh read. In the vendored firmware, derating is gradual: below `start + 0.1` the limits are kept, between start and end the permitted current is mapped linearly from the full limit down to zero, and above `end - 0.1` the controller stops with an over-temperature fault (`motor/mc_interface.c:2337` to `2349` for the FET and `:2363` to `2375` for the motor, at the bench firmware hash). Counting at or above the start value therefore means "derating possible or active". It is a conservative superset of the controller's own condition (start + 0.1). Whether the firmware compares the same filtered value that `(get-temp-fet)` returns (`mc_interface_temp_fet_filtered`, `lispBM/lispif_vesc_extensions.c:2260`) was not traced and is unverified.

A motor temperature sensor is fitted on the DPV (human-confirmed, 5 Nov 2026); the plausibility of its reading on the production unit is still to be confirmed with one at-rest read of `(get-temp-mot)` (no motor run is needed or wanted). `ui.qml` configures `m_motor_temp_sens_type` 0 (`TEMP_SENSOR_NTC_10K_25C`) in the Blacktip defaults. This is not claimed for other hardware or scooter types. With the factory 160 °C start value, derating is essentially unreachable (inference), so counter 165 is expected to stay at or near zero in normal use; how it is labelled is fixed by flag bit 1 (see [Flags](#flags-slot-131-bits-0-to-4)).

##### Imbalance counters

Imbalance only means something when the balance-wire feature is configured (`imbalance_detection_enabled`, that is `battery_imbalance_threshold_centi > 0`). The package computes imbalance at rest only: `update_lower_voltage_smooth` holds its averages while the motor runs and for `BALANCE_SETTLE_SAMPLES` after it stops (`balance_smoothing_held = 1`). There is no under-load imbalance, and block B does not invent one. Block B polls the existing globals and functions at its 5 Hz rate, no hook into the balance code:

* "Settled" is the condition `update_imbalance_latch` itself uses: detection enabled, `balance_smoothing_held = 0` and `lower_voltage_smooth > 0.1`. Only settled polls update counters 167 and 168.
* `imbalance` is `(get_battery_imbalance_voltage)`, in volts, positive when the upper pack is higher. Slot 167 stores `round(100 × |imbalance|)`, which is the unit of `battery_imbalance_threshold_centi`. Field A keeps the maximum and field B the most recent settled value.
* Slot 168 adds 1 for each settled poll where `(get_battery_imbalance_warning)` is not `BATTERY_IMBALANCE_WARN_NONE` (that is, `|imbalance|` exceeds `(battery_imbalance_threshold_voltage)`). It counts polls (5 Hz), not events or time, and there is no stored count of all settled polls, so a decoder cannot form a fraction of at-rest time.
* Slot 166 adds 1 when the polled `battery_imbalance_latched` becomes non-zero from a different polled value (0 to 1, 0 to 2, 1 to 2, 2 to 1). The previous polled value is 0 at boot, and the latch is RAM-only, so a persistent imbalance counts once per controller start. Polling is expected to be sufficient: the latch is set only from a settled reading and cleared only after the smoothed `|imbalance|` falls below half the threshold, which the 5 s exponential average cannot do within one 0.2 s poll interval. That is inference from the averaging constants, not a measurement.

##### Session ring

Four records of five slots, record `r` at `169 + 5r` with `r = (session_seq - 1) mod 4`. Fields:

| Offset | Content |
|---|---|
| 0 | Motor-on seconds, U31. |
| 1 | P15: A is mAh, B is Wh × 10 (0.1 Wh). |
| 2 | P15: A is maximum FET temperature, offset-binary 0.1 °C as in block A (0 means no sample); B is minimum supply voltage in 0.1 V (32767 means no sample). |
| 3 | P15: A is maximum absolute input current, 0.1 A; B is maximum absolute eRPM, unscaled. |
| 4 | P15: A is `pack_tag` (slot 133 at the last flush); B is the start `v_ref`, 0.1 V (0 means unset). |

* A session is one controller start: battery insertion to removal on an unmodified MK5, roughly a dive day. It begins at the first `running` sample the block B collector sees after boot, enabling or an explicit clear. `session_seq` is then incremented (saturating), record `r` is cleared (all fields 0 except minimum voltage 32767), and the start `v_ref` and `pack_tag` are set. The record is then updated in RAM at every running sample and written at every flush.
* mAh and Wh are the block B collector's own accumulation of `Δget-ah × 1000` and `Δget-wh × 10` (negative deltas discarded, as for block A) since the collector's first sample in the controller session. They include any idle draw before the first motor start. Maxima and the minimum are over running samples, as for block A's extremes.
* Because the clear happens at session start, a clear-log in the middle of a controller session makes the next running sample open a new record numbered 1; that first record covers only the time since the clear.
* Reading: the newest session is `session_seq`; record `(session_seq - k - 1) mod 4` holds session `session_seq - k` for `k = 0..3` while `session_seq - k >= 1`. `session_seq` saturates at 2147483647 (not reachable in practice) and the ring then stays on the same record.
* Units fit 15-bit fields: charge saturates at 32.767 Ah and energy at 3276.7 Wh (the same limits as block A's last-session slot 123); the Blacktip eRPM maximum is `MAX_ERPM_BLACKTIP` 4100 (Cuda X 7100), well under 32767, so no scale factor is needed; 0.1 V and 0.1 A fields reach 3276.7 V and A.

##### Other per-sample rules

| Update | Condition |
|---|---|
| `duty_ge_095_by_index[speed]` += `dt` seconds | `steady` and `\|duty\| >= LOG_DUTY_SATURATED` (0.95) and `speed` in 0..9 |
| `duty_hist[b]` += 1, `b = floor(\|duty\| / 0.2)` | `steady` and `\|duty\| < 0.8` |
| `fet_hist[b]` += 1 and `derate_fet`, `derate_motor` | `running` (not only `steady`); `b` from the FET bins |
| Ring and session maxima, minima | `running` |

`running`, `steady` and `dt` are defined in [Sampling](#sampling); `steady` excludes soft start, so the duty histogram follows block A's duty bands. Nil or NaN readings skip that metric for the sample. The histogram counts samples, not time; converting to seconds uses the nominal 0.2 s period. When both blocks have been enabled for the same time the sum over indices of `duty_ge_095_by_index` agrees with block A's slot 113 (ds) to within rounding.

#### Bin edges (binding)

The edges are decided. They are derived from three references stored in slots 189 and 190, so every block is self-describing and the decoder never hard-codes an edge. Do not re-choose them in an implementation.

**Evidence** (public sources only): the Blacktip defaults in `ui.qml` (`apply_defaults_blacktip`) set `l_in_current_max` 23 A, `l_temp_motor_start` 160 °C and `l_temp_motor_end` 180 °C, and `l_battery_cut_start` 32 V with `l_battery_cut_end` 30 V; the package constants are `MAX_CURRENT_BLACKTIP` 22.8 A, `MAX_CURRENT_CUDAX` 46 A, `MIN_CURRENT_BLACKTIP` 1.7 A and `MIN_CURRENT_CUDAX` 0.35 A; the firmware 7.00 defaults, which `ui.qml` does not override, are `l_temp_fet_start` 85 °C, `l_temp_fet_end` 100 °C and `l_max_duty` 0.95 (`motor/mcconf_default.h:93` and `:102` to `:105` at the bench firmware hash; no override was found in the headers of the 60-class boards). The factory FET derating start of 85 °C is therefore the firmware default: `apply_defaults_blacktip` sets no `l_temp_fet_*` value (`ui.qml` only reads `l_temp_fet_start` and `l_temp_fet_end` for the temperature gauges).

**The effective current cap is the package constant, not the stored value.** The package itself calls `conf-set` on `l-in-current-max` at run time: `MIN_CURRENT_*` at the start of soft start and `MAX_CURRENT_*` when soft start completes. Nothing restores the stored value. A `conf-get` of `l-in-current-max` therefore returns 23, 1.7 or 22.8 depending on timing and must NOT be used as the current reference. The stored 23 A is not the effective running cap either; analysis must use `I_REF`.

**References** (integer, 0.1 units):

| Reference | Value | Fallback |
|---|---|---|
| `I_REF` | `round(10 × MAX_CURRENT_BLACKTIP)` = 228, or 460 for Cuda X (`MAX_CURRENT_CUDAX`), chosen by `scooter_type`. No `conf-get`. | None needed. |
| `T_FET_REF` | The FIXED constant 850 (0.1 °C, 85 °C, the factory and VESC default). The package never reads a FET limit: `conf-get` of `'l-temp-fet-start` is not supported on firmware 7.00 (see [Derating limits and conf-get names](#derating-limits-and-conf-get-names)). | Not applicable. |
| `T_MOT_REF` | `round(10 × conf-get 'l-temp-motor-start)` | 1600 |

`round` is `floor(x + 0.5)`. `T_MOT_REF` is accepted only if `conf-get 'l-temp-motor-start` returns a number in 30.0 to 250.0 °C (so `round(10 × value)` is at most 2500, which fits a P15 field); otherwise the fallback 1600 is used and flag bit 1 is 0. The factory motor derating start of 160 °C (and the Blacktip's 160/180 °C configuration) is inside that range, and an earlier draft's 30.0 to 150.0 range would have rejected it. A failed read is caught with `trap`; an unrecognised parameter makes `conf-get` raise an error ("Parameter not recognized", `lispBM/lispif_vesc_extensions.c:4615`), which `trap` returns as an error result. No FET range exists because no FET value is ever read. Flag bit 4 is always 1 on 7.00 because of the FET constant.

**When references are read.** At sampler thread start with no stored references, at set-enabled and at clear-log, so a cleared block records the then-current limits and the status of the motor read (flag bit 1, see [Flags](#flags-slot-131-bits-0-to-4)). At boot, when block B is valid and a stored reference field is non-zero, the stored reference wins: the bins stay consistent with the accumulated counts, and flag bit 1 is carried from the stored header with it. If a fresh derivation or read of `I_REF` or `T_MOT_REF` differs from the stored value, flag bit 3 is set to 1 and the derating counters keep using the stored references. A zero stored field is unset and the fresh value (and its read status) is adopted at the next flush (bit 3 stays 0 for that field). Consequence for the PACKAGE-visible limits: changing the package current cap (`I_REF`) or the motor temperature limit (`T_MOT_REF`) requires a clear-log of block B (export first) to re-reference, and flag bit 3 shows a difference at boot. The rule does NOT apply to the FET limit, which the package can neither read nor detect: changing `l-temp-fet-start` leaves block B's FET bins and counter 164 referenced to 85 °C, and remembering that is the user's discipline. Tuning trials must follow this rule.

**Edges** (integer arithmetic in 0.1 units, no float maths added to the sampling path):

* Current: `step = 5 × ((I_REF + 39) div 40)`, which is `5 × ceil(I_REF / 40)` in 0.1 A, and `bin = min(7, floor(|I10| / step))`. Blacktip: `I_REF` 228 gives `step` 30 (3.0 A) with edges 3, 6, 9, 12, 15, 18 and 21 A; bin 7 is at or above 21.0 A and contains the 22.8 A cap and the stored 23 A. Cuda X: `I_REF` 460 gives `step` 60 (6.0 A). Rationale: `8 × step` is at least `I_REF`, so the 8 bins span 0 to the cap with a round step; 22.8 and 23 give the same step, so the result does not depend on which of the two configuration variants is in the unit; samples in soft start (limited to 1.7 A) are already excluded, so no bin is wasted on them; the top bin is the "at the limit" bin, which is what a tuning analysis needs.
* FET temperature: edges are `T_FET_REF - 450`, `- 300`, `- 150` and `- 0` (0.1 °C), and `bin` is the number of edges that are less than or equal to the reading (0 to 4), signed compare, no clamp. With the fixed `T_FET_REF` 850 the edges are fixed at 40, 55, 70 and 85 °C: below 40, 40 to 55, 55 to 70, 70 to 85 and 85 or above (the formula stays general so a later layout version could supply another reference). Rationale: the top bin starts where derating can begin (counter 164 equals it by construction and is a cross-check, labelled "assumed 85 deg C limit"), 15 °C steps give a coarse headroom picture below it; an underwater water-cooled unit is expected to sit mostly in the lowest bins (inference, not measured); the session ring's maximum FET temperature gives the fine value, so no further bins are added. If real logs show bin 0 holding nearly everything, a later layout version may refine it; do not change it now.
* Motor temperature: no histogram, only counter 165 against `T_MOT_REF` (160 °C factory, so derating is essentially unreachable), labelled from flag bit 1 as described in the slot table. See the sensor remark above.
* Duty: the bins stay fixed dimensionless constants 0.2, 0.4, 0.6 and 0.8. The factory `l_max_duty` is 0.95 (firmware default, not overridden by `ui.qml`), so block A's frozen 0.95 threshold is the controller's own ceiling. If `l-max-duty` were ever tuned below 0.95 the saturation counters would stop triggering, so the export records `l-max-duty` (in `limits`, see [Export format](#export-format)) rather than binning on it.
* The edges are identical for both configuration variants of the Blacktip.

#### Derating limits and conf-get names

Verified against the vendored bldc source at the bench firmware hash (`1fee61fb7ebc79745a359a0ee0c056cfce39a043`) and, for the name list, at the tip of its `release_7_00` checkout (`9483d8cf6ec97b92ddd203c372745ba518a3b12f`):

| Parameter | `conf-get` symbol | Result |
|---|---|---|
| Motor derating start | `'l-temp-motor-start` | Supported. Symbol registered at `lispBM/lispif_vesc_extensions.c:508` (tip: `:514`), read at `:4371` (tip: `:4403`), listed in `lispBM/README.md:3954` (tip: `:4038`). |
| Motor derating end | `'l-temp-motor-end` | Supported (`:510`, `:4373`, `README.md:3955`). |
| FET derating start | `'l-temp-fet-start` | NOT supported on 7.00. No such symbol is registered in `lispif_vesc_extensions.c` (at either revision) and `README.md` lists none. The only `l_temp_fet_*` lines in that file (`:4320` to `:4324`) fill the default-configuration branch and are never read back. An unknown symbol raises "Parameter not recognized" (`:4615`). The C-library interface (`lispif_c_lib.c:460`) has the field, but that is not reachable from LispBM and is out of scope here. |
| FET derating end | `'l-temp-fet-end` | NOT supported, as above. |
| Input current limit | `'l-in-current-max` | Supported (`:482`, `:4345`); not usable as the current reference (see above). |

Consequences of the missing FET symbol (amended 5 Nov 2026; the human accepted option (a): the FET reference is a fixed constant):

* `T_FET_REF` is the FIXED constant 850 (0.1 °C, 85 °C, the factory and VESC default). The package never reads a FET limit, and nothing in this specification assumes that a `conf-get` of a FET limit works. The 85 °C is the firmware 7.00 default (`mcconf_default.h:102`) and the Blacktip defaults in `ui.qml` do not change it, so it is correct for an unmodified unit. A user who changed the FET limit in VESC Tool is not detected.
* Flag bit 4 ("at least one edge reference is a fallback constant") is therefore always 1 on firmware 7.00, because of the FET constant, and it carries no information about the motor reference. Flag bit 1 is redefined (see [Flags](#flags-slot-131-bits-0-to-4)) and no longer concerns the FET reference.
* Counter 164 is an ASSUMED-LIMIT counter: time at or above 85 °C, not time in derating if the configured FET start differs. The FET histogram edges are fixed at 40, 55, 70 and 85 °C. Bits 5 to 7 stay reserved, written 0.
* Layout v1 does distinguish a successful read of exactly 160.0 °C from the 1600 fallback, because bit 1 now records the motor read. A later layout version could add a FET status bit and/or a host-supplied limit if a firmware exposes the FET limit or the need arises; no such mechanism is planned (a design in which the QML panel pushes limits to the package was considered and declined).
* The 85 °C and 160 °C starting values are the Blacktip factory defaults. Note that the firmware default for the motor start is 85 °C (`mcconf_default.h:108`), not 160, so the fallback 1600 is a Blacktip-specific constant.
* The export's `l_temp_fet_start_c` is read by the QML panel from the VESC Tool configuration object, not through `conf-get`, and is advisory (see [Export format](#export-format)).

#### Block states

A block reader (the package at start, the host on export) classifies each block independently from its header slots (64 to 67 for block A, 128 to 131 for block B):

| State | Condition | Reader state name |
|---|---|---|
| uninitialised | All four header slots read `nil`. | `empty` |
| foreign | At least one header slot is non-nil and the magic slot (66 or 130) does not hold the block's magic. Never overwritten silently; the block stays disabled and is reported until an explicit clear. | `foreign` |
| unknown layout | Magic matches, layout version is not 1. Reported and left untouched. | `unknown_layout` |
| torn | Magic and layout match and `commit_seq` is odd (or reads `nil`), or `commit_seq` is even and the recomputed masked CRC differs from the stored CRC (or the stored CRC or a covered slot reads `nil`). | `in_progress`, `crc_mismatch` |
| valid | `commit_seq` is even, the CRC matches and bit 0 of the flags is 1. | `ok` |
| valid-disabled | As valid, but bit 0 of the flags is 0. The block is intact and not collecting. | `ok` |

The same rules apply to block A (header slots 64 to 67, magic slot 66, flags slot 67); its slot map is unchanged. One behavioural consequence for block A: a range whose slot 66 is `nil` but where slot 64, 65 or 67 holds a value is now `foreign`, where the block A rules as first written classified it as `empty`. At boot a torn block is loaded as found and committed by the next flush (block B has no integrity counter; the unverified-at-load condition is reported through the read status, which is specified with extraction). A foreign block or one with an unknown layout is never loaded or written by the collector.

#### Collector and size budget

Implementation guidance (the code is specified elsewhere):

* One preallocated RAM image buffer per block, with the same slot numbering as the stored image, so that the CRC, the changed-slot flush and read-log iterate generically. A stored mirror of equal size per block detects changed slots.
* Sizes: block A's image is 63 slots (252 bytes) and block B's is 64 slots (256 bytes), so the two images plus the two mirrors total 1016 bytes (about 1.0 KB). Against 28 KiB of LispBM array memory (the figure was supplied with the design and is an estimate, not verified here) that is about 3.5 %. Float remainders and other small state are extra.
* RAM accumulators hold exact totals. The stored P15 and U31 values are derived from them at flush and totals are reloaded from the stored image at boot, so sub-unit fractions of the second-, charge- and energy-based fields are lost at boot: at most 1 unit per field per power cycle (1 s, 1 mAh, 0.1 Wh). The count-based fields (samples, events, sag sums) are integers and lose nothing.
* A small set of generic helpers (saturating add to a slot, bin lookup against an edge constant, P15 get and set) driven by constant tables, not one `defun` per field. No debug string building in the sampling loop.
* Lisp size budget: the main build is 106,110 B (81.0 % of the 131,064 B limit) and the rig build with the test fixture is 117,835 B (89.9 %). The rig build is 11,725 B larger than the main build. The whole log feature (all code changes together) is allocated 11,000 B, which puts the rig build at 128,835 B (98.3 %). Keeping to the 98 % target of 128,443 B would leave 10,608 B. Per-change allocations are set in the code changes.
* **Heap budget (proposal; the figures are bench numbers, not a design limit).** The LispBM heap on the HW 60 rig is 22024 B, which is 2753 cons cells. The 37 KB bench probe alone uses 2526 cells at idle, with 227 free. The production package's own heap use is UNKNOWN and cannot be scaled from the probe: the 106 KB package already runs, so heap use does not scale with source size. Every code change reports the free cons cells before and after (estimated with the native REPL harness; the authoritative on-hardware `:info` figure is a human step in the validation work). The proposed minimum is at least 500 free cons cells after the whole log feature on the production build. The rig build with the test fixture is larger and may be tighter; that is a risk to flag, not to fix by trimming the log.

#### Block B test vectors

These are for the unit tests of the later implementation (pure functions: packing, offset-binary, bin lookup, edge derivation, flag and reference derivation, ring index, block classification and the extraction frames). Every value below was computed with the reference script at the end of this subsection, which asserts all of them and prints `all vectors ok`. Every CRC was verified by a second method: the script computes it with Python `zlib.crc32` and with a bitwise port of the firmware's `crc32_with_init` and asserts that they agree. The P15, offset-binary, bin and frame values were also spot-checked by hand arithmetic. CRC semantics are those of block A (`crc32` builtin, `init = 0`, each slot four bytes big-endian, masked to 31 bits for storage). Nothing here was run on hardware or on the VESC LispBM runtime.

**Changes of 5 Nov 2026** (flag redefinition, motor range 30.0 to 250.0 °C, fixed FET reference). Every vector that contains a slot 131 value, or a CRC over one, was recomputed or re-stated:

| Vector | Status |
|---|---|
| Populated block B image, now flags 279 (bits 0, 1, 2, 4: realistic 7.00 pattern) | Changed: slot 131 277 to 279; CRC32 `0x8507C610` to `0x7865D08A`; slot 129 84395536 to 2019938442; first CRC input bytes `... 00 00 01 15 ...` to `... 00 00 01 17 ...`. The old image (flags 277, bit 1 = 0) is kept as a variant and its values are unchanged. |
| Cleared image with flags 273 (motor read failed, bit 1 = 0) | Unchanged: CRC32 `0xF8B2DEF6`, slot 129 2024988406 |
| Cleared image with flags 275 (motor read accepted, bit 1 = 1) | New: CRC32 `0x05D0C86C`, slot 129 97568876 |
| Populated image with slot 158 = 7001 | Changed (base image changed): CRC32 `0x98CDB30E` to `0x65AFA594`, masked 416133902 to 1706010004; the old value is unchanged for the flags 277 image |
| Slot 131 = 513 (layout version 2), slot 131 = 276 (bit 0 clear, bits 2 and 4) | Unchanged: CRC32 `0x3A52D4DB` and `0xFBB6CD5D` (slot 131 is replaced, the other slots are as before) |
| Slot 131 = 278 (bit 0 clear, bits 1, 2, 4: valid-disabled in the new pattern) | New: CRC32 `0x06D4DBC7`, masked 114613191 |
| Slot 131 = 307 (bits 0, 1, 4 and unknown bit 5) | New: CRC32 `0x8F08A616`, masked 252225046 |
| Reference derivation, flag words, stored-reference cases, counter 165 labels | Re-stated below (range 30.0 to 250.0, bit 1 meaning, bit 4 always 1) |
| Block A images, P15 packing, bin lookups, sag, ring index, edge derivation | Unchanged |

**Offset-binary and saturation** (`sag_sum`, bias 2^30 = 1073741824, stored range 0 to 2147483647):

| Total (0.1 V × samples) | Stored value |
|---|---|
| 0 | 1073741824 |
| +7200 | 1073749024 |
| -120 | 1073741704 |
| +1073741823 (2^30 - 1) | 2147483647 |
| +1073741824 (2^30), saturated | 2147483647 |
| -1073741824 (-2^30) | 0 |
| -1073741829 (-2^30 - 5), saturated | 0 |
| Decode stored 0 | -1073741824 |
| Decode stored 2147483647 | +1073741823 |
| Add +5 to a total of +1073741823 | stays +1073741823 (no wrap) |
| Add -1 to a total of -1073741824 | stays -1073741824 (no wrap) |

**P15 packing and saturation:**

| Operation | Result |
|---|---|
| `P15(1, 3)` | 32771 |
| `P15(40000, 5)` (field A clamped to 32767) | 1073709061 |
| `P15(-3, 32768)` (both clamped) | 32767 (A = 0, B = 32767) |
| `P15(32767, 32767)` | 1073741823 |
| `P15(228, 850)` (slot 189, `I_REF` and `T_FET_REF`) | 7471954 (unpacks to 228 and 850) |
| `P15(1600, 0)` (slot 190) | 52428800 |
| `P15(460, 850)` (Cuda X slot 189) | 15074130 |
| `P15(35, 90)` (slot 154: index 8 is 35 s, index 9 is 90 s) | 1146970 |
| `P15(0, 32767)` (a cleared ring record's minimum voltage) | 32767 |

**Current bin lookup** (`step` and `min(7, floor(|I10| / step))`):

| `I_REF` | `step` | Inputs `\|I10\|` to bins |
|---|---|---|
| 228 (Blacktip) | 30 | 29 to 0; 30 to 1; 209 to 6; 210 to 7; 228 to 7; 300 to 7 |
| 460 (Cuda X) | 60 | 59 to 0; 60 to 1; 419 to 6; 420 to 7; 460 to 7; 600 to 7 |
| 150 | 20 | 19 to 0; 20 to 1; 139 to 6; 140 to 7; 150 to 7; 200 to 7 |

**FET bin lookup** (edges `T_FET_REF - 450`, `- 300`, `- 150`, `- 0`; bin is the count of edges at or below the reading):

| `T_FET_REF` | Edges | Readings to bins |
|---|---|---|
| 850 | 400, 550, 700, 850 | 399 to 0; 400 to 1; 549 to 1; 550 to 2; 849 to 3; 850 to 4 |
| 450 | 0, 150, 300, 450 | -50 to 0 (signed compare, no clamp); 0 to 1; 150 to 2; 450 to 4 |

**One sag sample.** `I_REF` 228 (`step` 30), `v_ref` 36.4 V (`vref10` 364), `get-vin` 35.1 V (`vin10` 351), `|get-current-in|` 14.0 A (`I10` 140): bin 4, sag +13, so `n` of slot 142 gains 1 and `sag_sum` of slot 143 gains 13. With `get-vin` 36.5 V the sag is -1.

**Reference derivation** (`conf-get 'l-temp-motor-start` results are floats in °C, accepted only if a number in 30.0 to 250.0; `T_FET_REF` is the fixed 850 and is never read, so bit 4 is 1 in every row):

| Read result | `T_MOT_REF` (slot 190 field A) | Bit 1 | Counter 165 label |
|---|---|---|---|
| 160.0 (the factory value) | 1600 | 1 | limit read from configuration (value in slot 190) |
| 180.0 | 1800 | 1 | limit read from configuration (value in slot 190) |
| 250.0 (upper bound, accepted) | 2500 | 1 | limit read from configuration (value in slot 190) |
| 30.0 (lower bound, accepted) | 300 | 1 | limit read from configuration (value in slot 190) |
| 159.96 | 1600 (`floor(1599.6 + 0.5)`) | 1 | limit read from configuration (value in slot 190) |
| 85.06 | 851 | 1 | limit read from configuration (value in slot 190) |
| 29.9 | 1600 (fallback) | 0 | assumed 160 deg C factory fallback, configured limit unknown |
| 250.1 | 1600 (fallback) | 0 | assumed 160 deg C factory fallback, configured limit unknown |
| NaN, `nil`, a non-number or a trap error | 1600 (fallback) | 0 | assumed 160 deg C factory fallback, configured limit unknown |

A read of exactly 160.0 (slot 190 = 1600, bit 1 = 1) is therefore distinguishable from the fallback (slot 190 = 1600, bit 1 = 0). Counter 164 is labelled "assumed 85 deg C limit" in every case. Slot 189 and slot 190 packing for the 7.00 case: `P15(228, 850)` = 7471954 and `P15(1600, 0)` = 52428800 (both 1600 rows); `P15(1800, 0)` = 58982400, `P15(2500, 0)` = 81920000 and `P15(300, 0)` = 9830400 (these values fit a P15 field: 2500 is at most 32767).

**Flag words** (slot 131 = `256 + bits`; bit 0 = 1, value 1; bit 1 = 2; bit 2 = 4; bit 3 = 8; bit 4 = 16):

| Case | Slot 131 |
|---|---|
| Enabled, motor read accepted (bit 1 = 1, bit 4 = 1), imbalance not configured | 275 (`256 + 1 + 2 + 16`) |
| The same with imbalance configured | 279 (`256 + 1 + 2 + 4 + 16`) |
| Enabled, motor read failed (bit 1 = 0, bit 4 = 1), imbalance not configured | 273 |
| The same with imbalance configured | 277 |
| Bit 3 additionally set | 283 (from 275) and 281 (from 273) |
| Unknown flag bit 5 set with bits 0, 1, 4 | 307 (`275 + 32`); the decoder decodes normally and notes the unknown bit. Bits 5 to 7 all set: 499 (`275 + 224`) |

**Stored reference wins** (`I_REF` 228 unless stated; the counters keep using the stored references):

| Stored (flags) | Fresh read | Result |
|---|---|---|
| `T_MOT_REF` 1600, bit 1 = 1 (275) | 180.0, so fresh 1800 | bit 3 = 1, bit 1 stays 1, 1600 stays in use (flags 283); counter 165 label "limit read from configuration" |
| `T_MOT_REF` 1600, bit 1 = 0 (273) | 160.0 (exactly, a successful read) | bit 3 = 0 (the values are equal), bit 1 stays 0, 1600 in use (flags 273); label stays "assumed 160 deg C factory fallback" until the user exports and clears block B |
| 1600, bit 1 = 0 (273) | 150.0, so fresh 1500 | bit 3 = 1 (flags 281), bit 1 stays 0, 1600 in use: a motor reading of 1550 does not increment slot 165, where a fresh-read implementation would have counted it |
| 1800, bit 1 = 1 | a failed read, so fresh 1600 | bit 3 = 1, bit 1 stays 1, 1800 in use |
| 1600, bit 1 = 1 | a failed read, so fresh 1600 | bit 3 = 0, bit 1 stays 1 (carried, not recomputed) |
| 1600, bit 1 = 1, `I_REF` 228 | 160.0 after a package update changed `MAX_CURRENT_BLACKTIP` so that fresh `I_REF` is 460 | bit 3 = 1; stored 228 stays in use |
| None stored (zero) | 180.0 | 1800, bit 1 = 1, bit 3 = 0 |
| None stored (zero) | 29.9 | 1600, bit 1 = 0, bit 3 = 0 |

**Ring index** (`r = (session_seq - 1) mod 4`, record slot `169 + 5r`):

| `session_seq` | `r` | First slot |
|---|---|---|
| 1 | 0 | 169 |
| 2 | 1 | 174 |
| 4 | 3 | 184 |
| 5 (wrapped) | 0 | 169 |
| 9 | 0 | 169 |

**Images and CRC.**

*Cleared image* (the state a clear leaves, enabled, 7.00 reference case): slot 130 is the magic, slot 131 is the flags word (273 when the motor read failed, 275 when it was accepted; layout 1, bit 0, bit 4, and bit 1 for 275), slots 135, 137, 139, 141, 143, 145, 147 and 149 are 1073741824 (`sag_sum` of zero), slots 171, 175, 179 and 183 are 32767 (ring minimum voltage "none"), slot 189 is 7471954, slot 190 is 52428800, and all other slots 132 to 191 are 0. The two cleared images differ only in slot 131, so slot 190 alone does not show whether 1600 was read or assumed; bit 1 does.

| Check | Value |
|---|---|
| Cleared image CRC32 (slots 130 to 191, 248 bytes), flags 273 | `0xF8B2DEF6`; stored slot 129 is 2024988406 (unchanged) |
| Cleared image CRC32, flags 275 | `0x05D0C86C`; stored slot 129 is 97568876 (`0x05D0C86C`, new) |
| Populated image CRC32 (below, flags 279) | `0x7865D08A`; stored slot 129 is 2019938442 (`0x7865D08A`, the masked value is equal because bit 31 is clear; new) |
| Populated image with flags 277 (the earlier example: bit 1 = 0) | CRC32 `0x8507C610`; stored slot 129 is 84395536 (`0x0507C610`, masked); unchanged value |
| Populated image, `commit_seq` 6 | state `ok` (valid) |
| Populated image with slot 128 = 7 and the CRC unchanged | state `in_progress` (torn); CRC input is unchanged |
| Populated image with slot 158 read back as 7001 instead of 7000, stored CRC unchanged | recomputed CRC32 `0x65AFA594`, masked 1706010004, differs from 2019938442: state `crc_mismatch` (torn). (For the flags 277 image: `0x98CDB30E`, masked 416133902, against 84395536.) |
| Populated image with slot 131 = 513 (layout version 2, bit 0) | state `unknown_layout`, whatever the CRC (its recomputed CRC32 would be `0x3A52D4DB`) |
| Populated image with slot 131 = 278 (bit 0 clear, bits 1, 2, 4), slot 129 recomputed | CRC32 `0x06D4DBC7`, masked 114613191: state `ok` with bit 0 clear, that is valid-disabled |
| Populated image with slot 131 = 276 (bit 0 clear, bits 2, 4), slot 129 recomputed | CRC32 `0xFBB6CD5D`, masked 2075577693 (unchanged): valid-disabled |
| Populated image with slot 131 = 307 (bits 0, 1, 4 and unknown bit 5), slot 129 recomputed | CRC32 `0x8F08A616`, masked 252225046: state `ok` (valid); the decoder notes unknown flag bit 5 |
| Slots 128 to 255 all `nil` | state `empty` (uninitialised) |
| Slot 130 = `0x42544C47` (block A's magic, in block B's range), slot 131 = 257 | state `foreign` |
| Only slot 129 = 5, slots 128, 130 and 131 `nil` | state `foreign` |
| Block A: slots 64 to 67 all `nil` | state `empty`; with slot 65 = 7 and the rest `nil`, state `foreign` |
| Block A populated image (the export example), slots 66 to 126 | CRC32 `0x2C9626B5` (748037813), as in [Test vectors](#test-vectors) |

*Populated image* (`session_seq` 5, so the ring has wrapped once; slot 128 is 6; the first 16 CRC input bytes are `42 54 4C 48 00 00 01 17 00 00 00 05 00 03 80 00`). Slot 131 is 279 (bits 0, 1, 2 and 4: enabled, motor reference read, imbalance configured, FET constant). Slot 133 is `P15(7, 0)` = 229376. The sag table, `(n, total)` per bin 0 to 7: (40, -120), (1200, +7200), (3000, +27000), (2500, +35000), (1800, +36000), (900, +22500), (600, +18000), (350, +12250), stored as `n` in the even slot and the offset-binary value in the odd slot. Slots 150 to 154 are 0, 0, 3, 12, 1146970. Slots 155 to 158 are 400, 5200, 9100, 7000. Slots 159 to 165 are 30000, 9000, 2500, 300, 12, 12, 0. Slots 166 to 168 are 2, `P15(215, 38)` = 7045158 and 40. Slots 189 to 191 are 7471954, 52428800 and 0. The ring:

| Record `r` | Session | Slots (motor-on s; mAh, Wh × 10; max FET offset-binary, min Vin; max A × 10, max eRPM; tag, start `v_ref`) | Raw slots |
|---|---|---|---|
| 0 (169) | 5 | 2100; 3120, 346; 1412, 330; 198, 3600; 7, 364 | 2100, 102236506, 46268746, 6491664, 229740 |
| 1 (174) | 2 | 1800; 2650, 291; 1388, 335; 205, 3810; 7, 362 | 1800, 86835491, 45482319, 6721250, 229738 |
| 2 (179) | 3 | 2400; 4010, 442; 1455, 321; 228, 4012; 7, 366 | 2400, 131400122, 47677761, 7475116, 229742 |
| 3 (184) | 4 | 900; 1300, 140; 1362, 341; 176, 3300; 0, 363 | 900, 42598540, 44630357, 5770468, 363 |

Offset-binary FET fields are `1000 + 10 × °C`: 1412 is 41.2 °C, 1388 is 38.8 °C, 1455 is 45.5 °C and 1362 is 36.2 °C.

The reference script (Python 3, standard library only; it asserts every CRC, packing, flag, reference, bin, ring and protocol-frame value in the tables above, including the block A images, and prints `all vectors ok`). Each CRC is computed twice, with `zlib.crc32` and with `crc_fw`, a bitwise port of the firmware's `crc32_with_init`, and the two must agree:

```python
import math, struct, zlib

U31 = 0x7FFFFFFF
BIAS = 1 << 30
MAGIC_A, MAGIC_B = 0x42544C47, 0x42544C48
NIL = 0xFFFFFFFF                     # a slot that reads nil is sent as this

def p15(a, b):                       # clamp both fields, pack A*32768 + B
    return (max(0, min(32767, a)) << 15) | max(0, min(32767, b))

def enc_ob(s):                       # signed sum -> stored U31 (offset binary)
    return max(0, min(U31, s + BIAS))

def crc_fw(data, init=0):            # port of crc32_with_init (bitwise, reflected)
    c = ~init & 0xFFFFFFFF
    for byte in data:
        c ^= byte
        for _ in range(8):
            c = (c >> 1) ^ (0xEDB88320 if c & 1 else 0)
    return ~c & 0xFFFFFFFF

def crc_range(slots, lo, hi):        # slots lo..hi, big-endian, second method inside
    d = b"".join(struct.pack(">I", slots[n]) for n in range(lo, hi + 1))
    assert len(d) == 4 * (hi - lo + 1) and zlib.crc32(d) == crc_fw(d)
    return zlib.crc32(d)

def crc_image(slots): return crc_range(slots, 130, 191)       # block B, 248 bytes
def crc_image_a(slots): return crc_range(slots, 66, 126)      # block A, 244 bytes

def i_step(i_ref): return 5 * ((i_ref + 39) // 40)
def i_bin(i10, step): return min(7, i10 // step)
def fet_bin(t10, ref): return sum(e <= t10 for e in (ref - 450, ref - 300, ref - 150, ref))
def ring_slot(seq): return 169 + 5 * ((seq - 1) % 4)

# ---- slot 131 flags (layout version 1) -------------------------------------
T_FET_REF, T_MOT_FALLBACK = 850, 1600      # 7.00: the FET limit is never read

def motor_ref(read):                 # conf-get 'l-temp-motor-start result -> (ref, bit1)
    ok = (isinstance(read, (int, float)) and not isinstance(read, bool)
          and not math.isnan(read) and 30.0 <= read <= 250.0)
    return (math.floor(10 * read + 0.5), 1) if ok else (T_MOT_FALLBACK, 0)

def flags(imb=0, bit1=0, bit3=0, bit4=1, unknown=0):   # bit4 is always 1 on 7.00
    return 256 | 1 | (bit1 << 1) | (imb << 2) | (bit3 << 3) | (bit4 << 4) | unknown

def at_boot(stored_i, stored_mot, stored_bit1, fresh_i, fresh_read):
    """Stored references win; bit1 is carried; bit3 flags any difference."""
    fresh_mot, fresh_bit1 = motor_ref(fresh_read)
    if stored_mot == 0:                       # unset: fresh value and status used
        return fresh_mot, fresh_bit1, 0
    differs = int(fresh_i != stored_i or fresh_mot != stored_mot)
    return stored_mot, stored_bit1, differs

def label_165(bit1):
    return ("limit read from configuration (value in slot 190)" if bit1
            else "assumed 160 deg C factory fallback, configured limit unknown")

LABEL_164 = "assumed 85 deg C limit"          # never depends on a flag on 7.00

# ---- block images -------------------------------------------------------------
def cleared(flag_word, i_ref=228, t_fet=850, t_mot=1600):
    s = {n: 0 for n in range(128, 192)}
    s[130], s[131] = MAGIC_B, flag_word
    for b in range(8): s[135 + 2 * b] = BIAS            # sag_sum 0
    for r in range(4): s[171 + 5 * r] = p15(0, 32767)   # min Vin "none"
    s[189], s[190] = p15(i_ref, t_fet), p15(t_mot, 0)
    return s

def populated(flag_word=279):                           # bits 0, 1, 2, 4
    s = cleared(flag_word)
    s[132], s[133] = 5, p15(7, 0)
    sag = [(40, -120), (1200, 7200), (3000, 27000), (2500, 35000),
           (1800, 36000), (900, 22500), (600, 18000), (350, 12250)]
    for b, (n, tot) in enumerate(sag):
        s[134 + 2 * b], s[135 + 2 * b] = n, enc_ob(tot)
    s[152], s[153], s[154] = p15(0, 3), p15(0, 12), p15(35, 90)
    for n, v in zip(range(155, 159), (400, 5200, 9100, 7000)): s[n] = v
    for n, v in zip(range(159, 164), (30000, 9000, 2500, 300, 12)): s[n] = v
    s[164] = 12                                         # equals slot 163
    s[166], s[167], s[168] = 2, p15(215, 38), 40
    ring = [(2100, 3120, 346, 1412, 330, 198, 3600, 7, 364),
            (1800, 2650, 291, 1388, 335, 205, 3810, 7, 362),
            (2400, 4010, 442, 1455, 321, 228, 4012, 7, 366),
            (900, 1300, 140, 1362, 341, 176, 3300, 0, 363)]
    for r, (on, mah, wh, ft, mv, ii, er, tag, vr) in enumerate(ring):
        b = 169 + 5 * r
        s[b], s[b + 1], s[b + 2] = on, p15(mah, wh), p15(ft, mv)
        s[b + 3], s[b + 4] = p15(ii, er), p15(tag, vr)
    return s

A_RAW = [6, 748037813, 1112820807, 257, 12, 47, 32771, 1, 123000, 12345, 2764,
         48268582, 8323293, 131468403, 0, 0, 0, 0, 0, 0, 3000, 90000, 0, 6000,
         240000, 300, 36000, 1512000, 7200, 54000, 3240000, 67500, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 9000, 1890000, 72000, 0, 0, 12, 0, 95, 420, 1350, 5100, 1,
         0, 65536, 0, 0, 1, 21000, 102236506, 46271721, 6491664, 98306]
assert len(A_RAW) == 63
block_a = dict(zip(range(64, 127), A_RAW))              # block A populated image

def cleared_a(enabled=1):
    s = {n: 0 for n in range(64, 127)}
    s[66], s[67] = MAGIC_A, 256 | enabled
    s[77] = s[124] = 32767                              # minima "none" (P15 field B)
    return s

# ---- extraction protocol frames --------------------------------------------
def read_response(first, values, state, block, part):
    data = b"".join(struct.pack(">I", v) for v in values)
    count = -(-len(data) // 24)                          # ceil
    out = []
    for i in range(count):
        f = bytes([0xB1, block, part, i, count, state if i == 0 else 0])
        f += data[24 * i:24 * i + 24]
        assert len(f) <= 30
        out.append(f)
    return out

def ack(opcode, status, block): return bytes([0xB2, opcode, status, block])

DEFAULT_PACE_MS = 10                                      # LOG_CHUNK_PACE_MS (provisional)
def pace_ms(req):                                         # optional 4th byte
    p = req[3] if len(req) > 3 else 0
    return DEFAULT_PACE_MS if p == 0 else min(p, 250)
def retry_pace_ms(first_pace): return min(250, 2 * first_pace)

# ---- assertions: offset-binary, packing, bins, ring (unchanged vectors) ------
assert (enc_ob(7200), enc_ob(-120)) == (1073749024, 1073741704)
assert (enc_ob(2**30 - 1), enc_ob(2**30), enc_ob(-2**30), enc_ob(-2**30 - 5)) == (U31, U31, 0, 0)
assert (p15(228, 850), p15(1600, 0), p15(40000, 5)) == (7471954, 52428800, 1073709061)
assert [i_step(r) for r in (228, 460, 150)] == [30, 60, 20]
assert [i_bin(x, 30) for x in (29, 30, 209, 210, 228, 300)] == [0, 1, 6, 7, 7, 7]
assert [fet_bin(t, 850) for t in (399, 400, 849, 850)] == [0, 1, 3, 4]
assert [fet_bin(t, 450) for t in (-50, 0, 450)] == [0, 1, 4]
assert [ring_slot(q) for q in (1, 4, 5, 9)] == [169, 184, 169, 169]

# ---- block A images (slot 126 and the rest are unchanged) ---------------------
assert crc_image_a(block_a) == 0x2C9626B5 and block_a[65] == 0x2C9626B5 & U31
ca = cleared_a(); assert crc_image_a(ca) == 0x6178A90A

# ---- motor reference derivation and flags --------------------------------------
nan = float("nan")
assert [motor_ref(v) for v in (160.0, 180.0, 250.0, 30.0)] == [(1600, 1), (1800, 1), (2500, 1), (300, 1)]
assert motor_ref(159.96) == (1600, 1) and motor_ref(85.06) == (851, 1) and motor_ref(150.0) == (1500, 1)
assert all(motor_ref(v) == (1600, 0) for v in (29.9, 250.1, nan, None, "err", True))
assert p15(motor_ref(250.0)[0], 0) < 1 << 30 and motor_ref(250.0)[0] <= 32767
assert [flags(imb=1), flags(imb=0)] == [277, 273]                    # read failed (7.00 fallback)
assert [flags(imb=1, bit1=1), flags(imb=0, bit1=1)] == [279, 275]    # motor read accepted
assert flags(bit1=1, bit3=1) == 283 and flags(bit3=1) == 281
assert flags(bit1=1, unknown=32) == 307 and flags(bit1=1, unknown=224) == 499
assert [(f >> 1) & 1 for f in (273, 275)] == [0, 1] and all((f >> 4) & 1 for f in (273, 275, 277, 279))
assert at_boot(228, 1600, 1, 228, 180.0) == (1600, 1, 1)             # stored wins, bit3 set
assert at_boot(228, 1600, 0, 228, 160.0) == (1600, 0, 0)             # stays "assumed"
assert at_boot(228, 1600, 0, 228, 150.0) == (1600, 0, 1)
assert at_boot(228, 1800, 1, 228, None) == (1800, 1, 1)              # fresh read failed
assert at_boot(228, 1600, 1, 228, "err") == (1600, 1, 0)
assert at_boot(228, 1600, 1, 460, 160.0) == (1600, 1, 1)             # I_REF changed
assert at_boot(0, 0, 0, 228, 180.0) == (1800, 1, 0)                  # nothing stored
assert at_boot(0, 0, 0, 228, 29.9) == (1600, 0, 0)
assert label_165(1).startswith("limit read") and label_165(0).startswith("assumed 160")
assert cleared(flags(bit1=1))[190] == cleared(flags(bit1=0))[190] == 52428800   # same slot 190

# ---- block B images and CRCs ----------------------------------------------------
c273, c275 = cleared(273), cleared(275)
assert crc_image(c273) == 0xF8B2DEF6 and crc_image(c275) == 0x05D0C86C
p279, p277 = populated(279), populated(277)
assert crc_image(p277) == 0x8507C610 and crc_image(p277) & U31 == 84395536     # old example
assert crc_image(p279) == 0x7865D08A and crc_image(p279) & U31 == 2019938442   # new example
q = dict(p279); q[158] += 1
assert crc_image(q) == 0x65AFA594 and crc_image(q) & U31 == 1706010004
q = dict(p277); q[158] += 1
assert crc_image(q) == 0x98CDB30E and crc_image(q) & U31 == 416133902
for fw, crc in ((513, 0x3A52D4DB), (278, 0x06D4DBC7), (276, 0xFBB6CD5D), (307, 0x8F08A616)):
    q = dict(p279); q[131] = fw
    assert crc_image(q) == crc
assert crc_image(p279) & U31 != crc_image(p277) & U31

# ---- protocol frames --------------------------------------------------------------
a_vals = [block_a[n] for n in range(64, 127)]
a = read_response(64, a_vals, 0x09, 0, 0)
assert len(a) == 11 and [len(f) for f in a] == [30] * 10 + [18]
assert a[0] == bytes.fromhex("B1 00 00 00 0B 09".replace(" ", "")
    + "00000006" "2C9626B5" "42544C47" "00000101" "0000000C" "0000002F")
assert a[10] == bytes.fromhex("B1 00 00 0A 0B 00".replace(" ", "")
    + "02C20CE9" "00630E10" "00018002")                  # slots 124, 125, 126
live = dict(p279); live[155] = 417; live[128] = 6; live[129] = 2019938442
b_vals = [live[n] for n in range(128, 192)]
b = read_response(128, b_vals, 0x09, 1, 1)
assert len(b) == 11 and [len(f) for f in b] == [30] * 10 + [22]
assert b[0] == bytes.fromhex("B1 01 01 00 0B 09".replace(" ", "")
    + "00000006" "7865D08A" "42544C48" "00000117" "00000005" "00038000")
assert b[10] == bytes.fromhex("B1 01 01 0A 0B 00".replace(" ", "")
    + "0000016B" "00720352" "03200000" "00000000")      # slots 188 to 191
assert sum(len(f) for f in a) == 318 and sum(len(f) for f in b) == 322   # per part
assert 2 * (11 + 11) == 44
ACKS = [(0xA1, 3, 2, "B2A10302"), (0xA2, 0, 1, "B2A20001"), (0xA2, 1, 1, "B2A20101"),
        (0xA2, 3, 1, "B2A20301"), (0xA2, 2, 0, "B2A20200"), (0xA3, 0, 0, "B2A30000"),
        (0xA3, 2, 1, "B2A30201"), (0xA3, 3, 0, "B2A30300"), (0xA4, 0, 1, "B2A40001"),
        (0xA4, 3, 1, "B2A40301"), (0xA4, 2, 1, "B2A40201"), (0xA4, 1, 1, "B2A40101")]
assert all(ack(o, st, bl) == bytes.fromhex(h) for o, st, bl, h in ACKS)
assert (0x7F << 8 | 0xFF, 0x80 << 8 | 0x00) == (32767, 32768)        # pack tag bytes
reqs = ("A10000", "A1000000", "A100000A", "A1000019", "A10000FA", "A10000FF")
assert [pace_ms(bytes.fromhex(x)) for x in reqs] == [10, 10, 10, 25, 250, 250]
assert [retry_pace_ms(p) for p in (10, 25, 100, 200, 250)] == [20, 50, 200, 250, 250]
assert (p15(1800, 0), p15(2500, 0), p15(300, 0)) == (58982400, 81920000, 9830400)
print("all vectors ok")
```

### Open points and verification still needed

* On the MK5 DPV: confirmation of the rig-measured per-store cost (about 1.3 ms real, rig only), flush duration and the start-latency effect of a press during a flush; the at-rest readings behind the thresholds (`|eRPM| < 25`, `|duty| < 0.02`); whether a prop or motor connected changes them. If a measurement shows an added start delay of about 1 s or more, the planner revisits the design (see [Timing figures](#timing-figures)).
* Whether a page transfer occurs and how long it takes: no multi-second stall seen on the rig; a stall up to about 1 s is not excluded; MK5 unmeasured. The page model of [Page transfers and wear](#page-transfers-and-wear) is an estimate.
* The five-click flush path cannot be exercised on the rig (plain HW 60 without the power switch: no five-click, no idle auto-off). It needs a human validation on a modified MK5, and the idle auto-off behaviour with a short `shutdown_mode` needs the same. The stock MK5's open button input is human-confirmed but not yet measured with `(shutdown-btn-read)`.
* The `LOG_*` constants (`LOG_SETTLE_S` 5 s and `LOG_MIN_FLUSH_INTERVAL_S` 60 s are decided but stay easy to change), the stack size of the sampler thread (start at the `THREAD_STACK_MOTOR` value of 150 words and measure), and the chunk pacing and retry rules over Bluetooth (`LOG_CHUNK_PACE_MS` is provisional until the on-DPV read test).
* A `systime`-independent clock for flush diagnostics, if one exists (see [Flush diagnostics and clocks](#flush-diagnostics-and-clocks)); whether any count beyond `aborted_flushes` is stored needs a layout decision.
* The flush implementation re-verifies the non-interference rule against the source it is built on and states the result.
* Heap: the production package's own free cons cells are unknown; the proposed minimum is 500 free cells after the whole log feature (see [Collector and size budget](#collector-and-size-budget)).
* The untested single-record design option above.
* CudaX behaviour.
* Block B: the `trap` handling of the motor `conf-get` read (including the failed-read and out-of-range cases) has not been run on a controller. A changed FET limit is not detected, by design (see [Derating limits and conf-get names](#derating-limits-and-conf-get-names)).
* Block B: the plausibility of `(get-temp-mot)` on the production unit (a motor sensor is fitted, human-confirmed 5 Nov 2026) is still to be confirmed with one at-rest read.
* Block B: slots 128 to 255 of the production HW 60 MK5 DPV have not been read; the 256-slot range is confirmed on the plain HW 60 rig only, and the sweep of slots 128 to 255 is bench-reported and not yet in `tools/nv_write_probe_results.md`.
* Block B: that the sag table, `v_ref` rule and bin edges give a useful pack-resistance estimate is a design expectation, not tested. The lowest FET bin may hold nearly everything on a water-cooled unit (inference).

## Build System

The project uses GNU Make for building the VESC package:

```text
make              # Build blacktip_dpv.vescpkg (packaged Lisp stripped of comments and indentation)
make debug        # Build blacktip_dpv.vescpkg from the unmodified Lisp source (bench work, debugging)
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
* **Rebuild behavior**: The package is only rebuilt when source files change (`blacktip_dpv.lisp`, `ui.qml`, `pkgdesc.qml`, `README.md`), when `tools/strip_lisp.py` changes, or when the build mode switches between stripped and unstripped (see [Packaged Lisp is stripped](#packaged-lisp-is-stripped))

To update the version:

1. Edit the version line in `README.md`: `**Version:** 1.1.0`
1. Run `make` - the distribution file will be generated automatically with a new timestamp

**Note**: `README.dist.md` and `ui.dist.qml` are generated during build and should not be committed to git.

### Packaged Lisp is stripped

`make` packages a copy of `blacktip_dpv.lisp` with the comments and the indentation removed. The source file stays as readable as before; only the Lisp inside `blacktip_dpv.vescpkg` is stripped. VESC Tool stores the Lisp text byte for byte and the Lisp data has a fixed size limit (one 128 KiB flash block; VESC Tool prints the `Lisp data size` against it during the build), so every comment byte and every leading space counts against it. A comment in the source therefore costs nothing in the package, and indentation can be used freely.

**What `tools/strip_lisp.py` removes**

* Full-line comments and trailing `;` comments, and the whitespace in front of a trailing comment.
* All leading indentation (spaces and tabs), and trailing whitespace outside strings.
* Comment-only and blank lines become **empty lines**: the line count never changes.

Nothing else is touched. Strings (including strings that span lines, where the leading spaces of a continuation line are data), char literals (`\#;`, `\#"`, `\# ` and the `\#\n` forms), `@const-start` / `@const-end` and the `(import ...)` line are kept as they are, apart from their indentation. The lexical rules are those of the LispBM reader in VESC firmware 7.00 (`tokpar.c`), so a `;` or a quote inside a string or a char literal never starts a comment, and a quote or apostrophe inside a comment is dropped with the comment.

**Safety.** The script runs a self-check on every build: it re-reads the source and the output with a second, independent reader and requires identical token sequences (strings byte for byte, every token on the same line), identical line count, line ending style and import lines, and no comment or indentation left over. Anything it cannot handle with certainty (unterminated string, bad escape, bad char literal, bare backslash, control or non-ASCII byte in code, lone CR or mixed line endings) stops `make` with `file:line:col: error: message`, and any stale stripped file is removed, so a package is never built from an old stripped copy. `make test` repeats the comparison on the real source and on edge cases, including a mutation check that the comparison detects damage. When `LBM_REPL` points at a native LispBM repl (for example one built from the `lispBM/lispBM/repl` directory of the VESC firmware 7.00 tree), `make test` also compares the forms that the LispBM reader produces for both files.

**How the build works.** The stripped file is written to `generated/pkg/blacktip_dpv.lisp` (not in git). VESC Tool resolves `pkgLisp`, the other package files and the `generated/display_lut.bin` import relative to its working directory, so `make` runs it in `generated/pkg/`, which holds the stripped Lisp, copies of `pkgdesc.qml`, `README.dist.md`, `ui.dist.qml` and `generated/display_lut.bin`. The result is moved to `blacktip_dpv.vescpkg` in the project directory, as before. `pkgdesc.qml` is copied unchanged, so the package descriptor stored in the package is identical in both modes. The mode is recorded in `generated/pkg_mode.stamp`, so switching mode rebuilds the package.

**Unstripped build (opt-out).**

```text
make debug             # unstripped package; same as: make STRIP_LISP=0
make STRIP_LISP=0      # the same, from the unmodified source, exactly as before this step
make                   # stripped release package (the default)
```

`make debug` produces `blacktip_dpv.vescpkg` unstripped and **overwrites** the stripped package. Run `make` again before building a release or quoting sizes. Use the unstripped build for bench work or when debugging, so that error columns match the source exactly.

**Sizes.** Quote sizes in release notes from the stripped build (the `Lisp data size` line printed by `make`), not from `make debug`. When this step was introduced, the Lisp data of the package was 106,143 B (81.0 %) unstripped and 54,295 B (41.4 %) stripped.

**Mapping an error back to the source.** In the LispBM sources of firmware 7.00 (`eval_cps.c`), the position in an error message is the reader's position in the text it was given, which is the stripped text:

* Read errors (invalid token, bad string or char literal, unexpected end of the stream, unbalanced parenthesis, incorrect use of `.`) print `Line:` and `Column:`. These are 1-based, count bytes, and are the reader's position when it gave up, at or just after the offending token. This is the only error kind that carries a column.
* Other errors (`type_error`, `eval_error`, `out_of_memory` and so on) print no line or column. If the context has a row range, they print `Starting at row: N` or `Between row N and M`, the rows of the top-level form that was being read when the context started. Contexts started with `spawn` have no row range.

The stripped text has the same lines as the source, so **every line number and row refers to the same line in `blacktip_dpv.lisp`**. Columns shift by the indentation that was removed from that line:

```text
source column = stripped column + indentation (in bytes) of that source line
```

or let the tool do it: `python3 tools/strip_lisp.py --map LINE COLUMN blacktip_dpv.lisp` prints the source column for a `Line:` and `Column:` taken from the error message. For a line that starts inside a multi-line string nothing was removed from it, so the columns are equal.

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
    │   ├── preview_display.py          // ASCII/PGM visualization tool
    │   └── strip_lisp.py               // Strips comments and indentation from the packaged Lisp
    ├── generated/                       // Auto-generated files (not in git)
    │   ├── display_lut.bin             // Generated binary display data
    │   └── pkg/                        // Staging directory for the stripped package build
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
