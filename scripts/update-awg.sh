#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSIONS_FILE="${VERSIONS_FILE:-${PROJECT_DIR}/awg-versions.env}"
DOCKER_COMPOSE="${DOCKER_COMPOSE:-sudo docker compose}"

cd "$PROJECT_DIR"

if [[ ! -f "$VERSIONS_FILE" ]]; then
  echo "Missing versions file: $VERSIONS_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
. "$VERSIONS_FILE"

require_var() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "Missing required variable in ${VERSIONS_FILE}: ${name}" >&2
    exit 1
  fi
}

require_var AMNEZIAWG_GO_REPO
require_var AMNEZIAWG_GO_REF
require_var AMNEZIAWG_GO_COMMIT
require_var AMNEZIAWG_TOOLS_REPO
require_var AMNEZIAWG_TOOLS_REF
require_var AMNEZIAWG_TOOLS_COMMIT

resolve_ref() {
  local repo="$1"
  local ref="$2"
  git ls-remote "$repo" "$ref" | awk 'NR == 1 {print $1}'
}

new_go_commit="$(resolve_ref "$AMNEZIAWG_GO_REPO" "$AMNEZIAWG_GO_REF")"
new_tools_commit="$(resolve_ref "$AMNEZIAWG_TOOLS_REPO" "$AMNEZIAWG_TOOLS_REF")"

if [[ -z "$new_go_commit" || -z "$new_tools_commit" ]]; then
  echo "Failed to resolve upstream AmneziaWG refs" >&2
  exit 1
fi

if [[ "$new_go_commit" == "$AMNEZIAWG_GO_COMMIT" && "$new_tools_commit" == "$AMNEZIAWG_TOOLS_COMMIT" ]]; then
  echo "No AmneziaWG update found. Container was not rebuilt or restarted."
  exit 0
fi

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

awk -v go_commit="$new_go_commit" -v tools_commit="$new_tools_commit" '
  BEGIN { go_done=0; tools_done=0 }
  /^AMNEZIAWG_GO_COMMIT=/ {
    print "AMNEZIAWG_GO_COMMIT=" go_commit
    go_done=1
    next
  }
  /^AMNEZIAWG_TOOLS_COMMIT=/ {
    print "AMNEZIAWG_TOOLS_COMMIT=" tools_commit
    tools_done=1
    next
  }
  { print }
  END {
    if (!go_done) print "AMNEZIAWG_GO_COMMIT=" go_commit
    if (!tools_done) print "AMNEZIAWG_TOOLS_COMMIT=" tools_commit
  }
' "$VERSIONS_FILE" > "$tmp_file"

cat "$tmp_file" > "$VERSIONS_FILE"

echo "AmneziaWG update found:"
echo "  amneziawg-go:    ${AMNEZIAWG_GO_COMMIT} -> ${new_go_commit}"
echo "  amneziawg-tools: ${AMNEZIAWG_TOOLS_COMMIT} -> ${new_tools_commit}"

$DOCKER_COMPOSE build --pull awg-relay
$DOCKER_COMPOSE up -d --no-deps --force-recreate awg-relay

echo "AWG relay updated and restarted."
