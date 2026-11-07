#!/bin/bash
# インスタンスを作成する（作成済みなら何もしない）
#
# 設定値は、前後の空白と、両端を囲む引用符（" または ' の 1 組）を取り除いてから使う。
# Git の値が空ならホストの git config --global の値を使う。
# limactl start --param は値をカンマで区切ってしまうため、--param は limactl create で渡す。
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?
TEMPLATE=$(normalize "${TEMPLATE-coding-sandbox.yaml}")
if [ -z "${TEMPLATE}" ]; then
  echo >&2 "エラー: TEMPLATE が空です"
  exit 1
fi

st=$(get_status "${NAME}") || exit $?
if [ -n "${st}" ]; then
  echo "インスタンス ${NAME} は作成済みです"
  exit 0
fi

mounts=$(limactl template yq "./${TEMPLATE}" '.mounts[] | "- location: " + .location') || {
  echo >&2 "エラー: テンプレートまたは設定の検証に失敗しました"
  exit 1
}
if [ -n "${mounts}" ]; then
  echo >&2 "エラー: ホストのディレクトリをマウントする設定があります（docs/security.md の「ホストのマウントが混入しないように」を参照）:"
  printf '%s\n' "${mounts}" >&2
  exit 1
fi

cpus=$(normalize "${CPUS:-}")
memory=$(normalize "${MEMORY:-}")
disk=$(normalize "${DISK:-}")
name=$(normalize "${GIT_USER_NAME:-}")
email=$(normalize "${GIT_USER_EMAIL:-}")
block=$(normalize "${BLOCK_HOST_LOOPBACK:-}")
case "${block}" in
  ""|true|false) ;;
  *)
    echo >&2 "エラー: BLOCK_HOST_LOOPBACK は true か false を指定してください: ${block}"
    exit 1
    ;;
esac

instr=$(normalize "${AGENT_INSTRUCTIONS:-}")
case "${instr}" in
  ""|true|false) ;;
  *)
    echo >&2 "エラー: AGENT_INSTRUCTIONS は true か false を指定してください: ${instr}"
    exit 1
    ;;
esac

copilot_ver=$(normalize "${COPILOT_VERSION:-}")
case "${copilot_ver}" in
  ""|latest) copilot_ver="" ;;
  prerelease) ;;
  *)
    if ! printf '%s\n' "${copilot_ver}" | grep -Eq '^[vV]?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z._-]+)?$'; then
      echo >&2 "エラー: COPILOT_VERSION はバージョン（例: 1.0.91）または prerelease を指定してください: ${copilot_ver}"
      exit 1
    fi
    ;;
esac

mise_ver=$(normalize "${MISE_VERSION:-}")
case "${mise_ver}" in
  ""|latest) mise_ver="" ;;
  *)
    if ! printf '%s\n' "${mise_ver}" | grep -Eq '^[vV]?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z._-]+)?$'; then
      echo >&2 "エラー: MISE_VERSION はバージョン（例: 2026.10.7）を指定してください: ${mise_ver}"
      exit 1
    fi
    ;;
esac

[ -n "${name}" ] || name=$(git config --global user.name 2>/dev/null || true)
[ -n "${email}" ] || email=$(git config --global user.email 2>/dev/null || true)
if [ -z "${name}" ] || [ -z "${email}" ]; then
  echo >&2 "注意: Git のユーザ名またはメールアドレスが空です。VM の中で手動で設定してください（docs/authentication.md の「Git のコミット署名」を参照）"
fi

args=(
  create
  --tty=false
  "--name=${NAME}"
)
if [ -n "${cpus}" ]; then
  args+=("--cpus=${cpus}")
fi
if [ -n "${memory}" ]; then
  args+=("--memory=${memory}")
fi
if [ -n "${disk}" ]; then
  args+=("--disk=${disk}")
fi
args+=(
  --param "gitUserName=${name}"
  --param "gitUserEmail=${email}"
)
if [ -n "${block}" ]; then
  args+=(--param "blockHostLoopback=${block}")
fi
if [ -n "${instr}" ]; then
  args+=(--param "agentInstructions=${instr}")
fi
if [ -n "${copilot_ver}" ]; then
  args+=(--param "copilotVersion=${copilot_ver}")
fi
if [ -n "${mise_ver}" ]; then
  args+=(--param "miseVersion=${mise_ver}")
fi
args+=("./${TEMPLATE}")

set -x
limactl "${args[@]}"
