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
  printf '%s\n' \
    "インスタンス ${NAME} を削除します。" \
    "- VM 内のファイル（未 push のコミット・未コミットの変更・Git 管理外の作業データ）はすべて消えます（clone し直すだけでは復元できません）" \
    "- 認証情報（gh・copilot）と Git 署名鍵を引き継ぐ場合は、削除前に make backup-auth を実行してください（README.md を参照）"
  printf 'よろしいですか？ [y/N] '
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
