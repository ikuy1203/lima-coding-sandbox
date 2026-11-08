#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 3: provision/{herdr,antigravity-cli,copilot-cli,mise}.sh with stub curl
# -----------------------------------------------------------------------------
test_cli_provisioning() {
  local suite="provision/CLI installers"
  local test_dir="${MASTER_TEST_DIR}/cli_provisioning"
  rm -rf "${test_dir}"
  mkdir -p "${test_dir}"

  local fake_home="${test_dir}/home"
  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_home}" "${fake_bin}"

  create_stub_curl "${fake_bin}"

  local curl_log="${test_dir}/curl.log"

  # 高速テスト用設定
  local test_env=(
    "HOME=${fake_home}"
    "PATH=${fake_bin}:${PATH}"
    "STUB_CURL_LOG=${curl_log}"
    "DOWNLOAD_RETRY_DELAY=0"
    "DOWNLOAD_CONNECT_TIMEOUT=1"
    "DOWNLOAD_MAX_TIME=2"
    "DOWNLOAD_TOTAL_MAX_TIME=5"
    "DOWNLOAD_RETRY_COUNT=2"
  )

  # 3.1 herdr, agy, copilot の初回実行、--compressed の確認、冪等性と一時ファイル消去
  log_test "${suite}: herdr, agy, copilot installation, --compressed, and idempotency"
  local tmp_work="${test_dir}/tmp1"
  mkdir -p "${tmp_work}"
  : > "${curl_log}"
  (
    export "${test_env[@]}"
    export TMPDIR="${tmp_work}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/antigravity-cli.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  )

  local call_count_first
  call_count_first=$(wc -l < "${curl_log}" | tr -d ' ')

  local agy_compressed_called=0
  if grep -q -- "--compressed.*antigravity.google" "${curl_log}"; then
    agy_compressed_called=1
  fi

  local tmp_leftover_first
  tmp_leftover_first=$(count_dir_entries "${tmp_work}")

  # 2 回目実行: バイナリが存在するため curl は呼ばれないはず
  (
    export "${test_env[@]}"
    export TMPDIR="${tmp_work}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/antigravity-cli.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  )

  local call_count_second
  call_count_second=$(wc -l < "${curl_log}" | tr -d ' ')

  if [ -x "${fake_home}/.local/bin/herdr" ] && \
     [ -x "${fake_home}/.local/bin/agy" ] && \
     [ -x "${fake_home}/.local/bin/copilot" ] && \
     [ "${agy_compressed_called}" -eq 1 ] && \
     [ "${call_count_first}" -eq 3 ] && \
     [ "${call_count_second}" -eq 3 ] && \
     [ "${tmp_leftover_first}" -eq 0 ]; then
    log_pass "${suite}: herdr, agy, copilot installation, --compressed, and idempotency"
  else
    log_fail "${suite}: herdr, agy, copilot idempotency or tmp cleanup failed"
  fi

  # 3.2 mise.sh の冪等性と ~/.profile の重複防止
  log_test "${suite}: mise installation and ~/.profile non-duplication"
  local tmp_work_mise="${test_dir}/tmp_mise"
  mkdir -p "${tmp_work_mise}"
  (
    export "${test_env[@]}"
    export TMPDIR="${tmp_work_mise}"
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  )
  local marker_count tmp_leftover_mise
  marker_count=$(grep -c "added by lima-coding-sandbox provision/mise.sh" "${fake_home}/.profile" || true)
  tmp_leftover_mise=$(count_dir_entries "${tmp_work_mise}")
  if [ -x "${fake_home}/.local/bin/mise" ] && [ "${marker_count}" -eq 1 ] && [ "${tmp_leftover_mise}" -eq 0 ]; then
    log_pass "${suite}: mise installation and ~/.profile non-duplication"
  else
    log_fail "${suite}: mise ~/.profile duplicated or binary missing or tmp leftover"
  fi

  # 3.3 一時障害（HTTP 503 / 接続失敗）からの自動リトライ回復
  log_test "${suite}: recovery within single run from transient network failures"
  local retry_home="${test_dir}/retry_home"
  local retry_tmp="${test_dir}/retry_tmp"
  local retry_count_file="${test_dir}/retry_count.txt"
  mkdir -p "${retry_home}" "${retry_tmp}"
  : > "${curl_log}"
  rm -f "${retry_count_file}"

  (
    export "${test_env[@]}"
    export HOME="${retry_home}"
    export TMPDIR="${retry_tmp}"
    export STUB_CURL_MODE="retry_then_success"
    export STUB_CURL_COUNT_FILE="${retry_count_file}"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  )

  local retry_calls=0 tmp_leftover_retry=0
  if [ -f "${retry_count_file}" ]; then
    retry_calls=$(cat "${retry_count_file}")
  fi
  tmp_leftover_retry=$(count_dir_entries "${retry_tmp}")

  if [ -x "${retry_home}/.local/bin/copilot" ] && [ "${retry_calls}" -eq 3 ] && [ "${tmp_leftover_retry}" -eq 0 ]; then
    log_pass "${suite}: recovery within single run from transient network failures"
  else
    log_fail "${suite}: transient failure recovery failed (calls: ${retry_calls}, tmp leftover: ${tmp_leftover_retry})"
  fi

  # 3.4 HTTP 200 受信後の切断・タイムアウトからの自動リトライ回復
  log_test "${suite}: recovery from connection drop/timeout after HTTP 200 header"
  local h200_home="${test_dir}/h200_home"
  local h200_tmp="${test_dir}/h200_tmp"
  local h200_count_file="${test_dir}/h200_count.txt"
  mkdir -p "${h200_home}" "${h200_tmp}"
  : > "${curl_log}"
  rm -f "${h200_count_file}"

  (
    export "${test_env[@]}"
    export HOME="${h200_home}"
    export TMPDIR="${h200_tmp}"
    export STUB_CURL_MODE="http200_fail_then_success"
    export STUB_CURL_COUNT_FILE="${h200_count_file}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
  )

  local h200_calls=0 tmp_leftover_h200=0
  if [ -f "${h200_count_file}" ]; then
    h200_calls=$(cat "${h200_count_file}")
  fi
  tmp_leftover_h200=$(count_dir_entries "${h200_tmp}")

  if [ -x "${h200_home}/.local/bin/herdr" ] && [ "${h200_calls}" -eq 3 ] && [ "${tmp_leftover_h200}" -eq 0 ]; then
    log_pass "${suite}: recovery from connection drop/timeout after HTTP 200 header"
  else
    log_fail "${suite}: HTTP 200 recovery failed (calls: ${h200_calls}, tmp leftover: ${tmp_leftover_h200})"
  fi

  # 3.5 空本文リトライ後の HTTP 404 即時失敗（空本文判定が次試行へ持ち越されないこと）
  log_test "${suite}: immediate failure on 404 after empty body retry (no state leakage)"
  local empty404_home="${test_dir}/empty404_home"
  local empty404_tmp="${test_dir}/empty404_tmp"
  local empty404_count_file="${test_dir}/empty404_count.txt"
  local empty404_stderr="${test_dir}/empty404.stderr"
  mkdir -p "${empty404_home}" "${empty404_tmp}"
  rm -f "${empty404_count_file}" "${empty404_stderr}"

  local empty404_failed=0
  (
    export "${test_env[@]}"
    export HOME="${empty404_home}"
    export TMPDIR="${empty404_tmp}"
    export STUB_CURL_MODE="empty_then_404"
    export STUB_CURL_COUNT_FILE="${empty404_count_file}"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >"${empty404_stderr}" 2>&1
  ) || empty404_failed=1

  local empty404_calls=0 tmp_leftover_empty404=0
  if [ -f "${empty404_count_file}" ]; then
    empty404_calls=$(cat "${empty404_count_file}")
  fi
  tmp_leftover_empty404=$(count_dir_entries "${empty404_tmp}")

  if [ "${empty404_failed}" -eq 1 ] && [ "${empty404_calls}" -eq 2 ] && [ "${tmp_leftover_empty404}" -eq 0 ] && ! [ -e "${empty404_home}/.local/bin/copilot" ]; then
    log_pass "${suite}: immediate failure on 404 after empty body retry (no state leakage)"
  else
    log_fail "${suite}: empty body to 404 transition leaked retry state (failed: ${empty404_failed}, calls: ${empty404_calls}, tmp leftover: ${tmp_leftover_empty404})"
  fi

  # 3.6 恒久エラー（HTTP 404）での即時失敗（リトライしないこと）
  log_test "${suite}: immediate failure on permanent HTTP 404 without retry"
  local p404_home="${test_dir}/p404_home"
  local p404_tmp="${test_dir}/p404_tmp"
  local p404_count_file="${test_dir}/p404_count.txt"
  local p404_stderr="${test_dir}/p404.stderr"
  mkdir -p "${p404_home}" "${p404_tmp}"
  rm -f "${p404_count_file}" "${p404_stderr}"

  local p404_failed=0
  (
    export "${test_env[@]}"
    export HOME="${p404_home}"
    export TMPDIR="${p404_tmp}"
    export STUB_CURL_MODE="permanent_404"
    export STUB_CURL_COUNT_FILE="${p404_count_file}"
    bash "${REPO_ROOT}/provision/herdr.sh" 2>"${p404_stderr}"
  ) || p404_failed=1

  local p404_calls=0 tmp_leftover_p404=0 has_404_msg=0
  if [ -f "${p404_count_file}" ]; then
    p404_calls=$(cat "${p404_count_file}")
  fi
  tmp_leftover_p404=$(count_dir_entries "${p404_tmp}")
  if grep -q "permanent HTTP 404" "${p404_stderr}"; then
    has_404_msg=1
  fi

  if [ "${p404_failed}" -eq 1 ] && [ "${p404_calls}" -eq 1 ] && \
     [ "${has_404_msg}" -eq 1 ] && [ "${tmp_leftover_p404}" -eq 0 ] && \
     [ ! -e "${p404_home}/.local/bin/herdr" ]; then
    log_pass "${suite}: immediate failure on permanent HTTP 404 without retry"
  else
    log_fail "${suite}: permanent 404 should fail immediately with 1 call (calls: ${p404_calls}, tmp: ${tmp_leftover_p404})"
  fi

  # 3.5 タイムアウト（curl exit 28）での最大リトライ到達後の失敗
  log_test "${suite}: timeout exhaustion fails with cause and cleans up"
  local tout_home="${test_dir}/tout_home"
  local tout_tmp="${test_dir}/tout_tmp"
  local tout_count_file="${test_dir}/tout_count.txt"
  local tout_stderr="${test_dir}/tout.stderr"
  mkdir -p "${tout_home}" "${tout_tmp}"
  rm -f "${tout_count_file}" "${tout_stderr}"

  local tout_failed=0
  (
    export "${test_env[@]}"
    export HOME="${tout_home}"
    export TMPDIR="${tout_tmp}"
    export STUB_CURL_MODE="timeout"
    export STUB_CURL_COUNT_FILE="${tout_count_file}"
    bash "${REPO_ROOT}/provision/antigravity-cli.sh" 2>"${tout_stderr}"
  ) || tout_failed=1

  local tout_calls=0 tmp_leftover_tout=0 has_tout_msg=0
  if [ -f "${tout_count_file}" ]; then
    tout_calls=$(cat "${tout_count_file}")
  fi
  tmp_leftover_tout=$(count_dir_entries "${tout_tmp}")
  if grep -q "operation timed out" "${tout_stderr}"; then
    has_tout_msg=1
  fi

  # DOWNLOAD_RETRY_COUNT=2 なので、初回(1) + リトライ(2) = 計 3 回呼び出されるはず
  if [ "${tout_failed}" -eq 1 ] && [ "${tout_calls}" -eq 3 ] && \
     [ "${has_tout_msg}" -eq 1 ] && [ "${tmp_leftover_tout}" -eq 0 ]; then
    log_pass "${suite}: timeout exhaustion fails with cause and cleans up"
  else
    log_fail "${suite}: timeout exhaustion failed (calls: ${tout_calls}, tmp: ${tmp_leftover_tout})"
  fi

  # 3.6 途中失敗スクリプト片の不実行
  log_test "${suite}: do not execute partial script on download failure"
  local partial_home="${test_dir}/partial_home"
  local partial_tmp="${test_dir}/partial_tmp"
  local marker_partial="${test_dir}/partial_executed.marker"
  mkdir -p "${partial_home}" "${partial_tmp}"
  rm -f "${marker_partial}"

  local partial_failed=0
  (
    export "${test_env[@]}"
    export HOME="${partial_home}"
    export TMPDIR="${partial_tmp}"
    export STUB_CURL_MODE="partial_fail"
    export STUB_MARKER_PARTIAL="${marker_partial}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
  ) || partial_failed=1

  local tmp_leftover_partial
  tmp_leftover_partial=$(count_dir_entries "${partial_tmp}")

  if [ "${partial_failed}" -eq 1 ] && [ ! -f "${marker_partial}" ] && [ "${tmp_leftover_partial}" -eq 0 ]; then
    log_pass "${suite}: do not execute partial script on download failure"
  else
    log_fail "${suite}: partial script was executed or tmp leftover"
  fi

  # 3.8 総時間上限（DOWNLOAD_TOTAL_MAX_TIME）到達時の打ち切りと一時ファイル消去
  log_test "${suite}: total timeout exhaustion with backoff sleep fails cleanly"
  local total_home="${test_dir}/total_home"
  local total_tmp="${test_dir}/total_tmp"
  local total_stderr="${test_dir}/total.stderr"
  mkdir -p "${total_home}" "${total_tmp}"
  rm -f "${total_stderr}"

  local total_failed=0
  (
    export "${test_env[@]}"
    export HOME="${total_home}"
    export TMPDIR="${total_tmp}"
    export STUB_CURL_MODE="timeout"
    export DOWNLOAD_TOTAL_MAX_TIME=1
    export DOWNLOAD_RETRY_DELAY=1
    export DOWNLOAD_RETRY_COUNT=5
    bash "${REPO_ROOT}/provision/herdr.sh" 2>"${total_stderr}"
  ) || total_failed=1

  local tmp_leftover_total=0 has_total_msg=0
  tmp_leftover_total=$(count_dir_entries "${total_tmp}")
  if grep -q "exceeded total timeout" "${total_stderr}"; then
    has_total_msg=1
  fi

  if [ "${total_failed}" -eq 1 ] && [ "${has_total_msg}" -eq 1 ] && [ "${tmp_leftover_total}" -eq 0 ]; then
    log_pass "${suite}: total timeout exhaustion with backoff sleep fails cleanly"
  else
    log_fail "${suite}: total timeout failed (failed: ${total_failed}, msg: ${has_total_msg}, tmp: ${tmp_leftover_total})"
  fi

  # 3.9 6つのプロビジョニングスクリプト間での download_file / is_transient_* 関数の共通性検証
  log_test "${suite}: consistency of download_file and is_transient_* across all provision scripts"
  local scripts=(
    "${REPO_ROOT}/provision/herdr.sh"
    "${REPO_ROOT}/provision/antigravity-cli.sh"
    "${REPO_ROOT}/provision/copilot-cli.sh"
    "${REPO_ROOT}/provision/mise.sh"
    "${REPO_ROOT}/provision/github-cli.sh"
    "${REPO_ROOT}/provision/docker-engine.sh"
  )
  local ref_funcs
  ref_funcs=$(awk '/^is_transient_curl_rc\(\)/,/^}$/{print} /^is_transient_http_code\(\)/,/^}$/{print} /^download_file\(\)/,/^}$/{print}' "${scripts[0]}")
  local drift_found=0
  for s in "${scripts[@]}"; do
    local current_funcs
    current_funcs=$(awk '/^is_transient_curl_rc\(\)/,/^}$/{print} /^is_transient_http_code\(\)/,/^}$/{print} /^download_file\(\)/,/^}$/{print}' "${s}")
    if [ "${ref_funcs}" != "${current_funcs}" ]; then
      drift_found=1
      echo >&2 "Drift detected in $(basename "${s}")"
    fi
  done
  if [ "${drift_found}" -eq 0 ]; then
    log_pass "${suite}: consistency of download_file and is_transient_* across all provision scripts"
  else
    log_fail "${suite}: drift detected in download_file implementations"
  fi

  # 3.10 実行権限はあるが壊れている（非ゼロ終了）既存バイナリの自動復旧
  log_test "${suite}: recover from existing broken binary that exits with error"
  local broken_home="${test_dir}/broken_home"
  local broken_tmp="${test_dir}/broken_tmp"
  mkdir -p "${broken_home}/.local/bin" "${broken_tmp}"
  cat > "${broken_home}/.local/bin/herdr" << 'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "${broken_home}/.local/bin/herdr"

  (
    export "${test_env[@]}"
    export HOME="${broken_home}"
    export TMPDIR="${broken_tmp}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
  )

  local recovered=0
  if [ -x "${broken_home}/.local/bin/herdr" ] && "${broken_home}/.local/bin/herdr" >/dev/null 2>&1; then
    recovered=1
  fi

  if [ "${recovered}" -eq 1 ]; then
    log_pass "${suite}: recover from existing broken binary that exits with error"
  else
    log_fail "${suite}: failed to recover broken binary"
  fi

  # 3.11 実行時にハングする既存バイナリのタイムアウト検知と再インストール
  log_test "${suite}: recover from existing hanging binary via verify timeout"
  local hang_home="${test_dir}/hang_home"
  local hang_tmp="${test_dir}/hang_tmp"
  mkdir -p "${hang_home}/.local/bin" "${hang_tmp}"
  cat > "${hang_home}/.local/bin/copilot" << 'EOF'
#!/bin/sh
sleep 10
EOF
  chmod +x "${hang_home}/.local/bin/copilot"

  (
    export "${test_env[@]}"
    export HOME="${hang_home}"
    export TMPDIR="${hang_tmp}"
    export CLI_VERIFY_TIMEOUT=1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  )

  local hang_recovered=0
  if [ -x "${hang_home}/.local/bin/copilot" ] && "${hang_home}/.local/bin/copilot" >/dev/null 2>&1; then
    hang_recovered=1
  fi

  if [ "${hang_recovered}" -eq 1 ]; then
    log_pass "${suite}: recover from existing hanging binary via verify timeout"
  else
    log_fail "${suite}: failed to recover hanging binary"
  fi

  # 3.12 4つのCLIプロビジョニングスクリプト間での verify_cli 関数の共通性検証（ドリフト検査）
  log_test "${suite}: consistency of verify_cli across all CLI provision scripts"
  local cli_scripts=(
    "${REPO_ROOT}/provision/herdr.sh"
    "${REPO_ROOT}/provision/antigravity-cli.sh"
    "${REPO_ROOT}/provision/copilot-cli.sh"
    "${REPO_ROOT}/provision/mise.sh"
  )
  local ref_verify
  ref_verify=$(awk '/^verify_cli\(\)/,/^}$/{print}' "${cli_scripts[0]}")
  local v_drift_found=0
  for s in "${cli_scripts[@]}"; do
    local current_verify
    current_verify=$(awk '/^verify_cli\(\)/,/^}$/{print}' "${s}")
    if [ "${ref_verify}" != "${current_verify}" ]; then
      v_drift_found=1
      echo >&2 "Drift in verify_cli detected in $(basename "${s}")"
    fi
  done
  if [ "${v_drift_found}" -eq 0 ]; then
    log_pass "${suite}: consistency of verify_cli across all CLI provision scripts"
  else
    log_fail "${suite}: drift detected in verify_cli implementations"
  fi

  # 3.13 既存のバイナリが破損していて再インストールを試みる際、ダウンロード失敗時に既存バイナリが削除されないこと
  log_test "${suite}: preserve existing binary when re-download fails"
  local keep_home="${test_dir}/keep_home"
  local keep_tmp="${test_dir}/keep_tmp"
  mkdir -p "${keep_home}/.local/bin" "${keep_tmp}"
  echo "old broken binary content" > "${keep_home}/.local/bin/herdr"
  chmod +x "${keep_home}/.local/bin/herdr"

  local keep_failed=0
  (
    export "${test_env[@]}"
    export HOME="${keep_home}"
    export TMPDIR="${keep_tmp}"
    export STUB_CURL_MODE="permanent_404"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
  ) || keep_failed=1

  if [ "${keep_failed}" -eq 1 ] && [ -e "${keep_home}/.local/bin/herdr" ] && [ "$(cat "${keep_home}/.local/bin/herdr")" = "old broken binary content" ]; then
    log_pass "${suite}: preserve existing binary when re-download fails"
  else
    log_fail "${suite}: existing binary was deleted or overwritten on download failure"
  fi

  # 3.14 再インストール時、インストーラ実行が失敗した場合に既存バイナリが復元されること
  log_test "${suite}: restore existing binary from backup when installer execution fails"
  local restore_home="${test_dir}/restore_home"
  local restore_tmp="${test_dir}/restore_tmp"
  mkdir -p "${restore_home}/.local/bin" "${restore_tmp}"
  echo "original binary before install failure" > "${restore_home}/.local/bin/herdr"
  chmod +x "${restore_home}/.local/bin/herdr"

  local restore_failed=0
  (
    export "${test_env[@]}"
    export STUB_HERDR_INSTALL_FAIL=1
    export HOME="${restore_home}"
    export TMPDIR="${restore_tmp}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
  ) || restore_failed=1

  if [ "${restore_failed}" -eq 1 ] && [ -e "${restore_home}/.local/bin/herdr" ] && \
     [ "$(cat "${restore_home}/.local/bin/herdr")" = "original binary before install failure" ]; then
    log_pass "${suite}: restore existing binary from backup when installer execution fails"
  else
    log_fail "${suite}: existing binary was not restored when installer failed"
  fi

  # 3.15 dangling symlink の再インストール時、インストーラ実行失敗で元の dangling symlink が復元されること
  log_test "${suite}: restore existing dangling symlink from backup when installer fails"
  local link_home="${test_dir}/link_home"
  local link_tmp="${test_dir}/link_tmp"
  mkdir -p "${link_home}/.local/bin" "${link_tmp}"
  ln -s "/nonexistent/target/path" "${link_home}/.local/bin/herdr"

  local link_failed=0
  (
    export "${test_env[@]}"
    export STUB_HERDR_INSTALL_FAIL=1
    export HOME="${link_home}"
    export TMPDIR="${link_tmp}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
  ) || link_failed=1

  if [ "${link_failed}" -eq 1 ] && [ -L "${link_home}/.local/bin/herdr" ] && \
     [ "$(readlink "${link_home}/.local/bin/herdr")" = "/nonexistent/target/path" ]; then
    log_pass "${suite}: restore existing dangling symlink from backup when installer fails"
  else
    log_fail "${suite}: dangling symlink was not restored when installer failed"
  fi

  # 3.16 ユーザー既存の .bak ファイルが再インストール時に上書き・削除されず保持されること
  log_test "${suite}: preserve existing user .bak file during reinstallation"
  local user_bak_home="${test_dir}/user_bak_home"
  local user_bak_tmp="${test_dir}/user_bak_tmp"
  mkdir -p "${user_bak_home}/.local/bin" "${user_bak_tmp}"
  echo "pre-existing user backup" > "${user_bak_home}/.local/bin/herdr.bak"
  cat > "${user_bak_home}/.local/bin/herdr" << 'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "${user_bak_home}/.local/bin/herdr"

  (
    export "${test_env[@]}"
    export HOME="${user_bak_home}"
    export TMPDIR="${user_bak_tmp}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
  )

  local user_bak_preserved=0
  if [ -e "${user_bak_home}/.local/bin/herdr.bak" ] && \
     [ "$(cat "${user_bak_home}/.local/bin/herdr.bak")" = "pre-existing user backup" ]; then
    user_bak_preserved=1
  fi

  if [ "${user_bak_preserved}" -eq 1 ]; then
    log_pass "${suite}: preserve existing user .bak file during reinstallation"
  else
    log_fail "${suite}: user .bak file was overwritten or deleted during reinstallation"
  fi

  # 3.17 copilot-cli.sh: バージョン指定（semver、v/Vプレフィックス有無）での導入と検証
  log_test "${suite}: copilot-cli installs specified version (with/without v prefix)"
  local ver_home="${test_dir}/ver_home"
  local ver_tmp="${test_dir}/ver_tmp"
  mkdir -p "${ver_home}" "${ver_tmp}"
  local ver_success=0
  (
    export "${test_env[@]}"
    export HOME="${ver_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="1.0.91"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) && ver_success=1

  local bin_ver=""
  if [ -x "${ver_home}/.local/bin/copilot" ]; then
    bin_ver=$("${ver_home}/.local/bin/copilot" --version 2>&1 || true)
  fi

  local v_prefix_success=0
  local v_prefix_home="${test_dir}/v_prefix_home"
  mkdir -p "${v_prefix_home}"
  (
    export "${test_env[@]}"
    export HOME="${v_prefix_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="v1.0.91"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) && v_prefix_success=1

  local cap_v_prefix_success=0
  local cap_v_prefix_home="${test_dir}/cap_v_prefix_home"
  mkdir -p "${cap_v_prefix_home}"
  (
    export "${test_env[@]}"
    export HOME="${cap_v_prefix_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="V1.0.91"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) && cap_v_prefix_success=1

  if [ "${ver_success}" -eq 1 ] && [ "${v_prefix_success}" -eq 1 ] && [ "${cap_v_prefix_success}" -eq 1 ] && \
     printf '%s\n' "${bin_ver}" | grep -q "1.0.91"; then
    log_pass "${suite}: copilot-cli installs specified version (with/without v prefix)"
  else
    log_fail "${suite}: copilot-cli failed to install or verify specified version (ver=${ver_success}, v=${v_prefix_success}, V=${cap_v_prefix_success})"
  fi

  # 3.18 copilot-cli.sh: prerelease 指定での導入とタグ解決確認
  log_test "${suite}: copilot-cli installs prerelease version and verifies resolved tag"
  local pre_home="${test_dir}/pre_home"
  mkdir -p "${pre_home}"
  local pre_success=0
  (
    export "${test_env[@]}"
    export HOME="${pre_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="prerelease"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) && pre_success=1

  local pre_no_tag_failed=0
  local pre_no_tag_home="${test_dir}/pre_no_tag_home"
  mkdir -p "${pre_no_tag_home}"
  (
    export "${test_env[@]}"
    export HOME="${pre_no_tag_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="prerelease"
    export STUB_COPILOT_NO_PRERELEASE_TAG=1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) || pre_no_tag_failed=1

  if [ "${pre_success}" -eq 1 ] && [ "${pre_no_tag_failed}" -eq 1 ] && \
     [ -x "${pre_home}/.local/bin/copilot" ] && ! [ -e "${pre_no_tag_home}/.local/bin/copilot" ]; then
    log_pass "${suite}: copilot-cli installs prerelease version and verifies resolved tag"
  else
    log_fail "${suite}: copilot-cli prerelease installation or fallback handling failed"
  fi

  # 3.19 mise.sh: バージョン指定（semver、v/Vプレフィックス有無、latest正規化）での導入と検証
  log_test "${suite}: mise installs specified version and normalizes latest"
  local mise_ver_home="${test_dir}/mise_ver_home"
  mkdir -p "${mise_ver_home}"
  local mise_ver_success=0
  (
    export "${test_env[@]}"
    export HOME="${mise_ver_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_miseVersion="2026.10.7"
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) && mise_ver_success=1

  local mise_v_home="${test_dir}/mise_v_home"
  mkdir -p "${mise_v_home}"
  local mise_v_success=0
  (
    export "${test_env[@]}"
    export HOME="${mise_v_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_miseVersion="v2026.10.7"
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) && mise_v_success=1

  local mise_cap_v_home="${test_dir}/mise_cap_v_home"
  mkdir -p "${mise_cap_v_home}"
  local mise_cap_v_success=0
  (
    export "${test_env[@]}"
    export HOME="${mise_cap_v_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_miseVersion="V2026.10.7"
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) && mise_cap_v_success=1

  local mise_latest_home="${test_dir}/mise_latest_home"
  mkdir -p "${mise_latest_home}"
  local mise_latest_success=0
  (
    export "${test_env[@]}"
    export HOME="${mise_latest_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_miseVersion="latest"
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) && mise_latest_success=1

  if [ "${mise_ver_success}" -eq 1 ] && [ "${mise_v_success}" -eq 1 ] && [ "${mise_cap_v_success}" -eq 1 ] && [ "${mise_latest_success}" -eq 1 ] && \
     grep -q "2026.10.7" <("${mise_ver_home}/.local/bin/mise" --version) && \
     grep -q "2026.10.7" <("${mise_cap_v_home}/.local/bin/mise" --version) && \
     grep -q "2026.10.25" <("${mise_latest_home}/.local/bin/mise" --version); then
    log_pass "${suite}: mise installs specified version and normalizes latest"
  else
    log_fail "${suite}: mise specified version installation or latest normalization failed"
  fi

  # 3.20 暗黙フォールバック（インストーラが指定版を無視して別版を導入）の拒否と未検証バイナリ消去
  log_test "${suite}: reject implicit fallback when installer ignores version"
  local fallback_home="${test_dir}/fallback_home"
  mkdir -p "${fallback_home}"
  local fallback_failed=0
  (
    export "${test_env[@]}"
    export HOME="${fallback_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="1.0.91"
    export STUB_COPILOT_IGNORE_VERSION=1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) || fallback_failed=1

  local mise_fallback_home="${test_dir}/mise_fallback_home"
  mkdir -p "${mise_fallback_home}"
  local mise_fallback_failed=0
  (
    export "${test_env[@]}"
    export HOME="${mise_fallback_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_miseVersion="2026.10.7"
    export STUB_MISE_IGNORE_VERSION=1
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) || mise_fallback_failed=1

  # 破損バイナリからの再インストール時に暗黙フォールバックが発生した場合、元バイナリが復元されること
  local restore_fallback_home="${test_dir}/restore_fallback_home"
  mkdir -p "${restore_fallback_home}/.local/bin"
  echo "original broken binary" > "${restore_fallback_home}/.local/bin/copilot"
  chmod +x "${restore_fallback_home}/.local/bin/copilot"
  local restore_fallback_failed=0
  (
    export "${test_env[@]}"
    export HOME="${restore_fallback_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="1.0.91"
    export STUB_COPILOT_IGNORE_VERSION=1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) || restore_fallback_failed=1

  local restored_content=""
  if [ -e "${restore_fallback_home}/.local/bin/copilot" ]; then
    restored_content=$(cat "${restore_fallback_home}/.local/bin/copilot")
  fi

  if [ "${fallback_failed}" -eq 1 ] && ! [ -e "${fallback_home}/.local/bin/copilot" ] && \
     [ "${mise_fallback_failed}" -eq 1 ] && ! [ -e "${mise_fallback_home}/.local/bin/mise" ] && \
     [ "${restore_fallback_failed}" -eq 1 ] && [ "${restored_content}" = "original broken binary" ]; then
    log_pass "${suite}: reject implicit fallback when installer ignores version"
  else
    log_fail "${suite}: implicit fallback was not rejected or binary cleanup/restore failed"
  fi

  # 3.21 存在しないバージョン指定等でインストーラが非ゼロ終了した場合の失敗とバイナリ不残存
  log_test "${suite}: clean failure when installer fails on invalid/nonexistent version"
  local inst_fail_home="${test_dir}/inst_fail_home"
  mkdir -p "${inst_fail_home}"
  local copilot_fail=0 mise_fail=0
  (
    export "${test_env[@]}"
    export HOME="${inst_fail_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="999.999.999"
    export STUB_COPILOT_INSTALL_FAIL=1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) || copilot_fail=1

  (
    export "${test_env[@]}"
    export HOME="${inst_fail_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_miseVersion="999.999.999"
    export STUB_MISE_INSTALL_FAIL=1
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) || mise_fail=1

  if [ "${copilot_fail}" -eq 1 ] && [ "${mise_fail}" -eq 1 ] && \
     ! [ -e "${inst_fail_home}/.local/bin/copilot" ] && ! [ -e "${inst_fail_home}/.local/bin/mise" ]; then
    log_pass "${suite}: clean failure when installer fails on invalid/nonexistent version"
  else
    log_fail "${suite}: failed installer left residual binary or did not fail"
  fi

  # 3.22 不正なパラメータ形式の即時拒否（ダウンロード前の早期失敗）
  log_test "${suite}: immediate rejection on invalid parameter format"
  local invalid_param_home="${test_dir}/invalid_param_home"
  mkdir -p "${invalid_param_home}"
  local bad_copilot_failed=0 bad_mise_failed=0
  (
    export "${test_env[@]}"
    export HOME="${invalid_param_home}"
    export PARAM_copilotVersion="invalid version string!"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) || bad_copilot_failed=1

  (
    export "${test_env[@]}"
    export HOME="${invalid_param_home}"
    export PARAM_miseVersion="prerelease"
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) || bad_mise_failed=1

  if [ "${bad_copilot_failed}" -eq 1 ] && [ "${bad_mise_failed}" -eq 1 ]; then
    log_pass "${suite}: immediate rejection on invalid parameter format"
  else
    log_fail "${suite}: invalid parameter format was not rejected"
  fi

  # 3.23 インストール時固定の維持: 正常な既存バイナリがある場合は再インストールを行わない
  log_test "${suite}: preserve existing healthy binary across runs without reinstall"
  local keep_exist_home="${test_dir}/keep_exist_home"
  mkdir -p "${keep_exist_home}/.local/bin"
  cat > "${keep_exist_home}/.local/bin/copilot" << 'EOF'
#!/bin/sh
echo "GitHub Copilot CLI 1.0.105."
EOF
  chmod +x "${keep_exist_home}/.local/bin/copilot"

  cat > "${keep_exist_home}/.local/bin/mise" << 'EOF'
#!/bin/sh
echo "2026.10.25 linux-x64 (2026-10-31)"
EOF
  chmod +x "${keep_exist_home}/.local/bin/mise"

  : > "${curl_log}"
  (
    export "${test_env[@]}"
    export HOME="${keep_exist_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="1.0.91"
    export PARAM_miseVersion="2026.10.7"
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  )

  local curl_calls_keep
  curl_calls_keep=$(wc -l < "${curl_log}" | tr -d ' ')

  if [ "${curl_calls_keep}" -eq 0 ] && \
     grep -q "1.0.105" <("${keep_exist_home}/.local/bin/copilot" --version) && \
     grep -q "2026.10.25" <("${keep_exist_home}/.local/bin/mise" --version); then
    log_pass "${suite}: preserve existing healthy binary across runs without reinstall"
  else
    log_fail "${suite}: existing healthy binary was reinstalled or overwritten"
  fi

  # 3.24 インストーラがバイナリ配置後やタグ出力後に非ゼロ終了した場合の失敗検知（終了コード握り潰し防止）
  log_test "${suite}: reject installer failure even after binary placement or prerelease tag"
  local post_fail_home="${test_dir}/post_fail_home"
  mkdir -p "${post_fail_home}"
  local post_copilot_failed=0 post_pre_failed=0 post_mise_failed=0

  (
    export "${test_env[@]}"
    export HOME="${post_fail_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="1.0.91"
    export STUB_COPILOT_FAIL_AFTER_INSTALL=1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) || post_copilot_failed=1

  (
    export "${test_env[@]}"
    export HOME="${post_fail_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_copilotVersion="prerelease"
    export STUB_COPILOT_FAIL_AFTER_PRERELEASE_TAG=1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  ) || post_pre_failed=1

  (
    export "${test_env[@]}"
    export HOME="${post_fail_home}"
    export TMPDIR="${ver_tmp}"
    export PARAM_miseVersion="2026.10.7"
    export STUB_MISE_FAIL_AFTER_INSTALL=1
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) || post_mise_failed=1

  if [ "${post_copilot_failed}" -eq 1 ] && ! [ -e "${post_fail_home}/.local/bin/copilot" ] && \
     [ "${post_pre_failed}" -eq 1 ] && ! [ -e "${post_fail_home}/.local/bin/copilot" ] && \
     [ "${post_mise_failed}" -eq 1 ] && ! [ -e "${post_fail_home}/.local/bin/mise" ]; then
    log_pass "${suite}: reject installer failure even after binary placement or prerelease tag"
  else
    log_fail "${suite}: installer failure was swallowed or residual binary was left uncleaned"
  fi

  # 3.25 verify_cli の厳格な完全一致: 部分一致（1.0.910 や 1.0.91-alpha）の誤認防止
  log_test "${suite}: verify_cli rejects partial version match (1.0.91 vs 1.0.910 or 1.0.91-alpha)"
  local partial_home="${test_dir}/partial_home"
  mkdir -p "${partial_home}/.local/bin"
  local partial_num_failed=0 partial_suffix_failed=0

  cat > "${partial_home}/.local/bin/copilot" << 'EOF'
#!/bin/sh
echo "GitHub Copilot CLI 1.0.910."
EOF
  chmod +x "${partial_home}/.local/bin/copilot"

  local verify_fn
  verify_fn=$(awk '/^verify_cli\(\)/,/^}$/{print}' "${REPO_ROOT}/provision/copilot-cli.sh")
  (
    eval "${verify_fn}"
    if ! verify_cli "copilot" "${partial_home}/.local/bin/copilot" "1.0.91" >/dev/null 2>&1; then
      exit 0
    fi
    exit 1
  ) && partial_num_failed=1

  cat > "${partial_home}/.local/bin/copilot" << 'EOF'
#!/bin/sh
echo "GitHub Copilot CLI 1.0.91-alpha."
EOF
  chmod +x "${partial_home}/.local/bin/copilot"

  (
    eval "${verify_fn}"
    if ! verify_cli "copilot" "${partial_home}/.local/bin/copilot" "1.0.91" >/dev/null 2>&1; then
      exit 0
    fi
    exit 1
  ) && partial_suffix_failed=1

  if [ "${partial_num_failed}" -eq 1 ] && [ "${partial_suffix_failed}" -eq 1 ]; then
    log_pass "${suite}: verify_cli rejects partial version match (1.0.91 vs 1.0.910 or 1.0.91-alpha)"
  else
    log_fail "${suite}: verify_cli incorrectly accepted partial version match"
  fi
}
