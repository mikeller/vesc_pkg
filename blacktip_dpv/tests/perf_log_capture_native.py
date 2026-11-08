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
(define last_reply nil) (define reply_count 0)
(defun mock-systime () 0)
(defun mock-secs-since (start) 0.2)
(defun mock-get-rpm () 100.0) (defun mock-get-rpm-set () 120.0)
(defun mock-get-current-in () (if (= mock_getter_failure 1) (car 1) 2.0))
(defun mock-get-current () 3.0)
(defun mock-get-vin () 30.0) (defun mock-get-duty () mock_duty)
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
(setvar 'speed 5) (spawn THREAD_STACK_LOG log_owner_loop) (sleep 0.05)
(list (= mock_owner_ticks 4) (= log_owner -1)
      (bufget-u32 log_live 160) (bufget-u32 log_live 0) (= log_fault 1))
''')
    assert result == '(t t 1u32 1u32 t)', result
    print('native production spawned owner: forward/reverse transition and cleanup:', result)

    owner = production[production.index('(defun log_owner_inner'):]
    assert "(setvar 'log_live (bufcreate 320))" in owner
    assert "(setvar 'log_snapshot_valid 0)" in owner
    assert '(log_sample)' in owner and 'LOG_SAMPLE_PERIOD' in owner
    assert 'eeprom-' not in production and 'conf-store' not in production
    print('production owner source: fresh buffers, periodic sampling, zero persistence calls')
