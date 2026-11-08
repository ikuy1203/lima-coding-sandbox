#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 8: scripts/lint.sh documentation and configuration consistency
# -----------------------------------------------------------------------------
test_lint_checks() {
  local suite="scripts/lint.sh consistency checks"
  local test_dir="${MASTER_TEST_DIR}/lint_checks"
  rm -rf "${test_dir}"
  mkdir -p "${test_dir}"

  local fake_bin="${test_dir}/bin"
  mkdir -p "${fake_bin}"

  cat > "${fake_bin}/limactl" << 'EOF'
#!/bin/bash
set -eu
case "$*" in
  *".probes | length"*)
    echo "${STUB_LIMACTL_PROBE_COUNT:-0}"
    ;;
esac
exit 0
EOF
  chmod +x "${fake_bin}/limactl"

  create_noop_stubs "${fake_bin}" shellcheck

  setup_repo_copy() {
    local dst="$1"
    rm -rf "${dst}"
    mkdir -p "${dst}/provision" "${dst}/scripts/tests" "${dst}/docs"
    cp "${REPO_ROOT}/coding-sandbox.yaml" "${REPO_ROOT}/Makefile" "${REPO_ROOT}/README.md" "${dst}/"
    cp "${REPO_ROOT}"/provision/*.sh "${dst}/provision/"
    cp "${REPO_ROOT}"/scripts/*.sh "${dst}/scripts/"
    cp "${REPO_ROOT}"/scripts/tests/*.sh "${dst}/scripts/tests/"
    cp "${REPO_ROOT}"/docs/*.md "${dst}/docs/"
  }

  # 8.1 正常なリポジトリ状態（通常ロケールおよび LC_ALL=C）で lint.sh が成功すること
  log_test "${suite}: passes on consistent repository state (default and LC_ALL=C)"
  local repo_ok="${test_dir}/repo_ok"
  setup_repo_copy "${repo_ok}"
  local ok_rc=0 c_rc=0
  LINT_REPO_ROOT="${repo_ok}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" >/dev/null 2>&1 || ok_rc=$?
  LC_ALL=C LINT_REPO_ROOT="${repo_ok}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" >/dev/null 2>&1 || c_rc=$?
  if [ "${ok_rc}" -eq 0 ] && [ "${c_rc}" -eq 0 ]; then
    log_pass "${suite}: passes on consistent repository state (default and LC_ALL=C)"
  else
    log_fail "${suite}: failed on valid repository state (ok_rc=${ok_rc}, c_rc=${c_rc})"
  fi

  # 8.2 provision / scripts / docs の各検査が個別に不整合を検出すること
  log_test "${suite}: detects mismatches in each provision, scripts, and docs check individually"
  local repo_files="${test_dir}/repo_files"

  # 8.2a coding-sandbox.yaml の provision: から欠落した場合
  setup_repo_copy "${repo_files}"
  awk '!/file: provision\/mise\.sh/' "${repo_files}/coding-sandbox.yaml" > "${repo_files}/coding-sandbox.yaml.tmp"
  mv "${repo_files}/coding-sandbox.yaml.tmp" "${repo_files}/coding-sandbox.yaml"
  local prov_yaml_err="${test_dir}/prov_yaml.stderr"
  local prov_yaml_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${prov_yaml_err}" || prov_yaml_failed=1

  # 8.2b README.md「## 構成」の表から欠落した場合
  setup_repo_copy "${repo_files}"
  awk '!/provision\/mise\.sh/' "${repo_files}/README.md" > "${repo_files}/README.md.tmp"
  mv "${repo_files}/README.md.tmp" "${repo_files}/README.md"
  local prov_cfg_err="${test_dir}/prov_cfg.stderr"
  local prov_cfg_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${prov_cfg_err}" || prov_cfg_failed=1

  # 8.2c README.md「## ファイル構成」の provision/ から欠落した場合
  setup_repo_copy "${repo_files}"
  awk '!/├── mise\.sh/' "${repo_files}/README.md" > "${repo_files}/README.md.tmp"
  mv "${repo_files}/README.md.tmp" "${repo_files}/README.md"
  local prov_tree_err="${test_dir}/prov_tree.stderr"
  local prov_tree_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${prov_tree_err}" || prov_tree_failed=1

  # 8.2d scripts/ に未記載ファイルがある場合
  setup_repo_copy "${repo_files}"
  touch "${repo_files}/scripts/unlisted.sh"
  local script_err="${test_dir}/script.stderr"
  local script_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${script_err}" || script_failed=1

  # 8.2e docs/ に未記載ファイルがある場合
  setup_repo_copy "${repo_files}"
  touch "${repo_files}/docs/unlisted.md"
  local doc_err="${test_dir}/doc.stderr"
  local doc_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${doc_err}" || doc_failed=1

  # 8.2f scripts/tests/ に未読込ファイルがある場合、および test_*() 関数や集約スイートがランナーに未登録・コメントアウトされた場合
  setup_repo_copy "${repo_files}"
  touch "${repo_files}/scripts/tests/unlisted.sh"
  local test_suite_err="${test_dir}/test_suite.stderr"
  local test_suite_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${test_suite_err}" || test_suite_failed=1

  setup_repo_copy "${repo_files}"
  printf '\ntest_unregistered_suite() {\n  :\n}\n' >> "${repo_files}/scripts/tests/lint-checks.sh"
  local unreg_suite_err="${test_dir}/unreg_suite.stderr"
  local unreg_suite_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${unreg_suite_err}" || unreg_suite_failed=1

  setup_repo_copy "${repo_files}"
  awk '/^ALL_SUITES=\(/ { in_all = 1 } in_all && /^\)/ { in_all = 0 } in_all && /makefile_logic/ { next } { print }' "${repo_files}/scripts/test.sh" > "${repo_files}/scripts/test.sh.tmp"
  mv "${repo_files}/scripts/test.sh.tmp" "${repo_files}/scripts/test.sh"
  local ml_omit_err="${test_dir}/ml_omit.stderr"
  local ml_omit_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${ml_omit_err}" || ml_omit_failed=1

  setup_repo_copy "${repo_files}"
  awk '/^MAKEFILE_LOGIC_SUITES=\(/ { in_ml = 1 } in_ml && /^\)/ { in_ml = 0 } in_ml && /auth_and_signing_key/ { sub(/auth_and_signing_key/, "# auth_and_signing_key") } { print }' "${repo_files}/scripts/test.sh" > "${repo_files}/scripts/test.sh.tmp"
  mv "${repo_files}/scripts/test.sh.tmp" "${repo_files}/scripts/test.sh"
  local ml_comment_err="${test_dir}/ml_comment.stderr"
  local ml_comment_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${ml_comment_err}" || ml_comment_failed=1

  setup_repo_copy "${repo_files}"
  awk '
    /^append_suite_once\(\)/ { in_ap = 1 }
    in_ap && /^\}/ { in_ap = 0 }
    in_ap && /target.*makefile_logic/ { skip = 1; next }
    skip && /^[ \t]*fi$/ { skip = 0; next }
    !skip { print }
  ' "${repo_files}/scripts/test.sh" > "${repo_files}/scripts/test.sh.tmp"
  mv "${repo_files}/scripts/test.sh.tmp" "${repo_files}/scripts/test.sh"
  local ml_expand_err="${test_dir}/ml_expand.stderr"
  local ml_expand_failed=0
  LINT_REPO_ROOT="${repo_files}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${ml_expand_err}" || ml_expand_failed=1

  if [ "${prov_yaml_failed}" -eq 1 ] && grep -q "provision scripts in coding-sandbox.yaml do not match.*missing: provision/mise.sh" "${prov_yaml_err}" && \
     [ "${prov_cfg_failed}" -eq 1 ] && grep -q "provision scripts in README.md '## 構成' table do not match.*missing: provision/mise.sh" "${prov_cfg_err}" && \
     [ "${prov_tree_failed}" -eq 1 ] && grep -q "provision scripts in README.md '## ファイル構成' do not match.*missing: provision/mise.sh" "${prov_tree_err}" && \
     [ "${script_failed}" -eq 1 ] && grep -q "scripts/unlisted.sh" "${script_err}" && \
     [ "${doc_failed}" -eq 1 ] && grep -q "docs/unlisted.md" "${doc_err}" && \
     [ "${test_suite_failed}" -eq 1 ] && grep -q "scripts/tests/unlisted.sh" "${test_suite_err}" && \
     [ "${unreg_suite_failed}" -eq 1 ] && grep -q "unregistered_suite" "${unreg_suite_err}" && \
     [ "${ml_omit_failed}" -eq 1 ] && grep -q "default suites .*missing:.*makefile_create_and_start" "${ml_omit_err}" && \
     [ "${ml_comment_failed}" -eq 1 ] && grep -q "default suites .*missing: auth_and_signing_key" "${ml_comment_err}" && \
     [ "${ml_expand_failed}" -eq 1 ] && grep -q "default suites .*missing:.*makefile_create_and_start" "${ml_expand_err}"; then
    log_pass "${suite}: detects mismatches in each provision, scripts, and docs check individually"
  else
    log_fail "${suite}: failed individual file consistency checks (yaml=${prov_yaml_failed}, cfg=${prov_cfg_failed}, tree=${prov_tree_failed}, script=${script_failed}, doc=${doc_failed}, test_suite=${test_suite_failed}, unreg=${unreg_suite_failed}, ml_omit=${ml_omit_failed}, ml_comment=${ml_comment_failed}, ml_expand=${ml_expand_failed})"
  fi

  # 8.3 Makefile の未記載ターゲットを検出して失敗すること
  log_test "${suite}: detects undocumented Makefile target"
  local repo_make="${test_dir}/repo_make"
  setup_repo_copy "${repo_make}"
  printf '\nunlisted-target: ## 未記載のターゲット\n\t@true\n' >> "${repo_make}/Makefile"
  local make_err="${test_dir}/make.stderr"
  local make_failed=0
  LINT_REPO_ROOT="${repo_make}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${make_err}" || make_failed=1
  if [ "${make_failed}" -eq 1 ] && grep -q "Makefile targets do not match.*missing: unlisted-target" "${make_err}"; then
    log_pass "${suite}: detects undocumented Makefile target"
  else
    log_fail "${suite}: failed to detect undocumented Makefile target"
  fi

  # 8.4 base_packages・probe cmds・probe bins と README の不一致を個別に検出すること
  log_test "${suite}: detects package, probe command, and CLI binary mismatch with README"
  local repo_pkg="${test_dir}/repo_pkg"
  setup_repo_copy "${repo_pkg}"
  awk '{ gsub(/shellcheck/, "shellcheck tmux"); print }' "${repo_pkg}/provision/apt-packages.sh" > "${repo_pkg}/provision/apt-packages.sh.tmp"
  mv "${repo_pkg}/provision/apt-packages.sh.tmp" "${repo_pkg}/provision/apt-packages.sh"
  local pkg_err="${test_dir}/pkg.stderr"
  local pkg_failed=0
  LINT_REPO_ROOT="${repo_pkg}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${pkg_err}" || pkg_failed=1

  setup_repo_copy "${repo_pkg}"
  awk '{ gsub(/cmds=\(git /, "cmds=(git tmux "); print }' "${repo_pkg}/coding-sandbox.yaml" > "${repo_pkg}/coding-sandbox.yaml.tmp"
  mv "${repo_pkg}/coding-sandbox.yaml.tmp" "${repo_pkg}/coding-sandbox.yaml"
  local cmd_err="${test_dir}/cmd.stderr"
  local cmd_failed=0
  LINT_REPO_ROOT="${repo_pkg}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${cmd_err}" || cmd_failed=1

  setup_repo_copy "${repo_pkg}"
  awk '{ gsub(/bins=\(herdr /, "bins=(herdr unlistedcli "); print }' "${repo_pkg}/coding-sandbox.yaml" > "${repo_pkg}/coding-sandbox.yaml.tmp"
  mv "${repo_pkg}/coding-sandbox.yaml.tmp" "${repo_pkg}/coding-sandbox.yaml"
  local bin_err="${test_dir}/bin.stderr"
  local bin_failed=0
  LINT_REPO_ROOT="${repo_pkg}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${bin_err}" || bin_failed=1

  if [ "${pkg_failed}" -eq 1 ] && grep -q "packages in provision/apt-packages.sh.*missing: tmux" "${pkg_err}" && \
     [ "${cmd_failed}" -eq 1 ] && grep -q "probe basic tools commands.*missing: tmux" "${cmd_err}" && \
     [ "${bin_failed}" -eq 1 ] && grep -q "CLI binary '~/.local/bin/unlistedcli'" "${bin_err}"; then
    log_pass "${suite}: detects package, probe command, and CLI binary mismatch with README"
  else
    log_fail "${suite}: failed to detect package/cmd/bin mismatch (pkg=${pkg_failed}, cmd=${cmd_failed}, bin=${bin_failed})"
  fi

  # 8.5 Markdown のリンク切れ・probe 数不一致を検出し、インラインコード・重複見出し・インデントコードフェンス・閉じ # を正しく扱うこと
  log_test "${suite}: detects broken markdown links, probe count mismatch, and handles inline code and duplicate headings"
  local repo_link="${test_dir}/repo_link"
  setup_repo_copy "${repo_link}"
  printf '\n[壊れたファイルリンク](docs/nonexistent.md)\n' >> "${repo_link}/README.md"
  local file_link_err="${test_dir}/file_link.stderr"
  local file_link_failed=0
  LINT_REPO_ROOT="${repo_link}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${file_link_err}" || file_link_failed=1

  setup_repo_copy "${repo_link}"
  printf '\n[壊れたアンカーリンク](docs/security.md#存在しない見出し)\n' >> "${repo_link}/README.md"
  local anchor_link_err="${test_dir}/anchor_link.stderr"
  local anchor_link_failed=0
  LINT_REPO_ROOT="${repo_link}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${anchor_link_err}" || anchor_link_failed=1

  # インラインコード内の `[dummy](nonexistent.md)`、重複見出し `#重複見出し-1`、閉じ `#` 見出し、インデントコードフェンスは正常動作すること
  setup_repo_copy "${repo_link}"
  # shellcheck disable=SC2016
  printf '\n### 重複見出し\n### 重複見出し\n### 閉じシャープ付き ##\n  ```sh\n# フェンス内のコメント\n[壊れたリンクではない](nonexistent.md)\n  ```\n`[inline](nonexistent.md)` と [2つ目](#重複見出し-1) と [閉じシャープ](#閉じシャープ付き)\n' >> "${repo_link}/README.md"
  local inline_dup_rc=0
  LINT_REPO_ROOT="${repo_link}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" >/dev/null 2>&1 || inline_dup_rc=$?

  # インデントされたコードフェンス内の `# フェンス内のコメント` が見出しアンカーとして誤認識されないこと
  printf '\n[フェンス内はアンカーではない](#フェンス内のコメント)\n' >> "${repo_link}/README.md"
  local fence_anchor_err="${test_dir}/fence_anchor.stderr"
  local fence_anchor_failed=0
  LINT_REPO_ROOT="${repo_link}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" >/dev/null 2>"${fence_anchor_err}" || fence_anchor_failed=1

  # docs/security.md の requirement 1 of N 表記が probe 数と不一致の場合、および awk と limactl の件数が不一致の場合に検出すること
  setup_repo_copy "${repo_link}"
  local yq_cnt_err="${test_dir}/yq_cnt.stderr"
  local yq_cnt_failed=0
  STUB_LIMACTL_PROBE_COUNT=2 LINT_REPO_ROOT="${repo_link}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" >/dev/null 2>"${yq_cnt_err}" || yq_cnt_failed=1

  awk '{ gsub(/requirement 1 of [0-9]+:/, "requirement 1 of 999:"); print }' "${repo_link}/docs/security.md" > "${repo_link}/docs/security.md.tmp"
  mv "${repo_link}/docs/security.md.tmp" "${repo_link}/docs/security.md"
  local probe_cnt_err="${test_dir}/probe_cnt.stderr"
  local probe_cnt_failed=0
  LINT_REPO_ROOT="${repo_link}" PATH="${fake_bin}:${PATH}" bash "${REPO_ROOT}/scripts/lint.sh" 2>"${probe_cnt_err}" || probe_cnt_failed=1

  if [ "${file_link_failed}" -eq 1 ] && grep -q "broken link target 'docs/nonexistent.md'" "${file_link_err}" && \
     [ "${anchor_link_failed}" -eq 1 ] && grep -q "broken link anchor '#存在しない見出し'" "${anchor_link_err}" && \
     [ "${inline_dup_rc}" -eq 0 ] && \
     [ "${fence_anchor_failed}" -eq 1 ] && grep -q "broken link anchor '#フェンス内のコメント'" "${fence_anchor_err}" && \
     [ "${yq_cnt_failed}" -eq 1 ] && grep -q "probe count parsed by awk .* does not match limactl template yq" "${yq_cnt_err}" && \
     [ "${probe_cnt_failed}" -eq 1 ] && grep -q "docs/security.md does not match actual probe count" "${probe_cnt_err}"; then
    log_pass "${suite}: detects broken markdown links, probe count mismatch, and handles inline code and duplicate headings"
  else
    log_fail "${suite}: failed markdown link/probe count checks (file=${file_link_failed}, anchor=${anchor_link_failed}, inline_dup_rc=${inline_dup_rc}, fence=${fence_anchor_failed}, yq=${yq_cnt_failed}, probe_cnt=${probe_cnt_failed})"
  fi
}
