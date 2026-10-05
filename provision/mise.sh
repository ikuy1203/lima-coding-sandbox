#!/bin/bash
# mise をインストールする（mode: user / 通常ユーザで実行）
#
# 公式手順: https://mise.jdx.dev/installing-mise.html
# インストール先: ~/.local/bin/mise（以後の更新は `mise self-update`）
#
# bash 用の install スクリプト（https://mise.run/bash）を使う。mise 本体を入れたうえで、
# ~/.bashrc に `eval "$(~/.local/bin/mise activate bash)"` を追記する（目印のコメント付きで、
# 追記済みなら追記しない）。
#
# activate は対話シェルのプロンプトのたびに PATH を切り替える仕組みで、非対話のシェル（エージェントが
# 実行する bash -c など）では切り替わらない。その場合は `mise exec -- <コマンド>` を使う（README.md を参照）。
set -eux -o pipefail

# 本体の取得後、~/.bashrc への追記の前に失敗したときもやり直せるよう、両方を確認する
if [ -x "${HOME}/.local/bin/mise" ] && grep -qF "# added by https://mise.run/bash" "${HOME}/.bashrc" 2>/dev/null; then
  exit 0
fi

curl -fsSL https://mise.run/bash | sh
