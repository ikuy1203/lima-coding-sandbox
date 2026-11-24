#!/bin/bash
# テンプレートとスクリプト、およびドキュメントの整合性を検査する（GitHub Actions の CI でも同じスクリプトを実行する）
#
# 必要なもの: limactl（Lima）、shellcheck
#   $ ./scripts/lint.sh
set -eu -o pipefail

cd "${LINT_REPO_ROOT:-$(dirname "$0")/..}"

# ~/.lima/_config/default.yaml や override.yaml の混入を防ぎ、サンドボックス環境でも動作するよう一時ディレクトリを LIMA_HOME に使う
LIMA_HOME=$(mktemp -d)
export LIMA_HOME
trap 'rm -rf "${LIMA_HOME}"' EXIT

template=coding-sandbox.yaml
readme=README.md

# provision の file: の読み込みと minimumLimaVersion の確認も行われる
limactl validate "${template}"

shellcheck provision/*.sh scripts/*.sh scripts/tests/*.sh .github/actions/*/*.sh

# probes はテンプレートに直接書いてあるため、limactl template yq で取り出して検査する
count=$(limactl template yq "${template}" '.probes | length')
for ((i = 0; i < count; i++)); do
  echo "shellcheck: probes[${i}] in ${template}"
  limactl template yq "${template}" ".probes[${i}].script" | shellcheck -
done

# -----------------------------------------------------------------------------
# ドキュメントと設定の整合性検査
# -----------------------------------------------------------------------------
lint_errors=0
lint_err() {
  echo "lint error: $*" >&2
  lint_errors=$((lint_errors + 1))
}

# プロセス置換（/dev/fd）に依存せず 2 つの改行区切り集合を比較し、過不足を報告する
check_set_equal() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ -z "${expected}" ]; then
    lint_err "${label}: expected set is empty"
    return
  fi

  if [ "${expected}" = "${actual}" ]; then
    return
  fi

  local diff_summary
  diff_summary=$(
    EXP_SET="${expected}" ACT_SET="${actual}" awk '
      BEGIN {
        n_exp = split(ENVIRON["EXP_SET"], e_arr, "\n")
        for (i = 1; i <= n_exp; i++) {
          if (e_arr[i] != "") exp_set[e_arr[i]] = 1
        }
        n_act = split(ENVIRON["ACT_SET"], a_arr, "\n")
        for (i = 1; i <= n_act; i++) {
          if (a_arr[i] != "") act_set[a_arr[i]] = 1
        }
        missing = ""
        for (i = 1; i <= n_exp; i++) {
          item = e_arr[i]
          if (item != "" && !(item in act_set)) {
            missing = (missing == "" ? item : missing ", " item)
          }
        }
        extra = ""
        for (i = 1; i <= n_act; i++) {
          item = a_arr[i]
          if (item != "" && !(item in exp_set)) {
            extra = (extra == "" ? item : extra ", " item)
          }
        }
        msg = ""
        if (missing != "") msg = "missing: " missing
        if (extra != "") msg = (msg == "" ? "extra: " extra : msg "; extra: " extra)
        print msg
      }
    '
  )
  lint_err "${label} (${diff_summary})"
}

# README.md の指定した ## セクションを取り出す
extract_h2_section() {
  local file="$1"
  local heading="$2"
  awk -v h="## ${heading}" '
    $0 == h { in_sec = 1; next }
    in_sec && /^## / { exit }
    in_sec { print }
  ' "${file}"
}

# README.md の指定した ### セクションを取り出す
extract_h3_section() {
  local file="$1"
  local heading="$2"
  awk -v h="### ${heading}" '
    $0 == h { in_sec = 1; next }
    in_sec && /^###? / { exit }
    in_sec { print }
  ' "${file}"
}

# ファイル構成ツリーから指定ディレクトリ配下のファイル一覧を取り出す
# （mawk / LC_ALL=C でも動作するよう、ブラケット式内にマルチバイト文字を含めない）
extract_tree_dir_files() {
  local tree_text="$1"
  local dir_name="$2"
  printf '%s\n' "${tree_text}" | awk -v dir="${dir_name}" '
    $0 ~ "^(├|└)── " dir "/" { in_dir = 1; next }
    in_dir && /^(├|└)── / { in_dir = 0 }
    in_dir {
      line = $0
      sub(/#.*$/, "", line)
      if (match(line, /[A-Za-z0-9_.-]+\.(sh|md|yml|yaml)/)) {
        print dir "/" substr(line, RSTART, RLENGTH)
      }
    }
  ' | sort -u
}

# 1. provision/*.sh の整合性（coding-sandbox.yaml / ディスク上のファイル / README.md の「構成」と「ファイル構成」）
yaml_provisions=$(
  awk '
    /^provision:/ { in_prov = 1; next }
    in_prov && /^[a-zA-Z]/ { in_prov = 0 }
    in_prov {
      line = $0
      sub(/#.*$/, "", line)
      sub(/^[ \t]*-[ \t]*/, "", line)
      sub(/^[ \t]+/, "", line)
      if (line ~ /^file:[ \t]*/) {
        sub(/^file:[ \t]*/, "", line)
        gsub(/^["'\'']|["'\'']$/, "", line)
        sub(/[ \t]+$/, "", line)
        if (line != "") print line
      }
    }
  ' "${template}" | sort -u
)
disk_provisions=$(printf '%s\n' provision/*.sh | sort -u)

check_set_equal \
  "provision scripts in ${template} do not match files in provision/" \
  "${disk_provisions}" \
  "${yaml_provisions}"

config_section=$(extract_h2_section "${readme}" "構成")
tree_section=$(extract_h2_section "${readme}" "ファイル構成")

readme_config_provisions=$(
  printf '%s\n' "${config_section}" \
    | awk '/^\|/ { print }' \
    | grep -oE 'provision/[A-Za-z0-9_.-]+\.sh' \
    | sort -u || true
)
check_set_equal \
  "provision scripts in ${readme} '## 構成' table do not match provision/*.sh" \
  "${disk_provisions}" \
  "${readme_config_provisions}"

readme_tree_provisions=$(extract_tree_dir_files "${tree_section}" "provision")
check_set_equal \
  "provision scripts in ${readme} '## ファイル構成' do not match provision/*.sh" \
  "${disk_provisions}" \
  "${readme_tree_provisions}"

# 2. scripts/*.sh、scripts/tests/*.sh、docs/*.md の整合性
disk_scripts=$(printf '%s\n' scripts/*.sh | sort -u)
readme_tree_scripts=$(extract_tree_dir_files "${tree_section}" "scripts")
check_set_equal \
  "scripts in ${readme} '## ファイル構成' do not match scripts/*.sh" \
  "${disk_scripts}" \
  "${readme_tree_scripts}"

disk_test_suites=$(printf '%s\n' scripts/tests/*.sh | sort -u)
sourced_test_suites=$(
  awk '!/^[ \t]*#/ && match($0, /scripts\/tests\/[A-Za-z0-9_.-]+\.sh/) { print substr($0, RSTART, RLENGTH) }' scripts/test.sh | sort -u
)
check_set_equal \
  "test suite files sourced in scripts/test.sh do not match scripts/tests/*.sh" \
  "${disk_test_suites}" \
  "${sourced_test_suites}"

defined_test_suites=$(
  awk -F '(' '/^test_[a-z0-9_]+\(\)/ { sub(/^test_/, "", $1); print $1 }' scripts/tests/*.sh | sort -u
)
selectable_suites_in_runner=$(
  awk '
    /^SELECTABLE_SUITES=\(/ { in_arr = 1; next }
    in_arr && /^\)/ { exit }
    in_arr {
      gsub(/#.*$/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 == "makefile_logic") {
        has_ml = 1
      } else if ($0 != "") {
        suites[$0] = 1
      }
    }
    END {
      if (has_ml) {
        for (s in suites) print s
      }
    }
  ' scripts/test.sh | sort -u
)
check_set_equal \
  "SELECTABLE_SUITES in scripts/test.sh does not match test_*() functions in scripts/tests/*.sh" \
  "${defined_test_suites}" \
  "${selectable_suites_in_runner}"

run_suite_cases=$(
  awk '
    /^run_suite\(\)/ { in_fn = 1; next }
    in_fn && /^\}/ { exit }
    in_fn {
      gsub(/#.*$/, "")
      if (match($0, /^[ \t]*[a-z0-9_]+\)[ \t]*test_[a-z0-9_]+/)) {
        line = substr($0, RSTART, RLENGTH)
        sub(/^[ \t]*/, "", line)
        split(line, parts, /\)[ \t]*test_/)
        if (parts[1] != "" && parts[1] == parts[2]) {
          if (parts[1] == "makefile_logic") {
            has_ml_case = 1
          } else {
            suites[parts[1]] = 1
          }
        }
      }
    }
    END {
      if (has_ml_case) {
        for (s in suites) print s
      }
    }
  ' scripts/test.sh | sort -u
)
check_set_equal \
  "run_suite() cases in scripts/test.sh do not match test_*() functions in scripts/tests/*.sh" \
  "${defined_test_suites}" \
  "${run_suite_cases}"

default_executed_suites=$(
  awk '
    /^ALL_SUITES=\(/ { in_all = 1; next }
    in_all && /^\)/ { in_all = 0; next }
    in_all {
      gsub(/#.*$/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 == "makefile_logic") {
        has_ml_in_all = 1
      } else if ($0 != "") {
        all_suites[$0] = 1
      }
      next
    }
    /^MAKEFILE_LOGIC_SUITES=\(/ { in_ml_arr = 1; next }
    in_ml_arr && /^\)/ { in_ml_arr = 0; next }
    in_ml_arr {
      gsub(/#.*$/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      if ($0 != "") ml_suites[$0] = 1
      next
    }
    /^test_makefile_logic\(\)/ { in_ml_fn = 1; next }
    in_ml_fn && /^\}/ { in_ml_fn = 0; next }
    in_ml_fn {
      gsub(/#.*$/, "")
      if ($0 ~ /MAKEFILE_LOGIC_SUITES\[@\]/) ml_fn_uses_arr = 1
      next
    }
    /^append_suite_once\(\)/ { in_append = 1; next }
    in_append && /^\}/ { in_append = 0; next }
    in_append {
      gsub(/#.*$/, "")
      if ($0 ~ /MAKEFILE_LOGIC_SUITES\[@\]/) append_uses_arr = 1
      next
    }
    END {
      for (s in all_suites) print s
      if (has_ml_in_all && ml_fn_uses_arr && append_uses_arr) {
        for (s in ml_suites) print s
      }
    }
  ' scripts/test.sh | sort -u
)
check_set_equal \
  "default suites (ALL_SUITES + MAKEFILE_LOGIC_SUITES) in scripts/test.sh do not match test_*() functions in scripts/tests/*.sh" \
  "${defined_test_suites}" \
  "${default_executed_suites}"

disk_docs=$(printf '%s\n' docs/*.md | sort -u)
readme_tree_docs=$(extract_tree_dir_files "${tree_section}" "docs")
check_set_equal \
  "docs in ${readme} '## ファイル構成' do not match docs/*.md" \
  "${disk_docs}" \
  "${readme_tree_docs}"

# 3. Makefile の公開ターゲットと README.md「make で操作する」の表の整合性
makefile_targets=$(awk -F ':.*## ' '/^[a-z-]+:.*## / { print $1 }' Makefile | sort -u)
make_section=$(extract_h3_section "${readme}" "make で操作する")
# shellcheck disable=SC2016
readme_make_targets=$(
  printf '%s\n' "${make_section}" \
    | awk -F '|' '/^\| `make / { print $2 }' \
    | grep -oE '`make [a-z-]+`' \
    | tr -d '`' \
    | awk '{ print $2 }' \
    | sort -u || true
)
check_set_equal \
  "Makefile targets do not match ${readme} '### make で操作する' table" \
  "${makefile_targets}" \
  "${readme_make_targets}"

# 4. base_packages / github_cli_packages と probe コマンド、README.md「基本的なツール」表の整合性
apt_base_and_gh_pkgs=$(
  awk '
    /^(base_packages|github_cli_packages)=\(/ {
      in_arr = 1
      sub(/^(base_packages|github_cli_packages)=\(/, "")
    }
    in_arr {
      sub(/#.*$/, "")
      if (sub(/\).*$/, "")) {
        for (i = 1; i <= NF; i++) {
          if ($i != "") print $i
        }
        in_arr = 0
        next
      }
      for (i = 1; i <= NF; i++) {
        if ($i != "") print $i
      }
    }
  ' provision/apt-packages.sh | sort -u
)

basic_tools_section=$(extract_h3_section "${readme}" "基本的なツール")
readme_basic_pkgs=$(
  printf '%s\n' "${basic_tools_section}" | awk -F '|' '
    /^\|/ && $2 !~ /パッケージ/ && $2 !~ /---/ {
      col = $2
      while ((s = index(col, "（")) > 0) {
        rest = substr(col, s + length("（"))
        e = index(rest, "）")
        if (e == 0) break
        col = substr(col, 1, s - 1) substr(rest, e + length("）"))
      }
      gsub(/、/, " ", col)
      gsub(/,/, " ", col)
      n = split(col, arr, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (arr[i] != "") print arr[i]
      }
    }
  ' | sort -u
)
check_set_equal \
  "packages in provision/apt-packages.sh (base_packages + github_cli_packages) do not match ${readme} '### 基本的なツール' table" \
  "${apt_base_and_gh_pkgs}" \
  "${readme_basic_pkgs}"

probe_basic_cmds=$(
  {
    awk '
      /^- description: basic tools/ { in_probe = 1; next }
      in_probe && /^- description:/ { in_probe = 0 }
      in_probe && match($0, /cmds=\([^)]+\)/) {
        s = substr($0, RSTART + 6, RLENGTH - 7)
        n = split(s, arr, /[ \t]+/)
        for (i = 1; i <= n; i++) {
          if (arr[i] != "") print arr[i]
        }
      }
    ' "${template}"
    echo "gh"
  } | sort -u
)

readme_basic_cmds=$(
  printf '%s\n' "${basic_tools_section}" | awk -F '|' '
    /^\|/ && $2 !~ /パッケージ/ && $2 !~ /---/ {
      col = $3
      while (match(col, /`[^`]+`/)) {
        token = substr(col, RSTART + 1, RLENGTH - 2)
        sub(/ .*$/, "", token)
        if (token != "") {
          print token
        }
        col = substr(col, RSTART + RLENGTH)
      }
    }
  ' | sort -u
)
check_set_equal \
  "probe basic tools commands in ${template} do not match ${readme} '### 基本的なツール' table" \
  "${probe_basic_cmds}" \
  "${readme_basic_cmds}"

# CLI probe の bins=(herdr agy copilot mise) が README.md「構成」に記載されているか
probe_cli_bins=$(
  awk '
    /^- description: herdr, Antigravity/ { in_probe = 1; next }
    in_probe && /^- description:/ { in_probe = 0 }
    in_probe && match($0, /bins=\([^)]+\)/) {
      s = substr($0, RSTART + 6, RLENGTH - 7)
      n = split(s, arr, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (arr[i] != "") print arr[i]
      }
    }
  ' "${template}" | sort -u
)
if [ -z "${probe_cli_bins}" ]; then
  lint_err "could not extract CLI bins=(...) from ${template}"
else
  for bin in ${probe_cli_bins}; do
    # shellcheck disable=SC2088
    if ! printf '%s\n' "${config_section}" | grep -Fq "~/.local/bin/${bin}"; then
      # shellcheck disable=SC2088
      lint_err "CLI binary '~/.local/bin/${bin}' from probe is not documented in ${readme} '## 構成' table"
    fi
  done
fi

# 5. Markdown ファイルの相対リンク・見出しアンカー検査
# GitHub 形式の見出しアンカー一覧を生成する（同名見出しの -1, -2 サフィックスにも対応）
extract_anchors() {
  local md_file="$1"
  awk '
    /^[ \t]*```/ { in_code = !in_code; next }
    !in_code && /^#+ / {
      line = $0
      sub(/^#+[ \t]+/, "", line)
      sub(/[ \t]+#+[ \t]*$/, "", line)
      line = tolower(line)
      gsub(/[`!@#$%^&*()+=\[\]{}\\|;:'\''",.<>\/?~]/, "", line)
      gsub(/（|）|・|、|。|：|；|「|」|『|』|【|】|！|？|〜|—|→/, "", line)
      gsub(/ /, "-", line)
      c = seen[line]++
      if (c == 0) {
        print line
      } else {
        print line "-" c
      }
    }
  ' "${md_file}"
}

check_markdown_links() {
  local md_file="$1"
  local md_dir
  md_dir=$(dirname "${md_file}")

  local links
  links=$(
    awk '
      /^[ \t]*```/ { in_code = !in_code; next }
      !in_code {
        line = $0
        # インラインコード内の `](...)` を除外する
        gsub(/`[^`]*`/, "", line)
        while (match(line, /\]\([^)]+\)/)) {
          target = substr(line, RSTART + 2, RLENGTH - 3)
          print NR ":" target
          line = substr(line, RSTART + RLENGTH)
        }
      }
    ' "${md_file}"
  )

  local entry line_no target file_part anchor_part resolved_file anchors
  while IFS= read -r entry; do
    [ -n "${entry}" ] || continue
    line_no="${entry%%:*}"
    target="${entry#*:}"

    case "${target}" in
      http://*|https://*|mailto:*)
        continue
        ;;
    esac

    if [[ "${target}" == *#* ]]; then
      file_part="${target%%#*}"
      anchor_part="${target#*#}"
    else
      file_part="${target}"
      anchor_part=""
    fi

    if [ -z "${file_part}" ]; then
      resolved_file="${md_file}"
    else
      resolved_file="${md_dir}/${file_part}"
    fi

    if [ ! -e "${resolved_file}" ]; then
      lint_err "${md_file}:${line_no}: broken link target '${target}' (path '${resolved_file}' not found)"
      continue
    fi

    if [ -n "${anchor_part}" ]; then
      if [ ! -f "${resolved_file}" ]; then
        lint_err "${md_file}:${line_no}: cannot check anchor '#${anchor_part}' on non-file '${resolved_file}'"
      else
        anchors=$(extract_anchors "${resolved_file}")
        if ! grep -Fxq "${anchor_part}" <<< "${anchors}"; then
          lint_err "${md_file}:${line_no}: broken link anchor '#${anchor_part}' in '${resolved_file}'"
        fi
      fi
    fi
  done <<< "${links}"
}

for md in "${readme}" docs/*.md; do
  check_markdown_links "${md}"
done

# docs/security.md の probe 総数表記（requirement 1 of N）が実際の probe 数と一致するか検査
if [ -f "docs/security.md" ]; then
  actual_probes=$(
    awk '
      /^probes:/ { in_p = 1; next }
      in_p && /^[a-zA-Z]/ { in_p = 0 }
      in_p && /^[[:space:]]*-[[:space:]]*description:/ { n++ }
      END { print n + 0 }
    ' "${template}"
  )
  if [ "${count}" -gt 0 ] && [ "${actual_probes}" -ne "${count}" ]; then
    lint_err "probe count parsed by awk (${actual_probes}) does not match limactl template yq (${count})"
  fi
  if ! grep -Fq "requirement 1 of ${actual_probes}:" docs/security.md; then
    lint_err "docs/security.md does not match actual probe count ('requirement 1 of ${actual_probes}:')"
  fi
fi

# 6. provision/*.sh および coding-sandbox.yaml 間の重複関数の整合性検査
extract_sh_function_body() {
  local func_name="$1"
  local file="${2:-}"
  # set -o pipefail 下での SIGPIPE を防ぎ、また同一ファイル内の重複定義も検出するため入力を最後まで消費する
  awk -v fn="${func_name}" '
    $0 == fn "() {" {
      start_count++
      if (start_count == 1) {
        in_fn = 1
        print "{"
      }
      next
    }
    in_fn {
      print
      if ($0 == "}") {
        in_fn = 0
        found_end = 1
      }
    }
    END {
      if (start_count != 1 || !found_end || in_fn) {
        exit 1
      }
    }
  ' ${file:+"${file}"}
}

extract_probe_script() {
  local template_file="$1"
  local desc_prefix="$2"
  awk -v prefix="- description: ${desc_prefix}" '
    index($0, prefix) == 1 { in_probe = 1; next }
    in_probe && (/^- description:/ || /^[a-zA-Z]/) { exit }
    in_probe && /^  hint:/ { exit }
    in_probe && /^  script:/ { in_script = 1; next }
    in_script && /^ ? ? ?$/ { print ""; next }
    in_script && /^    / {
      sub(/^    /, "")
      print
    }
  ' "${template_file}"
}

find_probe_index() {
  local template_file="$1"
  local desc_prefix="$2"
  awk -v prefix="- description: ${desc_prefix}" '
    /^probes:/ { in_p = 1; idx = 0; next }
    in_p && /^[a-zA-Z]/ { in_p = 0 }
    in_p && /^[[:space:]]*-[[:space:]]*description:/ {
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (index(line, prefix) == 1) {
        print idx
        found = 1
        exit
      }
      idx++
    }
    END { if (!found) exit 1 }
  ' "${template_file}"
}

compare_function_bodies() {
  local ref_label="$1"
  local ref_body="$2"
  local target_label="$3"
  local target_body="$4"
  local err_msg="$5"

  if [ "${target_body}" != "${ref_body}" ]; then
    lint_err "${err_msg}"
    local ref_tmp="${LIMA_HOME}/ref_fn.tmp"
    local cur_tmp="${LIMA_HOME}/cur_fn.tmp"
    printf '%s\n' "${ref_body}" > "${ref_tmp}"
    printf '%s\n' "${target_body}" > "${cur_tmp}"
    diff -u --label "${ref_label}" --label "${target_label}" "${ref_tmp}" "${cur_tmp}" >&2 || true
  fi
}

check_shared_provision_functions() {
  local fn="$1"
  local check_file_set="$2"
  shift 2
  local files=("$@")
  local expected_files_set actual_files_set ref_file ref_body cur_body f

  if [ "${check_file_set}" = "true" ]; then
    expected_files_set=$(printf '%s\n' "${files[@]}" | sort -u)
    actual_files_set=$(
      awk -v fn="${fn}" '$0 == fn "() {" { print FILENAME }' provision/*.sh | sort -u
    )
    check_set_equal \
      "files defining ${fn}() in provision/*.sh do not match expected set" \
      "${expected_files_set}" \
      "${actual_files_set}"
  fi

  ref_file="${files[0]}"
  if ! ref_body=$(extract_sh_function_body "${fn}" "${ref_file}"); then
    lint_err "could not extract function '${fn}()' from ${ref_file}"
    return
  fi

  for f in "${files[@]:1}"; do
    if ! cur_body=$(extract_sh_function_body "${fn}" "${f}"); then
      lint_err "could not extract function '${fn}()' from ${f}"
    else
      compare_function_bodies \
        "${ref_file}:${fn}()" "${ref_body}" \
        "${f}:${fn}()" "${cur_body}" \
        "function '${fn}()' in ${f} does not match '${fn}()' in ${ref_file}"
    fi
  done
}

download_helper_files=(
  provision/github-cli.sh
  provision/docker-engine.sh
  provision/herdr.sh
  provision/antigravity-cli.sh
  provision/copilot-cli.sh
  provision/mise.sh
)
check_shared_provision_functions "cleanup" "false" "${download_helper_files[@]}"
for fn in is_transient_curl_rc is_transient_http_code download_file; do
  check_shared_provision_functions "${fn}" "true" "${download_helper_files[@]}"
done

verify_cli_files=(
  provision/herdr.sh
  provision/antigravity-cli.sh
  provision/copilot-cli.sh
  provision/mise.sh
)
check_shared_provision_functions "verify_cli" "true" "${verify_cli_files[@]}"

if ! gh_repo_ref_body=$(extract_sh_function_body "is_repo_configured" "provision/github-cli.sh"); then
  lint_err "could not extract function 'is_repo_configured()' from provision/github-cli.sh"
else
  if ! gh_repo_apt_body=$(extract_sh_function_body "is_official_gh_repo_configured" "provision/apt-packages.sh"); then
    lint_err "could not extract function 'is_official_gh_repo_configured()' from provision/apt-packages.sh"
  else
    compare_function_bodies \
      "provision/github-cli.sh:is_repo_configured()" "${gh_repo_ref_body}" \
      "provision/apt-packages.sh:is_official_gh_repo_configured()" "${gh_repo_apt_body}" \
      "function 'is_official_gh_repo_configured()' in provision/apt-packages.sh does not match 'is_repo_configured()' in provision/github-cli.sh"
  fi

  basic_probe_idx=$(find_probe_index "${template}" "basic tools" || printf '?')
  basic_probe_script=$(extract_probe_script "${template}" "basic tools")
  if [ -z "${basic_probe_script}" ] || ! gh_repo_probe_body=$(extract_sh_function_body "check_gh_repo" <<< "${basic_probe_script}"); then
    lint_err "could not extract function 'check_gh_repo()' from basic tools probe in ${template}"
  else
    compare_function_bodies \
      "provision/github-cli.sh:is_repo_configured()" "${gh_repo_ref_body}" \
      "${template} (probes[${basic_probe_idx}]):check_gh_repo()" "${gh_repo_probe_body}" \
      "function 'check_gh_repo()' in ${template} (probes[${basic_probe_idx}]) does not match 'is_repo_configured()' in provision/github-cli.sh"
  fi
fi

if ! herdr_cfg_ref_body=$(extract_sh_function_body "inspect_herdr_config" "provision/herdr.sh"); then
  lint_err "could not extract function 'inspect_herdr_config()' from provision/herdr.sh"
else
  herdr_probe_idx=$(find_probe_index "${template}" "herdr login shell" || printf '?')
  herdr_probe_script=$(extract_probe_script "${template}" "herdr login shell")
  if [ -z "${herdr_probe_script}" ] || ! herdr_cfg_probe_body=$(extract_sh_function_body "inspect_herdr_config" <<< "${herdr_probe_script}"); then
    lint_err "could not extract function 'inspect_herdr_config()' from herdr login shell probe in ${template}"
  else
    compare_function_bodies \
      "provision/herdr.sh:inspect_herdr_config()" "${herdr_cfg_ref_body}" \
      "${template} (probes[${herdr_probe_idx}]):inspect_herdr_config()" "${herdr_cfg_probe_body}" \
      "function 'inspect_herdr_config()' in ${template} (probes[${herdr_probe_idx}]) does not match 'inspect_herdr_config()' in provision/herdr.sh"
  fi
fi

# GITHUB_CLI_KEYRING / GITHUB_CLI_REPO_LIST の既定値リテラルの整合性検査
extract_env_default_literals() {
  local var_name="$1"
  awk -v v="${var_name}" '
    !/^[ \t]*#/ {
      in_sq = 0; in_dq = 0; line = ""
      for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        prev = (i > 1) ? substr($0, i - 1, 1) : ""
        if (c == "\047" && !in_dq) {
          in_sq = !in_sq
        } else if (c == "\"" && !in_sq && prev != "\\") {
          in_dq = !in_dq
        } else if (c == "#" && !in_sq && !in_dq && (i == 1 || prev ~ /[ \t]/)) {
          break
        }
        line = line c
      }
      pat = "\\$\\{" v "([^A-Za-z0-9_][^}]*)?\\}"
      while (match(line, pat)) {
        expr = substr(line, RSTART, RLENGTH)
        prefix = "${" v ":-"
        if (index(expr, prefix) == 1) {
          val = substr(expr, length(prefix) + 1, length(expr) - length(prefix) - 1)
          print (val == "" ? "<empty>" : val)
        } else {
          print "<invalid:" expr ">"
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' provision/*.sh "${template}" | sort -u
}

gh_keyring_defaults=$(extract_env_default_literals "GITHUB_CLI_KEYRING")
check_set_equal \
  "GITHUB_CLI_KEYRING default path across provision/*.sh and ${template} is inconsistent" \
  "/etc/apt/keyrings/githubcli-archive-keyring.gpg" \
  "${gh_keyring_defaults}"

gh_repo_list_defaults=$(extract_env_default_literals "GITHUB_CLI_REPO_LIST")
check_set_equal \
  "GITHUB_CLI_REPO_LIST default path across provision/*.sh and ${template} is inconsistent" \
  "/etc/apt/sources.list.d/github-cli.list" \
  "${gh_repo_list_defaults}"

# 7. GitHub Actions ワークフロー・アクションの steps[*].run 内での ${{ ... }} 直接展開検査
check_workflow_run_expressions() {
  local wf_file="$1"
  local violations
  violations=$(
    awk '
      function leading_spaces(s) {
        match(s, /^[ ]*/)
        return RLENGTH
      }
      function hex_val(h,    i, c, v, d) {
        v = 0
        for (i = 1; i <= length(h); i++) {
          c = tolower(substr(h, i, 1))
          d = index("0123456789abcdef", c)
          if (d == 0) return -1
          v = v * 16 + (d - 1)
        }
        return v
      }
      function repeat_nl(n,    i, out) {
        out = ""
        for (i = 1; i <= n; i++) out = out "\n"
        return out
      }
      function is_target_run_path(p) {
        return (p == "jobs.*.steps[*].run" || p == "runs.steps[*].run")
      }
      function is_target_prefix_path(p) {
        return (p == "" || p == "jobs" || p == "jobs.*" || p == "jobs.*.steps" || p == "jobs.*.steps[*]" || p == "jobs.*.steps[*].run" || p == "runs" || p == "runs.steps" || p == "runs.steps[*]" || p == "runs.steps[*].run")
      }
      function child_path(base, key) {
        if (key == "<<") return base
        if (base == "") return key
        if (base == "jobs") return "jobs.*"
        return base "." key
      }
      function apply_rel(base, rel) {
        if (rel == "") return base
        if (base == "jobs" && substr(rel, 1, 2) == ".*") return "jobs" rel
        if (base == "" && substr(rel, 1, 1) == ".") return substr(rel, 2)
        return base rel
      }
      function clear_anchor(anc,    k) {
        ANCHOR_DEFINED[anc] = 1
        delete ANCHOR_KEY_VAL[anc]
        for (k in ANCHOR_SUB_EXPR) {
          if (index(k, anc SUBSEP) == 1) delete ANCHOR_SUB_EXPR[k]
        }
      }
      function set_anchor_scalar_val(anc, val) {
        if (anc != "" && length(val) <= 256) {
          ANCHOR_KEY_VAL[anc] = val
        }
      }
      function record_suffix_on_enclosing(full_path, extra_rel, own_anc,    d, anc, base, rel) {
        if (own_anc != "") {
          ANCHOR_SUB_EXPR[own_anc, extra_rel] = 1
        }
        for (d = 1; d <= depth; d++) {
          anc = ctx_anchor[d]
          if (anc != "") {
            base = ctx_path[d]
            if (full_path == base) {
              rel = extra_rel
            } else if (base == "jobs" && substr(full_path, 1, 6) == "jobs.*") {
              rel = substr(full_path, 5) extra_rel
            } else if (index(full_path, base) == 1) {
              rel = substr(full_path, length(base) + 1) extra_rel
            } else {
              continue
            }
            ANCHOR_SUB_EXPR[anc, rel] = 1
          }
        }
        for (d = 1; d <= flow_depth; d++) {
          anc = f_anchor[d]
          if (anc != "") {
            base = f_path[d]
            if (full_path == base) {
              rel = extra_rel
            } else if (base == "jobs" && substr(full_path, 1, 6) == "jobs.*") {
              rel = substr(full_path, 5) extra_rel
            } else if (index(full_path, base) == 1) {
              rel = substr(full_path, length(base) + 1) extra_rel
            } else {
              continue
            }
            ANCHOR_SUB_EXPR[anc, rel] = 1
          }
        }
      }
      function report_line(line_no) {
        if (!REPORTED_LINE[line_no]) {
          print line_no ":expr"
          REPORTED_LINE[line_no] = 1
        }
      }
      function check_buf_and_report(line_no, buf, val_path, own_anc) {
        if (index(buf, "${{") > 0) {
          record_suffix_on_enclosing(val_path, "", own_anc)
          if (is_target_run_path(val_path)) {
            report_line(line_no)
          }
          return 1
        }
        return 0
      }
      function resolve_alias_at(alias_name, val_path, own_anc, line_no,    k, prefix, rel, combined) {
        if (!ANCHOR_DEFINED[alias_name]) {
          if (is_target_prefix_path(val_path)) report_line(line_no)
          return
        }
        if (own_anc != "" && (alias_name in ANCHOR_KEY_VAL)) {
          ANCHOR_KEY_VAL[own_anc] = ANCHOR_KEY_VAL[alias_name]
        }
        prefix = alias_name SUBSEP
        for (k in ANCHOR_SUB_EXPR) {
          if (index(k, prefix) == 1 && ANCHOR_SUB_EXPR[k]) {
            rel = substr(k, length(prefix) + 1)
            record_suffix_on_enclosing(val_path, rel, own_anc)
            combined = apply_rel(val_path, rel)
            if (is_target_run_path(combined)) {
              report_line(line_no)
            }
          }
        }
      }
      function scan_sq(s, start_i,    i, n, c, nxt, out) {
        n = length(s); i = start_i; out = ""
        while (i <= n) {
          c = substr(s, i, 1)
          if (c == "\047") {
            nxt = (i < n) ? substr(s, i + 1, 1) : ""
            if (nxt == "\047") {
              out = out "\047"
              i += 2
              continue
            }
            SCAN_OUT = out; SCAN_POS = i + 1; SCAN_CLOSED = 1
            return
          }
          out = out c
          i++
        }
        SCAN_OUT = out; SCAN_POS = n + 1; SCAN_CLOSED = 0
      }
      function scan_dq(s, start_i,    i, n, c, esc, hv, out, trail_ws) {
        n = length(s); i = start_i; out = ""; SCAN_LINE_CONT = 0; trail_ws = 0
        while (i <= n) {
          c = substr(s, i, 1)
          if (c == "\"") {
            SCAN_OUT = out; SCAN_POS = i + 1; SCAN_CLOSED = 1; SCAN_TRAIL_UNESC_WS = 0
            return
          }
          if (c == "\\") {
            if (i == n) {
              SCAN_OUT = out; SCAN_POS = n + 1; SCAN_CLOSED = 0; SCAN_LINE_CONT = 1; SCAN_TRAIL_UNESC_WS = 0
              return
            }
            trail_ws = 0
            esc = substr(s, i + 1, 1)
            if (esc == "x" && i + 3 <= n) {
              hv = hex_val(substr(s, i + 2, 2))
              if (hv >= 32 && hv <= 126) { out = out sprintf("%c", hv); i += 4; continue }
            } else if (esc == "u" && i + 5 <= n) {
              hv = hex_val(substr(s, i + 2, 4))
              if (hv >= 32 && hv <= 126) { out = out sprintf("%c", hv); i += 6; continue }
            } else if (esc == "U" && i + 9 <= n) {
              hv = hex_val(substr(s, i + 2, 8))
              if (hv >= 32 && hv <= 126) { out = out sprintf("%c", hv); i += 10; continue }
            } else if (esc == "\"" || esc == "\\" || esc == "/") {
              out = out esc; i += 2; continue
            } else if (esc == "n") {
              out = out "\n"; i += 2; continue
            } else if (esc == "r") {
              out = out "\r"; i += 2; continue
            } else if (esc == "t") {
              out = out "\t"; i += 2; continue
            } else if (esc == " ") {
              out = out " "; i += 2; continue
            }
            out = out esc; i += 2; continue
          }
          if (c == " " || c == "\t") trail_ws++
          else trail_ws = 0
          out = out c
          i++
        }
        SCAN_OUT = out; SCAN_POS = n + 1; SCAN_CLOSED = 0; SCAN_TRAIL_UNESC_WS = trail_ws
      }
      function strip_plain_comment(s,    i, n, c, prev) {
        n = length(s)
        for (i = 1; i <= n; i++) {
          c = substr(s, i, 1)
          prev = (i > 1) ? substr(s, i - 1, 1) : ""
          if (c == "#" && (i == 1 || prev ~ /[ \t]/)) {
            return substr(s, 1, i - 1)
          }
        }
        return s
      }
      function trim_ws(s) {
        sub(/^[ \t]+/, "", s)
        sub(/[ \t]+$/, "", s)
        return s
      }
      function extract_props(s, register_anc,    tok, mlen) {
        PROP_ANCHOR = ""
        sub(/^[ \t]+/, "", s)
        while (match(s, /^(&[^] \t,#\[{}]+|![^] \t,#\[{}]*)([ \t]+|$)/)) {
          mlen = RLENGTH
          tok = substr(s, 1, mlen)
          sub(/[ \t]+$/, "", tok)
          if (substr(tok, 1, 1) == "&") {
            PROP_ANCHOR = substr(tok, 2)
            if (register_anc && PROP_ANCHOR != "") clear_anchor(PROP_ANCHOR)
          }
          s = substr(s, mlen + 1)
          sub(/^[ \t]+/, "", s)
        }
        PROP_REST = s
        return s
      }
      function parse_scalar_key_atom(s, register_anc,    work, k, k_anc, aname) {
        work = extract_props(s, register_anc)
        k_anc = PROP_ANCHOR
        if (substr(work, 1, 1) == "*") {
          aname = trim_ws(strip_plain_comment(substr(work, 2)))
          return (aname in ANCHOR_KEY_VAL ? ANCHOR_KEY_VAL[aname] : "run")
        }
        if (substr(work, 1, 1) == "\047") {
          scan_sq(work, 2)
          if (!SCAN_CLOSED) return ""
          k = SCAN_OUT
        } else if (substr(work, 1, 1) == "\"") {
          scan_dq(work, 2)
          if (!SCAN_CLOSED) return ""
          k = SCAN_OUT
        } else {
          k = trim_ws(strip_plain_comment(work))
        }
        if (register_anc && k_anc != "") set_anchor_scalar_val(k_anc, k)
        return k
      }
      function parse_mapping_key(s, in_flow, register_anc,    work, rem, k, cpos, mlen, k_anc, aname) {
        work = extract_props(s, register_anc)
        k_anc = PROP_ANCHOR
        if (match(work, /^\*[^] \t,#\[{}:]+[ \t]*:([ \t]+|[,}\]]|$)/)) {
          cpos = index(work, ":")
          aname = substr(work, 2, cpos - 2)
          sub(/[ \t]+$/, "", aname)
          if (!in_flow && substr(work, cpos + 1) !~ /^([ \t]+|$)/) return 0
          k = (aname in ANCHOR_KEY_VAL ? ANCHOR_KEY_VAL[aname] : "run")
          rem = substr(work, cpos + 1)
          PARSED_KEY = k; PARSED_REST = rem
          return 1
        }
        if (substr(work, 1, 1) == "\047") {
          scan_sq(work, 2)
          if (!SCAN_CLOSED) return 0
          k = SCAN_OUT
          rem = substr(work, SCAN_POS)
          if (rem !~ /^[ \t]*:/) return 0
          sub(/^[ \t]*:/, "", rem)
          if (register_anc && k_anc != "") set_anchor_scalar_val(k_anc, k)
          PARSED_KEY = k; PARSED_REST = rem
          return 1
        }
        if (substr(work, 1, 1) == "\"") {
          scan_dq(work, 2)
          if (!SCAN_CLOSED) return 0
          k = SCAN_OUT
          rem = substr(work, SCAN_POS)
          if (rem !~ /^[ \t]*:/) return 0
          sub(/^[ \t]*:/, "", rem)
          if (register_anc && k_anc != "") set_anchor_scalar_val(k_anc, k)
          PARSED_KEY = k; PARSED_REST = rem
          return 1
        }
        if (in_flow) {
          if (match(work, /^[^] \t:#,\[{}\047"*&!][^] \t:#,\[{}\047"]*[ \t]*:([ \t]+|[,}\]]|$)/) || match(work, /^[^] \t:#,\[{}\047"*&!][ \t]*:([ \t]+|[,}\]]|$)/)) {
            cpos = index(work, ":")
            k = substr(work, 1, cpos - 1)
            sub(/[ \t]+$/, "", k)
            rem = substr(work, cpos + 1)
            if (register_anc && k_anc != "") set_anchor_scalar_val(k_anc, k)
            PARSED_KEY = k; PARSED_REST = rem
            return 1
          }
          return 0
        }
        if (match(work, /^[^] \t:#,\[{}\047"*&!][^] \t:#,\[{}\047"]*[ \t]*:([ \t]+|$)/) || match(work, /^[^] \t:#,\[{}\047"*&!][ \t]*:([ \t]+|$)/)) {
          mlen = RLENGTH
          cpos = index(work, ":")
          k = substr(work, 1, cpos - 1)
          sub(/[ \t]+$/, "", k)
          rem = substr(work, mlen + 1)
          if (register_anc && k_anc != "") set_anchor_scalar_val(k_anc, k)
          PARSED_KEY = k; PARSED_REST = rem
          return 1
        }
        return 0
      }
      function finalize_block_anchor(    final_val) {
        if (block_anc == "") return
        if (!block_has_lines) {
          final_val = (block_chomp == "+" ? repeat_nl(block_pending_blanks) : "")
        } else if (block_chomp == "-") {
          final_val = block_key_acc
        } else if (block_chomp == "+") {
          final_val = block_key_acc "\n" repeat_nl(block_pending_blanks)
        } else {
          final_val = block_key_acc "\n"
        }
        set_anchor_scalar_val(block_anc, final_val)
        block_anc = ""
      }
      function elem_path_for_seq(seq_path, is_merge) {
        if (is_merge) return seq_path
        return seq_path "[*]"
      }
      function consume_flow(s, line_no,    c, p, tok, anc, aname, is_m, part, sep) {
        while (length(s) > 0 && flow_depth > 0) {
          if (flow_quote != "") {
            if (flow_quote == "\047") {
              if (s ~ /^[ \t]*$/) { flow_quote_blanks++; return }
              sub(/^[ \t]+/, "", s)
              scan_sq(s, 1)
              part = SCAN_OUT
              if (!SCAN_CLOSED) sub(/[ \t]+$/, "", part)
              sep = (flow_quote_blanks > 0 ? repeat_nl(flow_quote_blanks) : " ")
              flow_quote_blanks = 0
              if (length(flow_quote_key_acc) <= 256) flow_quote_key_acc = flow_quote_key_acc sep part
              check_buf_and_report(line_no, SCAN_OUT, flow_quote_path, flow_quote_anc)
              s = substr(s, SCAN_POS)
              if (SCAN_CLOSED) {
                set_anchor_scalar_val(flow_quote_anc, flow_quote_key_acc)
                flow_quote = ""; flow_quote_buf = ""; flow_quote_key_acc = ""; flow_quote_path = ""; flow_quote_anc = ""
              }
            } else {
              if (!flow_dq_cont && s ~ /^[ \t]*$/) { flow_quote_blanks++; return }
              sub(/^[ \t]+/, "", s)
              if (!flow_dq_cont) flow_quote_buf = ""
              scan_dq(s, 1)
              part = SCAN_OUT
              if (!SCAN_CLOSED && !SCAN_LINE_CONT && SCAN_TRAIL_UNESC_WS > 0) {
                part = substr(part, 1, length(part) - SCAN_TRAIL_UNESC_WS)
              }
              sep = (flow_dq_cont ? "" : (flow_quote_blanks > 0 ? repeat_nl(flow_quote_blanks) : " "))
              flow_quote_blanks = 0
              flow_dq_cont = SCAN_LINE_CONT
              if (length(flow_quote_key_acc) <= 256) flow_quote_key_acc = flow_quote_key_acc sep part
              flow_quote_buf = flow_quote_buf SCAN_OUT
              check_buf_and_report(line_no, flow_quote_buf, flow_quote_path, flow_quote_anc)
              if (SCAN_LINE_CONT && length(flow_quote_buf) > 2) flow_quote_buf = substr(flow_quote_buf, length(flow_quote_buf) - 1)
              else if (!SCAN_LINE_CONT) flow_quote_buf = ""
              s = substr(s, SCAN_POS)
              if (SCAN_CLOSED) {
                set_anchor_scalar_val(flow_quote_anc, flow_quote_key_acc)
                flow_quote = ""; flow_quote_buf = ""; flow_quote_key_acc = ""; flow_quote_path = ""; flow_quote_anc = ""; flow_dq_cont = 0
              }
            }
            continue
          }
          sub(/^[ \t]+/, "", s)
          if (s == "" || substr(s, 1, 1) == "#") return
          c = substr(s, 1, 1)
          if (c == "{" || c == "[") {
            p = f_cur_val_path[flow_depth]
            is_m = f_cur_is_merge[flow_depth]
            anc = f_pending_anc
            f_pending_anc = ""
            if (p == "") p = elem_path_for_seq(f_path[flow_depth], f_is_merge[flow_depth])
            flow_depth++
            f_type[flow_depth] = (c == "{" ? "map" : "seq")
            f_path[flow_depth] = p
            f_is_merge[flow_depth] = (c == "[" ? is_m : 0)
            f_anchor[flow_depth] = anc
            f_expect_val[flow_depth] = 0
            f_cur_val_path[flow_depth] = ""
            f_cur_is_merge[flow_depth] = 0
            s = substr(s, 2)
            continue
          }
          if (c == "}" || c == "]") {
            f_anchor[flow_depth] = ""
            flow_depth--
            if (flow_depth > 0) {
              f_expect_val[flow_depth] = 0
              f_cur_val_path[flow_depth] = ""
              f_cur_is_merge[flow_depth] = 0
            }
            s = substr(s, 2)
            continue
          }
          if (c == ",") {
            f_expect_val[flow_depth] = 0
            f_cur_val_path[flow_depth] = ""
            f_cur_is_merge[flow_depth] = 0
            s = substr(s, 2)
            continue
          }
          if (f_type[flow_depth] == "map" && !f_expect_val[flow_depth]) {
            if (parse_mapping_key(s, 1, 1)) {
              f_expect_val[flow_depth] = 1
              f_cur_is_merge[flow_depth] = (PARSED_KEY == "<<" ? 1 : 0)
              f_cur_val_path[flow_depth] = child_path(f_path[flow_depth], PARSED_KEY)
              s = PARSED_REST
              continue
            }
          }
          p = (f_type[flow_depth] == "map" ? f_cur_val_path[flow_depth] : elem_path_for_seq(f_path[flow_depth], f_is_merge[flow_depth]))
          s = extract_props(s, 1)
          anc = PROP_ANCHOR
          if (s == "" || substr(s, 1, 1) == "#") return
          c = substr(s, 1, 1)
          if (c == "{" || c == "[") {
            f_cur_val_path[flow_depth] = p
            f_pending_anc = anc
            continue
          }
          if (c == "*") {
            match(s, /^\*[^] \t,#\[{}]+/)
            aname = substr(s, 2, RLENGTH - 1)
            resolve_alias_at(aname, p, anc, line_no)
            s = substr(s, RLENGTH + 1)
            continue
          }
          if (c == "\047") {
            scan_sq(s, 2)
            part = SCAN_OUT
            if (!SCAN_CLOSED) sub(/[ \t]+$/, "", part)
            check_buf_and_report(line_no, SCAN_OUT, p, anc)
            s = substr(s, SCAN_POS)
            if (SCAN_CLOSED) {
              set_anchor_scalar_val(anc, part)
            } else {
              flow_quote = "\047"; flow_quote_path = p; flow_quote_anc = anc; flow_quote_buf = ""; flow_quote_key_acc = part; flow_quote_blanks = 0
            }
            continue
          }
          if (c == "\"") {
            scan_dq(s, 2)
            part = SCAN_OUT
            if (!SCAN_CLOSED && !SCAN_LINE_CONT && SCAN_TRAIL_UNESC_WS > 0) {
              part = substr(part, 1, length(part) - SCAN_TRAIL_UNESC_WS)
            }
            check_buf_and_report(line_no, SCAN_OUT, p, anc)
            s = substr(s, SCAN_POS)
            if (SCAN_CLOSED) {
              set_anchor_scalar_val(anc, part)
            } else {
              flow_quote = "\""; flow_quote_path = p; flow_quote_anc = anc
              flow_dq_cont = SCAN_LINE_CONT; flow_quote_key_acc = part; flow_quote_blanks = 0
              flow_quote_buf = (SCAN_LINE_CONT && length(SCAN_OUT) > 2 ? substr(SCAN_OUT, length(SCAN_OUT) - 1) : SCAN_OUT)
            }
            continue
          }
          tok = ""
          while (length(s) > 0) {
            c = substr(s, 1, 1)
            if (c == "," || c == "}" || c == "]") break
            if (c == "#" && (tok == "" || substr(tok, length(tok), 1) ~ /[ \t]/)) { s = ""; break }
            tok = tok c
            s = substr(s, 2)
          }
          tok = trim_ws(tok)
          set_anchor_scalar_val(anc, tok)
          check_buf_and_report(line_no, tok, p, anc)
        }
      }
      function start_value(raw_rest, key_indent, val_path, is_merge_key, line_no, inherited_anc,    v, c, v_clean, anc, aname, part) {
        v = extract_props(raw_rest, 1)
        anc = (PROP_ANCHOR != "" ? PROP_ANCHOR : inherited_anc)
        if (anc != "" && depth > 0 && ctx_path[depth] == val_path && ctx_anchor[depth] == "") {
          ctx_anchor[depth] = anc
        }
        if (v == "" || substr(v, 1, 1) == "#") {
          pending_val = 1
          pending_key_indent = key_indent
          pending_val_path = val_path
          pending_is_merge = is_merge_key
          pending_anc = anc
          return
        }
        c = substr(v, 1, 1)
        if (c == "*") {
          v_clean = trim_ws(strip_plain_comment(v))
          if (match(v_clean, /^\*[^] \t,#\[{}]+$/)) {
            aname = substr(v_clean, 2)
            resolve_alias_at(aname, val_path, anc, line_no)
            return
          }
        }
        if (c == "{" || c == "[") {
          flow_depth = 1
          f_type[1] = (c == "{" ? "map" : "seq")
          f_path[1] = val_path
          f_is_merge[1] = (c == "[" ? is_merge_key : 0)
          f_anchor[1] = anc
          f_expect_val[1] = 0
          f_cur_val_path[1] = ""
          f_cur_is_merge[1] = 0
          f_pending_anc = ""
          consume_flow(substr(v, 2), line_no)
          return
        }
        if (c == "\047") {
          scan_sq(v, 2)
          part = SCAN_OUT
          if (!SCAN_CLOSED) sub(/[ \t]+$/, "", part)
          check_buf_and_report(line_no, SCAN_OUT, val_path, anc)
          if (SCAN_CLOSED) {
            set_anchor_scalar_val(anc, part)
          } else {
            state = "quote"; quote_char = "\047"; quote_path = val_path; quote_anc = anc; quote_buf = ""; quote_key_acc = part; quote_blanks = 0
          }
          return
        }
        if (c == "\"") {
          scan_dq(v, 2)
          part = SCAN_OUT
          if (!SCAN_CLOSED && !SCAN_LINE_CONT && SCAN_TRAIL_UNESC_WS > 0) {
            part = substr(part, 1, length(part) - SCAN_TRAIL_UNESC_WS)
          }
          check_buf_and_report(line_no, SCAN_OUT, val_path, anc)
          if (SCAN_CLOSED) {
            set_anchor_scalar_val(anc, part)
          } else {
            state = "quote"; quote_char = "\""; quote_path = val_path; quote_anc = anc
            quote_dq_cont = SCAN_LINE_CONT; quote_key_acc = part; quote_blanks = 0
            quote_buf = (SCAN_LINE_CONT && length(SCAN_OUT) > 2 ? substr(SCAN_OUT, length(SCAN_OUT) - 1) : SCAN_OUT)
          }
          return
        }
        v_clean = trim_ws(strip_plain_comment(v))
        if (v_clean ~ /^[|>]([-+]?[1-9]?|[1-9][-+]?)$/) {
          state = "block"
          block_path = val_path
          block_anc = anc
          block_style = substr(v_clean, 1, 1)
          block_chomp = (index(v_clean, "-") > 0 ? "-" : (index(v_clean, "+") > 0 ? "+" : ""))
          block_key_acc = ""
          block_has_lines = 0
          block_pending_blanks = 0
          block_min_indent = key_indent + 1
          if (match(v_clean, /[1-9]/)) {
            block_scalar_indent = key_indent + substr(v_clean, RSTART, 1) + 0
          } else {
            block_scalar_indent = 0
          }
          return
        }
        set_anchor_scalar_val(anc, v_clean)
        check_buf_and_report(line_no, v_clean, val_path, anc)
        state = "plain"
        plain_min_indent = key_indent + 1
        plain_path = val_path
        plain_anc = anc
        plain_key_acc = v_clean
        plain_blanks = 0
      }
      BEGIN {
        state = "normal"
        depth = 0
        flow_depth = 0
        flow_quote = ""
        f_pending_anc = ""
        pending_val = 0
        pending_key_indent = -1
        pending_val_path = ""
        pending_is_merge = 0
        pending_anc = ""
        explicit_key_indent = -1
        explicit_key_name = ""
      }
      {
        raw = $0
        sub(/\r$/, "", raw)

        if (flow_depth > 0) {
          consume_flow(raw, NR)
          next
        }

        if (state == "quote") {
          if (quote_char == "\047") {
            if (raw ~ /^[ \t]*$/) { quote_blanks++; next }
            sub_line = raw; sub(/^[ \t]+/, "", sub_line)
            scan_sq(sub_line, 1)
            part = SCAN_OUT
            if (!SCAN_CLOSED) sub(/[ \t]+$/, "", part)
            sep = (quote_blanks > 0 ? repeat_nl(quote_blanks) : " ")
            quote_blanks = 0
            if (length(quote_key_acc) <= 256) quote_key_acc = quote_key_acc sep part
            check_buf_and_report(NR, SCAN_OUT, quote_path, quote_anc)
            if (SCAN_CLOSED) {
              set_anchor_scalar_val(quote_anc, quote_key_acc)
              state = "normal"; quote_buf = ""; quote_key_acc = ""; quote_path = ""; quote_anc = ""
            }
          } else {
            if (!quote_dq_cont && raw ~ /^[ \t]*$/) { quote_blanks++; next }
            sub_line = raw; sub(/^[ \t]+/, "", sub_line)
            if (!quote_dq_cont) quote_buf = ""
            scan_dq(sub_line, 1)
            part = SCAN_OUT
            if (!SCAN_CLOSED && !SCAN_LINE_CONT && SCAN_TRAIL_UNESC_WS > 0) {
              part = substr(part, 1, length(part) - SCAN_TRAIL_UNESC_WS)
            }
            sep = (quote_dq_cont ? "" : (quote_blanks > 0 ? repeat_nl(quote_blanks) : " "))
            quote_blanks = 0
            quote_dq_cont = SCAN_LINE_CONT
            if (length(quote_key_acc) <= 256) quote_key_acc = quote_key_acc sep part
            quote_buf = quote_buf SCAN_OUT
            check_buf_and_report(NR, quote_buf, quote_path, quote_anc)
            if (SCAN_LINE_CONT && length(quote_buf) > 2) quote_buf = substr(quote_buf, length(quote_buf) - 1)
            else if (!SCAN_LINE_CONT) quote_buf = ""
            if (SCAN_CLOSED) {
              set_anchor_scalar_val(quote_anc, quote_key_acc)
              state = "normal"; quote_buf = ""; quote_key_acc = ""; quote_path = ""; quote_anc = ""; quote_dq_cont = 0
            }
          }
          next
        }

        if (state == "block") {
          if (raw ~ /^[ ]*$/) {
            if (block_scalar_indent > 0 && length(raw) > block_scalar_indent) {
              b_content = substr(raw, block_scalar_indent + 1)
              if (block_anc != "" && length(block_key_acc) <= 256) {
                if (!block_has_lines) {
                  block_key_acc = repeat_nl(block_pending_blanks) b_content
                  block_has_lines = 1
                } else if (block_style == "|") {
                  block_key_acc = block_key_acc "\n" repeat_nl(block_pending_blanks) b_content
                } else {
                  block_key_acc = block_key_acc (block_pending_blanks > 0 ? repeat_nl(block_pending_blanks) : " ") b_content
                }
                block_pending_blanks = 0
              }
            } else {
              block_pending_blanks++
            }
            next
          }
          ind = leading_spaces(raw)
          if (block_scalar_indent == 0) {
            if (ind >= block_min_indent) {
              block_scalar_indent = ind
            } else {
              finalize_block_anchor()
              state = "normal"
            }
          } else if (ind < block_scalar_indent) {
            finalize_block_anchor()
            state = "normal"
          }
          if (state == "block") {
            b_content = substr(raw, block_scalar_indent + 1)
            if (block_anc != "" && length(block_key_acc) <= 256) {
              if (!block_has_lines) {
                block_key_acc = repeat_nl(block_pending_blanks) b_content
                block_has_lines = 1
              } else if (block_style == "|") {
                block_key_acc = block_key_acc "\n" repeat_nl(block_pending_blanks) b_content
              } else {
                block_key_acc = block_key_acc (block_pending_blanks > 0 ? repeat_nl(block_pending_blanks) : " ") b_content
              }
              block_pending_blanks = 0
            }
            check_buf_and_report(NR, raw, block_path, block_anc)
            next
          }
        }

        if (state == "plain") {
          if (raw ~ /^[ \t]*$/) { plain_blanks++; next }
          ind = leading_spaces(raw)
          trimmed_chk = raw; sub(/^[ \t]+/, "", trimmed_chk)
          if (substr(trimmed_chk, 1, 1) == "#") next
          if (ind < plain_min_indent) {
            plain_anc = ""
            state = "normal"
          } else {
            p_val = trim_ws(strip_plain_comment(raw))
            if (plain_anc != "" && length(plain_key_acc) <= 256) {
              plain_key_acc = plain_key_acc (plain_blanks > 0 ? repeat_nl(plain_blanks) : " ") p_val
              set_anchor_scalar_val(plain_anc, plain_key_acc)
            }
            plain_blanks = 0
            check_buf_and_report(NR, p_val, plain_path, plain_anc)
            next
          }
        }

        if (raw ~ /^[ \t]*$/) next
        ind = leading_spaces(raw)
        rest_line = substr(raw, ind + 1)
        trimmed_rest = rest_line; sub(/^[ \t]+/, "", trimmed_rest)
        if (substr(trimmed_rest, 1, 1) == "#") next
        if (rest_line ~ /^---([ \t]+|$)/ || rest_line ~ /^\.\.\.([ \t]+|$)/) {
          depth = 0
          pending_val = 0
          explicit_key_indent = -1
          delete ANCHOR_DEFINED
          delete ANCHOR_KEY_VAL
          delete ANCHOR_SUB_EXPR
          next
        }

        if (pending_val) {
          if (ind > pending_key_indent && rest_line !~ /^(-[ \t]+|-$)/ && rest_line !~ /^\?([ \t]+|$)/ && !parse_mapping_key(rest_line, 0, 0)) {
            pv_indent = pending_key_indent
            pv_path = pending_val_path
            pv_merge = pending_is_merge
            pv_anc = pending_anc
            pending_val = 0
            start_value(rest_line, pv_indent, pv_path, pv_merge, NR, pv_anc)
            next
          }
          pending_val = 0
        }

        if (rest_line ~ /^(-[ \t]+|-$)/) {
          while (depth > 0 && (ind < ctx_indent[depth] || (ind == ctx_indent[depth] && ctx_kind[depth] == "seq_item"))) {
            ctx_anchor[depth] = ""
            depth--
          }
          if (explicit_key_indent >= ind) explicit_key_indent = -1
          cur_base = (depth > 0 ? ctx_path[depth] : "")
          is_m_seq = (depth > 0 && ctx_is_merge[depth] ? 1 : 0)
          depth++
          ctx_indent[depth] = ind
          ctx_kind[depth] = "seq_item"
          ctx_path[depth] = elem_path_for_seq(cur_base, is_m_seq)
          ctx_anchor[depth] = ""
          ctx_is_merge[depth] = 0

          if (rest_line == "-") {
            pending_val = 1
            pending_key_indent = ind
            pending_val_path = ctx_path[depth]
            pending_is_merge = 0
            pending_anc = ""
            next
          }
          match(rest_line, /^-[ \t]+/)
          after_dash_col = ind + RLENGTH
          rest_line = substr(rest_line, RLENGTH + 1)
          trimmed_seq = rest_line; sub(/^[ \t]+/, "", trimmed_seq)
          if (trimmed_seq == "" || substr(trimmed_seq, 1, 1) == "#") {
            pending_val = 1
            pending_key_indent = ind
            pending_val_path = ctx_path[depth]
            pending_is_merge = 0
            pending_anc = ""
            next
          }

          if (match(rest_line, /^\?[ \t]+/)) {
            q_rest = substr(rest_line, RLENGTH + 1)
            if (parse_mapping_key(q_rest, 0, 1)) {
              k_path = child_path(ctx_path[depth], PARSED_KEY)
              depth++
              ctx_indent[depth] = after_dash_col
              ctx_kind[depth] = "map_key"
              ctx_path[depth] = k_path
              ctx_anchor[depth] = ""
              ctx_is_merge[depth] = (PARSED_KEY == "<<" ? 1 : 0)
              start_value(PARSED_REST, after_dash_col, k_path, ctx_is_merge[depth], NR, "")
            } else {
              explicit_key_indent = after_dash_col
              explicit_key_name = parse_scalar_key_atom(q_rest, 1)
            }
            next
          }

          if (!parse_mapping_key(rest_line, 0, 1)) {
            start_value(rest_line, ind, ctx_path[depth], 0, NR, "")
            next
          }

          k_path = child_path(ctx_path[depth], PARSED_KEY)
          depth++
          ctx_indent[depth] = after_dash_col
          ctx_kind[depth] = "map_key"
          ctx_path[depth] = k_path
          ctx_anchor[depth] = ""
          ctx_is_merge[depth] = (PARSED_KEY == "<<" ? 1 : 0)
          start_value(PARSED_REST, after_dash_col, k_path, ctx_is_merge[depth], NR, "")
          next
        }

        if (explicit_key_indent == ind && match(rest_line, /^:([ \t]+|$)/)) {
          erest = substr(rest_line, RLENGTH + 1)
          while (depth > 0 && ind <= ctx_indent[depth]) {
            ctx_anchor[depth] = ""
            depth--
          }
          cur_base = (depth > 0 ? ctx_path[depth] : "")
          k_path = child_path(cur_base, explicit_key_name)
          explicit_key_name_saved = explicit_key_name
          explicit_key_indent = -1
          explicit_key_name = ""
          depth++
          ctx_indent[depth] = ind
          ctx_kind[depth] = "map_key"
          ctx_path[depth] = k_path
          ctx_anchor[depth] = ""
          ctx_is_merge[depth] = (explicit_key_name_saved == "<<" ? 1 : 0)
          start_value(erest, ind, k_path, ctx_is_merge[depth], NR, "")
          next
        }

        while (depth > 0 && ind <= ctx_indent[depth]) {
          ctx_anchor[depth] = ""
          depth--
        }
        if (explicit_key_indent >= ind) explicit_key_indent = -1

        if (match(rest_line, /^\?[ \t]+/)) {
          q_rest = substr(rest_line, RLENGTH + 1)
          if (parse_mapping_key(q_rest, 0, 1)) {
            cur_base = (depth > 0 ? ctx_path[depth] : "")
            k_path = child_path(cur_base, PARSED_KEY)
            depth++
            ctx_indent[depth] = ind
            ctx_kind[depth] = "map_key"
            ctx_path[depth] = k_path
            ctx_anchor[depth] = ""
            ctx_is_merge[depth] = (PARSED_KEY == "<<" ? 1 : 0)
            start_value(PARSED_REST, ind, k_path, ctx_is_merge[depth], NR, "")
          } else {
            explicit_key_indent = ind
            explicit_key_name = parse_scalar_key_atom(q_rest, 1)
          }
          next
        }

        if (!parse_mapping_key(rest_line, 0, 1)) {
          cur_base = (depth > 0 ? ctx_path[depth] : "")
          start_value(rest_line, ind, cur_base, 0, NR, "")
          next
        }

        cur_base = (depth > 0 ? ctx_path[depth] : "")
        k_path = child_path(cur_base, PARSED_KEY)
        depth++
        ctx_indent[depth] = ind
        ctx_kind[depth] = "map_key"
        ctx_path[depth] = k_path
        ctx_anchor[depth] = ""
        ctx_is_merge[depth] = (PARSED_KEY == "<<" ? 1 : 0)
        start_value(PARSED_REST, ind, k_path, ctx_is_merge[depth], NR, "")
      }
    ' "${wf_file}"
  )

  local entry line_no
  while IFS= read -r entry; do
    [ -n "${entry}" ] || continue
    line_no="${entry%%:*}"
    lint_err "${wf_file}:${line_no}: direct \${{ ... }} expression in 'run:' block (pass via step 'env:' instead)"
  done <<< "${violations}"
}

if [ ! -f ".github/workflows/ci.yml" ]; then
  lint_err "missing required workflow file '.github/workflows/ci.yml'"
fi
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [ -f "${wf}" ] || continue
  check_workflow_run_expressions "${wf}"
done
if [ -d ".github/actions" ]; then
  action_yamls=$(find .github/actions -type f \( -name '*.yml' -o -name '*.yaml' \) | LC_ALL=C sort)
  while IFS= read -r wf; do
    [ -n "${wf}" ] || continue
    check_workflow_run_expressions "${wf}"
  done <<< "${action_yamls}"
fi

if [ "${lint_errors}" -gt 0 ]; then
  echo "lint failed with ${lint_errors} error(s)." >&2
  exit 1
fi
