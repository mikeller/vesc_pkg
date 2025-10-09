;;;;;;;;; User Settings ;;;;;;;;;

; TODO: Move into config?

; Wait this long for charger to start charging
(def charger-max-delay 10.0)
(def sleep-unblock-en true) ; Enable automatic sleep unblocking

;;;;;;;;; End User Settings ;;;;;;;;;

; State
(def trigger-bal-after-charge false)
(def bal-ok false)
(def is-balancing false)
(def is-charging false)
(def charge-ok false)
(def c-min 0.0)
(def c-max 0.0)
(def t-min 0.0)
(def t-max 0.0)
(def t-mos 0.0)
(def t-ic 0.0)
(def charge-wakeup false)
(def psw-state false)
(def scd-latched false) ; Short circuit detected HW
(def init-done false)

(def psw-status "PSW_OFF")
(def chg-status "")
(def bal-status "")

(def rtc-val '(
        (wakeup-cnt . 0)
        (c-min . 3.5)
        (c-max . 3.5)
        (v-tot . 50.0)
        (soc . 0.5)
        (charge-fault . false)
        (updated . false)
))

(def is-bal false)
(def vtot 0.0)
(def vout 0.0)
(def vt-vchg 0.0)
(def iout 0.0)
(def soc -1.0)
(def i-zero-time 0.0)
(def chg-allowed true)

(def com-force-on false)
(def com-mutex (mutex-create))
(def pchg-mutex (mutex-create))
(def buz-mutex (mutex-create))

(def did-crash false)
(def crash-cnt 0)

@const-start

;;; Hack until problem is found ;;;
; Pre-load all functions that are loaded with the dynamic loader. This will
; make them end up in the image and there is no need to load them dynamically.

str-merge
foldl
foldr
zipwith
filter
str-cmp-asc
str-cmp-dsc
second
third
abs

defun
defunret
defmacro
loopfor
loopwhile
looprange
loopforeach
loopwhile-thd

;;; Hack End ;;;

(defun bms-current () (* (bms-get-current) -2.0))

(defun beep (times dt) {
        (loopwhile (> times 0) {
                (pwm-set-duty 0.5 0)
                (sleep dt)
                (pwm-set-duty 0.0 0)
                (sleep dt)
                (setq times (- times 1))
        })
})

(def rtc-val-magic 115)

; Short-circuit protection (SCD)
; - DDSGPinConfig (0x9302)
;   - 0b10000010 - DDSG, Active low, no pull, REG18, Tristate high
; - EnabledProtectionsA (0x9261)
;   - Bit 7 enables SCD
; - DSGFETProtectionsA (0x9269)
;   - Bit 7 enables SCD
;   - Note: Must be 0xE4, otherwise the protection will be slow!
; - SCDThreshold (0x9286)
;   0: 10 mV
;   1: 20 mV
;   2: 40 mV
;   3: 60 mV
;   4: 80 mV
;   5: 100 mV
;   6: 125 mV
;   7: 150 mV
;   8: 175 mV
;   9: 200 mV
;   10: 250 mV
;   11: 300 mV
;   12: 350 mV
;   13: 400 mV
;   14: 450 mV
;   15: 500 mV
; - SCDDelay (0x9287)
;   - Set to 1 for no delay, each step above 1 is 15 uS, max 31
; - SCDLLatchLimit (0x9295)
;   - Set to 1 to latch directly without recovering
; - MfgStatusInit (0x9343)
;   - Bit 4 FET EN has to be set
; - Recover from latch: bms-subcmd-cmdonly SCDL_RECOVER (0x009C)
; - Latch status: bms-direct-cmd SafetyAlertA (0x02) bit 7
(defun config-scd () {
        (bms-subcmd-cmdonly 1 0x0090) ; SET_CFGUPDATE
        (bms-write-reg 1 0x9343 0x10 1) ; MfgStatusInit
        (bms-write-reg 1 0x9302 0x82 1) ; DDSGPinConfig
        (bms-write-reg 1 0x9261 (if (= (bms-get-param 'psw_scd_en) 1) 0x80 0x00) 1) ; EnabledProtectionsA
        (bms-write-reg 1 0x9269 (if (= (bms-get-param 'psw_scd_en) 1) 0xE4 0x00) 1) ; DSGFETProtectionsA
        (bms-write-reg 1 0x9286 (bms-get-param 'psw_scd_tres) 1) ; SCDThreshold
        (bms-write-reg 1 0x9287 1 1) ; SCDDelay
        (bms-write-reg 1 0x9295 1 1) ; SCDLLatchLimit
        (bms-subcmd-cmdonly 1 0x0092) ; EXIT_CFGUPDATE
        (bms-subcmd-cmdonly 1 0x0096) ; All FETs on

        ; (bms-read-reg 1 0x9343 1) ; MfgStatusInit
        ; (bms-read-reg 1 0x9302 1) ; DDSGPinConfig
        ; (bms-read-reg 1 0x9261 1) ; EnabledProtectionsA
        ; (bms-read-reg 1 0x9269 1) ; DSGFETProtectionsA
        ; (bms-read-reg 1 0x9286 1) ; SCDThreshold
        ; (bms-read-reg 1 0x9287 1) ; SCDDelay
        ; (bms-read-reg 1 0x9295 1) ; SCDLLatchLimit
        ; (bms-direct-cmd 1 0x02) ; SafetyAlertA
        ; (bms-direct-cmd 1 0x7F) ; FetStatus

        ; (bms-read-reg 1 0x9308 1) ; FETOptions
        ; (bms-read-reg 1 0x9309 1) ; ChgPumpControl

        ; (bms-subcmd-cmdonly 1 0x0095) ; All FETs off
        ; (bms-subcmd-cmdonly 1 0x0096) ; All FETs on
        ; (bms-subcmd-cmdonly 1 0x0022) ; Fet Enable
})

; If in deepsleep, this will return 4
; (bms-direct-cmd 1 0x00)

; Exit deepsleep
; (bms-subcmd-cmdonly 1 0x000e)

(defun init-hw () {
        ; These are blocking and potentially slow operations and we don't want to
        ; run them at the same time as the PCHG buck runs
        (mutex-lock pchg-mutex)

        (loopwhile (not (bms-init (bms-get-param 'cells_ic1) (bms-get-param 'cells_ic2))) {
                (bms-subcmd-cmdonly 1 0x000e)
                (bms-subcmd-cmdonly 1 0x000e)
                (sleep 1)
        })
        (var was-sleep false)
        (if (= (bms-direct-cmd 1 0x00) 4) {
                (setq was-sleep true)
                (loopwhile (= (bms-direct-cmd 1 0x00) 4) {
                        (bms-subcmd-cmdonly 1 0x000e)
                        (sleep 0.01)
                })
        })
        (if (and (> (bms-get-param 'cells_ic2) 0) (= (bms-direct-cmd 2 0x00) 4)) {
                (setq was-sleep true)
                (loopwhile (= (bms-direct-cmd 2 0x00) 4) {
                        (bms-subcmd-cmdonly 2 0x000e)
                        (sleep 0.01)
                })
        })
        (if was-sleep {
                (loopwhile (not (bms-init (bms-get-param 'cells_ic1) (bms-get-param 'cells_ic2))) {
                        (bms-subcmd-cmdonly 1 0x000e)
                        (bms-subcmd-cmdonly 1 0x000e)
                        (sleep 1)
                })
        })

        (config-scd)

        (mutex-unlock pchg-mutex)
})

(defun save-rtc-val () {
        (var tmp (flatten rtc-val))
        (bufcpy (rtc-data) 0 tmp 0 (buflen tmp))
        (bufset-u8 (rtc-data) 900 rtc-val-magic)
})

(defun test-chg (samples) {
        ; Many chargers "pulse" before starting, try to catch a pulse
        (var vchg 0.0)
        (looprange i 0 samples {
                (if (> i 0) (sleep 0.01))
                (setq vchg (bms-get-vchg))
                (if (> vchg (bms-get-param 'v_charge_detect)) (break))
        })

        (var res (> vchg (bms-get-param 'v_charge_detect)))

        (if res (setq charge-dis-ts (systime)))

        res
})

(defun truncate (n min max)
    (if (< n min)
        min
        (if (> n max)
            max
            n
)))

; SOC from battery voltage
(defun calc-soc (v-cell) (truncate (/ (- v-cell (bms-get-param 'vc_empty)) (- (bms-get-param 'vc_full) (bms-get-param 'vc_empty))) 0.0 1.0))

; True when VESC Tool is connected, used to block sleep
(defun is-connected () (or (connected-wifi) (connected-usb) (connected-ble) (= (bms-get-param 'block_sleep) 1)))

(defunret can-active () {
        (var devs (can-list-devs))
        (if (eq devs nil) (return false))

        (looprange i 1 7 {
                (var res (can-msg-age (first devs) i))
                (if (and res (< res 0.1)) (return true))
        })

        false
})

; Run expression with communication enabled. Use up to 4 attempts in case of
; glithces from transients. Disable communication again when it is not needed
; to save power.
(defun with-com (expr) {
        (mutex-lock com-mutex)

        (gpio-write 9 0)

        (var res (looprange i 0 4 {
                    (match (trap (eval expr))
                        ((exit-ok (? a)) (break a))
                        (_ (if (= i 3) {
                                    (mutex-unlock com-mutex)
                                    (exit-error 0)
                        }))
                    )
        }))

        (if (and
                (not (can-active))
                (= (bms-get-btn) 0)
                (not com-force-on)
                (not (is-connected))
                (not is-charging)
            )
            (gpio-write 9 1)
        )

        (mutex-unlock com-mutex)
        res
})

(defun com-force (en)
    (if en
        {
            (setq com-force-on true)
            (gpio-write 9 0)
        }
        {
            (setq com-force-on false)
        }
    )
)

; Start power switch thread early to avoid output on delay
(defunret psw-on () {
        (var res false)

        (setq psw-status "PSW_WAIT")

        (loopwhile (not (assoc rtc-val 'updated)) (sleep 0.1))

        (if (or (= (bms-get-param 'psw_wait_init) 1) (= (bms-get-param 'psw_scd_en) 1)) {
                (loopwhile (not init-done) (sleep 0.1))
        })

        (bms-set-pchg 0)
        (bms-set-out 0)

        ; Return if button has been switched off
        (if (= (bms-get-btn) 0) {
                (setq psw-state true)
                (return true)
        })

        (setq psw-status "PSW_PCHG")

        (mutex-lock pchg-mutex)

        (var t-start (systime))
        (var t-pchg 0)
        (var v-start (bms-get-vout))
        (bms-set-pchg 1)
        (gpio-write 9 0)

        (loopwhile (< (secs-since t-start) (bms-get-param 'psw_t_pchg)) {
                (if (< (- (assoc rtc-val 'v-tot) (bms-get-vout)) 10.0) {
                        (gpio-write 9 0)
                        (bms-set-out 1)
                        (setq t-pchg (secs-since t-start))
                        (setq res t)
                        (break)
                })
                (sleep 0.005)
        })

        (bms-set-pchg 0)
        (setq psw-state true)

        (mutex-unlock pchg-mutex)

        (if res
            (print (str-from-n (* t-pchg 1000.0) "PCHG Time: %.1f ms"))
            (print "PCHG timeout, make sure that there is a load on the output and no short!")
        )

        res
})

(defun psw-off () {
        (bms-set-pchg 0)
        (bms-set-out 0)
        (setq psw-state false)
})

(defun update-temps () {
        ; Exit if any of the BQs has invalid temperature settings
        (if (!= (bms-read-reg 1 0x92fd 1) 0x3b) {
                (print "Invalid temp reg, retrying...")
                (sleep 0.01)

                (if (!= (bms-read-reg 1 0x92fd 1) 0x3b) {
                        (print "Temp reg still invalid, exit error!")
                        (exit-error 0)
                })
        })

        (if (> (bms-get-param 'cells_ic2) 0) {
                (if (!= (bms-read-reg 2 0x92fd 1) 0x3b) {
                        (print "Invalid temp IC2 reg, retrying...")
                        (sleep 0.01)

                        (if (!= (bms-read-reg 2 0x92fd 1) 0x3b) {
                                (print "Temp reg IC2 still invalid, exit error!")
                                (exit-error 0)
                        })
                })
        })

        (var bms-temps (with-com '(bms-get-temps)))
        (var temp-ext-num (truncate (bms-get-param 'temp_num) 0 4))

        ; First and last are balance IC temps
        (var t-sorted (sort < (map
                    (fn (x) (ix bms-temps (+ x 1)))
                    (range 0 temp-ext-num)
        )))

        ; If all sensors are disabled pretend we are at 24c
        (if (= (length t-sorted) 0) (setq t-sorted '(24)))

        (setq t-min (ix t-sorted 0))
        (setq t-max (ix t-sorted -1))
        (setq t-mos (ix bms-temps 5))
        (setq t-ic (ix bms-temps 0))

        bms-temps
})

(defun start-fun () {
        (setassoc rtc-val 'wakeup-cnt (+ (assoc rtc-val 'wakeup-cnt) 1))

        (var do-sleep true)
        (var sleep-early true)

        (if (= (bms-get-btn) 1) {
                (setq do-sleep false)
        })

        (if (or charge-wakeup (test-chg 5)) {
                (if (not (assoc rtc-val 'charge-fault)) {
                        (setq do-sleep false)
                        (setq charge-wakeup true)
                })

                ; Reset charge fault when the charger is not connected at boot
                (setassoc rtc-val 'charge-fault false)
        })

        (if (is-connected) (setq do-sleep false))
        (if (can-active) (setq do-sleep false))

        ; Every 1000 startupts we do some additional checks. That allows
        ; adjusting the sleep time based on the SoC.
        (if (= (mod (assoc rtc-val 'wakeup-cnt) 1000) 0) {
                (setq sleep-early false)
        })

        (if (and do-sleep sleep-early) {
                (save-rtc-val)

                (if (< (assoc rtc-val 'soc) 0.05)
                    {
                        (bms-set-btn-wakeup-state -1)
                        (sleep-deep (bms-get-param 'sleep_long))
                    }
                    {
                        (sleep-config-wakeup-pin 0 1)
                        (bms-set-btn-wakeup-state 1)
                        (sleep-deep (bms-get-param 'sleep_regular))
                    }
                )
        })

        (init-hw)

        (beep 2 0.1)

        (if (can-active) (setq do-sleep false))

        (var soc -2.0)
        (var v-cells nil)
        (var tries 0)

        ; It takes a few reads to get valid voltages the first time
        (loopwhile (< soc -1.5) {
                (setq v-cells (with-com '(bms-get-vcells)))
                (var v-sorted (sort < v-cells))
                (setq c-min (ix v-sorted 0))
                (setq c-max (ix v-sorted -1))
                (setq soc (calc-soc c-min))
                (setq tries (+ tries 1))
                (sleep 0.1)
        })

        (setassoc rtc-val 'c-min c-min)
        (setassoc rtc-val 'c-max c-max)
        (setassoc rtc-val 'v-tot (apply + v-cells))
        (setassoc rtc-val 'soc soc)
        (setassoc rtc-val 'updated true)
        (save-rtc-val)

        (update-temps)

        (setq init-done true)

        (setq charge-ok (and
                (< c-max (bms-get-param 'vc_charge_end))
                (> c-min (bms-get-param 'vc_charge_min))
                (< t-max (bms-get-param 't_charge_max))
                (> t-min (bms-get-param 't_charge_min))
                (< t-mos (bms-get-param 't_charge_max_mos))
                (not (assoc rtc-val 'charge-fault))
        ))

        (var ichg 0.0)
        (if (and (test-chg 400) charge-ok charge-wakeup) {
                (set-chg true)

                (looprange i 0 (* charger-max-delay 10.0) {
                        (sleep 0.1)
                        (setq ichg (- (bms-current)))
                        (if (> ichg (bms-get-param 'min_charge_current)) {
                                (setq do-sleep false)
                                (setq trigger-bal-after-charge true)
                                (break)
                        })
                })
        })

        (if (and (< soc 0.05) (not trigger-bal-after-charge) (not (is-connected))) (setq do-sleep true))

        ;(sleep 5)
        ;(print v-cells)
        ;(print soc)
        ;(print ichg)
        ;(print do-sleep)
        ;(print tries)

        (if do-sleep {
                (with-com '(bms-sleep))
                (save-rtc-val)

                (if (< (assoc rtc-val 'soc) 0.05)
                    {
                        (bms-set-btn-wakeup-state -1)
                        (sleep-deep (bms-get-param 'sleep_long))
                    }
                    {
                        (sleep-config-wakeup-pin 0 1)
                        (bms-set-btn-wakeup-state 1)
                        (sleep-deep (bms-get-param 'sleep_regular))
                    }
                )
        })
})

; === TODO===
;
; = Sleep =
;  - Go to sleep when key is left on

; Persistent settings
; Format: (label . (offset type))
(def eeprom-addrs '(
        (ver-code    . (0 i))
        (ah-cnt      . (1 f))
        (wh-cnt      . (2 f))
        (ah-chg-tot  . (3 f))
        (wh-chg-tot  . (4 f))
        (ah-dis-tot  . (5 f))
        (wh-dis-tot  . (6 f))
        (ah-cnt-soc  . (7 f))
))

; Settings version
(def settings-version 242i32)

(defun read-setting (name)
    (let (
            (addr (first (assoc eeprom-addrs name)))
            (type (second (assoc eeprom-addrs name)))
        )
        (cond
            ((eq type 'i) (eeprom-read-i addr))
            ((eq type 'f) (eeprom-read-f addr))
            ((eq type 'b) (!= (eeprom-read-i addr) 0))
)))

(defun write-setting (name val)
    (let (
            (addr (first (assoc eeprom-addrs name)))
            (type (second (assoc eeprom-addrs name)))
        )
        (cond
            ((eq type 'i) (eeprom-store-i addr val))
            ((eq type 'f) (eeprom-store-f addr val))
            ((eq type 'b) (eeprom-store-i addr (if val 1 0)))
)))

(defun restore-settings () {
        (write-setting 'ah-cnt 0.0)
        (write-setting 'wh-cnt 0.0)
        (write-setting 'ah-chg-tot 0.0)
        (write-setting 'wh-chg-tot 0.0)
        (write-setting 'ah-dis-tot 0.0)
        (write-setting 'wh-dis-tot 0.0)
        (write-setting 'ah-cnt-soc (* (calc-soc c-min) (bms-get-param 'batt_ah)))
        (write-setting 'ver-code settings-version)
})

(defun save-settings () {
        (write-setting 'ah-cnt ah-cnt)
        (write-setting 'wh-cnt wh-cnt)
        (write-setting 'ah-chg-tot ah-chg-tot)
        (write-setting 'wh-chg-tot wh-chg-tot)
        (write-setting 'ah-dis-tot ah-dis-tot)
        (write-setting 'wh-dis-tot wh-dis-tot)
        (write-setting 'ah-cnt-soc ah-cnt-soc)
})

(defun lpf (val sample tc)
    (- val (* tc (- val sample)))
)

(defun set-chg (chg) {
        (if chg
            {
                (gpio-write 9 0)
                (bms-set-chg 1)
                (setq is-charging true)
            }
            {
                (bms-set-chg 0)
                (setq is-charging false)

                ; Trigger balancing when charging ends and the charge
                ; has been ongoing for at least 10 seconds.
                (if (> (secs-since charge-ts) 10.0) {
                        (setq trigger-bal-after-charge true)
                })

                (setq charge-ts (systime))
            }
        )
})

(defun send-can-info () {
        (var buf-canid35 (array-create 8))

        (var ah-left (* (bms-get-param 'batt_ah) (- 1.0 soc)))
        (var min-left (if (< iout -1.0)
                (* (/ ah-left (- iout)) 60.0)
                0.0
        ))

        (bufset-i16 buf-canid35 0 (* soc 1000)) ; Battery A SOC
        (bufset-u8 buf-canid35 2 (if (> vt-vchg (bms-get-param 'v_charge_detect)) 1 0)) ; Battery A Charging
        (bufset-u16 buf-canid35 3 min-left) ; Battery A Charge Time Minutes
        (bufset-u16 buf-canid35 5 (* (bms-get-param 'batt_ah) 10.0))
        (can-send-sid 35 buf-canid35)

        (send-bms-can)
})

(defun main-ctrl () (loopwhile t {
            ; Exit if any of the BQs has fallen asleep
            (if (or
                    (= (bms-direct-cmd 1 0x00) 4)
                    (and (> (bms-get-param 'cells_ic2) 0) (= (with-com '(bms-direct-cmd 2 0x00)) 4))
                )
                (exit-error 0)
            )

            ; Detect if short circuit has been latched
            (setq scd-latched (!= (bms-direct-cmd 1 0x02) 0))

            (if (and scd-latched (not scd-before)) (print "Shorciruit protection triggered!"))
            (setq scd-before scd-latched)

            ; Reset latch when button has been switched off
            (if (and scd-latched (= (bms-get-btn) 0))
                (bms-subcmd-cmdonly 1 0x009C)
            )

            ; Update short circuit threshold when it changes in the config
            (if (!= (bms-get-param 'psw_scd_tres) tres-scd-before) (config-scd))
            (setq tres-scd-before (bms-get-param 'psw_scd_tres))

            (var v-cells (with-com '(bms-get-vcells)))
            (var bms-temps (update-temps))
            (var temp-ext-num (truncate (bms-get-param 'temp_num) 0 4))

            (var c-sorted (sort < v-cells))
            (setq c-min (ix c-sorted 0))
            (setq c-max (ix c-sorted -1))

            (setq vtot (apply + v-cells))
            (setq vout (with-com '(bms-get-vout)))
            (setq vt-vchg (bms-get-vchg))
            (setq iout (bms-current))

            (looprange i 0 cell-num {
                    (set-bms-val 'bms-v-cell i (ix v-cells i))
                    (set-bms-val 'bms-bal-state i (bms-get-bal i))
            })

            (set-bms-val 'bms-temp-adc-num (+ 5 temp-ext-num))
            (set-bms-val 'bms-temps-adc 0 t-ic) ; IC
            (set-bms-val 'bms-temps-adc 1 t-min) ; Cell Min
            (set-bms-val 'bms-temps-adc 2 t-max) ; Cell Max
            (set-bms-val 'bms-temps-adc 3 t-mos) ; Mosfet

            ; Use channel 4 as ambient-sensor when not used as a cell sensor
            ; and when it shows a valid reading
            (if (and (< temp-ext-num 4) (> (ix bms-temps 4) -50))
                (set-bms-val 'bms-temps-adc 4 (ix bms-temps 4))
                (set-bms-val 'bms-temps-adc 4 -300.0)
            )

            (looprange i 0 temp-ext-num {
                    (set-bms-val 'bms-temps-adc (+ 5 i) (ix bms-temps (+ i 1)))
            })
            (set-bms-val 'bms-data-version 1)

            (set-bms-val 'bms-v-cell-min c-min)
            (set-bms-val 'bms-v-cell-max c-max)

            (if (= (bms-get-param 'soc_use_ah) 1)
                {
                    ; Coulomb counting
                    (setq soc (/ ah-cnt-soc (bms-get-param 'batt_ah)))
                }
                {
                    (if (>= soc 0.0)
                        (setq soc (lpf soc (calc-soc c-min) (* 100.0 (bms-get-param 'soc_filter_const))))
                        (setq soc (calc-soc c-min))
                    )
                }
            )

            (var dt (secs-since t-last))
            (setq t-last (systime))
            (var t-chg (mod (/ (systime) 1000 60) 255))

            (var ah (* iout (/ dt 3600.0)))
            (setq ah-cnt-soc (truncate (- ah-cnt-soc ah) 0.0 (bms-get-param 'batt_ah)))

            ; Ah and Wh cnt
            (if (> (abs iout) (bms-get-param 'min_current_ah_wh_cnt)) {
                    (var wh (* ah vtot))

                    (setq ah-cnt (+ ah-cnt ah))
                    (setq wh-cnt (+ wh-cnt wh))

                    (if (> iout 0.0)
                        {
                            (setq ah-dis-tot (+ ah-dis-tot ah))
                            (setq wh-dis-tot (+ wh-dis-tot wh))
                        }
                        {
                            (setq ah-chg-tot (- ah-chg-tot ah))
                            (setq wh-chg-tot (- wh-chg-tot wh))
                        }
                    )
            })

            (set-bms-val 'bms-v-tot vtot)
            (set-bms-val 'bms-v-charge vt-vchg)
            (set-bms-val 'bms-i-in-ic iout)
            (set-bms-val 'bms-temp-ic (ix bms-temps 0))
            (set-bms-val 'bms-temp-cell-max t-max)
            (set-bms-val 'bms-soc soc)
            (set-bms-val 'bms-soh 1.0)
            (set-bms-val 'bms-ah-cnt ah-cnt)
            (set-bms-val 'bms-wh-cnt wh-cnt)
            (set-bms-val 'bms-ah-cnt-chg-total ah-chg-tot)
            (set-bms-val 'bms-wh-cnt-chg-total wh-chg-tot)
            (set-bms-val 'bms-ah-cnt-dis-total ah-dis-tot)
            (set-bms-val 'bms-wh-cnt-dis-total wh-dis-tot)

            (with-com '(send-can-info))

            ;;; Charge control

            (setq charge-ok (and
                    (< c-max (if is-charging
                            (bms-get-param 'vc_charge_end)
                            (bms-get-param 'vc_charge_start)
                    ))
                    (> c-min (bms-get-param 'vc_charge_min))
                    (< t-max (bms-get-param 't_charge_max))
                    (> t-min (bms-get-param 't_charge_min))
                    (< t-mos (bms-get-param 't_charge_max_mos))
                    chg-allowed
                    (not (assoc rtc-val 'charge-fault))
            ))

            ; If charging is enabled and maximum charge current is exceeded a charge fault is latched
            (if (and is-charging (> (- iout) (bms-get-param 'max_charge_current))) {
                    (setq charge-ok false)
                    (setassoc rtc-val 'charge-fault true)
            })

            ; Reset latched charge fault after disconnecting charger for 5s
            (if (and (assoc rtc-val 'charge-fault) (> (secs-since charge-dis-ts) 5.0)) {
                    (setassoc rtc-val 'charge-fault false)
            })

            (setq chg-status
                (cond
                    ((assoc rtc-val 'charge-fault) "FLT_CHG_OC")
                    (is-charging "CHARGING")
                    (true "")
            ))

            ; Set combined BMS status
            (set-bms-val 'bms-status (str-merge
                    psw-status
                    (if (> (str-len chg-status) 0) (str-merge " | " chg-status) "")
                    (if (> (str-len bal-status) 0) (str-merge " | " bal-status) "")
            ))

            (if (and (test-chg 1) charge-ok)
                {
                    (if (< (secs-since charge-ts) charger-max-delay)
                        (set-chg true)
                        (set-chg (> (- iout) (bms-get-param 'min_charge_current)))
                    )
                }
                {
                    (set-chg nil)

                    ; Reset coulomb counter when battery is full
                    (if (>= c-max (bms-get-param 'vc_charge_start)) {
                            (setq ah-cnt-soc (bms-get-param 'batt_ah))
                            (setq trigger-bal-after-charge true)
                    })
                }
            )

            ;;; Sleep

            (setassoc rtc-val 'c-min c-min)
            (setassoc rtc-val 'c-max c-max)
            (setassoc rtc-val 'v-tot vtot)
            (setassoc rtc-val 'soc soc)
            (setassoc rtc-val 'updated true)
            (save-rtc-val)

            ; Measure time without current
            (if (> (abs iout) (bms-get-param 'min_current_sleep))
                (setq i-zero-time 0.0)
                (setq i-zero-time (+ i-zero-time dt))
            )

            ; Go to sleep when button is off, not balancing and not connected
            (if (and (= (bms-get-btn) 0) (> i-zero-time 1.0) (not is-balancing) (not (is-connected)) (not (can-active))) {
                    (sleep 0.1)
                    (if (= (bms-get-btn) 0) {
                            (save-rtc-val)
                            (save-settings)
                            (with-com '(bms-sleep))
                            (sleep-config-wakeup-pin 0 1)
                            (bms-set-btn-wakeup-state 1)
                            (sleep-deep (bms-get-param 'sleep_regular))
                    })
            })

            ; Set SOC to 0 below 2.9V and not under load.
            (if (and (> i-zero-time 10.0) (<= c-min (bms-get-param 'vc_empty))) {
                    (setq ah-cnt-soc 0.0)
            })

            ; Always go to sleep when SOC is too low
            (if (and (< soc 0.05) (> i-zero-time 1.0) (<= c-min (bms-get-param 'vc_empty)) (not (is-connected)) (not (can-active))) {
                    ; Sleep longer and do not use the key to wake up when
                    ; almost empty
                    (save-rtc-val)
                    (save-settings)
                    (with-com '(bms-sleep))
                    (bms-set-btn-wakeup-state -1)
                    (sleep-deep (bms-get-param 'sleep_long))
            })

            (sleep 0.1)
}))

; Balancing
(defun balance () (loopwhile t {
            ; Disable balancing and wait for a bit to get clean
            ; measurements
            (looprange i 0 cell-num (with-com `(bms-set-bal ,i 0)))
            (sleep 2.0)

            (var v-cells (with-com '(bms-get-vcells)))

            (var cells-sorted (sort (fn (x y) (> (ix x 1) (ix y 1)))
                (map (fn (x) (list x (ix v-cells x))) (range cell-num)))
            )

            (var c-min (second (ix cells-sorted -1)))
            (var c-max (second (ix cells-sorted 0)))

            (if trigger-bal-after-charge (setq bal-ok true))

            (if (> (* (abs iout) (if is-balancing 0.8 1.0)) (bms-get-param 'balance_max_current)) {
                    (setq bal-ok false)
            })

            (if (< c-min (bms-get-param 'vc_balance_min)) {
                    (setq bal-ok false)
            })

            (if (> t-max (bms-get-param 't_bal_max_cell)) {
                    (setq bal-ok false)
            })

            (if (> t-ic (bms-get-param 't_bal_max_ic)) {
                    (setq bal-ok false)
            })

            (if bal-ok (setq trigger-bal-after-charge false))

            (if bal-ok {
                    (var bal-chs (map (fn (x) 0) (range cell-num)))
                    (var ch-cnt 0)

                    (loopforeach c cells-sorted {
                            (var n-cell (first c))
                            (var v-cell (second c))

                            (if (and
                                    (> (- v-cell c-min)
                                        (if is-balancing
                                            (bms-get-param 'vc_balance_end)
                                            (bms-get-param 'vc_balance_start)
                                    ))
                                    ; Do not balance adjacent cells
                                    (or (eq n-cell 0) (= (ix bal-chs (- n-cell 1)) 0))
                                    (or (eq n-cell (- cell-num 1)) (= (ix bal-chs (+ n-cell 1)) 0))
                                )
                                {
                                    (setix bal-chs n-cell 1)
                                    (setq ch-cnt (+ ch-cnt 1))
                            })

                            (if (>= ch-cnt (bms-get-param 'max_bal_ch)) (break))
                    })

                    (looprange i 0 cell-num (with-com `(bms-set-bal ,i ,(ix bal-chs i))))

                    (setq is-balancing (> ch-cnt 0))
            })

            (if (not bal-ok) {
                    (looprange i 0 cell-num (with-com `(bms-set-bal ,i 0)))
                    (setq is-balancing false)
            })

            (setq bal-status (if is-balancing "BAL" ""))

            (var bal-ok-before bal-ok)
            (looprange i 0 15 {
                    (if (not (eq bal-ok-before bal-ok)) (break))
                    (sleep 1.0)
            })
}))

(defun event-handler ()
    (loopwhile t
        (recv
            ((event-bms-chg-allow (? allow)) (setq chg-allowed (= allow 1)))
            ((event-bms-reset-cnt (? ah) (? wh)) {
                    (if (= ah 1) (setq ah-cnt 0.0))
                    (if (= wh 1) (setq wh-cnt 0.0))
            })
            ((event-bms-force-bal (? v)) (if (= v 1)
                    (setq bal-ok true)
                    (setq bal-ok false)
            ))
            (_ nil)
            ;((? a) (print a))
)))

(defun start-hum-thd ()
    ; Use humidity sensor if it is detected on the i2c-bus
    (if (i2c-detect-addr 0x40) {
            (i2c-tx-rx 0x40 '(2 0x10 0)) ; Temperature and humidity in sequence
            (i2c-tx-rx 0x40 '(0)) ; Start first measurement

            (loopwhile-thd ("hum" 100) t {
                    (sleep 0.5)
                    (var rx (bufcreate 4))
                    (i2c-tx-rx 0x40 '() rx)
                    (i2c-tx-rx 0x40 '(0)) ; Start next measurement
                    (var hum (* (/ (bufget-u16 rx 2) 65536.0) 100.0))
                    (var hum-temp (- (* (/ (bufget-u16 rx 0) 65536.0) 165.0) 40.0))

                    (set-bms-val 'bms-hum hum)
                    (set-bms-val 'bms-temp-hum hum-temp)
            })
}))

(defun main () {
	(set-fw-name "harmony32")

        ; Compatibility Check
        (loopwhile (!= (bms-fw-version) 6) {
                (if (< (bms-fw-version) 6)
                    (print "Firmware too old, please update")
                    (print "Package too old, please update")
                )

                (gpio-write 9 0) ; Enable CAN
                (sleep 5)
        })

        (def charge-dis-ts (systime))
        (def t-last (systime))
        (def charge-ts (systime))

        ; Buzzer
        (pwm-start 4000 0.0 0 3)

        (if (= (bufget-u8 (rtc-data) 900) rtc-val-magic) {
                (var tmp (unflatten (rtc-data)))
                (if tmp (setq rtc-val tmp))
        })

        (def cell-num (+ (bms-get-param 'cells_ic1) (bms-get-param 'cells_ic2)))

        ; First boot
        (if (= (assoc rtc-val 'wakeup-cnt) 0) {
                ; Increase charger detection voltage if it is set too low
                (if (< (bms-get-param 'v_charge_detect) 15) {
                        (bms-set-param 'v_charge_detect 30.0)
                        (bms-store-cfg)
                })

                ; Wait here on the first boot so that the upper BQ does not shut down its regulator
                ; when communicating with it before all connectors are plugged in.
                (looprange i 0 120 {
                        (set-bms-val 'bms-status (str-from-n (- 120 i) "Waiting %d"))
                        (sleep 1.0)
                })
        })
        (set-bms-val 'bms-status "Initializing...")

        ; Power switch
        (loopwhile-thd ("PSW" 100) t {
                (loopwhile (not (main-init-done)) (sleep 0.1))

                (if (and
                        psw-state
                        (or
                            (and (= (bms-get-param 't_psw_en) 1) (> t-mos (bms-get-param 't_psw_max_mos)))
                            scd-latched
                    ))
                    {
                        (bms-set-pchg 0)
                        (bms-set-out 0)

                        (setq psw-status (if scd-latched "FLT_PSW_SHORT" "FLT_PSW_OT"))
                })

                (if (and (= (bms-get-btn) 0) psw-state) {
                        (psw-off)
                        (setq psw-status "PSW_OFF")
                })

                (if (and (= (bms-get-btn) 1) (not psw-state)) {
                        (setq psw-status (if (psw-on) "PSW_ON" "FLT_PCHG"))
                })

                (sleep 0.2)
        })

        ; Quick PSW is enabled and BTN is on.
        (if (and (= (bms-get-btn) 1) (= (bms-get-param 'psw_wait_init) 0) (= (bms-get-param 'psw_scd_en) 0)) {
                ; Wake up lower BQ as it can hold the enable line low otherwise
                (bms-subcmd-cmdonly 1 0x000e)
                (bms-subcmd-cmdonly 1 0x000e)

                ; Give PSW some time start the precharge before starting the
                ; slow init-function so that PSW gets the mutex first.
                (sleep 1.0)
        })

        (def t-start-fun (secs-since 0))

        (loopwhile t {
                (match (trap (start-fun))
                    ((exit-ok (? a)) (break))
                    (_ nil)
                )
                (sleep 1.0)
        })

        ; Restore settings if version number does not match
        ; as that probably means something else is in eeprom
        (if (not-eq (read-setting 'ver-code) settings-version) (restore-settings))

        (def ah-cnt (read-setting 'ah-cnt))
        (def wh-cnt (read-setting 'wh-cnt))
        (def ah-chg-tot (read-setting 'ah-chg-tot))
        (def wh-chg-tot (read-setting 'wh-chg-tot))
        (def ah-dis-tot (read-setting 'ah-dis-tot))
        (def wh-dis-tot (read-setting 'wh-dis-tot))
        (def ah-cnt-soc (read-setting 'ah-cnt-soc))

        (event-register-handler (spawn event-handler))
        (event-enable 'event-bms-chg-allow)
        (event-enable 'event-bms-bal-ovr)
        (event-enable 'event-bms-reset-cnt)
        (event-enable 'event-bms-force-bal)
        (event-enable 'event-bms-zero-ofs)

        (set-bms-val 'bms-cell-num cell-num)
        (set-bms-val 'bms-can-id (can-local-id))

        (def tres-scd-before (bms-get-param 'psw_scd_tres))
        (def scd-before false)

        (loopwhile-thd ("main-ctrl" 200) t {
                (trap (main-ctrl))
                (setq did-crash true)
                (loopwhile did-crash (sleep 1.0))
        })

        (loopwhile-thd ("balance" 200) t {
                (trap (balance))
                (setq did-crash true)
                (loopwhile did-crash (sleep 1.0))
        })

        (loopwhile-thd ("re-init" 200) t {
                (if did-crash {
                        (com-force true)
                        (init-hw)
                        (com-force false)
                        (bms-set-chg 0)
                        (setq did-crash false)
                        (setq crash-cnt (+ crash-cnt 1))
                })

                (sleep 0.1)
        })

        (loopwhile-thd ("sleep-unblock" 100) t {
                (var sleep-unblock-ok (fn () (and
                            (= (bms-get-param 'block_sleep) 1)
                            (< (- c-max c-min) 0.05)
                            (> c-min 2.4)
                            (> (secs-since 0) 3600)
                            sleep-unblock-en
                )))

                (var should-unblock true)
                (looprange i 0 60 {
                        (if (not (sleep-unblock-ok)) {
                                (setq should-unblock false)
                        })
                        (sleep 1.0)
                })

                (if should-unblock {
                        (bms-set-param 'block_sleep 0)
                        (bms-store-cfg)
                        (print "Block sleep disabled")
                        (beep 4 0.2)

                })
        })

        (start-hum-thd)
})

@const-end

(image-save)
(main)
