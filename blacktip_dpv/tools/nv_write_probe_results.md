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

Transcribed from the human's reports. Statements under "Reported by human" are
reported facts. Text labelled "Analysis" or "Inference" is interpretation, not
measurement. There were two bench sessions on the same day; the first is
below, the second follows it ("Second session"). The status summary of items
1 to 4 after both sessions is at the end of the second session.

### First session

As reported after the first session, items 2 (slow writes over a long run) and
4 (power-cut tests) were NOT complete; both were addressed in the second
session.

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

Script defect found while running the bursts: the human reported a
`type_error ... Current: i bound to: 0 ... At: car ... In: +`. Reported by
human (4 Nov 2026, after the second session): the command that produced this
error was `(probe-bursts 2 200 0.5)`. Reproducing the original script in a
native LispBM 0.36.0 test build (the version vendored in bldc release_7_00,
with stubbed eeprom/rpm functions, not hardware) showed that `probe-dump`
itself runs, and that the same error text is raised by `(probe-bursts ...)`,
whose first parameter was named `first`, a LispBM reserved alias of `car`.
The reported command confirms that root cause. Fixed by renaming the
parameter. `probe-bursts` therefore never produced a result with the original
script.

### Second session (bench, 4 Nov 2026)

Reported by human, except where marked "Analysis" or "Inference".

Rig identification:

| Field | Value |
|---|---|
| Hardware | HW 60, not an MK5, no Bluetooth module |
| Firmware | 7.0.0, branch `release_7_00` |
| Firmware git hash | `1fee61fb7ebc79745a359a0ee0c056cfce39a043` |
| Probe script version | the committed version that includes the paced commands (`probe-paced`, `probe-paced-flip`, `probe-paced-loop`) and `probe-bursts-quiet` |

**Unused slots after reload (before cleanup).** `(probe-check-unused)` listed
non-nil slots `(64 13064) (65 13065) (66 13066) ... (74 13074` and on; the
pasted output was truncated at slot 78. These are leftover stamps from run 13
of the earlier session: `(probe-cleanup)` had not been run after runs 12 and
13. They lie in the probe's own range (64-126), so they are not a violation of
the expectation that slots outside that range are unused. The paste was
truncated, so only slots 64 to 78 are known to be non-nil, and no slot outside
64-126 was shown as non-nil in the visible part. Nothing is claimed about the
part of the listing that was cut off.

**Long timed run, `(probe-bursts-quiet 300 140 0.0)`.** Reported console
result:

| Measurement | Reported value |
|---|---|
| Bursts / writes | 140 bursts, 8400 writes |
| `quiet done` line | bursts 140, writes 8400, slow 0, store_failures 0, elapsed_s 4.544 |
| `worst_ms` in every summary line | 2.5 |
| Slowest write | 2.5 ms (write_index 255, run 304, slot 78) |
| Second slowest | 2.4 ms (write_index 7040, run 417, slot 83) |
| Third slowest | 2.4 ms (write_index 7323, run 422, slot 66) |
| Summary lines (every 10 bursts) | elapsed 0.326 s at 600 writes up to 4.543 s at 8400 writes |
| Average per write, including loop overhead | about 0.54 ms (as reported; 4.544 s / 8400 writes) |
| Writes above the 20 ms SLOW threshold | none |
| After the run | settings 0-35 identical to before, checksum 17532, slot 127 = 6 |

`(probe-paced-flip 65 66 5)` and related paced commands were then run in the
same script load, up to `writes_since_load` 9139. The paced commands do not
time their writes, so only the quiet run is timed.

Analysis (inference, not measurement): the estimate in Item 2 below, that a
page transfer should occur within about 4095 writes, is NOT supported by this
run. 8400 timed writes (and about 9139 writes in that load) showed no write
slower than 2.5 ms, whereas a sector erase would be expected to take hundreds
of ms. The reason is unknown. Possible explanations include that the page and
record model assumed from the source is wrong, that writes are absorbed
differently, or that the firmware behaves differently from the source that was
read. None of these has been tested and none is preferred here.

Recommendation (not a measurement): the log writer should still tolerate an
unobserved stall of up to 500 ms, the datasheet maximum erase time for a 16 KiB
sector, because about a second of start delay is acceptable.

**Power-cut tests and the at-rest guard.** Reported by human:
`(probe-paced-flip 65 66 5)` was run repeatedly with marker lines off and power
was cut. The following is the human's console reconstruction.
`writes_since_load` reset to 60, 120 and so on after each power cycle; the
stored Lisp script persists across power cycles, so the functions stayed
available; the script was re-uploaded once ("Preparing new image") part way.
About ten sessions were observed. NINE of the ten sessions ended with a console
line of the form `("ABORT: motor not at rest, rpm" X "duty" Y)` followed by
`("paced run" N "NOT complete, next slot" S ...)` and `("paced flip ended ...)`.
That is, the at-rest guard stopped the writes; a power cut did not tear a
write in those sessions.

Readings printed by the ABORT lines, as reported:

| rpm | duty |
|---|---|
| -0.572774 | -0.004207 |
| -0.233313 | -0.005800 |
| -0.018509 | 0.006395 |
| 0.015842 | -0.004612 |
| -3.362450 | -0.007518 |
| 2.154835 | 0.006293 |
| -0.111741 | -0.003949 |
| -0.037461 | -0.005615 |
| -0.031006 | -0.004758 |
| -0.073625 | -0.003958 |

Readings that PASSED the guard at rest at other times (from `(probe-info)`),
duty: 0.001402, 0.000746, -0.000361, -0.002032, 0.000203, -0.002243,
-0.002812, 0.000352, with rpm between -1.53 and +1.48.

The human did not say why the readings drifted.

Script thresholds (checked in `nv_write_probe.lisp`, `probe-at-rest`): the
guard passes only when `|rpm| < 5.0` and `|duty| < 0.005`. In the script
version that was run, the ABORT line called `(get-rpm)` and `(get-duty)` again
after the guard failed, so the printed values are a second read and not
necessarily the values that tripped the guard. The script has since been
changed (see "Guard decision" below) so that the guarded commands read both
values once and print that same reading.

Analysis: the duty threshold in the script is 0.005, not a value between 0.003
and 0.004. The passing readings above (largest magnitude 0.002812) are
consistent with it. Five of the ten printed duty readings (-0.004207,
-0.004612, -0.003949, -0.004758, -0.003958) are below 0.005 in magnitude, and
both printed rpm values that look large (-3.36, 2.15) are below 5.0, so those
printed values alone would pass the guard. They can have tripped it only if the
value tested by the guard was larger than the value printed a moment later,
which would mean the readings were changing fast. That was not observed
directly. Also, ten readings are listed but the report says nine of ten
sessions ended in an ABORT; this discrepancy is not resolved here.

Inference (unverified): duty and rpm readings may drift as the supply voltage
collapses during the power cut, so the guard aborts the paced loop just before
power dies and hides most tear opportunities. It is also possible that this is
ordinary noise on an unpowered or idle rig. Neither explanation was tested and
neither is claimed.

**The one genuine power cut.** Exactly ONE session ended WITHOUT an ABORT line.
After two complete passes (65, then 66) the console ended. After reboot,
`(probe-settings)` gave the same settings and checksum 17532, slot 127 = 6, and
`(probe-dump)` gave:

```
("run" 65 "slots" 64 112)
("bad slot" 113 "raw" 577 "hi" 0 "lo" 577 "lo-run" nil)
("run" -2 "slots" 113 113)
("run" 66 "slots" 114 123)
```

Analysis: the interrupted pass was a third pass, run 65, writing slots
ascending over the previous pass's run 66 values. Slots 64 to 112 hold the new
run 65 stamp and slots 114 to 123 still hold the old run 66 stamp. Slot 113
holds raw 577. Old stamp for slot 113: 66 * 1000 + 113 = 66113, which is hi 1,
lo 577. New stamp: 65 * 1000 + 113 = 65113, which is hi 0, lo 65113. The
observed hi 0, lo 577 is the NEW high half combined with the OLD low half: a
torn record that is neither the old nor the new value.

Inference from one event: this is consistent with the high half being written
first, then the low half, and power being lost between the two 16-bit records.
It shows that a per-slot torn value is possible, so a log in this storage needs
a record checksum and an in-progress marker. Only one torn write was captured
in about ten sessions; no rate can be derived from it.

**Second `(probe-dump)` (not a power cut).** After a guard ABORT session, with
no power cut involved, `(probe-dump)` gave `("run" 66 "slots" 64 94)` and
`("run" 65 "slots" 95 123)`, settings checksum 17532, slot 127 = 6. This is
only the clean boundary after a guard abort at slot 95. It is NOT a power-cut
result and must not be counted as a second cut.

**Settings integrity.** Settings 0-35 identical (checksum 17532) and slot 127
= 6 after the 8400-write run, after the power cut that produced the torn
record, and at the end of the session. The EEPROM remained readable after the
power cuts.

**Cleanup.** `(probe-cleanup)` was run at the end (slots 64-126 set to 0,
`writes_since_load` 63). The human did not read the slots back afterwards, so
it is not known that they read 0.

#### Status of items 1 to 4 after both sessions

| Item | Status |
|---|---|
| 1, write duration | Measured: 0.1 to 0.3 ms per single write, 0.5 to 0.6 ms slowest per burst of 60 (one burst 2.1 ms), about 0.54 ms average per write including loop overhead in the 8400-write run, slowest write 2.5 ms |
| 2, slow writes over a long run | No page transfer or slow write observed in 8400 timed writes (none above 20 ms, slowest 2.5 ms). The estimate of a page transfer within about 4095 writes is not supported. Cause unknown |
| 3, unused slots and settings | Settings integrity measured: 0-35 checksum 17532 and slot 127 = 6 unchanged throughout. Unused-slot listing only partly visible (truncated at slot 78), see above |
| 4, power-cut tests | One genuine torn record captured. Nine of about ten attempts were blocked by the at-rest guard, so power-cut coverage is thin. The guard is now off by default for the paced commands (human decision, 4 Nov 2026); not yet validated on hardware |

#### Guard decision

Decided by the human on 4 Nov 2026: "yes, set the guard off, this is the test
rig, so a spinning motor is not an inherent danger." The script was changed
accordingly. This change has been exercised only in a native LispBM 0.36.0
test build with stubbed `get-rpm`, `get-duty` and EEPROM functions. It is NOT
yet validated on hardware.

* The at-rest guard is OFF by default for the three paced commands
  (`probe-paced`, `probe-paced-loop`, `probe-paced-flip`): they write whatever
  `(get-rpm)` and `(get-duty)` return. Each paced command prints a one-line
  notice when it starts, and so does loading the script.
* Re-enable it for the paced commands with `(setq probe-guard t)`; switch it
  off again with `(setq probe-guard nil)`. The flag affects the paced commands
  only.
* `probe-single`, `probe-burst`, `probe-bursts`, `probe-bursts-quiet` and
  `probe-cleanup` still always check at rest and abort otherwise.
* Unchanged regardless of the flag: the script never issues a motor command,
  writes only slots 64-126, and refuses run ids outside 1-99999.
* The ABORT line of the guarded commands now prints the single rpm and duty
  reading that failed the check (no second read).
* The rig is HW 60, not an MK5. Never run this script on a DPV.

#### Open questions / suggested next steps

(a) The guard was blocking the power-cut test. Decided by the human on
4 Nov 2026: switch it off for the paced commands (see "Guard decision"), on the
rig only. The alternative of looser rpm and duty thresholds was not chosen. The
change is not yet validated on hardware: the first power-cut session with the
guard off is still to be run and recorded.

(b) Optional longer erase test, for example `(probe-bursts-quiet 300 900 0.0)`
(about 54000 writes, about 30 s at the measured rate) to look for a page event.
Estimate, not measurement: a handful of sector erases is negligible against
typical flash endurance.

(c) Confirm on the MK5 DPV that the timings are similar before any in-water
use. This is a separate human step; do not run the probe on the DPV.

(d) Resolved: the human reported that the earlier `type_error` came from
`(probe-bursts 2 200 0.5)`, which matches the documented root cause (the
reserved alias `first`).

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

Status: measured; see the reported values in the first and second sessions
above. The blank fields below were not filled from min/avg/max statistics
because only the reported figures exist.

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

Status: measured in the second session, no slow write observed. The estimate
below was NOT supported by the measurement; see "Second session" above.

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
| Command used, bursts run / total writes (`writes_since_load`) | `(probe-bursts-quiet 300 140 0.0)`, 140 bursts / 8400 writes (about 9139 writes in that load) |
| Number of SLOW lines (threshold `probe-slow-ms`, default 20 ms) | 0 |
| Duration of each SLOW write (ms) | none observed |
| Writes since load at each SLOW write (`write_index` / `writes_since_load`) | none observed |
| Spacing between SLOW writes (writes) | not applicable |
| Longest stall seen (ms) | 2.5 (worst_ms in every summary line) |
| `slowest` lines at the end of `probe-bursts-quiet` (ms, write_index, run, slot) | 2.5, 255, 304, 78; 2.4, 7040, 417, 83; 2.4, 7323, 422, 66 |
| `store_failures` (writes for which `eeprom-store-i` returned nil) | 0 |
| Notes (script reloaded between runs? total flash writes on this rig so far) | No page transfer or slow write observed in 8400 timed writes; the estimate above is not supported and the cause is unknown (see the second session). Total flash writes on the rig so far not reported. |

## Item 3: unused slots and settings unaffected

Status: settings integrity measured. The unused-slot listing after the
reload was truncated at slot 78 and is only partly visible.

| Check | Result |
|---|---|
| `(probe-check-unused)` before any write, non-nil slots in 36-126 (expected none) | First session: all nil. Second session, after reload and before cleanup: non-nil slots 64 to 78 visible (leftover run 13 stamps), listing truncated at slot 78, nothing shown outside 64-126 |
| `(probe-settings)` before: settings 0-35, slot 127, checksum | checksum 17532, slot 127 = 6 |
| `(probe-settings)` after bursts and cleanup: same values and checksum? | Same (17532, slot 127 = 6) after the 8400-write run, after the power cut and at the end of the session. Read back before the final cleanup, not after it |
| Any difference (slot, before, after) | none reported |

## Item 4: power-cut tests (motor OFF)

Status: one genuine torn record captured; nine of about ten attempts were
blocked by the at-rest guard, so power-cut coverage is thin. The table below
records only the genuine cut. See "Second session" for the guard aborts. The
guard is now off by default for the paced commands (see "Guard decision"); that
change is not yet validated on hardware.

Bursts take about 28 ms, which is too fast to cut power by hand, so use the
paced commands. They run with the at-rest guard OFF by default, so the writes
proceed whatever `(get-rpm)` and `(get-duty)` read; each paced command prints a
notice saying so. To turn the guard on for them, run `(setq probe-guard t)`
before the command; `(setq probe-guard nil)` turns it off again. Procedure (see
the header of `nv_write_probe.lisp` for detail):

1. Motor OFF. Leave `probe-guard` at its default (nil, guard off). Save the
   console log to a file if the VESC Tool offers it. The Lisp console
   connection drops when power is cut, so the last marker lines may never reach
   the log; the `(probe-dump)` after reboot is the authoritative record.
2. `(probe-paced 10 250)`, let it finish, `(probe-dump)`: all slots run 10.
3. `(probe-paced-flip 65 66 250)` (or `(probe-paced 11 250)` for a single pass,
   or `(probe-paced-loop 11 250)` for increasing run ids). Each pass takes about
   15 s and prints `("paced run" R "writing slot" S)` before every write. Cut
   power at an arbitrary moment and note the time since the pass started.
   The stop flag is `(setq probe-stop t)`; it stops a loop at the next write
   but needs a second console command. If the console is blocked, cutting
   power is the stop.
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
| 1 | `(probe-paced-flip 65 66 5)`, marker lines off | not reported | none (marker lines off) | y | y, 17532 | run 65 slots 64-112, bad slot 113 (raw 577, hi 0, lo 577, lo-run nil), run 66 slots 114-123 | y: new high half, old low half |
| 2 | | | | | | | |
| 3 | | | | | | | |
| 4 | | | | | | | |
| 5 | | | | | | | |

Number of cuts: 1 genuine cut (about ten sessions observed, nine ended by the at-rest guard ABORT, so they are not counted as cuts)  Number with any abnormality: 1

No cut has been recorded yet with the guard off (the default since the guard
decision of 4 Nov 2026).

## Cleanup

| Field | Value |
|---|---|
| `(probe-cleanup)` run (y/n) | y (`writes_since_load` 63) |
| Slots 64-126 read back as 0 afterwards (y/n) | not read back |

## Conclusions (human)

| Field | Value |
|---|---|
| Typical write time (ms) | |
| Worst stall (ms) and how often | |
| Torn-record behaviour | |
| Confidence for MK5 (indicative only until measured on MK5) | |
