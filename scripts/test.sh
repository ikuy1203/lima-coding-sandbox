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

  # スタブ curl: URL に応じたインストーラスクリプトを出力する
  cat > "${fake_bin}/curl" << 'EOF'
#!/bin/bash
set -eu
if [ "${STUB_CURL_FAIL:-0}" = "1" ]; then
  exit 1
fi
echo "$@" >> "${STUB_CURL_LOG}"
case "$*" in
  *herdr.dev/install.sh*)
    cat << 'INS'
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/herdr"
#!/bin/sh
echo "herdr stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/herdr"
INS
    ;;
  *antigravity.google/cli/install.sh*)
    cat << 'INS'
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/agy"
#!/bin/sh
echo "agy stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/agy"
INS
    ;;
  *gh.io/copilot-install*)
    cat << 'INS'
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/copilot"
#!/bin/sh
echo "copilot stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/copilot"
INS
    ;;
  *mise.run*)
    cat << 'INS'
mkdir -p "$HOME/.local/bin"
cat << 'BIN' > "$HOME/.local/bin/mise"
#!/bin/sh
echo "mise stub 0.1.0"
BIN
chmod +x "$HOME/.local/bin/mise"
INS
    ;;
  *)
    echo "unknown url: $*" >&2
    exit 1
    ;;
esac
EOF
  chmod +x "${fake_bin}/curl"

  local curl_log="${test_dir}/curl.log"

  # 3.1 herdr, agy, copilot の初回実行と冪等性
  log_test "${suite}: herdr, agy, copilot installation and idempotency"
  (
    export HOME="${fake_home}"
    export PATH="${fake_bin}:${PATH}"
    export STUB_CURL_LOG="${curl_log}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/antigravity-cli.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  )

  local call_count_first
  call_count_first=$(wc -l < "${curl_log}" | tr -d ' ')

  # 2 回目実行: バイナリが存在するため curl は呼ばれないはず
  (
    export HOME="${fake_home}"
    export PATH="${fake_bin}:${PATH}"
    export STUB_CURL_LOG="${curl_log}"
    bash "${REPO_ROOT}/provision/herdr.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/antigravity-cli.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/copilot-cli.sh" >/dev/null 2>&1
  )

  local call_count_second
  call_count_second=$(wc -l < "${curl_log}" | tr -d ' ')

  if [ -x "${fake_home}/.local/bin/herdr" ] && \
     [ -x "${fake_home}/.local/bin/agy" ] && \
     [ -x "${fake_home}/.local/bin/copilot" ] && \
     [ "${call_count_first}" -eq 3 ] && \
     [ "${call_count_second}" -eq 3 ]; then
    log_pass "${suite}: herdr, agy, copilot installation and idempotency"
  else
    log_fail "${suite}: herdr, agy, copilot idempotency failed"
  fi

  # 3.2 mise.sh の冪等性と ~/.profile の重複防止
  log_test "${suite}: mise installation and ~/.profile non-duplication"
  (
    export HOME="${fake_home}"
    export PATH="${fake_bin}:${PATH}"
    export STUB_CURL_LOG="${curl_log}"
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  )
  local marker_count
  marker_count=$(grep -c "added by lima-coding-sandbox provision/mise.sh" "${fake_home}/.profile" || true)
  if [ -x "${fake_home}/.local/bin/mise" ] && [ "${marker_count}" -eq 1 ]; then
    log_pass "${suite}: mise installation and ~/.profile non-duplication"
  else
    log_fail "${suite}: mise ~/.profile duplicated or binary missing"
  fi

  # 3.3 途中失敗からの回復テスト (curl 失敗時のエラー終了と再実行成功)
  log_test "${suite}: recovery after temporary curl failure"
  local recovery_home="${test_dir}/recovery_home"
  mkdir -p "${recovery_home}"
  local failed=0
  (
    export HOME="${recovery_home}"
    export PATH="${fake_bin}:${PATH}"
    export STUB_CURL_LOG="${curl_log}"
    export STUB_CURL_FAIL=1
    bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
  ) || failed=1

  if [ "${failed}" -eq 1 ] && [ ! -x "${recovery_home}/.local/bin/mise" ]; then
    (
      export HOME="${recovery_home}"
      export PATH="${fake_bin}:${PATH}"
      export STUB_CURL_LOG="${curl_log}"
      export STUB_CURL_FAIL=0
      bash "${REPO_ROOT}/provision/mise.sh" >/dev/null 2>&1
    )
    if [ -x "${recovery_home}/.local/bin/mise" ]; then
      log_pass "${suite}: recovery after temporary curl failure"
    else
      log_fail "${suite}: recovery rerun failed"
    fi
  else
    log_fail "${suite}: curl failure did not stop script"
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
# Main Runner
# -----------------------------------------------------------------------------
echo "Running test suites for lima-coding-sandbox..."
test_git_config
test_agent_instructions
test_cli_provisioning
test_makefile_logic

echo "--------------------------------------------------"
printf 'Test results: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
