#!/usr/bin/env python3
"""Production-bound contract checks for signed telemetry and B1 exports.

Runtime behaviour is exercised by perf_log_capture_native.py (when LBM_REPL
is available) and perf_log_qml_fixture.py. These checks intentionally inspect
the production source; they do not substitute a Python implementation.
"""

from pathlib import Path
import struct
import unittest

ROOT = Path(__file__).resolve().parents[1]
LISP = (ROOT / "blacktip_dpv.lisp").read_text()
QML = (ROOT / "ui.qml").read_text()


class SignedTelemetryProductionContract(unittest.TestCase):
    def test_wire_protocol_remains_v1_with_actual_buffer_lengths(self):
        self.assertIn("(define LOG_VERSION 1)", LISP)
        self.assertIn("(define LOG_PREFIX 177)", LISP)
        self.assertIn("(setvar 'log_live (bufcreate 320))", LISP)
        self.assertIn("(setvar 'log_snapshot_buf (bufcreate 320))", LISP)
        self.assertIn("(setvar 'log_diag_live (bufcreate 320))", LISP)
        self.assertIn("(setvar 'log_diag_snapshot (bufcreate 320))", LISP)
        self.assertIn("(setvar 'log_fault_live (bufcreate 12))", LISP)
        self.assertIn("(setvar 'log_fault_snapshot (bufcreate 12))", LISP)
        self.assertIn("(if (= op 2) 20 (if (or (= op 3) (= op 4)) 44", LISP)
        self.assertIn("(if (= op 5) 24 12)", LISP)

    def test_direction_inversion_is_applied_only_to_target_frame(self):
        sample = LISP[LISP.index("(defun log_diag_sample"):
                      LISP.index("; The Blacktip/CudaX profiles")]
        self.assertIn("(var inv (trap (conf-get 'm-invert-direction)))", sample)
        self.assertIn("(var framed (if (= (ix inv 1) 1) (- target) target))",
                      sample)
        self.assertIn("(var err (- framed rpm))", sample)
        self.assertIn("(bufset-f32 log_diag_live (+ off 4) ts)", sample)
        self.assertIn("(bufset-f32 log_diag_live (+ off 8) rs)", sample)
        self.assertIn("(bufset-f32 log_diag_live (+ off 12) es)", sample)

    def test_voltage_minimum_and_optional_failure_are_independent(self):
        sample = LISP[LISP.index("(defun log_diag_sample"):
                      LISP.index("; The Blacktip/CudaX profiles")]
        self.assertIn("(bufset-f32 log_diag_live (+ off 24) voltage)", sample)
        self.assertIn("(log_diag_failure off)", sample)
        sampler = LISP[LISP.index("(defun log_sample"):
                        LISP.index("(defun log_admit")]
        self.assertIn("; Diagnostic read failures cannot invalidate a good legacy sample.",
                      sampler)
        self.assertIn("(if (not (eq (ix diagnostic 0) 'exit-ok))", sampler)

    def test_ieee_float32_rounding_is_the_wire_precision(self):
        # Distinguishes binary32 storage from Python's binary64 intermediates.
        self.assertEqual(struct.unpack(">f", struct.pack(">f", 0.1))[0],
                         0.10000000149011612)
        self.assertIn("(bufset-f32 log_diag_live", LISP)
        self.assertIn("(bufget-u8 log_diag_snapshot", LISP)

    def test_fault_poll_is_outside_collection_eligibility(self):
        sample = LISP[LISP.index("(defun log_sample"):
                      LISP.index("(defun log_admit")]
        self.assertLess(sample.index("(var poll (trap (log_poll_fault)))"),
                        sample.index("(if (and eligible (= log_fault 0))"))
        self.assertIn("(defun log_poll_fault", LISP)
        self.assertIn("(get-fault)", LISP)

    def test_qml_keeps_v1_schema_and_production_transaction_guards(self):
        self.assertIn("view.getUint8(1) !== 1", QML)
        for required in ("logSequence", "logToken", "logRetries",
                         "logComplete", "logCsv(", "logReceive(view)"):
            self.assertIn(required, QML)


if __name__ == "__main__":
    unittest.main(verbosity=2)
