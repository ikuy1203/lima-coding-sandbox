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

# インスタンスが存在し Running 状態であることを確認する。
# 未作成・停止中・状態照会失敗時はエラーメッセージを標準エラー出力に出して非ゼロで終了する。
require_running() {
  local name="${1-}"
  if [ -z "${name}" ]; then
    name=$(resolve_name) || return $?
  fi
  local st
  st=$(get_status "${name}") || return $?
  if [ -z "${st}" ]; then
    echo >&2 "エラー: インスタンス ${name} はありません"
    return 1
  fi
  if [ "${st}" != Running ]; then
    echo >&2 "エラー: インスタンス ${name} は動いていません（先に make start で起動してください）"
    return 1
  fi
}

# ssh-keygen -lf の出力から公開鍵の指紋（SHA256:...）を抽出・検証して標準出力に返す。
# コメント欄に非 UTF-8 バイト列が含まれる場合でも影響を受けないよう LC_ALL=C で処理する。
extract_pubkey_fingerprint() {
  local raw_fp="${1:-}"
  local cand_fp
  cand_fp=$(printf '%s\n' "${raw_fp}" | LC_ALL=C awk 'NR==1 {print $2}' 2>/dev/null || true)
  if [[ ! "${cand_fp}" =~ ^SHA256:[A-Za-z0-9+/=]+$ ]]; then
    return 1
  fi
  printf '%s' "${cand_fp}"
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

# 退避・復元ディレクトリ内の認証情報・Git 署名鍵を検証する。
# 成功時は AUTH_VALIDATED_ITEMS（相対パス配列）と AUTH_VALIDATED_LABELS（表示用ラベル配列）を設定して 0 を返す。
AUTH_VALIDATED_ITEMS=()
AUTH_VALIDATED_LABELS=()
validate_auth_backup_items() {
  local dir="${1:?}"
  local context="${2:-退避先}"
  AUTH_VALIDATED_ITEMS=()
  AUTH_VALIDATED_LABELS=()

  local sub
  for sub in .ssh .config .config/gh .copilot; do
    if [ -L "${dir}/${sub}" ]; then
      echo >&2 "エラー: ${context}の ${dir}/${sub} がシンボリックリンクのため処理できません"
      return 1
    fi
  done

  # 1. 署名鍵の検証（非対話署名用のため、パスフレーズ保護や破損した秘密鍵はエラーにする）
  if [ -e "${dir}/.ssh/id_ed25519_signing" ] || [ -L "${dir}/.ssh/id_ed25519_signing" ] || \
     [ -e "${dir}/.ssh/id_ed25519_signing.pub" ] || [ -L "${dir}/.ssh/id_ed25519_signing.pub" ]; then
    if [ -L "${dir}/.ssh/id_ed25519_signing" ] || [ -L "${dir}/.ssh/id_ed25519_signing.pub" ]; then
      echo >&2 "エラー: ${context}の署名鍵にシンボリックリンクが含まれています: ${dir}/.ssh"
      return 1
    fi
    if [ ! -f "${dir}/.ssh/id_ed25519_signing" ] || [ ! -s "${dir}/.ssh/id_ed25519_signing" ] || \
       [ ! -r "${dir}/.ssh/id_ed25519_signing" ]; then
      echo >&2 "エラー: ${context}の秘密鍵 ~/.ssh/id_ed25519_signing が欠落しているか読み取れません"
      return 1
    fi
    if [ ! -f "${dir}/.ssh/id_ed25519_signing.pub" ] || [ ! -s "${dir}/.ssh/id_ed25519_signing.pub" ] || \
       [ ! -r "${dir}/.ssh/id_ed25519_signing.pub" ]; then
      echo >&2 "エラー: ${context}の公開鍵 ~/.ssh/id_ed25519_signing.pub が欠落しているか読み取れません"
      return 1
    fi
    local key_fp derived_pub actual_pub derived_key
    if ! key_fp=$(ssh-keygen -lf "${dir}/.ssh/id_ed25519_signing.pub" 2>/dev/null); then
      echo >&2 "エラー: ${context}の公開鍵 ~/.ssh/id_ed25519_signing.pub の形式が不正です"
      return 1
    fi
    if ! derived_pub=$(ssh-keygen -y -P '' -f "${dir}/.ssh/id_ed25519_signing" 2>&1); then
      echo >&2 "エラー: ${context}の秘密鍵 ~/.ssh/id_ed25519_signing がパスフレーズで保護されているか破損しています"
      return 1
    fi
    actual_pub=$(awk '{print $1, $2}' "${dir}/.ssh/id_ed25519_signing.pub") || return $?
    derived_key=$(printf '%s\n' "${derived_pub}" | awk '{print $1, $2}') || return $?
    if [ -z "${derived_key}" ] || [ "${derived_key}" != "${actual_pub}" ]; then
      echo >&2 "エラー: ${context}の署名鍵の秘密鍵と公開鍵が一致しません"
      return 1
    fi
    AUTH_VALIDATED_ITEMS+=(.ssh/id_ed25519_signing .ssh/id_ed25519_signing.pub)
    # shellcheck disable=SC2088
    AUTH_VALIDATED_LABELS+=("~/.ssh/id_ed25519_signing, ~/.ssh/id_ed25519_signing.pub (${key_fp})")
  fi

  # 2. GitHub CLI 設定の検証
  if [ -d "${dir}/.config/gh" ]; then
    local gh_invalid gh_valid
    gh_invalid=$(find "${dir}/.config/gh" \( ! -type f ! -type d \) -print -quit) || return $?
    if [ -n "${gh_invalid}" ]; then
      echo >&2 "エラー: ${context}の ~/.config/gh にシンボリックリンクまたは特殊ファイルが含まれています"
      return 1
    fi
    gh_valid=$(find "${dir}/.config/gh" -type f -size +0c -print -quit) || return $?
    if [ -z "${gh_valid}" ]; then
      echo >&2 "エラー: ${context}の ~/.config/gh に有効なファイルがありません"
      return 1
    fi
    AUTH_VALIDATED_ITEMS+=(.config/gh)
    # shellcheck disable=SC2088
    AUTH_VALIDATED_LABELS+=("~/.config/gh")
  fi

  # 3. GitHub Copilot CLI 設定の検証
  if [ -e "${dir}/.copilot/config.json" ] || [ -L "${dir}/.copilot/config.json" ]; then
    if [ -L "${dir}/.copilot/config.json" ]; then
      echo >&2 "エラー: ${context}の ~/.copilot/config.json がシンボリックリンクです"
      return 1
    fi
    if [ ! -f "${dir}/.copilot/config.json" ] || [ ! -s "${dir}/.copilot/config.json" ] || \
       [ ! -r "${dir}/.copilot/config.json" ]; then
      echo >&2 "エラー: ${context}の ~/.copilot/config.json が空または読み取り不可です"
      return 1
    fi
    # shellcheck disable=SC2034
    AUTH_VALIDATED_ITEMS+=(.copilot/config.json)
    # shellcheck disable=SC2034,SC2088
    AUTH_VALIDATED_LABELS+=("~/.copilot/config.json")
  fi

  if [ "${#AUTH_VALIDATED_ITEMS[@]}" -eq 0 ]; then
    echo >&2 "エラー: ${context}に有効な認証情報や署名鍵が見つかりません: ${dir}"
    return 1
  fi
}
