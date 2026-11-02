#!/bin/bash
# ホストの terminfo を検証し、VM の ~/.terminfo にコピーする
#
# --check が指定されたときは、ホストに TERM_NAME の terminfo があるかの事前検証のみを行う。
# ホストの infocmp の出力を VM の tic に渡す。tic は root 以外で実行すると ~/.terminfo に書き込む。
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?
TERM_NAME=$(normalize "${TERM_NAME-${TERM:-}}")

if [ -z "${TERM_NAME}" ]; then
  echo >&2 "エラー: TERM_NAME が空です（例: make terminfo TERM_NAME=xterm-ghostty）"
  exit 1
fi

if ! src=$(infocmp -x "${TERM_NAME}" 2>/dev/null); then
  echo >&2 "エラー: ホストに ${TERM_NAME} の terminfo がありません"
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  exit 0
fi

printf '%s\n' "${src}" | limactl shell "${NAME}" tic -x -
echo "${TERM_NAME} の terminfo を VM の ~/.terminfo にコピーしました（次に入るシェルから TERM が置き換えられなくなります）"
