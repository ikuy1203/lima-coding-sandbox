#!/bin/bash
# Antigravity CLI (agy) をインストールする（mode: user / 通常ユーザで実行）
#
# 公式手順: https://antigravity.google/docs/cli/install
# インストール先: ~/.local/bin/agy（本体はバックグラウンドで自動更新される）
#
# ドキュメントにある --skip-aliases / --skip-path は、現行の install.sh では
# "Unknown parameter" エラーになるため指定しない。
#
# 公式のコマンドに --compressed だけ追加している。antigravity.google は、クライアントが
# Accept-Encoding を送らなくても gzip 圧縮した本文（content-encoding: gzip）を返すことがある。
# そのままだと bash が gzip のバイナリを読んで構文エラーになるため、curl に展開させる。
#
# 公式手順では `curl -fsSL --compressed ... | bash` と案内されているが、
# 本スクリプトでは一時ファイルへのダウンロード完了後に実行し、途中失敗時の不完全な実行を防ぐ。
# また、接続タイムアウト・最大試行時間・リトライを設けて一時的なネットワーク障害から回復できるようにしている。
# なお、外側のタイムアウト・リトライ設定は install.sh 内部で行われる本体のダウンロードには引き継がれない
# （内部のタイムアウト・リトライや後始末は上流ツールの実装に依存する）。
set -eux -o pipefail

if [ -x "${HOME}/.local/bin/agy" ]; then
  exit 0
fi

tmp_files=()
cleanup() {
  if [ "${#tmp_files[@]}" -gt 0 ]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

is_transient_curl_rc() {
  case "$1" in
    6|7|16|18|28|35|52|55|56|92) return 0 ;;
    *) return 1 ;;
  esac
}

is_transient_http_code() {
  case "$1" in
    408|429|500|502|503|504) return 0 ;;
    *) return 1 ;;
  esac
}

download_file() {
  local extra_args=()
  while [ "$#" -gt 2 ]; do
    extra_args+=("$1")
    shift
  done
  local url="$1"
  local dest="$2"

  local connect_timeout="${DOWNLOAD_CONNECT_TIMEOUT:-10}"
  local max_time="${DOWNLOAD_MAX_TIME:-60}"
  local retry_count="${DOWNLOAD_RETRY_COUNT:-3}"
  local retry_delay="${DOWNLOAD_RETRY_DELAY:-2}"
  local total_max_time="${DOWNLOAD_TOTAL_MAX_TIME:-180}"

  local max_attempts=$((retry_count + 1))
  local deadline=$((SECONDS + total_max_time))
  local attempt=1
  local last_reason="unknown error"

  while [ "${attempt}" -le "${max_attempts}" ]; do
    local remaining=$((deadline - SECONDS))
    if [ "${remaining}" -le 0 ]; then
      rm -f "${dest}"
      echo >&2 "error: failed to download ${url}: exceeded total timeout (${total_max_time}s) after $((attempt - 1)) attempt(s) (last error: ${last_reason})"
      return 1
    fi

    local attempt_max_time="${max_time}"
    if [ "${remaining}" -lt "${attempt_max_time}" ]; then
      attempt_max_time="${remaining}"
    fi

    : > "${dest}"
    local http_code=""
    local rc=0
    local is_empty_body=0
    last_reason=""
    if http_code=$(curl -fsSL \
      --connect-timeout "${connect_timeout}" \
      --max-time "${attempt_max_time}" \
      ${extra_args[@]+"${extra_args[@]}"} \
      -o "${dest}" \
      -w '%{http_code}' \
      "${url}"); then
      rc=0
    else
      rc=$?
    fi

    if [ "${rc}" -eq 0 ]; then
      case "${http_code}" in
        2*|000|"")
          if [ -s "${dest}" ]; then
            return 0
          fi
          is_empty_body=1
          last_reason="empty response body"
          ;;
        *)
          rc=22
          ;;
      esac
    fi

    rm -f "${dest}"

    local transient=0
    if [ "${rc}" -ne 0 ] && is_transient_curl_rc "${rc}"; then
      # HTTP 200 ヘッダ受信後の切断（exit 18）やタイムアウト（exit 28）等、
      # curl 転送エラーが発生している場合は通信一時障害としてリトライする
      transient=1
      if [ "${rc}" -eq 28 ]; then
        last_reason="operation timed out (curl exit 28)"
      else
        last_reason="transient network error (curl exit ${rc})"
      fi
    elif [ "${is_empty_body}" -eq 1 ]; then
      transient=1
    elif [ -n "${http_code}" ] && [ "${http_code}" != "000" ]; then
      if is_transient_http_code "${http_code}"; then
        transient=1
        last_reason="transient HTTP ${http_code} (curl exit ${rc})"
      else
        echo >&2 "error: failed to download ${url}: permanent HTTP ${http_code} (curl exit ${rc})"
        return 1
      fi
    else
      echo >&2 "error: failed to download ${url}: permanent curl error (exit ${rc})"
      return 1
    fi

    if [ "${transient}" -ne 1 ] || [ "${attempt}" -ge "${max_attempts}" ]; then
      break
    fi

    remaining=$((deadline - SECONDS))
    if [ "${remaining}" -le 0 ]; then
      echo >&2 "error: failed to download ${url}: exceeded total timeout (${total_max_time}s) at attempt ${attempt}/${max_attempts} (${last_reason})"
      return 1
    fi

    if [ "${retry_delay}" -gt 0 ]; then
      local sleep_sec="${retry_delay}"
      if [ "${sleep_sec}" -gt "${remaining}" ]; then
        sleep_sec="${remaining}"
      fi
      echo >&2 "warning: failed to download ${url} (attempt ${attempt}/${max_attempts}: ${last_reason}); retrying in ${sleep_sec}s..."
      sleep "${sleep_sec}"
      retry_delay=$((retry_delay * 2))
    else
      echo >&2 "warning: failed to download ${url} (attempt ${attempt}/${max_attempts}: ${last_reason}); retrying..."
    fi

    attempt=$((attempt + 1))
  done

  echo >&2 "error: failed to download ${url} after ${attempt} attempt(s) (${last_reason})"
  return 1
}

installer=$(mktemp)
tmp_files+=("${installer}")
download_file --compressed https://antigravity.google/cli/install.sh "${installer}"
bash "${installer}"
