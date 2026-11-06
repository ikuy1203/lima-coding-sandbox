#!/bin/bash
# make update: 起動中の VM 内のツール（herdr・copilot・mise）と apt パッケージを一括更新する
#
# テスト用環境変数:
# - LIMA_SANDBOX_REBOOT_REQUIRED_FILE: 再起動要否判定ファイルのパス（既定: /var/run/reboot-required）
# - LIMA_SANDBOX_APT_UPDATE_ATTEMPTS: apt-get update の最大試行回数（既定: 30）
# - LIMA_SANDBOX_APT_UPDATE_SLEEP: apt-get update 再試行時の待機秒数（既定: 3）
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

# shellcheck disable=SC2016
limactl shell "${NAME}" bash -c '
  set -eu -o pipefail
  unset HERDR_ENV

  herdr_skipped=0
  echo "==> herdr を更新しています..."
  herdr_out=""
  if herdr_out=$("${HOME}/.local/bin/herdr" update </dev/null 2>&1); then
    printf "%s\n" "${herdr_out}"
  else
    rc=$?
    printf "%s\n" "${herdr_out}" >&2
    exit "${rc}"
  fi
  case "${herdr_out}" in
    *"Herdr was not updated."*)
      herdr_skipped=1
      ;;
  esac

  echo "==> GitHub Copilot CLI を更新しています..."
  "${HOME}/.local/bin/copilot" update </dev/null

  echo "==> mise を更新しています..."
  "${HOME}/.local/bin/mise" self-update -y </dev/null

  echo "==> apt パッケージを更新しています..."
  apt_update_attempts="${LIMA_SANDBOX_APT_UPDATE_ATTEMPTS:-30}"
  case "${apt_update_attempts}" in
    ""|*[!0-9]*|0) apt_update_attempts=30 ;;
  esac
  apt_update_sleep="${LIMA_SANDBOX_APT_UPDATE_SLEEP:-3}"
  apt_attempt=1
  while true; do
    apt_out=""
    if apt_out=$(sudo -n apt-get --error-on=any update 2>&1); then
      printf "%s\n" "${apt_out}"
      break
    else
      rc=$?
    fi
    case "${apt_out}" in
      *"Could not get lock"*|*"Unable to lock directory"*)
        if [ "${apt_attempt}" -ge "${apt_update_attempts}" ]; then
          printf "%s\n" "${apt_out}" >&2
          exit "${rc}"
        fi
        echo >&2 "apt のロック解放を待機しています。${apt_update_sleep} 秒後に再試行します (${apt_attempt}/${apt_update_attempts})..."
        sleep "${apt_update_sleep}"
        apt_attempt=$((apt_attempt + 1))
        ;;
      *)
        printf "%s\n" "${apt_out}" >&2
        exit "${rc}"
        ;;
    esac
  done
  sudo -n DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 upgrade -y --with-new-pkgs \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold
  if command -v fdfind >/dev/null 2>&1; then
    sudo -n ln -sf "$(command -v fdfind)" /usr/local/bin/fd
  fi

  if [ "${herdr_skipped}" -eq 1 ]; then
    echo ""
    echo "注意: 稼働中の herdr サーバーの再起動が必要な更新のため、herdr のバイナリ更新はスキップされました。herdr のセッションを終了してから再度 make update（または VM 内で herdr update）を実行してください"
  fi

  reboot_required_file="${LIMA_SANDBOX_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
  if [ -f "${reboot_required_file}" ]; then
    echo ""
    echo "再起動が必要な更新があります。反映するには make restart を実行してください"
  fi
'
