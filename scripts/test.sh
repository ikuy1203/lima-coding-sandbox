#!/bin/bash
# プロビジョニングスクリプトと Makefile の回帰テスト
#
# 外部通信や root 権限に依存せず、一時ディレクトリとスタブコマンドを用いて
# 冪等性、設定保持、途中失敗からの回復、Makefile の入力正規化などを検証する。
#
#   $ make test または bash ./scripts/test.sh
# shellcheck disable=SC2030,SC2031
set -eu -o pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "${REPO_ROOT}"

PASS_COUNT=0
FAIL_COUNT=0

# ホストの Git 設定・実行時環境変数との完全な隔離
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_SYSTEM=/dev/null
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE

# 全テスト用の一時ディレクトリ（異常終了時も含め EXIT trap で確実に削除）
MASTER_TEST_DIR=$(mktemp -d)
trap 'rm -rf "${MASTER_TEST_DIR}"' EXIT

log_test() {
  printf '==> RUN   %s\n' "$1"
}

log_pass() {
  printf '    PASS: %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

log_fail() {
  printf '    FAIL: %s\n' "$1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

count_dir_entries() {
  find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}

# -----------------------------------------------------------------------------
# Test Suite 1: provision/git-config.sh
# -----------------------------------------------------------------------------
test_git_config() {
  local suite="provision/git-config.sh"
  local test_dir="${MASTER_TEST_DIR}/git_config"
  mkdir -p "${test_dir}"

  local fake_home="${test_dir}/home"
  mkdir -p "${fake_home}"

  # 1.1 初回実行: 鍵生成、署名設定、署名付きコミットと検証
  log_test "${suite}: initial setup and commit signing verification"
  (
    export HOME="${fake_home}"
    export XDG_CONFIG_HOME="${fake_home}/.config"
    export GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig"
    export PARAM_gitUserName="Test User"
    export PARAM_gitUserEmail="test@example.com"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  )

  local key="${fake_home}/.ssh/id_ed25519_signing"
  local pub="${key}.pub"
  if [ -f "${key}" ] && [ -f "${pub}" ]; then
    # 一時 Git リポジトリで実際に署名付きコミットと検証を行う
    local repo_dir="${test_dir}/repo"
    mkdir -p "${repo_dir}"
    (
      cd "${repo_dir}"
      HOME="${fake_home}" XDG_CONFIG_HOME="${fake_home}/.config" GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig" git init -q
      HOME="${fake_home}" XDG_CONFIG_HOME="${fake_home}/.config" GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig" git config user.name "Test User"
      HOME="${fake_home}" XDG_CONFIG_HOME="${fake_home}/.config" GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig" git config user.email "test@example.com"
      HOME="${fake_home}" XDG_CONFIG_HOME="${fake_home}/.config" GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig" git commit --allow-empty -q -m "initial commit"
      HOME="${fake_home}" XDG_CONFIG_HOME="${fake_home}/.config" GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig" git verify-commit HEAD >/dev/null 2>&1
    )
    log_pass "${suite}: initial setup and commit signing verification"
  else
    log_fail "${suite}: initial setup failed (keys missing)"
  fi

  # 1.2 冪等性: 2 回目を実行しても鍵が変わらず、allowed_signers の行が重複しない
  log_test "${suite}: idempotency across repeated runs"
  local key_md5_before
  key_md5_before=$(cksum "${key}")
  local allowed_lines_before
  allowed_lines_before=$(wc -l < "${fake_home}/.config/git/allowed_signers" | tr -d ' ')

  (
    export HOME="${fake_home}"
    export XDG_CONFIG_HOME="${fake_home}/.config"
    export GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig"
    export PARAM_gitUserName="Test User"
    export PARAM_gitUserEmail="test@example.com"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  )

  local key_md5_after
  key_md5_after=$(cksum "${key}")
  local allowed_lines_after
  allowed_lines_after=$(wc -l < "${fake_home}/.config/git/allowed_signers" | tr -d ' ')

  if [ "${key_md5_before}" = "${key_md5_after}" ] && [ "${allowed_lines_before}" = "${allowed_lines_after}" ]; then
    log_pass "${suite}: idempotency across repeated runs"
  else
    log_fail "${suite}: idempotency violated (key changed or lines duplicated)"
  fi

  # 1.3 途中失敗からの回復: 公開鍵だけが欠損している場合に復元される
  log_test "${suite}: restore missing public key from private key"
  rm -f "${pub}"
  (
    export HOME="${fake_home}"
    export XDG_CONFIG_HOME="${fake_home}/.config"
    export GIT_CONFIG_GLOBAL="${fake_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  )
  if [ -f "${pub}" ]; then
    log_pass "${suite}: restore missing public key from private key"
  else
    log_fail "${suite}: failed to restore missing public key"
  fi

  # 1.4 既存設定の保持: 既にユーザ名や独自の署名形式（openpgp）が設定されている場合は上書きしない
  log_test "${suite}: preserve existing custom user and gpg settings"
  local custom_home="${test_dir}/custom_home"
  mkdir -p "${custom_home}"
  HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global user.name "Original Name"
  HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global user.email "original@example.com"
  HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global gpg.format "openpgp"
  HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global user.signingkey "0x12345678"

  (
    export HOME="${custom_home}"
    export XDG_CONFIG_HOME="${custom_home}/.config"
    export GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig"
    export PARAM_gitUserName="New Name"
    export PARAM_gitUserEmail="new@example.com"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  )

  local actual_name actual_email actual_format actual_key
  actual_name=$(HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global user.name)
  actual_email=$(HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global user.email)
  actual_format=$(HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global gpg.format)
  actual_key=$(HOME="${custom_home}" XDG_CONFIG_HOME="${custom_home}/.config" GIT_CONFIG_GLOBAL="${custom_home}/.gitconfig" git config --global user.signingkey)

  if [ "${actual_name}" = "Original Name" ] && \
     [ "${actual_email}" = "original@example.com" ] && \
     [ "${actual_format}" = "openpgp" ] && \
     [ "${actual_key}" = "0x12345678" ]; then
    log_pass "${suite}: preserve existing custom user and gpg settings"
  else
    log_fail "${suite}: existing settings overwritten"
  fi
}

# -----------------------------------------------------------------------------
# Test Suite 2: provision/agent-instructions.sh
# -----------------------------------------------------------------------------
test_agent_instructions() {
  local suite="provision/agent-instructions.sh"
  local test_dir="${MASTER_TEST_DIR}/agent_instructions"
  mkdir -p "${test_dir}"

  local fake_home="${test_dir}/home"
  mkdir -p "${fake_home}"

  local copilot_file="${fake_home}/.copilot/copilot-instructions.md"
  local agy_file="${fake_home}/.gemini/config/rules/lima-coding-sandbox.md"

  # 2.1 既定値（false）ではファイルが生成されない
  log_test "${suite}: default (false) creates no files"
  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="false"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  if [ ! -f "${copilot_file}" ] && [ ! -f "${agy_file}" ]; then
    log_pass "${suite}: default (false) creates no files"
  else
    log_fail "${suite}: files created unexpectedly when false"
  fi

  # 2.2 有効化（true）と冪等性
  log_test "${suite}: enable (true) and idempotency"
  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="true"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local b_count1 e_count1
  b_count1=$(grep -c "BEGIN lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  e_count1=$(grep -c "END lima-coding-sandbox agent-instructions" "${copilot_file}" || true)

  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="true"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local b_count2 e_count2
  b_count2=$(grep -c "BEGIN lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  e_count2=$(grep -c "END lima-coding-sandbox agent-instructions" "${copilot_file}" || true)

  if [ -f "${agy_file}" ] && [ "${b_count1}" -eq 1 ] && [ "${e_count1}" -eq 1 ] && \
     [ "${b_count2}" -eq 1 ] && [ "${e_count2}" -eq 1 ]; then
    log_pass "${suite}: enable (true) and idempotency"
  else
    log_fail "${suite}: files not created or markers duplicated"
  fi

  # 2.3 既存の独自指示の保持と無効化時のクリーンアップ
  log_test "${suite}: preserve custom instructions and cleanup managed block"
  printf '# Custom Top Instruction\n\n' > "${copilot_file}.new"
  cat "${copilot_file}" >> "${copilot_file}.new"
  printf '\n\n# Custom Bottom Instruction\n' >> "${copilot_file}.new"
  mv "${copilot_file}.new" "${copilot_file}"

  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="true"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local has_custom_top has_custom_bottom
  has_custom_top=$(grep -c "Custom Top Instruction" "${copilot_file}" || true)
  has_custom_bottom=$(grep -c "Custom Bottom Instruction" "${copilot_file}" || true)

  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="false"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local b_count_after e_count_after custom_after
  b_count_after=$(grep -c "BEGIN lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  e_count_after=$(grep -c "END lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  custom_after=$(grep -c "Custom Top Instruction" "${copilot_file}" || true)

  if [ "${has_custom_top}" -eq 1 ] && [ "${has_custom_bottom}" -eq 1 ] && \
     [ "${b_count_after}" -eq 0 ] && [ "${e_count_after}" -eq 0 ] && \
     [ "${custom_after}" -eq 1 ] && [ ! -f "${agy_file}" ]; then
    log_pass "${suite}: preserve custom instructions and cleanup managed block"
  else
    log_fail "${suite}: custom instructions lost or managed block not cleaned up"
  fi

  # 2.4 利用者の独自ルールファイル（agy_file）は false 時に削除されないこと
  log_test "${suite}: preserve user custom antigravity rules"
  mkdir -p "$(dirname "${agy_file}")"
  echo "# Custom Rule without marker" > "${agy_file}"
  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="false"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  if [ -f "${agy_file}" ] && grep -q "Custom Rule without marker" "${agy_file}"; then
    log_pass "${suite}: preserve user custom antigravity rules"
  else
    log_fail "${suite}: custom antigravity rule overwritten or deleted"
  fi

  # 2.5 不正な値の検証
  log_test "${suite}: reject invalid parameter"
  if (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="invalid_value"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  ); then
    log_fail "${suite}: should fail on invalid param"
  else
    log_pass "${suite}: reject invalid parameter"
  fi
}

# -----------------------------------------------------------------------------
# Test Suite 3: provision/{herdr,antigravity-cli,copilot-cli,mise}.sh with stub curl
# -----------------------------------------------------------------------------
test_cli_provisioning() {
  local suite="provision/CLI installers"
  local test_dir="${MASTER_TEST_DIR}/cli_provisioning"
  mkdir -p "${test_dir}"

  local fake_home="${test_dir}/home"
  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_home}" "${fake_bin}"

  # スタブ curl: -o でのスクリプト出力、-w '%{http_code}'、モード別エラー/リトライ制御に対応
  cat > "${fake_bin}/curl" << 'EOF'
#!/bin/bash
set -eu

dest=""
write_out=""
url=""

args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  arg="${args[$i]}"
  case "$arg" in
    -o)
      i=$((i + 1))
      dest="${args[$i]}"
      ;;
    -w)
      i=$((i + 1))
      write_out="${args[$i]}"
      ;;
    http://*|https://*)
      url="$arg"
      ;;
  esac
  i=$((i + 1))
done

if [ -n "${STUB_CURL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "${STUB_CURL_LOG}"
fi

count_file="${STUB_CURL_COUNT_FILE:-}"
count=1
if [ -n "${count_file}" ]; then
  if [ -f "${count_file}" ]; then
    count=$(($(cat "${count_file}") + 1))
  fi
  printf '%s' "${count}" > "${count_file}"
fi

mode="${STUB_CURL_MODE:-default}"

case "${mode}" in
  retry_then_success)
    # 1回目: HTTP 503 (exit 22), 2回目: exit 7 (connect fail), 3回目以降: 成功
    if [ "${count}" -eq 1 ]; then
      if [ -n "${write_out}" ]; then printf '503'; fi
      exit 22
    elif [ "${count}" -eq 2 ]; then
      exit 7
    fi
    ;;
  http200_fail_then_success)
    # 1回目: HTTP 200 受信後の転送中断 (exit 18), 2回目: HTTP 200 受信後のタイムアウト (exit 28), 3回目以降: 成功
    if [ "${count}" -eq 1 ]; then
      if [ -n "${dest}" ]; then echo "partial-script-fragment" > "${dest}"; fi
      if [ -n "${write_out}" ]; then printf '200'; fi
      exit 18
    elif [ "${count}" -eq 2 ]; then
      if [ -n "${write_out}" ]; then printf '200'; fi
      exit 28
    fi
    ;;
  empty_then_404)
    # 1回目: HTTP 200・空本文 (exit 0, 0 bytes)
    # 2回目: HTTP 404 (exit 22) -> 即時失敗すべき（前回の空本文判定が持ち越されてリトライされてはならない）
    if [ "${count}" -eq 1 ]; then
      if [ -n "${dest}" ]; then : > "${dest}"; fi
      if [ -n "${write_out}" ]; then printf '200'; fi
      exit 0
    elif [ "${count}" -eq 2 ]; then
      if [ -n "${write_out}" ]; then printf '404'; fi
      exit 22
    fi
    ;;
  permanent_404)
    if [ -n "${write_out}" ]; then printf '404'; fi
    exit 22
    ;;
  timeout)
    exit 28
    ;;
  partial_fail)
    if [ -n "${dest}" ]; then
      echo "touch \"${STUB_MARKER_PARTIAL:-/tmp/partial_marker}\"" > "${dest}"
    fi
    exit 18
    ;;
  fail)
    exit 1
    ;;
esac

if [ -n "${dest}" ]; then
  case "${url}" in
    *herdr.dev/install.sh*)
      cat << 'INS' > "${dest}"
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/herdr"
#!/bin/sh
echo "herdr stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/herdr"
INS
      ;;
    *antigravity.google/cli/install.sh*)
      cat << 'INS' > "${dest}"
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/agy"
#!/bin/sh
echo "agy stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/agy"
INS
      ;;
    *gh.io/copilot-install*)
      cat << 'INS' > "${dest}"
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/copilot"
#!/bin/sh
echo "copilot stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/copilot"
INS
      ;;
    *mise.run*)
      cat << 'INS' > "${dest}"
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/mise"
#!/bin/sh
echo "mise stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/mise"
INS
      ;;
    *)
      printf 'stub-content\n' > "${dest}"
      ;;
  esac
fi

if [ -n "${write_out}" ]; then
  printf '200'
fi
exit 0
EOF
  chmod +x "${fake_bin}/curl"

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
}

# -----------------------------------------------------------------------------
# Test Suite 4: Makefile input normalization, precedence and mount detection
# -----------------------------------------------------------------------------
test_makefile_logic() {
  local suite="Makefile rules and safety checks"
  local test_dir="${MASTER_TEST_DIR}/makefile_logic"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"

  # スタブ limactl: 引数境界を崩さずに 1 引数 1 行でログに記録する
  cat > "${fake_bin}/limactl" << 'EOF'
#!/bin/bash
set -eu
for arg in "$@"; do
  printf '%s\n' "$arg" >> "${STUB_LIMACTL_LOG}"
done
printf '%s\n' '---CMD_DELIM---' >> "${STUB_LIMACTL_LOG}"

cmd=""
for arg in "$@"; do
  case "$arg" in
    template|list|create|start|stop)
      cmd="$arg"
      break
      ;;
  esac
done

case "$cmd" in
  template)
    if [ "${STUB_TEMPLATE_MOUNTS:-0}" = "1" ]; then
      echo "- location: /Users/test/mounted"
    fi
    exit 0
    ;;
  list)
    case "$*" in
      *Name*Status*)
        # get-status
        echo "${STUB_LIMA_STATUS_OUTPUT:-}"
        exit 0
        ;;
      *Mounts*)
        if [ "${STUB_INSTANCE_MOUNTS:-0}" = "1" ]; then
          echo "- location: /Users/test/mounted"
        elif [ "${STUB_MOUNT_AFTER_START_FAIL:-0}" = "1" ] && grep -qx "start" "${STUB_LIMACTL_LOG}"; then
          echo "- location: /Users/test/mounted"
        fi
        exit 0
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  create)
    if [ "${STUB_CREATE_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  start)
    if [ "${STUB_START_FAIL:-0}" = "1" ]; then
      exit 42
    fi
    exit 0
    ;;
  stop)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/limactl"

  # スタブ git: git config --global の値を返す
  cat > "${fake_bin}/git" << 'EOF'
#!/bin/bash
set -eu
if [ "$*" = "config --global user.name" ]; then
  echo "Host Git Name"
elif [ "$*" = "config --global user.email" ]; then
  echo "host@example.com"
else
  exit 0
fi
EOF
  chmod +x "${fake_bin}/git"

  local lima_log="${test_dir}/limactl.log"
  local empty_env="${test_dir}/empty.env"
  touch "${empty_env}"

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
}

# -----------------------------------------------------------------------------
# Test Suite 5: provision/{github-cli,docker-engine}.sh apt keyring and sources
# -----------------------------------------------------------------------------
test_apt_key_provisioning() {
  local suite="provision/apt keyrings"
  local test_dir="${MASTER_TEST_DIR}/apt_key_provisioning"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"

  # スタブ dpkg
  cat > "${fake_bin}/dpkg" << 'EOF'
#!/bin/bash
set -eu
case "$*" in
  *--print-architecture*)
    echo "amd64"
    exit 0
    ;;
  *--get-selections*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/dpkg"

  # スタブ apt-get (macOS ホストなどの非 Linux 環境用)
  cat > "${fake_bin}/apt-get" << 'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${fake_bin}/apt-get"

  # スタブ curl: 鍵の出力とエラー制御
  cat > "${fake_bin}/curl" << 'EOF'
#!/bin/bash
set -eu

dest=""
write_out=""
url=""

args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  arg="${args[$i]}"
  case "$arg" in
    -o)
      i=$((i + 1))
      dest="${args[$i]}"
      ;;
    -w)
      i=$((i + 1))
      write_out="${args[$i]}"
      ;;
    http://*|https://*)
      url="$arg"
      ;;
  esac
  i=$((i + 1))
done

if [ -n "${STUB_CURL_LOG:-}" ]; then
  printf '%s\n' "$*" >> "${STUB_CURL_LOG}"
fi

mode="${STUB_CURL_MODE:-default}"

case "${mode}" in
  partial_fail)
    if [ -n "${dest}" ]; then
      echo "corrupted-partial-key-data" > "${dest}"
    fi
    exit 18
    ;;
  fail)
    exit 1
    ;;
esac

if [ -n "${dest}" ]; then
  case "${url}" in
    *githubcli-archive-keyring.gpg*)
      printf 'valid-githubcli-keyring\n' > "${dest}"
      ;;
    *download.docker.com/linux/ubuntu/gpg*)
      printf 'valid-docker-keyring\n' > "${dest}"
      ;;
    *)
      printf 'valid-content\n' > "${dest}"
      ;;
  esac
fi

if [ -n "${write_out}" ]; then
  printf '200'
fi
exit 0
EOF
  chmod +x "${fake_bin}/curl"

  local curl_log="${test_dir}/curl.log"
  local test_env=(
    "PATH=${fake_bin}:${PATH}"
    "STUB_CURL_LOG=${curl_log}"
    "DOWNLOAD_RETRY_DELAY=0"
    "DOWNLOAD_CONNECT_TIMEOUT=1"
    "DOWNLOAD_MAX_TIME=2"
    "DOWNLOAD_TOTAL_MAX_TIME=5"
    "DOWNLOAD_RETRY_COUNT=2"
    "DOCKER_UBUNTU_CODENAME=noble"
  )

  # 5.1 github-cli.sh: 初回作成、冪等性、一時ファイル消去
  log_test "${suite}: github-cli setup, idempotency, and tmp cleanup"
  local gh_dir="${test_dir}/gh"
  local gh_tmp="${test_dir}/gh_tmp"
  mkdir -p "${gh_dir}" "${gh_tmp}"

  local gh_key="${gh_dir}/githubcli.gpg"
  local gh_repo="${gh_dir}/githubcli.list"

  : > "${curl_log}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local gh_calls_1 gh_tmp_1
  gh_calls_1=$(wc -l < "${curl_log}" | tr -d ' ')
  gh_tmp_1=$(count_dir_entries "${gh_tmp}")

  # 2回目実行: 設定ファイルが存在するため curl は呼ばれない
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local gh_calls_2
  gh_calls_2=$(wc -l < "${curl_log}" | tr -d ' ')

  if [ -f "${gh_key}" ] && [ -f "${gh_repo}" ] && \
     [ "${gh_calls_1}" -eq 1 ] && [ "${gh_calls_2}" -eq 1 ] && \
     [ "${gh_tmp_1}" -eq 0 ]; then
    log_pass "${suite}: github-cli setup, idempotency, and tmp cleanup"
  else
    log_fail "${suite}: github-cli setup or idempotency failed"
  fi

  # 5.2 docker-engine.sh: 初回作成、冪等性、一時ファイル消去
  log_test "${suite}: docker-engine setup, idempotency, and tmp cleanup"
  local docker_dir="${test_dir}/docker"
  local docker_tmp="${test_dir}/docker_tmp"
  mkdir -p "${docker_dir}" "${docker_tmp}"

  local docker_key="${docker_dir}/docker.asc"
  local docker_src="${docker_dir}/docker.sources"
  local docker_wrap="${docker_dir}/docker"

  : > "${curl_log}"
  (
    export "${test_env[@]}"
    export TMPDIR="${docker_tmp}"
    export DOCKER_KEYRING="${docker_key}"
    export DOCKER_SOURCES="${docker_src}"
    export DOCKER_WRAPPER="${docker_wrap}"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local docker_calls_1 docker_tmp_1
  docker_calls_1=$(wc -l < "${curl_log}" | tr -d ' ')
  docker_tmp_1=$(count_dir_entries "${docker_tmp}")

  # 2回目実行
  (
    export "${test_env[@]}"
    export TMPDIR="${docker_tmp}"
    export DOCKER_KEYRING="${docker_key}"
    export DOCKER_SOURCES="${docker_src}"
    export DOCKER_WRAPPER="${docker_wrap}"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local docker_calls_2
  docker_calls_2=$(wc -l < "${curl_log}" | tr -d ' ')

  if [ -f "${docker_key}" ] && [ -f "${docker_src}" ] && [ -x "${docker_wrap}" ] && \
     [ "${docker_calls_1}" -eq 1 ] && [ "${docker_calls_2}" -eq 1 ] && \
     [ "${docker_tmp_1}" -eq 0 ]; then
    log_pass "${suite}: docker-engine setup, idempotency, and tmp cleanup"
  else
    log_fail "${suite}: docker-engine setup or idempotency failed"
  fi

  # 5.3 途中失敗時に既存の正常な鍵ファイルを破損させないこと
  log_test "${suite}: preserve existing valid keyring file on download failure"
  local corrupt_dir="${test_dir}/corrupt"
  local corrupt_tmp="${test_dir}/corrupt_tmp"
  mkdir -p "${corrupt_dir}" "${corrupt_tmp}"

  local corrupt_key="${corrupt_dir}/docker.asc"
  local corrupt_src="${corrupt_dir}/docker.sources"
  echo "pre-existing-good-key" > "${corrupt_key}"

  local corrupt_failed=0
  (
    export "${test_env[@]}"
    export TMPDIR="${corrupt_tmp}"
    export DOCKER_KEYRING="${corrupt_key}"
    export DOCKER_SOURCES="${corrupt_src}"
    export DOCKER_WRAPPER="${corrupt_dir}/docker"
    export STUB_CURL_MODE="partial_fail"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  ) || corrupt_failed=1

  local key_content=""
  if [ -f "${corrupt_key}" ]; then
    key_content=$(cat "${corrupt_key}")
  fi
  local corrupt_tmp_leftover
  corrupt_tmp_leftover=$(count_dir_entries "${corrupt_tmp}")

  if [ "${corrupt_failed}" -eq 1 ] && \
     [ "${key_content}" = "pre-existing-good-key" ] && \
     [ "${corrupt_tmp_leftover}" -eq 0 ]; then
    log_pass "${suite}: preserve existing valid keyring file on download failure"
  else
    log_fail "${suite}: pre-existing keyring was overwritten or corrupted or tmp leftover"
  fi

  # 5.4 既存の空・破損した Docker ラッパーが正常な実行可能スクリプトに復旧すること
  log_test "${suite}: recover corrupted or empty existing docker wrapper"
  local recover_dir="${test_dir}/recover_wrapper"
  local recover_tmp="${test_dir}/recover_tmp"
  mkdir -p "${recover_dir}" "${recover_tmp}"

  local rec_key="${recover_dir}/docker.asc"
  local rec_src="${recover_dir}/docker.sources"
  local rec_wrap="${recover_dir}/docker"
  # 既存の鍵・sources が存在し、wrapper が空かつ実行権限なし（壊れた状態）
  touch "${rec_key}" "${rec_src}"
  : > "${rec_wrap}"
  chmod 0644 "${rec_wrap}"

  (
    export "${test_env[@]}"
    export TMPDIR="${recover_tmp}"
    export DOCKER_KEYRING="${rec_key}"
    export DOCKER_SOURCES="${rec_src}"
    export DOCKER_WRAPPER="${rec_wrap}"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local wrap_size=0 is_executable=0
  if [ -f "${rec_wrap}" ]; then
    wrap_size=$(wc -c < "${rec_wrap}" | tr -d ' ')
  fi
  if [ -x "${rec_wrap}" ]; then
    is_executable=1
  fi
  local rec_tmp_leftover
  rec_tmp_leftover=$(count_dir_entries "${recover_tmp}")

  if [ "${is_executable}" -eq 1 ] && [ "${wrap_size}" -gt 20 ] && \
     grep -q "exec sudo -n /usr/bin/docker" "${rec_wrap}" && \
     [ "${rec_tmp_leftover}" -eq 0 ]; then
    log_pass "${suite}: recover corrupted or empty existing docker wrapper"
  else
    log_fail "${suite}: failed to recover corrupted docker wrapper"
  fi

  # 5.5 docker-engine.sh: /etc/os-release 不在かつ DOCKER_UBUNTU_CODENAME 未設定時のエラー終了
  log_test "${suite}: fail when Ubuntu codename cannot be determined"
  local no_os_dir="${test_dir}/no_os"
  local no_os_tmp="${test_dir}/no_os_tmp"
  local no_os_stderr="${test_dir}/no_os.stderr"
  mkdir -p "${no_os_dir}" "${no_os_tmp}"

  local no_os_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export TMPDIR="${no_os_tmp}"
    export DOCKER_KEYRING="${no_os_dir}/docker.asc"
    export DOCKER_SOURCES="${no_os_dir}/docker.sources"
    export DOCKER_WRAPPER="${no_os_dir}/docker"
    # Linux CI 環境でも確実に検証できるよう、存在しない os-release ファイルを指定し codename も未設定とする
    export DOCKER_OS_RELEASE_FILE="${no_os_dir}/nonexistent-os-release"
    bash "${REPO_ROOT}/provision/docker-engine.sh" 2>"${no_os_stderr}"
  ) || no_os_failed=1

  local tmp_leftover_no_os=0 has_codename_err=0
  tmp_leftover_no_os=$(count_dir_entries "${no_os_tmp}")
  if grep -q "could not determine Ubuntu codename" "${no_os_stderr}"; then
    has_codename_err=1
  fi

  if [ "${no_os_failed}" -eq 1 ] && [ "${has_codename_err}" -eq 1 ] && [ "${tmp_leftover_no_os}" -eq 0 ]; then
    log_pass "${suite}: fail when Ubuntu codename cannot be determined"
  else
    log_fail "${suite}: did not fail as expected when codename undetermined (failed: ${no_os_failed}, msg: ${has_codename_err}, tmp: ${tmp_leftover_no_os})"
  fi
}

# -----------------------------------------------------------------------------
# Main Runner
# -----------------------------------------------------------------------------
echo "Running test suites for lima-coding-sandbox..."
test_git_config
test_agent_instructions
test_cli_provisioning
test_makefile_logic
test_apt_key_provisioning

echo "--------------------------------------------------"
printf 'Test results: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
