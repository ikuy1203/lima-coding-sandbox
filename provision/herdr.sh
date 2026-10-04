#!/bin/bash
# herdr をインストールする（mode: user / 通常ユーザで実行）
#
# 公式手順: https://herdr.dev/docs/install/
# インストール先: ~/.local/bin/herdr（以後の更新は `herdr update`）
set -eux -o pipefail

if [ -x "${HOME}/.local/bin/herdr" ]; then
  exit 0
fi

curl -fsSL https://herdr.dev/install.sh | sh
