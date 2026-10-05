#!/usr/bin/env python3
"""One local verification gate, prepared for CI after dependency publication."""

import argparse
from dataclasses import dataclass
import difflib
import json
import os
from pathlib import Path
import subprocess
import time
import tomllib


ROOT = Path(__file__).resolve().parents[1]


@dataclass(frozen=True)
class Check:
    name: str
    directory: str
    command: tuple[str, ...]


# Every retained Gleam package is accounted for. Adding one without a gate is
# an error, rather than silently reducing what "full" covers.
PACKAGES = (
    ".",
    "consumers/saga_tool",
    "integrations/fabric_postgres",
    "integrations/fabric_relay",
    "consumers/app",
    "consumers/graph",
    "consumers/decision",
    "consumers/jobs",
    "consumers/writing",
    "consumers/approvers_warden",
    "experiments/workflow_composition",
    "experiments/graph_authoring",
    "experiments/graph_authoring/consumer",
)


def checks(root: Path, profile: str) -> list[Check]:
    found = {
        str(path.parent.relative_to(root))
        for path in root.rglob("gleam.toml")
        if "build" not in path.relative_to(root).parts
    }
    if found != set(PACKAGES):
        raise ValueError(
            f"package gate mismatch: added={found - set(PACKAGES)}, "
            f"missing={set(PACKAGES) - found}"
        )
    selected = [Check("formatting", ".", ("nix", "flake", "check"))]
    selected.append(Check(
        "approvers-recipe", ".", ("python3", "-B", "scripts/check.py", "recipe"),
    ))
    selected.append(Check(
        "saga-recipe", ".", ("python3", "-B", "scripts/check.py", "saga-recipe"),
    ))
    selected.append(Check(
        "gate-tests", ".",
        ("python3", "-B", "-m", "unittest", "discover", "-s", "scripts", "-p", "test_*.py"),
    ))
    for package in PACKAGES if profile != "fast" else (".",):
        name = "core" if package == "." else package.replace("/", "-")
        selected.append(Check(
            f"{name}-format", package, ("gleam", "format", "--check", "src", "test"),
        ))
        selected.append(Check(
            f"{name}-build", package, ("gleam", "build", "--warnings-as-errors"),
        ))
        if package == "integrations/fabric_postgres":
            command = ("bash", "scripts/test-postgres.sh")
        elif package == "consumers/jobs":
            command = ("bash", "test-service.sh")
        else:
            command = ("gleam", "test")
        selected.append(Check(f"{name}-tests", package, command))
    if profile != "fast":
        selected.extend([
            Check(
                "classification-protocol-tests", ".",
                ("python3", "-B", "-m", "unittest", "discover", "-s", "test/fixtures/classifier", "-p", "*_test.py"),
            ),
            Check(
                "writing-evaluation-tests", "consumers/writing",
                ("python3", "-B", "-m", "unittest", "discover", "-p", "test_live.py"),
            ),
            Check(
                "authoring-contract", ".",
                ("python3", "-B", "experiments/graph_authoring/check.py"),
            ),
        ])
    return selected


# The warden recipe of `fabric/approvers` is written three times: in the
# README (after the marker), in the module doc (after its heading) and as the
# consumer package that compiles and tests it. They must be identical.
RECIPE_README = "README.md"
RECIPE_MARKER = "<!-- approvers-recipe -->"
RECIPE_MODULE = "src/fabric/approvers.gleam"
RECIPE_HEADING = "//// ## With warden"
RECIPE_CONSUMER = "consumers/approvers_warden/src/approvers_warden.gleam"


def readme_recipe(text: str, marker: str = RECIPE_MARKER) -> str:
    """The first gleam block after the marker line."""
    lines = text.splitlines()
    try:
        start = lines.index(marker)
        opening = lines.index("```gleam", start)
        closing = lines.index("```", opening)
    except ValueError as error:
        raise ValueError(f"{RECIPE_README}: no gleam block after {marker}") from error
    return "\n".join(lines[opening + 1:closing]) + "\n"


def module_recipe(text: str, heading: str = RECIPE_HEADING) -> str:
    """The first gleam block of the module doc after the heading."""
    lines = text.splitlines()
    try:
        start = lines.index(heading)
        opening = lines.index("//// ```gleam", start)
        closing = lines.index("//// ```", opening)
    except ValueError as error:
        raise ValueError(f"{RECIPE_MODULE}: no gleam block after {heading}") from error
    return "\n".join(
        line.removeprefix("//// ").removeprefix("////")
        for line in lines[opening + 1:closing]
    ) + "\n"


SAGA_RECIPE = dict(
    consumer="consumers/saga_tool/src/saga_tool.gleam",
    module="src/fabric/tool.gleam", marker="<!-- saga-recipe -->",
    heading="//// ## With saga",
)


def recipe_problems(root: Path, *, consumer: str = RECIPE_CONSUMER,
                    module: str = RECIPE_MODULE, marker: str = RECIPE_MARKER,
                    heading: str = RECIPE_HEADING) -> list[str]:
    """Where the two documentation copies differ from the compiled consumer."""
    source = (root / consumer).read_text()
    copies = {
        RECIPE_README: readme_recipe((root / RECIPE_README).read_text(), marker),
        module: module_recipe((root / module).read_text(), heading),
    }
    problems = []
    for name, copy in copies.items():
        if copy != source:
            diff = difflib.unified_diff(source.splitlines(), copy.splitlines(),
                                        consumer, name, lineterm="")
            problems.append(f"{name} differs from {consumer}:\n" + "\n".join(diff))
    return problems


def dependencies(root: Path) -> list[dict[str, str]]:
    """Validate the current path arrangement; publishing is a separate step."""
    pending = [root / package for package in PACKAGES]
    seen: set[Path] = set()
    sources: list[dict[str, str]] = []
    while pending:
        path = pending.pop().resolve()
        if path in seen:
            continue
        seen.add(path)
        manifest = path / "gleam.toml"
        if not manifest.is_file():
            raise ValueError(
                f"missing package: {manifest}; check out the required sibling"
            )
        package = tomllib.loads(manifest.read_text())
        sources.append({
            "package": package["name"], "version": package["version"], "path": str(path),
        })
        for section in ("dependencies", "dev-dependencies"):
            for name, value in package.get(section, {}).items():
                if isinstance(value, dict) and "path" in value:
                    dependency = (path / value["path"]).resolve()
                    dependency_manifest = dependency / "gleam.toml"
                    if not dependency_manifest.is_file():
                        raise ValueError(
                            f"{package['name']} needs {name} at {dependency}; "
                            "check out the required sibling"
                        )
                    if tomllib.loads(dependency_manifest.read_text())["name"] != name:
                        raise ValueError(f"{dependency}: expected package {name}")
                    pending.append(dependency)
    return sources


def run_checks(root: Path, selected: list[Check], logs: Path) -> bool:
    environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    for name in (
        "OPENAI_API_KEY", "TYPESAFE_API_KEY",
        "FABRIC_DECISION_MODEL", "FABRIC_CLASSIFIER_MODEL",
    ):
        environment.pop(name, None)
    results = []
    (logs / "results.json").write_text("[]\n")
    for check in selected:
        print(f"Checking {check.name}", flush=True)
        started = time.monotonic()
        with (logs / f"{check.name}.log").open("w") as output:
            try:
                result = subprocess.run(
                    check.command, cwd=root / check.directory, env=environment,
                    stdout=output, stderr=subprocess.STDOUT,
                )
                status = result.returncode
            except OSError as error:
                output.write(str(error) + "\n")
                status = 127
        results.append({
            "name": check.name, "command": check.command,
            "directory": check.directory, "exit_code": status,
            "seconds": round(time.monotonic() - started, 3),
        })
        (logs / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if status:
            print(f"FAILED: {check.name}; see {logs / (check.name + '.log')}", flush=True)
            print((logs / f"{check.name}.log").read_text()[-12000:], flush=True)
            return False
    print(f"Passed {len(results)} checks. Evidence: {logs}", flush=True)
    return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=("fast", "full", "ci", "recipe", "saga-recipe"))
    parser.add_argument("--logs", type=Path, default=ROOT / ".artifacts/check")
    arguments = parser.parse_args()
    if arguments.profile in ("recipe", "saga-recipe"):
        try:
            problems = recipe_problems(ROOT, **(SAGA_RECIPE if arguments.profile == "saga-recipe" else {}))
        except (ValueError, OSError) as error:
            problems = [str(error)]
        for problem in problems:
            print(problem, flush=True)
        if not problems:
            print("the recipe is the same in the README, the module doc and the consumer")
        raise SystemExit(1 if problems else 0)
    logs = arguments.logs.resolve()
    logs.mkdir(parents=True, exist_ok=True)
    # Reset the result before preflight too: an old green must never describe
    # a new invocation that could not even find its dependencies.
    (logs / "results.json").write_text("[]\n")
    try:
        selected = checks(ROOT, arguments.profile)
        sources = dependencies(ROOT)
    except (ValueError, OSError, KeyError) as error:
        (logs / "preflight.log").write_text(str(error) + "\n")
        print(f"FAILED preflight: {error}", flush=True)
        raise SystemExit(1) from error
    (logs / "dependencies.json").write_text(json.dumps(sources, indent=2) + "\n")
    passed = run_checks(ROOT, selected, logs)
    raise SystemExit(0 if passed else 1)


if __name__ == "__main__":
    main()
