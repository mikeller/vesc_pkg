"""Read-only boot classifier vectors and isolated real LispBM execution."""
import ctypes
import re
import subprocess
import tempfile
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def crc(image, base, count):
    return zlib.crc32(b''.join(image[i].to_bytes(4, 'big')
                               for i in range(base + 2, base + count))) & 0x7fffffff


def classify(image, base, count, magic):
    if all(image.get(i) is None for i in range(base, base + 4)):
        return 'empty', False
    if image.get(base + 2) != magic:
        return 'foreign', False
    if image.get(base + 3) is None or (image[base + 3] >> 8) & 255 != 1:
        return 'unknown_layout', False
    if image.get(base) is None or image[base] & 1:
        return 'in_progress', False
    if any(not isinstance(image.get(i), int) or not 0 <= image[i] <= 0x7fffffff
           for i in range(base, base + count)):
        return 'crc_mismatch', False
    if image[base + 1] != crc(image, base, count):
        return 'crc_mismatch', False
    return 'ok', bool(image[base + 3] & 1)


def references(stored_i, stored_f, stored_m, flags, fresh_i, fresh_m, motor_read):
    mismatch = (stored_i and stored_i != fresh_i) or (stored_m and stored_m != fresh_m)
    flags = (flags & ~8) | (8 if mismatch else 0)
    if not stored_m:
        flags = (flags & ~2) | (2 if motor_read else 0)
    return stored_i or fresh_i, stored_f or 850, stored_m or fresh_m, flags


def native_source():
    source = (ROOT / 'blacktip_dpv.lisp').read_text()
    section = source[source.index('(defun log_blk_new'):source.index('; Unlike the generic fractional positive-only adder')]
    # Only the exact production boot functions and their common helpers are
    # evaluated; the default 128 KiB native REPL image fills on the full source.
    section = section[:section.index('(defun log_motor_reference')] + section[section.index('(defun log_boot_block'):]
    section = section.replace('(eeprom-read-i ', '(mock-eeprom-read ')
    # The native BLDC stub returns eval_error for crc32. Exercise the production
    # loader with an equivalent CRC32 implementation in this harness only.
    section = section.replace('(crc32 ', '(mock-crc32 ')
    return '''(define LOG_A_BASE 64) (define LOG_A_SLOTS 63)
(define LOG_B_BASE 128) (define LOG_B_SLOTS 64) (define LOG_FET_REF 850)
(define MAX_CURRENT_BLACKTIP 22.8) (define MAX_CURRENT_CUDAX 46)
(define SCOOTER_CUDAX 1) (define scooter_type 0)
(define log_a nil) (define log_b nil) (define log_bs nil) (define log_fet_edges nil)
(define log_enable_a 0) (define log_enable_b 0)
(define log_state_a 'empty) (define log_state_b 'empty)
(define nv (bufcreate 1024)) (define present (bufcreate 256))
(define mock_fail_slot -1)
(defun mock-eeprom-read (addr) {
    (if (= addr mock_fail_slot) (car 1))
    (if (or (< addr 64) (and (> addr 126) (< addr 128)) (> addr 191)) (car 1))
    (if (= (bufget-u8 present addr) 0) nil (bufget-u32 nv (* addr 4)))
})
(defun put (addr val) { (bufset-u32 nv (* addr 4) val) (bufset-u8 present addr 1) })
(define mock_motor_ref 1800) (define mock_motor_flag 2)
(defun log_motor_reference () (list mock_motor_ref mock_motor_flag))
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
''' + section


def native(repl, scenario):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / 'boot.lisp'
        path.write_text(native_source() + '\n' + scenario + '\n')
        p = subprocess.run([repl, '-H', '2753', '-M', '262144', '-C', '262144',
                            '--bldc_stubs', '--terminate', '-s', str(path)], capture_output=True,
                           text=True, timeout=30)
    values = [line[2:] for line in p.stdout.splitlines() if line.startswith('> ')]
    assert p.returncode == 0 and values and not any(x in p.stdout for x in
        ('fatal_error', 'exit-error', 'out_of_memory')), p.stdout + p.stderr
    return values[-1]


def make_image(base, count, magic, flags):
    image = {i: 0 for i in range(base, base + count)}
    image[base + 2] = magic
    image[base + 3] = flags
    image[base + 1] = crc(image, base, count)
    return image


def firmware_crc_vectors(source):
    """Compile the unmodified firmware CRC implementation and compare vectors.

    LBM_CRC_SOURCE points at the firmware's lispBM/lispBM/utils/crc.c. Neither
    the firmware source nor the package's C library is edited.
    """
    with tempfile.TemporaryDirectory() as tmp:
        lib_path = str(Path(tmp) / 'crc.so')
        subprocess.run(['cc', '-shared', '-fPIC', '-O2', '-o', lib_path, source],
                       check=True, capture_output=True, text=True)
        fn = ctypes.CDLL(lib_path).crc32_with_init
        fn.argtypes = (ctypes.POINTER(ctypes.c_uint8), ctypes.c_uint32, ctypes.c_uint32)
        fn.restype = ctypes.c_uint32

        def checksum(data, init=0):
            buf = (ctypes.c_uint8 * len(data)).from_buffer_copy(data)
            return fn(buf, len(data), init)

        results = [(checksum(b'123456789'), 0xcbf43926)]
        for base, count, magic, flags in ((64, 63, 1112820807, 257),
                                          (128, 64, 1112820808, 279)):
            image = make_image(base, count, magic, flags)
            image[base + 5] = 42
            data = b''.join(image[i].to_bytes(4, 'big')
                            for i in range(base + 2, base + count))
            chained = 0
            for i in range(0, len(data), 4):
                chained = checksum(data[i:i + 4], chained)
            results.extend(((checksum(data), zlib.crc32(data)),
                            (chained & 0x7fffffff, crc(image, base, count))))
        return results
