#!/bin/bash
# VM の前提をまとめたコーディングエージェント向けの指示ファイルを配置する（mode: user / 通常ユーザで実行）
#
# 配置先:
# - GitHub Copilot CLI: ~/.copilot/copilot-instructions.md（マーカーコメントで囲んだブロックとして管理）
# - Antigravity CLI:    ~/.gemini/config/rules/lima-coding-sandbox.md（trigger: always_on のルールファイル）
#
# - param の agentInstructions の既定値は "false"（配置しない）。"true" のときだけ配置する
# - "false" のときは、このスクリプトが配置したファイル・ブロックを削除する（利用者が書いた内容は残す）
# - Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある
set -eux -o pipefail

copilot_file="${HOME}/.copilot/copilot-instructions.md"
agy_file="${HOME}/.gemini/config/rules/lima-coding-sandbox.md"
begin_marker="<!-- BEGIN lima-coding-sandbox agent-instructions -->"
end_marker="<!-- END lima-coding-sandbox agent-instructions -->"
agy_marker="<!-- lima-coding-sandbox の provision/agent-instructions.sh が作成したファイル"

# 一時ファイルのクリーンアップ
tmp_files=()
cleanup() {
  if [ "${#tmp_files[@]}" -gt 0 ]; then
    for f in "${tmp_files[@]}"; do
      rm -f "${f}"
    done
  fi
}
trap cleanup EXIT

TMP_FILE=""
mktemp_tracked() {
  TMP_FILE=$(mktemp)
  tmp_files+=("${TMP_FILE}")
}

# ファイルへの書き込み（シンボリックリンクの場合は参照先を更新し、リンクを壊さない）
safe_write_file() {
  local src=$1 dst=$2
  if [ -L "${dst}" ]; then
    cat "${src}" > "${dst}"
  else
    install -m 0755 -d "$(dirname "${dst}")"
    install -m 0644 "${src}" "${dst}"
  fi
}

# マーカーコメントの整合性を検証する（0 組、または 1 組で begin < end の場合のみ 0 を返す）
validate_markers() {
  local file=$1
  local b_count e_count
  b_count=$(grep -c -Fx "${begin_marker}" "${file}" || true)
  e_count=$(grep -c -Fx "${end_marker}" "${file}" || true)
  if [ "${b_count}" -eq 0 ] && [ "${e_count}" -eq 0 ]; then
    return 0
  fi
  if [ "${b_count}" -eq 1 ] && [ "${e_count}" -eq 1 ]; then
    local b_line e_line
    b_line=$(grep -n -Fx "${begin_marker}" "${file}" | cut -d: -f1)
    e_line=$(grep -n -Fx "${end_marker}" "${file}" | cut -d: -f1)
    if [ "${b_line}" -lt "${e_line}" ]; then
      return 0
    fi
  fi
  return 1
}

# ファイルから管理ブロック（begin_marker 〜 end_marker）を取り除き、末尾の余分な空行を整理した内容を出力する
strip_managed_block() {
  awk -v begin="${begin_marker}" -v end="${end_marker}" '
    $0 == begin { in_block = 1; next }
    $0 == end   { in_block = 0; next }
    !in_block   { print }
  ' "$1" | awk '/[^[:space:]]/ { last = NR } { lines[NR] = $0 } END { for (i = 1; i <= last; i++) print lines[i] }'
}

case "${PARAM_agentInstructions:-false}" in
true) ;;
false)
  # Antigravity: 本スクリプトが作成したファイルであることを確認してから削除する（利用者の独自ファイルを保護）
  if [ -f "${agy_file}" ]; then
    if grep -qF "${agy_marker}" "${agy_file}"; then
      rm -f "${agy_file}"
    else
      echo >&2 "warning: ${agy_file} was not created by this script; skipping removal"
    fi
  fi

  # Copilot: マーカーブロックのみ削除し、利用者の指示を保持する
  if [ -f "${copilot_file}" ]; then
    if ! validate_markers "${copilot_file}"; then
      echo >&2 "warning: ${copilot_file} has unmatched marker comments; skipping removal to prevent data loss"
      exit 0
    fi
    if grep -qFx "${begin_marker}" "${copilot_file}"; then
      mktemp_tracked
      out="${TMP_FILE}"
      strip_managed_block "${copilot_file}" >"${out}"
      if grep -q '[^[:space:]]' "${out}"; then
        if ! cmp -s "${out}" "${copilot_file}"; then
          safe_write_file "${out}" "${copilot_file}"
        fi
      else
        if [ -L "${copilot_file}" ]; then
          : > "${copilot_file}"
        else
          rm -f "${copilot_file}"
        fi
      fi
    fi
  fi
  exit 0
  ;;
*)
  echo >&2 "error: param agentInstructions must be \"true\" or \"false\": ${PARAM_agentInstructions}"
  exit 1
  ;;
esac

if [ "${PARAM_blockHostLoopback:-true}" = false ]; then
  loopback_note="- \`host.lima.internal\` はホスト（macOS）の \`127.0.0.1\` につながっています（このインスタンスでは遮断が無効化されています）。指示されていない限り接続しないでください"
else
  loopback_note="- VM（Docker のコンテナを含む）から \`host.lima.internal\`（ホストの \`127.0.0.1\`）への接続は、VM 内の nftables（テーブル \`inet lima_coding_sandbox\`）で遮断されています。このファイアウォール設定を変更・削除しないでください"
fi

body=$(cat <<EOF
# lima-coding-sandbox 環境の前提

この環境は Lima で動いているコーディングエージェント用のサンドボックス VM（Ubuntu 26.04 LTS）です。作業時は以下の前提に従ってください。

## ファイルシステムと権限
- ホスト（macOS）のディレクトリはマウントされていません。VM 内のファイルシステム上で作業してください
- 通常ユーザはパスワードなしで \`sudo\` を実行できます（必要なシステムパッケージは \`sudo apt-get update && sudo apt-get install -y <パッケージ>\` で導入できます）

## Docker
- \`docker\` および \`docker compose\` は \`sudo\` なしでそのまま実行できます
- ただし \`/usr/local/bin/docker\` は内部で \`sudo -n /usr/bin/docker\` を実行するラッパーであるため、呼び出し元の環境変数（\`FOO=bar docker compose up\` など）や \`HOME\` は引き継がれません
  - Docker Compose に環境変数を渡すときは、カレントディレクトリの \`.env\` ファイルに書くか、コマンドのオプション（\`--env-file\` や \`docker run -e\` など）で渡してください
  - Docker の設定・認証情報は \`/root/.docker\` に保存・参照されます

## 言語ランタイムとパッケージ管理（mise / Python / Node.js）
- \`mise\` の shims（\`~/.local/share/mise/shims\`）が \`PATH\` の先頭に入っています。\`mise.toml\` や \`.tool-versions\` があるディレクトリでは \`mise exec\` を使わなくても自動でそのバージョンのツールが使われます
  - 新しく clone したプロジェクトなどでツールの shim がまだ無い場合は、\`mise install\`（環境変数設定などを含む \`mise.toml\` では先に \`mise trust\`）を実行してください
- システムの Python に \`pip3 install\` で直接パッケージを入れることはできません（\`externally-managed-environment\` エラーになります）。\`python3 -m venv\` で仮想環境を作って使うか、CLI ツールは \`pipx install\` で入れてください
- システムの Node.js で \`npm install -g\` をそのまま実行すると \`/usr/local\` への権限エラー（\`EACCES\`）になります。\`npx\` を使うか、\`mise\` で管理する Node.js を使うか、\`npm config set prefix ~/.local\` を設定してください

## ネットワークとブラウザ
- VM 内に Web ブラウザはありません
- VM 内で listen したポートは、ホストの \`127.0.0.1\` に**自動では転送されません**。開発サーバなどをホストのブラウザで確認してもらう必要があるときは、ホスト側で \`make forward PORT=<ポート番号>\` を実行するよう利用者に案内してください
${loopback_note}

## Git と GitHub
- Git のコミットとタグは SSH 鍵（\`~/.ssh/id_ed25519_signing\`）で自動的に署名されます
- \`git push\` や \`gh\` コマンド（Issue・Pull Request の作成やコメント、マージなど）は利用者の GitHub アカウントの権限で行われます。利用者の明示的な指示がある範囲に限って実行してください
EOF
)

# Antigravity CLI: ~/.gemini/config/rules/lima-coding-sandbox.md
if [ -f "${agy_file}" ] && ! grep -qF "${agy_marker}" "${agy_file}"; then
  echo >&2 "warning: ${agy_file} exists and was not created by this script; skipping overwrite to preserve custom rules"
else
  mktemp_tracked
  out="${TMP_FILE}"
  cat >"${out}" <<EOF
---
trigger: always_on
description: lima-coding-sandbox VM environment premises and constraints
---

${agy_marker}（起動のたびに上書きされる） -->

${body}
EOF
  if ! cmp -s "${out}" "${agy_file}"; then
    safe_write_file "${out}" "${agy_file}"
  fi
fi

# GitHub Copilot CLI: ~/.copilot/copilot-instructions.md（マーカーブロックのみ更新）
block=$(cat <<EOF
${begin_marker}
<!-- lima-coding-sandbox の provision/agent-instructions.sh が管理するブロック（起動のたびに更新される。独自の指示はこのブロックの外に書くこと） -->

${body}
${end_marker}
EOF
)

if [ -f "${copilot_file}" ]; then
  if ! validate_markers "${copilot_file}"; then
    echo >&2 "warning: ${copilot_file} has unmatched marker comments; skipping update to prevent data loss"
    exit 0
  fi
  mktemp_tracked
  stripped="${TMP_FILE}"
  strip_managed_block "${copilot_file}" >"${stripped}"
  mktemp_tracked
  out="${TMP_FILE}"
  if grep -q '[^[:space:]]' "${stripped}"; then
    cat "${stripped}" >"${out}"
    printf '\n\n%s\n' "${block}" >>"${out}"
  else
    printf '%s\n' "${block}" >"${out}"
  fi
else
  mktemp_tracked
  out="${TMP_FILE}"
  printf '%s\n' "${block}" >"${out}"
fi
if ! cmp -s "${out}" "${copilot_file}"; then
  safe_write_file "${out}" "${copilot_file}"
fi
