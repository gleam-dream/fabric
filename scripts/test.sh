#!/usr/bin/env bash
# Run application tests in the repository's Nix development shell.
set -euo pipefail
cd "$(dirname "$0")/.."
native_output="$(mktemp -d)"
trap 'rm -rf "$native_output"' EXIT
unset OPENAI_API_KEY TYPESAFE_API_KEY FABRIC_DECISION_MODEL FABRIC_CLASSIFIER_MODEL
export PYTHONDONTWRITEBYTECODE=1
for package in . consumers/saga_tool integrations/fabric_postgres consumers/relay_tools \
  consumers/app consumers/graph consumers/decision consumers/jobs consumers/writing \
  consumers/approvers_warden examples/usage experiments/workflow_composition; do (
    cd "$package"
    gleam build --warnings-as-errors
    includes=()
    for directory in build/dev/erlang/*/include; do includes+=(-I "$directory"); done
    export ERL_LIBS="$PWD/build/dev/erlang"
    find src test -name '*.erl' -exec erlc -Werror "${includes[@]}" -o "$native_output" {} +
    case "$package" in
    integrations/fabric_postgres) bash scripts/test-postgres.sh ;;
    consumers/jobs) bash test-service.sh ;;
    *) gleam test ;;
    esac
  ) done
python3 -B -m unittest discover -s test/fixtures/classifier -p '*_test.py'
(cd consumers/writing && python3 -B -m unittest discover -p test_live.py)
python3 -B experiments/graph_authoring/check.py
