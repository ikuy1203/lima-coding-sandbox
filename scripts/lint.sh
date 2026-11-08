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

shellcheck provision/*.sh scripts/*.sh scripts/tests/*.sh

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

if [ "${lint_errors}" -gt 0 ]; then
  echo "lint failed with ${lint_errors} error(s)." >&2
  exit 1
fi
