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

key_fp=""
if [ "${st}" = Running ]; then
  raw_fp=$(limactl shell "${NAME}" ssh-keygen -lf .ssh/id_ed25519_signing.pub </dev/null 2>/dev/null || true)
  cand_fp=$(printf '%s\n' "${raw_fp}" | LC_ALL=C awk 'NR==1 {print $2}' 2>/dev/null || true)
  if [[ "${cand_fp}" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]]; then
    key_fp="${cand_fp}"
  fi
fi

if [ "${yes_val}" != 1 ]; then
  printf '%s\n' \
    "インスタンス ${NAME} を削除します。" \
    "- VM 内のファイル（未 push のコミット・未コミットの変更・Git 管理外の作業データ）はすべて消えます（clone し直すだけでは復元できません）" \
    "- 認証情報（gh・copilot）と Git 署名鍵を引き継ぐ場合は、削除前に make backup-auth を実行してください（README.md を参照）" \
    "- 署名鍵を引き継がない場合は、GitHub の Signing Key（make register-key で登録した場合のタイトル: ${NAME} <日付>）も削除してください（https://github.com/settings/keys または gh api -X DELETE /user/ssh_signing_keys/<ID>）"
  if [ -n "${key_fp}" ]; then
    printf '  署名鍵の指紋: %s\n' "${key_fp}"
  fi
  printf 'よろしいですか？ [y/N] '
  read -r answer
  case "${answer}" in
    [yY]*) ;;
    *)
      echo "中止しました"
      exit 1
      ;;
  esac
else
  if [ -n "${key_fp}" ]; then
    printf '署名鍵の指紋: %s\n' "${key_fp}"
  fi
  printf '%s\n' \
    "署名鍵を引き継がない場合は、GitHub の Signing Key（make register-key で登録した場合のタイトル: ${NAME} <日付>）も削除してください（https://github.com/settings/keys または gh api -X DELETE /user/ssh_signing_keys/<ID>）"
fi

if [ "${st}" = Running ]; then
  (
    set -x
    limactl stop "${NAME}"
  )
fi
set -x
limactl delete "${NAME}"
