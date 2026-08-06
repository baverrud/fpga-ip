import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


REPO_ROOT = Path(__file__).resolve().parents[1]
RUNNER_PATH = REPO_ROOT / "run.py"

spec = importlib.util.spec_from_file_location("fpga_ip_run", RUNNER_PATH)
runner = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = runner
spec.loader.exec_module(runner)


class RunnerTests(unittest.TestCase):
    def manifest(self, text: str):
        handle = tempfile.NamedTemporaryFile(
            mode="w", suffix=".f", delete=False, encoding="utf-8"
        )
        try:
            handle.write(text)
            handle.close()
            path = Path(handle.name)
            return path, runner.parse_manifest(path)
        except Exception:
            handle.close()
            Path(handle.name).unlink(missing_ok=True)
            raise

    def test_all_manifests_parse_and_sources_exist(self):
        manifests = sorted(REPO_ROOT.glob("*/scripts/*.f"))
        self.assertEqual(len(manifests), 20)
        for path in manifests:
            manifest = runner.parse_manifest(path.resolve())
            for section in manifest.sections.values():
                for entry in section.entries:
                    if isinstance(entry, runner.FileEntry):
                        self.assertTrue(entry.path.is_file(), entry.path)

    def test_probe_identity_selects_version_and_edition_profile(self):
        result = SimpleNamespace(
            stdout="Questa Altera Starter FPGA Edition-64 vsim 2025.3",
            stderr="",
            returncode=0,
        )
        capabilities = runner.Capabilities.load(REPO_ROOT / "tool_capabilities.ini")
        with patch.object(runner.subprocess, "run", return_value=result) as probe:
            self.assertEqual(
                capabilities.detect_identity("questa"), ("2025.3", "starter")
            )
            features = capabilities.effective_features_for("questa", None, None)
        self.assertIn("vhdl-2019", features)
        probe.assert_called_once()

    def test_probe_failure_falls_back_to_base_profile(self):
        capabilities = runner.Capabilities.load(REPO_ROOT / "tool_capabilities.ini")
        with patch.object(
            runner.subprocess, "run", side_effect=FileNotFoundError
        ):
            features = capabilities.effective_features_for("questa", None, None)
        self.assertIn("uvvm", features)
        self.assertNotIn("vhdl-2019", features)

    def test_section_names_are_normalized(self):
        path, manifest = self.manifest(
            "[RTL]\ncommon/rtl/util_pkg.vhd\n"
        )
        try:
            self.assertIn("rtl", manifest.sections)
        finally:
            path.unlink(missing_ok=True)

    def test_unknown_file_attribute_is_rejected(self):
        path = tempfile.NamedTemporaryFile(
            mode="w", suffix=".f", delete=False, encoding="utf-8"
        )
        path.write("[rtl]\ncommon/rtl/util_pkg.vhd bogus=1\n")
        path.close()
        try:
            with self.assertRaises(runner.RunnerError):
                runner.parse_manifest(Path(path.name))
        finally:
            Path(path.name).unlink(missing_ok=True)

    def test_non_work_library_is_rejected(self):
        path = tempfile.NamedTemporaryFile(
            mode="w", suffix=".f", delete=False, encoding="utf-8"
        )
        path.write("DEFAULT_LIB: custom\n[rtl]\ncommon/rtl/util_pkg.vhd\n")
        path.close()
        try:
            with self.assertRaises(runner.RunnerError):
                runner.parse_manifest(Path(path.name))
        finally:
            Path(path.name).unlink(missing_ok=True)

    def test_duplicate_source_is_kept_once(self):
        path, manifest = self.manifest(
            "[rtl]\n"
            "common/rtl/util_pkg.vhd\n"
            "common/rtl/util_pkg.vhd\n"
        )
        try:
            files = runner.build_closure(
                manifest, ["rtl"], "modelsim", {manifest.path: manifest}
            )
            self.assertEqual([entry.path for entry in files].count(
                REPO_ROOT / "common/rtl/util_pkg.vhd"
            ), 1)
        finally:
            path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
