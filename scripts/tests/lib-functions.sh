#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2153,SC2329

# -----------------------------------------------------------------------------
# Test Suite 4b: scripts/lib.sh unit tests and scripts/test.sh runner checks
# -----------------------------------------------------------------------------
test_lib_functions() {
  local suite="Makefile rules and safety checks"
  local test_dir="${MASTER_TEST_DIR}/lib_functions"
  setup_makefile_test_env "${test_dir}"
  local fake_bin="${test_dir}/bin"
  local lima_log="${test_dir}/limactl.log"

  # 4.8 scripts/lib.sh: normalize 関数の単体テスト（各 assertion を個別に検証し偽陽性を防止）
  log_test "${suite}: scripts/lib.sh normalize unit tests"
  # shellcheck source=scripts/lib.sh
  source "${REPO_ROOT}/scripts/lib.sh"
  local norm_failures=0
  assert_norm() {
    local actual expected="$2"
    actual=$(normalize "$1")
    if [ "${actual}" != "${expected}" ]; then
      echo >&2 "normalize('$1') = '${actual}', expected '${expected}'"
      norm_failures=$((norm_failures + 1))
    fi
  }
  assert_norm "" ""
  assert_norm "   " ""
  assert_norm '  "  Doe, John  "  ' "Doe, John"
  assert_norm "  '  john@example.com  '  " "john@example.com"
  assert_norm ' ""inner"" ' '"inner"'
  assert_norm " '\"inner\"' " '"inner"'
  assert_norm ' "\"escaped\"" ' '\"escaped\"'
  assert_norm ' "unmatched ' '"unmatched'
  assert_norm '"' '"'

  if [ "${norm_failures}" -eq 0 ]; then
    log_pass "${suite}: scripts/lib.sh normalize unit tests"
  else
    log_fail "${suite}: scripts/lib.sh normalize unit tests failed (${norm_failures} failure(s))"
  fi

  # 4.9 scripts/lib.sh: get_status / resolve_name / require_running / extract_pubkey_fingerprint / validate_auth_backup_items の単体テスト
  log_test "${suite}: scripts/lib.sh get_status, resolve_name, require_running, extract_pubkey_fingerprint, and validate_auth_backup_items unit tests"
  local st_running st_stopped st_missing st_fail_rc=0
  local rn_default rn_quoted rn_empty_rc=0 rn_quoted_empty_rc=0
  local rr_running_rc=0 rr_stopped_rc=0 rr_stopped_err="" rr_missing_rc=0 rr_missing_err="" rr_fail_rc=0
  local fp_valid="" fp_nonutf8="" fp_invalid_rc=0 fp_empty_rc=0
  local vab_dir="${test_dir}/vab_unit" vab_ok_rc=0 vab_empty_rc=0 vab_sym_rc=0 vab_awk_fail_rc=0 vab_items_joined="" vab_labels_joined=""
  st_running=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=$'coding-sandbox2 Stopped\ncoding-sandbox Running'
    get_status "coding-sandbox"
  )
  st_stopped=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=$'coding-sandbox2 Stopped\ncoding-sandbox Running'
    get_status "coding-sandbox2"
  )
  st_missing=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=$'coding-sandbox2 Stopped\ncoding-sandbox Running'
    get_status "nonexistent"
  )
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_LIST_FAIL=1
    get_status "coding-sandbox" >/dev/null 2>&1
  ) || st_fail_rc=$?

  rn_default=$(unset NAME; resolve_name)
  rn_quoted=$(NAME=' "sandbox2" ' resolve_name)
  (NAME="" resolve_name >/dev/null 2>&1) || rn_empty_rc=$?
  (NAME=' "  " ' resolve_name >/dev/null 2>&1) || rn_quoted_empty_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=$'coding-sandbox2 Stopped\ncoding-sandbox Running'
    require_running "coding-sandbox" >/dev/null 2>&1
  ) || rr_running_rc=$?
  rr_stopped_err=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=$'coding-sandbox2 Stopped\ncoding-sandbox Running'
    require_running "coding-sandbox2" 2>&1
  ) || rr_stopped_rc=$?
  rr_missing_err=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=$'coding-sandbox2 Stopped\ncoding-sandbox Running'
    require_running "nonexistent" 2>&1
  ) || rr_missing_rc=$?
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_LIST_FAIL=1
    require_running "coding-sandbox" >/dev/null 2>&1
  ) || rr_fail_rc=$?

  fp_valid=$(extract_pubkey_fingerprint "256 SHA256:AbCdEf0123456789+/= user@host (ED25519)")
  fp_nonutf8=$(extract_pubkey_fingerprint "$(printf '256 SHA256:ZyXwVu9876543210+/= \377\376\233 (ED25519)\n')")
  (extract_pubkey_fingerprint "256 MD5:aa:bb:cc user@host" >/dev/null 2>&1) || fp_invalid_rc=$?
  (extract_pubkey_fingerprint "" >/dev/null 2>&1) || fp_empty_rc=$?

  mkdir -p "${vab_dir}/ok/.config/gh" "${vab_dir}/ok/.copilot" "${vab_dir}/key/.ssh" "${vab_dir}/empty" "${vab_dir}/sym"
  printf 'token\n' > "${vab_dir}/ok/.config/gh/hosts.yml"
  printf '{"oauth":true}\n' > "${vab_dir}/ok/.copilot/config.json"
  ssh-keygen -q -t ed25519 -N '' -C 'unit@test' -f "${vab_dir}/key/.ssh/id_ed25519_signing"
  ln -s /tmp "${vab_dir}/sym/.copilot"
  if validate_auth_backup_items "${vab_dir}/ok" >/dev/null 2>&1; then
    vab_items_joined="${AUTH_VALIDATED_ITEMS[*]}"
    vab_labels_joined="${AUTH_VALIDATED_LABELS[*]}"
  else
    vab_ok_rc=$?
  fi
  (validate_auth_backup_items "${vab_dir}/empty" >/dev/null 2>&1) || vab_empty_rc=$?
  (validate_auth_backup_items "${vab_dir}/sym" >/dev/null 2>&1) || vab_sym_rc=$?
  (
    awk() { printf 'ssh-ed25519 AAAA\n'; return 42; }
    validate_auth_backup_items "${vab_dir}/key" >/dev/null 2>&1
  ) || vab_awk_fail_rc=$?

  # shellcheck disable=SC2088
  if [ "${st_running}" = "Running" ] && \
     [ "${st_stopped}" = "Stopped" ] && \
     [ -z "${st_missing}" ] && \
     [ "${st_fail_rc}" -ne 0 ] && \
     [ "${rn_default}" = "coding-sandbox" ] && \
     [ "${rn_quoted}" = "sandbox2" ] && \
     [ "${rn_empty_rc}" -ne 0 ] && \
     [ "${rn_quoted_empty_rc}" -ne 0 ] && \
     [ "${rr_running_rc}" -eq 0 ] && \
     [ "${rr_stopped_rc}" -ne 0 ] && \
     [[ "${rr_stopped_err}" == *"動いていません"* ]] && \
     [ "${rr_missing_rc}" -ne 0 ] && \
     [[ "${rr_missing_err}" == *"はありません"* ]] && \
     [ "${rr_fail_rc}" -ne 0 ] && \
     [ "${fp_valid}" = "SHA256:AbCdEf0123456789+/=" ] && \
     [ "${fp_nonutf8}" = "SHA256:ZyXwVu9876543210+/=" ] && \
     [ "${fp_invalid_rc}" -ne 0 ] && \
     [ "${fp_empty_rc}" -ne 0 ] && \
     [ "${vab_ok_rc}" -eq 0 ] && \
     [ "${vab_items_joined}" = ".config/gh .copilot/config.json" ] && \
     [ "${vab_labels_joined}" = "~/.config/gh ~/.copilot/config.json" ] && \
     [ "${vab_empty_rc}" -ne 0 ] && \
     [ "${vab_sym_rc}" -ne 0 ] && \
     [ "${vab_awk_fail_rc}" -eq 42 ]; then
    log_pass "${suite}: scripts/lib.sh get_status, resolve_name, require_running, extract_pubkey_fingerprint, and validate_auth_backup_items unit tests"
  else
    log_fail "${suite}: scripts/lib.sh get_status, resolve_name, require_running, extract_pubkey_fingerprint, and validate_auth_backup_items unit tests failed"
  fi

  # 4.17 scripts/lib.sh: resolve_auth_backup_dir の単体テスト（既定パス・~展開・リポジトリ内拒否・シンボリックリンク拒否・危険パス拒否）
  log_test "${suite}: scripts/lib.sh resolve_auth_backup_dir unit tests"
  local fake_host_home="${test_dir}/host_home"
  mkdir -p "${fake_host_home}"
  local fake_host_home_phys
  fake_host_home_phys=$(cd "${fake_host_home}" && pwd -P)

  local def_bdir tilde_bdir
  def_bdir=$(HOME="${fake_host_home}" AUTH_BACKUP_DIR="" resolve_auth_backup_dir "coding-sandbox")
  tilde_bdir=$(HOME="${fake_host_home}" AUTH_BACKUP_DIR=' " ~/my-backups/sb2/ " ' resolve_auth_backup_dir "sb2")

  local repo_sub_rc=0 repo_root_rc=0 repo_link_rc=0 target_link_rc=0 root_dir_rc=0 home_dir_rc=0 tmp_dir_rc=0
  (HOME="${fake_host_home}" AUTH_BACKUP_DIR="${REPO_ROOT}/auth-backup" resolve_auth_backup_dir "coding-sandbox" >/dev/null 2>&1) || repo_sub_rc=$?
  (HOME="${fake_host_home}" AUTH_BACKUP_DIR="${REPO_ROOT}" resolve_auth_backup_dir "coding-sandbox" >/dev/null 2>&1) || repo_root_rc=$?

  ln -s "${REPO_ROOT}" "${test_dir}/repo_symlink"
  (HOME="${fake_host_home}" AUTH_BACKUP_DIR="${test_dir}/repo_symlink/sub" resolve_auth_backup_dir "coding-sandbox" >/dev/null 2>&1) || repo_link_rc=$?

  mkdir -p "${test_dir}/real_bdir"
  ln -s "${test_dir}/real_bdir" "${test_dir}/bdir_symlink"
  (HOME="${fake_host_home}" AUTH_BACKUP_DIR="${test_dir}/bdir_symlink" resolve_auth_backup_dir "coding-sandbox" >/dev/null 2>&1) || target_link_rc=$?

  (HOME="${fake_host_home}" AUTH_BACKUP_DIR="/" resolve_auth_backup_dir "coding-sandbox" >/dev/null 2>&1) || root_dir_rc=$?
  (HOME="${fake_host_home}" AUTH_BACKUP_DIR="~" resolve_auth_backup_dir "coding-sandbox" >/dev/null 2>&1) || home_dir_rc=$?
  (HOME="${fake_host_home}" AUTH_BACKUP_DIR="/tmp" resolve_auth_backup_dir "coding-sandbox" >/dev/null 2>&1) || tmp_dir_rc=$?

  if [ "${def_bdir}" = "${fake_host_home_phys}/.local/share/lima-coding-sandbox/auth-backup/coding-sandbox" ] && \
     [ "${tilde_bdir}" = "${fake_host_home_phys}/my-backups/sb2" ] && \
     [ "${repo_sub_rc}" -ne 0 ] && [ "${repo_root_rc}" -ne 0 ] && [ "${repo_link_rc}" -ne 0 ] && \
     [ "${target_link_rc}" -ne 0 ] && [ "${root_dir_rc}" -ne 0 ] && [ "${home_dir_rc}" -ne 0 ] && [ "${tmp_dir_rc}" -ne 0 ]; then
    log_pass "${suite}: scripts/lib.sh resolve_auth_backup_dir unit tests"
  else
    log_fail "${suite}: scripts/lib.sh resolve_auth_backup_dir unit tests failed"
  fi

  # 4.24 scripts/test.sh: CLI --list, --help, スイート選択実行・ハイフン/test_正規化・重複排除・不正スイート名拒否
  log_test "${suite}: scripts/test.sh CLI --list, --help, selective execution, normalization, deduplication, and invalid suite rejection"
  local list_out="" list_rc=0 help_out="" help_rc=0 sel_out="" sel_rc=0 bad_suite_err="" bad_suite_rc=0
  list_out=$(bash "${REPO_ROOT}/scripts/test.sh" --list 2>&1) || list_rc=$?
  help_out=$(bash "${REPO_ROOT}/scripts/test.sh" --help 2>&1) || help_rc=$?
  sel_out=$(bash "${REPO_ROOT}/scripts/test.sh" test_agent_instructions agent-instructions 2>&1) || sel_rc=$?
  bad_suite_err=$(bash "${REPO_ROOT}/scripts/test.sh" nonexistent_suite_name 2>&1) || bad_suite_rc=$?

  if [ "${list_rc}" -eq 0 ] && printf '%s\n' "${list_out}" | grep -qx "git_config" && \
     printf '%s\n' "${list_out}" | grep -qx "lib_functions" && \
     [ "${help_rc}" -eq 0 ] && printf '%s\n' "${help_out}" | grep -q "^Usage:" && \
     [ "${sel_rc}" -eq 0 ] && printf '%s\n' "${sel_out}" | grep -q "Test results: 5 passed, 0 failed" && \
     ! printf '%s\n' "${sel_out}" | grep -q "provision/git-config.sh" && \
     [ "${bad_suite_rc}" -ne 0 ] && printf '%s\n' "${bad_suite_err}" | grep -q "Unknown test suite 'nonexistent_suite_name'"; then
    log_pass "${suite}: scripts/test.sh CLI --list, --help, selective execution, normalization, deduplication, and invalid suite rejection"
  else
    log_fail "${suite}: scripts/test.sh CLI runner checks failed (list_rc=${list_rc}, help_rc=${help_rc}, sel_rc=${sel_rc}, bad_suite_rc=${bad_suite_rc})"
  fi
}
