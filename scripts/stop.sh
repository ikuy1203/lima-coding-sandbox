#!/bin/bash
# インスタンスを停止する
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?

st=$(get_status "${NAME}") || exit $?
if [ "${st}" = Running ]; then
  set -x
  limactl stop "${NAME}"
else
  echo "インスタンス ${NAME} は動いていません"
fi
