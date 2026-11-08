#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 7: coding-sandbox.yaml probes verification
# -----------------------------------------------------------------------------
test_probes() {
  local suite="coding-sandbox.yaml probes"
  local test_dir="${MASTER_TEST_DIR}/probes"
  rm -rf "${test_dir}"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  local fake_home="${test_dir}/home"
  mkdir -p "${fake_bin}" "${fake_home}/.local/bin" "${fake_home}/.ssh"

  # 基本コマンドのスタブを作成（git, timeout は本物を実行するため含めない）
  local basic_cmds=(curl wget jq less ssh gcc g++ make rg fd fdfind unzip zip tree shellcheck nft python3 pip3 pipx node npm npx)
  create_noop_stubs "${fake_bin}" "${basic_cmds[@]}"

  create_stub_dpkg "${fake_bin}"

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
    export STUB_DPKG_ARCH=""
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
