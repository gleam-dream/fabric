"""Public failures of the verification gate, using real child processes."""

import json
from pathlib import Path
import tempfile
import unittest

import check


class GateTest(unittest.TestCase):
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
                (directory / "gleam.toml").write_text('name = "example"\nversion = "0.0.0"\n[dependencies]\nmissing = { path = "missing" }\n')
            with self.assertRaisesRegex(ValueError, "needs missing"):
                check.dependencies(root)

    def test_failure_is_retained_and_later_checks_never_run(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            selected = [
                check.Check("failure", ".", ("python3", "-c", "raise SystemExit(23)")),
                check.Check("must-not-run", ".", ("python3", "-c", "raise SystemExit(0)")),
            ]
            self.assertFalse(check.run_checks(root, selected, root))
            results = json.loads((root / "results.json").read_text())
            self.assertEqual([(r["name"], r["exit_code"]) for r in results], [("failure", 23)])
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
            "////" + (" " + line if line else "") + "\n"
            for line in recipe.splitlines()
        )
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            consumer = root / check.RECIPE_CONSUMER
            consumer.parent.mkdir(parents=True)
            consumer.write_text(recipe)
            module = root / check.RECIPE_MODULE
            module.parent.mkdir(parents=True)
            module.write_text(f"//// Doc.\n{check.RECIPE_HEADING}\n////\n//// ```gleam\n{doc}//// ```\n")
            readme = root / check.RECIPE_README
            readme.write_text(f"# x\n{check.RECIPE_MARKER}\n\n```gleam\n{recipe}```\n")
            self.assertEqual(check.recipe_problems(root), [])
            readme.write_text(f"{check.RECIPE_MARKER}\n```gleam\n{recipe.replace('1', '2')}```\n")
            [problem] = check.recipe_problems(root)
            self.assertIn("README.md differs", problem)
            self.assertIn("+  2", problem)
            readme.write_text("no marker\n")
            with self.assertRaisesRegex(ValueError, "no gleam block"):
                check.recipe_problems(root)


if __name__ == "__main__":
    unittest.main()
