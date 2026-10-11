#!/bin/bash
# GitHub CLI (gh) の apt リポジトリを登録する（mode: system / root で実行）
#
# 公式手順: https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian
#
# Ubuntu のリポジトリ（universe）の gh は 2.46 で、廃止された GitHub の API を使っているため動かないと
# 公式に案内されている。そのため GitHub CLI の apt リポジトリを登録して入れる。
#
# 公式手順との差異:
# - apt-get update を 1 回に集約するため、公式手順の末尾にある apt update および apt install gh は
#   ここでは実行せず、後続の provision/apt-packages.sh でまとめて行う。
#   そのため、このスクリプトは apt-packages.sh より前に実行する（coding-sandbox.yaml の provision の順序）。
# - root で実行するため公式のコマンドから sudo を外している。
# - 非対話で実行するため apt は apt-get -y に置き換えている。
# - ディレクトリの作成は、shellcheck の警告（SC2174）を避けるため mkdir -p -m 755 を install -m 0755 -d に置き換えている。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
repo_list=/etc/apt/sources.list.d/github-cli.list

# 公式 apt リポジトリと鍵が登録済みであれば終了する
# （gh パッケージの存在判定にすると、万が一の失敗時に誤って入った Ubuntu 版の gh により
# 公式リポジトリの登録が再試行されなくなるため、リポジトリ設定ファイルの有無で判定する）
if [ -f "${keyring}" ] && [ -f "${repo_list}" ]; then
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
install -m 0644 "${out}" "${keyring}"
rm -f "${out}"
install -m 0755 -d /etc/apt/sources.list.d
echo "deb [arch=$(dpkg --print-architecture) signed-by=${keyring}] https://cli.github.com/packages stable main" >"${repo_list}"
