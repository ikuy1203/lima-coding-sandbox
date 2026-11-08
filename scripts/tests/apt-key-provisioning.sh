#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 5: provision/{github-cli,docker-engine}.sh apt keyring and sources
# -----------------------------------------------------------------------------
test_apt_key_provisioning() {
  local suite="provision/apt keyrings"
  local test_dir="${MASTER_TEST_DIR}/apt_key_provisioning"
  rm -rf "${test_dir}"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"

  create_stub_dpkg "${fake_bin}"
  create_noop_stubs "${fake_bin}" apt-get
  create_stub_curl "${fake_bin}"

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
