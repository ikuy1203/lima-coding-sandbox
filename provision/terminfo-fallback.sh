#!/bin/bash
# ホストのターミナルの terminfo が VM に無いときの代わりを設定する（mode: system / root で実行）
#
# limactl shell は、ホストの $TERM を ssh 経由でそのまま VM に渡す。Ghostty の xterm-ghostty のように
# VM の terminfo データベースに無い値だと、less（git log や man のページャ）が
# 「WARNING: terminal is not fully functional」と表示し、画面の表示も崩れる。
# Ubuntu では xterm-ghostty は ghostty パッケージ（ターミナル本体）にしか含まれず、ncurses-term にも無い。
#
# そこで、ログインシェルが読む /etc/profile.d/ に、$TERM の terminfo が無いときは
# xterm-256color（ncurses-base に含まれる）に置き換えるスクリプトを置く。
# limactl shell は、コマンドを指定したときも含めて、常にログインシェル（$SHELL -l）を起動する。
# ~/.bashrc に書かないのは、~/.bashrc がプロンプトの色を $TERM で決めるより前に置き換えるためと、
# 非対話のシェル（limactl shell <コマンド>）では ~/.bashrc が先頭で return してしまうため。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある（毎回同じ内容で上書きする）。
set -eux -o pipefail

out=$(mktemp)
cat >"${out}" <<'EOF'
# lima-coding-sandbox の provision/terminfo-fallback.sh が作成したファイル（起動のたびに上書きされる）。
# $TERM の terminfo が無いとき（例: Ghostty の xterm-ghostty）は xterm-256color に置き換える
if [ -n "${TERM:-}" ] && ! infocmp "${TERM}" >/dev/null 2>&1; then
  TERM=xterm-256color
  export TERM
fi
EOF
install -m 0644 "${out}" /etc/profile.d/terminfo-fallback.sh
rm -f "${out}"
