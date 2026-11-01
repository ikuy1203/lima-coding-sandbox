#!/bin/bash
# GitHub Copilot CLI をインストールする（mode: user / 通常ユーザで実行）
#
# 公式手順: https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli
# install スクリプト方式を使う（npm 方式とは異なり Node.js が不要）。
# root 以外で実行すると、インストール先は ~/.local/bin/copilot になる（以後の更新は `copilot update`）。
#
# バージョン固定（param.copilotVersion / .env の COPILOT_VERSION）:
# 公式 install スクリプトは環境変数 VERSION（例: 1.0.91、prerelease）を読み、
# GitHub Releases から該当版のアーカイブと SHA256SUMS.txt を取得して SHA-256 検証を行う。
# （空または latest のときは最新安定版を入れる。prerelease も指定可能）。
# 指定したバージョンが効くのは初回インストール時のみで、以後の更新は手動更新に任せる。
# なお、公式 install スクリプトは SHA256SUMS.txt の取得に失敗した場合は警告なしで検証をスキップする
# 制約（fail-open）があるため、本スクリプトでは導入後に verify_cli で指定版の一致と実動作を厳格に確認する。
#
# 公式手順では `curl -fsSL https://gh.io/copilot-install | bash` と案内されているが、
# 本スクリプトでは一時ファイルへのダウンロード完了後に実行し、途中失敗時の不完全な実行を防ぐ。
# また、接続タイムアウト・最大試行時間・リトライを設けて一時的なネットワーク障害から回復できるようにしている。
# なお、外側のタイムアウト・リトライ設定は install スクリプト内部で行われる本体アーカイブのダウンロードには引き継がれない
# （内部のタイムアウト・リトライや後始末は上流ツールの実装に依存する）。
set -eux -o pipefail

copilot_ver="${PARAM_copilotVersion:-}"
case "${copilot_ver}" in
  ""|latest)
    copilot_ver=""
    ;;
  prerelease)
    ;;
  *)
    if ! printf '%s\n' "${copilot_ver}" | grep -Eq '^[vV]?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z._-]+)?$'; then
      echo >&2 "error: param copilotVersion is invalid: '${copilot_ver}' (expected semver or 'prerelease')"
      exit 1
    fi
    copilot_ver="${copilot_ver#[vV]}"
    ;;
esac

tmp_files=()
cleanup() {
  if [ "${#tmp_files[@]}" -gt 0 ]; then
    rm -f "${tmp_files[@]}"
  fi
}
trap cleanup EXIT

verify_cli() {
  local name="$1"
  local bin="$2"
  local expected_version="${3:-}"
  local verify_timeout="${CLI_VERIFY_TIMEOUT:-10}"

  if [ ! -e "${bin}" ] && [ ! -L "${bin}" ]; then
    echo >&2 "error: ${name} verification failed: ${bin} does not exist"
    return 1
  fi
  if [ ! -x "${bin}" ]; then
    echo >&2 "error: ${name} verification failed: ${bin} is not executable"
    return 1
  fi

  local ver_out=""
  local rc=0
  if ver_out=$(timeout -k 2 "${verify_timeout}" "${bin}" --version 2>&1); then
    rc=0
  else
    rc=$?
  fi

  if [ "${rc}" -eq 124 ]; then
    echo >&2 "error: ${name} verification failed: '${bin} --version' timed out after ${verify_timeout}s"
    return 1
  elif [ "${rc}" -ne 0 ]; then
    echo >&2 "error: ${name} verification failed: '${bin} --version' exited with code ${rc}"
    return 1
  fi

  if [ -n "${expected_version}" ]; then
    local target_ver="${expected_version#[vV]}"
    local match_ok=0
    if printf '%s\n' "${ver_out}" | awk -v target="${target_ver}" '
      {
        for (i = 1; i <= NF; i++) {
          t = $i
          sub(/^[([{<"\047]+/, "", t)
          sub(/[.,;:!?)\]}>"\047]+$/, "", t)
          sub(/^[vV]/, "", t)
          if (t == target) { found = 1; exit 0 }
        }
      }
      END { exit !found }
    '; then
      match_ok=1
    fi

    if [ "${match_ok}" -ne 1 ]; then
      echo >&2 "error: ${name} verification failed: expected version '${expected_version}', but '${bin} --version' reported: ${ver_out}"
      return 1
    fi
  fi

  return 0
}

bin="${HOME}/.local/bin/copilot"
broken_existing=false
if [ -e "${bin}" ] || [ -L "${bin}" ]; then
  if verify_cli "copilot" "${bin}"; then
    exit 0
  fi
  echo >&2 "warning: existing copilot binary at ${bin} is broken or failed verification; reinstalling"
  broken_existing=true
fi

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
download_file https://gh.io/copilot-install "${installer}"

expected_ver=""
installer_log=$(mktemp)
tmp_files+=("${installer_log}")

run_installer() {
  local rc=0
  if [ "${copilot_ver}" = "prerelease" ]; then
    local installer_out
    if installer_out=$(VERSION="prerelease" bash "${installer}" 2>&1); then
      rc=0
    else
      rc=$?
    fi
    printf '%s\n' "${installer_out}" > "${installer_log}"
    if [ "${rc}" -ne 0 ]; then
      echo >&2 "error: copilot prerelease installer failed with exit code ${rc}"
      return "${rc}"
    fi
    local tag
    tag=$(awk '/Latest prerelease version:[[:space:]]*/ { print $NF }' "${installer_log}" | tail -n 1)
    if [ -z "${tag}" ]; then
      echo >&2 "error: failed to determine resolved prerelease version from installer output"
      return 1
    fi
    expected_ver="${tag}"
  elif [ -n "${copilot_ver}" ]; then
    if VERSION="${copilot_ver}" bash "${installer}"; then
      expected_ver="${copilot_ver}"
    else
      return $?
    fi
  else
    if VERSION="" bash "${installer}"; then
      expected_ver=""
    else
      return $?
    fi
  fi
}

backup_bin=""
if [ "${broken_existing}" = true ] && { [ -e "${bin}" ] || [ -L "${bin}" ]; }; then
  backup_bin=$(mktemp "${bin}.bak.XXXXXX")
  mv -f "${bin}" "${backup_bin}"
fi
if ! { run_installer && verify_cli "copilot" "${bin}" "${expected_ver}"; }; then
  rm -f "${bin}"
  if [ -n "${backup_bin}" ] && { [ -e "${backup_bin}" ] || [ -L "${backup_bin}" ]; }; then
    echo >&2 "warning: reinstallation failed; restoring original binary"
    mv -f "${backup_bin}" "${bin}"
  fi
  exit 1
fi
if [ -n "${backup_bin}" ]; then
  rm -f "${backup_bin}"
fi
