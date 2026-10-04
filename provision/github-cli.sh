#!/bin/bash
# GitHub CLI (gh) をインストールする（mode: system / root で実行）
#
# 公式手順: https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian
#
# Ubuntu のリポジトリ（universe）の gh は 2.46 で、廃止された GitHub の API を使っているため動かないと
# 公式に案内されている。そのため GitHub CLI の apt リポジトリを登録して入れる。
#
# root で実行するため公式のコマンドから sudo を外し、非対話で実行するため apt は apt-get -y に置き換えている。
# ディレクトリの作成は、shellcheck の警告（SC2174）を避けるため mkdir -p -m 755 を install -m 0755 -d に置き換えている。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

# shellcheck disable=SC2016
if [ "$(dpkg-query -W -f='${db:Status-Status}' gh 2>/dev/null)" = installed ]; then
  exit 0
fi

if ! type -p wget >/dev/null; then
  apt-get update
  apt-get install -y wget
fi

# GitHub CLI の apt リポジトリを登録する
# 鍵は一時ファイルに取得し、取得に成功してから置く（途中で失敗しても壊れた鍵を残さない）
install -m 0755 -d /etc/apt/keyrings
out=$(mktemp)
wget -nv -O"${out}" https://cli.github.com/packages/githubcli-archive-keyring.gpg
install -m 0644 "${out}" /etc/apt/keyrings/githubcli-archive-keyring.gpg
rm -f "${out}"
install -m 0755 -d /etc/apt/sources.list.d
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" >/etc/apt/sources.list.d/github-cli.list
apt-get update

apt-get install -y gh
