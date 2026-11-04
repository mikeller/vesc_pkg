# nv_write_probe results

Fill this in by hand from the VESC Tool Lisp console output of
`tools/nv_write_probe.lisp`. Leave a field blank if it was not measured. Do not
estimate or back-fill numbers.

**Caveat:** the probe is run on a HW60 test rig that is NOT an MK5 and has NO
Bluetooth module. The production DPV is a HW60 MK5 with a Bluetooth module.
Treat every result here as indicative for the MK5 only, until it is confirmed
on MK5 hardware. Record the exact firmware version, which is expected to match
the DPV.

## Measurements reported by human (bench, 4 Nov 2026)

Transcribed from the human's report. Only the facts below were reported; every
other field in this file is still blank. Items 2 (slow writes over a long run)
and 4 (power-cut tests) are NOT complete.

Rig identification:

| Field | Value |
|---|---|
| Hardware | HW 60, not an MK5, no Bluetooth module |
| Firmware | 7.0.0, branch `release_7_00` |
| Firmware git hash | `1fee61fb7ebc79745a359a0ee0c056cfce39a043` |
| Probe script version | as committed before the follow-up fix (the version that had `probe-single`, `probe-burst`, `probe-bursts`, `probe-dump`, `probe-cleanup` only) |

Item 1, write duration (`(probe-single 20)` and `(probe-burst N)`):

| Measurement | Reported value |
|---|---|
| `(probe-single 20)`, 20 writes to slot 64 | each write 0.1 to 0.3 ms, average 0.175 ms |
| `(probe-burst N)`, 60 writes, total time | 27.7 to 28.4 ms |
| `(probe-burst N)`, slowest single write per burst | 0.5 to 0.6 ms, except one burst (run 10) with a slowest write of 2.1 ms at slot 73 |
| Total writes when the session ended | about 263, after cleanup |
| SLOW writes (above 20 ms) | none observed so far |

Item 3, unused slots and settings unaffected:

| Check | Reported value |
|---|---|
| Slots 36-126 before any write | all read nil |
| Settings 0-35 checksum before and after the bursts | 17532, unchanged |
| Slot 127 before and after the bursts | 6, unchanged |

Not reported / not yet measured: the number of bursts, whether the 2.1 ms write
was a page event (not established either way), any long-run erase / page
transfer measurement, any power-cut result.

Script defect found while reading back: the human reported that `(probe-dump)`
failed with `type_error ... Current: i bound to: 0 ... At: car ... In: +`.
Reproducing the original script in a native LispBM 0.36.0 test build (the
version vendored in bldc release_7_00, with stubbed eeprom/rpm functions, not
hardware) showed that `probe-dump` itself runs, and that the same error text is
raised by `(probe-bursts ...)`, whose first parameter was named `first`, a
LispBM reserved alias of `car`. Fixed by renaming the parameter. `probe-bursts`
therefore never produced a result with the original script.

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

Run ONE of these. The quiet form is recommended for the long run because it
prints only SLOW writes, a summary every `probe-summary-every` bursts (default
10) and the slowest writes with their write index at the end.

`(probe-bursts first-run count pause)` (one line per burst), or
`(probe-bursts-quiet first-run count pause)`, for example
`(probe-bursts-quiet 300 140 0.0)` = 140 bursts = 8400 writes.

Why 8400 (estimate from reading bldc release_7_00 `driver/eeprom.c`, not a
measurement): each emulated-EEPROM page is 16 KiB of 4-byte records, about 4095
records. A probe write normally consumes one record, and the active page is
already partly used by earlier writes by unknown amounts, so a page transfer
(copy of the live variables plus a 16 KiB sector erase) should fall within the
next ~4095 writes, and a second one within the ~4095 writes after that. 8400 is
slightly more than 2 x 4095. The STM32F405/407 datasheet lists 250 ms typical,
500 ms maximum for a 16 KB sector erase at x32 parallelism, so a page transfer
is expected to appear as a SLOW write of hundreds of ms. If no SLOW write
appears in 8400 writes, report it as a surprise and do not assume a transfer
occurred.

| Field | Value |
|---|---|
| Command used, bursts run / total writes (`writes_since_load`) | |
| Number of SLOW lines (threshold `probe-slow-ms`, default 20 ms) | |
| Duration of each SLOW write (ms) | |
| Writes since load at each SLOW write (`write_index` / `writes_since_load`) | |
| Spacing between SLOW writes (writes) | |
| Longest stall seen (ms) | |
| `slowest` lines at the end of `probe-bursts-quiet` (ms, write_index, run, slot) | |
| `store_failures` (writes for which `eeprom-store-i` returned nil) | |
| Notes (script reloaded between runs? total flash writes on this rig so far) | |

## Item 3: unused slots and settings unaffected

| Check | Result |
|---|---|
| `(probe-check-unused)` before any write, non-nil slots in 36-126 (expected none) | |
| `(probe-settings)` before: settings 0-35, slot 127, checksum | |
| `(probe-settings)` after bursts and cleanup: same values and checksum? | |
| Any difference (slot, before, after) | |

## Item 4: power-cut tests (motor OFF)

Bursts take about 28 ms, which is too fast to cut power by hand, so use the
paced commands. Procedure (see the header of `nv_write_probe.lisp` for detail):

1. Motor OFF. Save the console log to a file if the VESC Tool offers it. The
   Lisp console connection drops when power is cut, so the last marker lines
   may never reach the log; the `(probe-dump)` after reboot is the authoritative
   record.
2. `(probe-paced 10 250)`, let it finish, `(probe-dump)`: all slots run 10.
3. `(probe-paced-flip 65 66 250)` (or `(probe-paced 11 250)` for a single pass,
   or `(probe-paced-loop 11 250)` for increasing run ids). Each pass takes about
   15 s and prints `("paced run" R "writing slot" S)` before every write. Cut
   power at an arbitrary moment and note the time since the pass started.
   `(setq probe-stop t)` stops a loop cleanly.
4. After power-up: upload the script again (it does not write), then run only
   `(probe-info)`, `(probe-settings)`, `(probe-dump)`. Record the output before
   running any write command.
5. Repeat with other cut moments.

Reading the dump: slots up to some slot read the new run and the rest read the
old run, so the cut fell near that boundary. A "bad slot" line (value that is
neither stamp) is a torn value: the value is two 16-bit records, high half
first, so a cut between them leaves the NEW high half and the OLD low half. This
is visible only when the two runs have different high halves; run ids 65 and 66
do for every slot, run ids 1 to 65 never do. Pairs 196/197 and 262/263 also
work. With `delay-ms` 250 only about 1 cut in 1000 is expected to land inside a
0.2 ms write; for more hits use a small delay with markers off, for example
`(setq probe-marker nil)` then `(probe-paced-flip 65 66 5)`.

| Cut # | Command and delay-ms | Approx. time since pass start (s) | Last marker line in log (run, slot), if any | EEPROM readable after reboot (y/n) | Settings 0-35 and 127 intact (y/n, checksum) | `(probe-dump)` output (old run vs new run per slot range, bad slots with hi/lo) | Torn record seen (y/n) and pattern |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
| 2 | | | | | | | |
| 3 | | | | | | | |
| 4 | | | | | | | |
| 5 | | | | | | | |

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
