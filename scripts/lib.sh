#!/bin/bash
# scripts/*.sh から読み込まれる共通関数

# インスタンスの状態（Running / Stopped など）を標準出力に返す。
# インスタンスが無ければ空文字列、照会失敗時は非ゼロで終了する。
get_status() {
  local name="${1-}"
  if [ -z "${name}" ]; then
    name=$(resolve_name) || return $?
  fi
  local out
  out=$(limactl --log-level=error list --format '{{.Name}} {{.Status}}') || return $?
  printf '%s\n' "${out}" | awk -v name="${name}" '$1 == name { print $2 }'
}

# 前後の空白と、両端を囲む引用符（" または ' の 1 組）を取り除く
normalize() {
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "${v}" in
    \"*\"|\'*\')
      v="${v#?}"
      v="${v%?}"
      ;;
  esac
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "${v}"
}

# NAME（未設定時は coding-sandbox）を正規化して検証し、標準出力に返す。
# 明示的に空値（NAME="" など）が指定された場合はエラーで非ゼロ終了する。
resolve_name() {
  local raw="${NAME-coding-sandbox}"
  local name
  name=$(normalize "${raw}")
  if [ -z "${name}" ]; then
    echo >&2 "エラー: NAME が空です"
    return 1
  fi
  printf '%s' "${name}"
}

# AUTH_BACKUP_DIR（未設定・空のときは ~/.local/share/lima-coding-sandbox/auth-backup/<NAME>）を
# 正規化・検証し、絶対パスを標準出力に返す。
# リポジトリ内のパス、シンボリックリンク先、またはルート・HOME 直下などが指定された場合はエラーで非ゼロ終了する。
resolve_auth_backup_dir() {
  local name="${1-}"
  if [ -z "${name}" ]; then
    name=$(resolve_name) || return $?
  fi
  if [ -z "${HOME:-}" ]; then
    echo >&2 "エラー: HOME が設定されていません"
    return 1
  fi

  local raw
  raw=$(normalize "${AUTH_BACKUP_DIR:-}")
  if [ -z "${raw}" ]; then
    raw="${HOME}/.local/share/lima-coding-sandbox/auth-backup/${name}"
  else
    # shellcheck disable=SC2088
    case "${raw}" in
      "~") raw="${HOME}" ;;
      "~/"*) raw="${HOME}/${raw#\~/}" ;;
    esac
  fi

  case "${raw}" in
    /*) ;;
    *)
      local pwd_phys
      pwd_phys=$(pwd -P) || return 1
      raw="${pwd_phys}/${raw}"
      ;;
  esac

  while [ "${#raw}" -gt 1 ] && [ "${raw%/}" != "${raw}" ]; do
    raw="${raw%/}"
  done

  local IFS='/'
  local -a parts
  read -r -a parts <<< "${raw}"

  local cur="/"
  local last_was_symlink=0
  local part next
  for part in "${parts[@]}"; do
    case "${part}" in
      ""|".")
        continue
        ;;
      "..")
        last_was_symlink=0
        cur=$(dirname "${cur}")
        if [ -d "${cur}" ]; then
          cur=$(cd "${cur}" 2>/dev/null && pwd -P) || return 1
        fi
        ;;
      *)
        if [ "${cur}" = "/" ]; then
          next="/${part}"
        else
          next="${cur}/${part}"
        fi
        if [ -L "${next}" ]; then
          last_was_symlink=1
        else
          last_was_symlink=0
        fi
        if [ -d "${next}" ]; then
          cur=$(cd "${next}" 2>/dev/null && pwd -P) || return 1
        else
          cur="${next}"
        fi
        ;;
    esac
  done

  if [ "${last_was_symlink}" -eq 1 ]; then
    echo >&2 "エラー: 退避先にシンボリックリンクは指定できません: ${raw}"
    return 1
  fi

  if [ -e "${cur}" ] && [ ! -d "${cur}" ]; then
    echo >&2 "エラー: 退避先がディレクトリではありません: ${cur}"
    return 1
  fi

  local lib_dir repo_root home_phys
  lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 1
  repo_root="$(cd "${lib_dir}/.." && pwd -P)" || return 1
  home_phys="$(cd "${HOME}" 2>/dev/null && pwd -P || printf '%s' "${HOME}")"

  if [ "${cur}" = "${repo_root}" ] || [[ "${cur}" == "${repo_root}/"* ]]; then
    echo >&2 "エラー: リポジトリ内のパスは退避先に指定できません（秘密鍵やトークンの誤コミットを防ぐため、リポジトリ外のパスを指定してください）: ${cur}"
    return 1
  fi

  case "${cur}" in
    "/"|"${HOME}"|"${home_phys}"|"/tmp"|"/private/tmp"|"/var"|"/private/var"|"/var/tmp"|"/private/var/tmp")
      echo >&2 "エラー: そのパスは退避先に指定できません: ${cur}"
      return 1
      ;;
  esac

  printf '%s' "${cur}"
}
