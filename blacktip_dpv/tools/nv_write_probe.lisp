; =============================================================================
; nv_write_probe.lisp - throwaway emulated-EEPROM write probe
; =============================================================================
;
; !!! TEST RIG ONLY. NEVER RUN THIS ON A PRODUCTION DPV. !!!
;
; * Run it manually from the VESC Tool Lisp console on the HW60 test rig.
; * It is NOT part of the Blacktip DPV package: it is not referenced by the
;   Makefile or pkgdesc.qml and must never be bundled into the .vescpkg.
; * Do not upload it on top of the installed package on a device you care
;   about: uploading replaces the running Lisp program.
; * It writes to flash. Each write consumes flash endurance on the rig.
;
; Purpose: measure how the emulated EEPROM behaves, so a performance-log design
; can be based on measured facts. See nv_write_probe_results.md for the results
; template.
;
; Safety:
; * AT-REST GUARD. probe-single, probe-burst, probe-bursts, probe-bursts-quiet
;   and probe-cleanup first check that (get-rpm) and (get-duty) are ~0
;   (|rpm| < 5.0 and |duty| < 0.005) and abort otherwise. Bursts re-check
;   before every burst. This guard is always on for those commands.
; * !!! THE GUARD IS OFF BY DEFAULT FOR THE PACED COMMANDS (probe-paced,
;   probe-paced-loop, probe-paced-flip). !!! They write regardless of
;   (get-rpm) and (get-duty). Reason: this is the test rig, a spinning motor is
;   not an inherent danger there, and during the power-cut test the readings
;   drift as the supply collapses, so the guard aborted nine of ten attempts
;   before power was lost. Each paced command prints a notice line saying so
;   when it starts, and so does loading this script. Turn the guard on for the
;   paced commands with (setq probe-guard t); back off with
;   (setq probe-guard nil). Rig only: never run this on a DPV.
; * Regardless of the guard: the script never issues a motor command, writes
;   only slots 64-126 and refuses run ids outside 1-99999.
; * Writes only touch slots 64-126. Settings slots 0-35 and 127 (package
;   schema version) are only read.
; * eeprom-store-i can stall the motor briefly in firmware, so keep the motor
;   OFF and do not start it while a probe runs.
; * Time units: (sleep x) and (secs-since t) are in SECONDS. The delay
;   arguments of the paced commands are in milliseconds and are converted.
;   All delays use (sleep ...), which yields to other threads. There is no
;   busy-wait anywhere in this script.
; * Do not name a parameter or variable "first", "rest", "loop", "array",
;   "list" or similar: these are LispBM reserved symbols ("first" is an alias
;   of car). An earlier version of probe-bursts used "first" as a parameter
;   name and failed with a type_error at car.
;
; Usage: upload and run this file, which only defines functions and prints the
; identification. Then enter, in this order:
;
;   (probe-info)                  firmware/hw identification
;   (probe-check-unused)          item 3: slots 36-126 should all read nil.
;                                 Run this BEFORE any write.
;   (probe-settings)              item 3: record settings 0-35 + 127 and the
;                                 checksum before the writes
;   (probe-single 20)             item 1: time 20 single writes to slot 64
;   (probe-burst 1)               item 1: one burst of 60 writes, slots 64-123,
;                                 stamped with run id 1
;   (probe-bursts 2 200 0.5)      item 2: bursts with run ids 2..201, 0.5 s
;                                 pause between them. SLOW lines flag any
;                                 write over probe-slow-ms.
;   (probe-bursts-quiet 300 140 0.0)
;                                 item 2, long run without console spam: 140
;                                 bursts (8400 writes), run ids 300..439. Prints
;                                 only SLOW writes (> probe-slow-ms), a summary
;                                 every probe-summary-every bursts, and at the
;                                 end the slowest writes with their write index.
;                                 See "Choosing the write count" below.
;   (probe-dump)                  read back the burst slots as run-length
;                                 groups of run ids
;   (probe-settings)              item 3: must match the "before" output
;   (probe-cleanup)               write 0 back to slots 64-126
;
; Choosing the write count for the erase / page-transfer test (ESTIMATE):
;   Source read: bldc release_7_00 driver/eeprom.c, driver/eeprom.h and
;   conf_general.c. The emulated EEPROM is two 16 KiB flash sectors. Each
;   record is 4 bytes (16-bit data + 16-bit virtual address) and the first
;   4 bytes of a page are its header, so a page holds about 4095 records.
;   eeprom-store-i writes the 32-bit value as TWO records (high half, low half).
;   EE_WriteVariable skips a half whose value is unchanged, so a probe write
;   usually consumes ONE record (the low half changes with every run id; the
;   high half only changes when run*1000+slot crosses a multiple of 65536).
;   When the active page is full the next write triggers a page transfer: all
;   live variables are copied to the other page and the old 16 KiB sector is
;   erased. The STM32F405/407 datasheet (Doc ID 022152 Rev 2) gives 16 KB
;   sector erase typ 250 ms / max 500 ms at x32 parallelism (typ 300 ms at x16),
;   word programming 16 us typ. A page transfer is therefore expected to show
;   up as one SLOW write of the order of hundreds of ms, not a few ms.
;   How full the active page is now is NOT readable from Lisp (earlier writes
;   by the package, settings saves and this probe all count). A transfer should
;   therefore happen within the next ~4095 records, and the second one about
;   (4095 minus the number of live variables copied) records after the first.
;   140 bursts = 8400 writes should cross at least two page transfers even in
;   the worst case (2 * 4095 = 8190 < 8400), provided nothing else writes
;   meanwhile and every write uses a new run id (a rewrite of an identical
;   value consumes no record). This is an estimate from source reading, not a
;   measurement: treat "no SLOW write after 8400 writes" as a surprise and
;   report it, do not assume a transfer happened.
;   Wear: a transfer erases one sector, so 8400 writes cost about 2 erases of a
;   10 000 cycle sector.
;
; Power-cut test (item 4, motor OFF). Bursts finish in about 28 ms, which is
; far too fast to cut power by hand. Use the paced commands instead:
;
;   (probe-paced run delay-ms)   writes slots 64-123 one at a time with
;                                delay-ms between writes (default use 250, a
;                                pass takes about 15 s). The marker line
;                                ("paced run" R "writing slot" S) is printed
;                                BEFORE each write. Same stamp as bursts
;                                (run*1000+slot). The at-rest guard is OFF by
;                                default here (see probe-guard below). Slots
;                                outside 64-126 are refused.
;   (probe-paced-loop first-run delay-ms)
;                                repeats paced passes with run id first-run,
;                                first-run+1, ... until a write is refused, a
;                                run id is refused, probe-stop is t, or (only
;                                with probe-guard t) the motor is not at rest.
;   (probe-paced-flip run-a run-b delay-ms)
;                                same, but alternates between two fixed run
;                                ids. Use 65 and 66, see "torn record" below.
;   (setq probe-guard t)         turn the at-rest guard ON for the paced
;                                commands (default nil = OFF). This one flag
;                                only affects the three paced commands; the
;                                other write commands always use the guard.
;   (setq probe-stop t)          stops a running loop at the next write (needs
;                                a second console command; if the console is
;                                blocked, cutting power is the stop).
;   (setq probe-marker nil)      suppress the marker lines (use with a small
;                                delay-ms to make the writes a larger share of
;                                the time, see "hit rate" below).
;
;   Procedure:
;   1. Motor OFF. Save the console log to a file if the VESC Tool offers it.
;      Leave probe-guard at its default (nil, guard off) for this test.
;   2. (probe-paced 10 250) and let it finish, then (probe-dump): all slots
;      are run 10.
;   3. (probe-paced-flip 65 66 250)   (or (probe-paced 11 250) for one pass)
;      Cut power at an arbitrary moment while it is printing marker lines.
;      Note the wall-clock time since the pass started. To stop without
;      cutting power use (setq probe-stop t); if the console is blocked,
;      cutting power is the stop.
;   4. Power up, reconnect, upload this script again (it does not write), then
;      run ONLY read commands: (probe-info) (probe-settings) (probe-dump).
;      Do not run any write command before recording the dump.
;   5. Repeat with a different cut moment. Record each result in the results
;      file. Fill the last marker lines from the console log if you have them.
;
;   Reading the dump after a cut during a paced pass of run N+1 over run N:
;   * slots up to and including some slot S read run N+1, the slots after it
;     read run N: the cut came while slot S+1 (or S) was being written. The
;     marker line before the cut names the slot being written.
;   * The Lisp console connection DROPS when power is cut, so the last marker
;     lines may never reach the log. The per-slot stamp in the dump is the
;     authoritative record; the markers are only a cross-check.
;   * A TORN record is a slot whose value is neither the old stamp nor the new
;     stamp. The value is stored as two separate 16-bit records, high half
;     first. If power dies between them the slot holds the NEW high half and
;     the OLD low half. probe-dump prints such a slot as "bad slot" with its
;     hi and lo halves. This is only visible when the two stamps have
;     different high halves. With run ids 1..65 the high half is always 0, so
;     a cut between the two records would be invisible and would simply read
;     as the old value. Run ids 65 and 66 differ in the high half for every
;     slot (65064..65123 -> hi 0, 66064..66123 -> hi 1), which is why
;     probe-paced-flip 65 66 is recommended. Other clean pairs: 196/197 and
;     262/263. A cut inside a single half-word program or before the address
;     half of a record is written leaves an unreadable record that the reader
;     ignores: that slot reads as the old value, not as a bad slot.
;   * A cut during a page transfer (rare, see the count estimate) would put
;     many slots, including the package settings 0-35 and 127, at risk. Always
;     compare (probe-settings) with the "before" output.
;
;   Hit rate: a single write takes about 0.2 ms (measured) and the pace is
;   250 ms, so a random cut lands inside a write roughly once in a thousand
;   cuts. Paced mode mostly shows that a cut BETWEEN writes loses nothing. To
;   hit writes more often use a small delay, for example
;   (setq probe-marker nil) (probe-paced-flip 65 66 5), at the cost of the
;   marker lines.
;
; Stamp format: value = run * 1000 + slot. Use run ids 1..99999 so the value
; stays a small integer (other ids are refused). Cleanup writes 0, so after
; cleanup the slots read 0 instead of nil; nothing in the firmware or package
; reads them. After (probe-single n) slot 64 holds 5000000+n-1, which probe-dump
; reports as a bad slot until a burst overwrites it.
; =============================================================================

(def probe-first 64)        ; first burst slot
(def probe-last 123)        ; last burst slot (60 slots)
(def probe-end 126)         ; last slot this script may ever write
(def probe-slow-ms 20.0)    ; a single write above this is flagged SLOW
(def probe-writes 0)        ; writes issued since this script was loaded
(def probe-failures 0)      ; writes for which eeprom-store-i returned nil
(def probe-stop nil)        ; set to t from the console to stop a paced loop
(def probe-marker t)        ; nil suppresses the paced marker lines
(def probe-guard nil)       ; t = at-rest guard ON for the paced commands only
(def probe-summary-every 10); probe-bursts-quiet summary interval in bursts
(def probe-top-n 3)         ; slowest writes kept by probe-bursts-quiet
(def probe-top nil)         ; list of (ms write-index run slot), slowest first
(def probe-top-floor 0.0)   ; ms of the last entry once probe-top is full

; --- guards ------------------------------------------------------------------

(defun probe-at-rest ()
    (and (< (abs (get-rpm)) 5.0) (< (abs (get-duty)) 0.005))
)

; At-rest check. Reads rpm and duty ONCE and reports exactly that reading when
; it fails, so the printed values are the ones that tripped the guard.
(defun probe-rest-check ()
    {
        (var rpm (get-rpm))
        (var duty (get-duty))
        (if (and (< (abs rpm) 5.0) (< (abs duty) 0.005))
            t
            {
                (print (list "ABORT: motor not at rest, rpm" rpm "duty" duty))
                nil
            }
        )
    }
)

; Guard for the paced commands only: runs the at-rest check only when the flag
; probe-guard is t. With the default nil it passes without reading anything.
(defun probe-paced-ok ()
    (if probe-guard (probe-rest-check) t)
)

; One-line notice, printed at load and once per paced command.
(defun probe-guard-notice ()
    (if probe-guard
        (print "paced commands: at-rest guard ON (probe-guard t); (setq probe-guard nil) turns it off")
        (print "paced commands: at-rest guard OFF (default, rig only); (setq probe-guard t) turns it on")
    )
)

; Run ids must keep the stamp run*1000+slot a small positive integer.
(defun probe-run-ok (run)
    (if (and (number? run) (>= run 1) (<= run 99999))
        t
        {
            (print (list "REFUSED: run id outside 1-99999" run))
            nil
        }
    )
)

; --- helpers -----------------------------------------------------------------

(defun probe-stamp (run slot)
    (+ (* run 1000) slot)
)

; Time one write. Returns elapsed seconds. Only slots 64-126 are allowed.
; eeprom-store-i returns t on success; nil is counted and reported.
(defun probe-timed-store (slot val)
    (if (and (>= slot probe-first) (<= slot probe-end))
        {
            (var t0 (systime))
            (var stored (eeprom-store-i slot val))
            (var dt (secs-since t0))
            (setq probe-writes (+ probe-writes 1))
            (if (not stored) {
                (setq probe-failures (+ probe-failures 1))
                (print (list "STORE FAILED slot" slot "val" val
                             "writes_since_load" probe-writes))
            })
            dt
        }
        {
            (print (list "REFUSED: slot outside 64-126" slot))
            0.0
        }
    )
)

; --- identification ----------------------------------------------------------

(defun probe-info ()
    {
        (print (list "hw-name" (sysinfo 'hw-name)))
        (print (list "hw-type" (sysinfo 'hw-type)))
        (print (list "fw-ver" (sysinfo 'fw-ver)))
        (print (list "git-branch" (sysinfo 'git-branch)))
        (print (list "git-hash" (sysinfo 'git-hash)))
        (print (list "rpm" (get-rpm) "duty" (get-duty) "at-rest" (probe-at-rest)
                     "paced-guard" (if probe-guard "ON" "OFF")))
        (print "Rig only: not an MK5, no Bluetooth module. Record in the results file.")
    }
)

; --- item 3: unused slots and settings ---------------------------------------

; Prints the slots in 36-126 that hold a value (expected: none before any write).
(defun probe-check-unused ()
    {
        (var slot 36)
        (var used nil)
        (loopwhile (<= slot 126) {
            (if (not-eq (eeprom-read-i slot) nil)
                (setq used (cons (list slot (eeprom-read-i slot)) used)))
            (setq slot (+ slot 1))
        })
        (print (list "non-nil slots in 36-126 (empty list is expected)" (reverse used)))
    }
)

; Prints settings slots 0-35 and 127, plus a checksum for before/after compare.
(defun probe-settings ()
    {
        (var slot 0)
        (var vals nil)
        (var sum 0)
        (loopwhile (<= slot 35) {
            (var v (eeprom-read-i slot))
            (setq vals (cons v vals))
            (setq sum (+ sum (* (or v 0) (+ slot 1))))
            (setq slot (+ slot 1))
        })
        (var v127 (eeprom-read-i 127))
        (setq sum (+ sum (* (or v127 0) 128)))
        (print (list "settings 0-35" (reverse vals)))
        (print (list "slot 127" v127))
        (print (list "checksum" sum))
    }
)

; --- item 1: single write timing ---------------------------------------------

; n timed writes of changing values to slot 64. Prints each time in ms.
(defun probe-single (n)
    (if (probe-rest-check)
        {
            (var i 0)
            (var sum 0.0)
            (var mx 0.0)
            (var mn 1000.0)
            (loopwhile (< i n) {
                (var dt (probe-timed-store probe-first (+ 5000000 i)))
                (print (list "single" i "ms" (* dt 1000.0)))
                (setq sum (+ sum dt))
                (if (> dt mx) (setq mx dt))
                (if (< dt mn) (setq mn dt))
                (setq i (+ i 1))
            })
            (print (list "single n" n "min_ms" (* mn 1000.0)
                         "avg_ms" (/ (* sum 1000.0) n) "max_ms" (* mx 1000.0)))
        }
    )
)

; --- items 1, 2, 4: burst of 60 stamped writes -------------------------------

; One burst, run id 1..99999. Prints the total and the slowest single write.
(defun probe-burst (run)
    (if (and (probe-run-ok run) (probe-rest-check))
        {
            (var t0 (systime))
            (var slot probe-first)
            (var mx 0.0)
            (var mxslot 0)
            (loopwhile (<= slot probe-last) {
                (var dt (probe-timed-store slot (probe-stamp run slot)))
                (if (> dt mx) {
                    (setq mx dt)
                    (setq mxslot slot)
                })
                (if (> (* dt 1000.0) probe-slow-ms)
                    (print (list "SLOW run" run "slot" slot "ms" (* dt 1000.0)
                                 "writes_since_load" probe-writes)))
                (setq slot (+ slot 1))
            })
            (print (list "burst run" run "total_ms" (* (secs-since t0) 1000.0)
                         "max_ms" (* mx 1000.0) "max_slot" mxslot
                         "writes_since_load" probe-writes))
            t
        }
        nil
    )
)

; count bursts with run ids first-run..first-run+count-1, pause seconds between
; them. Stops at once if the motor is not at rest.
(defun probe-bursts (first-run count pause)
    {
        (var i 0)
        (var ok t)
        (loopwhile (and ok (< i count)) {
            (setq ok (probe-burst (+ first-run i)))
            (setq i (+ i 1))
            (sleep pause)
        })
        (print (list "bursts done" i "of" count "writes_since_load" probe-writes))
    }
)

; --- item 2: long run without console spam -----------------------------------

; Keep the probe-top-n slowest writes, slowest first. Entry: (ms index run slot)
; where index is the number of writes since load, including this one.
(defun probe-top-add (ms run slot)
    {
        (setq probe-top
            (take (sort (lambda (a b) (> (car a) (car b)))
                        (cons (list ms probe-writes run slot) probe-top))
                  probe-top-n))
        (if (= (length probe-top) probe-top-n)
            (setq probe-top-floor (car (ix probe-top (- probe-top-n 1)))))
    }
)

(defun probe-top-print ()
    {
        (var i 0)
        (loopwhile (< i (length probe-top)) {
            (var e (ix probe-top i))
            (print (list "slowest" (+ i 1) "ms" (ix e 0) "write_index" (ix e 1)
                         "run" (ix e 2) "slot" (ix e 3)))
            (setq i (+ i 1))
        })
    }
)

; count bursts of 60 writes, run ids first-run..first-run+count-1, pause seconds
; between bursts. Prints only SLOW writes (> probe-slow-ms), a summary line every
; probe-summary-every bursts, and the slowest writes at the end. Stops at once if
; the motor is not at rest. 140 bursts = 8400 writes.
(defun probe-bursts-quiet (first-run count pause)
    (if (probe-run-ok first-run)
        {
            (var b 0)
            (var ok t)
            (var nslow 0)
            (var w0 probe-writes)
            (var t0 (systime))
            (setq probe-top nil)
            (setq probe-top-floor 0.0)
            (loopwhile (and ok (< b count)) {
                (var run (+ first-run b))
                (setq ok (and (probe-run-ok run) (probe-rest-check)))
                (if ok {
                    (var slot probe-first)
                    (loopwhile (<= slot probe-last) {
                        (var ms (* (probe-timed-store slot (probe-stamp run slot)) 1000.0))
                        (if (> ms probe-top-floor) (probe-top-add ms run slot))
                        (if (> ms probe-slow-ms) {
                            (setq nslow (+ nslow 1))
                            (print (list "SLOW run" run "slot" slot "ms" ms
                                         "writes_since_load" probe-writes))
                        })
                        (setq slot (+ slot 1))
                    })
                    (setq b (+ b 1))
                    (if (= (mod b probe-summary-every) 0)
                        (print (list "quiet summary bursts" b "of" count
                                     "writes_since_load" probe-writes "slow" nslow
                                     "worst_ms" (if probe-top (car (ix probe-top 0)) 0.0)
                                     "elapsed_s" (secs-since t0))))
                    (sleep pause)
                })
            })
            (print (list "quiet done bursts" b "of" count "writes" (- probe-writes w0)
                         "writes_since_load" probe-writes "slow" nslow
                         "store_failures" probe-failures "elapsed_s" (secs-since t0)))
            (probe-top-print)
        }
    )
)

; --- item 4: paced writes for the power-cut test -----------------------------

; One pass over slots 64-123 with delay-ms milliseconds between writes. Prints
; a marker BEFORE every write, so the last marker names the slot that was being
; written when power died. The at-rest guard applies only when probe-guard is t
; (default nil, off); it is then re-checked before every write. Returns t when
; all 60 slots were written, nil when it aborted, was stopped or was refused.
; probe-paced-pass is one pass without the notice line; the loop and flip
; commands print the notice once and then call it for every pass.
(defun probe-paced-pass (run delay-ms)
    (if (and (probe-run-ok run) (probe-paced-ok))
        {
            (var dly (if (> delay-ms 0) (/ delay-ms 1000.0) 0.0))
            (var slot probe-first)
            (var ok t)
            (loopwhile (and ok (not probe-stop) (<= slot probe-last)) {
                (setq ok (probe-paced-ok))
                (if ok {
                    (if probe-marker
                        (print (list "paced run" run "writing slot" slot)))
                    (probe-timed-store slot (probe-stamp run slot))
                    (setq slot (+ slot 1))
                    (sleep dly)
                })
            })
            (if (> slot probe-last)
                {
                    (print (list "paced run" run "complete writes_since_load" probe-writes))
                    t
                }
                {
                    (print (list "paced run" run "NOT complete, next slot" slot
                                 "stop-flag" probe-stop))
                    nil
                }
            )
        }
        nil
    )
)

(defun probe-paced (run delay-ms)
    {
        (probe-guard-notice)
        (probe-paced-pass run delay-ms)
    }
)

; Paced passes with run ids first-run, first-run+1, ... until a pass does not
; complete (bad run id, probe-stop is t, or motor not at rest with probe-guard t).
(defun probe-paced-loop (first-run delay-ms)
    {
        (probe-guard-notice)
        (setq probe-stop nil)
        (var run first-run)
        (var last-run 0)
        (var go t)
        (loopwhile (and go (not probe-stop)) {
            (setq last-run run)
            (setq go (probe-paced-pass run delay-ms))
            (setq run (+ run 1))
        })
        (print (list "paced loop ended, last run started" last-run
                     "stop-flag" probe-stop "writes_since_load" probe-writes))
    }
)

; Same, but alternates between two fixed run ids (recommended 65 and 66, whose
; stamps have different high 16-bit halves for every slot, which makes a cut
; between the two records of one value visible in probe-dump).
(defun probe-paced-flip (run-a run-b delay-ms)
    {
        (probe-guard-notice)
        (setq probe-stop nil)
        (var run run-a)
        (var last-run 0)
        (var go t)
        (loopwhile (and go (not probe-stop)) {
            (setq last-run run)
            (setq go (probe-paced-pass run delay-ms))
            (setq run (if (= run run-a) run-b run-a))
        })
        (print (list "paced flip ended, last run started" last-run
                     "stop-flag" probe-stop "writes_since_load" probe-writes))
    }
)

; --- read back ---------------------------------------------------------------

; Prints the burst slots as groups: ("run" r "slots" from to). Run -1 means nil
; (never written), run 0 means the cleanup value 0, run -2 means a value that
; does not match its slot (a "bad slot" line follows with the raw value and its
; high and low 16-bit halves, plus "lo-run" when the low half alone is a valid
; stamp of this slot, i.e. new high half over old low half). A torn burst
; shows as the old run followed by the new run, or the reverse, depending on
; the write order and the page state. Read only: never writes.
(defun probe-dump ()
    {
        (var slot probe-first)
        (var cur -3)
        (var from probe-first)
        (loopwhile (<= slot probe-last) {
            (var v (eeprom-read-i slot))
            (var key (cond
                ((eq v nil) -1)
                ((= v 0) 0)
                ((= (mod v 1000) slot) (/ v 1000))
                (t -2)))
            (if (!= key cur) {
                (if (!= cur -3) (print (list "run" cur "slots" from (- slot 1))))
                (setq cur key)
                (setq from slot)
            })
            (if (= key -2) {
                (var hi (shr v 16))
                (var lo (bitwise-and v 65535))
                (print (list "bad slot" slot "raw" v "hi" hi "lo" lo
                             "lo-run" (if (= (mod lo 1000) slot) (/ lo 1000) nil)))
            })
            (setq slot (+ slot 1))
        })
        (print (list "run" cur "slots" from probe-last))
    }
)

; --- cleanup -----------------------------------------------------------------

; Writes the sentinel 0 back to every slot this script may touch (64-126).
(defun probe-cleanup ()
    (if (probe-rest-check)
        {
            (var slot probe-first)
            (loopwhile (<= slot probe-end) {
                (probe-timed-store slot 0)
                (setq slot (+ slot 1))
            })
            (print (list "cleanup done, slots 64-126 now 0, writes_since_load" probe-writes))
        }
    )
)

; --- load: identification only, no writes ------------------------------------

(print "nv_write_probe loaded. RIG ONLY. No writes yet. Commands:")
(print "(probe-info) (probe-check-unused) (probe-settings) (probe-single n)")
(print "(probe-burst run) (probe-bursts first-run count pause) (probe-dump) (probe-cleanup)")
(print "(probe-bursts-quiet first-run count pause)   long run, prints SLOW only")
(print "(probe-paced run delay-ms) (probe-paced-loop first-run delay-ms)")
(print "(probe-paced-flip run-a run-b delay-ms)  power-cut test, stop: (setq probe-stop t)")
(probe-guard-notice)
(probe-info)
