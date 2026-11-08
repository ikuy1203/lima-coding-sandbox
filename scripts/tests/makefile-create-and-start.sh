#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 4a: Makefile input normalization, precedence, and make create/start
# -----------------------------------------------------------------------------
test_makefile_create_and_start() {
  local suite="Makefile rules and safety checks"
  local test_dir="${MASTER_TEST_DIR}/makefile_create_and_start"
  setup_makefile_test_env "${test_dir}"
  local fake_bin="${test_dir}/bin"
  local lima_log="${test_dir}/limactl.log"
  local empty_env="${test_dir}/empty.env"

  # --param の直後の引数が期待値と一致するかを検査する補助関数
  has_param_value() {
    local val=$1
    awk -v target="$val" '$0 == "--param" { getline; if ($0 == target) found=1 } END { exit !found }' "${lima_log}"
  }

  # 4.1 値の優先順位: コマンドライン引数 > .env > ホスト git config
  log_test "${suite}: parameter precedence (CLI > .env > host git)"
  local custom_env="${test_dir}/test.env"
  cat > "${custom_env}" << 'EOF'
GIT_USER_NAME="Env Name"
GIT_USER_EMAIL="env@example.com"
BLOCK_HOST_LOOPBACK=true
AGENT_INSTRUCTIONS=false
EOF

  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" create ENV_FILE="${custom_env}" GIT_USER_NAME="CLI Name" >/dev/null 2>&1
  )

  # 引数境界を崩さずに --param <値> のペアを厳密に照合
  if has_param_value "gitUserName=CLI Name" && \
     has_param_value "gitUserEmail=env@example.com" && \
     has_param_value "blockHostLoopback=true" && \
     has_param_value "agentInstructions=false"; then
    log_pass "${suite}: parameter precedence (CLI > .env > host git)"
  else
    log_fail "${suite}: parameter precedence failed"
  fi

  # 4.2 値の正規化: 前後の空白、カンマ、引用符の除去（引数境界の厳密検査）
  log_test "${suite}: whitespace, comma and quote normalization"
  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" create \
      ENV_FILE="${empty_env}" \
      GIT_USER_NAME='  "Doe, John"  ' \
      GIT_USER_EMAIL="  'john@example.com' " >/dev/null 2>&1
  )

  # カンマを含む "Doe, John" が分割されず単一の引数として渡っているか検証
  if has_param_value "gitUserName=Doe, John" && \
     has_param_value "gitUserEmail=john@example.com"; then
    log_pass "${suite}: whitespace, comma and quote normalization"
  else
    log_fail "${suite}: normalization failed"
  fi

  # 4.3 ホストマウント検出（create 時のテンプレートマウント検出）
  log_test "${suite}: make create rejects host mounts"
  : > "${lima_log}"
  local mount_rejected=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_TEMPLATE_MOUNTS=1
    make -f "${REPO_ROOT}/Makefile" create ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || mount_rejected=1

  if [ "${mount_rejected}" -eq 1 ] && ! grep -qx "create" "${lima_log}"; then
    log_pass "${suite}: make create rejects host mounts"
  else
    log_fail "${suite}: make create did not reject host mount"
  fi

  # 4.4 ホストマウント検出（start 時の既存インスタンスマウント検出と停止）
  log_test "${suite}: make start detects mount and stops running instance"
  : > "${lima_log}"
  local start_rejected=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_INSTANCE_MOUNTS=1
    make -f "${REPO_ROOT}/Makefile" start ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || start_rejected=1

  local stopped_called
  stopped_called=$(grep -cx "stop" "${lima_log}" || true)

  if [ "${start_rejected}" -eq 1 ] && [ "${stopped_called}" -ge 1 ]; then
    log_pass "${suite}: make start detects mount and stops running instance"
  else
    log_fail "${suite}: make start did not stop running instance on mount detection"
  fi

  # 4.5 limactl start 失敗時のエラー伝播とマウント検出時の停止
  log_test "${suite}: make start detects mount and stops on start failure"
  : > "${lima_log}"
  local start_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    export STUB_INSTANCE_MOUNTS=0
    export STUB_START_FAIL=1
    make -f "${REPO_ROOT}/Makefile" start ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || start_failed=1

  # さらに起動失敗後にマウントが検出されたケース（非ゼロ終了と stop の両方を検証）
  : > "${lima_log}"
  local start_mount_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    export STUB_INSTANCE_MOUNTS=0
    export STUB_MOUNT_AFTER_START_FAIL=1
    export STUB_START_FAIL=1
    make -f "${REPO_ROOT}/Makefile" start ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || start_mount_failed=1

  local fail_stopped_called
  fail_stopped_called=$(grep -cx "stop" "${lima_log}" || true)

  if [ "${start_failed}" -eq 1 ] && [ "${start_mount_failed}" -eq 1 ] && [ "${fail_stopped_called}" -ge 1 ]; then
    log_pass "${suite}: make start detects mount and stops on start failure"
  else
    log_fail "${suite}: failure handling or stop call failed"
  fi

  # 4.6 COPILOT_VERSION と MISE_VERSION の優先順位、正規化、および --param 受け渡し
  log_test "${suite}: CLI version precedence, normalization, and --param passing"
  local ver_env="${test_dir}/ver.env"
  cat > "${ver_env}" << 'EOF'
COPILOT_VERSION="1.0.90"
MISE_VERSION=' 2026.10.6 '
EOF

  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" create ENV_FILE="${ver_env}" COPILOT_VERSION=' "1.0.91" ' >/dev/null 2>&1
  )

  local has_copilot_param=0 has_mise_param=0
  if has_param_value "copilotVersion=1.0.91"; then
    has_copilot_param=1
  fi
  if has_param_value "miseVersion=2026.10.6"; then
    has_mise_param=1
  fi

  # latest 指定時は --param が省略されることの検証
  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" create ENV_FILE="${empty_env}" COPILOT_VERSION="latest" MISE_VERSION="latest" >/dev/null 2>&1
  )

  local copilot_omitted=0 mise_omitted=0
  if ! grep -q "copilotVersion=" "${lima_log}"; then
    copilot_omitted=1
  fi
  if ! grep -q "miseVersion=" "${lima_log}"; then
    mise_omitted=1
  fi

  if [ "${has_copilot_param}" -eq 1 ] && [ "${has_mise_param}" -eq 1 ] && \
     [ "${copilot_omitted}" -eq 1 ] && [ "${mise_omitted}" -eq 1 ]; then
    log_pass "${suite}: CLI version precedence, normalization, and --param passing"
  else
    log_fail "${suite}: CLI version precedence or normalization failed"
  fi

  # 4.7 不正な COPILOT_VERSION / MISE_VERSION の拒否
  log_test "${suite}: make create rejects invalid COPILOT_VERSION and MISE_VERSION"
  : > "${lima_log}"
  local bad_copilot_rej=0 bad_mise_rej=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" create ENV_FILE="${empty_env}" COPILOT_VERSION="invalid;string" >/dev/null 2>&1
  ) || bad_copilot_rej=1

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" create ENV_FILE="${empty_env}" MISE_VERSION="prerelease" >/dev/null 2>&1
  ) || bad_mise_rej=1

  if [ "${bad_copilot_rej}" -eq 1 ] && [ "${bad_mise_rej}" -eq 1 ] && ! grep -qx "create" "${lima_log}"; then
    log_pass "${suite}: make create rejects invalid COPILOT_VERSION and MISE_VERSION"
  else
    log_fail "${suite}: make create did not reject invalid version parameter"
  fi

  # 4.10 空の NAME 指定時（make delete NAME= YES=1 等）に既定 VM を操作せず即エラー終了すること
  log_test "${suite}: reject empty NAME without touching default coding-sandbox instance"
  : > "${lima_log}"
  local empty_del_rc=0 empty_stop_rc=0 empty_create_rc=0 empty_start_rc=0 empty_shell_rc=0 empty_status_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" NAME= YES=1 >/dev/null 2>&1
  ) || empty_del_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    make -f "${REPO_ROOT}/Makefile" stop ENV_FILE="${empty_env}" NAME=' "" ' >/dev/null 2>&1
  ) || empty_stop_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" create ENV_FILE="${empty_env}" NAME= >/dev/null 2>&1
  ) || empty_create_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" start ENV_FILE="${empty_env}" NAME= >/dev/null 2>&1
  ) || empty_start_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" shell ENV_FILE="${empty_env}" NAME= >/dev/null 2>&1
  ) || empty_shell_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" status ENV_FILE="${empty_env}" NAME= >/dev/null 2>&1
  ) || empty_status_rc=$?

  local empty_name_lima_calls
  empty_name_lima_calls=$(wc -l < "${lima_log}" | tr -d ' ')

  if [ "${empty_del_rc}" -ne 0 ] && [ "${empty_stop_rc}" -ne 0 ] && \
     [ "${empty_create_rc}" -ne 0 ] && [ "${empty_start_rc}" -ne 0 ] && \
     [ "${empty_shell_rc}" -ne 0 ] && [ "${empty_status_rc}" -ne 0 ] && \
     [ "${empty_name_lima_calls}" -eq 0 ]; then
    log_pass "${suite}: reject empty NAME without touching default coding-sandbox instance"
  else
    log_fail "${suite}: empty NAME was not rejected or triggered limactl calls (calls=${empty_name_lima_calls})"
  fi

  # 4.11 引用符・内側空白付きのリソース・タイムアウト・NAME 指定（.env および CLI）の全ターゲット一貫性
  log_test "${suite}: normalize quoted/spaced NAME, CPUS, MEMORY, DISK, and TIMEOUT across targets"
  local resource_env="${test_dir}/resource.env"
  cat > "${resource_env}" << 'EOF'
NAME=" sandbox-quoted "
CPUS="8"
MEMORY=' 16 '
DISK="200"
TIMEOUT="30m"
EOF

  : > "${lima_log}"
  local quoted_start_ok=0 quoted_targets_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" start ENV_FILE="${resource_env}" 'DISK="250"' 'TIMEOUT="45m"' >/dev/null 2>&1
  ) && quoted_start_ok=1

  local target_log="${test_dir}/target_name.log"
  quoted_targets_ok=1
  local tgt expected_count actual_norm actual_unnorm
  for tgt in shell herdr status pubkey logs; do
    : > "${target_log}"
    if ! (
      export PATH="${fake_bin}:${PATH}"
      export STUB_LIMACTL_LOG="${target_log}"
      export STUB_LIMA_STATUS_OUTPUT="sandbox2 Running"
      make -f "${REPO_ROOT}/Makefile" "${tgt}" ENV_FILE="${empty_env}" 'NAME=" sandbox2 "' >/dev/null 2>&1
    ); then
      quoted_targets_ok=0
      break
    fi
    case "${tgt}" in
      shell|herdr) expected_count=3 ;;
      *) expected_count=1 ;;
    esac
    actual_unnorm=$(grep -cx -- " sandbox2 " "${target_log}" || true)
    actual_norm=$(grep -cx -- "sandbox2" "${target_log}" || true)
    if [ "${actual_unnorm}" -ne 0 ] || [ "${actual_norm}" -ne "${expected_count}" ]; then
      quoted_targets_ok=0
      break
    fi
  done

  if [ "${quoted_start_ok}" -eq 1 ] && [ "${quoted_targets_ok}" -eq 1 ] && \
     grep -qx -- "--name=sandbox-quoted" "${lima_log}" && \
     grep -qx -- "--cpus=8" "${lima_log}" && \
     grep -qx -- "--memory=16" "${lima_log}" && \
     grep -qx -- "--disk=250" "${lima_log}" && \
     grep -qx -- "--timeout=45m" "${lima_log}" && \
     grep -qx -- "sandbox-quoted" "${lima_log}"; then
    log_pass "${suite}: normalize quoted/spaced NAME, CPUS, MEMORY, DISK, and TIMEOUT across targets"
  else
    log_fail "${suite}: quoted resource or NAME normalization across targets failed"
  fi
}
