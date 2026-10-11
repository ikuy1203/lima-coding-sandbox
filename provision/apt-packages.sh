#!/bin/bash
# apt パッケージをまとめてインストールする（mode: system / root で実行）
#
# 公式手順との差異:
# - GitHub CLI や Docker Engine などの各ソフトウェアの公式手順では、それぞれ個別に `apt update && apt install ...`
#   を実行するよう案内されている。
# - しかし、各スクリプトで個別に実行すると初回 VM 作成時に apt-get update が計 6 回実行され、
#   起動時間が大幅に延びてしまう。
# - そのため本環境では、サードパーティリポジトリの登録（provision/github-cli.sh, provision/docker-engine.sh）を
#   先行させ、このスクリプトで apt-get update と全 apt パッケージのインストールを 1 回に集約している。
# - サードパーティリポジトリの登録やインデックス取得に失敗している場合は、Ubuntu リポジトリに存在する古いパッケージ
#   （廃止 API を使っていて動かない Ubuntu 版 gh など）が誤ってインストールされないよう、
#   公式リポジトリの候補が利用可能な場合のみインストール対象に含める。
# - 一時的な外部リポジトリ障害（cli.github.com や download.docker.com への一時的な接続不能など）が発生しても、
#   基本的なツールや他の健全なソフトウェアのインストールが巻き添えで全て中断しないよう、
#   一括インストール失敗時にはソフトウェアグループごとのフォールバックインストールを行う。
#   フォールバックにより必要な全パッケージが揃った場合は正常終了する。
#
# パッケージを削除・変更したときは、coding-sandbox.yaml の probe（basic tools ...）のコマンド一覧も直すこと。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

export DEBIAN_FRONTEND=noninteractive

# 基本的なツール（Ubuntu のリポジトリ）
base_packages=(
  # イメージに同梱されているが、明示しておく
  ca-certificates curl wget git jq less openssh-client
  # gcc / g++ / make
  build-essential
  # 検索・ファイル操作（fd-find のコマンド名は fdfind。fd のシンボリックリンクを自動作成する）
  ripgrep fd-find unzip zip tree
  # シェルスクリプトの検査
  shellcheck
  # ファイアウォール（provision/host-loopback-firewall.sh で使う nft コマンド）
  nftables
  # Python（python3 -m venv / pip3 / pipx）
  python3-venv python3-pip pipx
  # Node.js（node / npm / npx）
  nodejs npm
)

# 音声再生ツール（Ubuntu のリポジトリ。デバイス設定は provision/audio.sh で行う）
audio_packages=(alsa-utils mpg123)

# GitHub CLI（provision/github-cli.sh で登録した cli.github.com のリポジトリ）
github_cli_packages=(gh)

# Docker Engine（provision/docker-engine.sh で登録した download.docker.com のリポジトリ）
docker_packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)

# 導入されるべき全パッケージ
expected_packages=(
  "${base_packages[@]}"
  "${audio_packages[@]}"
  "${github_cli_packages[@]}"
  "${docker_packages[@]}"
)

all_installed() {
  local package
  for package in "${expected_packages[@]}"; do
    # shellcheck disable=SC2016
    [ "$(dpkg-query -W -f='${db:Status-Status}' "${package}" 2>/dev/null)" = installed ] || return 1
  done
}

is_official_gh_available() {
  [ -f /etc/apt/sources.list.d/github-cli.list ] || return 1
  # 公式リポジトリのインデックスが取得できているか確認する。
  # 取得失敗時に Ubuntu 標準（universe）にある廃止 API を使う古い gh が
  # 誤ってインストールされるのを防ぐため、最新バージョン候補が cli.github.com 由来であることを確認する。
  # set -o pipefail の下で上流プロセスが SIGPIPE（終了コード 141）にならないよう、awk で入力を最後まで消費する
  apt-cache madison gh 2>/dev/null | awk 'NR==1 && /cli\.github\.com/ { found=1 } END { exit !found }'
}

is_official_docker_available() {
  [ -f /etc/apt/sources.list.d/docker.sources ] || return 1
  # docker-ce の公式インデックスが取得できているか確認する（同様に入力を最後まで消費する）
  apt-cache madison docker-ce 2>/dev/null | awk '/download\.docker\.com/ { found=1 } END { exit !found }'
}

# パッケージがすべてインストール済みでなければインストールする（起動のたびに apt-get update しない）
if ! all_installed; then
  # 一部の外部リポジトリに一時的に接続できなくても、取得できたインデックスでインストールを試みる
  apt-get update || true

  # 公式リポジトリが未登録またはインデックス取得に失敗している場合は、Ubuntu 側の古いパッケージ
  # （動かない gh など）が誤って入らないよう、公式のインデックスが有効な場合のみ対象に含める
  target_packages=("${base_packages[@]}" "${audio_packages[@]}")
  if is_official_gh_available; then
    target_packages+=("${github_cli_packages[@]}")
  else
    echo >&2 "warning: official gh package from cli.github.com not available; skipping gh to avoid installing broken Ubuntu version"
  fi
  if is_official_docker_available; then
    target_packages+=("${docker_packages[@]}")
  else
    echo >&2 "warning: official docker-ce package from download.docker.com not available; skipping docker packages"
  fi

  # 通常は 1 回でまとめてインストールする。失敗したとき（外部リポジトリの一時障害など）は、
  # 他の健全なソフトウェア群を巻き込まないよう、ソフトウェアグループごとに個別インストールを試みる
  if ! apt-get install -y "${target_packages[@]}"; then
    echo >&2 "warning: aggregated package installation failed; attempting group-by-group fallback"
    apt-get install -y "${base_packages[@]}" || true
    apt-get install -y "${audio_packages[@]}" || true
    if is_official_gh_available; then
      apt-get install -y "${github_cli_packages[@]}" || true
    fi
    if is_official_docker_available; then
      apt-get install -y "${docker_packages[@]}" || true
    fi
  fi
fi

# Ubuntu の fd-find はコマンド名が fdfind のため、エージェント等の互換性のために fd のシンボリックリンクを作成する
if command -v fdfind >/dev/null; then
  ln -sf "$(command -v fdfind)" /usr/local/bin/fd
fi

# 期待される全パッケージがインストールできたか最終判定する（フォールバックで復旧できた場合は正常終了する）
if ! all_installed; then
  echo >&2 "error: some packages failed to install"
  exit 1
fi
