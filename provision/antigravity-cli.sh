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
set -eux -o pipefail

if [ -x "${HOME}/.local/bin/agy" ]; then
  exit 0
fi

curl -fsSL --compressed https://antigravity.google/cli/install.sh | bash
