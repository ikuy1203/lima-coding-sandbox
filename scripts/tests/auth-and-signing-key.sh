#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 4d: Auth backup/restore and GitHub signing key registration
# -----------------------------------------------------------------------------
test_auth_and_signing_key() {
  local suite="Makefile rules and safety checks"
  local test_dir="${MASTER_TEST_DIR}/auth_and_signing_key"
  setup_makefile_test_env "${test_dir}"
  local fake_bin="${test_dir}/bin"
  local lima_log="${test_dir}/limactl.log"
  local empty_env="${test_dir}/empty.env"
  local fake_host_home="${test_dir}/host_home"
  mkdir -p "${fake_host_home}"

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
