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

    def test_saga_recipe_changes_fail_with_a_diff(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for relative in ["README.md", check.SAGA_RECIPE["consumer"], check.SAGA_RECIPE["module"]]:
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text((check.ROOT / relative).read_text())
            self.assertEqual(check.recipe_problems(root, **check.SAGA_RECIPE), [])
            module = root / check.SAGA_RECIPE["module"]
            module.write_text(module.read_text().replace("reporting.run_owned(", "reporting.changed("))
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
                    (root / "README.md").write_text(f"{marker}\n```gleam\n{recipe}```\n")
                    doc = "".join("//// " + line + "\n" for line in recipe.splitlines())
                    module.write_text(f"{heading}\n//// ```gleam\n{doc}//// ```\n")
                    expected = [] if count == limit else [f"{source_path}: recipe exceeds {limit} lines"]
                    self.assertEqual(check.recipe_problems(root, **config), expected)

    def test_each_relay_recipe_is_compiled_verbatim_and_mismatch_has_diff(self) -> None:
        for config in check.RELAY_RECIPES:
            with self.subTest(recipe=config["consumer"]), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                for relative in ["README.md", config["consumer"], config["module"]]:
                    destination = root / relative
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_text((check.ROOT / relative).read_text())
                self.assertEqual(check.recipe_problems(root, **config), [])
                source = (root / config["consumer"]).read_text()
                self.assertLessEqual(len(source.splitlines()), 50)
                readme = root / "README.md"
                readme.write_text(readme.read_text().replace(source, source.replace("pub fn", "fn", 1), 1))
                [problem] = check.recipe_problems(root, **config)
                self.assertIn("README.md differs", problem)
                self.assertIn("-pub fn", problem)
                self.assertIn("+fn", problem)


if __name__ == "__main__":
    unittest.main()
