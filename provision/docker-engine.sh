#!/bin/bash
# Docker Engine の apt リポジトリを登録し、ラッパーを配置する（mode: system / root で実行）
#
# 公式手順: https://docs.docker.com/engine/install/ubuntu/#install-using-the-repository
#
# 公式手順との差異:
# - apt-get update を 1 回に集約するため、リポジトリ登録後の apt update および Docker Engine パッケージ群
#   （docker-ce 等）のインストールはここでは実行せず、後続の provision/apt-packages.sh でまとめて行う。
#   そのため、このスクリプトは apt-packages.sh より前に実行する（coding-sandbox.yaml の provision の順序）。
# - 公式手順の事前準備にある apt-get update && apt-get install ca-certificates curl は、
#   どちらもイメージに同梱されているため、存在しない場合のみ実行する（不要な apt-get update を防ぐ）。
# - root で実行するため公式のコマンドから sudo を外している。
# - 非対話で実行するため apt は apt-get -y に置き換えている。
# - 公式手順の docker グループ追加方式の代わりに、/usr/local/bin/docker にパスワードなし sudo を透過実行する
#   ラッパースクリプトを配置している（グループ方式だと SSH セッション再接続まで反映されないため。README を参照）。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

keyring=/etc/apt/keyrings/docker.asc
sources=/etc/apt/sources.list.d/docker.sources

# 公式 apt リポジトリと鍵が登録済みであればスキップする
if [ ! -f "${keyring}" ] || [ ! -f "${sources}" ]; then
  # 競合する非公式パッケージを削除する
  conflicting_packages=$(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1 || true)
  if [ -n "${conflicting_packages}" ]; then
    # shellcheck disable=SC2086
    apt-get remove -y ${conflicting_packages}
  fi

  # 公式手順の apt-get install ca-certificates curl はイメージに同梱されているため、無いときだけ行う
  if ! command -v curl >/dev/null || [ ! -f /etc/ssl/certs/ca-certificates.crt ]; then
    apt-get update
    apt-get install -y ca-certificates curl
  fi

  # Docker の apt リポジトリを登録する
  # 鍵と sources は一時ファイルに取得・作成し、成功してから置く（途中で失敗しても壊れたファイルを残さない）
  install -m 0755 -d /etc/apt/keyrings
  out_key=$(mktemp)
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o "${out_key}"
  install -m 0644 "${out_key}" "${keyring}"
  rm -f "${out_key}"

  install -m 0755 -d /etc/apt/sources.list.d
  out_src=$(mktemp)
  # shellcheck disable=SC1091
  cat >"${out_src}" <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: ${keyring}
EOF
  install -m 0644 "${out_src}" "${sources}"
  rm -f "${out_src}"
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
