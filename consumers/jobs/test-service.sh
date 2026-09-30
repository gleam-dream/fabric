#!/usr/bin/env bash
# Owns a temporary service and database; never connects to a configured service.
set -euo pipefail
cd "$(dirname "$0")"
export PYTHONDONTWRITEBYTECODE=1
python3 -m unittest discover -s service -p "test_*.py"
job_tmp="$(mktemp -d "${TMPDIR:-/tmp}/fabric-jobs.XXXXXX")"
service_pid=""
cleanup() {
  if [[ -n "$service_pid" ]]; then
    kill "$service_pid" 2>/dev/null || true
    wait "$service_pid" 2>/dev/null || true
  fi
  rm -rf "$job_tmp"
}
trap cleanup EXIT
python3 service/server.py --directory "$job_tmp/service" --ready-file "$job_tmp/ready" >"$job_tmp/service.log" 2>&1 &
service_pid=$!
for _ in {1..100}; do
  if [[ -f "$job_tmp/ready" ]]; then break; fi
  if ! kill -0 "$service_pid" 2>/dev/null; then cat "$job_tmp/service.log"; exit 1; fi
  sleep 0.05
done
export FABRIC_JOBS_URL="$(cat "$job_tmp/ready")"
export FABRIC_JOBS_TMP="$job_tmp"
gleam build --warnings-as-errors
gleam test
