#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Samaritan's Purse
# tests/test-os-cloud.sh — --os-cloud extraction, manifest, audit, and CLI gates.
#
# Cluster-free. Extraction, secure.yaml merge, cacert rewrite, and the
# library-level manifest/audit checks run against lib/oscloud.py and the
# sourced libraries. CLI checks (--os-cloud on a non-tier-3 session, a
# missing cloud, a blocked auth_url, --board combined with --os-cloud)
# use `sandbox run --dry-run` and fail at input validation, before
# ensure_cluster_ready.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

SANDBOX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/sandbox-os-cloud-XXXXXX)"
HOME="${TEST_DIR}/home"; mkdir -p "${HOME}"
SANDBOX_NAMESPACE="sandbox"
SANDBOX_SERVICE_ACCOUNT="sandbox-runner"
export HOME SANDBOX_ROOT SANDBOX_NAMESPACE SANDBOX_SERVICE_ACCOUNT

cleanup() { rm -rf "${TEST_DIR}"; }
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

source "${SANDBOX_ROOT}/lib/platform.sh"
source "${SANDBOX_ROOT}/lib/resources.sh"
source "${SANDBOX_ROOT}/lib/filesystem.sh"
source "${SANDBOX_ROOT}/lib/policy.sh"
source "${SANDBOX_ROOT}/lib/manifest.sh"
source "${SANDBOX_ROOT}/lib/cluster.sh"
source "${SANDBOX_ROOT}/lib/oscloud.sh"
source "${SANDBOX_ROOT}/lib/agents.sh"
source "${SANDBOX_ROOT}/lib/tier.sh"
source "${SANDBOX_ROOT}/lib/audit.sh"
get_agent_domains() { :; }
get_tier_domains() { :; }
get_blocked_cidrs() { :; }
_normalize_domain() { echo "$1"; }
_apex_is_registrable_domain() { return 1; }
domain_is_blocked() { return 1; }

# Password used only in fixtures — never a real credential. Assertions
# check this string does not leak into session.json / audit / other clouds.
FAKE_PASS_DEMO="fixture-pass-demo-only"
FAKE_PASS_OTHER="fixture-pass-other-must-not-leak"
FAKE_PASS_SECURE="fixture-pass-from-secure"
FAKE_CA="-----BEGIN CERTIFICATE-----
FIXTURE-ONLY
-----END CERTIFICATE-----"

FIXTURE="${TEST_DIR}/os"
mkdir -p "${FIXTURE}"
printf '%s\n' "${FAKE_CA}" > "${FIXTURE}/ca.pem"
cat > "${FIXTURE}/clouds.yaml" <<EOF
clouds:
  demo:
    auth:
      auth_url: https://identity.example.com:5000/v3
      username: demo
      password: ${FAKE_PASS_DEMO}
      project_name: demo
      user_domain_name: Default
      project_domain_name: Default
    region_name: RegionOne
    cacert: ca.pem
  staging:
    auth:
      auth_url: https://identity-staging.example.com:5000/v3
      username: staging
      password: ${FAKE_PASS_OTHER}
      project_name: staging
  oidc:
    auth:
      auth_url: https://idp.example.com:5000/v3
    auth_type: v3oidcauthorizationcode
  vendor:
    profile: some-vendor-profile
EOF
cat > "${FIXTURE}/secure.yaml" <<EOF
clouds:
  demo:
    auth:
      password: ${FAKE_PASS_SECURE}
EOF

# A clouds.yaml whose auth_url is a shipped blocked domain, for the CLI gate.
cat > "${FIXTURE}/blocked-clouds.yaml" <<'EOF'
clouds:
  demo:
    auth:
      auth_url: https://slack.com:5000/v3
      username: demo
      password: fixture-blocked-only
      project_name: demo
EOF

# --- helpers ---
init_git_repo() {
  local d="$1"
  mkdir -p "${d}"
  git -C "${d}" init -q
  git -C "${d}" config user.email "dev@example.com"
  git -C "${d}" config user.name "Dev"
  echo "ok" > "${d}/README.md"
  git -C "${d}" add README.md
  git -C "${d}" commit -q -m "init"
}

init_board() {
  local d="$1"
  mkdir -p "${d}/bin"
  echo "# board" > "${d}/AGENTS.md"
  printf '#!/bin/sh\necho wb\n' > "${d}/bin/wb"
  chmod +x "${d}/bin/wb"
}

###############################################################################
# Extraction: named cloud only, secure.yaml merge, cacert rewrite
###############################################################################
test_extract_named_cloud_only() {
  info "Testing extract keeps only the named cloud..."
  local dest="${TEST_DIR}/out-one"
  mkdir -p "${dest}"
  os_cloud_prepare "${dest}" "${FIXTURE}/clouds.yaml" demo

  local cy
  cy="$(cat "${dest}/clouds.yaml")"
  python3 -c '
import json,sys
cy=json.load(open(sys.argv[1]))
clouds=cy.get("clouds") or {}
assert list(clouds)==["demo"], clouds
auth=clouds["demo"]["auth"]
assert auth["auth_url"]=="https://identity.example.com:5000/v3"
assert auth["password"]==sys.argv[2]
assert "staging" not in clouds
assert "oidc" not in clouds
' "${dest}/clouds.yaml" "${FAKE_PASS_SECURE}" \
    && pass "extract includes only demo, merged from secure.yaml" \
    || fail "extract did not keep only demo / merge secure.yaml"

  printf '%s' "${cy}" | grep -q "${FAKE_PASS_OTHER}" \
    && fail "other cloud's password leaked into extracted clouds.yaml" \
    || pass "other cloud's password is not in the extracted file"

  local cacert
  cacert="$(python3 -c 'import json; print(json.load(open("'"${dest}/clouds.yaml"'"))["clouds"]["demo"]["cacert"])')"
  [[ "${cacert}" == /home/agent/.config/openstack/cacert-* ]] \
    && pass "cacert path rewritten to the in-pod mount (${cacert})" \
    || fail "cacert path not rewritten: ${cacert}"
  local fname
  fname="$(basename "${cacert}")"
  [[ -f "${dest}/${fname}" ]] && grep -q "FIXTURE-ONLY" "${dest}/${fname}" \
    && pass "cacert file carried into the extract dir" \
    || fail "cacert file missing from extract dir"

  local urls
  urls="$(os_cloud_meta "${dest}" auth_urls)"
  [[ "${urls}" == "https://identity.example.com:5000/v3" ]] \
    && pass "auth_url recorded for auto-allowlisting" \
    || fail "unexpected auth_urls: ${urls}"
  [[ "$(os_cloud_meta "${dest}" os_cloud)" == "demo" ]] \
    && pass "os_cloud meta is demo (exactly one cloud)" \
    || fail "os_cloud meta wrong"

  # meta.json must not hold host paths
  if grep -q "${FIXTURE}" "${dest}/meta.json"; then
    fail "meta.json contains a host path"
  else
    pass "meta.json has no host paths"
  fi
}

test_extract_two_clouds() {
  info "Testing extract of two named clouds (OS_CLOUD unset)..."
  local dest="${TEST_DIR}/out-two"
  mkdir -p "${dest}"
  os_cloud_prepare "${dest}" "${FIXTURE}/clouds.yaml" demo staging
  python3 -c '
import json,sys
cy=json.load(open(sys.argv[1]))
assert set(cy["clouds"])=={"demo","staging"}, cy["clouds"]
assert "oidc" not in cy["clouds"]
' "${dest}/clouds.yaml" \
    && pass "both named clouds present, oidc excluded" \
    || fail "two-cloud extract wrong"
  [[ -z "$(os_cloud_meta "${dest}" os_cloud)" ]] \
    && pass "os_cloud meta empty when more than one cloud is given" \
    || fail "os_cloud should be empty for two clouds"
  local n
  n="$(os_cloud_meta "${dest}" auth_urls | wc -l | tr -d ' ')"
  [[ "${n}" == "2" ]] \
    && pass "two auth_urls recorded" \
    || fail "expected 2 auth_urls, got ${n}"
}

test_extract_missing_cloud() {
  info "Testing extract refuses a missing cloud name..."
  local dest="${TEST_DIR}/out-miss"
  mkdir -p "${dest}"
  local err
  if err="$(os_cloud_prepare "${dest}" "${FIXTURE}/clouds.yaml" nope 2>&1)"; then
    fail "missing cloud should have failed"
  else
    echo "${err}" | grep -q "not found" \
      && echo "${err}" | grep -q "demo" \
      && echo "${err}" | grep -qv "${FAKE_PASS_DEMO}" \
      && pass "missing cloud errors with names in the file, no secret" \
      || fail "unclear missing-cloud error: ${err}"
  fi
}

test_extract_oidc_refused() {
  info "Testing extract refuses interactive auth_type..."
  local dest="${TEST_DIR}/out-oidc"
  mkdir -p "${dest}"
  local err
  if err="$(os_cloud_prepare "${dest}" "${FIXTURE}/clouds.yaml" oidc 2>&1)"; then
    fail "oidc auth_type should have been refused"
  else
    echo "${err}" | grep -qi "auth_type" \
      && echo "${err}" | grep -qi "interactive" \
      && echo "${err}" | grep -qv "${FAKE_PASS_DEMO}" \
      && pass "interactive auth_type refused clearly, no secret in the message" \
      || fail "unclear oidc refusal: ${err}"
  fi
}

test_extract_vendor_profile_refused() {
  info "Testing extract refuses a vendor profile without auth_url..."
  local dest="${TEST_DIR}/out-vendor"
  mkdir -p "${dest}"
  local err
  if err="$(os_cloud_prepare "${dest}" "${FIXTURE}/clouds.yaml" vendor 2>&1)"; then
    fail "vendor profile should have been refused"
  else
    echo "${err}" | grep -qi "profile" \
      && pass "vendor profile without auth_url refused" \
      || fail "unclear vendor refusal: ${err}"
  fi
}

###############################################################################
# Manifest: mount + env
###############################################################################
test_manifest_os_cloud() {
  info "Testing build_pod_manifest mounts the Secret and sets OS_CLOUD..."
  local man
  man="$(SESSION_OS_CLOUD=1 SESSION_OS_CLOUD_NAME=demo HOME="${HOME}" \
    build_pod_manifest ses-os claude 3 img "" probe "" sandbox-ses-os "" "" "")"

  printf '%s\n' "${man}" | grep -q 'secretName: "os-cloud-ses-os"' \
    && pass "pod volume references os-cloud-ses-os" \
    || fail "os-cloud Secret not in the pod volume list:\n${man}"
  printf '%s\n' "${man}" | grep -q 'mountPath: /home/agent/.config/openstack' \
    && pass "Secret mounted at /home/agent/.config/openstack" \
    || fail "os-cloud mountPath missing"
  printf '%s\n' "${man}" | grep -q 'name: OS_CLIENT_CONFIG_FILE' \
    && printf '%s\n' "${man}" | grep -q '/home/agent/.config/openstack/clouds.yaml' \
    && pass "OS_CLIENT_CONFIG_FILE set to the mounted clouds.yaml" \
    || fail "OS_CLIENT_CONFIG_FILE missing or wrong"
  printf '%s\n' "${man}" | grep -A1 'name: OS_CLOUD' | grep -q 'value: "demo"' \
    && pass "OS_CLOUD=demo when exactly one cloud is given" \
    || fail "OS_CLOUD missing for a single cloud"

  # Two clouds: SESSION_OS_CLOUD_NAME empty → no OS_CLOUD.
  local two
  two="$(SESSION_OS_CLOUD=1 SESSION_OS_CLOUD_NAME="" HOME="${HOME}" \
    build_pod_manifest ses-os2 claude 3 img "" probe "" sandbox-ses-os2 "" "" "")"
  if printf '%s\n' "${two}" | grep -q 'name: OS_CLOUD'; then
    fail "OS_CLOUD should be unset when more than one cloud is given"
  else
    pass "OS_CLOUD omitted when SESSION_OS_CLOUD_NAME is empty"
  fi
  printf '%s\n' "${two}" | grep -q 'name: OS_CLIENT_CONFIG_FILE' \
    && pass "OS_CLIENT_CONFIG_FILE still set for multiple clouds" \
    || fail "OS_CLIENT_CONFIG_FILE missing for multiple clouds"

  # No --os-cloud: no volume, no env.
  local none
  none="$(SESSION_OS_CLOUD="" SESSION_OS_CLOUD_NAME="" HOME="${HOME}" \
    build_pod_manifest ses-x claude 3 img "" probe "" sandbox-ses-x "" "" "")"
  if printf '%s\n' "${none}" | grep -qE 'secretName: "os-cloud-|name: OS_CLOUD|name: OS_CLIENT_CONFIG_FILE|name: os-cloud'; then
    fail "os-cloud leaked into a pod that did not request it"
  else
    pass "no os-cloud volume or env when the flag is absent"
  fi
}

###############################################################################
# Audit: names only, no secret material
###############################################################################
test_audit_names_only() {
  info "Testing session.json records cloud names, never credentials..."
  local log_dir="${TEST_DIR}/audit"
  mkdir -p "${log_dir}"
  SESSION_OS_CLOUD=1 SESSION_OS_CLOUD_NAMES="demo,staging" \
  SESSION_INFRA_TOKEN="" SESSION_INFRA_KUBECONFIG="" \
  SESSION_KUBE_API_CIDR="" SESSION_KUBE_API_PORT="" \
  SESSION_KUBE_API_CONTEXTS="" SESSION_KUBE_HOST_ENTITY="" \
  SESSION_PROFILE="" SESSION_OVERLAY="" \
    audit_write_session_json \
      "${log_dir}" "ses-os" "claude" "3" "dev" '["/tmp/repo"]' "my-agent" \
      "sandbox-ses-os" "2026-11-13T00:00:00Z"

  local json="${log_dir}/session.json"
  [[ -f "${json}" ]] || fail "session.json was not created"
  python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("os_cloud") is True, d
assert d.get("os_clouds")==["demo","staging"], d.get("os_clouds")
blob=json.dumps(d)
for s in sys.argv[2:]:
    assert s not in blob, s
' "${json}" "${FAKE_PASS_DEMO}" "${FAKE_PASS_SECURE}" "${FAKE_PASS_OTHER}" \
    && pass "session.json has os_cloud=true and names demo,staging; no fixture passwords" \
    || fail "session.json os_cloud fields wrong or contain a secret"

  # Absent flag → false / empty.
  local log2="${TEST_DIR}/audit2"
  mkdir -p "${log2}"
  SESSION_OS_CLOUD="" SESSION_OS_CLOUD_NAMES="" \
    audit_write_session_json \
      "${log2}" "ses-x" "claude" "1" "dev" '[]' "" \
      "sandbox-ses-x" "2026-11-13T00:00:00Z"
  python3 -c '
import json
d=json.load(open("'"${log2}/session.json"'"))
assert d.get("os_cloud") is False, d
assert d.get("os_clouds")==[], d
' && pass "session.json os_cloud is false when the flag is absent" \
    || fail "absent --os-cloud should record os_cloud=false"
}

###############################################################################
# CLI gates (fail before ensure_cluster_ready)
###############################################################################
test_cli_non_tier3() {
  info "Testing --os-cloud is refused on a non-tier-3 session..."
  local output rc=0
  output="$("${SANDBOX_ROOT}/bin/sandbox" run \
    --agent claude --tier 1 \
    --os-cloud demo --os-clouds-file "${FIXTURE}/clouds.yaml" \
    --dry-run 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    fail "CLI should have refused --os-cloud on tier 1"
  fi
  echo "${output}" | grep -q -- "--os-cloud is only valid for tier 3" \
    && echo "${output}" | grep -qv "${FAKE_PASS_DEMO}" \
    && pass "tier 1 rejects --os-cloud before any extract" \
    || fail "unexpected non-tier-3 error: ${output}"
}

test_cli_missing_cloud() {
  info "Testing CLI rejects a cloud name that is not in clouds.yaml..."
  local repo="${TEST_DIR}/repo-miss"
  init_git_repo "${repo}"
  local output rc=0
  output="$("${SANDBOX_ROOT}/bin/sandbox" run \
    --agent claude --tier 3 --repo "${repo}" \
    --os-cloud nope --os-clouds-file "${FIXTURE}/clouds.yaml" \
    --dry-run 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    fail "CLI should have refused a missing cloud name"
  fi
  echo "${output}" | grep -qi "not found" \
    && echo "${output}" | grep -qv "${FAKE_PASS_DEMO}" \
    && echo "${output}" | grep -qv "${FAKE_PASS_SECURE}" \
    && pass "missing cloud rejected, no secret in the error" \
    || fail "unexpected missing-cloud CLI error: ${output}"
}

test_cli_blocked_auth_url() {
  info "Testing auth_url is checked against blocked destinations..."
  local repo="${TEST_DIR}/repo-block"
  init_git_repo "${repo}"
  local output rc=0
  output="$("${SANDBOX_ROOT}/bin/sandbox" run \
    --agent claude --tier 3 --repo "${repo}" \
    --os-cloud demo --os-clouds-file "${FIXTURE}/blocked-clouds.yaml" \
    --dry-run 2>&1)" || rc=$?
  if [[ "${rc}" -eq 0 ]]; then
    fail "CLI should have rejected a blocked auth_url"
  fi
  echo "${output}" | grep -qi "block\|forbidden\|not allowed" \
    && echo "${output}" | grep -qv "fixture-blocked-only" \
    && pass "blocked auth_url is rejected through the --infra-endpoint path" \
    || fail "blocked auth_url error unclear: ${output}"
}

test_cli_board_os_cloud_allowed() {
  info "Testing --board + --os-cloud is not refused as a profile secret..."
  local repo="${TEST_DIR}/repo-board"
  local board="${TEST_DIR}/board"
  local state="${TEST_DIR}/board-state"
  init_git_repo "${repo}"
  init_board "${board}"
  mkdir -p "${state}"
  local output rc=0
  output="$("${SANDBOX_ROOT}/bin/sandbox" run \
    --agent claude --tier 3 --repo "${repo}" \
    --board "${board}" --board-state "${state}" --name demo-agent \
    --os-cloud demo --os-clouds-file "${FIXTURE}/clouds.yaml" \
    --dry-run 2>&1)" || rc=$?
  if echo "${output}" | grep -qi "injects secrets\|can't be combined with a profile"; then
    fail "--board + --os-cloud was refused as a profile secret: ${output}"
  fi
  if echo "${output}" | grep -q -- "--os-cloud is only valid"; then
    fail "--os-cloud rejected on a tier 3 --board session: ${output}"
  fi
  if echo "${output}" | grep -q "requires at least one of --infra-token"; then
    fail "--os-cloud did not satisfy the Tier 3 credential requirement: ${output}"
  fi
  echo "${output}" | grep -qv "${FAKE_PASS_SECURE}" \
    && echo "${output}" | grep -qv "${FAKE_PASS_DEMO}" \
    && pass "credential values are not in the CLI output" \
    || fail "a fixture password appeared in CLI output"
  # Without a live cluster, launch stops at ensure_cluster_ready (or an
  # earlier image-presence probe). That is the expected cluster-free end.
  if [[ "${rc}" -eq 0 ]]; then
    # A live cluster would make --dry-run succeed; then assert the hint
    # and the mount. Still check secrets did not leak (above).
    echo "${output}" | grep -q "Auto-allowlisting auth_url" \
      && echo "${output}" | grep -q "Service catalog endpoints" \
      && echo "${output}" | grep -q "OS_CLIENT_CONFIG_FILE" \
      && pass "--board + --os-cloud dry-run succeeded (cluster present); hint and mount rendered" \
      || fail "dry-run succeeded but missing hint or mount: ${output}"
  else
    if echo "${output}" | grep -qi "Cannot reach Kubernetes\|Namespace .* not found\|gVisor RuntimeClass\|not present in the cluster\|No runnable image"; then
      pass "--board + --os-cloud reached cluster/image preflight (not a board refusal)"
    else
      fail "unexpected --board + --os-cloud failure: ${output}"
    fi
  fi
}

test_cli_help() {
  info "Testing sandbox run --help mentions --os-cloud..."
  local h
  h="$("${SANDBOX_ROOT}/bin/sandbox" run --help 2>&1)" || true
  echo "${h}" | grep -q -- "--os-cloud <NAME>" \
    && echo "${h}" | grep -q -- "--os-clouds-file" \
    && echo "${h}" | grep -q "or --os-cloud" \
    && pass "run --help documents --os-cloud and the Tier 3 requirement" \
    || fail "--help missing --os-cloud: ${h}"
}

###############################################################################
info "Running test-os-cloud tests..."
test_extract_named_cloud_only
test_extract_two_clouds
test_extract_missing_cloud
test_extract_oidc_refused
test_extract_vendor_profile_refused
test_manifest_os_cloud
test_audit_names_only
test_cli_non_tier3
test_cli_missing_cloud
test_cli_blocked_auth_url
test_cli_board_os_cloud_allowed
test_cli_help
echo "All test-os-cloud tests passed."
