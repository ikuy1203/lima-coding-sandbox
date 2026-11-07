#!/bin/bash
# make ssh-config: 起動中の VM の SSH 接続設定（~/.ssh/config 用の Include と ssh.config の内容）を表示する
set -eu -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?

st=$(get_status "${NAME}") || exit $?
if [ -z "${st}" ]; then
  echo >&2 "エラー: インスタンス ${NAME} はありません"
  exit 1
fi
if [ "${st}" != Running ]; then
  echo >&2 "エラー: インスタンス ${NAME} は動いていません（先に make start で起動してください）"
  exit 1
fi

dir=$(limactl list "${NAME}" --format '{{.Dir}}') || exit $?
if [ -z "${dir}" ]; then
  echo >&2 "エラー: インスタンス ${NAME} のディレクトリを取得できませんでした"
  exit 1
fi

ssh_config="${dir}/ssh.config"
if [ ! -r "${ssh_config}" ] || [ ! -s "${ssh_config}" ]; then
  echo >&2 "エラー: SSH 設定ファイルが見つかりません: ${ssh_config}"
  exit 1
fi

lima_parent=$(dirname "${dir}")
display_config="${ssh_config}"
include_target="${lima_parent}/*/ssh.config"
if [ -n "${HOME:-}" ]; then
  # shellcheck disable=SC2088
  if [ "${dir}" = "${HOME}/.lima/${NAME}" ]; then
    display_config="~/.lima/${NAME}/ssh.config"
    include_target="~/.lima/*/ssh.config"
  elif [[ "${dir}" == "${HOME}/"* ]]; then
    display_config="~/${dir#"${HOME}/"}/ssh.config"
    include_target="~/${lima_parent#"${HOME}/"}/*/ssh.config"
  fi
fi

case "${include_target}" in
  *[[:space:]]*) include_line="Include \"${include_target}\"" ;;
  *) include_line="Include ${include_target}" ;;
esac

host="lima-${NAME}"
host_lower=$(printf '%s' "${host}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
expected_port=$(awk 'tolower($1) == "port" { print $2; exit }' "${ssh_config}")
ssh_state="unconfigured"
if ssh_g_out=$(ssh -G "${host}" 2>/dev/null); then
  resolved_host=$(printf '%s\n' "${ssh_g_out}" | awk '$1 == "hostname" { print $2; exit }')
  resolved_lower=$(printf '%s' "${resolved_host}" | LC_ALL=C tr '[:upper:]' '[:lower:]')
  resolved_port=$(printf '%s\n' "${ssh_g_out}" | awk '$1 == "port" { print $2; exit }')
  if [ -n "${resolved_lower}" ] && [ "${resolved_lower}" != "${host_lower}" ]; then
    if [ -n "${expected_port}" ] && [ -n "${resolved_port}" ] && [ "${resolved_port}" != "${expected_port}" ]; then
      ssh_state="port_mismatch"
    else
      ssh_state="configured"
    fi
  fi
else
  ssh_state="unknown"
fi

echo "# インスタンス ${NAME} の SSH 接続設定"
echo "#"
echo "# ホスト名: ${host}"
echo "# 設定ファイル: ${display_config}"
case "${ssh_state}" in
  configured)
    echo "# 状態: 設定済み（ssh ${host} で接続できます）"
    echo "#"
    echo "# ホストの ~/.ssh/config の設定例:"
    echo "#   ${include_line}"
    echo "#"
    echo "# VS Code / Cursor (Remote - SSH) から接続するには:"
    echo "#   コマンドパレットから「Remote-SSH: Connect to Host...」を実行し、${host} を選ぶ"
    ;;
  port_mismatch)
    echo "# 状態: ポート不一致（~/.ssh/config のポート ${resolved_port} が現在の VM のポート ${expected_port} と一致しません。古い設定を直接書いていないか確認し、先頭で Include を使用してください）"
    echo "#"
    echo "#   ${include_line}"
    echo "#"
    echo "# VS Code / Cursor (Remote - SSH) から接続するには:"
    echo "#   1. ホストの ~/.ssh/config の先頭に上の Include 行を設定する"
    echo "#   2. コマンドパレットから「Remote-SSH: Connect to Host...」を実行し、${host} を選ぶ"
    ;;
  unknown)
    echo "# 状態: 不明（ssh -G ${host} で原因を確認し、~/.ssh/config の構文などを確認してください）"
    echo "#"
    echo "# ホストの ~/.ssh/config の先頭に追加する設定:"
    echo "#   ${include_line}"
    echo "#"
    echo "# VS Code / Cursor (Remote - SSH) から接続するには:"
    echo "#   1. ホストの ~/.ssh/config の先頭に上の Include 行を追加する（初回のみ）"
    echo "#   2. コマンドパレットから「Remote-SSH: Connect to Host...」を実行し、${host} を選ぶ"
    ;;
  *)
    echo "# 状態: 未設定（ホストの ~/.ssh/config の先頭に次の 1 行を追加してください）"
    echo "#"
    echo "#   ${include_line}"
    echo "#"
    echo "# VS Code / Cursor (Remote - SSH) から接続するには:"
    echo "#   1. ホストの ~/.ssh/config の先頭に上の Include 行を追加する（初回のみ）"
    echo "#   2. コマンドパレットから「Remote-SSH: Connect to Host...」を実行し、${host} を選ぶ"
    ;;
esac
echo "#"
echo "# 以下は ${display_config} の現在の内容です（ポート番号は起動のたびに変わることがあるため、"
echo "# この内容を ~/.ssh/config に直接コピーせず、上の Include を使用してください）:"
echo ""
cat "${ssh_config}"
