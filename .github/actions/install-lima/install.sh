#!/bin/bash
# GitHub Actions 用の Lima 導入スクリプト（.github/actions/install-lima/action.yml から呼び出される）
set -eu -o pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "Error: install-lima action supports Linux runners only (got '$(uname -s)')" >&2
  exit 1
fi

version_spec="${LIMA_VERSION_SPEC-latest}"
case "${version_spec}" in
  minimum)
    template_path="${GITHUB_WORKSPACE:?}/coding-sandbox.yaml"
    version=$(awk '$1 == "minimumLimaVersion:" { gsub(/^["\047]|["\047]$/, "", $2); print $2; exit }' "${template_path}")
    if [ -z "${version}" ]; then
      echo "Error: failed to read minimumLimaVersion from ${template_path}" >&2
      exit 1
    fi
    ;;
  latest)
    version=$(gh release view --repo lima-vm/lima --json tagName --jq .tagName)
    version="${version#v}"
    ;;
  *)
    version="${version_spec#v}"
    ;;
esac

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._-]+)?$ ]]; then
  echo "Error: invalid Lima version '${version}' (from input '${version_spec}')" >&2
  exit 1
fi

tarball="lima-${version}-Linux-$(uname -m).tar.gz"
tmp_dir=$(mktemp -d "${RUNNER_TEMP:?}/lima-download.XXXXXX")
trap 'rm -rf "${tmp_dir}"' EXIT

cd "${tmp_dir}"
gh release download "v${version}" --repo lima-vm/lima --pattern "${tarball}" --pattern SHA256SUMS
if [ ! -s "${tarball}" ]; then
  echo "Error: release asset '${tarball}' was not downloaded" >&2
  exit 1
fi
if [ ! -s SHA256SUMS ]; then
  echo "Error: SHA256SUMS was not downloaded" >&2
  exit 1
fi
if ! awk -v f="${tarball}" '$2 == f || $2 == "*" f { found = 1; exit } END { exit !found }' SHA256SUMS; then
  echo "Error: '${tarball}' is not listed in SHA256SUMS" >&2
  exit 1
fi
sha256sum --check --ignore-missing SHA256SUMS

install_dir="${RUNNER_TEMP}/lima"
rm -rf "${install_dir}"
mkdir -p "${install_dir}"
tar -C "${install_dir}" -xzf "${tarball}"
echo "${install_dir}/bin" >>"${GITHUB_PATH:?}"
