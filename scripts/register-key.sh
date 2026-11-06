#!/bin/bash
# VM 内の Git コミット署名用の公開鍵を、ホストの gh で GitHub に Signing Key として登録する
#
# --check が指定されたときは、VM 起動前にホストに gh があるかの事前検証のみを行う。
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?

if ! command -v gh >/dev/null 2>&1; then
  echo >&2 "エラー: ホストに gh（GitHub CLI）がインストールされていません（brew install gh）"
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  exit 0
fi

st=$(get_status "${NAME}") || exit $?
if [ "${st}" != Running ]; then
  echo >&2 "エラー: インスタンス ${NAME} は動いていません（先に make start で起動してください）"
  exit 1
fi

pubkey=$(limactl shell "${NAME}" cat .ssh/id_ed25519_signing.pub </dev/null) || {
  echo >&2 "エラー: VM から公開鍵（~/.ssh/id_ed25519_signing.pub）を取得できませんでした"
  exit 1
}
pubkey=$(printf '%s' "${pubkey}" | LC_ALL=C tr -d '\r')
if [ -z "${pubkey}" ]; then
  echo >&2 "エラー: VM の公開鍵（~/.ssh/id_ed25519_signing.pub）が空です"
  exit 1
fi
if [ "$(printf '%s\n' "${pubkey}" | wc -l | tr -d ' ')" -ne 1 ]; then
  echo >&2 "エラー: VM の公開鍵（~/.ssh/id_ed25519_signing.pub）が単一行ではありません"
  exit 1
fi
if ! raw_fp=$(printf '%s\n' "${pubkey}" | ssh-keygen -lf - 2>/dev/null); then
  echo >&2 "エラー: VM の公開鍵（~/.ssh/id_ed25519_signing.pub）の形式が不正です"
  exit 1
fi
key_fp=$(printf '%s\n' "${raw_fp}" | LC_ALL=C awk 'NR==1 {print $2}' 2>/dev/null || true)
if [[ ! "${key_fp}" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]]; then
  echo >&2 "エラー: VM の公開鍵（~/.ssh/id_ed25519_signing.pub）の指紋を取得できませんでした"
  exit 1
fi

# 鍵のコメント末尾に作成日（YYYY-MM-DD）があればタイトルに使い、無ければ今日の日付を使う
key_date=$(printf '%s\n' "${pubkey}" | awk '{print $NF}')
if [[ ! "${key_date}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  key_date=$(date +%Y-%m-%d)
fi
title="${NAME} ${key_date}"

gh_out=""
if ! gh_out=$(printf '%s\n' "${pubkey}" | gh ssh-key add --type signing --title "${title}" 2>&1); then
  if [ -n "${gh_out}" ]; then
    printf '%s\n' "${gh_out}" >&2
  fi
  echo >&2 "エラー: GitHub への Signing Key の登録に失敗しました。"
  echo >&2 "主な原因として、ホストの gh の未ログインやトークンの権限（スコープ）不足が考えられます:"
  echo >&2 "  - 未ログインの場合: gh auth login"
  echo >&2 "  - スコープ不足の場合: gh auth refresh -h github.com -s read:ssh_signing_key,write:ssh_signing_key"
  exit 1
fi

case "${gh_out}" in
  *"already exists"*)
    echo "インスタンス ${NAME} の署名鍵は既に GitHub に登録されています:"
    echo "  指紋:     ${key_fp}"
    ;;
  *)
    echo "インスタンス ${NAME} の署名鍵を GitHub に Signing Key として登録しました:"
    echo "  タイトル: ${title}"
    echo "  指紋:     ${key_fp}"
    ;;
esac
