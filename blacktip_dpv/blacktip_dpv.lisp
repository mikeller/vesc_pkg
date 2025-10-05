(defun eeprom_set_defaults ()
{
    (if (not-eq (eeprom-read-i 127) (to-i32 1)) {
        (puts "EEPROM: Initializing defaults for 1.0.0")
        ; Check for current version marker (blacktip_dpv release 1.0.0)
        ; New settings added in version 1.0.0
        (eeprom-store-i 25 0) ; Enable Auto-Engage Smart Cruise. 1=On 0=Off
        (eeprom-store-i 26 10) ; Auto-Engage Time in seconds (5-30 seconds)
        (eeprom-store-i 27 0) ; Enable Thirds warning on from power-up. 1=On 0=Off
        (eeprom-store-i 28 0) ; Battery calculation method: 0=Voltage-based, 1=Ampere-hour based
        (eeprom-store-i 29 0) ; Enable Debug Logging. 1=On 0=Off

        (if (not-eq (eeprom-read-i 127) (to-i32 150)) {
            (puts "EEPROM: No previous version detected, setting all defaults")
            ; Check for previous version marker (Dive Xtras V1.50 'Poseidon')
            ; User speeds, ie 1 thru 8 are only used in the GUI, this lisp code uses speeds 0-9 with 0 & 1 being the 2 reverse speeds.
            ; 99 is used as the "off" speed
            (eeprom-store-i 0 45) ; Reverse Speed 2 %
            (eeprom-store-i 1 20) ; Untangle Speed 1 %
            (eeprom-store-i 2 30) ; Speed 1 %
            (eeprom-store-i 3 38) ; Speed 2 %
            (eeprom-store-i 4 46) ; Speed 3 %
            (eeprom-store-i 5 54) ; Speed 4 %
            (eeprom-store-i 6 62) ; Speed 5 %
            (eeprom-store-i 7 70) ; Speed 6 %
            (eeprom-store-i 8 78) ; Speed 7 %
            (eeprom-store-i 9 100) ; Speed 8 %
            (eeprom-store-i 10 9) ; Maximum number of Speeds to use, must be greater or equal to start_speed (actual speed #, not user speed)
            (eeprom-store-i 11 4) ; Speed the scooter starts in. Range 2-9, must be less or equal to the max_speed_no (actual speed #, not user speed)
            (eeprom-store-i 12 7) ; Speed to jump to on triple click, (actual speed #, not user speed)
            (eeprom-store-i 13 1) ; Turn safe start on or off 1=On 0=Off
            (eeprom-store-i 14 0) ; Enable Reverse speed. 1=On 0=Off
            (eeprom-store-i 15 0) ; Enable 5 click Smart Cruise. 1=On 0=Off
            (eeprom-store-i 16 60) ; How long before Smart Cruise times out and requires reactivation in sec.
            (eeprom-store-i 17 0) ; rotation of Display, 0-3 . Each number rotates display 90 deg.
            (eeprom-store-i 18 5) ; Display Brighness 0-5
            (eeprom-store-i 19 0) ; Hardware configuration, 0 = Blacktip HW60 + Ble, 1 = Blacktip HW60 - Ble, 2 = Blacktip HW410 - Ble, 3 = Cuda-X HW60 + Ble, 4 = Cuda-X HW60 - Ble
            (eeprom-store-i 20 0) ; Battery Beeps
            (eeprom-store-i 21 3) ; Beep Volume
            (eeprom-store-i 22 0) ; CudaX Flip Screens
            (eeprom-store-i 23 0) ; 2nd Screen rotation of Display, 0-3 . Each number rotates display 90 deg.
            (eeprom-store-i 24 0) ; Trigger Click Beeps
        })
        ; Mark as initialised for 1.0.0
        (eeprom-store-i 127 1) ; indicate that the defaults have been applied
        (puts "EEPROM: Defaults initialized successfully")
    })
})

(defun update_settings() ; Program that reads eeprom and writes to variables
{
    (define max_speed_no (eeprom-read-i 10))
    (define start_speed (eeprom-read-i 11))
    (define jump_speed (eeprom-read-i 12))
    (define use_safe_start (eeprom-read-i 13))
    (define enable_reverse (eeprom-read-i 14))
    (define enable_smart_cruise (eeprom-read-i 15))
    (define smart_cruise_timeout (eeprom-read-i 16))
    (define rotation (eeprom-read-i 17))
    (define disp_brightness (eeprom-read-i 18))
    (define hardware_configuration (eeprom-read-i 19))
    (define enable_battery_beeps (eeprom-read-i 20))
    (define beeps_vol (eeprom-read-i 21))
    (define cudax_flip (eeprom-read-i 22))
    (define rotation2 (eeprom-read-i 23))
    (define enable_trigger_beeps (eeprom-read-i 24))
    (define enable_smart_cruise_auto_engage (eeprom-read-i 25))
    (define smart_cruise_auto_engage_time (eeprom-read-i 26))
    (define enable_thirds_warning_startup (eeprom-read-i 27))
    (define battery_calculation_method (eeprom-read-i 28))
    (define debug_enabled (eeprom-read-i 29))

    (define speed_set (list
        (eeprom-read-i 0) ; Reverse Speed 2 %
        (eeprom-read-i 1) ; Untangle Speed 1 %
        (eeprom-read-i 2) ; Speed 1 %
        (eeprom-read-i 3) ; Speed 2 %
        (eeprom-read-i 4) ; Speed 3 %
        (eeprom-read-i 5) ; Speed 4 %
        (eeprom-read-i 6) ; Speed 5 %
        (eeprom-read-i 7) ; Speed 6 %
        (eeprom-read-i 8) ; Speed 7 %
        (eeprom-read-i 9) ; Speed 8 %
    ))

    ; Sets scooter type, 0 = Blacktip, 1 = Cuda X
    (if (<= hardware_configuration HARDWARE_BLACKTIP_MAX)
        (define scooter_type SCOOTER_BLACKTIP)
        (define scooter_type SCOOTER_CUDAX)
    )

    ; Log configuration on startup
    (debug-log (str-merge "Config loaded: HW=" (to-str hardware_configuration)
                     " Type=" (to-str scooter_type)
                     " Debug=" (to-str debug_enabled)
                     " BattCalc=" (to-str battery_calculation_method)))
})

(move-to-flash update_settings)

; Debug logging helper function
(defun debug_log (msg)
{
    (if (and (not-eq debug_enabled nil) (= debug_enabled 1))
        (puts msg)
    )
})

(move-to-flash debug_log)

(defun calculate-corrected-battery ()
    ; Calculate corrected battery percentage from raw battery reading
    (let ((raw-batt (get-batt)))
        (+ (* BATTERY_COEFF_4 raw-batt raw-batt raw-batt raw-batt)
           (* BATTERY_COEFF_3 raw-batt raw-batt raw-batt)
           (* BATTERY_COEFF_2 raw-batt raw-batt)
           (* BATTERY_COEFF_1 raw-batt))))

(move-to-flash calculate-corrected-battery)

(defun calculate-ah-based-battery ()
    ; Calculate battery percentage based on ampere-hours used vs total capacity
    (let ((total-capacity (conf-get 'si-battery-ah))
          (used-ah (get-ah))
          (used_capacity (- 1.0 (/ used-ah total-capacity))))
        (if (and (> total-capacity 0) (> used_capacity 0))
            used_capacity
            0.0 ; Return 0% if no capacity configured or used capacity is negative
        )
    )
)

(move-to-flash calculate-ah-based-battery)

(defun get-battery-level ()
    ; Get battery level using the configured calculation method
    (if (= battery_calculation_method 1)
        (calculate-ah-based-battery)
        (calculate-corrected-battery)))

(move-to-flash get-battery-level)

(defun my_data_recv_prog (data)
{
    (if (= (bufget-u8 data 0) HANDSHAKE_CODE) { ; Handshake to trigger data send if not yet received.
        (define setbuf (array-create EEPROM_SETTINGS_COUNT)) ; create a temp array to store setting
        (bufclear setbuf) ; clear the buffer
        (looprange i 0 EEPROM_SETTINGS_COUNT
            (bufset-i8 setbuf i (or (eeprom-read-i i) 0)))
        (send-data setbuf)
        (free setbuf)
    } {
        (looprange i 0 EEPROM_SETTINGS_COUNT
            (eeprom-store-i i (bufget-u8 data i))) ; writes settings to eeprom
        (update_settings) ; updates actual settings in lisp
    })
})

(move-to-flash my_data_recv_prog)

(defun setup_event_handler()
{
    (defun event-handler ()
    {
        (loopwhile t
            (recv
                ((event-data-rx . (? data)) (my_data_recv_prog data))
                (_ nil))
        )
    })

    (event-register-handler (spawn event-handler))
    (event-enable 'event-data-rx)
})

(move-to-flash setup_event_handler)

(defun start_trigger_loop()
{
    (gpio-configure 'pin-ppm 'pin-mode-in-pd)
    (define sw_pressed 0)

    (loopwhile-thd THREAD_STACK_GPIO t {
        (sleep SLEEP_MOTOR_CONTROL)
        (if (= 1 (gpio-read 'pin-ppm))
            (setvar 'sw_pressed 1)
            (setvar 'sw_pressed 0)
        )
    })
})

(move-to-flash start_trigger_loop)

(defun start_smart_cruise_loop()
{
    (debug_log "Smart Cruise: Starting loop")
    (define smart_cruise SMART_CRUISE_OFF) ; variable to control Smart Cruise on 5 clicks

    (let ((speed_setting_timer 0) ; Timer for auto-engage functionality
          (last_speed_setting SPEED_OFF)) { ; Track last speed setting for auto-engage

        (loopwhile-thd THREAD_STACK_SMART_CRUISE t {
            (sleep SLEEP_BACKGROUND_CHECK)
            (if (and (> enable_smart_cruise 0) (> enable_smart_cruise_auto_engage 0) (= sw_state STATE_PRESSED) (= smart_cruise SMART_CRUISE_OFF) (!= speed SPEED_OFF) (>= speed SPEED_REVERSE_THRESHOLD)) {
                ; Check if speed setting has changed
                (if (!= speed last_speed_setting) {
                    (setvar 'last_speed_setting speed)
                    (setvar 'speed_setting_timer (systime))
                } {
                    ; Speed setting hasn't changed, check if timer expired
                    (if (> (secs-since speed_setting_timer) smart_cruise_auto_engage_time) {
                        (debug_log "Smart Cruise: Auto-engaged")
                        (setvar 'smart_cruise SMART_CRUISE_AUTO_ENGAGED)
                        (setvar 'timer_start (systime))
                        (setvar 'disp_num DISPLAY_SMART_CRUISE_FULL)
                        (setvar 'click_beep CLICKS_QUINTUPLE)
                        (if (< speed SPEED_REVERSE_THRESHOLD) ; re command actual speed as reverification sets it to 0.8x
                            (set-rpm (- 0 (* (/ (ix max_erpm scooter_type) 100)(ix speed_set speed))))
                            (set-rpm (* (/ (ix max_erpm scooter_type) 100)(ix speed_set speed)))
                        )
                    })
                })
            } {
                ; Not in the right state for auto-engage, reset timer
                (setvar 'speed_setting_timer (systime))
            })
        })
    })
})

(move-to-flash start_smart_cruise_loop)


; =============================================================================
; Constants
; =============================================================================

; Sleep intervals (seconds) - controls loop frequencies
(define SLEEP_STATE_MACHINE 0.02)     ; 50Hz - button state polling
(define SLEEP_MOTOR_CONTROL 0.04)     ; 25Hz - motor/GPIO polling
(define SLEEP_MOTOR_SPEED_CHANGE 0.25) ; 4Hz - motor speed transitions
(define SLEEP_UI_UPDATE 0.25)         ; 4Hz - display/beeper updates
(define SLEEP_BACKGROUND_CHECK 0.5)   ; 2Hz - Smart Cruise checking
(define SLEEP_BATTERY_STABILIZE 1.0)  ; 1Hz - one-time battery reading delay

; Timer durations (seconds)
(define TIMER_DISABLED 86400)         ; 24 hours - effectively infinite for scooter operation
(define TIMER_CLICK_WINDOW 0.3)       ; Click detection window
(define TIMER_RELEASE_WINDOW 0.5)     ; Release detection window
(define TIMER_SMART_CRUISE_TIMEOUT 5) ; Smart Cruise half-enable timeout
(define TIMER_DISPLAY_DURATION 5)     ; Display duration (used in calculations)
(define TIMER_LONG_PRESS 10)          ; Long press duration for special functions

; Thread priorities (lower number = higher priority)
; Thread stack sizes (in 4-byte words) for loopwhile-thd and spawn
; Stack size determines memory allocated for thread's local variables and call stack
; According to LispBM docs, typical values are 100-200 words (400-800 bytes)
; Stack requirements depend on: expression nesting depth, recursion, and function argument count
;
; Analysis of current threads:
; - GPIO: Simple pin read + variable set → minimal needs but should meet 100-word minimum
; - SmartCruise: Nested conditionals + arithmetic + multiple function calls → needs substantial stack
; - State machines: Spawn short-lived processes with moderate conditional logic
; - Motor: Most complex - deep nesting, string ops, list operations, spawning → needs largest stack
; - Display/Battery: I2C operations + moderate conditionals → needs good stack
; - ClickBeep: Simple timer checks + beep calls → modest needs
(define THREAD_STACK_GPIO 100)        ; GPIO reading - increased from 25 to meet minimum recommendation
(define THREAD_STACK_SMART_CRUISE 150) ; Smart Cruise - increased from 30 for nested conditionals + function calls
(define THREAD_STACK_STATE_MACHINE 120) ; State 2 (pressed) - increased from 30 for state logic
(define THREAD_STACK_STATE_TRANSITIONS 120) ; States 0, 3 - increased from 35 for consistency
(define THREAD_STACK_STATE_COUNTING 120) ; State 1 (counting clicks) - increased from 40 for consistency
(define THREAD_STACK_MOTOR 200)       ; Motor control - increased from 65, most complex thread
(define THREAD_STACK_DISPLAY 150)     ; Display updates - increased from 45 for I2C + conditionals
(define THREAD_STACK_BATTERY 150)     ; Battery display - increased from 45 for I2C + conditionals
(define THREAD_STACK_CLICK_BEEP 100)  ; Click beep playback - kept at 100 (already appropriate)

; State values
(define STATE_OFF 0)
(define STATE_COUNTING_CLICKS 1)
(define STATE_PRESSED 2)
(define STATE_GOING_OFF 3)

; Special speed values
(define SPEED_OFF 99)                 ; Motor off indicator
(define SPEED_REVERSE_THRESHOLD 2)    ; Speeds below this are reverse
(define SPEED_SOFT_START_SENTINEL 0.5) ; Sentinel value for soft start tracking

; Click counts
(define CLICKS_SINGLE 1)
(define CLICKS_DOUBLE 2)
(define CLICKS_TRIPLE 3)
(define CLICKS_QUADRUPLE 4)
(define CLICKS_QUINTUPLE 5)

; Smart Cruise states
(define SMART_CRUISE_OFF 0)
(define SMART_CRUISE_HALF_ENABLED 1)
(define SMART_CRUISE_FULLY_ENABLED 2)
(define SMART_CRUISE_AUTO_ENGAGED 3)

; Hardware configuration thresholds
(define HARDWARE_BLACKTIP_MAX 2)      ; Hardware configs 0-2 are Blacktip

; Scooter types (indices into hardware lists)
(define SCOOTER_BLACKTIP 0)
(define SCOOTER_CUDAX 1)

; Motor control constants
(define MAX_ERPM_BLACKTIP 4100)
(define MAX_ERPM_CUDAX 7100)
(define MAX_CURRENT_BLACKTIP 22.8)
(define MAX_CURRENT_CUDAX 46)
(define MIN_CURRENT_BLACKTIP 1.7)
(define MIN_CURRENT_CUDAX 0.35)

; Safe start parameters
(define SAFE_START_DUTY 0.06)         ; Initial duty cycle for soft start
(define SAFE_START_TIMEOUT 0.5)       ; Timeout for safe start checks
(define SAFE_START_MIN_RPM 350)       ; Minimum RPM for safe start success
(define SAFE_START_MIN_DUTY 0.05)     ; Minimum duty for safe start check
(define SAFE_START_MAX_CURRENT 5)     ; Maximum current during safe start spin-up
(define SAFE_START_FAIL_CURRENT 8)    ; Current threshold for safe start failure

; Smart Cruise speed adjustment (slowdown to 80%)
(define SMART_CRUISE_SLOWDOWN_DIVISOR 125) ; Divide by 125 instead of 100 for 80%

; Display offset (speed value to display number mapping)
(define DISPLAY_SPEED_OFFSET 4)

; Display numbers for special screens
(define DISPLAY_OFF 14)
(define DISPLAY_SMART_CRUISE_HALF 16)
(define DISPLAY_SMART_CRUISE_FULL 17)
(define DISPLAY_SENTINEL 99)          ; Sentinel for "no previous display"

; Warbler beep parameters
(define WARBLER_FREQUENCY 450)
(define WARBLER_DURATION 0.2)

; Display timing calculations (from State 2 repeat display)
(define DISPLAY_REPEAT_FIRST 6)       ; display duration + 1
(define DISPLAY_REPEAT_SECOND 12)     ; 2 * display duration + 2

; EEPROM settings buffer size
(define EEPROM_SETTINGS_COUNT 30)

; Battery polynomial coefficients (for voltage-based calculation)
(define BATTERY_COEFF_4 4.3867)
(define BATTERY_COEFF_3 -6.7072)
(define BATTERY_COEFF_2 2.4021)
(define BATTERY_COEFF_1 1.3619)

; Data receive handshake code
(define HANDSHAKE_CODE 255)

; Display timer stop value
(define DISPLAY_TIMER_STOP 2)

; =============================================================================
; State Machine Design Notes:
; - Each state handler runs in a loop checking (= sw_state N)
; - When transitioning, sw_state is updated, new handler spawned, and (break) called
; - The loop condition prevents race conditions by ensuring old handler exits
; - Old thread terminates naturally when loop condition becomes false
; =============================================================================

(defun setup_state_machine()
{
    (define sw_state 0)
    (define timer_start 0)
    (define timer_duration 0)
    (define clicks 0)
    (define actual_batt 0)
    (define new_start_speed start_speed)
})

(move-to-flash setup_state_machine)


; =============================================================================
; Speed Bounds Checking
; =============================================================================

; Helper function to safely set speed with bounds checking
; Valid speeds: 0 (reverse 2), 1 (reverse 1/untangle), 2-max_speed_no (forward), 99 (off)
; Returns the actual speed that was set after bounds checking
(defun set_speed_safe (new_speed)
{
    (let ((clamped_speed new_speed))
    {
        (if (= new_speed SPEED_OFF) {
            ; Speed 99 (OFF) is always valid
            (setvar 'speed SPEED_OFF)
            (debug_log "Speed: Set to OFF")
        } {
            ; Clamp to valid range
            (if (< new_speed 0) {
                (setvar 'clamped_speed 0)
                (debug_log (str-merge "Speed: Clamped " (to-str new_speed) " to 0 (underflow)"))
            })

            (if (> clamped_speed max_speed_no) {
                (setvar 'clamped_speed max_speed_no)
                (debug_log (str-merge "Speed: Clamped " (to-str new_speed) " to " (to-str max_speed_no) " (overflow)"))
            })

            ; Check reverse enable
            (if (and (< clamped_speed SPEED_REVERSE_THRESHOLD) (= enable_reverse 0)) {
                (setvar 'clamped_speed SPEED_REVERSE_THRESHOLD)
                (debug_log (str-merge "Speed: Reverse disabled, clamped " (to-str new_speed) " to " (to-str SPEED_REVERSE_THRESHOLD)))
            })

            (setvar 'speed clamped_speed)
            (debug_log (str-merge "Speed: Set to " (to-str clamped_speed)))
        })
        clamped_speed
    })
})

(move-to-flash set_speed_safe)


(defun state_handler_off ()
{
    ; xxxx State "0" Off
    (debug_log "State 0: Off")
    (loopwhile (= sw_state STATE_OFF) {
        (sleep SLEEP_STATE_MACHINE)
        ; Calculate corrected batt %, only needed when scooter is off in state 0
        (setvar 'actual_batt (get-battery-level))

        ; Pressed
        (if (= sw_pressed 1) {
            (debug_log "State 0->1: Button pressed")
            (setvar 'batt_disp_timer_start 0) ; Stop Battery Display in case its running
            (setvar 'disp_timer_start DISPLAY_TIMER_STOP) ; Stop Display in case its running
            (setvar 'timer_start (systime))
            (setvar 'timer_duration TIMER_CLICK_WINDOW)
            (setvar 'clicks CLICKS_SINGLE)
            (setvar 'sw_state STATE_COUNTING_CLICKS)
            (spawn THREAD_STACK_STATE_COUNTING state_handler_counting_clicks)
            (break)
        })
    })
})

(move-to-flash state_handler_off)


; Helper functions for click actions
(defun handle_single_click ()
{
    (if (and (= clicks CLICKS_SINGLE) (!= speed SPEED_OFF)) {
        (debug_log "Click action: Single click (speed down)")
        (setvar 'click_beep CLICKS_SINGLE)
        (if (> speed SPEED_REVERSE_THRESHOLD)
            (set_speed_safe (- speed 1))
            (if (= speed 0)
                (set_speed_safe 1)
            )
        )
    })
})

(defun handle_double_click ()
{
    (if (= clicks CLICKS_DOUBLE) {
        (if (= speed SPEED_OFF)
            {
                (debug_log (str-merge "Click action: Double click (start at speed " (to-str new_start_speed) ")"))
                (set_speed_safe new_start_speed)
            }
            {
                (debug_log "Click action: Double click (speed up)")
                (setvar 'click_beep CLICKS_DOUBLE)
                (if (< speed max_speed_no)
                    (if (> speed 1)
                        (set_speed_safe (+ speed 1))
                        (set_speed_safe 0)
                    )
                )
            }
        )
    })
})

(defun handle_triple_click ()
{
    (if (= clicks CLICKS_TRIPLE) {
        (debug_log (str-merge "Click action: Triple click (jump to speed " (to-str jump_speed) ")"))
        (if (!= speed SPEED_OFF)
            (setvar 'click_beep CLICKS_TRIPLE)
        )
        (set_speed_safe jump_speed)
    })
})

(defun handle_quadruple_click ()
{
    (if (and (= clicks CLICKS_QUADRUPLE) (= 1 enable_reverse)) {
        (debug_log "Click action: Quadruple click (untangle)")
        (if (!= speed SPEED_OFF)
            (setvar 'click_beep CLICKS_QUADRUPLE)
        )
        (set_speed_safe 1)
    })
})

(defun handle_quintuple_click ()
{
    (if (= clicks CLICKS_QUINTUPLE) {
        (debug_log (str-merge "Click action: Quintuple click (Smart Cruise " (to-str smart_cruise) "->" (to-str (+ smart_cruise 1)) ")"))
        (setvar 'click_beep CLICKS_QUINTUPLE)
        (if (and (!= speed SPEED_OFF) (> enable_smart_cruise 0) (< smart_cruise SMART_CRUISE_FULLY_ENABLED))
            (setvar 'smart_cruise (+ 1 smart_cruise))
        )

        (if (= smart_cruise SMART_CRUISE_HALF_ENABLED) {
            (debug_log "Smart Cruise: Half-enabled (waiting for confirmation)")
            (setvar 'disp_num DISPLAY_SMART_CRUISE_HALF)
            (setvar 'last_disp_num DISPLAY_SENTINEL)
        })

        (if (= smart_cruise SMART_CRUISE_FULLY_ENABLED) {
            (debug_log "Smart Cruise: Fully enabled")
            (setvar 'disp_num DISPLAY_SMART_CRUISE_FULL)
            (if (< speed SPEED_REVERSE_THRESHOLD)
                (set-rpm (- 0 (* (/ (ix max_erpm scooter_type) 100)(ix speed_set speed))))
                (set-rpm (* (/ (ix max_erpm scooter_type) 100)(ix speed_set speed)))
            )
        })
    })
})

(move-to-flash handle_single_click)
(move-to-flash handle_double_click)
(move-to-flash handle_triple_click)
(move-to-flash handle_quadruple_click)
(move-to-flash handle_quintuple_click)


; xxxx STATE 1 Counting clicks

(defun state_handler_counting_clicks ()
{
    (debug_log (str-merge "State 1: Counting clicks=" (to-str clicks)))
    (loopwhile (= sw_state STATE_COUNTING_CLICKS) {
        (sleep SLEEP_STATE_MACHINE)

        ; Released
        (if (= sw_pressed 0) {
            (setvar 'disp_timer_start DISPLAY_TIMER_STOP) ; Stop Display in case its running
            (setvar 'timer_start (systime))
            (setvar 'timer_duration TIMER_RELEASE_WINDOW)
            (setvar 'sw_state STATE_GOING_OFF)
            (spawn THREAD_STACK_STATE_TRANSITIONS state_handler_going_off)
            (break)
        })

        ; Timer Expiry
        (if (> (secs-since timer_start) timer_duration) {
            (debug_log (str-merge "State 1: Timer expired, clicks=" (to-str clicks)))

            ; Process click actions
            (handle_single_click)
            (handle_double_click)
            (handle_triple_click)
            (handle_quadruple_click)
            (handle_quintuple_click)

            ; End of Click Actions
            (debug_log (str-merge "State 1->2: Speed=" (to-str speed)))
            (setvar 'clicks 0)
            (setvar 'timer_duration TIMER_DISABLED)
            (setvar 'sw_state STATE_PRESSED)
            (spawn THREAD_STACK_STATE_MACHINE state_handler_pressed)
            (break)
        })
    })
})

(move-to-flash state_handler_counting_clicks)


; xxxx State 2 "Pressed"
(defun state_handler_pressed()
{
    (debug_log "State 2: Pressed")
   (loopwhile (= sw_state STATE_PRESSED) {
     (sleep SLEEP_STATE_MACHINE)
        (timeout-reset) ; keeps motor running

        ; xxx repeat display section whilst scooter is running xxx
        (if (and (> (secs-since timer_start) DISPLAY_REPEAT_FIRST) (= smart_cruise SMART_CRUISE_OFF)) ; 6 = display duration +1
            (setvar 'disp_num last_batt_disp_num)
        )

        (if (and (> (secs-since timer_start) DISPLAY_REPEAT_SECOND) (= smart_cruise SMART_CRUISE_OFF)) { ; 12= (2xdisplay duration + 2)
            (setvar 'disp_num (+ speed DISPLAY_SPEED_OFFSET))
            (setvar 'timer_start (systime))
        })

        ; xxx end repeat display section
        (if (and (= smart_cruise SMART_CRUISE_HALF_ENABLED) (> (secs-since timer_start) TIMER_SMART_CRUISE_TIMEOUT)) ; time out Smart Cruise if second activation isn't received within display duration
            (setvar 'smart_cruise SMART_CRUISE_OFF)
        )

        ; Extra Long Press Commands when off (10 seconds)
        (if (and (> (secs-since timer_start) TIMER_LONG_PRESS) (= speed SPEED_OFF)) {
            (setvar 'thirds_total actual_batt)
            (spawn warbler WARBLER_FREQUENCY WARBLER_DURATION 0)
            (setvar 'warning_counter 0)
        })

        ; Released
        (if (= sw_pressed 0) {
            (debug_log "State 2->3: Released")
            (setvar 'timer_start (systime))
            (setvar 'timer_duration TIMER_RELEASE_WINDOW)
            (setvar 'sw_state STATE_GOING_OFF)
            (spawn THREAD_STACK_STATE_TRANSITIONS state_handler_going_off)
            (break)
        })
    })
})

(move-to-flash state_handler_pressed)


; xxxx State 3 "Going Off"

(defun state_handler_going_off ()
{
    (debug_log "State 3: Going Off")
    (loopwhile (= sw_state STATE_GOING_OFF) {
        (sleep SLEEP_STATE_MACHINE)
        (if (> smart_cruise SMART_CRUISE_OFF) ; If Smart Cruise is enabled, dont shut down
            (timeout-reset)
        )

        ; Pressed
        (if (= sw_pressed 1) {
            (timeout-reset) ; keeps motor running, vesc automatically stops if it doesn't receive this command every second
            (setvar 'timer_start (systime))
            (setvar 'timer_duration TIMER_CLICK_WINDOW)

            (if (>= smart_cruise SMART_CRUISE_FULLY_ENABLED) ; if Smart Cruise is on and switch pressed, turn it off
                {
                    (debug_log "Smart Cruise: Disabled by button press")
                    (setvar 'smart_cruise SMART_CRUISE_OFF)
                }
                (if (< safe_start_timer 1) ; check safe start isn't running, don't allow gear shifts if it is on
                    (setvar 'clicks (+ clicks 1)))
            )

            (setvar 'sw_state STATE_COUNTING_CLICKS)
            (spawn THREAD_STACK_STATE_COUNTING state_handler_counting_clicks)
            (break)
        })

        ; Timer Expiry
        (if (> (secs-since timer_start) timer_duration) {
            (if (and (!= smart_cruise SMART_CRUISE_FULLY_ENABLED) (!= smart_cruise SMART_CRUISE_AUTO_ENGAGED)) { ; If Smart Cruise is enabled, don't shut down
                (debug_log "State 3->0: Timeout, shutting down")
                (setvar 'timer_duration TIMER_DISABLED)
                (if (< speed start_speed) ; start at old speed if less than start speed
                    (if (> speed 1)
                        (setvar 'new_start_speed speed)
                    )
                    (setvar 'new_start_speed start_speed)
                )
                (set_speed_safe SPEED_OFF)
                (setvar 'smart_cruise SMART_CRUISE_OFF) ; turn off Smart Cruise
                (setvar 'sw_state STATE_OFF)
                (spawn THREAD_STACK_STATE_TRANSITIONS state_handler_off)
                (break) ; SWST_OFF
            })

            (if (or (= smart_cruise SMART_CRUISE_FULLY_ENABLED) (= smart_cruise SMART_CRUISE_AUTO_ENGAGED)) ; Require Smart Cruise to be re-enabled after a fixed duration
                (if (> (secs-since timer_start) smart_cruise_timeout) {
                    (setvar 'smart_cruise SMART_CRUISE_HALF_ENABLED)
                    (setvar 'timer_start (systime))
                    (setvar 'timer_duration TIMER_SMART_CRUISE_TIMEOUT) ; sets timer duration to display duration to allow for re-enable
                    (setvar 'disp_num DISPLAY_SMART_CRUISE_HALF)
                    (setvar 'click_beep CLICKS_QUINTUPLE)
                    (if (< speed SPEED_REVERSE_THRESHOLD) ; slow scooter to 80% to help people realize custom is expiring
                        (set-rpm (- 0 (* (/ (ix max_erpm scooter_type) SMART_CRUISE_SLOWDOWN_DIVISOR)(ix speed_set speed))))
                        (set-rpm (* (/ (ix max_erpm scooter_type) SMART_CRUISE_SLOWDOWN_DIVISOR)(ix speed_set speed)))
                    )
                })
            )
        }) ; end Timer expiry
    }) ; end state
})

(move-to-flash state_handler_going_off)


(defun start_motor_speed_loop()
{
    (debug_log "Motor: Starting motor speed loop")
    (define speed SPEED_OFF) ; 99 is off speed
    (define safe_start_timer 0)
    (define max_erpm (list MAX_ERPM_BLACKTIP MAX_ERPM_CUDAX)) ; 1st no is Blacktip, second is CudaX

    (let ((last_speed SPEED_OFF)
        (max_current (list MAX_CURRENT_BLACKTIP MAX_CURRENT_CUDAX)) ; 1st no is Blacktip, second is CudaX
        (min_current (list MIN_CURRENT_BLACKTIP MIN_CURRENT_CUDAX))) { ; 1st no is Blacktip, second is CudaX

        (loopwhile-thd THREAD_STACK_MOTOR t {
            (sleep SLEEP_MOTOR_CONTROL)
            (loopwhile (!= speed last_speed) {
            (debug_log (str-merge "Motor: Speed change " (to-str last_speed) "->" (to-str speed)))
            (sleep SLEEP_MOTOR_SPEED_CHANGE)
            ; turn off motor if speed is 99, scooter will also stop if the (timeout-reset) command isn't received every second from the Switch_State program
            (if (= speed SPEED_OFF) {
                (debug_log "Motor: Stopping motor")
                (set-current 0)
                (setvar 'batt_disp_timer_start (systime)) ; Start trigger for Battery Display
                (setvar 'disp_num DISPLAY_OFF) ; Turn on Off display. (off display is needed to ensure restart triggers a new display number)
                (setvar 'safe_start_timer 0) ; unlock speed changes and disable safe start timer
                (setvar 'last_speed speed)
                })

            (if (!= speed SPEED_OFF) {
                ; Soft Start section for all speeds, makes start less juddering
                (if (= last_speed SPEED_OFF) {
                    (debug_log "Motor: Soft start initiated")
                    (conf-set 'l-in-current-max (ix min_current scooter_type))
                    (setvar 'safe_start_timer (systime))
                    (setvar 'last_speed SPEED_SOFT_START_SENTINEL)
                    (if (< speed SPEED_REVERSE_THRESHOLD)
                        (set-duty (- 0 SAFE_START_DUTY))
                        (set-duty SAFE_START_DUTY)
                    )
                })

                ; Set Actual Speeds section
                (if (and (> (secs-since safe_start_timer) SAFE_START_TIMEOUT) (or (= use_safe_start 0) (!= last_speed SPEED_SOFT_START_SENTINEL) (and (> (abs (get-rpm)) SAFE_START_MIN_RPM) (> (abs (get-duty)) SAFE_START_MIN_DUTY) (< (abs (get-current)) SAFE_START_MAX_CURRENT)))) {
                (conf-set 'l-in-current-max (ix max_current scooter_type))

                ; xxx reverse gear section
                (if (< speed SPEED_REVERSE_THRESHOLD)
                    (set-rpm (- 0 (* (/ (ix max_erpm scooter_type) 100)(ix speed_set speed))))
                    ; xxx Normal Gears Section
                    (set-rpm (* (/ (ix max_erpm scooter_type) 100)(ix speed_set speed)))
                )

                (setvar 'disp_num (+ speed DISPLAY_SPEED_OFFSET))
                ; Maybe causing issues with timing? (setvar 'timer_start (systime)) ; set state timer so that repeat display timing works in state 2
                (setvar 'safe_start_timer 0) ; unlock speed changes and disable safe start timer
                (setvar 'last_speed speed)
                } {
                ; If safe start conditions not met yet but last_speed is still 0.5, update it to speed to exit the inner loop
                (if (= last_speed SPEED_SOFT_START_SENTINEL) {
                    (setvar 'last_speed speed)
                })
                })

                ; exit and stop motor if safestart hasn't cleared in 0.5 seconds and rpm is less than 500.
                (if (and (> (secs-since safe_start_timer) SAFE_START_TIMEOUT) (> (abs (get-current)) SAFE_START_FAIL_CURRENT) (< (abs (get-rpm)) SAFE_START_MIN_RPM) (= use_safe_start 1) (= last_speed SPEED_SOFT_START_SENTINEL)) {
                (debug_log "Motor: Safe start failed, stopping motor")
                (set_speed_safe SPEED_OFF)
                (setvar 'sw_state STATE_COUNTING_CLICKS)
                (spawn THREAD_STACK_STATE_COUNTING state_handler_counting_clicks)
                (foc-beep 250 0.15 5)
                })
                })
          })
        })
    })
})

(move-to-flash start_motor_speed_loop)


(defun thirds_warning_startup()
{
    (define thirds_total 0)
    (define warning_counter 0) ; Count how many times the 3rds warnings have been triggered.

    (if (> enable_thirds_warning_startup 0) {
        (debug_log "Battery: Thirds warning enabled at startup")
        ; Wait a bit for battery reading to stabilize
        (sleep SLEEP_BATTERY_STABILIZE)
        ; Calculate battery % using the configured method
        ; Set thirds_total to current battery level
        (setvar 'thirds_total (get-battery-level))
        (debug_log (str-merge "Battery: Initial level=" (to-str thirds_total)))
        (setvar 'warning_counter 0)
    })
})

(move-to-flash thirds_warning_startup)


(defun start_display_output_loop()
{
    (define disp_num 1) ; variable used to define the display screen you are accesing 0-X
    (define last_disp_num 1) ; variable used to track last display screen show

    (let ((start_pos 0) ; variable used to define start position in the array of diferent display screens
          (pixbuf (array-create 16)) ; create a temp array to store display bytes in
          (Displays [
            0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x81 0 0x81 ; Display Battery 1 Bar rotation 0
            0 0x81 0 0x81 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 ; Display Battery 1 Bar rotation 1
            0 0x60 0 0x60 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 ; Display Battery 1 Bar rotation 2
            0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x60 0 0x60 ; Display Battery 1 Bar rotation 3

            0 0x00 0 0x00 0 0x00 0 0x00 0 0x06 0 0x06 0 0x87 0 0x87 ; Display Battery 2 Bars rotation 0
            0 0x81 0 0x81 0 0x87 0 0x87 0 0x00 0 0x00 0 0x00 0 0x00 ; Display Battery 2 Bars rotation 1
            0 0x78 0 0x78 0 0x18 0 0x18 0 0x00 0 0x00 0 0x00 0 0x00 ; Display Battery 2 Bars rotation 2
            0 0x00 0 0x00 0 0x00 0 0x00 0 0x78 0 0x78 0 0x60 0 0x60 ; Display Battery 2 Bars rotation 3

            0 0x00 0 0x00 0 0x18 0 0x18 0 0x1E 0 0x1E 0 0x9F 0 0x9F ; Display Battery 3 Bars rotation 0
            0 0x81 0 0x81 0 0x87 0 0x87 0 0x9F 0 0x9F 0 0x00 0 0x00 ; Display Battery 3 Bars rotation 1
            0 0x7E 0 0x7E 0 0x1E 0 0x1E 0 0x06 0 0x06 0 0x00 0 0x00 ; Display Battery 3 Bars rotation 2
            0 0x00 0 0x00 0 0x7E 0 0x7E 0 0x78 0 0x78 0 0x60 0 0x60 ; Display Battery 3 Bars rotation 3

            0 0x60 0 0x60 0 0x78 0 0x78 0 0x7E 0 0x7E 0 0xFF 0 0xFF ; Display Battery 4 Bars rotation 0
            0 0x81 0 0x81 0 0x87 0 0x87 0 0x9F 0 0x9F 0 0xFF 0 0xFF ; Display Battery 4 Bars rotation 1
            0 0xFF 0 0xFF 0 0x9F 0 0x9F 0 0x87 0 0x87 0 0x81 0 0x81 ; Display Battery 4 Bars rotation 2
            0 0xFF 0 0xFF 0 0x7E 0 0x7E 0 0x78 0 0x78 0 0x60 0 0x60 ; Display Battery 4 Bars rotation 3

            0 0x1F 0 0x3F 0 0x33 0 0x1F 0 0x0F 0 0x1B 0 0x33 0 0x33 ; Display Reverse rotation 0
            0 0x00 0 0xFF 0 0xFF 0 0x6C 0 0x6E 0 0xFB 0 0xB1 0 0x00 ; Display Reverse rotation 1
            0 0x33 0 0x33 0 0x36 0 0x3C 0 0x3E 0 0x33 0 0x3F 0 0x3E ; Display Reverse rotation 2
            0 0x00 0 0x63 0 0xF7 0 0x9D 0 0x8D 0 0xFF 0 0xFF 0 0x00 ; Display Reverse rotation 3

            0 0x33 0 0x33 0 0x33 0 0x33 0 0x33 0 0x33 0 0x3F 0 0x1E ; Display Untangle rotation 0
            0 0x00 0 0x7F 0 0xFF 0 0x81 0 0x81 0 0xFF 0 0x7F 0 0x00 ; Display Untangle rotation 1
            0 0x1E 0 0x3F 0 0x33 0 0x33 0 0x33 0 0x33 0 0x33 0 0x33 ; Display Untangle rotation 2
            0 0x00 0 0xBF 0 0xFF 0 0x60 0 0x60 0 0xFF 0 0xBF 0 0x00 ; Display Untangle rotation 3

            0 0x0C 0 0x0E 0 0x0E 0 0x0C 0 0x0C 0 0x0C 0 0x0C 0 0x1E ; Display One rotation 0
            0 0x00 0 0x00 0 0xB0 0 0xFF 0 0xFF 0 0x80 0 0x00 0 0x00 ; Display One rotation 1
            0 0x1E 0 0x0C 0 0x0C 0 0x0C 0 0x0C 0 0x1C 0 0x1C 0 0x0C ; Display One rotation 2
            0 0x00 0 0x00 0 0x40 0 0xFF 0 0xFF 0 0x43 0 0x00 0 0x00 ; Display One rotation 3

            0 0x1E 0 0x3F 0 0x31 0 0x18 0 0x06 0 0x03 0 0x3F 0 0x1E ; Display Two rotation 0
            0 0x00 0 0x33 0 0xE7 0 0xE5 0 0xE9 0 0xF9 0 0x31 0 0x00 ; Display Two rotation 1
            0 0x1E 0 0x3F 0 0x30 0 0x18 0 0x06 0 0x23 0 0x3F 0 0x1E ; Display Two rotation 2
            0 0x00 0 0x23 0 0xE7 0 0xE5 0 0xE9 0 0xF9 0 0x33 0 0x00 ; Display Two rotation 3

            0 0x1E 0 0x33 0 0x30 0 0x1C 0 0x3C 0 0x30 0 0x33 0 0x1E ; Display Three rotation 0
            0 0x00 0 0x21 0 0xE1 0 0xCC 0 0xCC 0 0xFF 0 0x37 0 0x00 ; Display Three rotation 1
            0 0x1E 0 0x33 0 0x03 0 0x0F 0 0x0E 0 0x03 0 0x33 0 0x1E ; Display Three rotation 2
            0 0x00 0 0x3B 0 0xFF 0 0xCC 0 0xCC 0 0xE1 0 0x21 0 0x00 ; Display Three rotation 3

            0 0x18 0 0x1C 0 0x1A 0 0x19 0 0x3F 0 0x3F 0 0x18 0 0x18 ; Display Four rotation 0
            0 0x00 0 0x0E 0 0x16 0 0x26 0 0xFF 0 0xFF 0 0x06 0 0x00 ; Display Four rotation 1
            0 0x06 0 0x06 0 0x3F 0 0x3F 0 0x26 0 0x16 0 0x0E 0 0x06 ; Display Four rotation 2
            0 0x00 0 0x18 0 0xFF 0 0xFF 0 0x19 0 0x1A 0 0x1C 0 0x00 ; Display Four rotation 3

            0 0x1E 0 0x03 0 0x03 0 0x1F 0 0x30 0 0x30 0 0x33 0 0x1E ; Display Five rotation 0
            0 0x00 0 0x39 0 0xF9 0 0xC8 0 0xC8 0 0xCF 0 0x07 0 0x00 ; Display Five rotation 1
            0 0x1E 0 0x33 0 0x03 0 0x03 0 0x3E 0 0x30 0 0x30 0 0x1E ; Display Five rotation 2
            0 0x00 0 0x38 0 0xFC 0 0xC4 0 0xC4 0 0xE7 0 0x27 0 0x00 ; Display Five rotation 3

            0 0x1E 0 0x23 0 0x03 0 0x1F 0 0x33 0 0x33 0 0x33 0 0x1E ; Display Six rotation 0
            0 0x00 0 0x3F 0 0xFF 0 0xC8 0 0xC8 0 0xCF 0 0x27 0 0x00 ; Display Six rotation 1
            0 0x1E 0 0x33 0 0x33 0 0x33 0 0x3E 0 0x30 0 0x31 0 0x1E ; Display Six rotation 2
            0 0x00 0 0x39 0 0xFC 0 0xC4 0 0xC4 0 0xFF 0 0x3F 0 0x00 ; Display Six rotation 3

            0 0x3F 0 0x33 0 0x30 0 0x18 0 0x0C 0 0x0C 0 0x0C 0 0x0C ; Display Seven rotation 0
            0 0x00 0 0x60 0 0x60 0 0xC7 0 0xCF 0 0x78 0 0x70 0 0x00 ; Display Seven rotation 1
            0 0x0C 0 0x0C 0 0x0C 0 0x0C 0 0x06 0 0x03 0 0x33 0 0x3F ; Display Seven rotation 2
            0 0x00 0 0x83 0 0x87 0 0xFC 0 0xF8 0 0x81 0 0x81 0 0x00 ; Display Seven rotation 3

            0 0x1E 0 0x21 0 0xD2 0 0xC0 0 0xD2 0 0xCC 0 0x21 0 0x1E ; Display Eight rotation 0
            0 0x1E 0 0x21 0 0xD4 0 0xC2 0 0xC2 0 0xD4 0 0x21 0 0x1E ; Display Eight rotation 1
            0 0x1E 0 0x21 0 0xCC 0 0xD2 0 0xC0 0 0xD2 0 0x21 0 0x1E ; Display Eight rotation 2
            0 0x1E 0 0x21 0 0xCA 0 0xD0 0 0xD0 0 0xCA 0 0x21 0 0x1E ; Display Eight rotation 3

            0 0x1E 0 0x21 0 0xC2 0 0xC4 0 0xC8 0 0xD0 0 0x21 0 0x1E ; Display Off rotation 0
            0 0x1E 0 0x21 0 0xC2 0 0xC4 0 0xC8 0 0xD0 0 0x21 0 0x1E ; Display Off rotation 1
            0 0x1E 0 0x21 0 0xC2 0 0xC4 0 0xC8 0 0xD0 0 0x21 0 0x1E ; Display Off rotation 2
            0 0x1E 0 0x21 0 0xD0 0 0xC8 0 0xC4 0 0xC2 0 0x21 0 0x1E ; Display Off rotation 3

            0 0x0C 0 0x2D 0 0xCC 0 0xCC 0 0xCC 0 0xC0 0 0x21 0 0x1E ; Display Startup rotation 0
            0 0x1E 0 0x21 0 0x80 0 0xFC 0 0xFC 0 0x80 0 0x21 0 0x1E ; Display Startup rotation 1
            0 0x1E 0 0x21 0 0xC0 0 0xCC 0 0xCC 0 0xCC 0 0x2D 0 0x0C ; Display Startup rotation 2
            0 0x1E 0 0x21 0 0x40 0 0xCF 0 0xCF 0 0x40 0 0x21 0 0x1E ; Display Startup rotation 3

            0 0x00 0 0x13 0 0xA8 0 0xA0 0 0x90 0 0x80 0 0x13 0 0x00 ; Display Custom ? rotation 0
            0 0x1E 0 0x21 0 0x21 0 0x00 0 0x10 0 0x25 0 0x18 0 0x00 ; Display Custom ? rotation 1
            0 0x00 0 0x32 0 0x40 0 0x42 0 0x41 0 0x45 0 0x32 0 0x00 ; Display Custom ? rotation 2
            0 0x00 0 0x06 0 0x29 0 0x02 0 0x00 0 0x21 0 0x21 0 0x1E ; Display Custom ? rotation 3

            0 0x1C 0 0x36 0 0x03 0 0x03 0 0x03 0 0x03 0 0x36 0 0x1C ; Display Custom rotation 0
            0 0x00 0 0x1E 0 0x3F 0 0xE1 0 0xC0 0 0xE1 0 0x21 0 0x00 ; Display Custom rotation 1
            0 0x0E 0 0x1B 0 0x30 0 0x30 0 0x30 0 0x30 0 0x1B 0 0x0E ; Display Custom rotation 2
            0 0x00 0 0x21 0 0xE1 0 0xC0 0 0xE1 0 0x3F 0 0x1E 0 0x00 ; Display Custom rotation 3

            0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x81 0 0x81 ; Display 3rds 1 Bar rotation 0
            0 0x81 0 0x81 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 ; Display 3rds 1 Bar rotation 1
            0 0x60 0 0x60 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 ; Display 3rds 1 Bar rotation 2
            0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x00 0 0x60 0 0x60 ; Display 3rds 1 Bar rotation 3

            0 0x00 0 0x00 0 0x00 0 0x0C 0 0x0C 0 0x0C 0 0x8D 0 0x8D ; Display 3rds 2 Bars rotation 0
            0 0x81 0 0x81 0 0x00 0 0x8F 0 0x8F 0 0x00 0 0x00 0 0x00 ; Display 3rds 2 Bars rotation 1
            0 0x6C 0 0x6C 0 0x0C 0 0x0C 0 0x0C 0 0x00 0 0x00 0 0x00 ; Display 3rds 2 Bars rotation 2
            0 0x00 0 0x00 0 0x00 0 0x7C 0 0x7C 0 0x00 0 0x60 0 0x60 ; Display 3rds 2 Bars rotation 3

            0 0x60 0 0x60 0 0x60 0 0x6C 0 0x6C 0 0x6C 0 0xED 0 0xED ; Display 3rds 3 Bars rotation 0
            0 0x81 0 0x81 0 0x00 0 0x8F 0 0x8F 0 0x00 0 0xFF 0 0xFF ; Display 3rds 3 Bars rotation 1
            0 0xED 0 0xED 0 0x8D 0 0x8D 0 0x8D 0 0x81 0 0x81 0 0x81 ; Display 3rds 3 Bars rotation 2
            0 0xFF 0 0xFF 0 0x00 0 0x7C 0 0x7C 0 0x00 0 0x60 0 0x60 ; Display 3rds 3 Bars rotation 3

            0 0x23 0 0x52 0 0x52 0 0x52 0 0x52 0 0x52 0 0x52 0 0xA7 ; Display 10 Percent rotation 0
            0 0x80 0 0xC0 0 0xFF 0 0x80 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 10 Percent rotation 1
            0 0x79 0 0x92 0 0x92 0 0x92 0 0x92 0 0x92 0 0x92 0 0x31 ; Display 10 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0x40 0 0xFF 0 0xC0 0 0x40 ; Display 10 Percent rotation 3

            0 0xA3 0 0x54 0 0x54 0 0x54 0 0x53 0 0xD0 0 0xD0 0 0x27 ; Display 20 Percent rotation 0
            0 0x43 0 0xC4 0 0xC4 0 0xB8 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 20 Percent rotation 1
            0 0x39 0 0xC2 0 0xC2 0 0xB2 0 0x8A 0 0x8A 0 0x8A 0 0x71 ; Display 20 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0x47 0 0xC8 0 0xC8 0 0xB0 ; Display 20 Percent rotation 3

            0 0xA3 0 0x54 0 0x54 0 0x53 0 0x54 0 0x54 0 0x54 0 0xA3 ; Display 30 Percent rotation 0
            0 0xC0 0 0xC8 0 0xC8 0 0x37 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 30 Percent rotation 1
            0 0x71 0 0x8A 0 0x8A 0 0x8A 0 0xB2 0 0x8A 0 0x8A 0 0x71 ; Display 30 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0x3B 0 0xC4 0 0xC4 0 0xC0 ; Display 30 Percent rotation 3

            0 0x22 0 0x53 0 0xD2 0 0xD2 0 0xD7 0 0x52 0 0x52 0 0x22 ; Display 40 Percent rotation 0
            0 0x1C 0 0x24 0 0xFF 0 0x04 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 40 Percent rotation 1
            0 0x11 0 0x92 0 0x92 0 0xFA 0 0xD2 0 0xD2 0 0xB2 0 0x11 ; Display 40 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0x08 0 0xFF 0 0x09 0 0x0E ; Display 40 Percent rotation 3

            0 0xA7 0 0xD0 0 0xD0 0 0x53 0 0x54 0 0x54 0 0x54 0 0xA3 ; Display 50 Percent rotation 0
            0 0xF0 0 0xC8 0 0xC8 0 0x47 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 50 Percent rotation 1
            0 0x71 0 0x8A 0 0x8A 0 0x8A 0 0xB2 0 0xC2 0 0xC2 0 0x79 ; Display 50 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0xB8 0 0xC4 0 0xC4 0 0xC3 ; Display 50 Percent rotation 3

            0 0x27 0 0xD0 0 0xD0 0 0xD3 0 0xD4 0 0xD4 0 0xD4 0 0x23 ; Display 60 Percent rotation 0
            0 0x3F 0 0xC8 0 0xC8 0 0x47 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 60 Percent rotation 1
            0 0x31 0 0xCA 0 0xCA 0 0xCA 0 0xF2 0 0xC2 0 0xC2 0 0x39 ; Display 60 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0xB8 0 0xC4 0 0xC4 0 0x3F ; Display 60 Percent rotation 3

            0 0xA7 0 0x54 0 0x54 0 0x53 0 0x52 0 0x51 0 0x51 0 0xA0 ; Display 70 Percent rotation 0
            0 0xC0 0 0x4B 0 0x4C 0 0x70 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 70 Percent rotation 1
            0 0x41 0 0xA2 0 0xA2 0 0x92 0 0xB2 0 0x8A 0 0x8A 0 0x79 ; Display 70 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0x83 0 0x8C 0 0xB4 0 0xC0 ; Display 70 Percent rotation 3

            0 0x23 0 0xD4 0 0xD4 0 0xD4 0 0x53 0 0xD4 0 0xD4 0 0x23 ; Display 80 Percent rotation 0
            0 0x3B 0 0xC4 0 0xC4 0 0x3B 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 80 Percent rotation 1
            0 0x31 0 0xCA 0 0xCA 0 0xB2 0 0xCA 0 0xCA 0 0xCA 0 0x31 ; Display 80 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0x37 0 0xC8 0 0xC8 0 0x37 ; Display 80 Percent rotation 3

            0 0x23 0 0xD4 0 0xD4 0 0x57 0 0x54 0 0x54 0 0x54 0 0xA3 ; Display 90 Percent rotation 0
            0 0xB0 0 0xC8 0 0xC8 0 0x3F 0 0x00 0 0x3F 0 0xC0 0 0x3F ; Display 90 Percent rotation 1
            0 0x71 0 0x8A 0 0x8A 0 0x8A 0 0xBA 0 0xCA 0 0xCA 0 0x31 ; Display 90 Percent rotation 2
            0 0x3F 0 0xC0 0 0x3F 0 0x00 0 0x3F 0 0xC4 0 0xC4 0 0x43 ; Display 90 Percent rotation 3

            0 0xE3 0 0x90 0 0x90 0 0x93 0 0x90 0 0x90 0 0x90 0 0xE0 ; Display 100 Percent rotation 0
            0 0xFF 0 0x48 0 0x48 0 0x00 0 0x00 0 0x3F 0 0xC0 0 0xC0 ; Display 100 Percent rotation 1
            0 0xC1 0 0x42 0 0x42 0 0x42 0 0x72 0 0x42 0 0x42 0 0xF1 ; Display 100 Percent rotation 2
            0 0xC0 0 0xC0 0 0x3F 0 0x00 0 0x00 0 0x84 0 0x84 0xFF ; Display 100 Percent rotation 3
        ])) {

        (bufclear pixbuf) ; clear the buffer
        (loopwhile-thd THREAD_STACK_DISPLAY t {
            (sleep SLEEP_UI_UPDATE)
            ; xxxx Timer section to turn display off, gets reset by each new request to display
            (if (> disp_timer_start 1) ; check to see if display is on. don't want to run i2c commands continuously
            (if (> (secs-since disp_timer_start) TIMER_DISPLAY_DURATION) { ; check timer to see if its longer than display duration and display needs turning off, new display commands will keep adding time
            (if (= scooter_type SCOOTER_BLACKTIP) ; For Blacktip Turn off the display
                    (if (!= last_disp_num DISPLAY_SMART_CRUISE_FULL) ; if last display was the Smart Cruise, don't disable display
                        (i2c-tx-rx 0x70 (list 0x80))))
            ; For Cuda X make sure it doesn't get stuck on displaying B1 or B2 error, so switch back to last battery.
            (if (and (= scooter_type SCOOTER_CUDAX) (> last_disp_num 20) )
                (setvar 'disp_num last_batt_disp_num))

            (setvar 'disp_timer_start 0)
            }))
            ; xxxx End of timer section

                (if (!= disp_num last_disp_num) {
                (if (= scooter_type 1) { ; For cuda X second screen
                    (if (= cudax_flip 1)
                        (setvar 'mpu-addr 0x70)
                        (setvar 'mpu-addr 0x71)
                    )
                    (if (or (= disp_num 0) (= disp_num 1) (= disp_num 2) (= disp_num 3) (> disp_num 17) )
                        (if (= cudax_flip 1)
                            (setvar 'mpu-addr 0x71)
                            (setvar 'mpu-addr 0x70)
                        )
                    )
                })
                (setvar 'disp_timer_start (systime))
                (if (= mpu-addr 0x70)
                    (setvar 'start_pos (+(* 64 disp_num) (* 16 rotation))) ; define the correct start position in the array for the display
                    (setvar 'start_pos (+(* 64 disp_num) (* 16 rotation2)))
                    )
                (bufclear pixbuf)
                (bufcpy pixbuf 0 Displays start_pos 16) ; copy the required display from "Displays" Array to "pixbuf"
                (i2c-tx-rx mpu-addr pixbuf) ; send display characters
                (i2c-tx-rx mpu-addr (list 0x81)) ; Turn on display
                (setvar 'last_disp_num disp_num)
                (setvar 'mpu-addr 0x70)
                    })
        })
    })
})

(move-to-flash start_display_output_loop)


 ; **** Program that triggers the display to show battery status ****

(defun start_display_battery_loop()
{
    (define batt_disp_timer_start 0) ; Timer to see if Battery display has been triggered
    (define last_batt_disp_num 3) ; variable used to track last display screen show

    (let ((batt_disp_state 0))
    (loopwhile-thd THREAD_STACK_BATTERY t {
       (sleep SLEEP_UI_UPDATE)

        (if (or (= batt_disp_timer_start 0) (= batt_disp_state 0)) {
        (setvar 'batt_disp_state 0)})


        (if (and (> batt_disp_timer_start 1) (> (secs-since batt_disp_timer_start) 6) (= batt_disp_state 0)) { ; waits Display Duration + 1 second after scooter is turned off to stabilize battery readings

        ; xxxx Section for normal 4 bar battery capacity display

             (if (= thirds_total 0)

             (if (> actual_batt 0.75) { (setvar 'disp_num 3) (spawn beeper 4)} ; gets the vesc battery % and triggers the display screen
                (if (> actual_batt 0.5) { (setvar 'disp_num 2) (spawn beeper 3)}
                    (if (> actual_batt 0.25) { (setvar 'disp_num 1) (spawn beeper 2)}
                        { (setvar 'disp_num 0) (spawn beeper 1)} (nil ))))

             ; Section for 1/3rds display
              (if (and (> actual_batt (* thirds_total 0.66)) (= warning_counter 0)) {
                (debug_log "Battery: 2/3rds warning triggered")
                (setvar 'disp_num 20)}
                (if (and (> actual_batt (* thirds_total 0.33)) (< warning_counter 3)) {
                 (debug_log "Battery: 1/3rd warning triggered")
                 (setvar 'disp_num 19)
                  (if (< warning_counter 2) {
                    (spawn warbler 350 0.5 0.5)
                     (setvar 'warning_counter (+ warning_counter 1)
                     )})
                    } {
                     (debug_log "Battery: Critical warning triggered")
                     (setvar 'disp_num 18)
                     (if (< warning_counter 4) {
                        (spawn warbler 350 0.5 0.5)
                        (setvar 'warning_counter (+ warning_counter 1))})} (nil ))))

                 (setvar 'batt_disp_state 1)
                 (setvar 'last_batt_disp_num disp_num)
                    })

         (if (and (> batt_disp_timer_start 1) (> (secs-since batt_disp_timer_start) 12) (= batt_disp_state 1) (> thirds_total 0)) {

              (if (> actual_batt 0.95) { (setvar 'disp_num 30)} ; gets the vesc battery % and triggers the display screen NOTE % are adjusted to better represent battery state, ie fully charged power tool battery will not display at 100% on the vesc
                (if (> actual_batt 0.90) { (setvar 'disp_num 29)} ; 90%
                    (if (> actual_batt 0.80) { (setvar 'disp_num 28)} ; 80%
                        (if (> actual_batt 0.70) { (setvar 'disp_num 27)} ; 70%
                            (if (> actual_batt 0.60) { (setvar 'disp_num 26)} ; 60%
                                (if (> actual_batt 0.50) { (setvar 'disp_num 25)} ; 50%
                                    (if (> actual_batt 0.40) { (setvar 'disp_num 24)} ; 40%
                                       (if (> actual_batt 0.30) { (setvar 'disp_num 23)} ; 30%
                                            (if (> actual_batt 0.20) { (setvar 'disp_num 22)} ; 20%
                                                { (setvar 'disp_num 21)} (nil ))))))))))
               (setvar 'batt_disp_state 0)
               (setvar 'batt_disp_timer_start 0)
              })
    })
    )
})

(move-to-flash start_display_battery_loop)


(defun beeper (beeps)
(loopwhile (and (= enable_battery_beeps 1) (> batt_disp_timer_start 0) (> beeps 0)) {
       (sleep SLEEP_UI_UPDATE)
       (foc-beep 350 0.5 beeps_vol)
      (setvar 'beeps (- beeps 1))
    }))

(move-to-flash beeper)

; xxxx warbler Program xxxx"

(defun warbler (Tone Time Delay)
{
         (sleep Delay)
         (foc-beep Tone Time beeps_vol)
         (foc-beep (- Tone 200) Time beeps_vol)
         (foc-beep Tone Time beeps_vol)
         (foc-beep (- Tone 200) Time beeps_vol)
         })

 (move-to-flash warbler)


; ***** Program that beeps trigger clicks

(defun start_beeper_loop()
{
    (define click_beep 0)

    (let ((click_beep_timer 0))
    (loopwhile-thd THREAD_STACK_CLICK_BEEP t {
        (sleep SLEEP_UI_UPDATE)

        (if (and (> (secs-since click_beep_timer) SLEEP_UI_UPDATE) (!= click_beep_timer 0)) {
        (foc-play-stop)
        (setvar 'click_beep_timer 0)
        })

        (if (> click_beep 0) {
        (if (and (= click_beep CLICKS_QUINTUPLE) (> enable_smart_cruise 0)(!= speed SPEED_OFF)) (foc-play-tone 1 1500 beeps_vol))
        (if (= enable_trigger_beeps 1) {
        (if (= click_beep CLICKS_SINGLE)(foc-play-tone 1 2500 beeps_vol))
        (if (= click_beep CLICKS_DOUBLE)(foc-play-tone 1 3000 beeps_vol))
        (if (= click_beep CLICKS_TRIPLE)(foc-play-tone 1 3500 beeps_vol))
        (if (= click_beep CLICKS_QUADRUPLE)(foc-play-tone 1 4000 beeps_vol))
        })

        (setvar 'click_beep_timer (systime))
        (setvar 'click_beep 0)
        })

    })
    )
})

(move-to-flash start_beeper_loop)


(defun peripherals_setup()
{
    (define disp_timer_start 0) ; Timer for display duration

    ; List with all the screen Brightness commands
    (let ((brightness_bytes (list
        0xE0; 0 Min
        0xE3; 1
        0xE6; 2
        0xE9; 3
        0xEC; 4
        0xEF; 5 Max
        ))) {

        (if (or (= 0 hardware_configuration) (= 3 hardware_configuration)) ; turn on i2c for the screen based on wiring. 0 = Blacktip with Bluetooth, 3 = CudaX with Bluetooth
            (i2c-start 'rate-400k 'pin-swdio 'pin-swclk) ; Works HW 60 with screen on SWD Connector. Screen SDA pin to Vesc SWDIO (2), Screen SCL pin to Vesc SWCLK (4)
            (if (or (= 1 hardware_configuration) ( = 4 hardware_configuration)) ; 1 = Blacktip without Bluetooth, 4 = CudaX without Bluetooth
                (i2c-start 'rate-400k 'pin-rx 'pin-tx) ; Works HW 60 with screen on Comm Connector. Screen SDA pin to Vesc RX/SDA (5), Screen SCL pin to Vesc TX/SCL (6)
                (if ( = 2 hardware_configuration)
                    (i2c-start 'rate-400k 'pin-tx 'pin-rx) ; tested on HW 410 Tested: SN 189, SN 1691
                    (nil))))

        (define mpu-addr 0x70) ; I2C Address for the screen

        (i2c-tx-rx 0x70 (list 0x21)) ; start the oscillator
        (i2c-tx-rx 0x70 (list (ix brightness_bytes disp_brightness))) ; set brightness

        (if (= scooter_type 1) { ; For cuda X setup second screen
                (i2c-tx-rx 0x71 (list 0x21)) ; start the oscillator
                (i2c-tx-rx 0x71 (list (ix brightness_bytes disp_brightness))) ; set brightness
        })
    })
})

(defun main()
{
    (eeprom_set_defaults)

    (update_settings) ; creates all settings variables

    (thirds_warning_startup)

    (setup_event_handler)

    (setup_state_machine)

    (start_motor_speed_loop)

    (start_beeper_loop)

    (peripherals_setup)

    (start_display_output_loop)

    (start_display_battery_loop)

    (start_smart_cruise_loop)

    (start_trigger_loop)

    (spawn THREAD_STACK_STATE_TRANSITIONS state_handler_off) ; ***Start state machine running for first time

    (setvar 'disp_num 15) ; display startup screen, change bytes if you want a different one
    (setvar 'batt_disp_timer_start (systime)) ; turns battery display on for power on.

    ; Log this irrespective of logging setting
    (puts "Startup complete")
})

(main)
