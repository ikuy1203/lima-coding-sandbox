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
