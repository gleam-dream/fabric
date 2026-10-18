"""Public failures of the verification gate, using real child processes."""

import json
from pathlib import Path
import tempfile
import unittest

import check
import quality


class GateTest(unittest.TestCase):
    def test_authored_erlang_warning_is_rejected_including_test_sources(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "src").mkdir()
            (root / "test").mkdir()
            (root / "src/accepted.erl").write_text(
                "-module(accepted).\n-export([value/0]).\nvalue() -> 2.\n"
            )
            self.assertEqual(quality.native(root), 0)
            (root / "test/rejected.erl").write_text(
                "-module(rejected).\n-export([value/0]).\nvalue() -> Unused = 1, 2.\n"
            )
            self.assertNotEqual(quality.native(root), 0)

    def test_empty_selection_cannot_report_a_pass(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "no checks selected"):
                check.run_checks(Path(folder), [], Path(folder))

    def test_missing_package_is_an_error_instead_of_a_skipped_check(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            with self.assertRaisesRegex(ValueError, "package gate mismatch"):
                check.checks(Path(folder), "full")

    def test_new_package_requires_a_gate_owner(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for package in (*check.PACKAGES, "consumers/new"):
                directory = root / package
                directory.mkdir(parents=True, exist_ok=True)
                (directory / "gleam.toml").write_text('name = "example"\n')
            with self.assertRaisesRegex(ValueError, "consumers/new"):
                check.checks(root, "ci")

    def test_missing_path_dependency_fails_with_the_package_name(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for package in check.PACKAGES:
                directory = root / package
                directory.mkdir(parents=True, exist_ok=True)
                (directory / "gleam.toml").write_text(
                    'name = "example"\nversion = "0.0.0"\n[dependencies]\nmissing = { path = "missing" }\n'
                )
            with self.assertRaisesRegex(ValueError, "needs missing"):
                check.dependencies(root)

    def test_failure_is_retained_and_later_checks_never_run(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            selected = [
                check.Check("failure", ".", ("python3", "-c", "raise SystemExit(23)")),
                check.Check(
                    "must-not-run", ".", ("python3", "-c", "raise SystemExit(0)")
                ),
            ]
            self.assertFalse(check.run_checks(root, selected, root))
            results = json.loads((root / "results.json").read_text())
            self.assertEqual(
                [(r["name"], r["exit_code"]) for r in results], [("failure", 23)]
            )
            self.assertFalse((root / "must-not-run.log").exists())

    def test_missing_executable_is_retained_as_failure(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            selected = [check.Check("missing", ".", (str(root / "absent-tool"),))]
            self.assertFalse(check.run_checks(root, selected, root))
            results = json.loads((root / "results.json").read_text())
            self.assertEqual(results[0]["exit_code"], 127)

    def test_compiled_recipes_stay_within_their_line_bounds(self) -> None:
        # The recipes are compiled consumer modules that applications copy.
        # The Saga recipe carries typed reporting errors and may use 60 lines;
        # every other recipe stays within 50.
        bounds = {
            "consumers/approvers_warden/src/approvers_warden.gleam": 50,
            "consumers/saga_tool/src/saga_tool.gleam": 60,
            "consumers/relay_tools/src/relay_tools.gleam": 50,
            "consumers/relay_tools/src/relay_discovery.gleam": 50,
            "consumers/relay_tools/src/relay_operation.gleam": 50,
            "consumers/relay_tools/src/relay_serve.gleam": 50,
            "consumers/relay_tools/src/relay_run.gleam": 50,
        }
        for relative, limit in bounds.items():
            with self.subTest(recipe=relative):
                lines = (check.ROOT / relative).read_text().splitlines()
                self.assertLessEqual(len(lines), limit, relative)


if __name__ == "__main__":
    unittest.main()
