#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Samaritan's Purse
# lib/board.sh — Optional shared workboard mounts (sandbox run --board).
#
# A workboard lets several sandboxes (different agents/models, different roles)
# coordinate through a file-based task board — see the agent-workboards project
# and docs/how-to/workboards.md. Two mounts, deliberately split by trust:
#
#   /workboard        the board DEFINITION (rules, personas, the `wb` CLI, gate
#                     scripts). Operator-owned instructions that every agent
#                     loads, so it is mounted READ-ONLY: an agent must not be
#                     able to rewrite the persona or gate another agent will run.
#   /workboard-state  the board STATE (tasks, verdicts, notes, git bundles).
#                     Read-write and SHARED by every session launched with the
#                     same state dir. It is an intentional, operator-opted-in
#                     data channel between sessions; its contents are
#                     agent-written and untrusted (see the security notes in
#                     docs/how-to/workboards.md).
#
# Nothing here touches the network policy: the board is filesystem-only.

SANDBOX_BOARD_MOUNT="/workboard"
SANDBOX_BOARD_STATE_MOUNT="/workboard-state"
SANDBOX_BOARD_STATE_DEFAULT="${SANDBOX_BOARD_STATE_DEFAULT:-${HOME}/.sandbox/board}"
# macOS: state lives VM-local (ext4) so every pod in the VM shares ONE directory
# with working atomic renames. The 9p-shared Mac home can't be written by the
# pod's uid (see SANDBOX_VM_AGENT_HOME_BASE in lib/platform.sh), and the
# per-session Mutagen copies used for workspaces would give each session its own
# copy — fatal for a coordination board.
SANDBOX_VM_BOARD_BASE="${SANDBOX_VM_BOARD_BASE:-/var/lib/sandbox/board}"

# Session-scoped values the manifest builder reads (set by board_configure).
SESSION_BOARD_DIR=""         # host/node path of the definition (read-only mount)
SESSION_BOARD_STATE=""       # operator-facing state path (as given / defaulted)
SESSION_BOARD_STATE_NODE=""  # node path the pod mounts (== STATE on Linux)
SESSION_BOARD_ROLE=""

# _board_realpath <path> — canonical absolute path (path may not exist yet; its
# nearest existing ancestor is canonicalised and the rest appended).
_board_realpath() {
  local p="$1" rest=""
  [[ "${p}" == /* ]] || p="${PWD}/${p}"
  while [[ ! -e "${p}" ]]; do
    rest="/$(basename "${p}")${rest}"
    p="$(dirname "${p}")"
  done
  if [[ -d "${p}" ]]; then
    p="$(cd "${p}" && pwd -P)"
  else
    p="$(cd "$(dirname "${p}")" && pwd -P)/$(basename "${p}")"
  fi
  p="${p%/}${rest}"
  printf '%s\n' "${p:-/}"
}

# _board_overlaps <a> <b> — true when a == b or one contains the other.
_board_overlaps() {
  local a="${1%/}/" b="${2%/}/"
  [[ "${a}" == "${b}" || "${a}" == "${b}"* || "${b}" == "${a}"* ]]
}

# _board_sensitive_paths — host paths a board mount must never equal or contain:
# credentials, the sandbox's own operator-side state (logs, secrets, kubeconfig),
# the agent-homes, and the agent-sandboxes checkout itself.
_board_sensitive_paths() {
  printf '%s\n' \
    "${HOME}/.ssh" "${HOME}/.aws" "${HOME}/.kube" "${HOME}/.gnupg" \
    "${HOME}/.config" "${HOME}/.docker" "${HOME}/.netrc" \
    "${HOME}/.sandbox/secrets" "${HOME}/.sandbox/logs" "${HOME}/.sandbox/kubeconfig" \
    "${HOME}/.sandbox/agent-home" "${HOME}/.sandbox/profiles" "${HOME}/.sandbox/config.yaml"
  [[ -n "${SANDBOX_ROOT:-}" ]] && printf '%s\n' "${SANDBOX_ROOT}"
  [[ -n "${SANDBOX_AGENT_HOME_OVERRIDE:-}" ]] && printf '%s\n' "${SANDBOX_AGENT_HOME_OVERRIDE}"
  return 0
}

# _board_check_path <label> <canonical path> — refuse "/", $HOME, and any path
# that contains (or sits inside) a sensitive path.
_board_check_path() {
  local label="$1" p="$2" s home
  home="$(_board_realpath "${HOME}")"
  [[ "${p}" != "/" ]] || die "${label} cannot be '/'."
  [[ "${p}" != "${home}" ]] || die "${label} cannot be your home directory."
  # Containing $HOME (e.g. /home) is as bad as being it.
  [[ "${home}/" != "${p%/}/"* ]] || die "${label} '${p}' contains your home directory."
  while IFS= read -r s; do
    [[ -n "${s}" ]] || continue
    s="$(_board_realpath "${s}")"
    if _board_overlaps "${p}" "${s}"; then
      die "${label} '${p}' overlaps sensitive path '${s}'. Use a dedicated directory."
    fi
  done < <(_board_sensitive_paths)
}

# board_configure <tier> <board_dir> <state_dir> <role> [repo...]
# Validate --board/--board-state/--role and set SESSION_BOARD_*. A no-op (all
# empty) when board_dir is empty; --board-state/--role without --board is an error.
board_configure() {
  local tier="$1" board="$2" state="$3" role="$4"
  shift 4
  local -a repos=("$@")
  SESSION_BOARD_DIR="" SESSION_BOARD_STATE="" SESSION_BOARD_STATE_NODE="" SESSION_BOARD_ROLE=""

  if [[ -z "${board}" ]]; then
    [[ -z "${state}" && -z "${role}" ]] \
      || die "--board-state / --role need --board <workboards checkout>."
    return 0
  fi

  # Tier 3 sessions hold infra credentials. A shared board is a data channel to
  # every other session on it (possibly other vendors' models), so refuse rather
  # than make credential exfiltration across sessions a one-flag affair.
  [[ "${tier}" -lt 3 ]] \
    || die "--board is not supported on Tier 3: a shared board would let a session holding infra credentials pass data to every other session on the board."

  board="${board/#\~/${HOME}}"
  state="${state/#\~/${HOME}}"
  [[ -d "${board}" ]] || die "--board '${board}' is not a directory."
  board="$(_board_realpath "${board}")"
  [[ -f "${board}/AGENTS.md" && -f "${board}/bin/wb" ]] \
    || die "--board '${board}' doesn't look like an agent-workboards checkout (needs AGENTS.md and bin/wb)."
  _board_check_path "--board" "${board}"

  # The definition is read by every agent on the board: refuse obvious secret
  # files at its top level rather than mount them into every session.
  local f
  for f in "${MASKED_FILE_PATHS[@]}"; do
    [[ ! -e "${board}/${f}" ]] \
      || die "--board '${board}' contains '${f}', a file the sandbox masks as sensitive. Remove it from the board checkout."
  done

  [[ -n "${state}" ]] || state="${SANDBOX_BOARD_STATE_DEFAULT}"
  state="$(_board_realpath "${state}")"
  _board_check_path "--board-state" "${state}"
  _board_overlaps "${board}" "${state}" \
    && die "--board-state '${state}' must not overlap --board '${board}' (the definition must stay read-only)."

  # A repo mounted read-write must not overlap either board path: through the
  # workspace an agent could rewrite the read-only definition, or reach state
  # outside the board.
  local r rc
  for r in "${repos[@]+"${repos[@]}"}"; do
    rc="$(_board_realpath "${r}")"
    _board_overlaps "${rc}" "${board}" \
      && die "--repo '${r}' overlaps --board '${board}'. Mount the board only via --board (read-only)."
    _board_overlaps "${rc}" "${state}" \
      && die "--repo '${r}' overlaps --board-state '${state}'."
  done

  if [[ -n "${role}" ]]; then
    [[ "${role}" =~ ^[a-z0-9][a-z0-9-]*(,[a-z0-9][a-z0-9-]*)*$ ]] \
      || die "--role '${role}' must be a comma-separated list of persona names (a-z, 0-9, -)."
    local rr
    local -a _roles=()
    IFS=',' read -ra _roles <<< "${role}"
    for rr in "${_roles[@]}"; do
      [[ "${rr}" == "gate" || -f "${board}/.ai/personas/${rr}.md" ]] \
        || die "--role '${rr}': no persona ${board}/.ai/personas/${rr}.md"
    done
  fi

  if is_macos; then
    # The definition is read straight off the 9p-shared Mac home (read-only
    # access works there; only writes by the pod uid fail). Outside $HOME there
    # is no mount in the VM.
    [[ "${board}/" == "$(_board_realpath "${HOME}")/"* ]] \
      || die "--board must live under your home directory on macOS (only \$HOME is shared into the VM)."
    SESSION_BOARD_STATE_NODE="${SANDBOX_VM_BOARD_BASE}/$(basename "${state}")"
  else
    SESSION_BOARD_STATE_NODE="${state}"
  fi
  SESSION_BOARD_DIR="${board}"
  SESSION_BOARD_STATE="${state}"
  SESSION_BOARD_ROLE="${role}"
}

# board_prepare_state — create the state dir the pod mounts. Linux/WSL: a host
# dir owned by the operator (the pod runs as the operator's uid, so it can write
# it). macOS: a VM-local ext4 dir owned by uid 1000 (the pod uid there).
board_prepare_state() {
  [[ -n "${SESSION_BOARD_DIR}" ]] || return 0
  if is_macos; then
    limactl shell "${LIMA_VM_NAME}" -- sudo install -d -m 0770 -o 1000 -g 1000 \
      "${SESSION_BOARD_STATE_NODE}" \
      || die "could not create board state ${SESSION_BOARD_STATE_NODE} in ${LIMA_VM_NAME}"
  else
    mkdir -p "${SESSION_BOARD_STATE_NODE}" \
      || die "could not create board state ${SESSION_BOARD_STATE_NODE}"
    chmod 0770 "${SESSION_BOARD_STATE_NODE}" 2>/dev/null || true
  fi
}

# board_volumes_block / board_mounts_block / board_env_block — manifest
# fragments (empty when no board). Indentation matches lib/manifest.sh.
board_volumes_block() {
  [[ -n "${SESSION_BOARD_DIR}" ]] || return 0
  cat <<EOF
    - name: workboard
      hostPath:
        path: "${SESSION_BOARD_DIR}"
        type: Directory
    - name: workboard-state
      hostPath:
        path: "${SESSION_BOARD_STATE_NODE}"
        type: Directory
EOF
}

board_mounts_block() {
  [[ -n "${SESSION_BOARD_DIR}" ]] || return 0
  cat <<EOF
        - name: workboard
          mountPath: ${SANDBOX_BOARD_MOUNT}
          readOnly: true
        - name: workboard-state
          mountPath: ${SANDBOX_BOARD_STATE_MOUNT}
EOF
}

# board_env_block <agent> <session_id> — WB_* identity for the `wb` CLI. The
# operator sets these at launch; the agent can change its own shell env, which
# only changes how it labels itself on the board (the board is cooperative
# coordination, not an authorization boundary — see the how-to).
board_env_block() {
  [[ -n "${SESSION_BOARD_DIR}" ]] || return 0
  local agent="$1" session_id="$2"
  cat <<EOF
        - name: WB_HOME
          value: "${SANDBOX_BOARD_MOUNT}"
        - name: WB_STATE
          value: "${SANDBOX_BOARD_STATE_MOUNT}"
        - name: WB_HOST_STATE
          value: "${SESSION_BOARD_STATE_NODE}"
        - name: WB_AGENT
          value: "${agent}"
        - name: WB_SESSION
          value: "${session_id}"
EOF
  [[ -z "${SESSION_BOARD_ROLE}" ]] || cat <<EOF
        - name: WB_ROLE
          value: "${SESSION_BOARD_ROLE}"
EOF
}

# board_boot_prompt — the operator-authored first message that tells the agent
# to load its profile from the board. Empty when no board.
board_boot_prompt() {
  [[ -n "${SESSION_BOARD_DIR}" ]] || return 0
  printf 'You are attached to a shared workboard. Run `%s/bin/wb boot` now and follow what it prints: it loads your rules and persona and shows the work waiting for your role(s).' \
    "${SANDBOX_BOARD_MOUNT}"
}

# board_audit_summary — one line for the session audit log.
board_audit_summary() {
  [[ -n "${SESSION_BOARD_DIR}" ]] || return 0
  printf 'definition=%s (ro) state=%s (rw, shared) role=%s' \
    "${SESSION_BOARD_DIR}" "${SESSION_BOARD_STATE_NODE}" "${SESSION_BOARD_ROLE:-default}"
}

# board_record_session <log_dir> — persist the board config in session.json
# (operator-side, outside the agent's reach) so resume can refuse to rebuild a
# board session silently and print the exact relaunch command instead.
board_record_session() {
  [[ -n "${SESSION_BOARD_DIR}" ]] || return 0
  local sj="$1/session.json" tmp
  [[ -f "${sj}" ]] || return 0
  tmp="$(mktemp)"
  if jq --arg d "${SESSION_BOARD_DIR}" --arg s "${SESSION_BOARD_STATE}" --arg r "${SESSION_BOARD_ROLE}" \
      '.board = $d | .board_state = $s | .board_role = $r' "${sj}" > "${tmp}"; then
    mv "${tmp}" "${sj}"
  else
    rm -f "${tmp}"
  fi
}
