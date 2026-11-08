"""Execute the production RAM snapshot protocol in the native LispBM REPL."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(repl):
    app = (ROOT / 'blacktip_dpv.lisp').read_text()
    production = app[app.index('(defun log_reply'):app.index('; Init-only peripheral setup.')]
    production = production.replace('(send-data ', '(mock-send-data ')
    production = production.replace('(systime)', '(mock-systime)')
    production = production.replace('(eeprom-store-i ', '(mock-eeprom-store-i ')
    production = production.replace('(secs-since deadline)', '(mock-secs-since deadline)')
    production = production.replace('(loopwhile t {',
        '(loopwhile (< mock_owner_ticks 4) { (setvar \'mock_owner_ticks (+ mock_owner_ticks 1)) '
        '(if (= mock_owner_ticks 3) (setvar \'speed 0))', 1)
    for getter in ('rpm', 'rpm-set', 'current-in', 'current', 'vin', 'duty'):
        production = production.replace('(get-' + getter + ')', '(mock-get-' + getter + ')')
    prefix = '''
(define LOG_PREFIX 177) (define LOG_VERSION 1)
(define LOG_MAX_COUNT 4294967294u32) (define SPEED_OFF 99)
(define LOG_SAMPLE_PERIOD 0.2) (define THREAD_STACK_LOG 160)
(define log_live nil) (define log_snapshot_buf nil)
(define log_snapshot_valid 0) (define log_snapshot_fault 0)
(define log_fault 0) (define log_snapshot_token 0)
(define log_previous_speed SPEED_OFF) (define log_previous_eligible 0)
(define log_owner -1) (define log_request nil) (define log_busy 0)
(define speed SPEED_OFF) (define soft_start_active 0)
(define safe_start_status 'idle)
(define mock_owner_ticks 0) (define mock_duty 0.4) (define mock_getter_failure 0)
(define mock_current_in 2.0) (define mock_rpm 100.0) (define mock_voltage 30.0)
(define mock_nonfinite 0) (define mock_nonfinite_buf (bufcreate 4))
(define last_reply nil) (define reply_count 0)
(define mock_store_count 0) (define eeprom_shadow (bufcreate 1024))
(defun mock-eeprom-store-i (addr value) {
    (setvar 'mock_store_count (+ mock_store_count 1))
    (bufset-u32 eeprom_shadow (* addr 4) value) t
})
(defun mock-systime () 0)
(defun mock-secs-since (start) 0.2)
(defun mock-get-rpm () mock_rpm) (defun mock-get-rpm-set () 120.0)
(defun mock-get-current-in ()
    (if (= mock_getter_failure 1) (car 1)
        (if (= mock_nonfinite 1) (bufget-f32 mock_nonfinite_buf 0) mock_current_in)))
(defun mock-get-current () 3.0)
(defun mock-get-vin () mock_voltage) (defun mock-get-duty () mock_duty)
(defun mock-send-data (b) {
    (setvar 'last_reply b) (setvar 'reply_count (+ reply_count 1)) t
})
'''

    def run(script):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'capture.lisp'
            path.write_text(prefix + production + '\n' + script)
            result = subprocess.run(
                [repl, '-H', '2753', '-M', '262144', '-C', '262144',
                 '--bldc_stubs', '--terminate', '-s', str(path)],
                capture_output=True, text=True, timeout=30)
        values = [line[2:] for line in result.stdout.splitlines()
                  if line.startswith('> ')]
        assert result.returncode == 0 and values, result.stdout + result.stderr
        assert not any(error in values[-1] for error in
                       ('eval_error', 'out_of_memory', 'out_of_stack')), \
            result.stdout + result.stderr
        return values[-1]

    result = run('''
(setvar 'log_live (bufcreate 320))
(setvar 'log_snapshot_buf (bufcreate 320))
(bufset-u32 log_live 0 3) (bufset-f32 log_live 4 12.5)
(setvar 'log_fault 1)
(log_serve '(2 7 42 255))
(bufset-u32 log_live 0 99) (bufset-f32 log_live 4 99.0)
(setvar 'log_fault 0)
(log_serve '(3 8 42 0))
(list reply_count (bufget-u8 last_reply 9) (bufget-u8 last_reply 10)
      (bufget-u8 last_reply 11) (bufget-u32 last_reply 12)
      (bufget-f32 last_reply 16))
''')
    assert result == '(2 0 0 1 3u32 12.500000f32)', result
    print('native production snapshot protocol: immutable rows and captured fault:', result)

    result = run('''
(setvar 'log_live (bufcreate 320))
(setvar 'log_snapshot_buf (bufcreate 320))
(log_serve '(3 9 99 0))
(list reply_count (bufget-u8 last_reply 9) (bufget-u8 last_reply 11))
''')
    assert result == '(1 3 0)', result
    print('native production snapshot protocol: mismatched token rejected:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 5) (setvar 'log_previous_eligible 1) (setvar 'speed 5)
(log_sample)
(list (bufget-u32 log_live 160) (bufget-f32 log_live 164)
      (bufget-f32 log_live 172) (bufget-u32 log_live 188))
''')
    assert result == '(1u32 100.000000f32 60.000000f32 0u32)', result
    print('native production sampler: stable forward sample:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 0) (setvar 'log_previous_eligible 1) (setvar 'speed 0)
(log_sample)
(list (bufget-u32 log_live 0) (bufget-f32 log_live 4)
      (bufget-f32 log_live 12) (bufget-u32 log_live 28))
''')
    assert result == '(1u32 100.000000f32 60.000000f32 0u32)', result
    print('native production sampler: reverse speed index:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 5) (setvar 'log_previous_eligible 1) (setvar 'speed 5)
(setvar 'mock_duty 2.0) (log_sample)
(list (bufget-u32 log_live 160) (bufget-u32 log_live 188) log_fault)
''')
    assert result == '(0u32 1u32 0)', result
    print('native production sampler: invalid duty rejected:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 5) (setvar 'log_previous_eligible 1) (setvar 'speed 5)
(setvar 'mock_getter_failure 1) (log_sample)
(list (bufget-u32 log_live 160) (bufget-u32 log_live 188) log_fault)
''')
    assert result == '(0u32 1u32 0)', result
    print('native production sampler: trapped getter failure rejected:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 5) (setvar 'log_previous_eligible 1) (setvar 'speed 5)
(setvar 'mock_current_in nil) (log_sample)
(list (bufget-u32 log_live 160) (bufget-u32 log_live 188) log_fault)
''')
    assert result == '(0u32 1u32 0)', result
    print('native production sampler: nil telemetry is rejected:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 5) (setvar 'log_previous_eligible 1) (setvar 'speed 5)
(bufset-u32 mock_nonfinite_buf 0 2139095040u32) (setvar 'mock_nonfinite 1) (log_sample)
(list (bufget-u32 log_live 160) (bufget-u32 log_live 188) log_fault)
''')
    assert result == '(0u32 1u32 0)', result
    print('native production sampler: non-finite telemetry is rejected:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 5) (setvar 'log_previous_eligible 1) (setvar 'speed 5)
(setvar 'mock_current_in -2.0) (log_sample)
(list (bufget-u32 log_live 160) (bufget-f32 log_live 168)
      (bufget-f32 log_live 172) log_fault)
''')
    assert result == '(1u32 -2.000000f32 -60.000000f32 0)', result
    print('native production sampler: signed current and power retained:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_fault 0)
(setvar 'log_previous_speed 5) (setvar 'log_previous_eligible 1) (setvar 'speed 5)
(bufset-u32 log_live 160 LOG_MAX_COUNT) (log_sample)
(setvar 'mock_rpm 200.0) (log_sample)
(list (bufget-u32 log_live 160) log_fault (bufget-u32 log_live 188))
''')
    assert result == '(4294967294u32 1 0u32)', result
    print('native production sampler: exhausted row freezes subsequent samples:', result)

    result = run('''
(setvar 'speed 5)
(looprange i 64 191 (bufset-u32 eeprom_shadow (* i 4) (+ i 12345)))
(define seeded (bufcreate 1024))
(looprange i 0 1024 (bufset-u8 seeded i (bufget-u8 eeprom_shadow i)))
(spawn THREAD_STACK_LOG log_owner_loop) (sleep 0.05)
(define same t)
(looprange i 0 1024 (if (!= (bufget-u8 seeded i) (bufget-u8 eeprom_shadow i))
    (setvar 'same nil)))
(list (= mock_owner_ticks 4) (= log_owner -1)
      (bufget-u32 log_live 160) (bufget-u32 log_live 0) (= log_fault 1)
      same mock_store_count)
''')
    assert result == '(t t 1u32 1u32 t t 0)', result
    print('native production spawned owner: transitions, seeded EEPROM unchanged, zero stores:', result)

    result = run('''
(setvar 'log_live (bufcreate 320)) (setvar 'log_snapshot_buf (bufcreate 320))
(looprange pass 0 4 {
    (setvar 'log_snapshot_valid 0)
    (log_serve (list 2 pass pass 255))
    (looprange row 0 10 (log_serve (list 3 pass pass row)))
})
(gc) (define free1 (mem-num-free)) (define span1 (mem-longest-free))
(looprange pass 0 4 {
    (setvar 'log_snapshot_valid 0)
    (log_serve (list 2 pass pass 255))
    (looprange row 0 10 (log_serve (list 3 pass pass row)))
})
(gc) (list (= free1 (mem-num-free)) (= span1 (mem-longest-free)))
''')
    assert result == '(t t)', result
    print('native production protocol: repeated downloads reclaim bounded heap:', result)

    receiver = app[app.index('(defun receive_data (data)'):app.index('; Setup functions')]
    receiver = receiver.replace('(eeprom_store_i_if_changed ', '(mock-store-i ')
    demux_prefix = '''
(define HANDSHAKE_CODE 255) (define LOG_PREFIX 177)
(define EEPROM_SETTINGS_COUNT 33) (define writes 0) (define admitted 0)
(define handshake 0) (define updated 0)
(defun mock-store-i (i v) (setvar 'writes (+ writes 1)))
(defun log_admit (data) (setvar 'admitted (+ admitted 1)))
(defun send_current_settings () (setvar 'handshake (+ handshake 1)))
(defun update_settings_from_eeprom () (setvar 'updated (+ updated 1)))
(defun debug_log_format (x) nil) (defun debug_log (x) nil)
'''
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'receive.lisp'
        path.write_text(demux_prefix + receiver + '''
(define malformed (bufcreate 1)) (bufset-u8 malformed 0 177) (receive_data malformed)
(define malformed_settings_sized_log (bufcreate 33))
(bufset-u8 malformed_settings_sized_log 0 177) (receive_data malformed_settings_sized_log)
(looprange op 161 165 { (define old (bufcreate 33)) (bufset-u8 old 0 op) (receive_data old) })
(define short_other (bufcreate 8)) (bufset-u8 short_other 0 20) (receive_data short_other)
(define settings (bufcreate 33)) (bufset-u8 settings 0 20) (receive_data settings)
(define hello (bufcreate 1)) (bufset-u8 hello 0 255) (receive_data hello)
(list admitted writes updated handshake)
''')
        result_native = subprocess.run(
            [repl, '-H', '2753', '-M', '262144', '-C', '262144',
             '--bldc_stubs', '--terminate', '-s', str(path)],
            capture_output=True, text=True, timeout=30)
    values = [line[2:] for line in result_native.stdout.splitlines() if line.startswith('> ')]
    assert result_native.returncode == 0 and values, result_native.stdout + result_native.stderr
    assert values[-1] == '(2 33 1 1)', values[-1]
    print('native production receive demux: malformed log, obsolete opcodes, settings, handshake:', values[-1])

    owner = production[production.index('(defun log_owner_inner'):]
    assert "(setvar 'log_live (bufcreate 320))" in owner
    assert "(setvar 'log_snapshot_valid 0)" in owner
    assert '(log_sample)' in owner and 'LOG_SAMPLE_PERIOD' in owner
    assert 'eeprom-' not in production and 'conf-store' not in production
    print('production owner source: fresh buffers, periodic sampling, zero persistence calls')
