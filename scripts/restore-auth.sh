#!/bin/bash
# ホスト側に退避した認証情報（gh・copilot）と Git コミット署名鍵を検証し、VM 内に復元する
#
# --check が指定されたときは、VM 起動前にホスト側の退避データの存在・整合性検証のみを副作用なしで行う。
# 復元時は VM 内の適切なパーミッションで配置し、Git の allowed_signers 更新・署名検証および gh auth setup-git を行う。
set -eu -o pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?
BACKUP_DIR=$(resolve_auth_backup_dir "${NAME}") || exit $?

if [ ! -e "${BACKUP_DIR}" ]; then
  echo >&2 "エラー: 退避データが見つかりません: ${BACKUP_DIR}（先に make backup-auth を実行してください）"
  exit 1
fi
if [ -L "${BACKUP_DIR}" ] || [ ! -d "${BACKUP_DIR}" ]; then
  echo >&2 "エラー: 退避先が通常のディレクトリではありません: ${BACKUP_DIR}"
  exit 1
fi
if [ ! -O "${BACKUP_DIR}" ]; then
  echo >&2 "エラー: 退避先の所有者が現在のユーザではありません: ${BACKUP_DIR}"
  exit 1
fi

for sub in .ssh .config .config/gh .copilot; do
  if [ -L "${BACKUP_DIR}/${sub}" ]; then
    echo >&2 "エラー: 退避先の ${BACKUP_DIR}/${sub} がシンボリックリンクのため復元できません"
    exit 1
  fi
done

items=()
restored_labels=()

# 1. 署名鍵の事前検証（非対話署名用のため、パスフレーズ保護や破損した秘密鍵はエラーにする）
if [ -e "${BACKUP_DIR}/.ssh/id_ed25519_signing" ] || [ -L "${BACKUP_DIR}/.ssh/id_ed25519_signing" ] || \
   [ -e "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub" ] || [ -L "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub" ]; then
  if [ -L "${BACKUP_DIR}/.ssh/id_ed25519_signing" ] || [ -L "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub" ]; then
    echo >&2 "エラー: 退避先の署名鍵にシンボリックリンクが含まれているため復元できません: ${BACKUP_DIR}/.ssh"
    exit 1
  fi
  if [ ! -f "${BACKUP_DIR}/.ssh/id_ed25519_signing" ] || [ ! -s "${BACKUP_DIR}/.ssh/id_ed25519_signing" ] || \
     [ ! -r "${BACKUP_DIR}/.ssh/id_ed25519_signing" ]; then
    echo >&2 "エラー: 退避先の秘密鍵 ${BACKUP_DIR}/.ssh/id_ed25519_signing が欠落しているか読み取れません"
    exit 1
  fi
  if [ ! -f "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub" ] || [ ! -s "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub" ] || \
     [ ! -r "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub" ]; then
    echo >&2 "エラー: 退避先の公開鍵 ${BACKUP_DIR}/.ssh/id_ed25519_signing.pub が欠落しているか読み取れません"
    exit 1
  fi
  if ! key_fp=$(ssh-keygen -lf "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub" 2>/dev/null); then
    echo >&2 "エラー: 退避先の公開鍵 ${BACKUP_DIR}/.ssh/id_ed25519_signing.pub の形式が不正です"
    exit 1
  fi
  if ! derived_pub=$(ssh-keygen -y -P '' -f "${BACKUP_DIR}/.ssh/id_ed25519_signing" 2>&1); then
    echo >&2 "エラー: 退避先の秘密鍵 ${BACKUP_DIR}/.ssh/id_ed25519_signing がパスフレーズで保護されているか破損しています"
    exit 1
  fi
  actual_pub=$(awk '{print $1, $2}' "${BACKUP_DIR}/.ssh/id_ed25519_signing.pub")
  derived_key=$(printf '%s\n' "${derived_pub}" | awk '{print $1, $2}')
  if [ -z "${derived_key}" ] || [ "${derived_key}" != "${actual_pub}" ]; then
    echo >&2 "エラー: 退避先の秘密鍵と公開鍵が一致しません"
    exit 1
  fi
  items+=(.ssh/id_ed25519_signing .ssh/id_ed25519_signing.pub)
  # shellcheck disable=SC2088
  restored_labels+=("~/.ssh/id_ed25519_signing, ~/.ssh/id_ed25519_signing.pub (${key_fp})")
fi

# 2. GitHub CLI 設定の事前検証
if [ -d "${BACKUP_DIR}/.config/gh" ]; then
  if [ -n "$(find "${BACKUP_DIR}/.config/gh" \( ! -type f ! -type d \) -print -quit)" ]; then
    echo >&2 "エラー: 退避先の ${BACKUP_DIR}/.config/gh にシンボリックリンクまたは特殊ファイルが含まれているため復元できません"
    exit 1
  fi
  if [ -z "$(find "${BACKUP_DIR}/.config/gh" -type f -size +0c -print -quit)" ]; then
    echo >&2 "エラー: 退避先の ${BACKUP_DIR}/.config/gh に有効なファイルがありません"
    exit 1
  fi
  items+=(.config/gh)
  # shellcheck disable=SC2088
  restored_labels+=("~/.config/gh")
fi

# 3. GitHub Copilot CLI 設定の事前検証
if [ -e "${BACKUP_DIR}/.copilot/config.json" ] || [ -L "${BACKUP_DIR}/.copilot/config.json" ]; then
  if [ -L "${BACKUP_DIR}/.copilot/config.json" ]; then
    echo >&2 "エラー: 退避先の ${BACKUP_DIR}/.copilot/config.json がシンボリックリンクのため復元できません"
    exit 1
  fi
  if [ ! -f "${BACKUP_DIR}/.copilot/config.json" ] || [ ! -s "${BACKUP_DIR}/.copilot/config.json" ] || \
     [ ! -r "${BACKUP_DIR}/.copilot/config.json" ]; then
    echo >&2 "エラー: 退避先の ${BACKUP_DIR}/.copilot/config.json が空または読み取り不可です"
    exit 1
  fi
  items+=(.copilot/config.json)
  # shellcheck disable=SC2088
  restored_labels+=("~/.copilot/config.json")
fi

if [ "${#items[@]}" -eq 0 ]; then
  echo >&2 "エラー: 退避先に復元できる認証情報や署名鍵が見つかりません: ${BACKUP_DIR}"
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  exit 0
fi

st=$(get_status "${NAME}") || exit $?
if [ "${st}" != Running ]; then
  echo >&2 "エラー: インスタンス ${NAME} は動いていません（先に make start で起動してください）"
  exit 1
fi

# shellcheck disable=SC2016
tar -C "${BACKUP_DIR}" -cf - "${items[@]}" | limactl shell "${NAME}" bash -c '
  set -eu -o pipefail
  umask 077

  for d in .ssh .config .config/gh .copilot; do
    if [ -L "${HOME}/${d}" ]; then
      echo >&2 "エラー: VM 内の ~/${d} がシンボリックリンクのため復元できません"
      exit 1
    fi
  done

  if [ -d "${HOME}/.config/gh" ]; then
    if [ -n "$(find "${HOME}/.config/gh" \( ! -type f ! -type d \) -print -quit)" ]; then
      echo >&2 "エラー: VM 内の ~/.config/gh にシンボリックリンクまたは特殊ファイルが含まれているため復元できません"
      exit 1
    fi
  fi

  stage_dir=$(mktemp -d)
  cleanup() {
    rm -rf "${stage_dir}"
  }
  trap cleanup EXIT

  tar -xf - -C "${stage_dir}"

  if [ -n "$(find "${stage_dir}" \( ! -type f ! -type d \) -print -quit)" ]; then
    echo >&2 "エラー: 復元データにシンボリックリンクまたは特殊ファイルが含まれています"
    exit 1
  fi

  # 1. Git 署名鍵の復元と allowed_signers の更新・署名検証
  if [ -s "${stage_dir}/.ssh/id_ed25519_signing" ] && [ -s "${stage_dir}/.ssh/id_ed25519_signing.pub" ]; then
    key="${HOME}/.ssh/id_ed25519_signing"
    if [ -L "${key}" ] || [ -L "${key}.pub" ]; then
      echo >&2 "エラー: VM 内の ~/.ssh/id_ed25519_signing* がシンボリックリンクのため復元できません"
      exit 1
    fi
    prev_key_type=""
    prev_key_blob=""
    if [ -s "${key}.pub" ]; then
      prev_key_type=$(awk "{print \$1}" "${key}.pub" 2>/dev/null || true)
      prev_key_blob=$(awk "{print \$2}" "${key}.pub" 2>/dev/null || true)
    elif [ -s "${key}" ]; then
      prev_derived=$(ssh-keygen -y -P "" -f "${key}" 2>/dev/null || true)
      if [ -n "${prev_derived}" ]; then
        prev_key_type=$(printf "%s\n" "${prev_derived}" | awk "{print \$1}")
        prev_key_blob=$(printf "%s\n" "${prev_derived}" | awk "{print \$2}")
      fi
    fi
    install -m 0700 -d "${HOME}/.ssh"
    install -m 0600 "${stage_dir}/.ssh/id_ed25519_signing" "${key}"
    install -m 0644 "${stage_dir}/.ssh/id_ed25519_signing.pub" "${key}.pub"

    configured_email=$(git config --includes --global --get user.email 2>/dev/null || true)
    gpg_format=$(git config --includes --global --get gpg.format 2>/dev/null || echo "openpgp")
    signing_key=$(git config --includes --global --get user.signingkey 2>/dev/null || true)
    signing_key="${signing_key/#\~/$HOME}"
    default_key_cmd=$(git config --includes --global --get gpg.ssh.defaultKeyCommand 2>/dev/null || true)

    if [ -z "${default_key_cmd}" ] && [ "${gpg_format}" = "ssh" ] && [ "${signing_key}" = "${key}" ]; then
      key_type=$(awk "{print \$1}" "${key}.pub")
      key_blob=$(awk "{print \$2}" "${key}.pub")
      key_pattern="${key_type} ${key_blob}"
      if [ -n "${configured_email}" ] && [ -n "${key_type}" ] && [ -n "${key_blob}" ]; then
        configured_signers=$(git config --includes --global --get gpg.ssh.allowedSignersFile 2>/dev/null || true)
        if [ -n "${configured_signers}" ]; then
          allowed_signers="${configured_signers/#\~/$HOME}"
        else
          allowed_signers="${HOME}/.config/git/allowed_signers"
        fi
        install -m 0755 -d "$(dirname "${allowed_signers}")"
        entry="${configured_email} namespaces=\"git\" ${key_pattern}"
        if [ -f "${allowed_signers}" ]; then
          tmp_signers="${stage_dir}/allowed_signers.tmp"
          awk -v email="${configured_email}" \
              -v key_type="${key_type}" \
              -v key_blob="${key_blob}" \
              -v prev_type="${prev_key_type}" \
              -v prev_blob="${prev_key_blob}" \
              -v new_entry="${entry}" "
            \$1 == email && \$2 == \"namespaces=\\\"git\\\"\" && ((\$3 == key_type && \$4 == key_blob) || (prev_type != \"\" && \$3 == prev_type && \$4 == prev_blob)) {
              if (!replaced) {
                print new_entry
                replaced = 1
              }
              next
            }
            { print }
            END {
              if (!replaced) print new_entry
            }
          " "${allowed_signers}" > "${tmp_signers}"
          install -m 0644 "${tmp_signers}" "${allowed_signers}"
        else
          printf "%s\n" "${entry}" > "${allowed_signers}"
          chmod 0644 "${allowed_signers}"
        fi
        if ! git config --includes --global --get gpg.ssh.allowedSignersFile >/dev/null 2>&1; then
          git config --global gpg.ssh.allowedSignersFile "${allowed_signers}"
        fi
      fi

      get_status=0
      raw_commit_sign=$(git config --includes --global --get commit.gpgsign 2>/dev/null) || get_status=$?
      if [ "${get_status}" -eq 1 ]; then
        commit_sign="false"
      elif [ "${get_status}" -ne 0 ]; then
        get_err=$(git config --includes --global --get commit.gpgsign 2>&1 || true)
        echo >&2 "エラー: commit.gpgsign の設定取得に失敗しました: ${get_err}"
        exit 1
      else
        if ! commit_sign=$(git config --includes --global --type=bool --get commit.gpgsign 2>/dev/null); then
          echo >&2 "エラー: commit.gpgsign の真偽値設定が不正です: ${raw_commit_sign}"
          exit 1
        fi
      fi
      if [ "${commit_sign}" = "true" ]; then
        diag_dir=$(mktemp -d "${stage_dir}/diag.XXXXXX")
        git init -q "${diag_dir}"
        configured_name=$(git config --includes --global --get user.name 2>/dev/null || true)
        if [ -z "${configured_name}" ] || [ -z "${configured_email}" ]; then
          test_signers="${diag_dir}/allowed_signers"
          printf "diagnostic@example.com namespaces=\"git\" %s\n" "${key_pattern}" > "${test_signers}"
          git -C "${diag_dir}" config user.name "Diagnostic User"
          git -C "${diag_dir}" config user.email "diagnostic@example.com"
          git -C "${diag_dir}" config gpg.format ssh
          git -C "${diag_dir}" config user.signingkey "${key}"
          git -C "${diag_dir}" config commit.gpgsign true
          git -C "${diag_dir}" config gpg.ssh.allowedSignersFile "${test_signers}"
        fi
        if ! timeout -k 3 10 git -C "${diag_dir}" -c core.hooksPath=/dev/null commit -q --allow-empty --no-verify -m "restore-auth verification" 2>&1 || \
           ! timeout -k 3 10 git -C "${diag_dir}" verify-commit HEAD >/dev/null 2>&1; then
          echo >&2 "エラー: 復元した署名鍵での Git コミット署名・検証に失敗しました"
          exit 1
        fi
      fi
    fi
  fi

  # 2. GitHub CLI 設定の復元と git credential helper の設定
  if [ -d "${stage_dir}/.config/gh" ]; then
    install -m 0755 -d "${HOME}/.config"
    install -m 0700 -d "${HOME}/.config/gh"
    cp -R "${stage_dir}/.config/gh/." "${HOME}/.config/gh/"
    find "${HOME}/.config/gh" -type d -exec chmod 0700 {} +
    find "${HOME}/.config/gh" -type f -exec chmod 0600 {} +
    if [ -s "${HOME}/.config/gh/hosts.yml" ] && command -v gh >/dev/null 2>&1; then
      if ! gh auth setup-git >/dev/null 2>&1; then
        echo >&2 "注意: gh auth setup-git の自動設定をスキップしました（トークンが失効している場合は VM 内で gh auth login を実行してください）"
      fi
    fi
  fi

  # 3. GitHub Copilot CLI 設定の復元（copilot-instructions.md などの他ファイルは保持）
  if [ -s "${stage_dir}/.copilot/config.json" ]; then
    if [ -L "${HOME}/.copilot/config.json" ]; then
      echo >&2 "エラー: VM 内の ~/.copilot/config.json がシンボリックリンクのため復元できません"
      exit 1
    fi
    install -m 0700 -d "${HOME}/.copilot"
    install -m 0600 "${stage_dir}/.copilot/config.json" "${HOME}/.copilot/config.json"
  fi
'

echo "インスタンス ${NAME} に認証情報・署名鍵を復元しました:"
echo "  復元元: ${BACKUP_DIR}"
for label in "${restored_labels[@]}"; do
  echo "  - ${label}"
done
echo "注意: トークンの有効期限切れや失効により認証エラーになる場合は、VM 内で再度ログイン（gh auth login / copilot の /login）してください。"
