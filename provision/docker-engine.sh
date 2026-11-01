#!/bin/bash
# Docker Engine の apt リポジトリを登録し、ラッパーを配置する（mode: system / root で実行）
#
# 公式手順: https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
#
# 公式手順との差異:
# - apt-get update を 1 回に集約するため、リポジトリ登録後の apt update および Docker Engine パッケージ群
#   （docker-ce 等）のインストールはここでは実行せず、後続の provision/apt-packages.sh でまとめて行う。
#   そのため、このスクリプトは apt-packages.sh より前に実行する（coding-sandbox.yaml の provision の順序）。
# - 公式手順の事前準備にある apt-get update && apt-get install ca-certificates curl は、
#   どちらもイメージに同梱されているため、存在しない場合のみ実行する（不要な apt-get update を防ぐ）。
# - 鍵の取得処理には接続タイムアウト・最大試行時間・限定回数のリトライを設けて
#   一時的な通信障害から回復できるようにしている。
# - 鍵ファイル、sources.list、ラッパースクリプトは一時ファイルへの取得・生成が完了してから配置し、失敗時に壊れたファイルを残さない。
# - root で実行するため公式のコマンドから sudo を外している。
# - 非対話で実行するため apt は apt-get -y に置き換えている。
# - 公式手順の docker グループ追加方式の代わりに、/usr/local/bin/docker にパスワードなし sudo を透過実行する
#   ラッパースクリプトを配置している（グループ方式だと SSH セッション再接続まで反映されないため。README を参照）。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

keyring="${DOCKER_KEYRING:-/etc/apt/keyrings/docker.asc}"
sources="${DOCKER_SOURCES:-/etc/apt/sources.list.d/docker.sources}"
wrapper="${DOCKER_WRAPPER:-/usr/local/bin/docker}"

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

is_repo_configured() {
  [ -s "${keyring}" ] && [ -s "${sources}" ] && \
    awk -v uri="https://download.docker.com/linux/ubuntu" -v key="${keyring}" '
      BEGIN { RS = ""; found = 0 }
      {
        has_uri = 0; has_key = 0; enabled = 1
        n = split($0, lines, "\n")
        for (i = 1; i <= n; i++) {
          line = lines[i]
          sub(/#.*$/, "", line)
          sub(/^[ \t]+/, "", line)
          sub(/[ \t]+$/, "", line)
          if (line == "") continue
          if (tolower(line) ~ /^enabled:[ \t]*(no|false|0)([ \t]|$)/) enabled = 0
          if (line ~ /^URIs:[ \t]+/) {
            val = line
            sub(/^URIs:[ \t]+/, "", val)
            n_uris = split(val, uwords, /[ \t]+/)
            for (j = 1; j <= n_uris; j++) {
              u = uwords[j]
              sub(/\/+$/, "", u)
              target_u = uri
              sub(/\/+$/, "", target_u)
              if (u == target_u) has_uri = 1
            }
          }
          if (line ~ /^Signed-By:[ \t]+/) {
            val = line
            sub(/^Signed-By:[ \t]+/, "", val)
            sub(/^[ \t"]+/, "", val)
            sub(/[ \t"]+$/, "", val)
            if (val == key) has_key = 1
          }
        }
        if (has_uri && has_key && enabled) found = 1
      }
      END { exit !found }
    ' "${sources}" 2>/dev/null
}

# 公式 apt リポジトリと鍵が登録済みであればスキップする
if ! is_repo_configured; then
  # 競合する非公式パッケージを削除する
  conflicting_packages=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1 || true)
  if [ -n "${conflicting_packages}" ]; then
    # shellcheck disable=SC2086
    apt-get remove -y ${conflicting_packages}
  fi

  # 公式手順の apt-get install ca-certificates curl はイメージに同梱されているため、無いときだけ行う
  if ! command -v curl >/dev/null || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    apt-get update
    apt-get install -y ca-certificates curl
  fi

  # Docker の apt リポジトリを登録する
  # 鍵と sources は一時ファイルに取得・作成し、成功してから置く（途中で失敗しても壊れたファイルを残さない）
  install -m 0755 -d "$(dirname "${keyring}")"
  out_key=$(mktemp)
  tmp_files+=("${out_key}")
  download_file https://download.docker.com/linux/ubuntu/gpg "${out_key}"
  install -m 0644 "${out_key}" "${keyring}"
  rm -f "${out_key}"

  install -m 0755 -d "$(dirname "${sources}")"
  ubuntu_codename="${DOCKER_UBUNTU_CODENAME:-}"
  os_release_file="${DOCKER_OS_RELEASE_FILE:-/etc/os-release}"
  if [ -z "${ubuntu_codename}" ]; then
    if [ -f "${os_release_file}" ]; then
      # shellcheck disable=SC1090
      . "${os_release_file}"
      ubuntu_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    fi
  fi
  if [ -z "${ubuntu_codename}" ]; then
    echo >&2 "error: could not determine Ubuntu codename from ${os_release_file} (and DOCKER_UBUNTU_CODENAME is unset)"
    exit 1
  fi

  out_src=$(mktemp)
  tmp_files+=("${out_src}")
  cat >"${out_src}" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${ubuntu_codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: ${keyring}
EOF
  install -m 0644 "${out_src}" "${sources}"
  rm -f "${out_src}"
fi

# エージェントや通常ユーザが sudo を意識せずに Docker を利用できるよう、
# パスワードなし sudo を透過実行するラッパースクリプトを /usr/local/bin/docker に配置する
install -m 0755 -d "$(dirname "${wrapper}")"
out=$(mktemp)
tmp_files+=("${out}")
cat >"${out}" <<'EOF'
#!/bin/sh
exec sudo -n /usr/bin/docker "$@"
EOF
install -m 0755 "${out}" "${wrapper}"
rm -f "${out}"
