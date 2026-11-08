#!/bin/bash
# make versions: ホストと起動中の VM 内の主要ソフトウェアのバージョンを一覧表示する
#
# トラブルシューティング時にも使えるよう、VM 内の個別ツールが欠落・失敗していても
# 他の項目の表示を継続し、取得できなかった項目には "(取得失敗)" を表示する。
#
# テスト用環境変数:
# - LIMA_SANDBOX_OS_RELEASE_FILE: OS 情報ファイルのパス（既定: /etc/os-release）
# - LIMA_SANDBOX_PYTHON3_BIN: システム python3 のパス（既定: /usr/bin/python3）
# - LIMA_SANDBOX_NODE_BIN: システム node のパス（既定: /usr/bin/node）
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?

require_running "${NAME}" || exit $?

if command -v sw_vers >/dev/null 2>&1; then
  host_os_label="macOS"
  macos_ver=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
  cpu_brand=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || uname -m)
  host_os="${macos_ver} (${cpu_brand})"
else
  host_os_label=$(uname -s 2>/dev/null || echo "Host OS")
  host_os="$(uname -r 2>/dev/null || echo "unknown") ($(uname -m 2>/dev/null || echo "unknown"))"
fi

lima_ver=$(limactl --version 2>/dev/null | sed -n '1p' | sed -E 's/^limactl version //') || lima_ver=""
[ -n "${lima_ver}" ] || lima_ver="(取得失敗)"

printf "%-20s %s\n" "${host_os_label}" "${host_os}"
printf "%-20s %s\n" "Lima" "${lima_ver}"

# shellcheck disable=SC2016
limactl shell "${NAME}" bash -c '
  set -u

  print_ver() {
    local label="$1"
    local val="$2"
    [ -n "${val}" ] || val="(取得失敗)"
    printf "%-20s %s\n" "${label}" "${val}"
  }

  os_release_file="${LIMA_SANDBOX_OS_RELEASE_FILE:-/etc/os-release}"
  ubuntu_ver=""
  if [ -r "${os_release_file}" ]; then
    # shellcheck disable=SC1090
    ubuntu_ver=$(. "${os_release_file}" 2>/dev/null && printf "%s\n" "${PRETTY_NAME:-${VERSION:-}}") || ubuntu_ver=""
    ubuntu_ver="${ubuntu_ver#Ubuntu }"
  fi
  print_ver "Ubuntu" "${ubuntu_ver}"

  kernel_ver=$(uname -r 2>/dev/null) || kernel_ver=""
  [ -n "${kernel_ver}" ] || kernel_ver="(取得失敗)"
  # bash 3.2 / bash 5.x の双方でバイト長基準のパディング幅（24 バイト = 表示幅 20 カラム）に揃える
  LC_ALL=C printf "%-24s %s\n" "カーネル" "${kernel_ver}"

  git_ver=$(git --version 2>/dev/null | sed -n "1p" | sed -E "s/^git version //") || git_ver=""
  print_ver "git" "${git_ver}"

  gh_ver=$(gh --version 2>/dev/null | awk "NR==1 {print \$3}") || gh_ver=""
  print_ver "GitHub CLI" "${gh_ver}"

  py_bin="${LIMA_SANDBOX_PYTHON3_BIN:-/usr/bin/python3}"
  [ -x "${py_bin}" ] || py_bin="python3"
  python_ver=$("${py_bin}" --version 2>/dev/null | awk "NR==1 {print \$2}") || python_ver=""
  print_ver "Python" "${python_ver}"

  node_bin="${LIMA_SANDBOX_NODE_BIN:-/usr/bin/node}"
  [ -x "${node_bin}" ] || node_bin="node"
  node_ver=$("${node_bin}" --version 2>/dev/null | sed -n "1p" | sed -E "s/^v//") || node_ver=""
  print_ver "Node.js" "${node_ver}"

  docker_ver=$(docker version --format "{{.Server.Version}}" 2>/dev/null | sed -n "1p") || docker_ver=""
  if [ -z "${docker_ver}" ]; then
    docker_client_ver=$(docker --version 2>/dev/null | sed -n "1p" | sed -E "s/^Docker version ([^,]+).*/\1/") || docker_client_ver=""
    if [ -n "${docker_client_ver}" ]; then
      docker_ver="${docker_client_ver} (クライアント)"
    fi
  fi
  print_ver "Docker Engine" "${docker_ver}"

  herdr_ver=$("${HOME}/.local/bin/herdr" --version 2>/dev/null | awk "NR==1 {print \$2}") || herdr_ver=""
  print_ver "herdr" "${herdr_ver}"

  mpg123_ver=$(mpg123 --version 2>/dev/null | awk "NR==1 {print \$2}") || mpg123_ver=""
  print_ver "mpg123" "${mpg123_ver}"

  agy_ver=$("${HOME}/.local/bin/agy" --version 2>/dev/null | sed -n "1p") || agy_ver=""
  print_ver "Antigravity CLI" "${agy_ver}"

  copilot_ver=$("${HOME}/.local/bin/copilot" --version 2>/dev/null | sed -n "1p" | sed -E "s/^GitHub Copilot CLI //; s/\.$//") || copilot_ver=""
  print_ver "GitHub Copilot CLI" "${copilot_ver}"

  mise_ver=$("${HOME}/.local/bin/mise" --version 2>/dev/null | awk "NR==1 {print \$1}") || mise_ver=""
  print_ver "mise" "${mise_ver}"
'
