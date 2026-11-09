#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Samaritan's Purse
# tests/test-board.sh — Shared workboard mounts (sandbox run --board). Cluster-free.
#
# Covers lib/board.sh and its manifest wiring:
#   1. board_configure validation: no-op without --board; --board-state/--role
#      need --board; Tier 3 refused; the definition must look like an
#      agent-workboards checkout and carry no masked secret files; neither path
#      may be /, $HOME, a parent of $HOME, or overlap a sensitive path
#      (~/.ssh, ~/.sandbox/secrets, ...); board/state/repos must not overlap;
#      roles must be persona names that exist (or 'gate').
#   2. The rendered pod mounts the definition READ-ONLY at /workboard and the
#      state read-write at /workboard-state, with WB_* identity env, and emits
#      nothing board-related without --board.
#   3. The boot prompt reaches each agent's launch argv in its supported form.
#   4. board_record_session persists the config into session.json.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

SANDBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/sandbox-board-test-XXXXXX)"
HOME="${TEST_DIR}/home"; mkdir -p "${HOME}"
SANDBOX_NAMESPACE="sandbox"
SANDBOX_SERVICE_ACCOUNT="sandbox-runner"
cleanup() { rm -rf "${TEST_DIR}"; }
trap cleanup EXIT

source "${SANDBOX_ROOT}/lib/platform.sh"
source "${SANDBOX_ROOT}/lib/resources.sh"
source "${SANDBOX_ROOT}/lib/config.sh"
source "${SANDBOX_ROOT}/lib/profile.sh"
source "${SANDBOX_ROOT}/lib/filesystem.sh"
source "${SANDBOX_ROOT}/lib/agents.sh"
source "${SANDBOX_ROOT}/lib/manifest.sh"
SANDBOX_BOARD_STATE_DEFAULT="${HOME}/.sandbox/board"
source "${SANDBOX_ROOT}/lib/board.sh"

eval "detect_platform() { echo linux; }"
die() { echo "DIE: $*" >&2; exit 1; }

eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "${expected}" == "${actual}" ]]; then pass "${label}"
  else fail "${label}: expected '${expected}', got '${actual}'"; fi
}
# refuses <label> <expected stderr fragment> <args...> — board_configure must die.
refuses() {
  local label="$1" frag="$2" err
  shift 2
  if err="$( (board_configure "$@") 2>&1 >/dev/null)"; then
    fail "${label}: board_configure accepted"
  fi
  case "${err}" in
    *"${frag}"*) pass "${label}" ;;
    *) fail "${label}: expected '${frag}' in: ${err}" ;;
  esac
}

# Fixture: a minimal agent-workboards checkout and a project repo.
BOARD="${HOME}/agent-workboards"
mkdir -p "${BOARD}/bin" "${BOARD}/.ai/personas"
: > "${BOARD}/AGENTS.md"; : > "${BOARD}/bin/wb"
: > "${BOARD}/.ai/personas/developer.md"; : > "${BOARD}/.ai/personas/tester.md"
REPO="${HOME}/repos/app"; mkdir -p "${REPO}/.git"
STATE="${HOME}/boards/team"

###############################################################################
test_configure_validation() {
  info "Testing board_configure validation..."
  board_configure 2 "" "" ""
  eq "no --board is a no-op" "" "${SESSION_BOARD_DIR}"

  refuses "--board-state needs --board" "need --board" 2 "" "${STATE}" ""
  refuses "--role needs --board" "need --board" 2 "" "" developer
  refuses "tier 3 refused" "not supported on Tier 3" 3 "${BOARD}" "" ""
  refuses "missing dir refused" "not a directory" 2 "${HOME}/nope" "" ""
  mkdir -p "${HOME}/notaboard"
  refuses "non-workboards dir refused" "doesn't look like" 2 "${HOME}/notaboard" "" ""
  refuses "state == board refused" "must not overlap" 2 "${BOARD}" "${BOARD}" ""
  refuses "state inside board refused" "must not overlap" 2 "${BOARD}" "${BOARD}/state" ""
  refuses "state == HOME refused" "home directory" 2 "${BOARD}" "${HOME}" ""
  refuses "state = / refused" "cannot be '/'" 2 "${BOARD}" "/" ""
  refuses "state containing HOME refused" "contains your home" 2 "${BOARD}" "$(dirname "${HOME}")" ""
  refuses "state = ~/.ssh refused" "sensitive path" 2 "${BOARD}" "${HOME}/.ssh" ""
  refuses "state = ~/.sandbox (holds secrets/logs) refused" "sensitive path" 2 "${BOARD}" "${HOME}/.sandbox" ""
  refuses "state inside agent-home refused" "sensitive path" 2 "${BOARD}" "${HOME}/.sandbox/agent-home/claude/b" ""
  refuses "repo overlapping board refused" "overlaps --board" 2 "${BOARD}" "${STATE}" "" "${BOARD}"
  refuses "repo containing state refused" "overlaps --board-state" 2 "${BOARD}" "${REPO}/board" "" "${REPO}"
  refuses "bad role syntax refused" "comma-separated" 2 "${BOARD}" "${STATE}" "Dev;rm"
  refuses "unknown persona refused" "no persona" 2 "${BOARD}" "${STATE}" "developer,wizard"

  : > "${BOARD}/.env"
  refuses "board with masked secret file refused" "masks as sensitive" 2 "${BOARD}" "${STATE}" ""
  rm -f "${BOARD}/.env"

  board_configure 2 "${BOARD}" "" "" "${REPO}"
  eq "default state dir" "${HOME}/.sandbox/board" "${SESSION_BOARD_STATE}"

  board_configure 2 "~/agent-workboards" "${STATE}" "developer,gate" "${REPO}"
  eq "tilde expanded + canonical board" "${BOARD}" "${SESSION_BOARD_DIR}"
  eq "state node path (linux) == state" "${STATE}" "${SESSION_BOARD_STATE_NODE}"
  eq "role kept" "developer,gate" "${SESSION_BOARD_ROLE}"

  board_configure 1 "${BOARD}" "${STATE}" ""
  eq "tier 1 allowed" "${BOARD}" "${SESSION_BOARD_DIR}"
}

###############################################################################
test_manifest() {
  info "Testing pod manifest board mounts and env..."
  board_configure 2 "${BOARD}" "${STATE}" "developer" "${REPO}"
  local man
  man="$(build_pod_manifest ses-20260101-000000-abcd claude 2 img name user "" pod-x "" "" "" "${REPO}")"
  printf '%s\n' "${man}" | yq -e '.' >/dev/null || fail "board manifest is not valid YAML"
  pass "board manifest is valid YAML"

  local q='.spec.containers[0].volumeMounts[] | select(.name == "workboard")'
  eq "definition mounted at /workboard" "/workboard" "$(printf '%s\n' "${man}" | yq -r "${q} | .mountPath")"
  eq "definition mount is readOnly" "true" "$(printf '%s\n' "${man}" | yq -r "${q} | .readOnly")"
  q='.spec.containers[0].volumeMounts[] | select(.name == "workboard-state")'
  eq "state mounted at /workboard-state" "/workboard-state" "$(printf '%s\n' "${man}" | yq -r "${q} | .mountPath")"
  eq "state mount is writable" "null" "$(printf '%s\n' "${man}" | yq -r "${q} | .readOnly")"
  eq "definition hostPath" "${BOARD}" \
    "$(printf '%s\n' "${man}" | yq -r '.spec.volumes[] | select(.name == "workboard") | .hostPath.path')"
  eq "state hostPath" "${STATE}" \
    "$(printf '%s\n' "${man}" | yq -r '.spec.volumes[] | select(.name == "workboard-state") | .hostPath.path')"
  local envq='.spec.containers[0].env[] | select(.name == "%s") | .value'
  # shellcheck disable=SC2059
  eq "WB_AGENT" "claude" "$(printf '%s\n' "${man}" | yq -r "$(printf "${envq}" WB_AGENT)")"
  # shellcheck disable=SC2059
  eq "WB_SESSION" "ses-20260101-000000-abcd" "$(printf '%s\n' "${man}" | yq -r "$(printf "${envq}" WB_SESSION)")"
  # shellcheck disable=SC2059
  eq "WB_ROLE" "developer" "$(printf '%s\n' "${man}" | yq -r "$(printf "${envq}" WB_ROLE)")"
  # shellcheck disable=SC2059
  eq "WB_HOME" "/workboard" "$(printf '%s\n' "${man}" | yq -r "$(printf "${envq}" WB_HOME)")"

  board_configure 2 "" "" ""
  man="$(build_pod_manifest ses-1 claude 2 img name user "" pod-x "" "" "" "${REPO}")"
  case "${man}" in
    *workboard*|*WB_*) fail "no-board manifest mentions the board" ;;
    *) pass "no board mounts/env without --board" ;;
  esac
}

###############################################################################
test_boot_prompt() {
  info "Testing boot prompt launch args..."
  board_configure 2 "${BOARD}" "${STATE}" ""
  local p; p="$(board_boot_prompt)"
  case "${p}" in *"/workboard/bin/wb boot"*) pass "prompt names wb boot" ;; *) fail "prompt: ${p}" ;; esac
  local -a a=()
  read_into_array a < <(get_agent_initial_prompt_args claude "${p}")
  eq "claude: one positional arg" "1" "${#a[@]}"
  read_into_array a < <(get_agent_initial_prompt_args opencode "${p}")
  eq "opencode: --prompt flag" "--prompt" "${a[0]}"
  read_into_array a < <(get_agent_initial_prompt_args copilot "${p}")
  eq "copilot: -i flag" "-i" "${a[0]}"
  read_into_array a < <(get_agent_initial_prompt_args grok "${p}")
  eq "grok: not wired (banner tells the operator)" "0" "${#a[@]}"
  board_configure 2 "" "" ""
  eq "no board, no prompt" "" "$(board_boot_prompt)"
}

###############################################################################
test_record_session() {
  info "Testing board_record_session..."
  local ld="${TEST_DIR}/log"; mkdir -p "${ld}"
  echo '{"session_id":"ses-1"}' > "${ld}/session.json"
  board_configure 2 "${BOARD}" "${STATE}" "tester"
  board_record_session "${ld}"
  eq "session.json board" "${BOARD}" "$(jq -r .board "${ld}/session.json")"
  eq "session.json board_state" "${STATE}" "$(jq -r .board_state "${ld}/session.json")"
  eq "session.json board_role" "tester" "$(jq -r .board_role "${ld}/session.json")"
  eq "session.json keeps existing keys" "ses-1" "$(jq -r .session_id "${ld}/session.json")"
}

test_configure_validation
test_manifest
test_boot_prompt
test_record_session
echo "All board tests passed."
