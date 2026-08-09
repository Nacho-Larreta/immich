import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import strict_evidence
from strict_evidence import EvidenceValidationError, MAX_JSON_BYTES, load_strict_json


class StrictJsonTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.addCleanup(self.temporary_directory.cleanup)
        self.path = Path(self.temporary_directory.name) / "manifest.json"

    def test_rejects_duplicate_json_keys(self) -> None:
        self.path.write_text('{"schemaVersion": 1, "schemaVersion": 2}', encoding="utf-8")
        self.path.chmod(0o600)

        with self.assertRaisesRegex(EvidenceValidationError, "duplicate_json_key"):
            load_strict_json(self.path)

    def test_rejects_nan_and_infinity(self) -> None:
        for value in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(value=value):
                self.path.write_text(f'{{"value": {value}}}', encoding="utf-8")
                self.path.chmod(0o600)
                with self.assertRaisesRegex(EvidenceValidationError, "non_finite_number"):
                    load_strict_json(self.path)

    def test_accepts_standard_finite_json(self) -> None:
        value = {"schemaVersion": 1, "value": 1.25}
        self.path.write_text(json.dumps(value), encoding="utf-8")
        self.path.chmod(0o600)

        self.assertEqual(value, load_strict_json(self.path))

    def test_rejects_symlink_fifo_oversize_and_non_private_json(self) -> None:
        target = self._write_private("target.json", b"{}")
        symlink = self.path.parent / "symlink.json"
        symlink.symlink_to(target)
        fifo = self.path.parent / "fifo.json"
        os.mkfifo(fifo, 0o600)
        oversize = self._write_private("oversize.json", b"")
        os.truncate(oversize, MAX_JSON_BYTES + 1)
        public = self._write_private("public.json", b"{}")
        public.chmod(0o644)

        expected_codes = {
            symlink: "json_unreadable",
            fifo: "json_not_regular_file",
            oversize: "json_oversize",
            public: "json_not_private",
        }
        for path, code in expected_codes.items():
            with self.subTest(path=path.name):
                with self.assertRaisesRegex(EvidenceValidationError, code):
                    load_strict_json(path)

    def test_rejects_invalid_utf8_and_excessive_depth(self) -> None:
        invalid_utf8 = self._write_private("invalid.json", b"\xff")
        nested: object = 0
        for _ in range(33):
            nested = [nested]
        deep = self._write_private("deep.json", json.dumps({"value": nested}).encode())

        with self.assertRaisesRegex(EvidenceValidationError, "json_invalid_utf8"):
            load_strict_json(invalid_utf8)
        with self.assertRaisesRegex(EvidenceValidationError, "json_too_deep"):
            load_strict_json(deep)

    def test_rejects_json_outside_explicit_root(self) -> None:
        allowed = self.path.parent / "allowed"
        allowed.mkdir(mode=0o700)
        outside = self._write_private("outside.json", b"{}")

        with self.assertRaisesRegex(EvidenceValidationError, "json_outside_allowed_root"):
            load_strict_json(outside, root=allowed)

    def test_rejects_json_mutated_while_reading(self) -> None:
        self._write_private("manifest.json", b"{}")
        original = strict_evidence._read_bounded

        def mutate_after_read(descriptor: int, location: str) -> bytes:
            payload = original(descriptor, location)
            self.path.write_bytes(b'{"changed": true}')
            self.path.chmod(0o600)
            return payload

        with patch("strict_evidence._read_bounded", side_effect=mutate_after_read):
            with self.assertRaisesRegex(EvidenceValidationError, "json_changed_while_reading"):
                load_strict_json(self.path)

    def _write_private(self, name: str, payload: bytes) -> Path:
        path = self.path.parent / name
        path.write_bytes(payload)
        path.chmod(0o600)
        return path


if __name__ == "__main__":
    unittest.main()
