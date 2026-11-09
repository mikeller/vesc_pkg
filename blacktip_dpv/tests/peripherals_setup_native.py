"""Run the production peripheral setup in native LispBM with mocked hardware."""

import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def check(repl):
    source = (ROOT / 'blacktip_dpv.lisp').read_text()
    setup = source[source.index('(defun peripherals_setup'):
                   source.index('; Display LUT binary format helpers', source.index('(defun peripherals_setup'))]
    setup = setup.replace('(i2c-start ', '(mock-i2c-start ')
    setup = setup.replace('(i2c-tx-rx ', '(mock-i2c-tx-rx ')
    prefix = '''
(define hardware_configuration 5)
(define scooter_type 0)
(define disp_brightness 3)
(define BRIGHTNESS_LUT (list 224 227 230 233 236 239))
(define pin_init_count 0)
(define tx_count 0)
(define correct_pins 0)
(define first_tx_init_count -1)
(defun mock-i2c-start (rate sda scl) {
  (setvar 'pin_init_count (+ pin_init_count 1))
  (setvar 'correct_pins (if (and (eq sda 'pin-rx) (eq scl 'pin-tx)) 1 0))})
(defun mock-i2c-tx-rx (address data) {
  (if (= tx_count 0) (setvar 'first_tx_init_count pin_init_count) nil)
  (setvar 'tx_count (+ tx_count 1))})
(defun clamp (value low high) (if (< value low) low (if (> value high) high value)))
(defun ix (items index) (ix items index))
'''
    # Production ix is a built-in, so leave it available rather than shadowing it.
    prefix = prefix.replace("(defun ix (items index) (ix items index))\n", "")
    with tempfile.TemporaryDirectory() as directory:
        script = Path(directory) / 'config5.lisp'
        script.write_text(prefix + setup + '\n(peripherals_setup)\n'
                          '(list pin_init_count tx_count correct_pins first_tx_init_count)\n')
        result = subprocess.run([repl, '-H', '10000', '-M', '262144', '-C', '262144',
                                 '--bldc_stubs', '--terminate', '-s', str(script)],
                                capture_output=True, text=True, timeout=30)
    values = [line[2:] for line in result.stdout.splitlines() if line.startswith('> ')]
    output = result.stdout + result.stderr
    assert result.returncode == 0 and values, output
    assert not any(error in output for error in ('eval_error', 'out_of_memory', 'out_of_stack')), output
    assert values[-1] == '(1 3 1 1)', values[-1]
