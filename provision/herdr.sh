#!/bin/bash
# herdr をインストールし、ログインシェル設定を構成する（mode: user / 通常ユーザで実行）
#
# 公式手順: https://herdr.dev/docs/install/
# インストール先: ~/.local/bin/herdr（以後の更新は `herdr update`）
# 設定ファイル: ~/.config/herdr/config.toml（[terminal] shell_mode = "login"）
#
# Linux 版の herdr は [terminal].shell_mode の既定値 "auto" が非ログインシェルを起動する。
# そのため make herdr-remote（herdr --remote）等で非ログイン SSH 経由でサーバが起動すると、
# ~/.profile（mise shims や ~/.local/bin）および /etc/profile.d/* が一度も読み込まれない。
# そこで ~/.config/herdr/config.toml に shell_mode = "login" を設定する（冪等、かつ利用者が
# 既に shell_mode を設定済みの場合は上書きせず尊重する）。
#
# 公式 install スクリプトはバージョン指定に未対応（常に https://herdr.dev/latest.json の版を入れる。
# 環境変数は HERDR_INSTALL_DIR のみ）。インストーラ自身が latest.json に記載された sha256 と
# ダウンロードしたバイナリを照合して検証する（独立した署名ファイルの検証は行われない）。
#
# 公式手順では `curl -fsSL https://herdr.dev/install.sh | sh` と案内されているが、
# 本スクリプトでは一時ファイルへのダウンロード完了後に実行し、途中失敗時の不完全な実行を防ぐ。
# また、接続タイムアウト・最大試行時間・リトライを設けて一時的なネットワーク障害から回復できるようにしている。
# なお、外側のタイムアウト・リトライ設定は install.sh 内部で行われる本体バイナリのダウンロードには引き継がれない
# （内部のタイムアウト・リトライや後始末は上流ツールの実装に依存する）。
set -eux -o pipefail

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

need_install=1
bin="${HOME}/.local/bin/herdr"
broken_existing=false
if [ -e "${bin}" ] || [ -L "${bin}" ]; then
  if verify_cli "herdr" "${bin}"; then
    need_install=0
  else
    echo >&2 "warning: existing herdr binary at ${bin} is broken or failed verification; reinstalling"
    broken_existing=true
  fi
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

if [ "${need_install}" -eq 1 ]; then
  installer=$(mktemp)
  tmp_files+=("${installer}")
  download_file https://herdr.dev/install.sh "${installer}"
  backup_bin=""
  if [ "${broken_existing}" = true ] && { [ -e "${bin}" ] || [ -L "${bin}" ]; }; then
    backup_bin=$(mktemp "${bin}.bak.XXXXXX")
    mv -f "${bin}" "${backup_bin}"
  fi
  if ! { sh "${installer}" && verify_cli "herdr" "${bin}"; }; then
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
fi

inspect_herdr_config() {
  local config_file="$1"
  awk '
    function scan_multiline_state(s,    i, n, c, c3, in_dq, in_sq) {
      n = length(s)
      i = 1
      in_dq = 0
      in_sq = 0
      while (i <= n) {
        if (in_ml_dq) {
          if (substr(s, i, 1) == "\\") {
            i += 2
            continue
          }
          if (substr(s, i, 3) == "\"\"\"") {
            in_ml_dq = 0
            i += 3
            continue
          }
          i++
          continue
        }
        if (in_ml_sq) {
          if (substr(s, i, 3) == "\047\047\047") {
            in_ml_sq = 0
            i += 3
            continue
          }
          i++
          continue
        }
        if (in_dq) {
          c = substr(s, i, 1)
          if (c == "\\") {
            i += 2
            continue
          }
          if (c == "\"") {
            in_dq = 0
          }
          i++
          continue
        }
        if (in_sq) {
          if (substr(s, i, 1) == "\047") {
            in_sq = 0
          }
          i++
          continue
        }
        c = substr(s, i, 1)
        if (c == "#") {
          break
        }
        c3 = substr(s, i, 3)
        if (c3 == "\"\"\"") {
          in_ml_dq = 1
          i += 3
          continue
        }
        if (c3 == "\047\047\047") {
          in_ml_sq = 1
          i += 3
          continue
        }
        if (c == "\"") {
          in_dq = 1
        } else if (c == "\047") {
          in_sq = 1
        } else if (c == "[") {
          bracket_depth++
        } else if (c == "]") {
          if (bracket_depth > 0) {
            bracket_depth--
          }
        } else if (c == "{") {
          brace_depth++
        } else if (c == "}") {
          if (brace_depth > 0) {
            brace_depth--
          }
        }
        i++
      }
    }
    BEGIN {
      in_root = 1
      in_terminal = 0
      in_ml_dq = 0
      in_ml_sq = 0
      bracket_depth = 0
      brace_depth = 0
      first_terminal_line = 0
      has_shell_mode = 0
      has_unsupported_form = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      started_nested = (in_ml_dq || in_ml_sq || bracket_depth > 0 || brace_depth > 0)
      scan_multiline_state(line)
      if (started_nested) {
        next
      }
      if (line ~ /^[ \t]*\[[ \t]*(terminal|"terminal"|\047terminal\047)[ \t]*\]([ \t]*(#.*)?)?$/) {
        in_terminal = 1
        in_root = 0
        if (!first_terminal_line) {
          first_terminal_line = NR
        }
        next
      }
      if (line ~ /^[ \t]*\[/) {
        in_terminal = 0
        in_root = 0
        next
      }
      if (in_terminal && line ~ /^[ \t]*(shell_mode|"shell_mode"|\047shell_mode\047)[ \t]*=/) {
        has_shell_mode = 1
        next
      }
      if (in_root && line ~ /^[ \t]*(terminal|"terminal"|\047terminal\047)[ \t]*\.[ \t]*(shell_mode|"shell_mode"|\047shell_mode\047)[ \t]*=/) {
        has_shell_mode = 1
        next
      }
      if (in_root && (line ~ /^[ \t]*(terminal|"terminal"|\047terminal\047)[ \t]*=[ \t]*\{/ || line ~ /^[ \t]*(terminal|"terminal"|\047terminal\047)[ \t]*\./)) {
        has_unsupported_form = 1
        next
      }
    }
    END {
      if (has_shell_mode) {
        print "already_set"
      } else if (has_unsupported_form) {
        print "unsupported_form"
      } else if (first_terminal_line > 0) {
        print "insert_in_section:" first_terminal_line
      } else {
        print "append_section"
      }
    }
  ' "${config_file}"
}

configure_herdr_shell_mode() {
  local config_file="${HOME}/.config/herdr/config.toml"
  local marker="# added by lima-coding-sandbox provision/herdr.sh"
  local comment_line="${marker}: リモート接続（herdr --remote）でも ~/.profile（mise shims や ~/.local/bin）が読まれるようにする"
  local verify_timeout="${CLI_VERIFY_TIMEOUT:-10}"
  local tmp=""

  if [ ! -e "${config_file}" ]; then
    tmp=$(mktemp)
    tmp_files+=("${tmp}")
    cat >"${tmp}" <<EOF
${comment_line}
[terminal]
shell_mode = "login"
EOF
    if ! HERDR_CONFIG_PATH="${tmp}" timeout -k 2 "${verify_timeout}" "${bin}" config check >/dev/null 2>&1; then
      echo >&2 "error: generated herdr config failed 'herdr config check'"
      return 1
    fi
    if [ -L "${config_file}" ]; then
      local link_target
      link_target=$(readlink "${config_file}")
      case "${link_target}" in
        /*) ;;
        *) link_target="$(dirname "${config_file}")/${link_target}" ;;
      esac
      install -m 0755 -d "$(dirname "${link_target}")"
      cat "${tmp}" >"${config_file}"
    else
      install -m 0755 -d "$(dirname "${config_file}")"
      install -m 0644 "${tmp}" "${config_file}"
    fi
    return 0
  fi

  # 既存ファイルが壊れている場合は上書きせず保護する
  if ! HERDR_CONFIG_PATH="${config_file}" timeout -k 2 "${verify_timeout}" "${bin}" config check >/dev/null 2>&1; then
    echo >&2 "warning: existing ${config_file} failed 'herdr config check'; skipping shell_mode configuration"
    return 0
  fi

  local action
  if ! action=$(inspect_herdr_config "${config_file}"); then
    echo >&2 "error: failed to inspect ${config_file}"
    return 1
  fi

  local eol=""
  if awk '/\r$/ { found=1; exit } END { exit !found }' "${config_file}"; then
    eol=$'\r'
  fi

  case "${action}" in
    already_set)
      return 0
      ;;
    unsupported_form)
      echo >&2 "warning: ${config_file} defines terminal via inline table or dotted key without shell_mode; skipping automatic configuration"
      return 0
      ;;
    insert_in_section:*)
      local target_line="${action#insert_in_section:}"
      tmp=$(mktemp)
      tmp_files+=("${tmp}")
      HERDR_COMMENT_LINE="${comment_line}" HERDR_EOL="${eol}" awk -v target="${target_line}" '
        NR == target {
          print
          print ENVIRON["HERDR_COMMENT_LINE"] ENVIRON["HERDR_EOL"]
          print "shell_mode = \"login\"" ENVIRON["HERDR_EOL"]
          next
        }
        { print }
      ' "${config_file}" >"${tmp}"
      ;;
    append_section)
      tmp=$(mktemp)
      tmp_files+=("${tmp}")
      if [ ! -s "${config_file}" ]; then
        cat >"${tmp}" <<EOF
${comment_line}
[terminal]
shell_mode = "login"
EOF
      else
        HERDR_COMMENT_LINE="${comment_line}" HERDR_EOL="${eol}" awk '
          { print }
          END {
            print "" ENVIRON["HERDR_EOL"]
            print ENVIRON["HERDR_COMMENT_LINE"] ENVIRON["HERDR_EOL"]
            print "[terminal]" ENVIRON["HERDR_EOL"]
            print "shell_mode = \"login\"" ENVIRON["HERDR_EOL"]
          }
        ' "${config_file}" >"${tmp}"
      fi
      ;;
    *)
      echo >&2 "error: unexpected herdr config analysis result: ${action}"
      return 1
      ;;
  esac

  # 既存の構文エラーや未知キーは事前チェックで return 0 スキップ済みのため、
  # ここで失敗するのは本スクリプトが生成した更新内容に不備がある場合のみ。
  # 既存ファイルを書き換えずに保護したうえで、不具合を隠さないよう非ゼロ終了する。
  if ! HERDR_CONFIG_PATH="${tmp}" timeout -k 2 "${verify_timeout}" "${bin}" config check >/dev/null 2>&1; then
    echo >&2 "error: updated herdr config failed 'herdr config check'; preserving existing ${config_file}"
    return 1
  fi
  if ! cmp -s "${tmp}" "${config_file}"; then
    cat "${tmp}" >"${config_file}"
  fi
}

configure_herdr_shell_mode
