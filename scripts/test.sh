#!/bin/bash
# プロビジョニングスクリプトと Makefile の回帰テスト
#
# 外部通信や root 権限に依存せず、一時ディレクトリとスタブコマンドを用いて
# 冪等性、設定保持、途中失敗からの回復、Makefile の入力正規化などを検証する。
#
#   $ make test または bash ./scripts/test.sh [--list|-l] [suite ...]
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

create_noop_stubs() {
  local bin_dir="${1:?}"
  shift
  local cmd
  for cmd in "$@"; do
    cat > "${bin_dir}/${cmd}" << 'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "${bin_dir}/${cmd}"
  done
}

create_stub_dpkg() {
  local bin_dir="${1:?}"
  cat > "${bin_dir}/dpkg" << 'EOF'
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
  chmod +x "${bin_dir}/dpkg"
}

create_stub_curl() {
  local bin_dir="${1:?}"
  cat > "${bin_dir}/curl" << 'EOF'
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
    if [ "${count}" -eq 1 ]; then
      if [ -n "${write_out}" ]; then printf '503'; fi
      exit 22
    elif [ "${count}" -eq 2 ]; then
      exit 7
    fi
    ;;
  http200_fail_then_success)
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
      if [ -n "${STUB_MARKER_PARTIAL:-}" ]; then
        echo "touch \"${STUB_MARKER_PARTIAL}\"" > "${dest}"
      else
        echo "corrupted-partial-key-data" > "${dest}"
      fi
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
    *herdr.dev/install.sh*)
      cat << 'INS' > "${dest}"
#!/bin/sh
if [ "${STUB_HERDR_INSTALL_FAIL:-0}" = "1" ]; then
  exit 1
fi
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
      printf 'valid-content\n' > "${dest}"
      ;;
  esac
fi

if [ -n "${write_out}" ]; then
  printf '200'
fi
exit 0
EOF
  chmod +x "${bin_dir}/curl"
}

setup_makefile_test_env() {
  local test_dir="${1:?}"
  rm -rf "${test_dir}"
  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}" "${test_dir}/host_home"
  touch "${test_dir}/empty.env" "${test_dir}/limactl.log"

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
    --version|template|list|create|start|stop|delete|shell)
      cmd="$arg"
      break
      ;;
  esac
done

case "$cmd" in
  --version)
    echo "limactl version ${STUB_LIMA_VERSION_OUTPUT:-2.2.0}"
    exit 0
    ;;
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
}

# -----------------------------------------------------------------------------
# スイート別テスト定義の読み込み
# -----------------------------------------------------------------------------
# shellcheck source=scripts/tests/git-config.sh
source "${REPO_ROOT}/scripts/tests/git-config.sh"
# shellcheck source=scripts/tests/agent-instructions.sh
source "${REPO_ROOT}/scripts/tests/agent-instructions.sh"
# shellcheck source=scripts/tests/cli-provisioning.sh
source "${REPO_ROOT}/scripts/tests/cli-provisioning.sh"
# shellcheck source=scripts/tests/makefile-create-and-start.sh
source "${REPO_ROOT}/scripts/tests/makefile-create-and-start.sh"
# shellcheck source=scripts/tests/lib-functions.sh
source "${REPO_ROOT}/scripts/tests/lib-functions.sh"
# shellcheck source=scripts/tests/host-helper-scripts.sh
source "${REPO_ROOT}/scripts/tests/host-helper-scripts.sh"
# shellcheck source=scripts/tests/auth-and-signing-key.sh
source "${REPO_ROOT}/scripts/tests/auth-and-signing-key.sh"
# shellcheck source=scripts/tests/apt-key-provisioning.sh
source "${REPO_ROOT}/scripts/tests/apt-key-provisioning.sh"
# shellcheck source=scripts/tests/gh-and-apt-packages.sh
source "${REPO_ROOT}/scripts/tests/gh-and-apt-packages.sh"
# shellcheck source=scripts/tests/probes.sh
source "${REPO_ROOT}/scripts/tests/probes.sh"
# shellcheck source=scripts/tests/lint-checks.sh
source "${REPO_ROOT}/scripts/tests/lint-checks.sh"

MAKEFILE_LOGIC_SUITES=(
  makefile_create_and_start
  lib_functions
  host_helper_scripts
  auth_and_signing_key
)

test_makefile_logic() {
  local s
  for s in "${MAKEFILE_LOGIC_SUITES[@]}"; do
    run_suite "${s}"
  done
}

# -----------------------------------------------------------------------------
# Main Runner
# -----------------------------------------------------------------------------
ALL_SUITES=(
  git_config
  agent_instructions
  cli_provisioning
  makefile_logic
  apt_key_provisioning
  gh_and_apt_packages
  probes
  lint_checks
)

SELECTABLE_SUITES=(
  git_config
  agent_instructions
  cli_provisioning
  makefile_logic
  makefile_create_and_start
  lib_functions
  host_helper_scripts
  auth_and_signing_key
  apt_key_provisioning
  gh_and_apt_packages
  probes
  lint_checks
)

normalize_suite_arg() {
  local target="$1"
  target="${target#scripts/tests/}"
  target="${target%.sh}"
  target="${target#test_}"
  target="${target//-/_}"
  printf '%s' "${target}"
}

is_valid_suite() {
  local target
  target=$(normalize_suite_arg "$1")
  local s
  for s in "${SELECTABLE_SUITES[@]}"; do
    if [ "${s}" = "${target}" ]; then
      return 0
    fi
  done
  return 1
}

selected_suites=()
append_suite_once() {
  local target="$1"
  local s
  if [ "${target}" = "makefile_logic" ]; then
    for s in "${MAKEFILE_LOGIC_SUITES[@]}"; do
      append_suite_once "${s}"
    done
    return 0
  fi
  local existing
  for existing in "${selected_suites[@]+"${selected_suites[@]}"}"; do
    if [ "${existing}" = "${target}" ]; then
      return 0
    fi
  done
  selected_suites+=("${target}")
}

if [ "$#" -eq 0 ]; then
  for s in "${ALL_SUITES[@]}"; do
    append_suite_once "${s}"
  done
else
  for arg in "$@"; do
    case "${arg}" in
      --list|-l)
        printf '%s\n' "${SELECTABLE_SUITES[@]}"
        exit 0
        ;;
      --help|-h)
        printf 'Usage: %s [--list|-l] [suite ...]\n' "$0"
        exit 0
        ;;
      *)
        if ! is_valid_suite "${arg}"; then
          echo "ERROR: Unknown test suite '${arg}'. Run '$0 --list' to see available suites." >&2
          exit 1
        fi
        append_suite_once "$(normalize_suite_arg "${arg}")"
        ;;
    esac
  done
fi

run_suite() {
  case "$1" in
    git_config) test_git_config ;;
    agent_instructions) test_agent_instructions ;;
    cli_provisioning) test_cli_provisioning ;;
    makefile_logic) test_makefile_logic ;;
    makefile_create_and_start) test_makefile_create_and_start ;;
    lib_functions) test_lib_functions ;;
    host_helper_scripts) test_host_helper_scripts ;;
    auth_and_signing_key) test_auth_and_signing_key ;;
    apt_key_provisioning) test_apt_key_provisioning ;;
    gh_and_apt_packages) test_gh_and_apt_packages ;;
    probes) test_probes ;;
    lint_checks) test_lint_checks ;;
    *)
      echo "ERROR: Unknown test suite '$1'." >&2
      return 1
      ;;
  esac
}

echo "Running test suites for lima-coding-sandbox..."
for s in "${selected_suites[@]}"; do
  run_suite "${s}"
done

echo "--------------------------------------------------"
printf 'Test results: %d passed, %d failed\n' "${PASS_COUNT}" "${FAIL_COUNT}"
if [ "${FAIL_COUNT}" -gt 0 ]; then
  exit 1
fi
exit 0
