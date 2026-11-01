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
if [ ! -s "${key}" ]; then
  install -m 0700 -d "${HOME}/.ssh"
  rm -f "${key}" "${key}.pub"
  ssh-keygen -t ed25519 -N '' -C "git-signing ${USER}@$(hostname)" -f "${key}"
elif [ ! -s "${key}.pub" ]; then
  ssh-keygen -y -P '' -f "${key}" > "${key}.pub"
  chmod 0644 "${key}.pub"
fi

# SSH 鍵でコミットとタグに署名する
# 既存の署名設定（GPG 鍵、署名形式、鍵選択コマンドなど）がある場合は上書き・変更しない
if ! git config --includes --global --get user.signingkey >/dev/null && \
   ! git config --includes --global --get gpg.format >/dev/null && \
   ! git config --includes --global --get gpg.ssh.defaultKeyCommand >/dev/null; then
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

if [ -n "${configured_email}" ] && [ "${gpg_format}" = "ssh" ] && [ "${signing_key}" = "${key}" ] && [ -s "${key}.pub" ]; then
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
    entry="${configured_email} namespaces=\"git\" ${key_pattern}"
    if ! grep -qF "${entry}" "${allowed_signers}"; then
      printf '%s\n' "${entry}" >>"${allowed_signers}"
    fi
    set_if_unset gpg.ssh.allowedSignersFile "${allowed_signers}"
  fi
fi

# Git の署名設定および実動作を診断する
diagnose_git_signing() {
  local commit_sign default_key_cmd
  commit_sign=$(git config --includes --global --type=bool --get commit.gpgsign 2>/dev/null || echo "false")
  default_key_cmd=$(git config --includes --global --get gpg.ssh.defaultKeyCommand 2>/dev/null || true)
  local current_signing_key current_gpg_format
  current_signing_key=$(git config --includes --global --get user.signingkey 2>/dev/null || true)
  current_signing_key="${current_signing_key/#\~/$HOME}"
  current_gpg_format=$(git config --includes --global --get gpg.format 2>/dev/null || echo "openpgp")

  # 1. 署名が有効化されていない（未設定、明示的 false/no/0 等）場合は尊重する
  if [ "${commit_sign}" != "true" ]; then
    echo "notice: Git commit signing is not enabled (commit.gpgsign=${commit_sign}); skipping signature verification"
    return 0
  fi

  # 2. 独自の署名設定がある場合は尊重する
  if [ -n "${default_key_cmd}" ] || [ "${current_signing_key}" != "${key}" ] || [ "${current_gpg_format}" != "ssh" ]; then
    echo "notice: Custom Git signing configuration detected (format: ${current_gpg_format}, signingkey: ${current_signing_key}); preserving user configuration"
    return 0
  fi

  # 3. テンプレート作成の SSH 署名鍵の整合性確認
  if [ ! -s "${key}" ]; then
    echo >&2 "error: signing key ${key} is missing or empty"
    return 1
  fi
  if [ ! -s "${key}.pub" ]; then
    echo >&2 "error: signing public key ${key}.pub is missing or empty"
    return 1
  fi

  local derived_pub actual_pub
  if ! derived_pub=$(ssh-keygen -y -P '' -f "${key}" 2>&1); then
    case "${derived_pub}" in
      *[Pp]assphrase*|*[Ii]ncorrect*)
        echo "notice: Git signing key is protected by passphrase; skipping non-interactive signature verification"
        return 0
        ;;
      *)
        echo >&2 "error: failed to read public key from private key ${key}: ${derived_pub}"
        return 1
        ;;
    esac
  fi
  actual_pub=$(awk '{print $1, $2}' "${key}.pub")
  derived_pub=$(echo "${derived_pub}" | awk '{print $1, $2}')
  if [ -z "${derived_pub}" ] || [ "${derived_pub}" != "${actual_pub}" ]; then
    echo >&2 "error: public key ${key}.pub does not match private key ${key}"
    return 1
  fi

  # 4. 一時リポジトリでの署名・検証
  local diag_dir
  diag_dir=$(mktemp -d)
  cleanup_diag() {
    rm -rf "${diag_dir}"
  }

  local rc=0
  if ! run_diag_test "${diag_dir}" "${actual_pub}"; then
    rc=1
  fi
  cleanup_diag
  return "${rc}"
}

run_diag_test() {
  local td="$1"
  local pub="$2"
  git init -q "${td}"

  local configured_name configured_email
  configured_name=$(git config --includes --global --get user.name 2>/dev/null || true)
  configured_email=$(git config --includes --global --get user.email 2>/dev/null || true)

  if [ -z "${configured_name}" ] || [ -z "${configured_email}" ]; then
    # PARAM_* が指定されていたのに空なら設定エラー
    if [ -n "${PARAM_gitUserName:-}" ] || [ -n "${PARAM_gitUserEmail:-}" ]; then
      echo >&2 "error: Git user identity was specified in param but not configured properly"
      return 1
    fi

    # 未指定の場合は検証用ローカル設定で署名機構自体の正常性をテスト
    local test_signers="${td}/allowed_signers"
    printf 'diagnostic@example.com namespaces="git" %s\n' "${pub}" > "${test_signers}"
    git -C "${td}" config user.name "Diagnostic User"
    git -C "${td}" config user.email "diagnostic@example.com"
    git -C "${td}" config gpg.format ssh
    git -C "${td}" config user.signingkey "${key}"
    git -C "${td}" config commit.gpgsign true
    git -C "${td}" config gpg.ssh.allowedSignersFile "${test_signers}"

    if ! timeout -k 3 10 git -C "${td}" -c core.hooksPath=/dev/null commit -q --allow-empty --no-verify -m "diagnostic commit" 2>&1; then
      echo >&2 "error: Git commit signing verification failed in temporary repository"
      return 1
    fi
    if ! timeout -k 3 10 git -C "${td}" verify-commit HEAD >/dev/null 2>&1; then
      echo >&2 "error: Git signature verification failed in temporary repository"
      return 1
    fi

    echo >&2 "notice: Git commit signing mechanism is verified, but user identity is not configured yet."
    echo >&2 "        Please configure your name and email inside the VM (see README.md):"
    if [ -z "${configured_name}" ]; then
      echo >&2 "          git config --global user.name \"<Your Name>\""
    fi
    if [ -z "${configured_email}" ]; then
      echo >&2 "          git config --global user.email \"<your.email@example.com>\""
    fi
    return 0
  fi

  # 名前とメールアドレスが設定済みの場合はグローバル設定で署名・検証
  if ! timeout -k 3 10 git -C "${td}" -c core.hooksPath=/dev/null commit -q --allow-empty --no-verify -m "diagnostic commit" 2>&1; then
    echo >&2 "error: Git commit signing failed with global settings"
    return 1
  fi
  if ! timeout -k 3 10 git -C "${td}" verify-commit HEAD >/dev/null 2>&1; then
    echo >&2 "error: Git signature verification failed with global settings"
    return 1
  fi

  return 0
}

diagnose_git_signing
