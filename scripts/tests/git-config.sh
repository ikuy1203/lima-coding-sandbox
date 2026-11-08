#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 1: provision/git-config.sh
# -----------------------------------------------------------------------------
test_git_config() {
  local suite="provision/git-config.sh"
  local test_dir="${MASTER_TEST_DIR}/git_config"
  rm -rf "${test_dir}"
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
      cd "${repo_dir}" || exit 1
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
