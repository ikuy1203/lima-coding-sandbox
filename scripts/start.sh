#!/bin/bash
# インスタンスのマウント設定を検証して起動する
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?
timeout_val=$(normalize "${TIMEOUT:-}")
mount_format='{{range .Config.Mounts}}- location: {{.Location}}{{"\n"}}{{end}}'

mounts=$(limactl list "${NAME}" --format "${mount_format}") || {
  echo >&2 "エラー: インスタンス ${NAME} の設定確認に失敗しました"
  exit 1
}
if [ -n "${mounts}" ]; then
  echo >&2 "エラー: ホストのディレクトリをマウントする設定があります（README.md の「ホストのマウントが混入しないように」を参照）:"
  printf '%s\n' "${mounts}" >&2
  st=$(get_status "${NAME}") || exit $?
  if [ "${st}" = Running ]; then
    echo >&2 "インスタンス ${NAME} を停止します..."
    limactl stop "${NAME}"
  fi
  exit 1
fi

start_args=(start)
if [ -n "${timeout_val}" ]; then
  start_args+=("--timeout=${timeout_val}")
fi
start_args+=("${NAME}")

if limactl "${start_args[@]}"; then
  :
else
  ret=$?
  if mounts=$(limactl list "${NAME}" --format "${mount_format}"); then
    if [ -n "${mounts}" ]; then
      echo >&2 "エラー: 起動後にホストのマウントが検出されました。インスタンス ${NAME} を停止します..."
      if ! limactl stop "${NAME}"; then
        echo >&2 "警告: インスタンス ${NAME} の自動停止に失敗しました。手動で limactl stop ${NAME} を実行してください"
      fi
      echo >&2 "検出されたマウント:"
      printf '%s\n' "${mounts}" >&2
    fi
  else
    echo >&2 "警告: 起動失敗後のマウント設定の再確認に失敗しました"
  fi
  exit "${ret}"
fi
