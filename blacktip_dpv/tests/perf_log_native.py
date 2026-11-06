"""Exercise the real RAM collector in the 7.00 native LispBM REPL.

Only the external telemetry getters and elapsed-time source are replaced. The
collector, its tables, buffer layout and rule engine are loaded from the source.
This is a simulation, not a substitute for measuring a controller's stack or
heap. Run with LBM_REPL pointing to a native REPL built from release_7_00.
"""

import re
import subprocess
import tempfile
from pathlib import Path


GETTERS = ('rpm', 'rpm-set', 'current-in', 'ah', 'wh', 'fault',
           'temp-fet', 'temp-mot', 'current', 'vin', 'duty')
ROOT = Path(__file__).resolve().parents[1]


def source_with_mocks():
    source = (ROOT / 'blacktip_dpv.lisp').read_text()
    source = source[:source.index('(init)\n\n(progn')]
    source = source.replace('(import "generated/display_lut.bin" \'display_lut_bin)',
                            '(define display_lut_bin (bufcreate 1))')
    start = source.index('(defun log_sample ()')
    end = source.index('; Hook in safe_start_abort_with_reason', start)
    sample = source[start:end]
    for name in GETTERS:
        old = '(get-' + name + ')'
        assert old in sample
        sample = sample.replace(old, '(mock-get-' + name + ')')
    assert '(secs-since (bufget-u32 st 0))' in sample
    sample = sample.replace('(secs-since (bufget-u32 st 0))', '(mock-dt)')
    source = source[:start] + sample + source[end:]
    mocks = '''(define mock_values (bufcreate 44))
(define mock_elapsed 0.2)
(defun mock-dt () mock_elapsed)
(defun mock-read (i) {
    (var n (bufget-f32 mock_values (* i 4)))
    (if (= n -123456) nil (if (= n -123457) (car 1) n))
})
'''
    for index, name in enumerate(GETTERS):
        mocks += f'(defun mock-get-{name} () (mock-read {index}))\n'
    mocks += '''(defun mock-put (i v) (bufset-f32 mock_values (* i 4) v))
(defun mock-slot (slot) (bufget-u32 log_a (+ 8 (* 4 (- slot LOG_A_BASE)))))
(defun mock-setup () {
    (setvar 'log_a (log_blk_new LOG_A_BASE LOG_A_SLOTS))
    (log_apply log_a LOG_A_INIT)
    (setvar 'log_st (bufcreate 108))
    (bufset-f32 log_st 40 1)
    (setvar 'soft_start_active 0)
    (setvar 'speed SPEED_OFF)
    (mock-put 0 2950) (mock-put 1 3000) (mock-put 2 14)
    (mock-put 3 0) (mock-put 4 0) (mock-put 5 0)
    (mock-put 6 41.2) (mock-put 7 30) (mock-put 8 24)
    (mock-put 9 35.1) (mock-put 10 0.96)
})
'''
    return '(define event-enable (lambda (x) t))\n' + source + mocks


def run(repl, scenario, *, heap=2753):
    with tempfile.TemporaryDirectory() as work:
        script = Path(work) / 'sample.lisp'
        script.write_text(source_with_mocks() + '\n' + scenario + '\n')
        proc = subprocess.run([repl, '-H', str(heap), '-M', '262144', '-C', '262144',
                               '--bldc_stubs', '--terminate', '-s', str(script)],
                              capture_output=True, text=True, timeout=60)
    # The final REPL value, not a Python port of the accumulator, is the result.
    lines = [line[2:] for line in proc.stdout.splitlines() if line.startswith('> ')]
    if proc.returncode or not lines or 'exit-error' in lines[-1] or \
            'out_of_stack' in proc.stdout or 'out_of_memory' in proc.stdout:
        raise AssertionError(f'native collector failed: {proc.returncode}\n{proc.stdout}\n{proc.stderr}')
    return lines[-1]


def integer_values(value):
    """Extract the u32/i32 slot values from a LispBM list result."""
    return [int(n) for n in re.findall(r'(?<![\w.])-?\d+(?=u32\b|i32\b)', value)]
