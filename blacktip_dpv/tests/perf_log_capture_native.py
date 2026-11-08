"""Execute the production RAM snapshot protocol in the native LispBM REPL."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(repl):
    app = (ROOT / 'blacktip_dpv.lisp').read_text()
    production = app[app.index('(defun log_reply'):app.index('; Init-only peripheral setup.')]
    production = production.replace('(send-data ', '(mock-send-data ')
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
(define last_reply nil) (define reply_count 0)
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

    owner = production[production.index('(defun log_owner_inner'):]
    assert "(setvar 'log_live (bufcreate 320))" in owner
    assert "(setvar 'log_snapshot_valid 0)" in owner
    assert '(log_sample)' in owner and 'LOG_SAMPLE_PERIOD' in owner
    assert 'eeprom-' not in production and 'conf-store' not in production
    print('production owner source: fresh buffers, periodic sampling, zero persistence calls')
