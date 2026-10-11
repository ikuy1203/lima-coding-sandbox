#!/bin/bash
# Docker Engine をインストールする（mode: system / root で実行）
#
# 公式手順: https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
#
# 非対話で実行するため、ドキュメントの apt コマンドは apt-get -y に置き換えている。
# インストールすると Docker のサービスは自動で起動・有効化される（Ubuntu の既定）。
# エージェントや通常ユーザが sudo を意識せずに使えるよう、/usr/local/bin/docker にラッパーを配置する。
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

# パッケージがすべてインストール済みでなければインストールする（起動のたびに apt-get update しない）
if ! all_installed; then
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
fi

# エージェントや通常ユーザが sudo を意識せずに Docker を利用できるよう、
# パスワードなし sudo を透過実行するラッパースクリプトを /usr/local/bin/docker に配置する
wrapper=/usr/local/bin/docker
out=$(mktemp)
cat >"${out}" <<'EOF'
#!/bin/sh
exec sudo -n /usr/bin/docker "$@"
EOF
install -m 0755 "${out}" "${wrapper}"
rm -f "${out}"
