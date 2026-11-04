#!/bin/bash
# VM 内の認証情報（gh・copilot）と Git コミット署名鍵をホスト側の安全なディレクトリに退避する
#
# 対象（VM 内の $HOME からの相対パス）:
# - .ssh/id_ed25519_signing, .ssh/id_ed25519_signing.pub
# - .config/gh
# - .copilot/config.json
#
# 退避先はディレクトリ 0700・ファイル 0600 に設定し、鍵ペアの整合性や復元用アーカイブの読み出しまで検証してから反映する。
set -eu -o pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

NAME=$(resolve_name) || exit $?
BACKUP_DIR=$(resolve_auth_backup_dir "${NAME}") || exit $?

st=$(get_status "${NAME}") || exit $?
if [ -z "${st}" ]; then
  echo >&2 "エラー: インスタンス ${NAME} はありません"
  exit 1
fi
if [ "${st}" != Running ]; then
  echo >&2 "エラー: インスタンス ${NAME} は動いていません（先に make start で起動してください）"
  exit 1
fi

parent_dir="$(dirname "${BACKUP_DIR}")"
if [ ! -d "${parent_dir}" ]; then
  # 存在しない親ディレクトリのみ umask 077 (0700) で作成し、既存の親ディレクトリの権限は変更しない
  mkdir -p "${parent_dir}"
fi

if [ -L "${BACKUP_DIR}" ]; then
  echo >&2 "エラー: 退避先にシンボリックリンクは指定できません: ${BACKUP_DIR}"
  exit 1
fi

created_backup_dir=0
if [ -e "${BACKUP_DIR}" ]; then
  if [ ! -d "${BACKUP_DIR}" ]; then
    echo >&2 "エラー: 退避先がディレクトリではありません: ${BACKUP_DIR}"
    exit 1
  fi
  if [ ! -O "${BACKUP_DIR}" ]; then
    echo >&2 "エラー: 退避先の所有者が現在のユーザではありません: ${BACKUP_DIR}"
    exit 1
  fi
  chmod 0700 "${BACKUP_DIR}"
else
  install -m 0700 -d "${BACKUP_DIR}"
  created_backup_dir=1
fi

stage_dir=""
old_dir=""
swap_completed=0
cleanup() {
  if [ "${swap_completed}" -ne 1 ] && [ -n "${old_dir}" ] && [ -d "${old_dir}" ]; then
    local item rollback_failed=0
    for item in .ssh .config .copilot; do
      if [ -e "${old_dir}/${item}" ] || [ -L "${old_dir}/${item}" ]; then
        rm -rf "${BACKUP_DIR:?}/${item}" 2>/dev/null || rollback_failed=1
        mv "${old_dir}/${item}" "${BACKUP_DIR}/${item}" 2>/dev/null || rollback_failed=1
      fi
    done
    if [ "${rollback_failed}" -eq 0 ]; then
      rm -rf "${old_dir}"
    fi
  elif [ -n "${old_dir}" ] && [ -d "${old_dir}" ]; then
    rm -rf "${old_dir}"
  fi
  if [ -n "${stage_dir}" ] && [ -e "${stage_dir}" ]; then
    rm -rf "${stage_dir}"
  fi
  if [ "${created_backup_dir}" -eq 1 ] && [ -d "${BACKUP_DIR}" ]; then
    rmdir "${BACKUP_DIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

stage_dir=$(mktemp -d "${BACKUP_DIR}/.auth-backup-stage.XXXXXX")
chmod 0700 "${stage_dir}"
archive_file="${stage_dir}/.archive.tar"

# VM 内で対象ファイルを検証し、tar ストリームとして標準出力へ書き出す
# shellcheck disable=SC2016
limactl shell "${NAME}" bash -c '
  set -eu -o pipefail
  cd "${HOME}"

  for d in .ssh .config .config/gh .copilot; do
    if [ -L "${d}" ]; then
      echo >&2 "エラー: VM 内の ~/${d} がシンボリックリンクのため退避できません"
      exit 1
    fi
  done

  items=()

  if [ -L .ssh/id_ed25519_signing ] || [ -L .ssh/id_ed25519_signing.pub ]; then
    echo >&2 "エラー: VM 内の ~/.ssh/id_ed25519_signing* がシンボリックリンクのため退避できません"
    exit 1
  fi
  if { [ -e .ssh/id_ed25519_signing ] && [ ! -f .ssh/id_ed25519_signing ]; } || \
     { [ -e .ssh/id_ed25519_signing.pub ] && [ ! -f .ssh/id_ed25519_signing.pub ]; }; then
    echo >&2 "エラー: VM 内の ~/.ssh/id_ed25519_signing* が通常ファイルではありません"
    exit 1
  fi
  if [ ! -s .ssh/id_ed25519_signing ] && [ -s .ssh/id_ed25519_signing.pub ]; then
    echo >&2 "エラー: VM 内に公開鍵 ~/.ssh/id_ed25519_signing.pub のみがあり、秘密鍵 ~/.ssh/id_ed25519_signing がありません"
    exit 1
  fi
  if [ -s .ssh/id_ed25519_signing ]; then
    if [ ! -s .ssh/id_ed25519_signing.pub ]; then
      derived_out=$(ssh-keygen -y -P "" -f .ssh/id_ed25519_signing 2>&1) || {
        echo >&2 "エラー: 公開鍵 ~/.ssh/id_ed25519_signing.pub が無く、秘密鍵からの導出にも失敗しました"
        exit 1
      }
      printf "%s\n" "${derived_out}" > .ssh/id_ed25519_signing.pub
      chmod 0644 .ssh/id_ed25519_signing.pub
    fi
    items+=(.ssh/id_ed25519_signing .ssh/id_ed25519_signing.pub)
  fi

  if [ -d .config/gh ]; then
    if [ -n "$(find .config/gh \( ! -type f ! -type d \) -print -quit)" ]; then
      echo >&2 "エラー: VM 内の ~/.config/gh にシンボリックリンクまたは特殊ファイルが含まれているため退避できません"
      exit 1
    fi
    if [ -n "$(find .config/gh -type f -size +0c -print -quit)" ]; then
      items+=(.config/gh)
    fi
  fi

  if [ -L .copilot/config.json ]; then
    echo >&2 "エラー: VM 内の ~/.copilot/config.json がシンボリックリンクのため退避できません"
    exit 1
  fi
  if [ -e .copilot/config.json ] && [ ! -f .copilot/config.json ]; then
    echo >&2 "エラー: VM 内の ~/.copilot/config.json が通常ファイルではありません"
    exit 1
  fi
  if [ -s .copilot/config.json ]; then
    items+=(.copilot/config.json)
  fi

  if [ "${#items[@]}" -eq 0 ]; then
    echo >&2 "エラー: VM 内に退避できる認証情報や署名鍵が見つかりません（~/.ssh/id_ed25519_signing*、~/.config/gh、~/.copilot/config.json）"
    exit 1
  fi

  tar -cf - "${items[@]}"
' > "${archive_file}"

if [ ! -s "${archive_file}" ]; then
  echo >&2 "エラー: VM からの退避データの取得に失敗しました（アーカイブが空です）"
  exit 1
fi

# 展開前にアーカイブ内のエントリパスを検証する（パストラバーサル・想定外パスの防止）
tar_entries=$(tar -tf "${archive_file}") || {
  echo >&2 "エラー: 取得した退避アーカイブの検証に失敗しました"
  exit 1
}
if [ -z "${tar_entries}" ]; then
  echo >&2 "エラー: 取得した退避アーカイブにファイルが含まれていません"
  exit 1
fi

while IFS= read -r entry; do
  [ -n "${entry}" ] || continue
  clean="${entry#./}"
  clean="${clean%/}"
  [ -n "${clean}" ] || continue
  case "${entry}" in
    /*)
      echo >&2 "エラー: 退避アーカイブに絶対パスが含まれています: ${entry}"
      exit 1
      ;;
  esac
  case "/${clean}/" in
    *"/../"*|*"/./"*)
      echo >&2 "エラー: 退避アーカイブに不正な相対パスが含まれています: ${entry}"
      exit 1
      ;;
  esac
  case "${clean}" in
    .ssh|.ssh/id_ed25519_signing|.ssh/id_ed25519_signing.pub|.config|.config/gh|.config/gh/*|.copilot|.copilot/config.json)
      ;;
    *)
      echo >&2 "エラー: 退避アーカイブに対象外のパスが含まれています: ${entry}"
      exit 1
      ;;
  esac
done <<< "${tar_entries}"

tar -xf "${archive_file}" -C "${stage_dir}"
rm -f "${archive_file}"

# 展開後にシンボリックリンクや特殊ファイルが無いことを確認する
if [ -n "$(find "${stage_dir}" \( ! -type f ! -type d \) -print -quit)" ]; then
  echo >&2 "エラー: 退避データにシンボリックリンクまたは特殊ファイルが含まれています"
  exit 1
fi

# 権限を所有者のみ（ディレクトリ 0700、ファイル 0600）に設定する
find "${stage_dir}" -type d -exec chmod 0700 {} +
find "${stage_dir}" -type f -exec chmod 0600 {} +

backed_up_items=()
key_fingerprint=""

# 1. 署名鍵の検証（非対話署名用のため、パスフレーズ保護や破損した秘密鍵はエラーにする）
if [ -e "${stage_dir}/.ssh/id_ed25519_signing" ] || [ -e "${stage_dir}/.ssh/id_ed25519_signing.pub" ]; then
  if [ ! -s "${stage_dir}/.ssh/id_ed25519_signing" ] || [ ! -s "${stage_dir}/.ssh/id_ed25519_signing.pub" ]; then
    echo >&2 "エラー: 退避した署名鍵（秘密鍵または公開鍵）が空または欠落しています"
    exit 1
  fi
  if ! key_fingerprint=$(ssh-keygen -lf "${stage_dir}/.ssh/id_ed25519_signing.pub" 2>/dev/null); then
    echo >&2 "エラー: 退避した公開鍵 ~/.ssh/id_ed25519_signing.pub の形式が不正です"
    exit 1
  fi
  if ! derived_pub=$(ssh-keygen -y -P '' -f "${stage_dir}/.ssh/id_ed25519_signing" 2>&1); then
    echo >&2 "エラー: 退避した秘密鍵 ~/.ssh/id_ed25519_signing がパスフレーズで保護されているか破損しています"
    exit 1
  fi
  actual_pub=$(awk '{print $1, $2}' "${stage_dir}/.ssh/id_ed25519_signing.pub")
  derived_key=$(printf '%s\n' "${derived_pub}" | awk '{print $1, $2}')
  if [ -z "${derived_key}" ] || [ "${derived_key}" != "${actual_pub}" ]; then
    echo >&2 "エラー: 退避した署名鍵の秘密鍵と公開鍵が一致しません"
    exit 1
  fi
  # shellcheck disable=SC2088
  backed_up_items+=("~/.ssh/id_ed25519_signing, ~/.ssh/id_ed25519_signing.pub (${key_fingerprint})")
fi

# 2. GitHub CLI 設定の検証
if [ -d "${stage_dir}/.config/gh" ]; then
  if [ -z "$(find "${stage_dir}/.config/gh" -type f -size +0c -print -quit)" ]; then
    echo >&2 "エラー: 退避した ~/.config/gh に有効なファイルがありません"
    exit 1
  fi
  # shellcheck disable=SC2088
  backed_up_items+=("~/.config/gh")
fi

# 3. GitHub Copilot CLI 設定の検証
if [ -e "${stage_dir}/.copilot/config.json" ]; then
  if [ ! -s "${stage_dir}/.copilot/config.json" ] || [ ! -r "${stage_dir}/.copilot/config.json" ]; then
    echo >&2 "エラー: 退避した ~/.copilot/config.json が空または読み取り不可です"
    exit 1
  fi
  # shellcheck disable=SC2088
  backed_up_items+=("~/.copilot/config.json")
fi

if [ "${#backed_up_items[@]}" -eq 0 ]; then
  echo >&2 "エラー: 退避された有効なファイルがありません"
  exit 1
fi

# 復元用のアーカイブ生成・一覧読み出しができることまで確認する
if ! tar -C "${stage_dir}" -cf - . | tar -tf - >/dev/null 2>&1; then
  echo >&2 "エラー: 退避データの復元確認テストに失敗しました"
  exit 1
fi

# 検証に成功したら既存の退避アイテムをロールバック用ディレクトリへ退避してから入れ替える
old_dir=$(mktemp -d "${BACKUP_DIR}/.auth-backup-old.XXXXXX")
for top_item in .ssh .config .copilot; do
  if [ -e "${BACKUP_DIR}/${top_item}" ] || [ -L "${BACKUP_DIR}/${top_item}" ]; then
    mv "${BACKUP_DIR}/${top_item}" "${old_dir}/${top_item}"
  fi
done
for top_item in .ssh .config .copilot; do
  if [ -e "${stage_dir}/${top_item}" ]; then
    mv "${stage_dir}/${top_item}" "${BACKUP_DIR}/${top_item}"
  fi
done
swap_completed=1
created_backup_dir=0
rm -rf "${old_dir}"
old_dir=""
rm -rf "${stage_dir}"
stage_dir=""
chmod 0700 "${BACKUP_DIR}"

echo "インスタンス ${NAME} の認証情報・署名鍵を退避しました:"
echo "  退避先: ${BACKUP_DIR} (ディレクトリ 0700 / ファイル 0600)"
for item in "${backed_up_items[@]}"; do
  echo "  - ${item}"
done
echo "注意: 退避先には秘密鍵や平文トークンが含まれます。共有領域へ移動せず、不要になったら削除してください。"
