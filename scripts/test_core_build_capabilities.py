#!/usr/bin/env python3
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("capabilities", Path(__file__).with_name("verify-core-build-capabilities.py"))
capabilities = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capabilities)

class CoreBuildCapabilityTests(unittest.TestCase):
    def probe(self, payload, status=0):
        with tempfile.TemporaryDirectory(prefix="clashfx-feature-contract-") as folder:
            core = Path(folder) / "core"
            core.write_text("#!" + sys.executable + "\nimport sys\nassert sys.argv[1:] == ['--features']\nprint(" + repr(payload) + ")\nraise SystemExit(" + str(status) + ")\n")
            core.chmod(0o700)
            with contextlib.redirect_stdout(io.StringIO()):
                capabilities.verify(core)
    def testTaggedCoreAccepted(self):
        self.probe(json.dumps({"features": ["with_gvisor"]}))
    def testUntaggedCoreRejected(self):
        with self.assertRaisesRegex(RuntimeError, "missing with_gvisor"):
            self.probe(json.dumps({"features": []}))
    def testMalformedFeatureMetadataRejected(self):
        for payload in ["not json", json.dumps({"features": "with_gvisor"}), json.dumps({"features": [True]})]:
            with self.subTest(payload=payload), self.assertRaises(RuntimeError):
                self.probe(payload)
    def testOldCoreWithoutCapabilityQueryRejected(self):
        with self.assertRaisesRegex(RuntimeError, "cannot report"):
            self.probe("flag not defined", status=2)

if __name__ == "__main__":
    unittest.main()
