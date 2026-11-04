# nv_write_probe results

Fill this in by hand from the VESC Tool Lisp console output of
`tools/nv_write_probe.lisp`. Leave a field blank if it was not measured. Do not
estimate or back-fill numbers.

**Caveat:** the probe is run on a HW60 test rig that is NOT an MK5 and has NO
Bluetooth module. The production DPV is a HW60 MK5 with a Bluetooth module.
Treat every result here as indicative for the MK5 only, until it is confirmed
on MK5 hardware. Record the exact firmware version, which is expected to match
the DPV.

## Identification (from `(probe-info)`)

| Field | Value |
|---|---|
| Date | |
| `hw-name` | |
| `hw-type` | |
| `fw-ver` | |
| `git-branch` / `git-hash` | |
| Hardware actually used (not MK5, no Bluetooth) | |
| Motor connected / rest confirmed (rpm, duty) | |
| Probe script version (git hash of this repo) | |
| Rig and DPV firmware confirmed identical? | |

## Item 1: write duration

`(probe-single 20)`

| Field | Value |
|---|---|
| Samples (n) | |
| min / avg / max single write (ms) | |

`(probe-burst N)`, 60 writes to slots 64-123

| Field | Value |
|---|---|
| Bursts measured | |
| Total burst time min / avg / max (ms) | |
| Slowest single write in any burst (ms) and slot | |

## Item 2: slow writes (page transfer / erase) over repeated bursts

`(probe-bursts first count pause)`

| Field | Value |
|---|---|
| Bursts run / total writes (`writes_since_load`) | |
| Number of SLOW lines (threshold `probe-slow-ms`, default 20 ms) | |
| Duration of each SLOW write (ms) | |
| Writes since load at each SLOW write | |
| Spacing between SLOW writes (writes) | |
| Longest stall seen (ms) | |
| Notes (script reloaded between runs? total flash writes on this rig so far) | |

## Item 3: unused slots and settings unaffected

| Check | Result |
|---|---|
| `(probe-check-unused)` before any write, non-nil slots in 36-126 (expected none) | |
| `(probe-settings)` before: settings 0-35, slot 127, checksum | |
| `(probe-settings)` after bursts and cleanup: same values and checksum? | |
| Any difference (slot, before, after) | |

## Item 4: power-cut tests (motor OFF)

For each cut: complete `(probe-burst N)` first, then `(probe-burst N+1)` and cut
power part-way through. After reboot run `(probe-info)`, `(probe-settings)`,
`(probe-dump)`.

| Cut # | Approx. cut delay after burst start | EEPROM readable after reboot (y/n) | Settings 0-35 and 127 intact (y/n, checksum) | `(probe-dump)` output (old run N vs new run N+1 per slot range) | Torn record seen (y/n) and pattern |
|---|---|---|---|---|---|
| 1 | | | | | |
| 2 | | | | | |
| 3 | | | | | |
| 4 | | | | | |
| 5 | | | | | |

Number of cuts: ______  Number with any abnormality: ______

## Cleanup

| Field | Value |
|---|---|
| `(probe-cleanup)` run (y/n) | |
| Slots 64-126 read back as 0 afterwards (y/n) | |

## Conclusions (human)

| Field | Value |
|---|---|
| Typical write time (ms) | |
| Worst stall (ms) and how often | |
| Torn-record behaviour | |
| Confidence for MK5 (indicative only until measured on MK5) | |
