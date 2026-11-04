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
; * Every command that writes first checks (get-rpm) and (get-duty) are ~0 and
;   aborts otherwise. Bursts re-check before every burst.
; * The script never issues a motor command.
; * Writes only touch slots 64-126. Settings slots 0-35 and slot 127 (package
;   schema version) are only read.
; * eeprom-store-i can stall the motor briefly in firmware, so keep the motor
;   OFF and do not start it while a probe runs.
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
;   (probe-dump)                  read back the burst slots as run-length
;                                 groups of run ids
;   (probe-settings)              item 3: must match the "before" output
;   (probe-cleanup)               write 0 back to slots 64-126
;
; Power-cut test (item 4, motor OFF):
;   1. (probe-burst 10)   let it finish, then (probe-dump): all slots run 10.
;   2. (probe-burst 11)   and cut power part-way through. The per-slot stamp
;                         lets the dump after reboot show which slots hold
;                         the old run (10) and which hold the new run (11).
;   3. After reboot upload this script again (it does not write), then run
;      (probe-info) (probe-settings) (probe-dump). Repeat several times,
;      using run ids that increase each time.
;   Note: the probe has no way to know when a power cut is "mid-burst"; start
;   the burst and cut power by hand, varying the delay.
;
; Stamp format: value = run * 1000 + slot. Use run ids 1..99999 so the value
; stays a small integer. Cleanup writes 0, so after cleanup the slots read 0
; instead of nil; nothing in the firmware or package reads them.
; =============================================================================

(def probe-first 64)        ; first burst slot
(def probe-last 123)        ; last burst slot (60 slots)
(def probe-end 126)         ; last slot this script may ever write
(def probe-slow-ms 20.0)    ; a single write above this is flagged SLOW
(def probe-writes 0)        ; writes issued since this script was loaded

; --- guards ------------------------------------------------------------------

(defun probe-at-rest ()
    (and (< (abs (get-rpm)) 5.0) (< (abs (get-duty)) 0.005))
)

(defun probe-guard ()
    (if (probe-at-rest)
        t
        {
            (print (list "ABORT: motor not at rest, rpm" (get-rpm) "duty" (get-duty)))
            nil
        }
    )
)

; --- helpers -----------------------------------------------------------------

(defun probe-stamp (run slot)
    (+ (* run 1000) slot)
)

; Time one write. Returns elapsed seconds. Only slots 64-126 are allowed.
(defun probe-timed-store (slot val)
    (if (and (>= slot probe-first) (<= slot probe-end))
        {
            (var t0 (systime))
            (eeprom-store-i slot val)
            (var dt (secs-since t0))
            (setq probe-writes (+ probe-writes 1))
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
        (print (list "rpm" (get-rpm) "duty" (get-duty) "at-rest" (probe-at-rest)))
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
    (if (probe-guard)
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
    (if (probe-guard)
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

; count bursts with run ids first..first+count-1, pause seconds between them.
; Stops at once if the motor is not at rest.
(defun probe-bursts (first count pause)
    {
        (var i 0)
        (var ok t)
        (loopwhile (and ok (< i count)) {
            (setq ok (probe-burst (+ first i)))
            (setq i (+ i 1))
            (sleep pause)
        })
        (print (list "bursts done" i "of" count "writes_since_load" probe-writes))
    }
)

; --- read back ---------------------------------------------------------------

; Prints the burst slots as groups: ("run" r "slots" from to). Run -1 means nil
; (never written); run -2 means a value that does not match its slot (printed
; raw). A torn burst shows as the old run followed by the new run, or the
; reverse, depending on the write order and the page state.
(defun probe-dump ()
    {
        (var slot probe-first)
        (var cur -3)
        (var from probe-first)
        (loopwhile (<= slot probe-last) {
            (var v (eeprom-read-i slot))
            (var key (cond
                ((eq v nil) -1)
                ((= (mod v 1000) slot) (/ v 1000))
                (t -2)))
            (if (!= key cur) {
                (if (!= cur -3) (print (list "run" cur "slots" from (- slot 1))))
                (setq cur key)
                (setq from slot)
            })
            (if (= key -2) (print (list "bad slot" slot "raw" v)))
            (setq slot (+ slot 1))
        })
        (print (list "run" cur "slots" from probe-last))
    }
)

; --- cleanup -----------------------------------------------------------------

; Writes the sentinel 0 back to every slot this script may touch (64-126).
(defun probe-cleanup ()
    (if (probe-guard)
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
(print "(probe-burst run) (probe-bursts first count pause) (probe-dump) (probe-cleanup)")
(probe-info)
