"""Public failures of the verification gate, using real child processes."""

import json
import os
from pathlib import Path
import tempfile
import subprocess
import unittest

import check
import quality


class GateTest(unittest.TestCase):
    def test_invalid_or_incomplete_sibling_pins_fail_before_checkout(self) -> None:
        for pins in ("", "unknown=" + "a" * 40, "sinal=invalid", "sinal=" + "a" * 40):
            with self.subTest(pins=pins), tempfile.TemporaryDirectory() as folder:
                root = Path(folder) / "fabric"
                (root / "scripts").mkdir(parents=True)
                (root / "scripts/checkout-siblings.sh").write_text(
                    (check.ROOT / "scripts/checkout-siblings.sh").read_text()
                )
                (root / "sibling-revisions.txt").write_text(pins + "\n")
                result = subprocess.run(
                    ["bash", "scripts/checkout-siblings.sh"],
                    cwd=root,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(list(Path(folder).iterdir()), [root])

    def test_public_sibling_checkout_needs_no_custom_credential(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "fabric"
            (root / "scripts").mkdir(parents=True)
            (root / "scripts/checkout-siblings.sh").write_text(
                (check.ROOT / "scripts/checkout-siblings.sh").read_text()
            )
            pins = (check.ROOT / "sibling-revisions.txt").read_text()
            (root / "sibling-revisions.txt").write_text(pins)
            tools = Path(folder) / "tools"
            tools.mkdir()
            git = tools / "git"
            git.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "args = sys.argv[1:]\n"
                "with open(os.environ['GIT_CALL_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(args) + '\\n')\n"
                "if args[0] == 'init':\n"
                "    pathlib.Path(args[-1]).mkdir()\n"
                "elif args[2] == 'fetch':\n"
                "    (pathlib.Path(args[1]) / 'revision').write_text(args[-1])\n"
                "elif args[2:] == ['rev-parse', 'HEAD']:\n"
                "    print((pathlib.Path(args[1]) / 'revision').read_text())\n"
            )
            git.chmod(0o755)
            log = Path(folder) / "git-calls.jsonl"
            environment = dict(
                os.environ,
                PATH=f"{tools}{os.pathsep}{os.environ['PATH']}",
                GIT_CALL_LOG=str(log),
            )
            for name in (
                "SIBLINGS_TOKEN",
                "SIBLINGS_APP_CLIENT_ID",
                "SIBLINGS_APP_PRIVATE_KEY",
                "SIBLINGS_READ_TOKEN",
            ):
                environment.pop(name, None)
            result = subprocess.run(
                ["bash", "scripts/checkout-siblings.sh"],
                cwd=root,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            selected = dict(
                line.split("=", 1)
                for line in pins.splitlines()
                if line and not line.startswith("#")
            )
            fetches = {
                Path(args[1]).name: args[-1]
                for args in calls
                if args[0] == "-C" and args[2] == "fetch"
            }
            self.assertEqual(fetches, selected)
            remotes = {
                Path(args[1]).name: args[-1]
                for args in calls
                if args[0] == "-C" and args[2] == "remote"
            }
            self.assertEqual(
                remotes,
                {
                    package: "https://github.com/"
                    + ("lostbean" if package == "json_blueprint" else "gleam-dream")
                    + f"/{package}.git"
                    for package in selected
                },
            )
            self.assertTrue(all(args[0] in ("init", "-C") for args in calls))
            self.assertNotIn("extraheader", json.dumps(calls).lower())

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

    def test_missing_sibling_fails_with_the_package_name(self) -> None:
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
