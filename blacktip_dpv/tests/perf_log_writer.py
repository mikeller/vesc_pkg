"""Exercise the production LispBM EEPROM writer in the native 7.00 REPL.

Only hardware primitives are replaced. This is a software simulation, not a
measurement of flash latency, shutdown scheduling or controller heap use.
"""

import re
import subprocess
import tempfile
from pathlib import Path

from perf_log_boot import crc


ROOT = Path(__file__).resolve().parents[1]


def source():
    text = (ROOT / 'blacktip_dpv.lisp').read_text()
    section = text[text.index('(defun clamp ('):text.index('(defun speed_percentage_at')]
    section += text[text.index('(defun log_blk_new'):text.index('; Unlike the generic fractional')]
    section += text[text.index('(defun log_b_set_tag'):text.index('(defun log_b_ring_begin')]
    section += text[text.index('(defun log_rest_ok'):text.index('; Init-only peripheral setup.')]
    for old, new in (('(eeprom-read-i ', '(mock-eeprom-read '),
                     ('(eeprom-store-i ', '(mock-eeprom-store '),
                     ('(get-rpm)', '(mock-rpm)'), ('(get-duty)', '(mock-duty)'),
                     ("(gpio-read 'pin-ppm)", '(mock-pin)'),
                     ('(systime)', '(mock-systime)'), ('(secs-since ', '(mock-secs-since '),
                     ('(sleep ', '(mock-sleep '), ('(crc32 ', '(mock-crc32 ')):
        section = section.replace(old, new)
    return '''(define SPEED_OFF 99) (define LOG_A_BASE 64) (define LOG_A_SLOTS 63)
(define LOG_B_BASE 128) (define LOG_B_SLOTS 64)
(define LOG_SETTLE_S 5.0) (define LOG_MIN_FLUSH_INTERVAL_S 60.0)
(define LOG_STORE_YIELD_MS 1) (define LOG_REST_ERPM_MAX 25.0)
(define LOG_REST_DUTY_MAX 0.02) (define LOG_FET_REF 850)
(define LOG_A_INIT '((66 1112820807) (67 257) (77 32767) (124 32767)))
(define LOG_B_INIT '((130 1112820808) (131 273) (135 1073741824)
 (137 1073741824) (139 1073741824) (141 1073741824) (143 1073741824)
 (145 1073741824) (147 1073741824) (149 1073741824) (171 32767)
 (176 32767) (181 32767) (186 32767)))
(define log_a nil) (define log_b nil) (define log_bs nil)
(define log_enable_a 0) (define log_enable_b 0)
(define log_state_a 'empty) (define log_state_b 'empty)
(define log_st nil) (define log_fet_edges nil)
(define log_rest_since 0) (define log_last_flush 0) (define log_flush_seen 0)
(define log_flush_stores 0) (define log_flush_count 0)
(define log_flush_aborts 0) (define log_flush_largest 0)
(define log_shutdown_request 0) (define log_shutdown_active 0)
(define log_shutdown_cancelled 0)
(define speed SPEED_OFF) (define startup_tune_active 0)
(define scooter_type 0) (define SCOOTER_CUDAX 1)
(define MAX_CURRENT_BLACKTIP 22.8) (define MAX_CURRENT_CUDAX 46)
(define battery_imbalance_threshold_centi 0)
(define nv (bufcreate 1024)) (define present (bufcreate 256))
(define trace (bufcreate 1024)) (define writes 0)
(define fail_write -1) (define false_write -1) (define fail_read -1)
(define fail_read_after_write -1) (define fail_read_after_count -1)
(define press_write -1) (define cancel_write -1) (define mock_pressed 0)
(define mock_rpm_value 0.0) (define mock_duty_value 0.0)
(define mock_now 10000) (define mock_sleep_calls 0)
(defun mock-rpm () mock_rpm_value)
(defun mock-duty () mock_duty_value)
(defun mock-pin () mock_pressed)
(defun mock-systime () mock_now)
(defun mock-secs-since (start) (/ (- mock_now start) 1000.0))
(defun mock-sleep (s) (setvar 'mock_sleep_calls (+ mock_sleep_calls 1)))
(defun mock-eeprom-read (addr) {
    (if (or (= addr fail_read)
            (and (= addr fail_read_after_write) (= writes fail_read_after_count)))
        (car 1))
    (if (or (< addr 64) (and (> addr 126) (< addr 128)) (> addr 191)) (car 1))
    (if (= (bufget-u8 present addr) 0) nil (bufget-u32 nv (* addr 4)))
})
(defun mock-eeprom-store (addr val) {
    (if (or (< addr 64) (and (> addr 126) (< addr 128)) (> addr 191)) (car 1))
    (setvar 'writes (+ writes 1))
    (bufset-u8 trace (- writes 1) addr)
    (if (= writes press_write) (setvar 'mock_pressed 1))
    (if (= writes cancel_write) (setvar 'log_shutdown_request 0))
    (if (= writes fail_write) nil
        (if (= writes false_write) t {
            (bufset-u32 nv (* addr 4) val)
            (bufset-u8 present addr 1)
            t
        }))
})
(defun mock-crc32 (b init) {
    (var c (bitwise-xor init 0xFFFFFFFFu32))
    (looprange i 0 (buflen b) {
        (setq c (bitwise-xor c (bufget-u8 b i)))
        (looprange j 0 8
            (setq c (if (= (bitwise-and c 1) 1)
                (bitwise-xor (shr c 1) 0xEDB88320u32) (shr c 1))))
    })
    (bitwise-xor c 0xFFFFFFFFu32)
})
(defun log_motor_reference () (list 1600 2))
(defun log_get (r) (if (and (eq (ix r 0) 'exit-ok) (number? (ix r 1))) (ix r 1) nil))
(defun mock-setup () {
    (setvar 'log_a (log_blk_new 64 63))
    (log_apply log_a LOG_A_INIT)
    (setvar 'log_b (log_blk_new 128 64))
    (log_apply log_b LOG_B_INIT)
    (setvar 'log_bs (bufcreate 20))
    (setvar 'log_st (bufcreate 108))
    (setvar 'log_rest_since 1000)
})
(defun mock-slot (b slot) (bufget-u32 b (+ 8 (* 4 (- slot (bufget-u32 b 0))))))
(defun mock-set (b slot val) {
    (bufset-u32 b (+ 8 (* 4 (- slot (bufget-u32 b 0)))) val)
    (bufset-u32 b 4 1)
})
@const-start
''' + section + '\n@const-end\n'


def run(repl, script):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'writer.lisp'
        path.write_text(source() + '\n' + script + '\n')
        result = subprocess.run([repl, '-H', '2753', '-M', '262144', '-C', '262144',
                                 '--bldc_stubs', '--terminate', '-s', str(path)],
                                text=True, capture_output=True, timeout=45)
    lines = [line[2:] for line in result.stdout.splitlines() if line.startswith('> ')]
    if result.returncode or not lines or any(x in result.stdout for x in
             ('fatal_error', 'out_of_memory', 'out_of_stack')):
        raise AssertionError(result.stdout + result.stderr)
    if 'exit-error' in lines[-1]:
        raise AssertionError(result.stdout + result.stderr)
    return lines[-1]


def ints(result):
    return [int(x) for x in re.findall(r'(?<![\w.])-?\d+(?=u32\b|i32\b|[\s)])', result)]


def check(repl):
    def actual(script):
        return run(repl, '(mock-setup) ' + script)

    def expect(name, script, value):
        result = actual(script)
        assert result == value, (name, result, value)

    expect('no dirty, multi-hour idle',
           '(log_initialise log_a 1) (setvar \'mock_now 90000000) '
           '(list (log_flush_once nil) writes log_flush_count)', '(nil 64 0)')
    expect('five-click gate waives only timing',
           '(log_initialise log_a 1) (mock-set log_a 72 12) '
           '(setvar \'log_rest_since 0) '
           '(list (log_gate nil) (log_gate t) '
           ' (progn (setvar \'startup_tune_active 1) (log_gate t)) '
           ' (progn (setvar \'startup_tune_active 0) (setvar \'mock_pressed 1) (log_gate t)) '
           ' (progn (setvar \'mock_pressed 0) (setvar \'mock_rpm_value 25) (log_gate t)) '
           ' (progn (setvar \'mock_rpm_value 0) (setvar \'mock_duty_value 0.02) (log_gate t)) '
           ' (progn (setvar \'mock_duty_value 0) (setvar \'speed 3) (log_gate t)))',
           '(nil t nil nil nil nil nil)')
    expect('strict settle and interval',
           '(log_initialise log_a 1) (mock-set log_a 72 12) '
           '(setvar \'mock_now 5999) (define short (log_gate nil)) '
           '(setvar \'mock_now 6000) (define ready (log_gate nil)) '
           '(setvar \'log_flush_seen 1) (setvar \'log_last_flush 6000) '
           '(list short ready (log_gate nil) '
           ' (progn (setvar \'mock_now 66000) (log_gate nil)))',
           '(nil t nil t)')
    expect('tag alone dirty, independent B commit',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(log_b_set_tag 17) '
           '(list (bufget-u32 log_a 4) (bufget-u32 log_b 4) '
           ' (log_flush_once nil) (mock-eeprom-read 133) '
           ' (log_boot_block 128 64 1112820808) log_flush_stores)',
           '(0u32 1u32 t 557056u32 ok 4)')
    expect('advisory duration is zeroed on the next real flush',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(mock-set log_a 126 98304) (mock-set log_b 133 32768) '
           '(list (log_flush_once nil) (mock-eeprom-read 126) '
           ' (log_boot_block 64 63 1112820807))',
           '(t 0u32 ok)')
    expect('both blocks ordered and verify after boot',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(mock-set log_a 72 12) (log_b_set_tag 17) '
           '(define start writes) (log_flush_once nil) '
           '(list (bufget-u8 trace start) (bufget-u8 trace (+ start 4)) '
           ' (mock-eeprom-read 64) (mock-eeprom-read 128) '
           ' (log_boot_block 64 63 1112820807) '
           ' (log_boot_block 128 64 1112820808) '
           ' log_flush_stores log_flush_largest log_flush_count)',
           '(64 128 4u32 4u32 ok ok 8 8 1)')
    image_text = actual('(log_initialise log_a 1) (mock-set log_a 72 12) '
                        '(log_flush_once nil) (define out nil) '
                        '(looprange i 2 63 (setvar \'out (cons (mock-eeprom-read (+ 64 i)) out))) '
                        '(cons (mock-eeprom-read 65) (reverse out))')
    # Verify native slot-image CRC against an independent Python big-endian
    # implementation and test that the header is not CRC-covered.
    numbers = ints(image_text)
    assert len(numbers) == 62, ('CRC export', image_text)
    image = {64 + i: n for i, n in enumerate(numbers[1:], start=2)}
    assert numbers[0] == crc(image, 64, 63), ('CRC byte order', numbers[0])
    for offset, state in ((1, 'ok'), (2, 'in_progress'),
                          (3, 'in_progress'), (4, 'in_progress')):
        result = actual('(log_initialise log_a 1) (log_initialise log_b 1) '
                        '(mock-set log_a 72 12) (mock-set log_b 133 32768) '
                        f'(setvar \'fail_write (+ writes {offset})) '
                        '(define fail (log_flush_once nil)) '
                        '(define owned log_a) '
                        '(define stage (log_boot_block 64 63 1112820807)) '
                        '(setvar \'log_a owned) '
                        '(setvar \'fail_write -1) (setvar \'mock_now 80000) '
                        '(define retry (log_flush_once nil)) '
                        '(list fail stage retry (log_boot_block 64 63 1112820807) '
                        ' (log_boot_block 128 64 1112820808) '
                        ' (mock-eeprom-read 72) (mock-eeprom-read 133))')
        assert result == f'(nil {state} t ok ok 12u32 32768u32)', (offset, result)
    for field in ('false_write', 'fail_read'):
        result = actual('(log_initialise log_a 1) (mock-set log_a 72 12) '
                        f'(setvar \'{field} ' +
                        ('(+ writes 2)' if field == 'false_write' else '72') + ') '
                        '(list (log_flush_once nil) (bufget-u32 log_a 4) '
                        ' (mock-eeprom-read 64))')
        assert result.startswith('(nil '), (field, result)
    expect('readback error after successful data write aborts and retries',
           '(log_initialise log_a 1) (mock-set log_a 72 12) '
           '(setvar \'fail_read_after_write 72) '
           '(setvar \'fail_read_after_count (+ writes 2)) '
           '(define refused (log_flush_once nil)) '
           '(setvar \'fail_read_after_write -1) '
           '(list refused (log_boot_block 64 63 1112820807) '
           ' (log_flush_once nil) (log_boot_block 64 63 1112820807))',
           '(nil in_progress t ok)')
    expect('trigger interrupts before next store; retry A, then B',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(mock-set log_a 72 12) (mock-set log_b 133 32768) '
           '(setvar \'press_write (+ writes 1)) '
           '(define attempt (log_flush_once nil)) '
           '(define interrupted (log_boot_block 64 63 1112820807)) '
           '(define still_b (mock-eeprom-read 128)) '
           '(setvar \'mock_pressed 0) (setvar \'mock_now 80000) '
           '(list attempt interrupted still_b (log_flush_once nil) '
           ' (log_boot_block 64 63 1112820807) '
           ' (log_boot_block 128 64 1112820808))',
           '(nil in_progress 2u32 t ok ok)')
    expect('A commits independently when B aborts; next attempt waits interval',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(mock-set log_a 72 12) (mock-set log_b 133 32768) '
           '(setvar \'press_write (+ writes 5)) '
           '(define attempt (log_flush_once nil)) '
           '(define a_state (log_boot_block 64 63 1112820807)) '
           '(define b_state (log_boot_block 128 64 1112820808)) '
           '(setvar \'mock_pressed 0) (setvar \'mock_now 15000) '
           '(define premature (log_flush_once nil)) '
           '(setvar \'mock_now 70000) '
           '(list attempt a_state b_state premature '
           ' log_flush_aborts (log_flush_once nil) '
           ' (log_boot_block 128 64 1112820808))',
           '(nil ok in_progress nil 1 t ok)')
    expect('rollover sequence stays odd then even',
           '(log_initialise log_a 1) (mock-set log_a 72 3) '
           '(bufset-u32 nv 256 2147483646) '
           '(list (log_flush_once nil) (mock-eeprom-read 64) '
           ' (log_boot_block 64 63 1112820807))', '(t 0u32 ok)')
    expect('retry sequence wraps from maximum odd without remaining odd',
           '(log_initialise log_a 1) (mock-set log_a 72 3) '
           '(bufset-u32 nv 256 2147483647) '
           '(list (log_flush_once nil) (mock-eeprom-read 64) '
           ' (log_boot_block 64 63 1112820807))', '(t 2u32 ok)')
    expect('cancel unclaimed five-click; no background periodic continuation',
           '(log_initialise log_a 1) (mock-set log_a 72 4) '
           '(log_shutdown_flush) '
           '(list log_shutdown_request log_shutdown_cancelled mock_sleep_calls '
           ' (log_flush_once nil) (mock-eeprom-read 64))',
           '(0 1 164 nil 2u32)')
    expect('cancel claimed five-click between stores, no B or retry',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(mock-set log_a 72 4) (mock-set log_b 133 32768) '
           '(setvar \'log_shutdown_request 2) '
           '(setvar \'cancel_write (+ writes 1)) '
           '(list (log_flush_once t) (mock-eeprom-read 128) '
           ' (mock-eeprom-read 72) (log_boot_block 64 63 1112820807))',
           '(nil 2u32 0u32 in_progress)')
    expect('five-click writes once without settle and interval, using sampler ownership',
           '(log_initialise log_a 1) (mock-set log_a 72 4) '
           '(setvar \'log_rest_since 0) (setvar \'log_shutdown_request 2) '
           '(list (log_flush_once t) (mock-eeprom-read 72) log_flush_count '
           ' (log_flush_once nil))', '(t 4u32 1 nil)')
    expect('init and clear require ordinary settle and interval',
           '(setvar \'log_rest_since 0) '
           '(define refused (log_initialise log_a 1)) '
           '(setvar \'log_rest_since 1000) (log_initialise log_a 1) '
           '(setvar \'log_flush_seen 1) (setvar \'log_last_flush mock_now) '
           '(list refused (log_clear log_a) (log_set_enabled log_a 0) '
           ' writes)', '(nil nil nil 64)')
    expect('torn state requires explicit clear and stays disabled',
           '(setvar \'log_state_a \'in_progress) '
           '(setvar \'log_enable_a 1) (mock-set log_a 72 5) '
           '(define refused (log_flush_once nil)) '
           '(list refused (log_clear log_a) (mock-eeprom-read 67) '
           ' (log_boot_block 64 63 1112820807) log_enable_a)',
           '(nil t 256u32 ok 0)')
    expect('protected addresses denied even with malformed buffer',
           '(bufset-u32 log_a 0 63) '
           '(list (log_write_slot 127 3) (log_write_slot 192 3) '
           ' (log_write_slot 0 3) (log_clear log_a) writes)',
           '(nil nil nil nil 0)')
    expect('160-word sampler stack commits both blocks in spawned context',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(mock-set log_a 72 4) (mock-set log_b 133 32768) '
           '(spawn 160 (lambda () (trap (log_flush_once nil)))) (sleep 0.1) '
           '(list (mock-eeprom-read 72) (mock-eeprom-read 133) '
           ' (log_boot_block 128 64 1112820808))',
           '(4u32 32768u32 ok)')
    expect('disabled foreign/unknown/torn never written periodically',
           '(setvar \'log_state_a \'foreign) '
           '(setvar \'log_enable_a 1) (mock-set log_a 72 5) '
           '(define a (log_flush_once nil)) '
           '(setvar \'log_state_a \'unknown_layout) '
           '(define b (log_flush_once nil)) '
           '(setvar \'log_state_a \'in_progress) '
           '(list a b (log_flush_once nil) writes)', '(nil nil nil 0)')
    expect('explicit clear foreign claims, unknown refused; flags last',
           '(setvar \'log_state_a \'foreign) '
           '(define before (log_initialise log_a 1)) '
           '(define clear (log_clear log_a)) '
           '(define flags (bufget-u8 trace (- writes 3))) '
           '(setvar \'log_state_a \'unknown_layout) '
           '(list before clear flags (log_clear log_a) writes)',
           '(nil t 67 nil 64)')
    expect('disable preserves CRC and leaves other block',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(list (log_set_enabled log_a 0) '
           ' (log_boot_block 64 63 1112820807) '
           ' (log_boot_block 128 64 1112820808) '
           ' (bitwise-and (mock-eeprom-read 67) 1) log_enable_a)',
           '(t ok ok 0u32 0)')
    expect('clear preserves verified enabled flag and CRC',
           '(log_initialise log_a 1) (mock-set log_a 72 19) '
           '(log_flush_once nil) (setvar \'mock_now 80000) '
           '(list (log_clear log_a) (mock-eeprom-read 72) '
           ' (bitwise-and (mock-eeprom-read 67) 1) '
           ' (log_boot_block 64 63 1112820807))',
           '(t 0u32 1u32 ok)')
    expect('block B clear re-references and commits independently',
           '(log_initialise log_a 1) (log_initialise log_b 1) '
           '(mock-set log_b 133 32768) (log_flush_once nil) '
           '(bufset-u32 log_bs 12 1) (setvar \'mock_now 80000) '
           '(list (log_clear log_b) (mock-eeprom-read 133) '
           ' (bufget-u32 log_bs 12) '
           ' (log_boot_block 64 63 1112820807) '
           ' (log_boot_block 128 64 1112820808))',
           '(t 0u32 0u32 ok ok)')
    expect('clear discards fractional carry and resets session state',
           '(log_initialise log_a 1) (log_upd log_a 0 144 0.5) '
           '(bufset-f32 log_st 8 1) (log_clear log_a) '
           '(log_upd log_a 0 144 0.5) '
           '(list (mock-slot log_a 72) (bufget-f32 log_st 8))',
           '(0u32 0.000000f32)')
    expect('interrupted explicit clear never resumes from periodic writer',
           '(log_initialise log_a 1) '
           '(setvar \'fail_write (+ writes 1)) '
           '(list (log_clear log_a) log_state_a '
           ' (log_flush_once nil) writes)',
           '(nil in_progress nil 65)')
    allocations = []
    for count in (100, 200):
        result = actual('(log_initialise log_a 1) (log_initialise log_b 1) '
                        f'(looprange i 1 {count + 1} {{ '
                        '(log_b_set_tag i) (log_flush_once nil) '
                        "(setvar 'mock_now (+ mock_now 60000)) }) "
                        "(gc) (list (lbm-heap-state 'get-num-alloc-cells) "
                        'log_flush_count writes)')
        match = re.fullmatch(r'\((\d+)u (\d+) (\d+)\)', result)
        assert match and int(match[2]) == count, ('native flush soak', result)
        allocations.append(int(match[1]))
    assert allocations[0] == allocations[1], ('GC-reclaimed writer heap', allocations)
    print('native writer: gate, init, CRC, phase failure/retry, tag, reboot, clear and soak passed')
