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
        self.assertTrue(manifests, "no .f manifests found under any IP scripts dir")
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

    def test_toolchain_setup_captures_child_environment(self):
        config = runner.configparser.ConfigParser()
        config.read_string(
            "[toolchain.questa]\n"
            "setup = q26\n"
            "[toolchain.vivado.2025.2]\n"
            "setup = v25\n"
        )
        toolchains = runner.Toolchains(config, Path("toolchains.ini"))
        result = SimpleNamespace(
            stdout="PATH=C:\\tools\\questa\nQSIM_INI=C:\\sim\\modelsim.ini\n",
            stderr="",
            returncode=0,
        )
        with patch.object(runner.subprocess, "run", return_value=result) as setup:
            environment = toolchains.prepare("questa", None)
            versioned = toolchains.prepare("vivado", "2025.2")
        self.assertEqual(environment["PATH"], "C:\\tools\\questa")
        self.assertEqual(environment["QSIM_INI"], "C:\\sim\\modelsim.ini")
        self.assertEqual(versioned["PATH"], "C:\\tools\\questa")
        self.assertEqual(setup.call_count, 2)
        self.assertIn("call q26", setup.call_args_list[0].args[0][-1])
        self.assertIn("call v25", setup.call_args_list[1].args[0][-1])

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

    def test_xsim_gui_script_requests_trace_debug(self):
        files = [
            runner.FileEntry(
                path=REPO_ROOT / "common/rtl/util_pkg.vhd",
                section="rtl",
                std="2008",
                lib="work",
                tools=[],
                order=1,
            )
        ]
        runs_root = REPO_ROOT / ".runs"
        runs_root.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=runs_root) as temp_dir:
            gui_path = Path(temp_dir) / "sim_gui.tcl"
            batch_path = Path(temp_dir) / "sim_batch.tcl"
            runner.write_xsim_script(
                gui_path, files, "tb", "gui", "xsim", "vhdl.f",
                "example_ip", "default", gui_path.name, "2008"
            )
            runner.write_xsim_script(
                batch_path, files, "tb", "batch", "xsim", "vhdl.f",
                "example_ip", "default", batch_path.name, "2008"
            )
            gui_text = gui_path.read_text(encoding="utf-8")
            batch_text = batch_path.read_text(encoding="utf-8")
            self.assertIn("xelab -debug all", gui_text)
            self.assertIn("--gui --tclbatch", gui_text)
            self.assertNotIn("xelab -debug all", batch_text)
            self.assertNotIn("--gui --tclbatch", batch_text)


if __name__ == "__main__":
    unittest.main()
