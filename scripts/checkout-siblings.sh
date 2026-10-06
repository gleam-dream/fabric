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

if [[ -z ${SIBLINGS_TOKEN:-} ]]; then
  echo "private sibling checkout requires vars.SIBLINGS_APP_CLIENT_ID with secrets.SIBLINGS_APP_PRIVATE_KEY, or secrets.SIBLINGS_READ_TOKEN" >&2
  exit 1
fi

# Authentication exists only on the fetch invocation, never in Git config.
unset GIT_TRACE GIT_TRACE_CURL GIT_CURL_VERBOSE
encoded="$(printf 'x-access-token:%s' "$SIBLINGS_TOKEN" | base64 -w 0)"
header=(-c "http.https://github.com/.extraheader=AUTHORIZATION: basic $encoded")
for package in http_gun json_blueprint llm_wire sinal saga relay warden; do
  revision="${revisions[$package]}"
  owner=gleam-dream
  auth=("${header[@]}")
  if [[ $package == json_blueprint ]]; then
    owner=lostbean
    auth=()
  fi
  destination="$workspace/$package"
  if [[ -e $destination ]]; then
    echo "refusing to replace existing sibling: $package" >&2
    exit 1
  fi
  git init --quiet "$destination"
  git -C "$destination" remote add origin "https://github.com/$owner/$package.git"
  git "${auth[@]}" -C "$destination" fetch --quiet --depth 1 origin "$revision"
  git -C "$destination" checkout --quiet --detach FETCH_HEAD
  test "$(git -C "$destination" rev-parse HEAD)" = "$revision"
  printf '%s %s\n' "$package" "$revision"
done
