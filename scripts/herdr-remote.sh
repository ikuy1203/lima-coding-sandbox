#!/bin/bash
# ホストの herdr から VM のセッションにリモート接続する
#
# Lima はインスタンスごとに ~/.lima/<名前>/ssh.config（Host lima-<名前>、HostName 127.0.0.1）を作る。
# ~/.ssh/config がそれを Include していないと、ssh -G は HostName としてホスト名をそのまま返す。
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?

if ! command -v herdr >/dev/null 2>&1; then
  echo >&2 "エラー: ホストに herdr がインストールされていません（brew install herdr。ほかの方法は https://herdr.dev/docs/install/ を参照）"
  exit 1
fi

host="lima-${NAME}"
out=$(ssh -G "${host}") || exit $?
if [ "$(printf '%s\n' "${out}" | awk '$1 == "hostname" { print $2 }')" = "${host}" ]; then
  echo >&2 "エラー: ssh で ${host} に接続する設定がありません。ホストの ~/.ssh/config の先頭に次の 1 行を追加してください:"
  echo >&2 "  Include ~/.lima/*/ssh.config"
  exit 1
fi

herdr --remote "${host}"
