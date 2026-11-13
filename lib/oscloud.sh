#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Samaritan's Purse
# lib/oscloud.sh — Host-side --os-cloud handling for Tier 3 sessions.
#
# Extracts only the named cloud(s) from a clouds.yaml (and a matching
# secure.yaml next to it) into a 0700 temp dir, copies cacert/cert/key
# files, and rewrites those paths to the in-pod mount. The temp dir is
# packed into a per-session Secret and torn down with the session,
# matching --infra-kubeconfig.
#
# The agent sees:
#   /home/agent/.config/openstack/clouds.yaml   (and any carried CA/cert files)
#   OS_CLIENT_CONFIG_FILE  — that clouds.yaml
#   OS_CLOUD               — set only when exactly one --os-cloud is given
set -euo pipefail

OS_CLOUD_MOUNT_DIR="/home/agent/.config/openstack"
OSCLOUD_PY="${SANDBOX_ROOT}/lib/oscloud.py"

# os_cloud_run_py — run the helper; forwards remaining args. stdout is the
# helper's stdout; stderr is left alone. Returns the helper's exit status.
os_cloud_run_py() {
  python3 "${OSCLOUD_PY}" "$@"
}

# os_cloud_prepare — extract named clouds into <dest_dir> (0700).
# Signature: os_cloud_prepare <dest_dir> <clouds_file_or_empty> <cloud> [cloud ...]
# Writes dest/clouds.yaml, dest/meta.json, and any carried cert files.
# Dies (via the helper's ERROR: on stderr) on refusal or a missing cloud.
os_cloud_prepare() {
  local dest="$1"
  local clouds_file="${2:-}"
  shift 2
  command -v python3 >/dev/null 2>&1     || die "--os-cloud requires python3 on the host."
  local -a args=(extract --mount-dir "${OS_CLOUD_MOUNT_DIR}" --write-dir "${dest}" --cwd "${PWD}" --home "${HOME}")
  [[ -n "${clouds_file}" ]] && args+=(--os-clouds-file "${clouds_file}")
  args+=("$@")
  local err
  err="$(mktemp)"
  if ! os_cloud_run_py "${args[@]}" >"${dest}/.extract.out" 2>"${err}"; then
    local msg
    msg="$(sed 's/^ERROR: //' "${err}" | tr '\n' ' ')"
    rm -f "${err}" "${dest}/.extract.out"
    die "${msg:-failed to extract --os-cloud}"
  fi
  rm -f "${err}" "${dest}/.extract.out"
}

# os_cloud_meta — print a field from dest/meta.json (clouds, auth_urls, os_cloud).
# clouds and auth_urls are printed one per line.
os_cloud_meta() {
  local dest="$1"
  local field="$2"
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
v=d.get(sys.argv[2])
if isinstance(v, list):
    for x in v:
        print(x)
else:
    print(v or "")
' "${dest}/meta.json" "${field}"
}

# create_os_cloud_secret — pack the extracted dir into a K8s Secret.
# Signature: create_os_cloud_secret <session_id> <extract_dir>
# The Secret's keys are the filenames (clouds.yaml, cacert-0.pem, ...).
create_os_cloud_secret() {
  local session_id="$1"
  local extract_dir="$2"
  local secret_name="os-cloud-${session_id}"

  local -a from_file=()
  local f
  for f in "${extract_dir}"/*; do
    [[ -f "${f}" ]] || continue
    case "$(basename "${f}")" in
      meta.json|.*) continue ;;
    esac
    from_file+=("--from-file=$(basename "${f}")=${f}")
  done
  [[ "${#from_file[@]}" -gt 0 ]] || die "internal error: nothing to store in ${secret_name}"

  kubectl create secret generic "${secret_name}" \
    --namespace "${SANDBOX_NAMESPACE}" \
    "${from_file[@]}" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "  Created secret: ${secret_name}"
}

# delete_os_cloud_secret — remove the per-session OpenStack Secret.
delete_os_cloud_secret() {
  local session_id="$1"
  kubectl delete secret -n "${SANDBOX_NAMESPACE}" \
    "os-cloud-${session_id}" --ignore-not-found=true 2>&1 || true
}

# os_cloud_secret_name — print the Secret name for a session.
os_cloud_secret_name() {
  echo "os-cloud-$1"
}
