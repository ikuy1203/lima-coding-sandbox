#!/bin/bash
# インスタンスを削除する（確認あり。YES=1 で確認を省略）
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?
yes_val=$(normalize "${YES:-}")

st=$(get_status "${NAME}") || exit $?
if [ -z "${st}" ]; then
  echo "インスタンス ${NAME} はありません"
  exit 0
fi

if [ "${yes_val}" != 1 ]; then
  printf 'インスタンス %s を削除します。VM 内のファイルと認証情報もすべて消えます。よろしいですか？ [y/N] ' "${NAME}"
  read -r answer
  case "${answer}" in
    [yY]*) ;;
    *)
      echo "中止しました"
      exit 1
      ;;
  esac
fi

if [ "${st}" = Running ]; then
  (
    set -x
    limactl stop "${NAME}"
  )
fi
set -x
limactl delete "${NAME}"
