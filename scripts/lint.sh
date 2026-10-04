#!/bin/bash
# テンプレートとスクリプトを検査する（GitHub Actions の CI でも同じスクリプトを実行する）
#
# 必要なもの: limactl（Lima）、shellcheck
#   $ ./scripts/lint.sh
set -eu -o pipefail

cd "$(dirname "$0")/.."

template=coding-sandbox.yaml

# provision の file: の読み込みと minimumLimaVersion の確認も行われる
limactl validate "${template}"

shellcheck provision/*.sh scripts/*.sh

# probes はテンプレートに直接書いてあるため、limactl template yq で取り出して検査する
count=$(limactl template yq "${template}" '.probes | length')
for ((i = 0; i < count; i++)); do
  echo "shellcheck: probes[${i}] in ${template}"
  limactl template yq "${template}" ".probes[${i}].script" | shellcheck -
done
