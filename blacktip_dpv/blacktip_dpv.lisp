; Import display and brightness lookup tables from binary files
; These files are generated at build time from CSV sources
(import "generated/display_lut.bin" 'display_lut_bin)
(import "generated/brightness_lut.bin" 'brightness_lut_bin)

; Display LUT binary format helpers (init-only, not moved to flash)
(defun validate_lut_header (data magic expected_version)
{
    (let ((file_magic (bufget-u32 data 0 'little-endian))
          (file_version (bufget-u16 data 4 'little-endian))
          (num_items (bufget-u16 data 6 'little-endian)))
    {
        (if (!= file_magic magic)
            nil
            (if (!= file_version expected_version)
                nil
                num_items))
    })
})

; Initialize display LUT (returns number of frames or nil on error)
(define display_num_frames (validate_lut_header display_lut_bin 0x4C555444u32 1))

; Initialize brightness LUT (returns number of levels or nil on error)
(define brightness_num_levels (validate_lut_header brightness_lut_bin 0x4C555442u32 1))

; Verify LUTs loaded successfully - halt if validation fails
(if (not display_num_frames)
    (exit-error "LUT validation failed: display"))
(if (not brightness_num_levels)
    (exit-error "LUT validation failed: brightness"))

; EEPROM initialization (init-only, not moved to flash)
(defun eeprom_set_defaults ()

{
    (if (not-eq (eeprom-read-i 127) (to-i32 1)) {
        (puts "EEPROM: Initializing defaults for 1.0.0")
        ; Check for current version marker (blacktip_dpv release 1.0.0)
        ; New settings added in version 1.0.0
        (eeprom_store_i_if_changed 25 0) ; Enable Auto-Engage Smart Cruise. 1=On 0=Off
        (eeprom_store_i_if_changed 26 10) ; Auto-Engage Time in seconds (5-30 seconds)
        (eeprom_store_i_if_changed 27 0) ; Enable Thirds warning on from power-up. 1=On 0=Off
        (eeprom_store_i_if_changed 28 0) ; Battery calculation method: 0=Voltage-based, 1=Ampere-hour based
        (eeprom_store_i_if_changed 29 0) ; Enable Debug Logging. 1=On 0=Off

        (if (not-eq (eeprom-read-i 127) (to-i32 150)) {
            (puts "EEPROM: No previous version detected, setting all defaults")
            ; Check for previous version marker (Dive Xtras V1.50 'Poseidon')
            ; User speeds, ie 1 thru 8 are only used in the GUI, this lisp code uses speeds 0-9 with 0 & 1 being the 2 reverse speeds.
            ; 99 is used as the "off" speed
            (eeprom_store_i_if_changed 0 45) ; Reverse Speed 2 %
            (eeprom_store_i_if_changed 1 20) ; Untangle Speed 1 %
            (eeprom_store_i_if_changed 2 30) ; Speed 1 %
            (eeprom_store_i_if_changed 3 38) ; Speed 2 %
            (eeprom_store_i_if_changed 4 46) ; Speed 3 %
            (eeprom_store_i_if_changed 5 54) ; Speed 4 %
            (eeprom_store_i_if_changed 6 62) ; Speed 5 %
            (eeprom_store_i_if_changed 7 70) ; Speed 6 %
            (eeprom_store_i_if_changed 8 78) ; Speed 7 %
            (eeprom_store_i_if_changed 9 100) ; Speed 8 %
            (eeprom_store_i_if_changed 10 9) ; Maximum number of Speeds to use, must be greater or equal to start_speed (actual speed #, not user speed)
            (eeprom_store_i_if_changed 11 4) ; Speed the scooter starts in. Range 2-9, must be less or equal to the max_speed_no (actual speed #, not user speed)
            (eeprom_store_i_if_changed 12 7) ; Speed to jump to on triple click, (actual speed #, not user speed)
            (eeprom_store_i_if_changed 13 1) ; Turn safe start on or off 1=On 0=Off
            (eeprom_store_i_if_changed 14 0) ; Enable Reverse speed. 1=On 0=Off
            (eeprom_store_i_if_changed 15 0) ; Enable 5 click Smart Cruise. 1=On 0=Off
            (eeprom_store_i_if_changed 16 60) ; How long before Smart Cruise times out and requires reactivation in sec.
            (eeprom_store_i_if_changed 17 0) ; rotation of Display, 0-3 . Each number rotates display 90 deg.
            (eeprom_store_i_if_changed 18 5) ; Display Brighness 0-5
            (eeprom_store_i_if_changed 19 0) ; Hardware configuration, 0 = Blacktip HW60 + Ble, 1 = Blacktip HW60 - Ble, 2 = Blacktip HW410 - Ble, 3 = Cuda-X HW60 + Ble, 4 = Cuda-X HW60 - Ble
            (eeprom_store_i_if_changed 20 0) ; Battery Beeps
            (eeprom_store_i_if_changed 21 3) ; Beep Volume
            (eeprom_store_i_if_changed 22 0) ; CudaX Flip Screens
            (eeprom_store_i_if_changed 23 0) ; 2nd Screen rotation of Display, 0-3 . Each number rotates display 90 deg.
            (eeprom_store_i_if_changed 24 0) ; Trigger Click Beeps
        })
        ; Mark as initialised for 1.0.0
        (eeprom_store_i_if_changed 127 1) ; indicate that the defaults have been applied
        (puts "EEPROM: Defaults initialized successfully")
    })
})


; Helper function to reduce EEPROM wear by only writing when value changes
(defun eeprom_store_i_if_changed (addr new_val)
{
    (let ((current_val (eeprom-read-i addr)))
    {
        (if (or (eq current_val nil) (!= current_val new_val))
            (eeprom-store-i addr new_val))
    })
})

(move-to-flash eeprom_store_i_if_changed)


; =============================================================================
; Safe Start Helpers
; =============================================================================
; =============================================================================

(defun safe_start_reset_state ()
{
    (setvar 'safe_start_timer 0)
    (setvar 'safe_start_attempt_speed SPEED_OFF)
    (setvar 'safe_start_failures 0)
    (setvar 'safe_start_status 'idle)
})

(move-to-flash safe_start_reset_state)

(defun safe_start_begin (target_speed)
{
    (setvar 'safe_start_timer (systime))
    (setvar 'safe_start_attempt_speed target_speed)
    (setvar 'safe_start_status 'running)
    (debug_log (str-merge "Motor: Safe start attempt " (to-str (+ safe_start_failures 1)) " targeting speed " (to-str target_speed)))
})

(move-to-flash safe_start_begin)

(defun safe_start_success ()
{
    (setvar 'safe_start_timer 0)
    (setvar 'safe_start_attempt_speed SPEED_OFF)
    (setvar 'safe_start_failures 0)
    (setvar 'safe_start_status 'success)
})

(move-to-flash safe_start_success)

(defun safe_start_increment_failure (reason)
{
    (setvar 'safe_start_failures (+ safe_start_failures 1))
    (setvar 'safe_start_status 'failed)
    (debug_log (str-merge "Motor: Safe start attempt " (to-str safe_start_failures) "/" (to-str SAFE_START_MAX_RETRIES) " failed (" reason ")"))
})

(move-to-flash safe_start_increment_failure)

(defun safe_start_should_retry ()
{
    (< safe_start_failures SAFE_START_MAX_RETRIES)
})

(move-to-flash safe_start_should_retry)

(defun safe_start_abort_with_reason (reason)
{
    (safe_start_increment_failure reason)
    (if (safe_start_should_retry) {
        (sleep SAFE_START_RETRY_BACKOFF)
        (safe_start_begin safe_start_attempt_speed)
    } {
        (debug_log "Motor: Safe start retries exhausted, stopping motor")
        (set_speed_safe SPEED_OFF)
        (state_transition_to STATE_COUNTING_CLICKS "safe_start_abort" THREAD_STACK_STATE_COUNTING state_handler_counting_clicks)
        (foc-beep 250 0.15 5)
        (safe_start_reset_state)
    })
})

(move-to-flash safe_start_abort_with_reason)

(defun safe_start_value_valid (value max_abs)
{
    (and (= value value) (< (abs value) max_abs))
})

(move-to-flash safe_start_value_valid)

(defun safe_start_telemetry_valid (rpm duty current)
{
    (and (safe_start_value_valid rpm 20000)
         (safe_start_value_valid duty 1.0)
         (safe_start_value_valid current 200))
})

(move-to-flash safe_start_telemetry_valid)

(defun safe_start_met_success_criteria (rpm duty current)
{
    (and (> (abs rpm) SAFE_START_MIN_RPM)
         (> (abs duty) SAFE_START_MIN_DUTY)
         (< (abs current) SAFE_START_MAX_CURRENT))
})

(move-to-flash safe_start_met_success_criteria)

; Settings initialization (init-only, not moved to flash)
(defun update_settings()
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
    (debug_log (str-merge "Config loaded: HW=" (to-str (to-i hardware_configuration))
                     " Type=" (to-str scooter_type)
                     " Debug=" (to-str (to-i debug_enabled))
                     " BattCalc=" (to-str (to-i battery_calculation_method))))
})

; Debug logging helper function
(defun debug_log (msg)
{
    (if (and (not-eq debug_enabled nil) (= debug_enabled 1))
        (puts msg)
    )
})

(move-to-flash debug_log)

; Lightweight macro to conditionally evaluate debug logging expressions
; Only evaluates the logging expression when debug_enabled is 1
; This prevents expensive str-merge and to-str calls on memory-constrained targets
(define debug_log_macro (macro (expr)
    `(if (and (not-eq debug_enabled nil) (= debug_enabled 1))
        (puts ,expr)
    )
))

(move-to-flash debug_log_macro)

(defun calculate_corrected_battery ()
    ; Calculate corrected battery percentage from raw battery reading
    (let ((raw_batt (get-batt)))
        (+ (* BATTERY_COEFF_4 raw_batt raw_batt raw_batt raw_batt)
           (* BATTERY_COEFF_3 raw_batt raw_batt raw_batt)
           (* BATTERY_COEFF_2 raw_batt raw_batt)
           (* BATTERY_COEFF_1 raw_batt))))

(move-to-flash calculate_corrected_battery)

(defun calculate_ah_based_battery ()
    ; Calculate battery percentage based on ampere-hours used vs total capacity
    (let ((total-capacity (conf-get 'si-battery-ah))
          (used-ah (get-ah))
          (remaining_capacity (- 1.0 (/ used-ah total-capacity))))
        (if (and (> total-capacity 0) (> remaining_capacity 0))
            remaining_capacity
            0.0)))

(move-to-flash calculate_ah_based_battery)

(defun get_battery_level ()
    ; Get battery level using the configured calculation method
    (if (= battery_calculation_method 1)
        (calculate_ah_based_battery)
        (calculate_corrected_battery)))

(move-to-flash get_battery_level)

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
        ; For non-handshake messages, validate buffer size
        (if (< (buflen data) EEPROM_SETTINGS_COUNT) {
            (debug_log (str-merge "Error: Received data buffer too small: " (to-str (buflen data)) " < " (to-str EEPROM_SETTINGS_COUNT)))
            nil ; Return early on invalid data
        } {
            (debug_log "Receiving settings from external source, validating...")
            (looprange i 0 EEPROM_SETTINGS_COUNT
                (eeprom_store_i_if_changed i (bufget-u8 data i))) ; writes settings to eeprom
            (update_settings) ; updates actual settings in lisp (with validation)
            (gc) ; Force garbage collection to free memory from validation strings
            (debug_log "Settings updated and validated")
        })
    })
})

(move-to-flash my_data_recv_prog)

; Setup functions (init-only, not moved to flash)
(defun setup_event_handler()
{
    (defun event_handler ()
    {
        (loopwhile t
            (recv
                ((event-data-rx . (? data)) (my_data_recv_prog data))
                (_ nil))
        )
    })

    (event-register-handler (spawn event_handler))
    (event-enable 'event-data-rx)
})

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
                        ; re command actual speed as reverification sets it to 0.8x
                        (set-rpm (calculate_rpm speed RPM_PERCENT_DENOMINATOR))
                    })
                })
            } {
                ; Not in the right state for auto-engage, reset timer
                (setvar 'speed_setting_timer (systime))
            })
        })
    })
})

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

; Thread stack sizes (in 4-byte words) for loopwhile-thd and spawn
; Reduced to minimum safe values to conserve memory
(define THREAD_STACK_GPIO 80)         ; GPIO reading - minimal needs
(define THREAD_STACK_SMART_CRUISE 100) ; Smart Cruise - reduced
(define THREAD_STACK_STATE_MACHINE 80) ; State 2 (pressed) - reduced
(define THREAD_STACK_STATE_TRANSITIONS 80) ; States 0, 3 - reduced
(define THREAD_STACK_STATE_COUNTING 80) ; State 1 (counting clicks) - reduced
(define THREAD_STACK_MOTOR 150)       ; Motor control - reduced but still largest
(define THREAD_STACK_DISPLAY 100)     ; Display updates - reduced
(define THREAD_STACK_BATTERY 100)     ; Battery display - reduced
(define THREAD_STACK_CLICK_BEEP 80)   ; Click beep playback - reduced

; State values
(define STATE_UNINITIALIZED -1)
(define STATE_OFF 0)
(define STATE_COUNTING_CLICKS 1)
(define STATE_PRESSED 2)
(define STATE_GOING_OFF 3)

; State machine tracking (minimal for memory conservation)
(define state_last_state STATE_UNINITIALIZED)
(define state_last_change_time 0)
(define state_last_reason "")

(defun state_index_for (state)
{
    (cond
        ((= state STATE_OFF) 0)
        ((= state STATE_COUNTING_CLICKS) 1)
        ((= state STATE_PRESSED) 2)
        ((= state STATE_GOING_OFF) 3)
        (t -1))
})

(defun state_name_for (state)
{
    (cond
        ((= state STATE_OFF) "Off")
        ((= state STATE_COUNTING_CLICKS) "CountingClicks")
        ((= state STATE_PRESSED) "Pressed")
        ((= state STATE_GOING_OFF) "GoingOff")
        ((= state STATE_UNINITIALIZED) "Init")
        (t "Unknown"))
})

(defun state_metrics_reset ()
{
    (setvar 'state_last_state STATE_UNINITIALIZED)
    (setvar 'state_last_change_time (systime))
    (setvar 'state_last_reason "startup")
})

(defun state_metrics_accumulate (state elapsed)
{
    ; Disabled to save memory
    nil
})

(defun state_record_transition (from_state to_state reason)
{
    (setvar 'state_last_state to_state)
    (setvar 'state_last_change_time (systime))
    (setvar 'state_last_reason reason)
    (debug_log_macro (str-merge "State: " (to-str from_state) "->" (to-str to_state) " " reason))
})

(defun state_transition_to (new_state reason thread_stack handler)
{
    (state_record_transition
        (if (= state_last_state STATE_UNINITIALIZED) STATE_UNINITIALIZED sw_state)
        new_state
        reason)
    (setvar 'sw_state new_state)
    (spawn thread_stack handler)
})

(move-to-flash state_index_for)
(move-to-flash state_name_for)
(move-to-flash state_metrics_reset)
(move-to-flash state_metrics_accumulate)
(move-to-flash state_record_transition)
(move-to-flash state_transition_to)

; Special speed values
(define SPEED_REVERSE_2 0)            ; Reverse speed level 2 (strong reverse)
(define SPEED_UNTANGLE 1)             ; Reverse speed level 1 / untangle assist
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

; RPM scaling
(define RPM_PERCENT_DENOMINATOR 100)

; Safe start parameters
(define SAFE_START_DUTY 0.06)         ; Initial duty cycle for soft start
(define SAFE_START_TIMEOUT 0.5)       ; Timeout for safe start checks
(define SAFE_START_TIMEOUT_GRACE 0.1) ; Additional grace period before aborting (seconds)
(define SAFE_START_MIN_RPM 350)       ; Minimum RPM for safe start success
(define SAFE_START_MIN_DUTY 0.05)     ; Minimum duty for safe start check
(define SAFE_START_MAX_CURRENT 5)     ; Maximum current during safe start spin-up
(define SAFE_START_FAIL_CURRENT 8)    ; Current threshold for safe start failure
(define SAFE_START_MAX_RETRIES 3)     ; Max safe start retries before shutting down
(define SAFE_START_RETRY_BACKOFF 0.2) ; Delay before retrying safe start (seconds)

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
; RPM Calculation Helper
; =============================================================================

(defun clamp (value min_val max_val)
{
    (cond
        ((< value min_val) min_val)
        ((> value max_val) max_val)
        (t value))
})

(move-to-flash clamp)

(defun speed_percentage_at (speed_index)
{
    (if (= speed_index SPEED_OFF)
        0
        (let ((count (length speed_set)))
        {
            (if (= count 0)
                {
                    (debug_log "Speed: speed_set empty, defaulting to 0%")
                    0
                }
                {
              (let ((max_index (- count 1))
                  (clamped (clamp speed_index SPEED_REVERSE_2 max_index)))
                    {
                        (if (!= speed_index clamped)
                            (debug_log_macro (str-merge "Speed: Index " (to-str speed_index) " clamped to " (to-str clamped) " for speed_set"))
                        )
                        (ix speed_set clamped)
                    })
                })
        })
    )
})

(move-to-flash speed_percentage_at)

(defun calculate_rpm (speed_index divisor)
{
    (let ((speed_percent (speed_percentage_at speed_index))
         (max_rpm (cond
             ((= scooter_type SCOOTER_BLACKTIP) MAX_ERPM_BLACKTIP)
             ((= scooter_type SCOOTER_CUDAX) MAX_ERPM_CUDAX)
             (t (debug_log "Invalid scooter_type, defaulting to Blacktip") MAX_ERPM_BLACKTIP)
         )))
    {
        (let ((base_rpm (* (/ max_rpm divisor) speed_percent)))
        {
            (if (< speed_index SPEED_REVERSE_THRESHOLD)
                (- 0 base_rpm)
                base_rpm)
        })
    })
})

(move-to-flash calculate_rpm)

; =============================================================================
; State Machine Design Notes:
; - Each state handler runs in a loop checking (= sw_state N)
; - When transitioning, sw_state is updated, new handler spawned, and (break) called
; - The loop condition prevents race conditions by ensuring old handler exits
; - Old thread terminates naturally when loop condition becomes false
; =============================================================================

; Setup state machine (init-only, not moved to flash)
(defun setup_state_machine()
{
    (state_metrics_reset)
    (define sw_state 0)
    (define timer_start 0)
    (define timer_duration 0)
    (define clicks 0)
    (define actual_batt 0)
    (define new_start_speed start_speed)
})

; =============================================================================
; Speed Bounds Checking
; =============================================================================

; Helper function to safely set speed with bounds checking
; Valid speeds: SPEED_REVERSE_2, SPEED_UNTANGLE, 2-max_speed_no (forward), SPEED_OFF
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
            (if (< new_speed SPEED_REVERSE_2) {
                (setvar 'clamped_speed SPEED_REVERSE_2)
                (debug_log_macro (str-merge "Speed: Clamped " (to-str new_speed) " to " (to-str SPEED_REVERSE_2) " (underflow)"))
            })

            (if (> clamped_speed max_speed_no) {
                (setvar 'clamped_speed max_speed_no)
                (debug_log_macro (str-merge "Speed: Clamped " (to-str new_speed) " to " (to-str (to-i max_speed_no)) " (overflow)"))
            })

            ; Check reverse enable
            (if (and (< clamped_speed SPEED_REVERSE_THRESHOLD) (= enable_reverse 0)) {
                (setvar 'clamped_speed SPEED_REVERSE_THRESHOLD)
                (debug_log_macro (str-merge "Speed: Reverse disabled, clamped " (to-str new_speed) " to " (to-str SPEED_REVERSE_THRESHOLD)))
            })

            (setvar 'speed clamped_speed)
            (debug_log_macro (str-merge "Speed: Set to " (to-str clamped_speed)))
        })
        clamped_speed
    })
})

(move-to-flash set_speed_safe)

(defun state_handler_off()
{
    ; xxxx State "0" Off
    (debug_log "State 0: Off")
    (loopwhile (= sw_state STATE_OFF) {
        (sleep SLEEP_STATE_MACHINE)
        ; Calculate corrected batt %, only needed when scooter is off in state 0
        (setvar 'actual_batt (get_battery_level))

        ; Pressed
        (if (= sw_pressed 1) {
            (debug_log "State 0->1: Button pressed")
            (setvar 'batt_disp_timer_start 0) ; Stop Battery Display in case its running
            (setvar 'disp_timer_start 0) ; Stop Display in case its running
            (setvar 'timer_start (systime))
            (setvar 'timer_duration TIMER_CLICK_WINDOW)
            (setvar 'clicks CLICKS_SINGLE)
            (state_transition_to STATE_COUNTING_CLICKS "button_press" THREAD_STACK_STATE_COUNTING state_handler_counting_clicks)
            (break)
        })
    })
})

(move-to-flash state_handler_off)

; Encapsulated click action handler
(defun apply_click_action (click_count)
{
    (cond
        ((= click_count CLICKS_SINGLE)
        {
            (if (!= speed SPEED_OFF)
            {
                (debug_log "Click action: Single click (speed down)")
                (setvar 'click_beep CLICKS_SINGLE)
                (cond
                    ((> speed SPEED_REVERSE_THRESHOLD)
                        (set_speed_safe (- speed 1)))
                    ((= speed SPEED_REVERSE_2)
                        (set_speed_safe SPEED_UNTANGLE)))
            })
        })
        ((= click_count CLICKS_DOUBLE)
        {
            (if (= speed SPEED_OFF)
            {
                (debug_log_macro (str-merge "Click action: Double click (start at speed " (to-str new_start_speed) ")"))
                (set_speed_safe new_start_speed)
            }
            {
                (debug_log "Click action: Double click (speed up)")
                (setvar 'click_beep CLICKS_DOUBLE)
                (if (< speed max_speed_no)
                {
                    (if (> speed SPEED_UNTANGLE)
                        (set_speed_safe (+ speed 1))
                        (set_speed_safe SPEED_REVERSE_2))
                })
            })
        })
        ((= click_count CLICKS_TRIPLE)
        {
            (debug_log_macro (str-merge "Click action: Triple click (jump to speed " (to-str (to-i jump_speed)) ")"))
            (if (!= speed SPEED_OFF)
                (setvar 'click_beep CLICKS_TRIPLE)
            )
            (set_speed_safe jump_speed)
        })
        ((= click_count CLICKS_QUADRUPLE)
        {
            (if (= enable_reverse 1)
            {
                (debug_log "Click action: Quadruple click (untangle)")
                (if (!= speed SPEED_OFF)
                    (setvar 'click_beep CLICKS_QUADRUPLE)
                )
                (set_speed_safe SPEED_UNTANGLE)
            })
        })
        ((= click_count CLICKS_QUINTUPLE)
        {
            (debug_log_macro (str-merge "Click action: Quintuple click (Smart Cruise " (to-str smart_cruise) "->" (to-str (+ smart_cruise 1)) ")"))
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
                (set-rpm (calculate_rpm speed RPM_PERCENT_DENOMINATOR))
            })
        })
        (t
            (debug_log_macro (str-merge "Click action: Unsupported count " (to-str click_count))))
    )
})

(move-to-flash apply_click_action)

; xxxx STATE 1 Counting clicks
(defun state_handler_counting_clicks ()
{
    (debug_log_macro (str-merge "State 1: Counting clicks=" (to-str clicks)))
    (loopwhile (= sw_state STATE_COUNTING_CLICKS) {
        (sleep SLEEP_STATE_MACHINE)

        ; Released
        (if (= sw_pressed 0) {
            (setvar 'disp_timer_start 0) ; Stop Display in case its running
            (setvar 'timer_start (systime))
            (setvar 'timer_duration TIMER_RELEASE_WINDOW)
            (state_transition_to STATE_GOING_OFF "released" THREAD_STACK_STATE_TRANSITIONS state_handler_going_off)
            (break)
        })

        ; Timer Expiry
        (if (> (secs-since timer_start) timer_duration) {
            (debug_log_macro (str-merge "State 1: Timer expired, clicks=" (to-str clicks)))

            ; Process click actions
            (apply_click_action clicks)

            ; End of Click Actions
            (debug_log_macro (str-merge "State 1->2: Speed=" (to-str speed)))
            (setvar 'clicks 0)
            (setvar 'timer_duration TIMER_DISABLED)
            (state_transition_to STATE_PRESSED "click_window_expired" THREAD_STACK_STATE_MACHINE state_handler_pressed)
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
        (if (and (> (secs-since timer_start) TIMER_LONG_PRESS) (= speed SPEED_OFF) (= thirds_total 0)) {
            (debug_log "Battery: Thirds warning enabled")
            (setvar 'thirds_total actual_batt)
            (spawn warbler WARBLER_FREQUENCY WARBLER_DURATION 0)
            (setvar 'warning_counter 0)
        })

        ; Released
        (if (= sw_pressed 0) {
            (debug_log "State 2->3: Released")
            (setvar 'timer_start (systime))
            (setvar 'timer_duration TIMER_RELEASE_WINDOW)
            (state_transition_to STATE_GOING_OFF "released" THREAD_STACK_STATE_TRANSITIONS state_handler_going_off)
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
                (if (= safe_start_timer 0) { ; safe start uses 0 as the inactive sentinel
                    (setvar 'clicks (+ clicks 1))
                })
            )

            (state_transition_to STATE_COUNTING_CLICKS "button_pressed" THREAD_STACK_STATE_COUNTING state_handler_counting_clicks)
            (break)
        })

        ; Timer Expiry
        (if (> (secs-since timer_start) timer_duration) {
            (if (and (!= smart_cruise SMART_CRUISE_FULLY_ENABLED) (!= smart_cruise SMART_CRUISE_AUTO_ENGAGED)) { ; If Smart Cruise is enabled, don't shut down
                (debug_log "State 3->0: Timeout, shutting down")
                (setvar 'timer_duration TIMER_DISABLED)
                (cond
                    ((and (< speed start_speed) (> speed SPEED_UNTANGLE)) ; start at old speed if less than start speed
                        (setvar 'new_start_speed speed))
                    ((>= speed start_speed)
                        (setvar 'new_start_speed start_speed)))
                (set_speed_safe SPEED_OFF)
                (setvar 'smart_cruise SMART_CRUISE_OFF) ; turn off Smart Cruise
                (state_transition_to STATE_OFF "timeout_shutdown" THREAD_STACK_STATE_TRANSITIONS state_handler_off)
                (break) ; SWST_OFF
            })

            (if (or (= smart_cruise SMART_CRUISE_FULLY_ENABLED) (= smart_cruise SMART_CRUISE_AUTO_ENGAGED)) ; Require Smart Cruise to be re-enabled after a fixed duration
                (if (> (secs-since timer_start) smart_cruise_timeout) {
                    (setvar 'smart_cruise SMART_CRUISE_HALF_ENABLED)
                    (setvar 'timer_start (systime))
                    (setvar 'timer_duration TIMER_SMART_CRUISE_TIMEOUT) ; sets timer duration to display duration to allow for re-enable
                    (setvar 'disp_num DISPLAY_SMART_CRUISE_HALF)
                    (setvar 'click_beep CLICKS_QUINTUPLE)
                    ; slow scooter to 80% to help people realize custom is expiring
                    (set-rpm (calculate_rpm speed SMART_CRUISE_SLOWDOWN_DIVISOR))
                })
            )
        }) ; end Timer expiry
    }) ; end state
})

(move-to-flash state_handler_going_off)

(defun start_motor_speed_loop()
{
    (debug_log "Motor: Starting motor speed loop")
    (define speed SPEED_OFF)
    (define safe_start_timer 0)
    (define safe_start_attempt_speed SPEED_OFF)
    (define safe_start_failures 0)
    (define safe_start_status 'idle)

    (safe_start_reset_state)

    (let ((last_speed SPEED_OFF))
    {
        (loopwhile-thd THREAD_STACK_MOTOR t {
            (sleep SLEEP_MOTOR_CONTROL)
            (loopwhile (!= speed last_speed) {
            (debug_log_macro (str-merge "Motor: Speed change " (to-str (to-i last_speed)) "->" (to-str (to-i speed))))
            (sleep SLEEP_MOTOR_SPEED_CHANGE)
            ; turn off motor if speed is 99
            (if (= speed SPEED_OFF) {
                (debug_log "Motor: Stopping motor")
                (set-current 0)
                (setvar 'batt_disp_timer_start (systime)) ; Start trigger for Battery Display
                (setvar 'disp_num DISPLAY_OFF) ; Turn on Off display. (off display is needed to ensure restart triggers a new display number)
                (safe_start_reset_state) ; unlock speed changes and disable safe start timer
                (setvar 'last_speed speed)
                })

            (if (!= speed SPEED_OFF) {
                ; Soft Start section for all speeds
                (if (= last_speed SPEED_OFF) {
                    (debug_log "Motor: Soft start initiated")
                    (conf-set 'l-in-current-max (if (= scooter_type SCOOTER_BLACKTIP) MIN_CURRENT_BLACKTIP MIN_CURRENT_CUDAX))
                    (safe_start_begin speed)
                    (setvar 'last_speed SPEED_SOFT_START_SENTINEL)
                    (if (< speed SPEED_REVERSE_THRESHOLD)
                        (set-duty (- 0 SAFE_START_DUTY))
                        (set-duty SAFE_START_DUTY)
                    )
                })

                ; Set Actual Speeds section
            (let ((elapsed (secs-since safe_start_timer))
                (rpm (get-rpm))
                (duty (get-duty))
                (current (get-current))) {
                    (if (and (= use_safe_start 1) (not (safe_start_telemetry_valid rpm duty current)))
                        (safe_start_abort_with_reason "invalid telemetry")
                    )

                    (if (or (= use_safe_start 0)
                            (!= last_speed SPEED_SOFT_START_SENTINEL)
                            (safe_start_met_success_criteria rpm duty current))
                    {
                        (conf-set 'l-in-current-max (if (= scooter_type SCOOTER_BLACKTIP) MAX_CURRENT_BLACKTIP MAX_CURRENT_CUDAX))
                        (set-rpm (calculate_rpm speed RPM_PERCENT_DENOMINATOR))
                        (setvar 'disp_num (+ speed DISPLAY_SPEED_OFFSET))
                        (safe_start_success)
                        (setvar 'last_speed speed)
                    } {
                        (if (and (= use_safe_start 1)
                                 (= last_speed SPEED_SOFT_START_SENTINEL)
                                 (> elapsed (+ SAFE_START_TIMEOUT SAFE_START_TIMEOUT_GRACE)))
                            (safe_start_abort_with_reason "timeout")
                        )

                        ; If safe start conditions not met yet but last_speed is still sentinel, update to speed to exit inner loop after abort
                        (if (and (= last_speed SPEED_SOFT_START_SENTINEL)
                                 (not-eq safe_start_status 'running))
                            (setvar 'last_speed speed)
                        )
                    })

                    ; Detect high-current stall during safe start
                    (if (and (= use_safe_start 1)
                             (= last_speed SPEED_SOFT_START_SENTINEL)
                             (> elapsed SAFE_START_TIMEOUT)
                             (> (abs current) SAFE_START_FAIL_CURRENT)
                             (< (abs rpm) SAFE_START_MIN_RPM))
                        (safe_start_abort_with_reason "high current stall")
                    )
                })
                })
          })
        })
    })
})

(move-to-flash start_motor_speed_loop)

; Init-only function (not moved to flash)
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
        (setvar 'thirds_total (get_battery_level))
        (debug_log (str-merge "Battery: Initial level=" (to-str thirds_total)))
        (setvar 'warning_counter 0)
    })
})

(defun start_display_output_loop()
{
    (define disp_num 1) ; variable used to define the display screen you are accesing 0-X
    (define last_disp_num 1) ; variable used to track last display screen show

    (let ((start_pos 0) ; variable used to define start position in the array of diferent display screens
          (pixbuf (array-create 16))) ; create a temp array to store display bytes in
        {
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
                        (setvar 'mpu_addr 0x70)
                        (setvar 'mpu_addr 0x71)
                    )
                    (if (or (= disp_num 0) (= disp_num 1) (= disp_num 2) (= disp_num 3) (> disp_num 17) )
                        (if (= cudax_flip 1)
                            (setvar 'mpu_addr 0x71)
                            (setvar 'mpu_addr 0x70)
                        )
                    )
                })
                (setvar 'disp_timer_start (systime))
                (if (= mpu_addr 0x70)
                    (setvar 'start_pos (+(* 64 disp_num) (* 16 rotation))) ; define the correct start position in the array for the display
                    (setvar 'start_pos (+(* 64 disp_num) (* 16 rotation2)))
                    )
                (bufclear pixbuf)
                ; Copy display data from binary LUT (8 byte header + frame data)
                (bufcpy pixbuf 0 display_lut_bin (+ 8 start_pos) 16) ; copy the required display from binary LUT to "pixbuf"
                (i2c-tx-rx mpu_addr pixbuf) ; send display characters
                (i2c-tx-rx mpu_addr (list 0x81)) ; Turn on display
                (setvar 'last_disp_num disp_num)
                (setvar 'mpu_addr 0x70)
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

            (if (= thirds_total 0) {
                (cond
                    ((> actual_batt 0.75)
                    {
                        (setvar 'disp_num 3)
                        (spawn beeper 4)
                    })
                    ((> actual_batt 0.5)
                    {
                        (setvar 'disp_num 2)
                        (spawn beeper 3)
                    })
                    ((> actual_batt 0.25)
                    {
                        (setvar 'disp_num 1)
                        (spawn beeper 2)
                    })
                    (t
                    {
                        (setvar 'disp_num 0)
                        (spawn beeper 1)
                    }))
            })

            ; Section for 1/3rds display
            (cond
                ((and (> actual_batt (* thirds_total 0.66)) (= warning_counter 0))
                {
                    (debug_log "Battery: 2/3rds warning triggered")
                    (setvar 'disp_num 20)
                })
                ((and (> actual_batt (* thirds_total 0.33)) (< warning_counter 3))
                {
                    (debug_log "Battery: 1/3rd warning triggered")
                    (setvar 'disp_num 19)
                    (if (< warning_counter 2) {
                        (spawn warbler 350 0.5 0.5)
                        (setvar 'warning_counter (+ warning_counter 1))
                    })
                })
                (t
                {
                    (debug_log "Battery: Critical warning triggered")
                    (setvar 'disp_num 18)
                    (if (< warning_counter 4) {
                        (spawn warbler 350 0.5 0.5)
                        (setvar 'warning_counter (+ warning_counter 1))
                    })
                }))

            (setvar 'batt_disp_state 1)
            (setvar 'last_batt_disp_num disp_num)
        })

        (if (and (> batt_disp_timer_start 1) (> (secs-since batt_disp_timer_start) 12) (= batt_disp_state 1) (> thirds_total 0)) {

            (cond
                ((> actual_batt 0.95)
                    (setvar 'disp_num 30))
                ((> actual_batt 0.90)
                    (setvar 'disp_num 29)) ; 90%
                ((> actual_batt 0.80)
                    (setvar 'disp_num 28)) ; 80%
                ((> actual_batt 0.70)
                    (setvar 'disp_num 27)) ; 70%
                ((> actual_batt 0.60)
                    (setvar 'disp_num 26)) ; 60%
                ((> actual_batt 0.50)
                    (setvar 'disp_num 25)) ; 50%
                ((> actual_batt 0.40)
                    (setvar 'disp_num 24)) ; 40%
                ((> actual_batt 0.30)
                    (setvar 'disp_num 23)) ; 30%
                ((> actual_batt 0.20)
                    (setvar 'disp_num 22)) ; 20%
                (t
                    (setvar 'disp_num 21)))
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

; Init-only function (not moved to flash)
(defun peripherals_setup()
{
    (define disp_timer_start 0) ; Timer for display duration

    (if (or (= 0 hardware_configuration) (= 3 hardware_configuration)) ; turn on i2c for the screen based on wiring. 0 = Blacktip with Bluetooth, 3 = CudaX with Bluetooth
            (i2c-start 'rate-400k 'pin-swdio 'pin-swclk) ; Works HW 60 with screen on SWD Connector. Screen SDA pin to Vesc SWDIO (2), Screen SCL pin to Vesc SWCLK (4)
            (if (or (= 1 hardware_configuration) ( = 4 hardware_configuration)) ; 1 = Blacktip without Bluetooth, 4 = CudaX without Bluetooth
                (i2c-start 'rate-400k 'pin-rx 'pin-tx) ; Works HW 60 with screen on Comm Connector. Screen SDA pin to Vesc RX/SDA (5), Screen SCL pin to Vesc TX/SCL (6)
                (if ( = 2 hardware_configuration)
                    (i2c-start 'rate-400k 'pin-tx 'pin-rx) ; tested on HW 410 Tested: SN 189, SN 1691
                    (nil))))

        (define mpu_addr 0x70) ; I2C Address for the screen

        (i2c-tx-rx 0x70 (list 0x21)) ; start the oscillator
        ; Get brightness byte from binary LUT (8 byte header + brightness data)
        (i2c-tx-rx 0x70 (list (bufget-u8 brightness_lut_bin (+ 8 disp_brightness)))) ; set brightness

        (if (= scooter_type 1) { ; For cuda X setup second screen
                (i2c-tx-rx 0x71 (list 0x21)) ; start the oscillator
                (i2c-tx-rx 0x71 (list (bufget-u8 brightness_lut_bin (+ 8 disp_brightness)))) ; set brightness
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

    (state_transition_to STATE_OFF "startup" THREAD_STACK_STATE_TRANSITIONS state_handler_off) ; ***Start state machine running for first time

    (setvar 'disp_num 15) ; display startup screen, change bytes if you want a different one
    (setvar 'batt_disp_timer_start (systime)) ; turns battery display on for power on.

    ; Log this irrespective of logging setting
    (debug_log "Startup complete")
})

(main)
