#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 6: GitHub CLI packaging source and apt-packages.sh verification
# -----------------------------------------------------------------------------
test_gh_and_apt_packages() {
  local suite="provision/github-cli.sh & apt-packages.sh gh verification"
  local test_dir="${MASTER_TEST_DIR}/gh_apt_packages"
  rm -rf "${test_dir}"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"

  local installed_flag="${test_dir}/gh_upgraded.flag"

  create_stub_dpkg "${fake_bin}"

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
  create_noop_stubs "${fake_bin}" ln

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

  create_stub_curl "${fake_bin}"

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
