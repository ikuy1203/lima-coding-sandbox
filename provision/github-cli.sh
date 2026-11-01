#!/bin/bash
# GitHub CLI (gh) の apt リポジトリを登録する（mode: system / root で実行）
#
# 公式手順: https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian
#
# Ubuntu のリポジトリ（universe）の gh は 2.46 で、廃止された GitHub の API を使っているため動かないと
# 公式に案内されている。そのため GitHub CLI の apt リポジトリを登録して入れる。
#
# 公式手順との差異:
# - apt-get update を 1 回に集約するため、公式手順の末尾にある apt update および apt install gh は
#   ここでは実行せず、後続の provision/apt-packages.sh でまとめて行う。
#   そのため、このスクリプトは apt-packages.sh より前に実行する（coding-sandbox.yaml の provision の順序）。
# - 事前準備にある ca-certificates / curl はイメージに同梱されているため、無いときだけ行う（不要な apt-get update を防ぐ）。
# - 公式手順の wget は curl に統一し、接続タイムアウト・最大試行時間・限定回数のリトライを設けて
#   一時的な通信障害から回復できるようにしている。
# - 鍵ファイルおよび sources.list は一時ファイルへの取得・生成が完了してから配置し、失敗時に壊れたファイルを残さない。
# - root で実行するため公式のコマンドから sudo を外している。
# - 非対話で実行するため apt は apt-get -y に置き換えている。
# - ディレクトリの作成は、shellcheck の警告（SC2174）を避けるため mkdir -p -m 755 を install -m 0755 -d に置き換えている。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

keyring="${GITHUB_CLI_KEYRING:-/etc/apt/keyrings/githubcli-archive-keyring.gpg}"
repo_list="${GITHUB_CLI_REPO_LIST:-/etc/apt/sources.list.d/github-cli.list}"

is_repo_configured() {
  [ -s "${keyring}" ] && [ -s "${repo_list}" ] && \
    grep -qF "https://cli.github.com/packages" "${repo_list}" 2>/dev/null && \
    grep -qF "signed-by=${keyring}" "${repo_list}" 2>/dev/null
}

# 公式 apt リポジトリと鍵が正常に登録済みであれば終了する
# （gh パッケージの存在判定にすると、既存の Ubuntu 版 gh がある場合に
# 公式リポジトリの登録がスキップされてしまうため、リポジトリ設定ファイルの内容で判定する）
if is_repo_configured; then
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

# 公式手順の ca-certificates / curl はイメージに同梱されているため、無いときだけ行う
if ! command -v curl >/dev/null || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
  apt-get update
  apt-get install -y ca-certificates curl
fi

# GitHub CLI の apt リポジトリを登録する
# 鍵と repo_list は一時ファイルに取得・作成し、成功してから置く（途中で失敗しても壊れたファイルを残さない）
install -m 0755 -d "$(dirname "${keyring}")"
out_key=$(mktemp)
tmp_files+=("${out_key}")
download_file https://cli.github.com/packages/githubcli-archive-keyring.gpg "${out_key}"
install -m 0644 "${out_key}" "${keyring}"
rm -f "${out_key}"

install -m 0755 -d "$(dirname "${repo_list}")"
out_src=$(mktemp)
tmp_files+=("${out_src}")
echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://cli.github.com/packages stable main" >"${out_src}"
install -m 0644 "${out_src}" "${repo_list}"
rm -f "${out_src}"
