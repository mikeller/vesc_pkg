"""Native LispBM protocol checks with EEPROM, transport and motor mocked."""

import subprocess
import tempfile
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
(defun mock-send-data (b) {
    (if (= fail_send 1) (car 1))
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


def run(repl, script):
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
    text += MOCKS + receiver + script
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'protocol.lisp'
        path.write_text(text)
        result = subprocess.run([repl, '-H', '2753', '-M', '262144', '-C', '262144',
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
    expect('B tag accepts zero and maximum, rejects overflow',
           "(mock-setup) (log_operation '(163 1 1 0 3 1)) "
           "(log_operation '(164 1 255 0 3 127)) "
           "(define hi (mock-slot log_b 133)) "
           "(log_operation '(164 1 0 0 3 128)) "
           "(list hi (mock-slot log_b 133) (mock-frame 2 2) (mock-frame 2 3))",
           '(1073709056u32 1073709056u32 3 1)')
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
    expect('shutdown retires pending write without a delayed store',
           "(mock-setup) (mock-request 163 0 1) (log_shutdown_flush) "
           "(log_requests) (list writes log_shutdown_state log_write_busy "
           "log_write_request frame_count)", '(0 3 0 nil 0)')
    expect('lengths two, four and eight and settings-sized opcode rejected',
           "(mock-setup) (loopforeach n '(2 4 8 33) { "
           "(setvar 'log_write_busy 0) (setvar 'log_write_request nil) "
           "(mock-receive n 162) (log_requests) }) "
           "(list frame_count (mock-frame 0 2) (mock-frame 3 2) "
           "settings_writes writes)", '(4 3 3 0 0)')
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
           "(log_start) (define owner log_owner) "
           "(mock-request 163 0 1) (mock-await-frames 1) "
           "(mock-request 163 0 0) (mock-await-frames 2) "
           "(mock-request 163 0 1) (mock-await-frames 3) "
           "(list (= owner log_owner) frame_count log_enable_a log_state_a writes)",
           '(t 3 1 ok 72)')
    expect('timed native owner samples despite protocol wake traffic',
           "(setvar 'log_owner -1) (setvar 'log_enable_a 1) "
           "(setvar 'log_a (log_blk_new 64 63)) "
           "(setvar 'log_st nil) (log_start) "
           "(looprange i 0 8 { (send log_owner 'log-wake) (sleep 0.005) }) "
           "(setvar 'mock_now (+ mock_now 250)) "
           "(send log_owner 'log-wake) (sleep 0.05) "
           "(list (= sample_count 1) (= log_owner -1))", '(t nil)')
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
    expect('sender has all eleven chunks and exact last frame',
           "(mock-setup) (define s (log_snapshot 0 0)) "
           "(log_send_snapshot 0 0 10 (ix s 0) (ix s 1)) "
           "(list frame_count (mock-frame 0 0) (mock-frame 0 4) "
           "(mock-frame 10 3) (mock-frame 10 5) log_read_busy)",
           '(11 177 11 10 0 0)')
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
    expect('request pace 255 clamps to 250 in spawned sender',
           "(mock-setup) (setvar 'log_read_busy 1) (setvar 'mock_concurrent 1) "
           "(log_operation '(161 0 0 255 4 0)) "
           "(loopwhile (< frame_count 2) (sleep 0.01)) "
           "(list frame_count pace_seen log_read_busy)", '(2 0.250000f32 1)')
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
