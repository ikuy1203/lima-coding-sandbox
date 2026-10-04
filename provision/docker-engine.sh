#!/bin/bash
# Docker Engine をインストールする（mode: system / root で実行）
#
# 公式手順: https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
#
# 非対話で実行するため、ドキュメントの apt コマンドは apt-get -y に置き換えている。
# インストールすると Docker のサービスは自動で起動・有効化される（Ubuntu の既定）。
# 通常ユーザは docker グループに追加しないため、Docker は `sudo docker` で使う。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

all_installed() {
  local package
  for package in "${docker_packages[@]}"; do
    # shellcheck disable=SC2016
    [ "$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null)" = installed ] || return 1
  done
}

# すべてインストール済みなら何もしない。途中で失敗していた場合は、手順を最初からやり直す。
if all_installed; then
  exit 0
fi

# 競合する非公式パッケージを削除する
conflicting_packages=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1 || true)
if [ -n "${conflicting_packages}" ]; then
  # shellcheck disable=SC2086
  apt-get remove -y ${conflicting_packages}
fi

# Docker の apt リポジトリを登録する
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
# shellcheck disable=SC1091
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update

# Docker Engine をインストールする
apt-get install -y "${docker_packages[@]}"
