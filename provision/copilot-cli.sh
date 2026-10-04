#!/bin/bash
# GitHub Copilot CLI をインストールする（mode: user / 通常ユーザで実行）
#
# 公式手順: https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli
# install スクリプト方式を使う（npm 方式とは異なり Node.js が不要）。
# root 以外で実行すると、インストール先は ~/.local/bin/copilot になる。
set -eux -o pipefail

if [ -x "${HOME}/.local/bin/copilot" ]; then
  exit 0
fi

curl -fsSL https://gh.io/copilot-install | bash
