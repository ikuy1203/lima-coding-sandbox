#!/bin/bash
# Git のユーザ名・メールアドレスと、SSH 鍵によるコミット署名を設定する（mode: user / 通常ユーザで実行）
#
# - ユーザ名とメールアドレスは、インスタンスの作成時に --param で渡す（coding-sandbox.yaml の param を参照）。
#   渡されなかったとき（空のとき）は設定しない
# - 署名用の SSH 鍵（ed25519、パスフレーズなし）を ~/.ssh/id_ed25519_signing に作る。
#   エージェントが非対話でコミットできるよう、パスフレーズは付けない
# - コミットとタグに常に署名する。公開鍵を GitHub に Signing Key として登録すると Verified と表示される
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
# VM の中で変えた設定を戻さないよう、すでに設定されている値は上書きしない。
set -eux -o pipefail

key="${HOME}/.ssh/id_ed25519_signing"

# 値が設定されていなければ設定する
set_if_unset() {
  if ! git config --global --get "$1" >/dev/null; then
    git config --global "$1" "$2"
  fi
}

# $PARAM_* は Lima が param から設定する（未指定なら空）
name="${PARAM_gitUserName:-}"
email="${PARAM_gitUserEmail:-}"
if [ -n "${name}" ]; then
  set_if_unset user.name "${name}"
fi
if [ -n "${email}" ]; then
  set_if_unset user.email "${email}"
fi

# 署名用の SSH 鍵を作る（公開鍵だけ欠けている場合は秘密鍵から復元する）
if [ ! -f "${key}" ]; then
  install -m 0700 -d "${HOME}/.ssh"
  ssh-keygen -t ed25519 -N '' -C "git-signing ${USER}@$(hostname)" -f "${key}"
elif [ ! -f "${key}.pub" ]; then
  ssh-keygen -y -f "${key}" > "${key}.pub"
  chmod 0644 "${key}.pub"
fi

# SSH 鍵でコミットとタグに署名する
# 既存の署名設定（GPG 鍵、署名形式、鍵選択コマンドなど）がある場合は上書き・変更しない
if ! git config --global --get user.signingkey >/dev/null && \
   ! git config --global --get gpg.format >/dev/null && \
   ! git config --global --get gpg.ssh.defaultKeyCommand >/dev/null; then
  git config --global gpg.format ssh
  git config --global user.signingkey "${key}"
  set_if_unset commit.gpgsign true
  set_if_unset tag.gpgsign true
fi

# git log --show-signature などで、VM の中でも署名を検証できるようにする。
# このスクリプトが作成した鍵（id_ed25519_signing）を署名に使う場合のみ自動登録する。
# （利用者が独自の署名鍵や設定に変更した場合は、検証ファイルの管理も利用者に任せる）
configured_email=$(git config --global --get user.email || true)
gpg_format=$(git config --global --get gpg.format || echo "openpgp")
signing_key=$(git config --global --get user.signingkey || true)
signing_key="${signing_key/#\~/$HOME}"

if [ -n "${configured_email}" ] && [ "${gpg_format}" = "ssh" ] && [ "${signing_key}" = "${key}" ] && [ -f "${key}.pub" ]; then
  # allowedSignersFile のパスを取得する（設定されていればそれを使い、未設定なら既定値を使う）
  configured_signers=$(git config --global --get gpg.ssh.allowedSignersFile || true)
  if [ -n "${configured_signers}" ]; then
    allowed_signers="${configured_signers/#\~/$HOME}"
  else
    allowed_signers="${HOME}/.config/git/allowed_signers"
  fi

  key_pattern=$(awk '{print $1, $2}' "${key}.pub")
  if [ -n "${key_pattern}" ]; then
    install -m 0755 -d "$(dirname "${allowed_signers}")"
    touch "${allowed_signers}"
    if ! grep -qF "${key_pattern}" "${allowed_signers}"; then
      printf '%s namespaces="git" %s\n' "${configured_email}" "${key_pattern}" >>"${allowed_signers}"
    fi
    set_if_unset gpg.ssh.allowedSignersFile "${allowed_signers}"
  fi
fi
