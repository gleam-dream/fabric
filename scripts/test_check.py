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
    def test_registered_recipe_commands_reach_their_public_cli(self) -> None:
        recipes = {"approvers-recipe", "saga-recipe", "relay-recipes"}
        for item in check.checks(check.ROOT, "fast"):
            if item.name in recipes:
                with self.subTest(recipe=item.name):
                    result = subprocess.run(
                        item.command,
                        cwd=check.ROOT,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                    )
                    self.assertEqual(result.returncode, 0, result.stdout)

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

    def test_recipe_copies_must_match_the_consumer(self) -> None:
        recipe = "import fabric/approvers\n\npub fn x() {\n  1\n}\n"
        doc = "".join(
            "////" + (" " + line if line else "") + "\n" for line in recipe.splitlines()
        )
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            consumer = root / check.RECIPE_CONSUMER
            consumer.parent.mkdir(parents=True)
            consumer.write_text(recipe)
            module = root / check.RECIPE_MODULE
            module.parent.mkdir(parents=True)
            module.write_text(
                f"//// Doc.\n{check.RECIPE_HEADING}\n////\n//// ```gleam\n{doc}//// ```\n"
            )
            readme = root / check.RECIPE_README
            readme.write_text(f"# x\n{check.RECIPE_MARKER}\n\n```gleam\n{recipe}```\n")
            self.assertEqual(check.recipe_problems(root), [])
            readme.write_text(
                f"{check.RECIPE_MARKER}\n```gleam\n{recipe.replace('1', '2')}```\n"
            )
            [problem] = check.recipe_problems(root)
            self.assertIn("USAGE.md differs", problem)
            self.assertIn("+  2", problem)
            readme.write_text("no marker\n")
            with self.assertRaisesRegex(ValueError, "no gleam block"):
                check.recipe_problems(root)

    def test_saga_recipe_changes_fail_with_a_diff(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in [
                "USAGE.md",
                check.SAGA_RECIPE["consumer"],
                check.SAGA_RECIPE["module"],
            ]:
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text((check.ROOT / relative).read_text())
            self.assertEqual(check.recipe_problems(root, **check.SAGA_RECIPE), [])
            module = root / check.SAGA_RECIPE["module"]
            module.write_text(
                module.read_text().replace("reporting.run_owned(", "reporting.changed(")
            )
            [problem] = check.recipe_problems(root, **check.SAGA_RECIPE)
            self.assertIn("reporting.changed(", problem)

    def test_recipe_line_bounds_include_the_complete_source(self) -> None:
        for config, limit in [(check.SAGA_RECIPE, 60), ({}, 50)]:
            with self.subTest(limit=limit), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                source_path = config.get("consumer", check.RECIPE_CONSUMER)
                module_path = config.get("module", check.RECIPE_MODULE)
                marker = config.get("marker", check.RECIPE_MARKER)
                heading = config.get("heading", check.RECIPE_HEADING)
                source = root / source_path
                module = root / module_path
                source.parent.mkdir(parents=True, exist_ok=True)
                module.parent.mkdir(parents=True, exist_ok=True)
                for count in [limit, limit + 1]:
                    recipe = "// recipe line\n" * count
                    source.write_text(recipe)
                    (root / "USAGE.md").write_text(f"{marker}\n```gleam\n{recipe}```\n")
                    doc = "".join("//// " + line + "\n" for line in recipe.splitlines())
                    module.write_text(f"{heading}\n//// ```gleam\n{doc}//// ```\n")
                    expected = (
                        []
                        if count == limit
                        else [f"{source_path}: recipe exceeds {limit} lines"]
                    )
                    self.assertEqual(check.recipe_problems(root, **config), expected)

    def test_each_relay_recipe_is_compiled_verbatim_and_mismatch_has_diff(self) -> None:
        for config in check.RELAY_RECIPES:
            with (
                self.subTest(recipe=config["consumer"]),
                tempfile.TemporaryDirectory() as folder,
            ):
                root = Path(folder)
                for relative in ["USAGE.md", config["consumer"], config["module"]]:
                    destination = root / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_text((check.ROOT / relative).read_text())
                self.assertEqual(check.recipe_problems(root, **config), [])
                source = (root / config["consumer"]).read_text()
                self.assertLessEqual(len(source.splitlines()), 50)
                readme = root / "USAGE.md"
                readme.write_text(
                    readme.read_text().replace(
                        source, source.replace("pub fn", "fn", 1), 1
                    )
                )
                [problem] = check.recipe_problems(root, **config)
                self.assertIn("USAGE.md differs", problem)
                self.assertIn("-pub fn", problem)
                self.assertIn("+fn", problem)


if __name__ == "__main__":
    unittest.main()
