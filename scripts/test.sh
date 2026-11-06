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
unset GIT_CONFIG_GLOBAL XDG_CONFIG_HOME GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE

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

get_octal_perm() {
  local out
  if out=$(stat -c '%a' "$1" 2>/dev/null); then
    printf '%s' "${out}"
  elif out=$(stat -f '%Lp' "$1" 2>/dev/null); then
    printf '%s' "${out}"
  fi
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
  if [ -f "${key}" ] && [ -f "${pub}" ] && grep -Eq 'git-signing [^ ]+@[^ ]+ [0-9]{4}-[0-9]{2}-[0-9]{2}$' "${pub}"; then
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
    log_fail "${suite}: initial setup failed (keys missing or invalid comment format)"
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

  # 1.5 ユーザ名・メール未指定時の動作: 署名機構が検証され、未設定の診断案内が出力されて成功する
  log_test "${suite}: unconfigured user identity diagnoses and verifies mechanism"
  local unset_home="${test_dir}/unset_home"
  local unset_stderr="${test_dir}/unset.stderr"
  mkdir -p "${unset_home}"
  local unset_success=0
  (
    export HOME="${unset_home}"
    export XDG_CONFIG_HOME="${unset_home}/.config"
    export GIT_CONFIG_GLOBAL="${unset_home}/.gitconfig"
    export PARAM_gitUserName=""
    export PARAM_gitUserEmail=""
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>"${unset_stderr}"
  ) && unset_success=1

  local has_notice=0
  if grep -q "Git commit signing mechanism is verified, but user identity is not configured yet" "${unset_stderr}"; then
    has_notice=1
  fi

  if [ "${unset_success}" -eq 1 ] && [ "${has_notice}" -eq 1 ] && [ -s "${unset_home}/.ssh/id_ed25519_signing" ]; then
    log_pass "${suite}: unconfigured user identity diagnoses and verifies mechanism"
  else
    log_fail "${suite}: unconfigured user identity diagnosis failed (success=${unset_success}, notice=${has_notice})"
  fi

  # 1.6 秘密鍵と公開鍵の不整合の検出
  log_test "${suite}: detect mismatch between private and public key"
  local mismatch_home="${test_dir}/mismatch_home"
  local mismatch_stderr="${test_dir}/mismatch.stderr"
  mkdir -p "${mismatch_home}/.ssh"
  ssh-keygen -t ed25519 -N '' -f "${mismatch_home}/.ssh/id_ed25519_signing" -C "key1" >/dev/null 2>&1
  ssh-keygen -t ed25519 -N '' -f "${mismatch_home}/.ssh/other" -C "key2" >/dev/null 2>&1
  cp "${mismatch_home}/.ssh/other.pub" "${mismatch_home}/.ssh/id_ed25519_signing.pub"
  rm -f "${mismatch_home}/.ssh/other"*

  local mismatch_failed=0
  (
    export HOME="${mismatch_home}"
    export XDG_CONFIG_HOME="${mismatch_home}/.config"
    export GIT_CONFIG_GLOBAL="${mismatch_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" 2>"${mismatch_stderr}"
  ) || mismatch_failed=1

  local has_mismatch_msg=0
  if grep -q "does not match private key" "${mismatch_stderr}"; then
    has_mismatch_msg=1
  fi

  if [ "${mismatch_failed}" -eq 1 ] && [ "${has_mismatch_msg}" -eq 1 ]; then
    log_pass "${suite}: detect mismatch between private and public key"
  else
    log_fail "${suite}: key mismatch detection failed"
  fi

  # 1.7 明示的に署名が無効化（commit.gpgsign=false）されている場合は上書きせず診断も通過
  log_test "${suite}: respect explicitly disabled commit signing"
  local disabled_home="${test_dir}/disabled_home"
  mkdir -p "${disabled_home}"
  HOME="${disabled_home}" XDG_CONFIG_HOME="${disabled_home}/.config" GIT_CONFIG_GLOBAL="${disabled_home}/.gitconfig" git config --global commit.gpgsign false

  local disabled_success=0
  (
    export HOME="${disabled_home}"
    export XDG_CONFIG_HOME="${disabled_home}/.config"
    export GIT_CONFIG_GLOBAL="${disabled_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  ) && disabled_success=1

  local actual_sign
  actual_sign=$(HOME="${disabled_home}" XDG_CONFIG_HOME="${disabled_home}/.config" GIT_CONFIG_GLOBAL="${disabled_home}/.gitconfig" git config --global --get commit.gpgsign || true)

  if [ "${disabled_success}" -eq 1 ] && [ "${actual_sign}" = "false" ]; then
    log_pass "${suite}: respect explicitly disabled commit signing"
  else
    log_fail "${suite}: disabled commit signing was overwritten or failed"
  fi

  # 1.8 グローバルの core.hooksPath でコミットが拒否される環境でも診断用コミットが妨害されないこと
  log_test "${suite}: ignore global core.hooksPath during signing diagnosis"
  local hook_home="${test_dir}/hook_home"
  local hook_dir="${test_dir}/global_hooks"
  mkdir -p "${hook_home}" "${hook_dir}"
  cat > "${hook_dir}/pre-commit" << 'EOF'
#!/bin/sh
echo "pre-commit hook triggered and rejected" >&2
exit 1
EOF
  chmod +x "${hook_dir}/pre-commit"

  HOME="${hook_home}" XDG_CONFIG_HOME="${hook_home}/.config" GIT_CONFIG_GLOBAL="${hook_home}/.gitconfig" git config --global core.hooksPath "${hook_dir}"
  HOME="${hook_home}" XDG_CONFIG_HOME="${hook_home}/.config" GIT_CONFIG_GLOBAL="${hook_home}/.gitconfig" git config --global user.name "Hook User"
  HOME="${hook_home}" XDG_CONFIG_HOME="${hook_home}/.config" GIT_CONFIG_GLOBAL="${hook_home}/.gitconfig" git config --global user.email "hook@example.com"

  local hook_success=0
  (
    export HOME="${hook_home}"
    export XDG_CONFIG_HOME="${hook_home}/.config"
    export GIT_CONFIG_GLOBAL="${hook_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  ) && hook_success=1

  if [ "${hook_success}" -eq 1 ]; then
    log_pass "${suite}: ignore global core.hooksPath during signing diagnosis"
  else
    log_fail "${suite}: global hooks interfered with signing diagnosis"
  fi

  # 1.9 秘密鍵が 0 バイトの空ファイルの場合に非対話で上書き確認なく再生成・復旧されること
  log_test "${suite}: recover empty private key non-interactively without overwrite prompt"
  local empty_home="${test_dir}/empty_home"
  mkdir -p "${empty_home}/.ssh"
  touch "${empty_home}/.ssh/id_ed25519_signing"

  local empty_success=0
  (
    export HOME="${empty_home}"
    export XDG_CONFIG_HOME="${empty_home}/.config"
    export GIT_CONFIG_GLOBAL="${empty_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" </dev/null >/dev/null 2>&1
  ) && empty_success=1

  if [ "${empty_success}" -eq 1 ] && [ -s "${empty_home}/.ssh/id_ed25519_signing" ] && [ -s "${empty_home}/.ssh/id_ed25519_signing.pub" ]; then
    log_pass "${suite}: recover empty private key non-interactively without overwrite prompt"
  else
    log_fail "${suite}: failed to recover 0-byte private key non-interactively"
  fi

  # 1.10 commit.gpgsign が no / off / 0 / unset の場合に署名診断がスキップされ正常終了すること
  log_test "${suite}: respect normalized boolean variants of commit.gpgsign (no/off/0/unset)"
  local gpgsign_home="${test_dir}/gpgsign_home"
  mkdir -p "${gpgsign_home}"
  HOME="${gpgsign_home}" XDG_CONFIG_HOME="${gpgsign_home}/.config" GIT_CONFIG_GLOBAL="${gpgsign_home}/.gitconfig" git config --global user.name "GpgSign User"
  HOME="${gpgsign_home}" XDG_CONFIG_HOME="${gpgsign_home}/.config" GIT_CONFIG_GLOBAL="${gpgsign_home}/.gitconfig" git config --global user.email "gpgsign@example.com"

  # まず初期設定を実行
  (
    export HOME="${gpgsign_home}"
    export XDG_CONFIG_HOME="${gpgsign_home}/.config"
    export GIT_CONFIG_GLOBAL="${gpgsign_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  )

  local all_bool_variants_pass=1
  for val in "no" "off" "0" "false"; do
    HOME="${gpgsign_home}" XDG_CONFIG_HOME="${gpgsign_home}/.config" GIT_CONFIG_GLOBAL="${gpgsign_home}/.gitconfig" git config --global commit.gpgsign "${val}"
    if ! (
      export HOME="${gpgsign_home}"
      export XDG_CONFIG_HOME="${gpgsign_home}/.config"
      export GIT_CONFIG_GLOBAL="${gpgsign_home}/.gitconfig"
      bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
    ); then
      all_bool_variants_pass=0
      break
    fi
  done

  # --unset の場合もテスト
  HOME="${gpgsign_home}" XDG_CONFIG_HOME="${gpgsign_home}/.config" GIT_CONFIG_GLOBAL="${gpgsign_home}/.gitconfig" git config --global --unset commit.gpgsign
  if ! (
    export HOME="${gpgsign_home}"
    export XDG_CONFIG_HOME="${gpgsign_home}/.config"
    export GIT_CONFIG_GLOBAL="${gpgsign_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  ); then
    all_bool_variants_pass=0
  fi

  if [ "${all_bool_variants_pass}" -eq 1 ]; then
    log_pass "${suite}: respect normalized boolean variants of commit.gpgsign (no/off/0/unset)"
  else
    log_fail "${suite}: failed to handle boolean false or unset commit.gpgsign"
  fi

  # 1.11 独自設定（user.signingkey が別鍵、または未設定で gpg.format=ssh）が尊重されること
  log_test "${suite}: preserve custom user.signingkey and custom ssh format without template key"
  local custom_ssh_home="${test_dir}/custom_ssh_home"
  local custom_ssh_stderr="${test_dir}/custom_ssh.stderr"
  mkdir -p "${custom_ssh_home}"
  HOME="${custom_ssh_home}" XDG_CONFIG_HOME="${custom_ssh_home}/.config" GIT_CONFIG_GLOBAL="${custom_ssh_home}/.gitconfig" git config --global user.name "Custom SSH User"
  HOME="${custom_ssh_home}" XDG_CONFIG_HOME="${custom_ssh_home}/.config" GIT_CONFIG_GLOBAL="${custom_ssh_home}/.gitconfig" git config --global user.email "custom-ssh@example.com"
  HOME="${custom_ssh_home}" XDG_CONFIG_HOME="${custom_ssh_home}/.config" GIT_CONFIG_GLOBAL="${custom_ssh_home}/.gitconfig" git config --global commit.gpgsign true
  HOME="${custom_ssh_home}" XDG_CONFIG_HOME="${custom_ssh_home}/.config" GIT_CONFIG_GLOBAL="${custom_ssh_home}/.gitconfig" git config --global gpg.format ssh
  # user.signingkey は未設定（ssh-agent 利用構成などを想定）

  local custom_success=0
  (
    export HOME="${custom_ssh_home}"
    export XDG_CONFIG_HOME="${custom_ssh_home}/.config"
    export GIT_CONFIG_GLOBAL="${custom_ssh_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>"${custom_ssh_stderr}"
  ) && custom_success=1

  local custom_preserved=0
  if grep -q "Custom Git signing configuration detected" "${custom_ssh_stderr}" 2>/dev/null; then
    custom_preserved=1
  fi

  if [ "${custom_success}" -eq 1 ] && [ "${custom_preserved}" -eq 1 ]; then
    log_pass "${suite}: preserve custom user.signingkey and custom ssh format without template key"
  else
    log_fail "${suite}: custom signing configuration was not preserved"
  fi

  # 1.12 パスフレーズ付き鍵が存在する場合に非対話エラーとならずスキップ・成功すること
  log_test "${suite}: handle passphrase-protected key gracefully by skipping non-interactive test"
  local pass_home="${test_dir}/pass_home"
  mkdir -p "${pass_home}/.ssh"
  ssh-keygen -t ed25519 -N 'secret-passphrase' -f "${pass_home}/.ssh/id_ed25519_signing" -C "pass-key" >/dev/null 2>&1
  HOME="${pass_home}" XDG_CONFIG_HOME="${pass_home}/.config" GIT_CONFIG_GLOBAL="${pass_home}/.gitconfig" git config --global user.name "Pass User"
  HOME="${pass_home}" XDG_CONFIG_HOME="${pass_home}/.config" GIT_CONFIG_GLOBAL="${pass_home}/.gitconfig" git config --global user.email "pass@example.com"

  local pass_success=0
  (
    export HOME="${pass_home}"
    export XDG_CONFIG_HOME="${pass_home}/.config"
    export GIT_CONFIG_GLOBAL="${pass_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" </dev/null >/dev/null 2>&1
  ) && pass_success=1

  if [ "${pass_success}" -eq 1 ]; then
    log_pass "${suite}: handle passphrase-protected key gracefully by skipping non-interactive test"
  else
    log_fail "${suite}: passphrase-protected key caused failure"
  fi

  # 1.13 include.path で読み込んだ独自の GPG 設定が尊重されること
  log_test "${suite}: preserve custom GPG configuration loaded via include.path"
  local inc_home="${test_dir}/inc_home"
  mkdir -p "${inc_home}"
  HOME="${inc_home}" XDG_CONFIG_HOME="${inc_home}/.config" GIT_CONFIG_GLOBAL="${inc_home}/.gitconfig" git config --global user.name "Include User"
  HOME="${inc_home}" XDG_CONFIG_HOME="${inc_home}/.config" GIT_CONFIG_GLOBAL="${inc_home}/.gitconfig" git config --global user.email "include@example.com"
  printf '[user]\n\tsigningkey = CUSTOM_GPG_KEY_ID\n[gpg]\n\tformat = openpgp\n' > "${inc_home}/custom.gitconfig"
  HOME="${inc_home}" XDG_CONFIG_HOME="${inc_home}/.config" GIT_CONFIG_GLOBAL="${inc_home}/.gitconfig" git config --global include.path "${inc_home}/custom.gitconfig"

  local inc_success=0
  (
    export HOME="${inc_home}"
    export XDG_CONFIG_HOME="${inc_home}/.config"
    export GIT_CONFIG_GLOBAL="${inc_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  ) && inc_success=1

  if [ "${inc_success}" -eq 1 ]; then
    log_pass "${suite}: preserve custom GPG configuration loaded via include.path"
  else
    log_fail "${suite}: include.path custom GPG configuration was not preserved"
  fi

  # 1.14 include.path で commit.gpgsign=false が指定された場合、上書きされず署名診断がスキップされること
  log_test "${suite}: preserve disabled commit signing supplied via include.path"
  local inc_disable_home="${test_dir}/inc_disable_home"
  mkdir -p "${inc_disable_home}"
  printf '[commit]\n\tgpgsign = false\n' > "${inc_disable_home}/disabled.gitconfig"
  HOME="${inc_disable_home}" XDG_CONFIG_HOME="${inc_disable_home}/.config" GIT_CONFIG_GLOBAL="${inc_disable_home}/.gitconfig" git config --global include.path "${inc_disable_home}/disabled.gitconfig"

  local inc_disable_success=0
  (
    export HOME="${inc_disable_home}"
    export XDG_CONFIG_HOME="${inc_disable_home}/.config"
    export GIT_CONFIG_GLOBAL="${inc_disable_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  ) && inc_disable_success=1

  local inc_actual_sign
  inc_actual_sign=$(HOME="${inc_disable_home}" XDG_CONFIG_HOME="${inc_disable_home}/.config" GIT_CONFIG_GLOBAL="${inc_disable_home}/.gitconfig" git config --includes --global --get commit.gpgsign 2>/dev/null || true)

  if [ "${inc_disable_success}" -eq 1 ] && [ "${inc_actual_sign}" = "false" ]; then
    log_pass "${suite}: preserve disabled commit signing supplied via include.path"
  else
    log_fail "${suite}: disabled commit signing in include.path was overwritten or failed (success=${inc_disable_success}, actual=${inc_actual_sign})"
  fi

  # 1.15 include.path で user.email が指定された場合、allowed_signers に反映されグローバル署名検証に成功すること
  log_test "${suite}: configure allowed_signers and verify when identity is from include.path"
  local inc_ident_home="${test_dir}/inc_ident_home"
  mkdir -p "${inc_ident_home}"
  printf '[user]\n\tname = Inc Identity\n\temail = inc_ident@example.com\n' > "${inc_ident_home}/identity.gitconfig"
  HOME="${inc_ident_home}" XDG_CONFIG_HOME="${inc_ident_home}/.config" GIT_CONFIG_GLOBAL="${inc_ident_home}/.gitconfig" git config --global include.path "${inc_ident_home}/identity.gitconfig"

  local inc_ident_success=0
  (
    export HOME="${inc_ident_home}"
    export XDG_CONFIG_HOME="${inc_ident_home}/.config"
    export GIT_CONFIG_GLOBAL="${inc_ident_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>&1
  ) && inc_ident_success=1

  local allowed_signers_file="${inc_ident_home}/.config/git/allowed_signers"
  local has_inc_signer=0
  if [ -s "${allowed_signers_file}" ] && grep -q "inc_ident@example.com" "${allowed_signers_file}"; then
    has_inc_signer=1
  fi

  if [ "${inc_ident_success}" -eq 1 ] && [ "${has_inc_signer}" -eq 1 ]; then
    log_pass "${suite}: configure allowed_signers and verify when identity is from include.path"
  else
    log_fail "${suite}: failed to configure allowed_signers from include.path identity (success=${inc_ident_success}, signer=${has_inc_signer})"
  fi

  # 1.16 PARAM_gitUserName のみ指定され PARAM_gitUserEmail が空の場合、設定エラーにならず診断メッセージを出して正常終了すること
  log_test "${suite}: succeed with notice when only gitUserName is supplied in param"
  local single_param_home="${test_dir}/single_param_home"
  local single_param_stderr="${test_dir}/single_param.stderr"
  mkdir -p "${single_param_home}"

  local single_param_success=0
  (
    export HOME="${single_param_home}"
    export XDG_CONFIG_HOME="${single_param_home}/.config"
    export GIT_CONFIG_GLOBAL="${single_param_home}/.gitconfig"
    export PARAM_gitUserName="Single User"
    export PARAM_gitUserEmail=""
    bash "${REPO_ROOT}/provision/git-config.sh" >/dev/null 2>"${single_param_stderr}"
  ) && single_param_success=1

  local has_email_prompt=0
  if grep -q 'git config --global user.email "<your.email@example.com>"' "${single_param_stderr}" 2>/dev/null; then
    has_email_prompt=1
  fi

  if [ "${single_param_success}" -eq 1 ] && [ "${has_email_prompt}" -eq 1 ]; then
    log_pass "${suite}: succeed with notice when only gitUserName is supplied in param"
  else
    log_fail "${suite}: failed when only gitUserName was supplied (success=${single_param_success}, prompt=${has_email_prompt})"
  fi

  # 1.17 パスフレーズ付き鍵で .pub ファイルが欠落している場合でも、エラーで落ちずにスキップ・正常終了すること
  log_test "${suite}: handle passphrase-protected key gracefully with missing public key file"
  local pass_nopub_home="${test_dir}/pass_nopub_home"
  mkdir -p "${pass_nopub_home}/.ssh"
  ssh-keygen -t ed25519 -N 'secret-passphrase' -f "${pass_nopub_home}/.ssh/id_ed25519_signing" -C "pass-nopub-key" >/dev/null 2>&1
  rm -f "${pass_nopub_home}/.ssh/id_ed25519_signing.pub"

  local pass_nopub_success=0
  (
    export HOME="${pass_nopub_home}"
    export XDG_CONFIG_HOME="${pass_nopub_home}/.config"
    export GIT_CONFIG_GLOBAL="${pass_nopub_home}/.gitconfig"
    bash "${REPO_ROOT}/provision/git-config.sh" </dev/null >/dev/null 2>&1
  ) && pass_nopub_success=1

  if [ "${pass_nopub_success}" -eq 1 ]; then
    log_pass "${suite}: handle passphrase-protected key gracefully with missing public key file"
  else
    log_fail "${suite}: passphrase-protected key with missing .pub caused failure"
  fi

  # 1.18 commit.gpgsign に不正なブール値（例: treu）が設定されている場合はエラー終了すること
  log_test "${suite}: fail when commit.gpgsign contains an invalid boolean value"
  local invalid_bool_home="${test_dir}/invalid_bool_home"
  mkdir -p "${invalid_bool_home}/.ssh"
  local invalid_bool_gitconfig="${invalid_bool_home}/.gitconfig"
  git config -f "${invalid_bool_gitconfig}" commit.gpgsign "treu"

  local invalid_bool_failed=0
  local invalid_bool_stderr="${test_dir}/invalid_bool.stderr"
  (
    export HOME="${invalid_bool_home}"
    export XDG_CONFIG_HOME="${invalid_bool_home}/.config"
    export GIT_CONFIG_GLOBAL="${invalid_bool_gitconfig}"
    bash "${REPO_ROOT}/provision/git-config.sh" </dev/null 2>"${invalid_bool_stderr}"
  ) || invalid_bool_failed=1

  local invalid_bool_reported=0
  if grep -q "invalid boolean config value for commit.gpgsign: 'treu'" "${invalid_bool_stderr}" 2>/dev/null; then
    invalid_bool_reported=1
  fi

  if [ "${invalid_bool_failed}" -eq 1 ] && [ "${invalid_bool_reported}" -eq 1 ]; then
    log_pass "${suite}: fail when commit.gpgsign contains an invalid boolean value"
  else
    log_fail "${suite}: invalid boolean commit.gpgsign was not rejected with diagnostic error"
  fi

  # 1.19 .gitconfig に構文エラーがあり git config の取得自体が失敗（exit != 1）した場合は診断エラー終了すること
  log_test "${suite}: fail when git config query fails due to broken syntax"
  local syntax_err_home="${test_dir}/syntax_err_home"
  mkdir -p "${syntax_err_home}/.ssh"
  local syntax_err_gitconfig="${syntax_err_home}/.gitconfig"
  echo "[broken section" > "${syntax_err_gitconfig}"

  local syntax_err_failed=0
  local syntax_err_stderr="${test_dir}/syntax_err.stderr"
  (
    export HOME="${syntax_err_home}"
    export GIT_CONFIG_GLOBAL="${syntax_err_gitconfig}"
    fn_def=$(awk '/^diagnose_git_signing\(\) *\{/ { p=1 } p { print; b += gsub(/\{/, "{") - gsub(/\}/, "}"); if (b == 0) exit }' "${REPO_ROOT}/provision/git-config.sh")
    eval "${fn_def}"
    key="${syntax_err_home}/.ssh/id_ed25519_signing"
    diagnose_git_signing
  ) 2>"${syntax_err_stderr}" || syntax_err_failed=1

  local syntax_err_reported=0
  if grep -q "failed to query commit.gpgsign:" "${syntax_err_stderr}" 2>/dev/null; then
    syntax_err_reported=1
  fi

  if [ "${syntax_err_failed}" -eq 1 ] && [ "${syntax_err_reported}" -eq 1 ]; then
    log_pass "${suite}: fail when git config query fails due to broken syntax"
  else
    log_fail "${suite}: broken .gitconfig syntax was not rejected with query error"
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
#!/bin/bash
if [ "${STUB_COPILOT_INSTALL_FAIL:-0}" = "1" ]; then
  exit 1
fi
case "${VERSION:-}" in
  ""|prerelease)
    ;;
  [vV]*)
    echo >&2 "stub-error: upstream copilot installer received unnormalized VERSION: ${VERSION}"
    exit 99
    ;;
esac
mkdir -p "$HOME/.local/bin"
resolved_ver="${VERSION:-1.0.105}"
if [ "${STUB_COPILOT_IGNORE_VERSION:-0}" = "1" ]; then
  resolved_ver="1.0.105"
fi
if [ "${VERSION:-}" = "prerelease" ]; then
  if [ "${STUB_COPILOT_NO_PRERELEASE_TAG:-0}" = "1" ]; then
    :
  else
    echo "Latest prerelease version: v1.1.0-alpha.1"
  fi
  resolved_ver="1.1.0-alpha.1"
  if [ "${STUB_COPILOT_FAIL_AFTER_PRERELEASE_TAG:-0}" = "1" ]; then
    exit 43
  fi
fi
cat << BIN > "$HOME/.local/bin/copilot"
#!/bin/sh
echo "GitHub Copilot CLI ${resolved_ver}."
BIN
chmod +x "$HOME/.local/bin/copilot"
if [ "${STUB_COPILOT_FAIL_AFTER_INSTALL:-0}" = "1" ]; then
  exit 42
fi
INS
      ;;
    *mise.run*)
      cat << 'INS' > "${dest}"
#!/bin/bash
if [ "${STUB_MISE_INSTALL_FAIL:-0}" = "1" ]; then
  exit 1
fi
case "${MISE_VERSION:-}" in
  "")
    ;;
  [vV]*)
    echo >&2 "stub-error: upstream mise installer received unnormalized MISE_VERSION: ${MISE_VERSION}"
    exit 99
    ;;
esac
mkdir -p "$HOME/.local/bin"
resolved_ver="${MISE_VERSION:-2026.10.25}"
if [ "${STUB_MISE_IGNORE_VERSION:-0}" = "1" ]; then
  resolved_ver="2026.10.25"
fi
cat << BIN > "$HOME/.local/bin/mise"
#!/bin/sh
echo "${resolved_ver} linux-x64 (2026-10-31)"
BIN
chmod +x "$HOME/.local/bin/mise"
if [ "${STUB_MISE_FAIL_AFTER_INSTALL:-0}" = "1" ]; then
  exit 42
fi
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

  local fake_fail_inst_bin="${test_dir}/fake_fail_inst_bin"
  mkdir -p "${fake_fail_inst_bin}"
  cat > "${fake_fail_inst_bin}/curl" << 'EOF'
#!/bin/bash
set -eu
dest=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  if [ "${args[$i]}" = "-o" ]; then
    i=$((i + 1))
    dest="${args[$i]}"
  fi
  i=$((i + 1))
done
if [ -n "${dest}" ]; then
  cat > "${dest}" << 'INSTALL_FAIL'
#!/bin/sh
exit 1
INSTALL_FAIL
fi
printf '200'
exit 0
EOF
  chmod +x "${fake_fail_inst_bin}/curl"

  local restore_failed=0
  (
    export PATH="${fake_fail_inst_bin}:${PATH}"
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
    export PATH="${fake_fail_inst_bin}:${PATH}"
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
    template|list|create|start|stop|delete|shell)
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
    if [ "${STUB_LIMA_LIST_FAIL:-0}" = "1" ]; then
      exit 1
    fi
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
      *.Dir*)
        echo "${STUB_LIMA_DIR_OUTPUT:-/tmp/fake-lima-dir}"
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
    if [ "${STUB_STOP_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    exit 0
    ;;
  delete)
    exit 0
    ;;
  shell)
    if [ -n "${STUB_LIMA_SHELL_STDIN:-}" ]; then
      cat > "${STUB_LIMA_SHELL_STDIN}"
    fi
    if [ "${STUB_LIMA_SHELL_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    if [ -n "${STUB_LIMA_GUEST_HOME:-}" ]; then
      shift 2
      cd "${STUB_LIMA_GUEST_HOME}"
      HOME="${STUB_LIMA_GUEST_HOME}" \
        XDG_CONFIG_HOME="${STUB_LIMA_GUEST_HOME}/.config" \
        GIT_CONFIG_GLOBAL="${STUB_LIMA_GUEST_HOME}/.gitconfig" \
        PATH="${STUB_LIMA_GUEST_PATH:-${PATH}}" "$@"
      exit $?
    fi
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

  # 4.9 scripts/lib.sh: get_status と resolve_name の単体テスト（状態取得・未作成・エラー伝播・空 NAME 拒否）
  log_test "${suite}: scripts/lib.sh get_status and resolve_name unit tests"
  local st_running st_stopped st_missing st_fail_rc=0
  local rn_default rn_quoted rn_empty_rc=0 rn_quoted_empty_rc=0
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

  if [ "${st_running}" = "Running" ] && \
     [ "${st_stopped}" = "Stopped" ] && \
     [ -z "${st_missing}" ] && \
     [ "${st_fail_rc}" -ne 0 ] && \
     [ "${rn_default}" = "coding-sandbox" ] && \
     [ "${rn_quoted}" = "sandbox2" ] && \
     [ "${rn_empty_rc}" -ne 0 ] && \
     [ "${rn_quoted_empty_rc}" -ne 0 ]; then
    log_pass "${suite}: scripts/lib.sh get_status and resolve_name unit tests"
  else
    log_fail "${suite}: scripts/lib.sh get_status and resolve_name unit tests failed"
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

  # 4.12 make stop (scripts/stop.sh): Running 時の停止、Stopped 時のスキップ、状態照会失敗時のエラー伝播
  log_test "${suite}: make stop stops running instance, skips stopped, and fails on status error"
  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    make -f "${REPO_ROOT}/Makefile" stop ENV_FILE="${empty_env}" >/dev/null 2>&1
  )
  local stop_when_running
  stop_when_running=$(grep -cx "stop" "${lima_log}" || true)

  : > "${lima_log}"
  local stop_msg
  stop_msg=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    make -f "${REPO_ROOT}/Makefile" stop ENV_FILE="${empty_env}" 2>&1
  )
  local stop_when_stopped
  stop_when_stopped=$(grep -cx "stop" "${lima_log}" || true)

  : > "${lima_log}"
  local stop_list_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_LIST_FAIL=1
    make -f "${REPO_ROOT}/Makefile" stop ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || stop_list_fail_rc=$?
  local stop_on_list_fail
  stop_on_list_fail=$(grep -cx "stop" "${lima_log}" || true)

  if [ "${stop_when_running}" -eq 1 ] && [ "${stop_when_stopped}" -eq 0 ] && \
     printf '%s\n' "${stop_msg}" | grep -q "動いていません" && \
     [ "${stop_list_fail_rc}" -ne 0 ] && [ "${stop_on_list_fail}" -eq 0 ]; then
    log_pass "${suite}: make stop stops running instance, skips stopped, and fails on status error"
  else
    log_fail "${suite}: make stop behavior failed"
  fi

  # 4.13 make delete (scripts/delete.sh): 未作成・確認中止・確認承認・YES=1・停止失敗時の削除中止
  log_test "${suite}: make delete confirmation prompt, YES=1, and abort when stop fails"
  : > "${lima_log}"
  local del_nonexistent_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=""
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) && del_nonexistent_ok=1
  local del_nonexistent_calls
  del_nonexistent_calls=$(grep -cx "delete" "${lima_log}" || true)

  # 確認プロンプトで n を入力して中止（未 push 作業データおよび make backup-auth の案内表示も検証）
  : > "${lima_log}"
  local del_aborted=0 del_prompt_out=""
  del_prompt_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    printf 'n\n' | make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" 2>&1
  ) || del_aborted=1
  local del_aborted_calls
  del_aborted_calls=$(grep -cx "delete" "${lima_log}" || true)

  # Running 状態で y を入力して stop -> delete（ゲスト内の署名鍵の指紋表示と stdin 保護も検証）
  local del_guest_home="${test_dir}/del_guest_home"
  mkdir -p "${del_guest_home}/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C "git-signing test@lima-coding-sandbox 2026-11-06" -f "${del_guest_home}/.ssh/id_ed25519_signing"
  local del_expected_fp
  del_expected_fp=$(ssh-keygen -lf "${del_guest_home}/.ssh/id_ed25519_signing.pub" | awk '{print $2}')

  : > "${lima_log}"
  local del_confirmed_ok=0 del_running_out=""
  del_running_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${del_guest_home}"
    printf 'y\n' | make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" 2>&1
  ) && del_confirmed_ok=1
  local del_confirmed_stops del_confirmed_deletes
  del_confirmed_stops=$(grep -cx "stop" "${lima_log}" || true)
  del_confirmed_deletes=$(grep -cx "delete" "${lima_log}" || true)

  # Running 状態で YES=1 の場合も削除前に署名鍵の指紋と削除案内が出力されること
  : > "${lima_log}"
  local del_running_yes_ok=0 del_running_yes_out=""
  del_running_yes_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${del_guest_home}"
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" YES=1 </dev/null 2>&1
  ) && del_running_yes_ok=1

  # Running 状態で limactl stop が失敗した場合は limactl delete を呼ばずに異常終了すること
  : > "${lima_log}"
  local del_stop_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_STOP_FAIL=1
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" YES=1 >/dev/null 2>&1
  ) || del_stop_fail_rc=$?
  local del_after_stop_fail
  del_after_stop_fail=$(grep -cx "delete" "${lima_log}" || true)

  # YES="1"（引用符付き）でもプロンプトなし削除が動き、Stopped 時も削除案内（タイトルと /user/ssh_signing_keys）が出力されること
  : > "${lima_log}"
  local del_yes_ok=0 del_yes_out=""
  del_yes_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" 'YES="1"' </dev/null 2>&1
  ) && del_yes_ok=1
  local del_yes_deletes
  del_yes_deletes=$(grep -cx "delete" "${lima_log}" || true)

  # ゲスト側 ssh-keygen が非 UTF-8 バイト列（\xff）や制御文字を返しても UTF-8 ロケール下で中断せず削除が完走すること
  local del_badbytes_bin="${test_dir}/del_badbytes_bin"
  mkdir -p "${del_badbytes_bin}"
  cat > "${del_badbytes_bin}/ssh-keygen" << 'EOF'
#!/bin/sh
printf '256 SHA256:AbCdEf123456 \377\376\233 bad-comment (ED25519)\n'
EOF
  chmod +x "${del_badbytes_bin}/ssh-keygen"
  : > "${lima_log}"
  local del_badbytes_ok=0 del_badbytes_out=""
  del_badbytes_out=$(
    export LC_ALL=en_US.UTF-8
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${del_guest_home}"
    export STUB_LIMA_GUEST_PATH="${del_badbytes_bin}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" YES=1 </dev/null 2>&1
  ) && del_badbytes_ok=1
  local del_badbytes_deletes
  del_badbytes_deletes=$(grep -cx "delete" "${lima_log}" || true)

  if [ "${del_nonexistent_ok}" -eq 1 ] && [ "${del_nonexistent_calls}" -eq 0 ] && \
     [ "${del_aborted}" -eq 1 ] && [ "${del_aborted_calls}" -eq 0 ] && \
     printf '%s\n' "${del_prompt_out}" | grep -q "clone し直すだけでは復元できません" && \
     printf '%s\n' "${del_prompt_out}" | grep -q "make backup-auth" && \
     printf '%s\n' "${del_prompt_out}" | grep -q "/user/ssh_signing_keys" && \
     [ "${del_confirmed_ok}" -eq 1 ] && [ "${del_confirmed_stops}" -eq 1 ] && [ "${del_confirmed_deletes}" -eq 1 ] && \
     printf '%s\n' "${del_running_out}" | grep -qF "${del_expected_fp}" && \
     [ "${del_running_yes_ok}" -eq 1 ] && \
     printf '%s\n' "${del_running_yes_out}" | grep -qF "${del_expected_fp}" && \
     printf '%s\n' "${del_running_yes_out}" | grep -q "/user/ssh_signing_keys" && \
     [ "${del_stop_fail_rc}" -ne 0 ] && [ "${del_after_stop_fail}" -eq 0 ] && \
     [ "${del_yes_ok}" -eq 1 ] && [ "${del_yes_deletes}" -eq 1 ] && \
     printf '%s\n' "${del_yes_out}" | grep -q "タイトル: coding-sandbox <日付>" && \
     printf '%s\n' "${del_yes_out}" | grep -q "/user/ssh_signing_keys" && \
     [ "${del_badbytes_ok}" -eq 1 ] && [ "${del_badbytes_deletes}" -eq 1 ] && \
     printf '%s\n' "${del_badbytes_out}" | grep -qF "SHA256:AbCdEf123456"; then
    log_pass "${suite}: make delete confirmation prompt, YES=1, and abort when stop fails"
  else
    log_fail "${suite}: make delete behavior failed"
  fi

  # 4.14 scripts/herdr-remote.sh: herdr 未導入・ssh 未設定の拒否と正常接続
  log_test "${suite}: scripts/herdr-remote.sh prerequisite checks and remote invocation"
  local herdr_log="${test_dir}/herdr.log"
  cat > "${fake_bin}/ssh" << 'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = "-G" ]; then
  echo "hostname ${STUB_SSH_G_HOSTNAME:-127.0.0.1}"
  exit 0
fi
printf '%s\n' "$@" > "${STUB_SSH_LOG}"
if [ "${STUB_SSH_FAIL:-0}" = "1" ]; then
  exit 255
fi
exit 0
EOF
  chmod +x "${fake_bin}/ssh"

  # herdr が PATH に無い状態で失敗すること
  local no_herdr_failed=0
  (
    export PATH="${fake_bin}:/usr/bin:/bin"
    if command -v herdr >/dev/null 2>&1; then
      exit 1
    fi
    bash "${REPO_ROOT}/scripts/herdr-remote.sh" >/dev/null 2>&1
  ) || no_herdr_failed=1

  cat > "${fake_bin}/herdr" << 'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" > "${STUB_HERDR_LOG}"
exit 0
EOF
  chmod +x "${fake_bin}/herdr"

  # ssh -G がホスト名をそのまま返す（Include 未設定）ときに失敗すること
  local unconf_ssh_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_HERDR_LOG="${herdr_log}"
    export STUB_SSH_G_HOSTNAME="lima-coding-sandbox"
    bash "${REPO_ROOT}/scripts/herdr-remote.sh" >/dev/null 2>&1
  ) || unconf_ssh_failed=1

  # ssh -G が 127.0.0.1 を返すときに herdr --remote lima-<NAME> が呼ばれること
  : > "${herdr_log}"
  local herdr_remote_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_HERDR_LOG="${herdr_log}"
    export STUB_SSH_G_HOSTNAME="127.0.0.1"
    export STUB_LIMA_STATUS_OUTPUT="sandbox2 Running"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" herdr-remote ENV_FILE="${empty_env}" 'NAME="sandbox2"' >/dev/null 2>&1
  ) && herdr_remote_ok=1

  if [ "${no_herdr_failed}" -eq 1 ] && [ "${unconf_ssh_failed}" -eq 1 ] && \
     [ "${herdr_remote_ok}" -eq 1 ] && grep -qx -- "--remote lima-sandbox2" "${herdr_log}"; then
    log_pass "${suite}: scripts/herdr-remote.sh prerequisite checks and remote invocation"
  else
    log_fail "${suite}: scripts/herdr-remote.sh checks failed"
  fi

  # 4.15 make forward (scripts/forward.sh): PORT / HOST_PORT 検証、ControlMaster 無効化オプション、ssh 失敗伝播
  log_test "${suite}: make forward port validation, ControlMaster options, and ssh error propagation"
  local ssh_log="${test_dir}/ssh.log"
  local no_port_failed=0 bad_port_failed=0 bad_host_port_failed=0 forward_ok=0 forward_ssh_fail_rc=0

  (
    export PATH="${fake_bin}:${PATH}"
    bash "${REPO_ROOT}/scripts/forward.sh" >/dev/null 2>&1
  ) || no_port_failed=1

  (
    export PATH="${fake_bin}:${PATH}"
    PORT="abc" bash "${REPO_ROOT}/scripts/forward.sh" >/dev/null 2>&1
  ) || bad_port_failed=1

  (
    export PATH="${fake_bin}:${PATH}"
    PORT="3000" HOST_PORT="abc" bash "${REPO_ROOT}/scripts/forward.sh" >/dev/null 2>&1
  ) || bad_host_port_failed=1

  : > "${ssh_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_DIR_OUTPUT="/tmp/test-lima-instance"
    export STUB_SSH_LOG="${ssh_log}"
    make -f "${REPO_ROOT}/Makefile" forward ENV_FILE="${empty_env}" 'PORT="3000"' 'HOST_PORT="13000"' >/dev/null 2>&1
  ) && forward_ok=1

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_DIR_OUTPUT="/tmp/test-lima-instance"
    export STUB_SSH_LOG="${test_dir}/ssh_fail.log"
    export STUB_SSH_FAIL=1
    make -f "${REPO_ROOT}/Makefile" forward ENV_FILE="${empty_env}" PORT=3000 >/dev/null 2>&1
  ) || forward_ssh_fail_rc=$?

  if [ "${no_port_failed}" -eq 1 ] && [ "${bad_port_failed}" -eq 1 ] && \
     [ "${bad_host_port_failed}" -eq 1 ] && [ "${forward_ok}" -eq 1 ] && \
     [ "${forward_ssh_fail_rc}" -ne 0 ] && \
     grep -qx "/tmp/test-lima-instance/ssh.config" "${ssh_log}" && \
     grep -qx "ControlMaster=no" "${ssh_log}" && \
     grep -qx "ControlPath=none" "${ssh_log}" && \
     grep -qx "ExitOnForwardFailure=yes" "${ssh_log}" && \
     grep -qx -- "-N" "${ssh_log}" && \
     grep -qx "127.0.0.1:13000:127.0.0.1:3000" "${ssh_log}" && \
     grep -qx "lima-coding-sandbox" "${ssh_log}"; then
    log_pass "${suite}: make forward port validation, ControlMaster options, and ssh error propagation"
  else
    log_fail "${suite}: make forward validation or ssh invocation failed"
  fi

  # 4.16 make terminfo (scripts/terminfo.sh): 事前検証（起動前失敗）、tic -x - 引数検証、tic 失敗伝播
  log_test "${suite}: make terminfo pre-start check, tic arguments, and tic failure propagation"
  cat > "${fake_bin}/infocmp" << 'EOF'
#!/bin/bash
set -eu
if [ "${STUB_INFOCMP_FAIL:-0}" = "1" ]; then
  exit 1
fi
echo "fake-terminfo-data-for-$*"
EOF
  chmod +x "${fake_bin}/infocmp"

  # TERM_NAME が空、または infocmp 失敗時は start (limactl) が呼ばれる前に失敗すること
  : > "${lima_log}"
  local empty_term_failed=0 missing_term_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" TERM_NAME="" >/dev/null 2>&1
  ) || empty_term_failed=1

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_INFOCMP_FAIL=1
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" TERM_NAME="xterm-ghostty" >/dev/null 2>&1
  ) || missing_term_failed=1

  local lima_calls_on_term_fail
  lima_calls_on_term_fail=$(wc -l < "${lima_log}" | tr -d ' ')

  # 正常時は infocmp の出力が limactl shell <NAME> tic -x - の標準入力に渡ること
  local tic_stdin="${test_dir}/tic.stdin"
  : > "${lima_log}"
  local terminfo_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_SHELL_STDIN="${tic_stdin}"
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" 'TERM_NAME="xterm-ghostty"' >/dev/null 2>&1
  ) && terminfo_ok=1

  # tic (limactl shell) が失敗した場合は非ゼロ終了すること
  local tic_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_SHELL_STDIN="${tic_stdin}"
    export STUB_LIMA_SHELL_FAIL=1
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" TERM_NAME="xterm-ghostty" >/dev/null 2>&1
  ) || tic_fail_rc=$?

  if [ "${empty_term_failed}" -eq 1 ] && [ "${missing_term_failed}" -eq 1 ] && \
     [ "${lima_calls_on_term_fail}" -eq 0 ] && [ "${terminfo_ok}" -eq 1 ] && \
     [ "${tic_fail_rc}" -ne 0 ] && \
     grep -q "fake-terminfo-data-for--x xterm-ghostty" "${tic_stdin}" && \
     grep -qx "tic" "${lima_log}" && grep -qx -- "-x" "${lima_log}" && grep -qx -- "-" "${lima_log}"; then
    log_pass "${suite}: make terminfo pre-start check, tic arguments, and tic failure propagation"
  else
    log_fail "${suite}: make terminfo check or tic piping failed"
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

  # 4.18 make backup-auth (scripts/backup-auth.sh): 正常退避・親ディレクトリ権限保持・権限検証・公開鍵自動導出・パスフレーズ鍵拒否・異常時既存バックアップ保護・recreate 連鎖の中断
  log_test "${suite}: make backup-auth normal backup, permissions, pubkey derivation, and failure safety"
  local guest_home_1="${test_dir}/guest_home_1"
  local backup_parent="${test_dir}/auth_backup_store"
  local backup_dest="${backup_parent}/coding-sandbox"
  local default_path
  default_path=$(command -p getconf PATH 2>/dev/null || echo "/usr/bin:/bin:/usr/sbin:/sbin")
  local guest_bin="${test_dir}/guest_bin"
  mkdir -p "${guest_home_1}/.ssh" "${guest_home_1}/.config/gh" "${guest_home_1}/.copilot" "${guest_bin}" "${backup_parent}"
  chmod 0755 "${backup_parent}"

  ssh-keygen -q -t ed25519 -N '' -C "test-backup@lima" -f "${guest_home_1}/.ssh/id_ed25519_signing"
  printf 'github.com:\n    oauth_token: gho_testtoken123\n    user: testuser\n' > "${guest_home_1}/.config/gh/hosts.yml"
  printf '{"oauth_token":"copilot_token_abc"}\n' > "${guest_home_1}/.copilot/config.json"
  printf 'managed instructions\n' > "${guest_home_1}/.copilot/copilot-instructions.md"

  local orig_pub
  orig_pub=$(cat "${guest_home_1}/.ssh/id_ed25519_signing.pub")

  # 1) 公開鍵 (.pub) が欠けている状態でも秘密鍵から導出して退避でき、既存の親ディレクトリ権限 (0755) を変更しないこと
  rm -f "${guest_home_1}/.ssh/id_ed25519_signing.pub"
  local backup_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_1}"
    export STUB_LIMA_GUEST_PATH="${guest_bin}:${default_path}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" backup-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" >/dev/null 2>&1
  ) && backup_ok=1

  # 権限確認 (親ディレクトリ 0755 維持、退避ディレクトリ 0700 / ファイル 0600)
  local parent_perm="" bdir_perm="" key_perm="" gh_perm="" copilot_perm=""
  parent_perm=$(get_octal_perm "${backup_parent}")
  if [ -d "${backup_dest}" ]; then
    bdir_perm=$(get_octal_perm "${backup_dest}")
    key_perm=$(get_octal_perm "${backup_dest}/.ssh/id_ed25519_signing")
    gh_perm=$(get_octal_perm "${backup_dest}/.config/gh/hosts.yml")
    copilot_perm=$(get_octal_perm "${backup_dest}/.copilot/config.json")
  fi

  # 2) Stopped 状態やパスフレーズ保護鍵、シンボリックリンク混入時に失敗し、既存の backup_dest を壊さず、recreate 連鎖時は delete に進まないこと
  local stopped_backup_rc=0 passphrase_backup_rc=0 symlink_backup_rc=0 chain_abort_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    export STUB_LIMA_GUEST_HOME="${guest_home_1}"
    make -f "${REPO_ROOT}/Makefile" backup-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" >/dev/null 2>&1
  ) || stopped_backup_rc=$?

  # パスフレーズ付き鍵および破損した秘密鍵は非対話署名に使えないため拒否され、既存バックアップが維持されること
  local corrupt_backup_rc=0
  mv "${guest_home_1}/.ssh/id_ed25519_signing" "${guest_home_1}/.ssh/id_ed25519_signing.nopass"
  mv "${guest_home_1}/.ssh/id_ed25519_signing.pub" "${guest_home_1}/.ssh/id_ed25519_signing.pub.nopass"
  ssh-keygen -q -t ed25519 -N 'secretpass' -C "pass@lima" -f "${guest_home_1}/.ssh/id_ed25519_signing"
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_1}"
    export STUB_LIMA_GUEST_PATH="${guest_bin}:${default_path}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" backup-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" >/dev/null 2>&1
  ) || passphrase_backup_rc=$?
  printf 'corrupted-private-key-content\n' > "${guest_home_1}/.ssh/id_ed25519_signing"
  cp "${guest_home_1}/.ssh/id_ed25519_signing.pub.nopass" "${guest_home_1}/.ssh/id_ed25519_signing.pub"
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_1}"
    export STUB_LIMA_GUEST_PATH="${guest_bin}:${default_path}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" backup-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" >/dev/null 2>&1
  ) || corrupt_backup_rc=$?
  mv "${guest_home_1}/.ssh/id_ed25519_signing.nopass" "${guest_home_1}/.ssh/id_ed25519_signing"
  mv "${guest_home_1}/.ssh/id_ed25519_signing.pub.nopass" "${guest_home_1}/.ssh/id_ed25519_signing.pub"

  # ゲスト内の config.json がシンボリックリンクにすり替えられた場合
  mv "${guest_home_1}/.copilot/config.json" "${guest_home_1}/.copilot/config.json.real"
  ln -s "/etc/passwd" "${guest_home_1}/.copilot/config.json"
  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_1}"
    export STUB_LIMA_GUEST_PATH="${guest_bin}:${default_path}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" backup-auth recreate ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" YES=1 >/dev/null 2>&1
  ) || chain_abort_rc=$?
  symlink_backup_rc="${chain_abort_rc}"
  local delete_calls_on_backup_fail
  delete_calls_on_backup_fail=$(grep -cx "delete" "${lima_log}" || true)
  rm -f "${guest_home_1}/.copilot/config.json"
  mv "${guest_home_1}/.copilot/config.json.real" "${guest_home_1}/.copilot/config.json"

  local backed_pub=""
  if [ -f "${backup_dest}/.ssh/id_ed25519_signing.pub" ]; then
    backed_pub=$(awk '{print $1, $2}' "${backup_dest}/.ssh/id_ed25519_signing.pub")
  fi
  local expected_pub
  expected_pub=$(printf '%s\n' "${orig_pub}" | awk '{print $1, $2}')

  if [ "${backup_ok}" -eq 1 ] && \
     [ "${parent_perm}" = "755" ] && [ "${bdir_perm}" = "700" ] && [ "${key_perm}" = "600" ] && \
     [ "${gh_perm}" = "600" ] && [ "${copilot_perm}" = "600" ] && \
     [ "${backed_pub}" = "${expected_pub}" ] && \
     [ ! -e "${backup_dest}/.copilot/copilot-instructions.md" ] && \
     [ "${stopped_backup_rc}" -ne 0 ] && [ "${passphrase_backup_rc}" -ne 0 ] && [ "${corrupt_backup_rc}" -ne 0 ] && [ "${symlink_backup_rc}" -ne 0 ] && \
     [ "${delete_calls_on_backup_fail}" -eq 0 ] && \
     grep -q "gho_testtoken123" "${backup_dest}/.config/gh/hosts.yml" && \
     grep -q "copilot_token_abc" "${backup_dest}/.copilot/config.json"; then
    log_pass "${suite}: make backup-auth normal backup, permissions, pubkey derivation, and failure safety"
  else
    log_fail "${suite}: make backup-auth checks failed (ok=${backup_ok}, perms=${parent_perm}/${bdir_perm}/${key_perm}/${gh_perm}/${copilot_perm}, stop_rc=${stopped_backup_rc}, pass_rc=${passphrase_backup_rc}, sym_rc=${symlink_backup_rc}, del=${delete_calls_on_backup_fail})"
  fi

  # 4.19 make restore-auth (scripts/restore-auth.sh): 起動前検証（副作用なし）・シンボリックリンク拒否・新 VM への復元・allowed_signers 更新と署名検証・gh auth setup-git・instructions 保持
  log_test "${suite}: make restore-auth pre-start check, key/signers restoration, signing verification, and gh setup-git"
  : > "${lima_log}"
  local missing_restore_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" restore-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${test_dir}/nonexistent_backup" >/dev/null 2>&1
  ) || missing_restore_rc=$?
  local lima_calls_on_restore_check_fail
  lima_calls_on_restore_check_fail=$(wc -l < "${lima_log}" | tr -d ' ')

  # 退避先の秘密鍵が破損またはパスフレーズ保護されている場合、VM 起動 (limactl) 前に --check で失敗すること
  local corrupt_restore_dir="${test_dir}/corrupt_restore_backup"
  mkdir -p "${corrupt_restore_dir}/.ssh"
  chmod 0700 "${corrupt_restore_dir}" "${corrupt_restore_dir}/.ssh"
  printf 'corrupt-key\n' > "${corrupt_restore_dir}/.ssh/id_ed25519_signing"
  cp "${backup_dest}/.ssh/id_ed25519_signing.pub" "${corrupt_restore_dir}/.ssh/id_ed25519_signing.pub"
  chmod 0600 "${corrupt_restore_dir}/.ssh/id_ed25519_signing" "${corrupt_restore_dir}/.ssh/id_ed25519_signing.pub"
  : > "${lima_log}"
  local corrupt_restore_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" restore-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${corrupt_restore_dir}" >/dev/null 2>&1
  ) || corrupt_restore_rc=$?
  local lima_calls_on_corrupt_restore
  lima_calls_on_corrupt_restore=$(wc -l < "${lima_log}" | tr -d ' ')

  local passphrase_restore_dir="${test_dir}/passphrase_restore_backup"
  mkdir -p "${passphrase_restore_dir}/.ssh"
  chmod 0700 "${passphrase_restore_dir}" "${passphrase_restore_dir}/.ssh"
  ssh-keygen -q -t ed25519 -N 'restorepass' -C "pass@restore" -f "${passphrase_restore_dir}/.ssh/id_ed25519_signing"
  chmod 0600 "${passphrase_restore_dir}/.ssh/id_ed25519_signing" "${passphrase_restore_dir}/.ssh/id_ed25519_signing.pub"
  : > "${lima_log}"
  local passphrase_restore_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" restore-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${passphrase_restore_dir}" >/dev/null 2>&1
  ) || passphrase_restore_rc=$?
  local lima_calls_on_passphrase_restore
  lima_calls_on_passphrase_restore=$(wc -l < "${lima_log}" | tr -d ' ')

  # --check が退避先内のファイル権限を変更しない（副作用がない）ことを確認
  touch "${backup_dest}/unrelated.txt"
  chmod 0644 "${backup_dest}/unrelated.txt"
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    AUTH_BACKUP_DIR="${backup_dest}" bash "${REPO_ROOT}/scripts/restore-auth.sh" --check >/dev/null 2>&1
  )
  local check_unrelated_perm
  check_unrelated_perm=$(get_octal_perm "${backup_dest}/unrelated.txt")
  rm -f "${backup_dest}/unrelated.txt"

  # 新しく再作成された VM のホームディレクトリを模擬（初回起動で別の鍵が生成され、allowed_signers と copilot-instructions.md がある状態）
  # 同一メールアドレスの別端末鍵 (other_device_pub) が併存している場合も、一時鍵のみ置換され別端末鍵は保持されることを確認
  local guest_home_2="${test_dir}/guest_home_2"
  mkdir -p "${guest_home_2}/.ssh" "${guest_home_2}/.config/git" "${guest_home_2}/.config/gh" "${guest_home_2}/.copilot"
  ssh-keygen -q -t ed25519 -N '' -C "throwaway@lima" -f "${guest_home_2}/.ssh/id_ed25519_signing"
  local throwaway_pub other_device_pub
  throwaway_pub=$(awk '{print $1, $2}' "${guest_home_2}/.ssh/id_ed25519_signing.pub")
  other_device_pub="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOtherDeviceKeyBlobForSameEmail123456"
  {
    printf 'restored@example.com namespaces="git" %s\n' "${other_device_pub}"
    printf 'restored@example.com namespaces="git" %s\n' "${throwaway_pub}"
  } > "${guest_home_2}/.config/git/allowed_signers"
  printf 'keep-this-agent-instructions\n' > "${guest_home_2}/.copilot/copilot-instructions.md"

  local real_git
  real_git=$(PATH="${default_path}:${PATH}" command -v git)
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global user.name "Restored User"
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global user.email "restored@example.com"
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global gpg.format ssh
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global user.signingkey "${guest_home_2}/.ssh/id_ed25519_signing"
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global commit.gpgsign true
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global gpg.ssh.allowedSignersFile "${guest_home_2}/.config/git/allowed_signers"

  # ゲスト側 gh スタブ（gh auth setup-git の呼び出しを記録）
  local gh_setup_log="${test_dir}/gh_setup.log"
  cat > "${guest_bin}/gh" << EOF
#!/bin/bash
printf '%s\n' "\$*" >> "${gh_setup_log}"
exit 0
EOF
  chmod +x "${guest_bin}/gh"
  ln -sf "${real_git}" "${guest_bin}/git"

  # ゲスト内の ~/.config/gh/hosts.yml がシンボリックリンクの場合は復元を拒否すること
  ln -s "/tmp/outside_hosts.yml" "${guest_home_2}/.config/gh/hosts.yml"
  local gh_child_symlink_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_2}"
    export STUB_LIMA_GUEST_PATH="${guest_bin}:${default_path}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" restore-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" >/dev/null 2>&1
  ) || gh_child_symlink_rc=$?
  rm -f "${guest_home_2}/.config/gh/hosts.yml"

  # commit.gpgsign に不正な真偽値が設定されている場合はエラー終了すること
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global commit.gpgsign "not-a-bool"
  local invalid_gpgsign_restore_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_2}"
    export STUB_LIMA_GUEST_PATH="${guest_bin}:${default_path}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" restore-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" >/dev/null 2>&1
  ) || invalid_gpgsign_restore_rc=$?
  HOME="${guest_home_2}" GIT_CONFIG_GLOBAL="${guest_home_2}/.gitconfig" "${real_git}" config --global commit.gpgsign true

  local restore_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_host_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_2}"
    export STUB_LIMA_GUEST_PATH="${guest_bin}:${default_path}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" restore-auth ENV_FILE="${empty_env}" AUTH_BACKUP_DIR="${backup_dest}" >/dev/null 2>&1
  ) && restore_ok=1

  local restored_pub="" signers_content="" signers_lines=0
  if [ -f "${guest_home_2}/.ssh/id_ed25519_signing.pub" ]; then
    restored_pub=$(awk '{print $1, $2}' "${guest_home_2}/.ssh/id_ed25519_signing.pub")
  fi
  if [ -f "${guest_home_2}/.config/git/allowed_signers" ]; then
    signers_content=$(cat "${guest_home_2}/.config/git/allowed_signers")
    signers_lines=$(wc -l < "${guest_home_2}/.config/git/allowed_signers" | tr -d ' ')
  fi

  if [ "${missing_restore_rc}" -ne 0 ] && [ "${lima_calls_on_restore_check_fail}" -eq 0 ] && \
     [ "${corrupt_restore_rc}" -ne 0 ] && [ "${lima_calls_on_corrupt_restore}" -eq 0 ] && \
     [ "${passphrase_restore_rc}" -ne 0 ] && [ "${lima_calls_on_passphrase_restore}" -eq 0 ] && \
     [ "${check_unrelated_perm}" = "644" ] && \
     [ "${gh_child_symlink_rc}" -ne 0 ] && [ ! -e "/tmp/outside_hosts.yml" ] && \
     [ "${invalid_gpgsign_restore_rc}" -ne 0 ] && \
     [ "${restore_ok}" -eq 1 ] && \
     [ "${restored_pub}" = "${expected_pub}" ] && \
     [ "${signers_lines}" -eq 2 ] && \
     printf '%s\n' "${signers_content}" | grep -qF "${other_device_pub}" && \
     printf '%s\n' "${signers_content}" | grep -qF "${expected_pub}" && \
     ! printf '%s\n' "${signers_content}" | grep -qF "${throwaway_pub}" && \
     grep -qx "auth setup-git" "${gh_setup_log}" && \
     grep -q "gho_testtoken123" "${guest_home_2}/.config/gh/hosts.yml" && \
     grep -q "copilot_token_abc" "${guest_home_2}/.copilot/config.json" && \
     grep -qx "keep-this-agent-instructions" "${guest_home_2}/.copilot/copilot-instructions.md"; then
    log_pass "${suite}: make restore-auth pre-start check, key/signers restoration, signing verification, and gh setup-git"
  else
    log_fail "${suite}: make restore-auth checks failed (missing_rc=${missing_restore_rc}, calls=${lima_calls_on_restore_check_fail}, pass_rc=${passphrase_restore_rc}, perm=${check_unrelated_perm}, gh_sym=${gh_child_symlink_rc}, gpg_rc=${invalid_gpgsign_restore_rc}, restore_ok=${restore_ok}, lines=${signers_lines})"
  fi

  # 4.20 make register-key (scripts/register-key.sh): 起動前検証（gh 未導入・空 NAME）・正常登録・公開鍵不備やスコープ不足時のエラー案内
  log_test "${suite}: make register-key pre-start check, signing key registration, and scope error guidance"
  local host_gh_args="${test_dir}/host_gh.args"
  local host_gh_stdin="${test_dir}/host_gh.stdin"

  # 1) ホストの PATH に gh が無い場合、VM 起動 (limactl) 前に失敗すること
  local no_gh_bin="${test_dir}/no_gh_bin"
  mkdir -p "${no_gh_bin}"
  for tool in bash sh grep awk sed tr wc cat rm mkdir mktemp dirname pwd cd printf chmod install tar ssh-keygen date; do
    local tool_path
    if tool_path=$(command -v "${tool}" 2>/dev/null) && [ -x "${tool_path}" ]; then
      ln -sf "${tool_path}" "${no_gh_bin}/${tool}"
    fi
  done
  ln -sf "${fake_bin}/limactl" "${no_gh_bin}/limactl"
  local make_bin
  make_bin=$(command -v make)

  : > "${lima_log}"
  local no_gh_reg_rc=0
  (
    export PATH="${no_gh_bin}"
    export STUB_LIMACTL_LOG="${lima_log}"
    "${make_bin}" -f "${REPO_ROOT}/Makefile" register-key ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || no_gh_reg_rc=$?
  local lima_calls_on_no_gh
  lima_calls_on_no_gh=$(wc -l < "${lima_log}" | tr -d ' ')

  # ホスト側 gh スタブを作成
  cat > "${fake_bin}/gh" << 'EOF'
#!/bin/bash
set -eu
for arg in "$@"; do
  printf '%s\n' "$arg" >> "${STUB_HOST_GH_ARGS}"
done
cat > "${STUB_HOST_GH_STDIN}"
if [ "${STUB_HOST_GH_FAIL:-0}" = "1" ]; then
  echo >&2 "HTTP 404: Not Found (https://api.github.com/user/ssh_signing_keys)"
  exit 1
fi
if [ "${STUB_HOST_GH_EXISTS:-0}" = "1" ]; then
  echo "✓ Public key already exists on your account"
  exit 0
fi
exit 0
EOF
  chmod +x "${fake_bin}/gh"

  # 2) NAME="" の場合も VM 起動前に失敗すること
  : > "${lima_log}"
  local empty_name_reg_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" register-key ENV_FILE="${empty_env}" NAME= >/dev/null 2>&1
  ) || empty_name_reg_rc=$?
  local lima_calls_on_empty_reg_name
  lima_calls_on_empty_reg_name=$(wc -l < "${lima_log}" | tr -d ' ')

  # 3) 正常登録: ゲストの .ssh/id_ed25519_signing.pub が gh ssh-key add --type signing --title "<NAME> <YYYY-MM-DD>" に渡ること
  : > "${host_gh_args}"
  : > "${host_gh_stdin}"
  local reg_ok=0 reg_out=""
  reg_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="sandbox2 Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_2}"
    export STUB_HOST_GH_ARGS="${host_gh_args}"
    export STUB_HOST_GH_STDIN="${host_gh_stdin}"
    make -f "${REPO_ROOT}/Makefile" register-key ENV_FILE="${empty_env}" 'NAME=" sandbox2 "' 2>&1
  ) && reg_ok=1

  local guest_2_pub guest_2_fp reg_stdin_pub reg_gh_args_snapshot
  guest_2_pub=$(cat "${guest_home_2}/.ssh/id_ed25519_signing.pub")
  guest_2_fp=$(ssh-keygen -lf "${guest_home_2}/.ssh/id_ed25519_signing.pub" | awk '{print $2}')
  reg_stdin_pub=$(cat "${host_gh_stdin}")
  reg_gh_args_snapshot=$(cat "${host_gh_args}")

  # 3b) 鍵コメント末尾に作成日（例: 2026-10-15、CRLF 改行付き）がある場合、その日付がタイトルに使われ、既存鍵登録済みの場合は「既に GitHub に登録されています」と表示され「登録しました」は表示されないこと
  local dated_guest="${test_dir}/dated_guest"
  mkdir -p "${dated_guest}/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C "git-signing test@lima-sandbox2 2026-10-15" -f "${dated_guest}/.ssh/id_ed25519_signing"
  printf '%s\r\n' "$(cat "${dated_guest}/.ssh/id_ed25519_signing.pub")" > "${dated_guest}/.ssh/id_ed25519_signing.pub"
  : > "${host_gh_args}"
  local reg_exists_ok=0 reg_exists_out="" reg_dated_args=""
  reg_exists_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="sandbox2 Running"
    export STUB_LIMA_GUEST_HOME="${dated_guest}"
    export STUB_HOST_GH_ARGS="${host_gh_args}"
    export STUB_HOST_GH_STDIN="${host_gh_stdin}"
    export STUB_HOST_GH_EXISTS=1
    make -f "${REPO_ROOT}/Makefile" register-key ENV_FILE="${empty_env}" NAME=sandbox2 2>&1
  ) && reg_exists_ok=1
  reg_dated_args=$(cat "${host_gh_args}")

  # 4) ゲストが Stopped の状態で直接 scripts/register-key.sh を呼んだ場合は失敗し gh を呼ばないこと
  : > "${host_gh_args}"
  local stopped_reg_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    export STUB_HOST_GH_ARGS="${host_gh_args}"
    export STUB_HOST_GH_STDIN="${host_gh_stdin}"
    bash "${REPO_ROOT}/scripts/register-key.sh" >/dev/null 2>&1
  ) || stopped_reg_rc=$?
  local gh_calls_on_stopped
  gh_calls_on_stopped=$(wc -l < "${host_gh_args}" | tr -d ' ')

  # 5) ゲストの公開鍵が破損している場合、または複数行の場合は gh を呼ばずに失敗すること
  local bad_pub_guest="${test_dir}/bad_pub_guest"
  mkdir -p "${bad_pub_guest}/.ssh"
  printf 'not-a-valid-ssh-public-key\n' > "${bad_pub_guest}/.ssh/id_ed25519_signing.pub"
  : > "${host_gh_args}"
  local bad_pub_reg_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${bad_pub_guest}"
    export STUB_HOST_GH_ARGS="${host_gh_args}"
    export STUB_HOST_GH_STDIN="${host_gh_stdin}"
    make -f "${REPO_ROOT}/Makefile" register-key ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || bad_pub_reg_rc=$?
  local gh_calls_on_bad_pub
  gh_calls_on_bad_pub=$(wc -l < "${host_gh_args}" | tr -d ' ')

  local multi_pub_guest="${test_dir}/multi_pub_guest"
  mkdir -p "${multi_pub_guest}/.ssh"
  {
    printf '%s\n' "${guest_2_pub}"
    printf '%s\n' "${guest_2_pub}"
  } > "${multi_pub_guest}/.ssh/id_ed25519_signing.pub"
  : > "${host_gh_args}"
  local multi_pub_reg_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${multi_pub_guest}"
    export STUB_HOST_GH_ARGS="${host_gh_args}"
    export STUB_HOST_GH_STDIN="${host_gh_stdin}"
    make -f "${REPO_ROOT}/Makefile" register-key ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || multi_pub_reg_rc=$?
  local gh_calls_on_multi_pub
  gh_calls_on_multi_pub=$(wc -l < "${host_gh_args}" | tr -d ' ')

  # 6) gh ssh-key add がスコープ不足等で失敗した場合、非ゼロ終了し gh auth refresh の案内が出ること
  local gh_fail_reg_rc=0 gh_fail_reg_err=""
  gh_fail_reg_err=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${guest_home_2}"
    export STUB_HOST_GH_ARGS="${host_gh_args}"
    export STUB_HOST_GH_STDIN="${host_gh_stdin}"
    export STUB_HOST_GH_FAIL=1
    make -f "${REPO_ROOT}/Makefile" register-key ENV_FILE="${empty_env}" 2>&1
  ) || gh_fail_reg_rc=$?

  if [ "${no_gh_reg_rc}" -ne 0 ] && [ "${lima_calls_on_no_gh}" -eq 0 ] && \
     [ "${empty_name_reg_rc}" -ne 0 ] && [ "${lima_calls_on_empty_reg_name}" -eq 0 ] && \
     [ "${reg_ok}" -eq 1 ] && \
     [ "${reg_stdin_pub}" = "${guest_2_pub}" ] && \
     printf '%s\n' "${reg_gh_args_snapshot}" | grep -qx "ssh-key" && \
     printf '%s\n' "${reg_gh_args_snapshot}" | grep -qx "add" && \
     printf '%s\n' "${reg_gh_args_snapshot}" | grep -qx -- "--type" && \
     printf '%s\n' "${reg_gh_args_snapshot}" | grep -qx "signing" && \
     printf '%s\n' "${reg_gh_args_snapshot}" | grep -qx -- "--title" && \
     printf '%s\n' "${reg_gh_args_snapshot}" | grep -Eq '^sandbox2 [0-9]{4}-[0-9]{2}-[0-9]{2}$' && \
     printf '%s\n' "${reg_out}" | grep -qF "${guest_2_fp}" && \
     [ "${reg_exists_ok}" -eq 1 ] && \
     printf '%s\n' "${reg_dated_args}" | grep -qx "sandbox2 2026-10-15" && \
     printf '%s\n' "${reg_exists_out}" | grep -q "既に GitHub に登録されています" && \
     ! printf '%s\n' "${reg_exists_out}" | grep -q "登録しました" && \
     [ "${stopped_reg_rc}" -ne 0 ] && [ "${gh_calls_on_stopped}" -eq 0 ] && \
     [ "${bad_pub_reg_rc}" -ne 0 ] && [ "${gh_calls_on_bad_pub}" -eq 0 ] && \
     [ "${multi_pub_reg_rc}" -ne 0 ] && [ "${gh_calls_on_multi_pub}" -eq 0 ] && \
     [ "${gh_fail_reg_rc}" -ne 0 ] && \
     printf '%s\n' "${gh_fail_reg_err}" | grep -q "gh auth refresh -h github.com -s read:ssh_signing_key,write:ssh_signing_key"; then
    log_pass "${suite}: make register-key pre-start check, signing key registration, and scope error guidance"
  else
    log_fail "${suite}: make register-key checks failed (no_gh_rc=${no_gh_reg_rc}/${lima_calls_on_no_gh}, empty_rc=${empty_name_reg_rc}/${lima_calls_on_empty_reg_name}, reg_ok=${reg_ok}, reg_exists=${reg_exists_ok}, stop_rc=${stopped_reg_rc}, bad_pub=${bad_pub_reg_rc}, multi_pub=${multi_pub_reg_rc}, gh_fail=${gh_fail_reg_rc})"
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

  # 5.6 docker-engine.sh: docker.sources が Enabled: no または Signed-By 参照先不一致の場合、スキップせず再作成すること
  log_test "${suite}: docker-engine reconfigures when deb822 stanza is disabled or misconfigured"
  local deb822_dir="${test_dir}/deb822_reconfig"
  local deb822_tmp="${test_dir}/deb822_tmp"
  mkdir -p "${deb822_dir}" "${deb822_tmp}"

  local deb822_key="${deb822_dir}/docker.asc"
  local deb822_src="${deb822_dir}/docker.sources"
  echo "valid-key-data" > "${deb822_key}"
  cat > "${deb822_src}" << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: ${deb822_key}
Enabled: no
EOF

  (
    export "${test_env[@]}"
    export TMPDIR="${deb822_tmp}"
    export DOCKER_KEYRING="${deb822_key}"
    export DOCKER_SOURCES="${deb822_src}"
    export DOCKER_WRAPPER="${deb822_dir}/docker"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local deb822_has_active_stanza=0
  if awk -v uri="https://download.docker.com/linux/ubuntu" -v key="${deb822_key}" '
    BEGIN { RS = ""; found = 0 }
    {
      has_uri = 0; has_key = 0; enabled = 1
      n = split($0, lines, "\n")
      for (i = 1; i <= n; i++) {
        line = lines[i]
        sub(/#.*$/, "", line)
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]+$/, "", line)
        if (line == "") continue
        if (tolower(line) ~ /^enabled:[ \t]*(no|false|0)/) enabled = 0
        if (line ~ /^URIs:[ \t]+/) {
          val = line; sub(/^URIs:[ \t]+/, "", val)
          n_uris = split(val, uwords, /[ \t]+/)
          for (j = 1; j <= n_uris; j++) {
            u = uwords[j]; sub(/\/+$/, "", u)
            target_u = uri; sub(/\/+$/, "", target_u)
            if (u == target_u) has_uri = 1
          }
        }
        if (line ~ /^Signed-By:[ \t]+/) {
          val = line; sub(/^Signed-By:[ \t]+/, "", val)
          sub(/^[ \t"]+/, "", val)
          sub(/[ \t"]+$/, "", val)
          if (val == key) has_key = 1
        }
      }
      if (has_uri && has_key && enabled) found = 1
    }
    END { exit !found }
  ' "${deb822_src}" 2>/dev/null; then
    deb822_has_active_stanza=1
  fi

  # Signed-By が .old を指している場合もテスト
  cat > "${deb822_src}" << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: ${deb822_key}.old
EOF
  (
    export "${test_env[@]}"
    export TMPDIR="${deb822_tmp}"
    export DOCKER_KEYRING="${deb822_key}"
    export DOCKER_SOURCES="${deb822_src}"
    export DOCKER_WRAPPER="${deb822_dir}/docker"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local deb822_fixed_old_key=0
  if grep -q "Signed-By: ${deb822_key}$" "${deb822_src}" 2>/dev/null; then
    deb822_fixed_old_key=1
  fi

  if [ "${deb822_has_active_stanza}" -eq 1 ] && [ "${deb822_fixed_old_key}" -eq 1 ]; then
    log_pass "${suite}: docker-engine reconfigures when deb822 stanza is disabled or misconfigured"
  else
    log_fail "${suite}: docker-engine failed to reconfigure disabled or misconfigured deb822 sources"
  fi

  # 5.7 docker-engine.sh: Types が deb-src のみ、または Suites/Components が欠落している場合は再設定すること
  log_test "${suite}: docker-engine reconfigures when Types is deb-src only or suite/components missing"
  cat > "${deb822_src}" << EOF
Types: deb-src
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Signed-By: ${deb822_key}
EOF
  (
    export "${test_env[@]}"
    export TMPDIR="${deb822_tmp}"
    export DOCKER_KEYRING="${deb822_key}"
    export DOCKER_SOURCES="${deb822_src}"
    export DOCKER_WRAPPER="${deb822_dir}/docker"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local deb822_fixed_types=0
  if grep -q "Types:.*deb\([ \t]\|$\)" "${deb822_src}" 2>/dev/null && ! grep -q "^Types:[ \t]*deb-src[ \t]*$" "${deb822_src}" 2>/dev/null; then
    deb822_fixed_types=1
  fi

  if [ "${deb822_fixed_types}" -eq 1 ]; then
    log_pass "${suite}: docker-engine reconfigures when Types is deb-src only or suite/components missing"
  else
    log_fail "${suite}: docker-engine failed to reconfigure deb822 sources with deb-src only"
  fi

  # 5.8 docker-engine.sh: Architectures が native_arch を除外している場合は再設定すること
  log_test "${suite}: docker-engine reconfigures when Architectures excludes native arch"
  cat > "${deb822_src}" << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: arm64
Signed-By: ${deb822_key}
EOF
  (
    export "${test_env[@]}"
    export TMPDIR="${deb822_tmp}"
    export DOCKER_KEYRING="${deb822_key}"
    export DOCKER_SOURCES="${deb822_src}"
    export DOCKER_WRAPPER="${deb822_dir}/docker"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local deb822_fixed_arch=0
  if grep -Eq "^Architectures:[[:space:]]+amd64" "${deb822_src}" 2>/dev/null; then
    deb822_fixed_arch=1
  fi

  if [ "${deb822_fixed_arch}" -eq 1 ]; then
    log_pass "${suite}: docker-engine reconfigures when Architectures excludes native arch"
  else
    log_fail "${suite}: docker-engine failed to reconfigure deb822 sources when native arch excluded"
  fi

  # 5.9 docker-engine.sh: Architectures-Remove: amd64 は再設定し、Architectures-Add: arm64 は受理すること
  log_test "${suite}: docker-engine handles Architectures-Remove and Architectures-Add correctly"
  cat > "${deb822_src}" << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures-Remove: amd64
Architectures: amd64
Signed-By: ${deb822_key}
EOF
  (
    export "${test_env[@]}"
    export TMPDIR="${deb822_tmp}"
    export DOCKER_KEYRING="${deb822_key}"
    export DOCKER_SOURCES="${deb822_src}"
    export DOCKER_WRAPPER="${deb822_dir}/docker"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local deb822_remove_reconfigured=0
  if grep -Eq "^Architectures:[[:space:]]+amd64" "${deb822_src}" 2>/dev/null && ! grep -q "Architectures-Remove" "${deb822_src}" 2>/dev/null; then
    deb822_remove_reconfigured=1
  fi

  if [ "${deb822_remove_reconfigured}" -eq 1 ]; then
    log_pass "${suite}: docker-engine handles Architectures-Remove and Architectures-Add correctly"
  else
    log_fail "${suite}: docker-engine failed to reconfigure deb822 sources on Architectures-Remove"
  fi

  # 5.10 docker-engine.sh: Architectures: の後に継続行で arm64 が指定された場合、再設定すること
  log_test "${suite}: docker-engine folds Deb822 continuation lines and reconfigures when native arch excluded"
  cat > "${deb822_src}" << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures:
  arm64
Signed-By: ${deb822_key}
EOF
  (
    export "${test_env[@]}"
    export TMPDIR="${deb822_tmp}"
    export DOCKER_KEYRING="${deb822_key}"
    export DOCKER_SOURCES="${deb822_src}"
    export DOCKER_WRAPPER="${deb822_dir}/docker"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local deb822_continuation_reconfigured=0
  if grep -Eq "^Architectures:[[:space:]]+amd64" "${deb822_src}" 2>/dev/null; then
    deb822_continuation_reconfigured=1
  fi

  if [ "${deb822_continuation_reconfigured}" -eq 1 ]; then
    log_pass "${suite}: docker-engine folds Deb822 continuation lines and reconfigures when native arch excluded"
  else
    log_fail "${suite}: docker-engine failed to reconfigure deb822 sources with indented non-native arch"
  fi

  # 5.11 docker-engine.sh: Architectures: arm64 の後に継続行で amd64 が指定された場合、受理されること
  log_test "${suite}: docker-engine folds Deb822 continuation lines and accepts when native arch included"
  cat > "${deb822_src}" << EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: noble
Components: stable
Architectures: arm64
  amd64
Signed-By: ${deb822_key}
EOF
  (
    export "${test_env[@]}"
    export TMPDIR="${deb822_tmp}"
    export DOCKER_KEYRING="${deb822_key}"
    export DOCKER_SOURCES="${deb822_src}"
    export DOCKER_WRAPPER="${deb822_dir}/docker"
    bash "${REPO_ROOT}/provision/docker-engine.sh" >/dev/null 2>&1
  )

  local deb822_continuation_accepted=0
  if grep -q "arm64" "${deb822_src}" 2>/dev/null && grep -q "amd64" "${deb822_src}" 2>/dev/null; then
    deb822_continuation_accepted=1
  fi

  if [ "${deb822_continuation_accepted}" -eq 1 ]; then
    log_pass "${suite}: docker-engine folds Deb822 continuation lines and accepts when native arch included"
  else
    log_fail "${suite}: docker-engine failed to accept deb822 sources with folded native arch"
  fi
}

# -----------------------------------------------------------------------------
# Test Suite 6: GitHub CLI packaging source and apt-packages.sh verification
# -----------------------------------------------------------------------------
test_gh_and_apt_packages() {
  local suite="provision/github-cli.sh & apt-packages.sh gh verification"
  local test_dir="${MASTER_TEST_DIR}/gh_apt_packages"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"

  local installed_flag="${test_dir}/gh_upgraded.flag"

  # スタブ dpkg
  cat > "${fake_bin}/dpkg" << 'EOF'
#!/bin/bash
set -eu
case "$*" in
  *--print-architecture*)
    echo "${STUB_DPKG_ARCH-amd64}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/dpkg"

  # スタブ dpkg-query
  cat > "${fake_bin}/dpkg-query" << EOF
#!/bin/bash
set -eu
case "\$*" in
  *db:Status-Status*gh*)
    if [ "\${STUB_GH_INSTALLED:-1}" = "1" ]; then
      echo "installed"
    else
      echo "not-installed"
    fi
    ;;
  *db:Status-Status*)
    echo "installed"
    ;;
  *Maintainer*gh*)
    if [ -f "${installed_flag}" ]; then
      echo "GitHub <support@github.com>"
    else
      echo "\${STUB_GH_MAINTAINER:-GitHub <support@github.com>}"
    fi
    ;;
  *)
    echo "ok"
    ;;
esac
EOF
  chmod +x "${fake_bin}/dpkg-query"

  # スタブ apt-cache
  cat > "${fake_bin}/apt-cache" << 'EOF'
#!/bin/bash
set -eu
case "$*" in
  *madison*gh*)
    if [ "${STUB_MADISON_OFFICIAL:-1}" = "1" ]; then
      echo "gh | 2.60.0 | https://cli.github.com/packages stable/main amd64 Packages"
    else
      echo "gh | 2.46.0 | http://archive.ubuntu.com/ubuntu noble/universe amd64 Packages"
    fi
    ;;
  *madison*docker-ce*)
    echo "docker-ce | 27.0.0 | https://download.docker.com/linux/ubuntu noble/stable amd64 Packages"
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/apt-cache"

  # スタブ apt-get
  local apt_log="${test_dir}/apt.log"
  cat > "${fake_bin}/apt-get" << EOF
#!/bin/bash
set -eu
printf '%s\n' "\$*" >> "${apt_log}"
case "\$*" in
  *install*gh*)
    touch "${installed_flag}"
    ;;
esac
exit 0
EOF
  chmod +x "${fake_bin}/apt-get"

  # スタブ gh
  cat > "${fake_bin}/gh" << 'EOF'
#!/bin/bash
set -eu
case "${STUB_GH_MODE:-default}" in
  fail)
    exit 1
    ;;
  hang)
    sleep 10
    ;;
  *)
    echo "gh version 2.60.0 (2026-10-01)"
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/gh"

  # スタブ ln（ホストの /usr/local/bin/fd 等への書き込みを防止）
  cat > "${fake_bin}/ln" << 'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${fake_bin}/ln"

  local test_env=(
    "PATH=${fake_bin}:${PATH}"
    "GH_BIN=${fake_bin}/gh"
    "CLI_VERIFY_TIMEOUT=1"
  )

  # 6.1 github-cli.sh: 空または破損した repo_list がある場合、スキップせず公式リポジトリを再設定する
  log_test "${suite}: github-cli reconfigures when repo list is empty or corrupted"
  local gh_dir="${test_dir}/gh_reconfig"
  local gh_tmp="${test_dir}/gh_reconfig_tmp"
  mkdir -p "${gh_dir}" "${gh_tmp}"
  local gh_key="${gh_dir}/key.gpg"
  local gh_repo="${gh_dir}/repo.list"
  touch "${gh_key}"
  echo "# corrupted list" > "${gh_repo}"

  cat > "${fake_bin}/curl" << 'EOF'
#!/bin/bash
set -eu
dest=""
write_out=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  arg="${args[$i]}"
  case "$arg" in
    -o) i=$((i + 1)); dest="${args[$i]}" ;;
    -w) i=$((i + 1)); write_out="${args[$i]}" ;;
  esac
  i=$((i + 1))
done
if [ -n "${dest}" ]; then printf 'valid-key\n' > "${dest}"; fi
if [ -n "${write_out}" ]; then printf '200'; fi
exit 0
EOF
  chmod +x "${fake_bin}/curl"

  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local has_official_url=0
  if grep -qF "https://cli.github.com/packages" "${gh_repo}" 2>/dev/null; then
    has_official_url=1
  fi

  if [ -s "${gh_key}" ] && [ "${has_official_url}" -eq 1 ]; then
    log_pass "${suite}: github-cli reconfigures when repo list is empty or corrupted"
  else
    log_fail "${suite}: github-cli failed to reconfigure corrupted repo list"
  fi

  # 6.2 apt-packages.sh: Ubuntu 版 gh が存在する場合、all_installed が false となり公式版のインストールを実行する
  log_test "${suite}: apt-packages detects Ubuntu universe gh and triggers install"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  local ubuntu_gh_run=0
  (
    export "${test_env[@]}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) && ubuntu_gh_run=1

  local apt_install_called=0
  if grep -q "install.*gh" "${apt_log}"; then
    apt_install_called=1
  fi

  if [ "${ubuntu_gh_run}" -eq 1 ] && [ "${apt_install_called}" -eq 1 ]; then
    log_pass "${suite}: apt-packages detects Ubuntu universe gh and triggers install"
  else
    log_fail "${suite}: apt-packages did not trigger install for Ubuntu universe gh (run=${ubuntu_gh_run}, called=${apt_install_called})"
  fi

  # 6.3 apt-packages.sh: 公式版 gh が正常に導入されている場合、再実行時は apt-get update/install をスキップする
  log_test "${suite}: apt-packages skips execution when official gh is installed and working"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="GitHub <support@github.com>"
    export STUB_GH_MODE="default"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  )

  local apt_called_count
  apt_called_count=$(wc -l < "${apt_log}" | tr -d ' ')

  if [ "${apt_called_count}" -eq 0 ]; then
    log_pass "${suite}: apt-packages skips execution when official gh is installed and working"
  else
    log_fail "${suite}: apt-packages ran unexpectedly when all packages were up to date"
  fi

  # 6.4 apt-packages.sh: gh --version が失敗する場合、all_installed が false となる
  log_test "${suite}: apt-packages detects broken gh binary via --version"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="GitHub <support@github.com>"
    export STUB_GH_MODE="fail"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) || true

  local fail_detected=0
  if grep -q "install.*gh" "${apt_log}" && grep -q -- "--reinstall" "${apt_log}"; then
    fail_detected=1
  fi

  if [ "${fail_detected}" -eq 1 ]; then
    log_pass "${suite}: apt-packages detects broken gh binary via --version"
  else
    log_fail "${suite}: broken gh binary was not detected or reinstalled"
  fi

  # 6.5 github-cli.sh: コメントアウトされた deb 行のみの場合はスキップせず再設定すること
  log_test "${suite}: github-cli reconfigures when deb line is commented out"
  echo "# deb [signed-by=${gh_key}] https://cli.github.com/packages stable main" > "${gh_repo}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local has_uncommented_deb=0
  if grep -Eq '^[[:space:]]*deb[[:space:]]+.*https://cli\.github\.com/packages' "${gh_repo}" 2>/dev/null; then
    has_uncommented_deb=1
  fi

  if [ "${has_uncommented_deb}" -eq 1 ]; then
    log_pass "${suite}: github-cli reconfigures when deb line is commented out"
  else
    log_fail "${suite}: github-cli skipped reconfigure on commented-out repo line"
  fi

  # 6.6 apt-packages.sh: GitHub 以外のサードパーティ Maintainer が存在する場合に公式版インストールを実行する
  log_test "${suite}: apt-packages rejects non-GitHub third-party maintainer"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="ThirdParty Packager <packager@example.com>"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) || true

  local thirdparty_install_called=0
  if grep -q "install.*gh" "${apt_log}"; then
    thirdparty_install_called=1
  fi

  if [ "${thirdparty_install_called}" -eq 1 ]; then
    log_pass "${suite}: apt-packages rejects non-GitHub third-party maintainer"
  else
    log_fail "${suite}: third-party maintainer was accepted as official"
  fi

  # 6.7 apt-packages.sh: PATH 上の別バイナリではなく管理対象バイナリ（GH_BIN）を検証すること
  log_test "${suite}: apt-packages verifies managed binary rather than shadowing command on PATH"
  local shadow_bin="${test_dir}/shadow_bin"
  mkdir -p "${shadow_bin}"
  # shadow_bin の gh は常に成功
  cat > "${shadow_bin}/gh" << 'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "${shadow_bin}/gh"

  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    export PATH="${shadow_bin}:${PATH}"
    # managed binary である GH_BIN は fail モード
    export STUB_GH_MODE="fail"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="GitHub <support@github.com>"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) || true

  local managed_check_called=0
  if grep -q "install.*gh" "${apt_log}"; then
    managed_check_called=1
  fi

  if [ "${managed_check_called}" -eq 1 ]; then
    log_pass "${suite}: apt-packages verifies managed binary rather than shadowing command on PATH"
  else
    log_fail "${suite}: apt-packages used shadowing command on PATH instead of managed binary"
  fi

  # 6.8 github-cli.sh: signed-by に .old が付いている場合や公式 URI がコメントのみにある場合は再設定すること
  log_test "${suite}: github-cli reconfigures when signed-by has .old suffix or URI is in comment"
  echo "deb [signed-by=${gh_key}.old] https://cli.github.com/packages stable main" > "${gh_repo}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local has_fixed_key=0
  if grep -qF "signed-by=${gh_key}]" "${gh_repo}" 2>/dev/null; then
    has_fixed_key=1
  fi

  echo "deb [signed-by=${gh_key}] https://other.com/packages stable main # https://cli.github.com/packages" > "${gh_repo}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local has_fixed_comment_uri=0
  if grep -Eq '^[[:space:]]*deb[[:space:]]+\[[^]]*\][[:space:]]+https://cli\.github\.com/packages[[:space:]]+stable' "${gh_repo}" 2>/dev/null; then
    has_fixed_comment_uri=1
  fi

  if [ "${has_fixed_key}" -eq 1 ] && [ "${has_fixed_comment_uri}" -eq 1 ]; then
    log_pass "${suite}: github-cli reconfigures when signed-by has .old suffix or URI is in comment"
  else
    log_fail "${suite}: github-cli failed to reconfigure on .old key or comment URI (key=${has_fixed_key}, uri=${has_fixed_comment_uri})"
  fi

  # 6.9 apt-packages.sh: 管理対象バイナリ欠落時、PATH 上の別 gh にフォールバックせず修復対象とすること
  log_test "${suite}: apt-packages does not fall back to PATH command when managed gh is missing"
  local missing_gh="${test_dir}/missing_bin/gh"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    # PATH には動く gh がある環境
    export PATH="${shadow_bin}:${PATH}"
    # 管理対象バイナリは存在しないパスを指定（ホスト環境に /usr/bin/gh があっても隔離される）
    export GH_BIN="${missing_gh}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="GitHub <support@github.com>"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) || true

  local fallback_prevented=0
  # 管理対象バイナリが存在しないため、PATH の gh に騙されず apt-get install gh が呼ばれること
  if grep -q "install.*gh" "${apt_log}"; then
    fallback_prevented=1
  fi

  if [ "${fallback_prevented}" -eq 1 ]; then
    log_pass "${suite}: apt-packages does not fall back to PATH command when managed gh is missing"
  else
    log_fail "${suite}: apt-packages fell back to rogue PATH command instead of managing gh"
  fi

  # 6.10 github-cli.sh: suite や component が欠落・不正な場合はスキップせず再設定すること
  log_test "${suite}: github-cli reconfigures when suite or component is invalid"
  echo "deb [signed-by=${gh_key}] https://cli.github.com/packages test unstable" > "${gh_repo}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local has_fixed_suite_comp=0
  if grep -Eq '^[[:space:]]*deb[[:space:]]+\[[^]]*\][[:space:]]+https://cli\.github\.com/packages[[:space:]]+stable[[:space:]]+.*main' "${gh_repo}" 2>/dev/null; then
    has_fixed_suite_comp=1
  fi

  if [ "${has_fixed_suite_comp}" -eq 1 ]; then
    log_pass "${suite}: github-cli reconfigures when suite or component is invalid"
  else
    log_fail "${suite}: github-cli failed to reconfigure on invalid suite or component"
  fi

  # 6.11 apt-packages.sh: repo_list がコメントのみ、または suite/component/key 不正時は install gh を呼ぶこと
  log_test "${suite}: apt-packages detects invalid or commented-out repo list and triggers install"
  echo "# deb [signed-by=${gh_key}] https://cli.github.com/packages stable main" > "${gh_repo}"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="GitHub <support@github.com>"
    export STUB_GH_MODE="default"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) || true

  local invalid_repo_detected=0
  if grep -q "install.*gh" "${apt_log}"; then
    invalid_repo_detected=1
  fi

  if [ "${invalid_repo_detected}" -eq 1 ]; then
    log_pass "${suite}: apt-packages detects invalid or commented-out repo list and triggers install"
  else
    log_fail "${suite}: apt-packages accepted commented-out or invalid repo list as valid"
  fi

  # 6.12 github-cli.sh: arch が native_arch を除外している場合はスキップせず再設定すること
  log_test "${suite}: github-cli reconfigures when arch option excludes native architecture"
  echo "deb [arch=arm64 signed-by=${gh_key}] https://cli.github.com/packages stable main" > "${gh_repo}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local has_fixed_arch=0
  if grep -Eq '^[[:space:]]*deb[[:space:]]+\[[^]]*arch=amd64[^]]*\][[:space:]]+https://cli\.github\.com/packages' "${gh_repo}" 2>/dev/null; then
    has_fixed_arch=1
  fi

  if [ "${has_fixed_arch}" -eq 1 ]; then
    log_pass "${suite}: github-cli reconfigures when arch option excludes native architecture"
  else
    log_fail "${suite}: github-cli failed to reconfigure when arch option excluded native architecture"
  fi

  # 6.13 apt-packages.sh: repo_list の arch が native_arch を除外している場合は install gh を呼ぶこと
  log_test "${suite}: apt-packages detects repo list excluding native arch and triggers install"
  echo "deb [arch=arm64 signed-by=${gh_key}] https://cli.github.com/packages stable main" > "${gh_repo}"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="GitHub <support@github.com>"
    export STUB_GH_MODE="default"
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) || true

  local arch_mismatch_detected=0
  if grep -q "install.*gh" "${apt_log}"; then
    arch_mismatch_detected=1
  fi

  if [ "${arch_mismatch_detected}" -eq 1 ]; then
    log_pass "${suite}: apt-packages detects repo list excluding native arch and triggers install"
  else
    log_fail "${suite}: apt-packages accepted repo list excluding native arch"
  fi

  # 6.14 github-cli.sh: 記述順に依存しない arch, arch+=, arch-= セマンティクス
  log_test "${suite}: github-cli respects order-independent arch operators"
  echo "deb [arch-=amd64 arch=amd64 signed-by=${gh_key}] https://cli.github.com/packages stable main" > "${gh_repo}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )

  local has_fixed_remove_native=0
  if grep -Eq '^[[:space:]]*deb[[:space:]]+\[[^]]*arch=amd64[^]]*\][[:space:]]+https://cli\.github\.com/packages' "${gh_repo}" 2>/dev/null && ! grep -q "arch-=amd64" "${gh_repo}" 2>/dev/null; then
    has_fixed_remove_native=1
  fi

  # arch+=amd64 arch=arm64 (add takes precedence over replace -> native kept -> accepted)
  echo "deb [arch+=amd64 arch=arm64 signed-by=${gh_key}] https://cli.github.com/packages stable main" > "${gh_repo}"
  (
    export "${test_env[@]}"
    export TMPDIR="${gh_tmp}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    bash "${REPO_ROOT}/provision/github-cli.sh" >/dev/null 2>&1
  )
  local add_native_accepted=0
  if grep -q "arch+=amd64" "${gh_repo}" 2>/dev/null; then
    add_native_accepted=1
  fi

  if [ "${has_fixed_remove_native}" -eq 1 ] && [ "${add_native_accepted}" -eq 1 ]; then
    log_pass "${suite}: github-cli respects order-independent arch operators"
  else
    log_fail "${suite}: github-cli failed order-independent arch operators check"
  fi

  # 6.15 apt-packages.sh: dpkg --print-architecture 取得失敗（空値）時は受理せず install gh を呼ぶこと
  log_test "${suite}: apt-packages detects missing native arch query and triggers install"
  echo "deb [signed-by=${gh_key}] https://cli.github.com/packages stable main" > "${gh_repo}"
  : > "${apt_log}"
  rm -f "${installed_flag}"
  (
    export "${test_env[@]}"
    export GITHUB_CLI_KEYRING="${gh_key}"
    export GITHUB_CLI_REPO_LIST="${gh_repo}"
    export STUB_GH_MAINTAINER="GitHub <support@github.com>"
    export STUB_GH_MODE="default"
    export STUB_DPKG_ARCH=""
    bash "${REPO_ROOT}/provision/apt-packages.sh" >/dev/null 2>&1
  ) || true

  local query_fail_detected=0
  if grep -q "install.*gh" "${apt_log}"; then
    query_fail_detected=1
  fi

  if [ "${query_fail_detected}" -eq 1 ]; then
    log_pass "${suite}: apt-packages detects missing native arch query and triggers install"
  else
    log_fail "${suite}: apt-packages accepted repo when dpkg architecture query was empty"
  fi
}

# -----------------------------------------------------------------------------
# Test Suite 7: coding-sandbox.yaml probes verification
# -----------------------------------------------------------------------------
test_probes() {
  local suite="coding-sandbox.yaml probes"
  local test_dir="${MASTER_TEST_DIR}/probes"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  local fake_home="${test_dir}/home"
  mkdir -p "${fake_bin}" "${fake_home}/.local/bin" "${fake_home}/.ssh"

  # 基本コマンドのスタブを作成（git, timeout は本物を実行するため含めない）
  local basic_cmds=(curl wget jq less ssh gcc make rg fd fdfind unzip zip tree shellcheck nft pip3 pipx node npm)
  for cmd in "${basic_cmds[@]}"; do
    cat > "${fake_bin}/${cmd}" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${fake_bin}/${cmd}"
  done

  # スタブ dpkg
  cat > "${fake_bin}/dpkg" << 'EOF'
#!/bin/bash
set -eu
case "$*" in
  *--print-architecture*)
    echo "${STUB_PROBE_DPKG_ARCH-amd64}"
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF
  chmod +x "${fake_bin}/dpkg"

  # スタブ dpkg-query
  cat > "${fake_bin}/dpkg-query" << 'EOF'
#!/bin/bash
set -eu
case "$*" in
  *db:Status-Status*gh*)
    echo "${STUB_PROBE_GH_STATUS:-installed}"
    ;;
  *Maintainer*gh*)
    if [ "${STUB_PROBE_GH_QUERY_FAIL:-0}" = "1" ]; then
      exit 1
    fi
    echo "${STUB_PROBE_GH_MAINTAINER:-GitHub <support@github.com>}"
    ;;
  *)
    echo "installed"
    ;;
esac
EOF
  chmod +x "${fake_bin}/dpkg-query"

  # スタブ gh
  cat > "${fake_bin}/gh" << 'EOF'
#!/bin/bash
set -eu
if [ "${STUB_PROBE_GH_FAIL:-0}" = "1" ]; then
  exit 1
fi
echo "gh version 2.60.0"
exit 0
EOF
  chmod +x "${fake_bin}/gh"

  # スタブ CLI ツール群（herdr, agy, copilot, mise）
  local cli_tools=(herdr agy copilot mise)
  for tool in "${cli_tools[@]}"; do
    local tool_upper
    tool_upper=$(echo "${tool}" | tr '[:lower:]' '[:upper:]')
    cat > "${fake_home}/.local/bin/${tool}" << EOF
#!/bin/bash
set -eu
if [ "\${STUB_PROBE_${tool_upper}_FAIL:-0}" = "1" ]; then
  exit 1
fi
if [ "\${STUB_PROBE_${tool_upper}_HANG:-0}" = "1" ]; then
  sleep 10
fi
echo "${tool} version 1.0.0"
exit 0
EOF
    chmod +x "${fake_home}/.local/bin/${tool}"
  done

  local test_key="${test_dir}/key.gpg"
  local test_repo="${test_dir}/repo.list"
  echo "key" > "${test_key}"
  echo "deb [signed-by=${test_key}] https://cli.github.com/packages stable main" > "${test_repo}"

  # 7.1 probe basic tools: 公式 gh で成功、Ubuntu 版 gh で理由表示して失敗
  log_test "${suite}: probe basic tools verifies official gh and reports failure cause"
  local p1_script
  p1_script=$(limactl template yq "${REPO_ROOT}/coding-sandbox.yaml" '.probes[] | select(.description | test("basic tools")) | .script')

  local p1_success=0
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${test_repo}"
    export STUB_PROBE_GH_MAINTAINER="GitHub <support@github.com>"
    export PROBE_TIMEOUT=1
    export PROBE_SLEEP=0
    bash -c "${p1_script}" >/dev/null 2>&1
  ) && p1_success=1

  local p1_ubuntu_failed=0
  local p1_ubuntu_stderr="${test_dir}/p1_ubuntu.stderr"
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${test_repo}"
    export STUB_PROBE_GH_MAINTAINER="Ubuntu Developers <ubuntu-devel-discuss@lists.ubuntu.com>"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p1_script}" 2>"${p1_ubuntu_stderr}"
  ) || p1_ubuntu_failed=1

  local has_ubuntu_cause=0
  if grep -q "from Ubuntu universe" "${p1_ubuntu_stderr}" 2>/dev/null; then
    has_ubuntu_cause=1
  fi

  if [ "${p1_success}" -eq 1 ] && [ "${p1_ubuntu_failed}" -eq 1 ] && [ "${has_ubuntu_cause}" -eq 1 ]; then
    log_pass "${suite}: probe[1] verifies official gh and reports failure cause"
  else
    log_fail "${suite}: probe[1] gh verification failed"
  fi

  # 7.2 probe CLI tools: 全ツール正常で成功、起動失敗時に理由を表示して失敗
  log_test "${suite}: probe CLI tools verifies via --version and reports cause"
  local p3_script
  p3_script=$(limactl template yq "${REPO_ROOT}/coding-sandbox.yaml" '.probes[] | select(.description | test("herdr, Antigravity")) | .script')

  local p3_success=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_home}"
    export PROBE_TIMEOUT=1
    export PROBE_SLEEP=0
    bash -c "${p3_script}" >/dev/null 2>&1
  ) && p3_success=1

  local p3_fail=0
  local p3_fail_stderr="${test_dir}/p3_fail.stderr"
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_home}"
    export STUB_PROBE_AGY_FAIL=1
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p3_script}" 2>"${p3_fail_stderr}"
  ) || p3_fail=1

  local has_agy_cause=0
  if grep -q "agy ('agy --version' exited with code 1)" "${p3_fail_stderr}" 2>/dev/null; then
    has_agy_cause=1
  fi

  if [ "${p3_success}" -eq 1 ] && [ "${p3_fail}" -eq 1 ] && [ "${has_agy_cause}" -eq 1 ]; then
    log_pass "${suite}: probe[3] verifies CLI tools via --version and reports cause"
  else
    log_fail "${suite}: probe[3] CLI tools verification failed"
  fi

  # 7.3 probe Git commit signing: 正常鍵で成功、鍵不整合で失敗
  log_test "${suite}: probe Git commit signing verifies key pair and reports cause"
  local p7_script
  p7_script=$(limactl template yq "${REPO_ROOT}/coding-sandbox.yaml" '.probes[] | select(.description | test("signing")) | .script')

  local git_home="${test_dir}/probe_git_home"
  mkdir -p "${git_home}/.ssh"
  ssh-keygen -t ed25519 -N '' -f "${git_home}/.ssh/id_ed25519_signing" -C "probe-key" >/dev/null 2>&1
  HOME="${git_home}" XDG_CONFIG_HOME="${git_home}/.config" GIT_CONFIG_GLOBAL="${git_home}/.gitconfig" git config --global gpg.format ssh
  HOME="${git_home}" XDG_CONFIG_HOME="${git_home}/.config" GIT_CONFIG_GLOBAL="${git_home}/.gitconfig" git config --global user.signingkey "${git_home}/.ssh/id_ed25519_signing"
  HOME="${git_home}" XDG_CONFIG_HOME="${git_home}/.config" GIT_CONFIG_GLOBAL="${git_home}/.gitconfig" git config --global commit.gpgsign true

  # 正常鍵（かつ core.hooksPath が存在しても影響を受けないこと）
  local hook_dir="${git_home}/hooks"
  mkdir -p "${hook_dir}"
  cat > "${hook_dir}/pre-commit" << 'EOF'
#!/bin/sh
echo "probe pre-commit rejected" >&2
exit 1
EOF
  chmod +x "${hook_dir}/pre-commit"
  HOME="${git_home}" XDG_CONFIG_HOME="${git_home}/.config" GIT_CONFIG_GLOBAL="${git_home}/.gitconfig" git config --global core.hooksPath "${hook_dir}"

  local p7_success=0
  (
    export HOME="${git_home}"
    export XDG_CONFIG_HOME="${git_home}/.config"
    export GIT_CONFIG_GLOBAL="${git_home}/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_SYSTEM=/dev/null
    export PROBE_TIMEOUT=1
    export PROBE_SLEEP=0
    bash -c "${p7_script}" >/dev/null 2>&1
  ) && p7_success=1

  # 不整合鍵で失敗し、stderr に理由が出力されること
  echo "invalid-public-key" > "${git_home}/.ssh/id_ed25519_signing.pub"
  local p7_mismatch_failed=0
  local p7_mismatch_stderr="${test_dir}/p7_mismatch.stderr"
  (
    export HOME="${git_home}"
    export XDG_CONFIG_HOME="${git_home}/.config"
    export GIT_CONFIG_GLOBAL="${git_home}/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_SYSTEM=/dev/null
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p7_script}" 2>"${p7_mismatch_stderr}"
  ) || p7_mismatch_failed=1

  local has_mismatch_cause=0
  if grep -q "does not match private key" "${p7_mismatch_stderr}" 2>/dev/null; then
    has_mismatch_cause=1
  fi

  # commit.gpgsign=no で署名無効化されている場合は通過すること
  local p7_gpgsign_no_success=0
  (
    export HOME="${git_home}"
    export XDG_CONFIG_HOME="${git_home}/.config"
    export GIT_CONFIG_GLOBAL="${git_home}/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_SYSTEM=/dev/null
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    git config --global commit.gpgsign no
    bash -c "${p7_script}" >/dev/null 2>&1
  ) && p7_gpgsign_no_success=1

  if [ "${p7_success}" -eq 1 ] && [ "${p7_mismatch_failed}" -eq 1 ] && \
     [ "${has_mismatch_cause}" -eq 1 ] && [ "${p7_gpgsign_no_success}" -eq 1 ]; then
    log_pass "${suite}: probe Git commit signing verifies key pair and reports cause"
  else
    log_fail "${suite}: probe Git commit signing verification failed (success=${p7_success}, mismatch_fail=${p7_mismatch_failed}, cause=${has_mismatch_cause}, no_success=${p7_gpgsign_no_success})"
  fi

  # 7.4 probe basic tools: dpkg-query メタデータ取得失敗または未インストールの場合に拒否し理由を出力すること
  log_test "${suite}: probe basic tools rejects gh on failed metadata query"
  local p1_dpkg_fail_stderr="${test_dir}/p1_dpkg_fail.stderr"
  local p1_dpkg_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${test_repo}"
    export STUB_PROBE_GH_QUERY_FAIL=1
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p1_script}" 2>"${p1_dpkg_fail_stderr}"
  ) || p1_dpkg_failed=1

  local has_query_fail_cause=0
  if grep -q "unable to query package maintainer metadata" "${p1_dpkg_fail_stderr}" 2>/dev/null; then
    has_query_fail_cause=1
  fi

  if [ "${p1_dpkg_failed}" -eq 1 ] && [ "${has_query_fail_cause}" -eq 1 ]; then
    log_pass "${suite}: probe basic tools rejects gh on failed metadata query"
  else
    log_fail "${suite}: probe[1] did not report failure when dpkg-query failed"
  fi

  # 7.5 probe Git commit signing: パスフレーズ付き鍵で .pub 不在時でもスキップ・通過すること
  log_test "${suite}: probe Git commit signing skips passphrase-protected key with missing .pub"
  local probe_pass_home="${test_dir}/probe_pass_home"
  mkdir -p "${probe_pass_home}/.ssh"
  ssh-keygen -t ed25519 -N 'secret' -f "${probe_pass_home}/.ssh/id_ed25519_signing" -C "probe-pass-key" >/dev/null 2>&1
  rm -f "${probe_pass_home}/.ssh/id_ed25519_signing.pub"
  HOME="${probe_pass_home}" XDG_CONFIG_HOME="${probe_pass_home}/.config" GIT_CONFIG_GLOBAL="${probe_pass_home}/.gitconfig" git config --global gpg.format ssh
  HOME="${probe_pass_home}" XDG_CONFIG_HOME="${probe_pass_home}/.config" GIT_CONFIG_GLOBAL="${probe_pass_home}/.gitconfig" git config --global user.signingkey "${probe_pass_home}/.ssh/id_ed25519_signing"
  HOME="${probe_pass_home}" XDG_CONFIG_HOME="${probe_pass_home}/.config" GIT_CONFIG_GLOBAL="${probe_pass_home}/.gitconfig" git config --global commit.gpgsign true

  local p7_pass_success=0
  (
    export HOME="${probe_pass_home}"
    export XDG_CONFIG_HOME="${probe_pass_home}/.config"
    export GIT_CONFIG_GLOBAL="${probe_pass_home}/.gitconfig"
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_SYSTEM=/dev/null
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p7_script}" >/dev/null 2>&1
  ) && p7_pass_success=1

  if [ "${p7_pass_success}" -eq 1 ]; then
    log_pass "${suite}: probe Git commit signing skips passphrase-protected key with missing .pub"
  else
    log_fail "${suite}: probe Git commit signing failed on passphrase-protected key without .pub"
  fi

  # 7.6 probe basic tools: 管理対象バイナリ欠落時、PATH 上の別 gh にフォールバックせず失敗すること
  log_test "${suite}: probe basic tools does not fall back to PATH command when managed gh is missing"
  local missing_gh="${test_dir}/missing_bin/gh"
  local p1_nofallback_stderr="${test_dir}/p1_nofallback.stderr"
  local p1_nofallback_failed=0
  (
    # PATH にはスタブ gh がある環境
    export PATH="${fake_bin}:${PATH}"
    # 管理対象バイナリは存在しないパスを指定（ホスト環境に /usr/bin/gh があっても隔離される）
    export GH_BIN="${missing_gh}"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${test_repo}"
    export STUB_PROBE_GH_MAINTAINER="GitHub <support@github.com>"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p1_script}" 2>"${p1_nofallback_stderr}"
  ) || p1_nofallback_failed=1

  local has_nofallback_cause=0
  if grep -q "gh (${missing_gh} not found or not executable)" "${p1_nofallback_stderr}" 2>/dev/null; then
    has_nofallback_cause=1
  fi

  if [ "${p1_nofallback_failed}" -eq 1 ] && [ "${has_nofallback_cause}" -eq 1 ]; then
    log_pass "${suite}: probe basic tools does not fall back to PATH command when managed gh is missing"
  else
    log_fail "${suite}: probe[1] fell back to PATH command or did not report missing gh"
  fi

  # 7.7 probe Git commit signing: commit.gpgsign に不正なブール値（例: treu）がある場合は失敗理由を報告すること
  log_test "${suite}: probe Git commit signing rejects invalid boolean value for commit.gpgsign"
  local p7_invalid_gitconfig="${fake_home}/.gitconfig_invalid"
  git config -f "${p7_invalid_gitconfig}" commit.gpgsign "treu"
  local p7_invalid_stderr="${test_dir}/p7_invalid.stderr"
  local p7_invalid_failed=0
  (
    export HOME="${fake_home}"
    export GIT_CONFIG_GLOBAL="${p7_invalid_gitconfig}"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p7_script}" 2>"${p7_invalid_stderr}"
  ) || p7_invalid_failed=1

  local p7_invalid_cause=0
  if grep -q "invalid boolean config value for commit.gpgsign: 'treu'" "${p7_invalid_stderr}" 2>/dev/null; then
    p7_invalid_cause=1
  fi

  if [ "${p7_invalid_failed}" -eq 1 ] && [ "${p7_invalid_cause}" -eq 1 ]; then
    log_pass "${suite}: probe Git commit signing rejects invalid boolean value for commit.gpgsign"
  else
    log_fail "${suite}: probe Git commit signing failed to reject invalid boolean value for commit.gpgsign"
  fi

  # 7.8 probe basic tools: repo_list がコメントのみまたは不正な場合、リポジトリ不正を報告して失敗すること
  log_test "${suite}: probe basic tools rejects invalid or commented-out repo list"
  local p1_badrepo_stderr="${test_dir}/p1_badrepo.stderr"
  local p1_badrepo_list="${test_dir}/badrepo.list"
  echo "# deb [signed-by=${test_key}] https://cli.github.com/packages stable main" > "${p1_badrepo_list}"
  local p1_badrepo_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${p1_badrepo_list}"
    export STUB_PROBE_GH_MAINTAINER="GitHub <support@github.com>"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p1_script}" 2>"${p1_badrepo_stderr}"
  ) || p1_badrepo_failed=1

  local p1_badrepo_cause=0
  if grep -q "gh (official apt repository not configured or invalid)" "${p1_badrepo_stderr}" 2>/dev/null; then
    p1_badrepo_cause=1
  fi

  if [ "${p1_badrepo_failed}" -eq 1 ] && [ "${p1_badrepo_cause}" -eq 1 ]; then
    log_pass "${suite}: probe basic tools rejects invalid or commented-out repo list"
  else
    log_fail "${suite}: probe[1] accepted commented-out or invalid repo list as valid"
  fi

  # 7.9 probe Git commit signing: .gitconfig に構文エラーがある場合は失敗理由を報告すること
  log_test "${suite}: probe Git commit signing rejects syntax error in .gitconfig"
  local p7_syntax_gitconfig="${fake_home}/.gitconfig_syntax"
  echo "[broken section" > "${p7_syntax_gitconfig}"
  local p7_syntax_stderr="${test_dir}/p7_syntax.stderr"
  local p7_syntax_failed=0
  (
    export HOME="${fake_home}"
    export GIT_CONFIG_GLOBAL="${p7_syntax_gitconfig}"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p7_script}" 2>"${p7_syntax_stderr}"
  ) || p7_syntax_failed=1

  local p7_syntax_cause=0
  if grep -q "failed to query commit.gpgsign:" "${p7_syntax_stderr}" 2>/dev/null; then
    p7_syntax_cause=1
  fi

  if [ "${p7_syntax_failed}" -eq 1 ] && [ "${p7_syntax_cause}" -eq 1 ]; then
    log_pass "${suite}: probe Git commit signing rejects syntax error in .gitconfig"
  else
    log_fail "${suite}: probe Git commit signing failed to reject syntax error in .gitconfig"
  fi

  # 7.10 probe basic tools: gh repo の arch が native_arch を除外している場合に拒否すること
  log_test "${suite}: probe basic tools rejects gh repository excluding native architecture"
  local p1_arch_repo="${test_dir}/arch_mismatch_repo.list"
  echo "deb [arch=arm64 signed-by=${test_key}] https://cli.github.com/packages stable main" > "${p1_arch_repo}"
  local p1_arch_failed=0
  local p1_arch_stderr="${test_dir}/p1_arch.stderr"
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${p1_arch_repo}"
    export STUB_PROBE_GH_MAINTAINER="GitHub <support@github.com>"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p1_script}" 2>"${p1_arch_stderr}"
  ) || p1_arch_failed=1

  local p1_arch_cause=0
  if grep -q "gh (official apt repository not configured or invalid)" "${p1_arch_stderr}" 2>/dev/null; then
    p1_arch_cause=1
  fi

  if [ "${p1_arch_failed}" -eq 1 ] && [ "${p1_arch_cause}" -eq 1 ]; then
    log_pass "${suite}: probe basic tools rejects gh repository excluding native architecture"
  else
    log_fail "${suite}: probe basic tools accepted gh repository excluding native architecture"
  fi

  # 7.11 probe basic tools: 記述順に依存しない arch, arch+=, arch-= セマンティクス
  log_test "${suite}: probe basic tools respects order-independent arch operators"
  # arch-=amd64 arch=amd64 (rejected)
  local p1_sub_arch_repo="${test_dir}/sub_arch_repo.list"
  echo "deb [arch-=amd64 arch=amd64 signed-by=${test_key}] https://cli.github.com/packages stable main" > "${p1_sub_arch_repo}"
  local p1_sub_arch_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${p1_sub_arch_repo}"
    export STUB_PROBE_GH_MAINTAINER="GitHub <support@github.com>"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p1_script}" >/dev/null 2>&1
  ) || p1_sub_arch_failed=1

  # arch+=amd64 arch=arm64 (accepted)
  local p1_add_arch_repo="${test_dir}/add_arch_repo.list"
  echo "deb [arch+=amd64 arch=arm64 signed-by=${test_key}] https://cli.github.com/packages stable main" > "${p1_add_arch_repo}"
  local p1_add_arch_success=0
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${p1_add_arch_repo}"
    export STUB_PROBE_GH_MAINTAINER="GitHub <support@github.com>"
    export PROBE_TIMEOUT=1
    export PROBE_SLEEP=0
    bash -c "${p1_script}" >/dev/null 2>&1
  ) && p1_add_arch_success=1

  if [ "${p1_sub_arch_failed}" -eq 1 ] && [ "${p1_add_arch_success}" -eq 1 ]; then
    log_pass "${suite}: probe basic tools respects order-independent arch operators"
  else
    log_fail "${suite}: probe basic tools failed order-independent arch operators check (sub_failed=${p1_sub_arch_failed}, add_success=${p1_add_arch_success})"
  fi

  # 7.12 probe basic tools: dpkg --print-architecture 取得失敗（空値）時は拒否すること
  log_test "${suite}: probe basic tools rejects repository when dpkg query is empty"
  local p1_empty_arch_repo="${test_dir}/empty_arch_repo.list"
  echo "deb [signed-by=${test_key}] https://cli.github.com/packages stable main" > "${p1_empty_arch_repo}"
  local p1_empty_arch_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export GH_BIN="${fake_bin}/gh"
    export GITHUB_CLI_KEYRING="${test_key}"
    export GITHUB_CLI_REPO_LIST="${p1_empty_arch_repo}"
    export STUB_PROBE_GH_MAINTAINER="GitHub <support@github.com>"
    export STUB_PROBE_DPKG_ARCH=""
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p1_script}" >/dev/null 2>&1
  ) || p1_empty_arch_failed=1

  if [ "${p1_empty_arch_failed}" -eq 1 ]; then
    log_pass "${suite}: probe basic tools rejects repository when dpkg query is empty"
  else
    log_fail "${suite}: probe basic tools accepted repository when dpkg query was empty"
  fi

  # 7.13 probe CLI tools: 不正な PARAM_copilotVersion / PARAM_miseVersion の拒否
  log_test "${suite}: probe CLI tools rejects invalid version parameters"
  local p3_bad_copilot_stderr="${test_dir}/p3_bad_copilot.stderr"
  local p3_bad_copilot_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_home}"
    export PARAM_copilotVersion="invalid version"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p3_script}" 2>"${p3_bad_copilot_stderr}"
  ) || p3_bad_copilot_failed=1

  local p3_bad_mise_stderr="${test_dir}/p3_bad_mise.stderr"
  local p3_bad_mise_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export HOME="${fake_home}"
    export PARAM_miseVersion="prerelease"
    export PROBE_TIMEOUT=0
    export PROBE_SLEEP=0
    bash -c "${p3_script}" 2>"${p3_bad_mise_stderr}"
  ) || p3_bad_mise_failed=1

  local has_bad_copilot_msg=0 has_bad_mise_msg=0
  if grep -q "invalid param copilotVersion:" "${p3_bad_copilot_stderr}" 2>/dev/null; then
    has_bad_copilot_msg=1
  fi
  if grep -q "invalid param miseVersion:" "${p3_bad_mise_stderr}" 2>/dev/null; then
    has_bad_mise_msg=1
  fi

  if [ "${p3_bad_copilot_failed}" -eq 1 ] && [ "${p3_bad_mise_failed}" -eq 1 ] && \
     [ "${has_bad_copilot_msg}" -eq 1 ] && [ "${has_bad_mise_msg}" -eq 1 ]; then
    log_pass "${suite}: probe CLI tools rejects invalid version parameters"
  else
    log_fail "${suite}: probe CLI tools failed to reject invalid version parameters"
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
test_gh_and_apt_packages
test_probes

echo "--------------------------------------------------"
printf 'Test results: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
