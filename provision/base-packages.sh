#!/bin/bash
# 基本的なツールを Ubuntu のリポジトリからインストールする（mode: system / root で実行）
#
# git や jq などイメージに同梱されているものも、イメージが変わっても確実に入るように明記している。
# gh は Ubuntu のリポジトリの版が動かないため、ここではなく provision/github-cli.sh で入れる。
#
# パッケージを削除したときは、coding-sandbox.yaml の probe（basic tools ...）のコマンド一覧も直すこと。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

base_packages=(
  # イメージに同梱されているが、明示しておく
  ca-certificates curl wget git jq less openssh-client
  # gcc / g++ / make
  build-essential
  # 検索・ファイル操作（fd-find のコマンド名は fdfind）
  ripgrep fd-find unzip zip tree
  # シェルスクリプトの検査
  shellcheck
  # Python（python3 -m venv / pip3 / pipx）
  python3-venv python3-pip pipx
  # Node.js（node / npm / npx）
  nodejs npm
)

all_installed() {
  local package
  for package in "${base_packages[@]}"; do
    # shellcheck disable=SC2016
    [ "$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null)" = installed ] || return 1
  done
}

# すべてインストール済みなら何もしない（起動のたびに apt-get update しない）
if all_installed; then
  exit 0
fi

apt-get update
apt-get install -y "${base_packages[@]}"
