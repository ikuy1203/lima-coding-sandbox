#!/bin/bash
# インスタンスのシェルに入る（引数が指定された場合はそのコマンドを VM 内で実行する）
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?

exec limactl shell "${NAME}" "$@"
