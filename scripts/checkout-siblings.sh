#!/usr/bin/env bash
# Validate the complete pin set before fetching any required sibling source.
set -euo pipefail
fabric_root="$(cd "$(dirname "$0")/.." && pwd)"
workspace="$(dirname "$fabric_root")"
declare -A revisions=()
while IFS='=' read -r package revision extra; do
  [[ -z $package || $package == \#* ]] && continue
  if [[ ! $package =~ ^(http_gun|json_blueprint|llm_wire|sinal|saga|relay|warden)$ || ! $revision =~ ^[a-f0-9]{40}$ || -n $extra ]]; then
    echo "invalid sibling revision entry" >&2
    exit 1
  fi
  if [[ -n ${revisions[$package]+present} ]]; then
    echo "duplicate sibling revision: $package" >&2
    exit 1
  fi
  revisions[$package]="$revision"
done <"$fabric_root/sibling-revisions.txt"
for package in http_gun json_blueprint llm_wire sinal saga relay warden; do
  if [[ -z ${revisions[$package]:-} ]]; then
    echo "missing sibling revision: $package" >&2
    exit 1
  fi
done

# Public sibling fetches need no checkout credential or persisted Git header.
unset GIT_TRACE GIT_TRACE_CURL GIT_CURL_VERBOSE
for package in http_gun json_blueprint llm_wire sinal saga relay warden; do
  revision="${revisions[$package]}"
  owner=gleam-dream
  if [[ $package == json_blueprint ]]; then
    owner=lostbean
  fi
  destination="$workspace/$package"
  if [[ -e $destination ]]; then
    echo "refusing to replace existing sibling: $package" >&2
    exit 1
  fi
  git init --quiet "$destination"
  git -C "$destination" remote add origin "https://github.com/$owner/$package.git"
  git -C "$destination" fetch --quiet --depth 1 origin "$revision"
  git -C "$destination" checkout --quiet --detach FETCH_HEAD
  test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
  printf '%s %s\n' "$package" "$revision"
done
