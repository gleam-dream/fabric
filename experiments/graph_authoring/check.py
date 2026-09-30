#!/usr/bin/env python3
"""Run the authoring proof, its external consumer and negative type checks."""

import json
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent
BLUEPRINT = (ROOT / "../../../json_blueprint").resolve()


def run(directory: Path, *arguments: str) -> None:
    subprocess.run(["gleam", *arguments], cwd=directory, check=True)


def check_types() -> None:
    # A fresh external package prevents a stale artifact or missing dependency
    # from masquerading as proof that the intended type mismatch was rejected.
    with tempfile.TemporaryDirectory(prefix="fabric-graph-types-") as folder:
        project = Path(folder)
        (project / "src").mkdir()
        (project / "gleam.toml").write_text(
            'name = "graph_type_probe"\nversion = "0.0.0"\ntarget = "erlang"\n'
            "[dependencies]\n"
            f"fabric_graph_authoring = {{ path = {json.dumps(str(ROOT))} }}\n"
            f"json_blueprint = {{ path = {json.dumps(str(BLUEPRINT))} }}\n"
        )
        source = '''import fabric_graph_authoring as graph
import json/blueprint/codec

pub fn checked() -> graph.Node(Nil, Int, String) {
  let assert Ok(id) = graph.node_id("typed")
  let work = graph.operation(
    graph.Identity("work", 1), codec.int(), codec.string(),
    fn(_, _input) { Ok("answer") },
    fn(_error: Nil) { graph.DefiniteFailure("unreachable") },
  )
  graph.node(id, work,
    select: fn(state) { Ok(state) },
    accept: fn(state, output) { Ok(graph.Finish(state, output)) },
    destinations: [],
  )
}
'''
        probe = project / "src/graph_type_probe.gleam"
        probe.write_text(source)
        run(project, "build", "--warnings-as-errors")
        cases = {
            "input projection": source.replace(
                "select: fn(state) { Ok(state) }",
                'select: fn(_state) { Ok("wrong input type") }',
            ),
            "result acceptance": source.replace(
                "accept: fn(state, output)",
                "accept: fn(state, output: Int)",
            ),
        }
        for name, invalid in cases.items():
            probe.write_text(invalid)
            result = subprocess.run(
                ["gleam", "build", "--warnings-as-errors"],
                cwd=project,
                capture_output=True,
                text=True,
            )
            diagnostic = result.stdout + result.stderr
            if result.returncode == 0 or "Type mismatch" not in diagnostic:
                raise RuntimeError(f"{name}: expected a type mismatch\n{diagnostic}")
            print(f"Compiler correctly rejected {name}", flush=True)


def main() -> None:
    for directory in (ROOT, ROOT / "consumer"):
        run(directory, "format", "--check", "src", "test")
        run(directory, "build", "--warnings-as-errors")
        run(directory, "test")
    run(ROOT / "consumer", "run")
    check_types()


if __name__ == "__main__":
    main()
