"""Native LispBM protocol checks with EEPROM, transport and motor mocked."""

import ast
import re
import struct
import subprocess
import tempfile
import zlib
from pathlib import Path

from perf_log_writer import source as writer_source

ROOT = Path(__file__).resolve().parents[1]

MOCKS = '''
(define frames (bufcreate 1024)) (define frame_count 0)
(define frame_lengths (bufcreate 16))
(define pace_seen 0)
(define mock_motor_ref 180.0)
(defun mock-conf-get () mock_motor_ref)
(define fail_send 0)
(define ack_gate 0)
(defun mock-send-data (b) {
    (if (= fail_send 1) (car 1))
    (if (and (= ack_gate 1) (= (bufget-u8 b 0) 178)) {
        (setvar 'ack_gate 0)
        (mock-barrier 5)
    })
    (bufset-u8 frames (* frame_count 32) (bufget-u8 b 0))
    (bufset-u8 frame_lengths frame_count (buflen b))
    (looprange i 0 (buflen b) (bufset-u8 frames (+ (* frame_count 32) i) (bufget-u8 b i)))
    (setvar 'frame_count (+ frame_count 1))
    t
})
(defun mock-frame (i p) (bufget-u8 frames (+ (* i 32) p)))
(define settings_writes 0)
(defun mock-settings-write (i v) (setvar 'settings_writes (+ settings_writes 1)))
(defun update_settings_from_eeprom () t)
(defun debug_log_format (s) nil)
(defun debug_log (s) nil)
(defun send_current_settings () (setvar 'frame_count (+ frame_count 1)))
(define HANDSHAKE_CODE 255) (define EEPROM_SETTINGS_COUNT 33)
(define LOG_SAMPLE_PERIOD 0.2) (define THREAD_STACK_LOG 160)
(define LOG_CHUNK_PACE_MS 10)
(define sample_count 0)
(defun log_sample () {
    (setvar 'sample_count (+ sample_count 1))
    (bufset-u32 log_st 0 mock_now)
})
(defun mock-receive (len op) {
    (var p (bufcreate len))
    (if (> len 0) (bufset-u8 p 0 op))
    (receive_data p)
})
(defun mock-request (op block value) {
    (var p (bufcreate 3))
    (bufset-u8 p 0 op) (bufset-u8 p 1 block) (bufset-u8 p 2 value)
    (receive_data p)
})
(defun mock-await-frames (count) {
    (var tries 0)
    (loopwhile (and (< frame_count count) (< tries 300)) {
        (sleep 0.001)
        (setq tries (+ tries 1))
    })
    (= frame_count count)
})
'''


def source(replacements=(), extra='', production_sample=False):
    # The writer harness replaces hardware primitives in the production source.
    app = (ROOT / 'blacktip_dpv.lisp').read_text()
    receiver = app[app.index('(defun receive_data (data)'):app.index('; Setup functions')]
    receiver = receiver.replace('(eeprom_store_i_if_changed ', '(mock-settings-write ')
    text = writer_source().replace('(send-data ', '(mock-send-data ')
    original = '(defun log_motor_reference () (list 1600 2))'
    motor_ref = app[app.index('(defun log_motor_reference ()'):
                    app.index('(defun log_b_references (b)')]
    text = text.replace(original,
                        motor_ref.replace("(conf-get 'l-temp-motor-start)", '(mock-conf-get)'))
    text = text.replace("(conf-get 'l-temp-motor-start)", '(mock-conf-get)')
    text = text.replace('(defun mock-sleep (s) {',
                        "(defun mock-sleep (s) { (setvar 'pace_seen s)")
    if production_sample:
        constants = app[app.index('; Performance log block A.'):
                        app.index('; Lightweight macro')]
        sample = app[app.index('(defun log_b_sag ('):
                     app.index('; Hook in safe_start_abort_with_reason')]
        for name in ('rpm', 'rpm-set', 'current-in', 'ah', 'wh', 'fault',
                     'temp-fet', 'temp-mot', 'current', 'vin', 'duty'):
            sample = sample.replace('(get-' + name + ')', '(mock-get-' + name + ')')
        sample = sample.replace('(systime)', '(mock-systime)')
        sample = sample.replace('(secs-since ', '(mock-secs-since ')
        sample = sample.replace('(get-battery-imbalance-voltage)',
                                '(mock-get-battery-imbalance-voltage)')
        sample = sample.replace('(get-battery-imbalance-warning)',
                                '(mock-get-battery-imbalance-warning)')
        text = constants + text
        extra += '''
(define soft_start_active 0) (define safe_start_status 'idle)
(define SCOOTER_BLACKTIP 0) (define BATTERY_IMBALANCE_WARN_NONE 0)
(define DUTY_AT_REST_THRESHOLD 0.02)
(define battery_imbalance_latched 0) (define balance_smoothing_held 1)
(define lower_voltage_smooth 0.0)
(defun mock-get-rpm () mock_rpm_value)
(defun mock-get-rpm-set () 0.0)
(defun mock-get-current-in () 0.0)
(defun mock-get-ah () 0.0)
(defun mock-get-wh () 0.0)
(defun mock-get-fault () 0.0)
(defun mock-get-temp-fet () 35.0)
(defun mock-get-temp-mot () 30.0)
(defun mock-get-current () 0.0)
(defun mock-get-vin () 35.0)
(defun mock-get-duty () mock_duty_value)
''' + sample
    for old, new in replacements:
        assert old in text, old
        text = text.replace(old, new)
    return text + MOCKS + extra + receiver


def run(repl, script, replacements=(), extra='', production_sample=False, heap=2753):
    text = source(replacements, extra, production_sample) + script
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'protocol.lisp'
        path.write_text(text)
        result = subprocess.run([repl, '-H', str(heap), '-M', '262144', '-C', '262144',
                                 '--bldc_stubs', '--terminate', '-s', str(path)],
                                capture_output=True, text=True, timeout=60)
    lines = [line[2:] for line in result.stdout.splitlines() if line.startswith('> ')]
    if result.returncode or not lines or 'Error:' in result.stdout or \
            any(x in lines[-1] for x in ('eval_error', 'out_of_memory', 'out_of_stack')):
        raise AssertionError(result.stdout + result.stderr)
    return lines[-1]


def check(repl):
    def expect(name, script, expected):
        value = run(repl, script)
        assert value == expected, (name, value, expected)

    # This uses the production log_sample and collector helpers, not the
    # counting sampler stub used by the other protocol isolation tests.
    simultaneous = run(repl, '''
(mock-setup) (log_initialise log_a 1) (log_initialise log_b 1)
(setvar 'log_owner -1) (setvar 'mock_concurrent 1) (log_start)
(define before_writes writes)
(define request (bufcreate 4))
(bufset-u8 request 0 161) (bufset-u8 request 1 0)
(bufset-u8 request 2 1) (bufset-u8 request 3 250)
(receive_data request)
(define first_frame (mock-await-frames 1))
(setvar 'speed 5) (setvar 'mock_rpm_value 3600.0)
(setvar 'mock_duty_value 0.3) (setvar 'mock_now (+ mock_now 250))
(send log_owner 'log-wake) (sleep 0.05)
(define live_sample (mock-slot log_a 72))
(setvar 'speed SPEED_OFF) (setvar 'mock_rpm_value 0.0)
(setvar 'mock_duty_value 0.0) (setvar 'mock_now (+ mock_now 250))
(send log_owner 'log-wake) (sleep 0.05)
(mock-request 163 1 0)
(define tries 0)
(loopwhile (and (= log_write_busy 1) (< tries 400)) {
    (sleep 0.001) (setq tries (+ tries 1))
})
(define write_finished (= log_write_busy 0))
(define concurrent_read_busy log_read_busy)
(setq tries 0)
(loopwhile (and (< frame_count 12) (< tries 400)) {
    (sleep 0.01) (setq tries (+ tries 1))
})
(define all_frames (= frame_count 12))
(setq tries 0)
(loopwhile (and (= log_read_busy 1) (< tries 400)) {
    (sleep 0.001) (setq tries (+ tries 1))
})
(gc)
(list first_frame before_writes writes live_sample
      (bufget-u32 frames (+ (* 32 2) 14)) (bufget-u32 log_st 0)
      log_enable_b write_finished concurrent_read_busy all_frames
      log_read_busy frame_count (mem-num-free) (mem-longest-free))
''', production_sample=True, heap=8000)
    values = simultaneous.strip('()').split()
    assert len(values) == 14 and values[:12] == [
        't', '129', '137', '2u32', '0u32', '10500u32',
        '0', 't', '1', 't', '0', '12'], simultaneous
    assert int(values[12]) > 0 and int(values[13]) > 0, simultaneous
    print('native production sampler/read/write checkpoint:', simultaneous)

    repeated = run(repl, '''
(mock-setup) (log_initialise log_a 1) (log_initialise log_b 1)
(setvar 'log_owner -1) (setvar 'mock_concurrent 1) (log_start)
(define first_free 0) (define first_longest 0) (define first_gc 0)
(define complete t)
(looprange group 0 2 {
    (looprange iteration 0 3 {
        (setvar 'frame_count 0)
        (mock-request 161 0 1)
        (setvar 'speed 5) (setvar 'mock_rpm_value 3600.0)
        (setvar 'mock_duty_value 0.3) (setvar 'mock_now (+ mock_now 250))
        (send log_owner 'log-wake) (sleep 0.01)
        (setvar 'speed SPEED_OFF) (setvar 'mock_rpm_value 0.0)
        (setvar 'mock_duty_value 0.0) (setvar 'mock_now (+ mock_now 250))
        (send log_owner 'log-wake)
        (mock-request 163 1 0)
        (var attempts 0)
        (loopwhile (and (= log_write_busy 1) (< attempts 400)) {
            (sleep 0.001) (setq attempts (+ attempts 1))
        })
        (if (or (!= log_write_busy 0) (!= log_enable_b 0))
            (setvar 'complete nil))
        (setq attempts 0)
        (loopwhile (and (= log_read_busy 1) (< attempts 400)) {
            (sleep 0.001) (setq attempts (+ attempts 1))
        })
        (if (or (!= log_read_busy 0) (!= frame_count 12))
            (setvar 'complete nil))
        (mock-request 163 1 1)
        (setq attempts 0)
        (loopwhile (and (= log_write_busy 1) (< attempts 400)) {
            (sleep 0.001) (setq attempts (+ attempts 1))
        })
        (if (or (!= log_write_busy 0) (!= log_enable_b 1)
                (!= frame_count 13)) (setvar 'complete nil))
    })
    (gc)
    (if (= group 0) {
        (setvar 'first_free (mem-num-free))
        (setvar 'first_longest (mem-longest-free))
        (setvar 'first_gc (lbm-heap-state 'get-gc-num))
    })
})
(gc)
(list complete (> (mock-slot log_a 72) 0) first_free (mem-num-free)
      first_longest (mem-longest-free) first_gc
      (lbm-heap-state 'get-gc-num) log_read_busy log_write_busy)
''', production_sample=True, heap=8000)
    values = repeated.strip('()').split()
    assert len(values) == 10 and values[:2] == ['t', 't'] and values[-2:] == ['0', '0'], repeated
    assert values[2] == values[3] and values[4] == values[5], repeated
    assert int(values[7].rstrip('u')) > int(values[6].rstrip('u')), repeated
    print('native production sampler repeated-request checkpoints:', repeated)

    expect('empty first enable commits one owner block',
           "(mock-setup) (setvar 'log_a nil) (setvar 'log_state_a 'empty) "
           "(log_operation '(163 0 1 0 3 0)) "
           "(list writes log_enable_a log_state_a frame_count (mock-frame 0 2))",
           '(64 1 ok 1 0)')
    expect('explicit enable waives settle and interval but not rest',
           "(mock-setup) (setvar 'log_state_a 'empty) "
           "(setvar 'log_rest_since 0) (setvar 'log_flush_seen 1) "
           "(setvar 'log_last_flush mock_now) "
           "(log_operation '(163 0 1 0 3 0)) "
           "(list log_enable_a (mock-frame 0 2) writes)", '(1 0 64)')
    expect('malformed clear wins over rest and state',
           "(mock-setup) (setvar 'speed 5) (setvar 'log_state_a 'foreign) "
           "(log_operation '(162 0 0 0 3 0)) "
           "(list writes (mock-frame 0 2) log_state_a)", '(0 3 foreign)')
    expect('rest wins over block state',
           "(mock-setup) (setvar 'speed 5) (setvar 'log_state_a 'foreign) "
           "(log_operation '(163 0 1 0 3 0)) "
           "(list writes (mock-frame 0 2) log_state_a)", '(0 1 foreign)')
    expect('foreign cannot be enabled',
           "(mock-setup) (setvar 'log_state_a 'foreign) "
           "(log_operation '(163 0 1 0 3 0)) "
           "(list writes (mock-frame 0 2) log_state_a)", '(0 2 foreign)')
    expect('foreign clear claims disabled',
           "(mock-setup) (setvar 'log_state_a 'foreign) "
           "(log_operation '(162 0 90 0 3 0)) "
           "(list log_enable_a log_state_a (mock-frame 0 2))", '(0 ok 0)')
    expect('empty B clear references and claims disabled',
           "(mock-setup) (setvar 'log_b nil) (setvar 'log_state_b 'empty) "
           "(log_operation '(162 1 90 0 3 1)) "
           "(list log_enable_b log_state_b (mock-slot log_b 190) "
           "(bitwise-and (mock-slot log_b 189) 32767) (mock-frame 0 2))",
           '(0 ok 58982400u32 850u32 0)')
    expect('failed motor reference read falls back to 1600 on clear',
           "(mock-setup) (setvar 'mock_motor_ref nil) "
           "(setvar 'log_state_b 'foreign) "
           "(log_operation '(162 1 90 0 3 1)) "
           "(list (mock-slot log_b 190) "
           "(bitwise-and (mock-slot log_b 131) 2) (mock-frame 0 2))",
           '(52428800u32 0u32 0)')
    expect('empty B enable refreshes accepted 180 degree motor reference',
           "(mock-setup) (setvar 'log_b nil) (setvar 'log_state_b 'empty) "
           "(log_operation '(163 1 1 0 3 1)) "
           "(list log_enable_b (mock-slot log_b 190) "
           "(bitwise-and (mock-slot log_b 189) 32767) "
           "(bitwise-and (mock-slot log_b 131) 2) (mock-frame 0 2))",
           '(1 58982400u32 850u32 2u32 0)')
    expect('B tag accepts zero and maximum, rejects overflow',
           "(mock-setup) (log_operation '(163 1 1 0 3 1)) "
           "(log_operation '(164 1 255 0 3 127)) "
           "(define hi (mock-slot log_b 133)) "
           "(log_operation '(164 1 0 0 3 128)) "
           "(list hi (mock-slot log_b 133) (mock-frame 2 2) (mock-frame 2 3))",
           '(1073709056u32 1073709056u32 3 1)')
    expect('pack tag zero changes only B RAM and leaves A untouched',
           "(mock-setup) (log_operation '(163 0 1 0 3 0)) "
           "(log_operation '(163 1 1 0 3 1)) "
           "(define previous_writes writes) (define a_copy (mock-snapshot log_a)) "
           "(log_operation '(164 1 255 0 3 127)) "
           "(log_operation '(164 1 0 0 3 0)) "
           "(list (mock-frame 3 2) (mock-slot log_b 133) "
           "(bufget-u32 log_b 4) (= previous_writes writes) "
           "(mock-same log_a a_copy))", '(0 0u32 1u32 t t)')
    expect('explicit store failure never acknowledges success',
           "(mock-setup) (setvar 'log_a nil) (setvar 'log_state_a 'empty) "
           "(setvar 'fail_write 2) (log_operation '(163 0 1 0 3 0)) "
           "(list writes log_enable_a log_state_a (mock-frame 0 2))",
           '(2 0 in_progress 2)')
    expect('rest loss during explicit store never acknowledges success',
           "(mock-setup) (setvar 'log_a nil) (setvar 'log_state_a 'empty) "
           "(setvar 'press_write 1) (log_operation '(163 0 1 0 3 0)) "
           "(list writes log_enable_a log_state_a (mock-frame 0 2))",
           '(1 0 in_progress 1)')
    for block, n in ((0, 63), (1, 64)):
        for offset in (1, 2, n - 2, n, n + 1):
            expect(f'block {block} rest loss after store phase {offset}',
                   f"(mock-setup) (setvar 'log_{'a' if block == 0 else 'b'} nil) "
                   f"(setvar 'log_state_{'a' if block == 0 else 'b'} 'empty) "
                   f"(setvar 'press_write {offset}) "
                   f"(log_operation '(163 {block} 1 0 3 {block})) "
                   "(list writes (mock-frame 0 2))", f'({offset} 1)')
        base = 64 if block == 0 else 128
        for offset, slot in ((1, base), (2, base + 2),
                             (n - 2, base + n - 1), (n, base + 1),
                             (n + 1, base)):
            expect(f'block {block} store failure phase {offset}',
                   f"(mock-setup) (setvar 'log_{'a' if block == 0 else 'b'} nil) "
                   f"(setvar 'log_state_{'a' if block == 0 else 'b'} 'empty) "
                   f"(setvar 'fail_write {offset}) "
                   f"(log_operation '(163 {block} 1 0 3 {block})) "
                   "(list writes (mock-frame 0 2))", f'({offset} 2)')
            expect(f'block {block} readback failure phase {offset}',
                   f"(mock-setup) (setvar 'log_{'a' if block == 0 else 'b'} nil) "
                   f"(setvar 'log_state_{'a' if block == 0 else 'b'} 'empty) "
                   f"(setvar 'fail_read_after_write {slot}) "
                   f"(setvar 'fail_read_after_count {offset}) "
                   f"(log_operation '(163 {block} 1 0 3 {block})) "
                   "(list writes (mock-frame 0 2))", f'({offset} 2)')
    expect('shutdown revocation after first store prevents all later stores',
           "(mock-setup) (setvar 'log_a nil) (setvar 'log_state_a 'empty) "
           "(setvar 'cancel_write 1) (log_operation '(163 0 1 0 3 0)) "
           "(list writes log_enable_a log_state_a (mock-frame 0 2))",
           '(1 0 in_progress 2)')
    expect('unknown and read-error states refuse without touching EEPROM',
           "(mock-setup) (setvar 'log_state_b 'unknown_layout) "
           "(log_operation '(162 1 90 0 3 1)) "
           "(setvar 'log_state_b 'read_error) (log_operation '(163 1 1 0 3 1)) "
           "(list writes (mock-frame 0 2) (mock-frame 1 2))",
           '(0 2 2)')
    for block in (0, 1):
        symbol = 'a' if block == 0 else 'b'
        for state, initially_enabled in (('empty', 0), ('ok', 1), ('ok', 0),
                                         ('foreign', 0), ('unknown_layout', 0),
                                         ('in_progress', 0), ('crc_mismatch', 0),
                                         ('read_error', 0)):
            setup = (f"(mock-setup) (setvar 'log_state_{symbol} '{state}) "
                     f"(setvar 'log_enable_{symbol} {initially_enabled}) "
                     f"(bufset-u32 log_{symbol} 20 "
                     f"(bitwise-or (bitwise-and (bufget-u32 log_{symbol} 20) "
                     f"(bitwise-not 1)) {initially_enabled})) "
                     f"(define before_image (mock-snapshot log_{symbol})) ")
            clear_ok = state in ('empty', 'ok', 'foreign', 'in_progress', 'crc_mismatch')
            for op, value, succeeds in ((162, 90, clear_ok),
                                         (163, 1, state in ('empty', 'ok'))):
                output = (f"(log_operation '({op} {block} {value} 0 3 {block})) "
                          f"(list (mock-frame 0 2) log_state_{symbol} "
                          f"log_enable_{symbol} (if (> writes 0) 1 0) "
                          f"(if (= writes 0) (mock-same log_{symbol} before_image) t))")
                expected_enable = (initially_enabled if op == 162 else 1) if succeeds else initially_enabled
                enabled_text = (f'{expected_enable}u32' if op == 162 and succeeds
                                and state == 'ok' else str(expected_enable))
                expected = (f"({0 if succeeds else 2} "
                            f"{('ok' if succeeds else state)} {enabled_text} "
                            f"{1 if succeeds else 0} t)")
                expect(f'block {block} {state}/{initially_enabled} opcode {op}',
                       setup + output, expected)
    expect('invalid pack tag',
           "(mock-setup) (log_operation '(164 1 0 0 3 128)) "
           "(list writes (mock-frame 0 2) (mock-frame 0 3))", '(0 3 1)')
    expect('empty and malformed prefixes never write settings',
           "(mock-setup) (mock-receive 0 0) (mock-receive 1 162) "
           "(mock-receive 33 161) (mock-receive 200 164) "
           "(list settings_writes (ix log_write_request 4) (ix log_read_request 4))",
           '(0 1 33)')
    expect('bounded write and read admission under burst',
           "(mock-setup) (mock-request 162 0 90) (mock-request 163 1 1) "
           "(mock-request 161 0 0) (mock-request 161 1 1) "
           "(list (ix log_write_request 0) (ix log_read_request 1) "
           "log_write_busy log_read_busy settings_writes)",
           '(162 0 1 1 0)')
    for opcode in (161, 163):
        expect(f'failed wake releases opcode {opcode} reservation',
               "(mock-setup) (setvar 'log_owner 2147483647) "
               f"(mock-request {opcode} 0 0) "
               "(list log_read_busy log_write_busy log_read_request "
               "log_write_request frame_count writes)",
               '(0 0 nil nil 0 0)')
    expect('same-class command drops while first acknowledgement blocked',
           "(setvar 'log_owner -1) (setvar 'log_a nil) "
           "(setvar 'log_st nil) (setvar 'log_state_a 'empty) "
           "(setvar 'mock_concurrent 1) (setvar 'ack_gate 1) "
           "(log_start) (mock-request 163 0 1) "
           "(mock-await 5) (mock-request 163 0 0) "
           "(define still_busy log_write_busy) "
           "(setvar 'mock_release 1) (mock-await-frames 1) "
           "(loopwhile (= log_write_busy 1) (sleep 0.001)) "
           "(mock-request 163 0 0) (mock-await-frames 2) "
           "(list still_busy frame_count log_enable_a writes)",
           '(1 2 0 68)')
    expect('shutdown retires pending write without a delayed store',
           "(mock-setup) (mock-request 163 0 1) (log_shutdown_flush) "
           "(log_requests) (list writes log_shutdown_state log_write_busy "
           "log_write_request frame_count)", '(0 3 0 nil 0)')
    expect('quiescent activity re-arm never replays cancelled protocol work',
           "(mock-setup) (mock-request 163 0 1) (log_shutdown_flush) "
           "(setvar 'speed 5) (log_rest_tick) "
           "(setvar 'speed SPEED_OFF) (log_rest_tick) "
           "(log_requests) (list writes log_shutdown_state log_write_busy "
           "log_write_request frame_count)", '(0 0 0 nil 0)')
    expect('lengths two, four and eight and settings-sized opcode rejected',
           "(mock-setup) (loopforeach n '(2 4 8 33) { "
           "(setvar 'log_write_busy 0) (setvar 'log_write_request nil) "
           "(mock-receive n 162) (log_requests) }) "
           "(list frame_count (mock-frame 0 2) (mock-frame 3 2) "
           "settings_writes writes)", '(4 3 3 0 0)')
    for op in (161, 162, 163, 164):
        for length in (0, 1, 2, 3, 4, 8, 33, 200):
            # Deliberately invalid arguments make every non-empty request an
            # acknowledgement, even when the nominal length is correct.
            payload = (f'(define p (bufcreate {length})) '
                       + (f'(bufset-u8 p 0 {op}) ' if length else '')
                       + (f'(bufset-u8 p 1 {128 if op == 164 else 2}) '
                          if length > 1 else '')
                       + '(receive_data p) (log_requests) '
                       '(list settings_writes writes frame_count '
                       '(if (> frame_count 0) (mock-frame 0 0) 0) '
                       '(if (> frame_count 0) (mock-frame 0 1) 0) '
                       '(if (> frame_count 0) (mock-frame 0 2) 0) '
                       '(if (> frame_count 0) (mock-frame 0 3) 0))')
            block = 1 if op == 164 else 255 if length == 1 else 2
            expected = (f'(0 0 1 178 {op} 3 {block})' if length
                        else '(0 0 0 0 0 0 0)')
            expect(f'opcode {op} malformed length {length}',
                   '(mock-setup) ' + payload, expected)
    expect('invalid admitted read acknowledges with missing block sentinel',
           "(mock-setup) (mock-receive 1 161) (log_requests) "
           "(list frame_count (mock-frame 0 0) (mock-frame 0 1) "
           "(mock-frame 0 2) (mock-frame 0 3) log_read_busy)",
           '(1 178 161 3 255 0)')
    expect('handshake and settings write remain intact',
           "(mock-setup) (mock-receive 1 255) (mock-receive 33 20) "
           "(list frame_count settings_writes log_write_busy)", '(1 33 0)')
    expect('spawned dormant owner enables, disables last, re-enables',
           "(setvar 'log_owner -1) (setvar 'log_a nil) (setvar 'log_b nil) "
           "(setvar 'log_st nil) (setvar 'log_state_a 'empty) "
           "(log_start) (define owner log_owner) (log_start) "
           "(mock-request 163 0 1) (mock-await-frames 1) "
           "(mock-request 163 0 0) (mock-await-frames 2) "
           "(mock-request 163 0 1) (mock-await-frames 3) "
           "(list (= owner log_owner) frame_count log_enable_a log_state_a writes)",
           '(t 3 1 ok 72)')
    owner_failure = run(repl,
        "(setvar 'log_owner -1) (setvar 'log_st nil) "
        "(setvar 'mock_concurrent 1) (log_start) "
        "(mock-request 163 0 1) "
        "(loopwhile (!= log_owner -1) (sleep 0.001)) "
        "(list log_shutdown_state log_write_busy log_write_request log_read_busy "
        "log_read_request writes)",
        (('(log_requests)\n    })', '(mock-crash-owner)\n    })'),),
        '(defun mock-crash-owner () (car 1))')
    assert owner_failure == '(3 0 nil 0 nil 0)', ('owner trap cleanup', owner_failure)
    startup_failure = run(repl,
        "(setvar 'log_owner -1) (setvar 'log_enable_a 1) "
        "(setvar 'log_a (log_blk_new 64 63)) "
        "(setvar 'mock_concurrent 1) (log_start) "
        "(list log_owner log_shutdown_state log_write_busy log_read_busy)",
        (('(var st (bufcreate 108))', '(var st (mock-state-create 108))'),),
        '(defun mock-state-create (n) (car 1))')
    assert startup_failure == '(-1 3 0 0)', ('owner startup failure does not hang', startup_failure)
    expect('timed native owner samples despite protocol wake traffic',
           "(setvar 'log_owner -1) (setvar 'log_enable_a 1) "
           "(setvar 'log_a (log_blk_new 64 63)) "
           "(setvar 'log_st nil) (log_start) "
           "(looprange i 0 8 { (send log_owner 'log-wake) (sleep 0.005) }) "
           "(setvar 'mock_now (+ mock_now 250)) "
           "(send log_owner 'log-wake) (sleep 0.05) "
           "(list (= sample_count 1) (= log_owner -1))", '(t nil)')
    expect('spawned protocol store revoked while reserved, no later store',
           "(setvar 'log_owner -1) (setvar 'log_a nil) (setvar 'log_st nil) "
           "(setvar 'log_state_a 'empty) (setvar 'mock_concurrent 1) "
           "(setvar 'mock_block_write 1) (log_start) "
           "(mock-request 163 0 1) (mock-await 1) "
           "(spawn 150 log_shutdown_flush) "
           "(loopwhile (!= log_shutdown_state 3) (sleep 0.001)) "
           "(setvar 'mock_release 1) (mock-await-frames 1) "
           "(sleep 0.02) (list writes log_shutdown_state log_write_busy "
           "log_enable_a log_state_a (mock-frame 0 2))",
           '(1 3 0 0 in_progress 2)')
    for block, size, base in ((0, 63, 64), (1, 64, 128)):
        for offset, slot in ((1, base), (2, base + 2),
                             (size - 2, base + size - 1),
                             (size, base + 1), (size + 1, base)):
            for barrier, phase in (('mock_block_write', 1),
                                   ('mock_block_yield', 2),
                                   ('mock_block_read', 3)):
                barrier_setup = (f"(setvar '{barrier} {offset}) " +
                                 (f"(setvar 'mock_block_read_slot {slot}) "
                                  if phase == 3 else ''))
                result = run(repl,
                    f"(setvar 'log_owner -1) (setvar 'log_a nil) "
                    f"(setvar 'log_b nil) (setvar 'log_st nil) "
                    f"(setvar 'log_state_{'a' if block == 0 else 'b'} 'empty) "
                    "(setvar 'mock_concurrent 1) " + barrier_setup +
                    f"(log_start) (mock-request 163 {block} 1) "
                    f"(mock-await {phase}) (spawn 150 log_shutdown_flush) "
                    "(loopwhile (!= log_shutdown_state 3) (sleep 0.001)) "
                    "(setvar 'mock_release 1) (mock-await-frames 1) "
                    f"(list writes log_shutdown_state log_write_busy "
                    f"(mock-frame 0 2))")
                expected = f'({offset} 3 0 2)'
                assert result == expected, (block, offset, barrier, result, expected)
    expect('shutdown does not await a paced read sender',
           "(setvar 'log_owner -1) (setvar 'log_st nil) "
           "(setvar 'mock_concurrent 1) (log_start) "
           "(mock-request 161 0 0) (mock-await-frames 1) "
           "(log_shutdown_flush) "
           "(list log_shutdown_state (= log_read_busy 1) (< frame_count 11))",
           '(3 t t)')
    expect('snapshot of empty stored and disabled live',
           "(mock-setup) (define s (log_snapshot 0 1)) "
           "(list (ix s 1) (bufget-u32 (ix s 0) 0) (buflen (ix s 0)))",
           '(0 4294967295u32 252)')
    expect('stored verified enabled and live retained header',
           "(mock-setup) (log_initialise log_a 1) "
           "(define s (log_snapshot 0 0)) (define l (log_snapshot 0 1)) "
           "(list (ix s 1) (ix l 1) (bufget-u32 (ix s 0) 0) "
           "(bufget-u32 (ix l 0) 0) (bufget-u32 (ix l 0) 4))",
           '(9 9 2u32 2u32 1635297546u32)')
    expect('stored partial read is torn with sentinel',
           "(mock-setup) (log_initialise log_a 1) "
           "(setvar 'fail_read 69) (define s (log_snapshot 0 0)) "
           "(list (ix s 1) (bufget-u32 (ix s 0) 20))",
           '(11 4294967295u32)')
    expect('disabled live has sentinel though stored valid',
           "(mock-setup) (log_initialise log_a 0) "
           "(define l (log_snapshot 0 1)) "
           "(list (ix l 1) (bufget-u32 (ix l 0) 0) "
           "(bufget-u32 (ix l 0) 248))",
           '(2 4294967295u32 4294967295u32)')
    expect('foreign image is preserved verbatim',
           "(mock-setup) (bufset-u32 nv (* 66 4) 42) "
           "(bufset-u8 present 66 1) (define s (log_snapshot 0 0)) "
           "(list (ix s 1) (bufget-u32 (ix s 0) 8) "
           "(bufget-u32 (ix s 0) 12))",
           '(5 42u32 4294967295u32)')
    expect('unknown layout takes precedence over missing sequence',
           "(mock-setup) (bufset-u32 nv (* 66 4) 1112820807) "
           "(bufset-u32 nv (* 67 4) 512) "
           "(bufset-u8 present 66 1) (bufset-u8 present 67 1) "
           "(ix (log_snapshot 0 0) 1)", '4')
    expect('missing sequence with known magic is torn',
           "(mock-setup) (bufset-u32 nv (* 66 4) 1112820807) "
           "(bufset-u32 nv (* 67 4) 257) "
           "(bufset-u8 present 66 1) (bufset-u8 present 67 1) "
           "(ix (log_snapshot 0 0) 1)", '11')
    for block, base in ((0, 64), (1, 128)):
        for kind, state in (('empty', 0), ('enabled', 9), ('disabled', 2),
                            ('foreign', 13), ('unknown', 4), ('odd', 11),
                            ('crc', 11), ('read_error', 11)):
            init = ('' if kind == 'empty' else
                    f"(log_initialise log_{'a' if block == 0 else 'b'} "
                    f"{0 if kind == 'disabled' else 1}) ")
            changes = {
                'foreign': f'(bufset-u32 nv (* {base + 2} 4) 42) ',
                'unknown': f'(bufset-u32 nv (* {base + 3} 4) 512) ',
                'odd': f'(bufset-u32 nv (* {base} 4) 3) ',
                'crc': f'(bufset-u32 nv (* {base + 5} 4) 42) ',
                'read_error': f"(setvar 'fail_read {base + 5}) ",
            }.get(kind, '')
            # The state derives from EEPROM rather than the boot mirror or a
            # Python classifier. Both readable and unreadable words are sent.
            script = (f'(mock-setup) {init}{changes}'
                      f'(define s (log_snapshot {block} 0)) '
                      f'(list (ix s 1) (bufget-u32 (ix s 0) 0) '
                      f'(bufget-u32 (ix s 0) 20))')
            result = run(repl, script)
            values = result.strip('()').split()
            assert len(values) == 3 and values[0] == str(state), (block, kind, result)
            if kind == 'empty':
                assert values[1:] == ['4294967295u32', '4294967295u32'], result
            if kind == 'read_error':
                assert values[2] == '4294967295u32', result
    expect('sender has all eleven chunks and exact last frame',
           "(mock-setup) (define s (log_snapshot 0 0)) "
           "(log_send_snapshot 0 0 10 (ix s 0) (ix s 1)) "
           "(list frame_count (mock-frame 0 0) (mock-frame 0 4) "
           "(mock-frame 10 3) (mock-frame 10 5) log_read_busy)",
           '(11 177 11 10 0 0)')
    for block, base, n, magic in ((0, 64, 63, 1112820807),
                                  (1, 128, 64, 1112820808)):
        stored = [6, 0, magic, 257] + [100000 + i * 317 for i in range(4, n)]
        stored[1] = zlib.crc32(b''.join(struct.pack('>I', v) for v in stored[2:])) & 0x7fffffff
        for part in (0, 1):
            image = stored.copy()
            if part:
                image[15] += 19
            header = bytes([177, block, part])
            frames = [header + bytes([i, 11, 9 if i == 0 else 0]) +
                      b''.join(struct.pack('>I', v) for v in image[i * 6:i * 6 + 6])
                      for i in range(11)]
            put = ''.join(f'(bufset-u32 nv (* {base + i} 4) {v}u32) '
                          f'(bufset-u8 present {base + i} 1) '
                          for i, v in enumerate(stored))
            if part:
                put += (f"(setvar 'log_enable_{'a' if block == 0 else 'b'} 1) "
                        f"(setvar 'log_state_{'a' if block == 0 else 'b'} 'ok) "
                        f"(bufset-u32 log_{'a' if block == 0 else 'b'} "
                        f"(+ 8 (* 4 15)) {image[15]}) ")
                put += ''.join(f"(bufset-u32 log_{'a' if block == 0 else 'b'} "
                               f"(+ 8 (* 4 {i})) {v}u32) "
                               for i, v in enumerate(image))
            expected = ''.join(f'(bufset-u8 expected {32 * i + j} {byte}) '
                               for i, frame in enumerate(frames)
                               for j, byte in enumerate(frame))
            script = (f'(mock-setup) {put}(define s (log_snapshot {block} {part})) '
                      f'(log_send_snapshot {block} {part} 10 (ix s 0) (ix s 1)) '
                      f'(define expected (bufcreate 352)) {expected}'
                      '(define same (= frame_count 11)) '
                      '(looprange i 0 11 { '
                      f'(if (!= (bufget-u8 frame_lengths i) (if (= i 10) {len(frames[10])} 30)) '
                      "    (setvar 'same nil)) "
                      '(looprange j 0 (bufget-u8 frame_lengths i) '
                      '(if (!= (bufget-u8 frames (+ (* i 32) j)) '
                      '(bufget-u8 expected (+ (* i 32) j))) (setvar \'same nil))) '
                      '}) same')
            result = run(repl, script)
            assert result == 't', ('full byte vector', block, part, result)
    docs = (ROOT / 'DEVELOPMENT.md').read_text()
    a_raw = ast.literal_eval(re.search(r'^A_RAW = (\[[^]]+\])', docs, re.M | re.S).group(1))
    assert len(a_raw) == 63 and a_raw[1] == 748037813
    published = (
        (0, 0, ''.join(f'(bufset-u32 nv (* {64 + i} 4) {v}u32) '
                         f'(bufset-u8 present {64 + i} 1) '
                         for i, v in enumerate(a_raw)),
         ('B10000000B09000000062C9626B542544C47000001010000000C0000002F',
          'B100000A0B0002C20CE900630E1000018002')),
        (1, 1, '(log_initialise log_b 1) '
         + ''.join(f'(bufset-u32 log_b (+ 8 (* 4 {slot - 128})) {value}u32) '
                   for slot, value in ((128, 6), (129, 2019938442), (130, 1112820808),
                                       (131, 279), (132, 5), (133, 229376),
                                       (188, 363), (189, 7471954), (190, 52428800),
                                       (191, 0))),
         ('B10101000B09000000067865D08A42544C48000001170000000500038000',
          'B101010A0B000000016B007203520320000000000000')),
    )
    for block, part, setup, (first_hex, last_hex) in published:
        script = (f'(mock-setup) {setup} '
                  f"(setvar 'log_enable_{'a' if block == 0 else 'b'} 1) "
                  f'(define s (log_snapshot {block} {part})) '
                  f'(log_send_snapshot {block} {part} 10 (ix s 0) (ix s 1)) '
                  '(list frame_count (bufget-u8 frame_lengths 0) '
                  '(bufget-u8 frame_lengths 10) '
                  '(bufget-u8 frames 5))')
        assert run(repl, script) == f'(11 30 {18 if block == 0 else 22} 9)'
        # Compare every byte of the published first and last literal frames.
        for index, hex_frame in ((0, first_hex), (10, last_hex)):
            frame_bytes = bytes.fromhex(hex_frame)
            check = ''.join(f'(if (!= (mock-frame {index} {j}) {v}) '
                            "(setvar 'same nil)) " for j, v in enumerate(frame_bytes))
            result = run(repl, f'(mock-setup) {setup} '
                         f"(setvar 'log_enable_{'a' if block == 0 else 'b'} 1) "
                         f'(define s (log_snapshot {block} {part})) '
                         f'(log_send_snapshot {block} {part} 10 (ix s 0) (ix s 1)) '
                         f'(define same t) {check} same')
            assert result == 't', ('published frame', block, part, index, result)
    expect('B last frame and send error release busy',
           "(mock-setup) (define s (log_snapshot 1 0)) "
           "(log_send_snapshot 1 0 250 (ix s 0) (ix s 1)) "
           "(setvar 'fail_send 1) (setvar 'log_read_busy 1) "
           "(log_send_snapshot 1 0 0 (ix s 0) (ix s 1)) "
           "(list frame_count (mock-frame 10 3) (mock-frame 10 5) log_read_busy)",
           '(11 10 0 0)')
    expect('paced sender owns immutable live snapshot during owner mutation',
           "(mock-setup) (log_initialise log_a 1) "
           "(mock-set log_a 72 42) (define s (log_snapshot 0 1)) "
           "(setvar 'log_read_busy 1) (setvar 'mock_concurrent 1) "
           "(spawn 120 log_send_snapshot 0 1 10 (ix s 0) (ix s 1)) "
           "(mock-await-frames 1) (mock-set log_a 72 99) "
           "(mock-await-frames 11) "
           "(list (bufget-u32 frames (+ 32 14)) (mock-slot log_a 72) "
           "frame_count log_read_busy)", '(42u32 99u32 11 0)')
    for pace, length, expected in ((0, 3, '0.010000f32'),
                                    (0, 4, '0.010000f32'),
                                    (25, 4, '0.025000f32'),
                                    (255, 4, '0.250000f32')):
        expect(f'request pace {pace} length {length} in spawned sender',
               "(mock-setup) (setvar 'log_read_busy 1) (setvar 'mock_concurrent 1) "
               f"(log_operation '(161 0 0 {pace} {length} 0)) "
               "(loopwhile (< frame_count 2) (sleep 0.01)) "
               "(list frame_count pace_seen log_read_busy)", f'(2 {expected} 1)')
    allocation = run(repl, "(mock-setup) (setvar 'log_read_busy 1) "
                     "(define s (log_snapshot 0 0)) "
                     "(log_send_snapshot 0 0 10 (ix s 0) (ix s 1)) "
                     "(list log_read_busy frame_count)",
                     (('(bufcreate (+ 6 (* 4 count)))', '(mock-frame-create (+ 6 (* 4 count)))'),),
                     '(defun mock-frame-create (n) (car 1))')
    assert allocation == '(0 0)', ('frame allocation failure cleanup', allocation)
    snapshot_failure = run(repl, "(mock-setup) (setvar 'log_read_busy 1) "
                           "(log_operation '(161 0 0 0 3 0)) "
                           "(list log_read_busy frame_count)",
                           (('(var image (bufcreate (* 4 n)))',
                             '(var image (mock-image-create (* 4 n)))'),),
                           '(defun mock-image-create (n) (car 1))')
    assert snapshot_failure == '(0 0)', ('snapshot allocation failure cleanup', snapshot_failure)
    spawn_failure = run(repl, "(mock-setup) (setvar 'log_read_busy 1) "
                        "(log_operation '(161 0 0 0 3 0)) "
                        "(list log_read_busy frame_count)",
                        (('(spawn 120 log_send_snapshot', '(mock-spawn-fail 120 log_send_snapshot'),),
                        '(defun mock-spawn-fail (stack f block part ms image state) nil)')
    assert spawn_failure == '(0 0)', ('sender spawn failure cleanup', spawn_failure)
    expect('ack transport error releases write slot without success response',
           "(mock-setup) (setvar 'fail_send 1) (mock-request 163 0 1) "
           "(log_requests) (list log_write_busy frame_count log_state_a)",
           '(0 0 ok)')
    for block, slots, last_len in ((0, 63, 18), (1, 64, 22)):
        for part in (0, 1):
            expect(f'all chunk boundaries block {block} part {part}',
                   f"(mock-setup) (define s (log_snapshot {block} {part})) "
                   f"(log_send_snapshot {block} {part} 10 (ix s 0) (ix s 1)) "
                   "(define good t) "
                   "(looprange i 0 11 { "
                   "(if (or (!= (mock-frame i 0) 177) "
                   f"        (!= (mock-frame i 1) {block}) "
                   f"        (!= (mock-frame i 2) {part}) "
                   "        (!= (mock-frame i 3) i) (!= (mock-frame i 4) 11) "
                   "        (!= (bufget-u8 frame_lengths i) "
                   f"            (if (= i 10) {last_len} 30))) "
                   "    (setvar 'good nil)) "
                   "}) (list good frame_count)", '(t 11)')
    for request, expected in ((0, '0.010000f32'), (10, '0.010000f32'),
                              (85, '0.085000f32'), (250, '0.250000f32')):
        expect(f'pace {request} ms in sender',
               "(mock-setup) (define s (log_snapshot 0 0)) "
               f"(log_send_snapshot 0 0 {request or 10} (ix s 0) (ix s 1)) "
               'pace_seen', expected)
    expect('repeated read snapshots and sends reclaim native cons cells',
           "(mock-setup) (log_initialise log_a 1) "
           "(looprange k 0 3 { (setvar 'frame_count 0) "
           "(var s (log_snapshot 0 1)) "
           "(log_send_snapshot 0 1 10 (ix s 0) (ix s 1)) }) "
           "(gc) (define before_free (mem-num-free)) "
           "(looprange k 0 3 { (setvar 'frame_count 0) "
           "(var s (log_snapshot 0 1)) "
           "(log_send_snapshot 0 1 10 (ix s 0) (ix s 1)) }) "
           "(gc) (= before_free (mem-num-free))", 't')
    resources = run(repl,
           "(mock-setup) (log_initialise log_a 1) "
           "(setvar 'log_owner -1) (setvar 'mock_concurrent 1) (log_start) "
           "(define first_free 0) (define first_longest 0) "
           "(define first_cells 0) (define first_arrays 0) (define first_gc 0) "
           "(looprange outer 0 2 { "
           "(looprange i 0 3 { "
           "(setvar 'frame_count 0) (mock-request 161 0 0) "
           "(mock-await-frames 11) "
           "(loopwhile (= log_read_busy 1) (sleep 0.001)) "
           "(mock-request 163 0 0) (mock-await-frames 12) "
           "(mock-request 163 0 1) (mock-await-frames 13) "
           "(setvar 'mock_now (+ mock_now 250)) (send log_owner 'log-wake) "
           "(sleep 0.005) }) "
           "(gc) (if (= outer 0) { "
           "(setvar 'first_free (mem-num-free)) "
           "(setvar 'first_longest (mem-longest-free)) "
           "(setvar 'first_cells (lbm-heap-state 'get-num-alloc-cells)) "
           "(setvar 'first_arrays (lbm-heap-state 'get-num-alloc-arrays)) "
           "(setvar 'first_gc (lbm-heap-state 'get-gc-num)) "
           "}) }) (gc) "
           "(list first_free (mem-num-free) first_longest (mem-longest-free) "
           "first_cells (lbm-heap-state 'get-num-alloc-cells) "
           "first_arrays (lbm-heap-state 'get-num-alloc-arrays) "
           "first_gc (lbm-heap-state 'get-gc-num) "
           "(> sample_count 0) (= log_write_busy 0) (= log_read_busy 0))")
    numbers = [int(x) for x in re.findall(r'\d+', resources)]
    assert len(numbers) == 10 and resources.endswith('t t t)'), resources
    assert numbers[0] == numbers[1] and numbers[2] == numbers[3], resources
    # get-num-alloc-arrays is cumulative; it must increase when request frames
    # are allocated. The stable post-GC array-memory free space matters here.
    assert numbers[7] > numbers[6], resources
    assert numbers[9] > numbers[8], resources
    print('native protocol resource checkpoints:', resources)
