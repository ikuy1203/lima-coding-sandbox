#!/bin/bash
# mise をインストールする（mode: user / 通常ユーザで実行）
#
# 公式手順: https://mise.jdx.dev/installing-mise.html
# インストール先: ~/.local/bin/mise（以後の更新は `mise self-update`）
#
# 本体は https://mise.run で入れる（シェルの設定ファイルは書き換えない）。
# bash 用の https://mise.run/bash は ~/.bashrc に `mise activate bash` を追記するため使わない。
#
# activate ではなく shims（~/.local/share/mise/shims）を使う。activate はプロンプトの表示時にしか
# PATH を切り替えず、しかも実ツールのディレクトリを PATH の先頭に置く。そのため、対話シェルから起動した
# エージェントが実行する bash -c などでは、cd しても起動時のバージョンが使われてしまう。
# shims は実行のたびにカレントディレクトリの mise.toml / .tool-versions を読んでバージョンを決めるので、
# 非対話のシェルでも mise exec なしで正しいバージョンが使われる。
#
# shims は ~/.profile で PATH の先頭に追加する（目印のコメント付きで、追記済みなら追記しない）。
# limactl shell はコマンドを指定したときもログインシェルを起動するため、~/.profile が読まれる。
# ~/.local/bin を PATH に追加しているのも ~/.profile なので、エージェントが動く環境には必ず入る。
set -eux -o pipefail

if [ ! -x "${HOME}/.local/bin/mise" ]; then
  curl -fsSL https://mise.run | sh
fi

marker="# added by lima-coding-sandbox provision/mise.sh"
if ! grep -qF "${marker}" "${HOME}/.profile" 2>/dev/null; then
  # $HOME / $PATH はログイン時に展開させる
  cat >>"${HOME}/.profile" <<EOF

${marker}: mise の shims を PATH の先頭に追加する
PATH="\${HOME}/.local/share/mise/shims:\${PATH}"
export PATH
EOF
fi
