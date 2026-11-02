#!/bin/bash
# VM のポートをホストの 127.0.0.1 に転送する
#
# Lima がインスタンスごとに作る ssh.config（ホストの ~/.ssh/config への Include は不要）で ssh -L する。
# ControlMaster を使うと、ssh は転送を Lima の既存の接続に登録してすぐ終了し、転送が残り続けるため使わない
# （ControlMaster=no で専用の接続を張るので、Ctrl-C で ssh を終了すると転送も止まる）。
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?
port=$(normalize "${PORT:-}")
host_port=$(normalize "${HOST_PORT:-}")

case "${port}" in
  ''|*[!0-9]*)
    echo >&2 "エラー: PORT=<VM のポート> を指定してください（例: make forward PORT=3000）"
    exit 1
    ;;
esac

host_port="${host_port:-${port}}"
case "${host_port}" in
  ''|*[!0-9]*)
    echo >&2 "エラー: HOST_PORT にはポート番号（数値）を指定してください: ${host_port}"
    exit 1
    ;;
esac

dir=$(limactl list "${NAME}" --format '{{.Dir}}') || exit $?
echo "VM の 127.0.0.1:${port} を http://127.0.0.1:${host_port} に転送します（Ctrl-C で終了）"
exec ssh -F "${dir}/ssh.config" -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes \
  -N -L "127.0.0.1:${host_port}:127.0.0.1:${port}" "lima-${NAME}"
