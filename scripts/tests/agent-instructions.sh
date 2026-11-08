#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 2: provision/agent-instructions.sh
# -----------------------------------------------------------------------------
test_agent_instructions() {
  local suite="provision/agent-instructions.sh"
  local test_dir="${MASTER_TEST_DIR}/agent_instructions"
  rm -rf "${test_dir}"
  mkdir -p "${test_dir}"

  local fake_home="${test_dir}/home"
  mkdir -p "${fake_home}"

  local copilot_file="${fake_home}/.copilot/copilot-instructions.md"
  local agy_file="${fake_home}/.gemini/config/rules/lima-coding-sandbox.md"

  # 2.1 既定値（false）ではファイルが生成されない
  log_test "${suite}: default (false) creates no files"
  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="false"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  if [ ! -f "${copilot_file}" ] && [ ! -f "${agy_file}" ]; then
    log_pass "${suite}: default (false) creates no files"
  else
    log_fail "${suite}: files created unexpectedly when false"
  fi

  # 2.2 有効化（true）と冪等性
  log_test "${suite}: enable (true) and idempotency"
  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="true"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local b_count1 e_count1
  b_count1=$(grep -c "BEGIN lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  e_count1=$(grep -c "END lima-coding-sandbox agent-instructions" "${copilot_file}" || true)

  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="true"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local b_count2 e_count2
  b_count2=$(grep -c "BEGIN lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  e_count2=$(grep -c "END lima-coding-sandbox agent-instructions" "${copilot_file}" || true)

  if [ -f "${agy_file}" ] && [ "${b_count1}" -eq 1 ] && [ "${e_count1}" -eq 1 ] && \
     [ "${b_count2}" -eq 1 ] && [ "${e_count2}" -eq 1 ]; then
    log_pass "${suite}: enable (true) and idempotency"
  else
    log_fail "${suite}: files not created or markers duplicated"
  fi

  # 2.3 既存の独自指示の保持と無効化時のクリーンアップ
  log_test "${suite}: preserve custom instructions and cleanup managed block"
  printf '# Custom Top Instruction\n\n' > "${copilot_file}.new"
  cat "${copilot_file}" >> "${copilot_file}.new"
  printf '\n\n# Custom Bottom Instruction\n' >> "${copilot_file}.new"
  mv "${copilot_file}.new" "${copilot_file}"

  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="true"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local has_custom_top has_custom_bottom
  has_custom_top=$(grep -c "Custom Top Instruction" "${copilot_file}" || true)
  has_custom_bottom=$(grep -c "Custom Bottom Instruction" "${copilot_file}" || true)

  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="false"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  local b_count_after e_count_after custom_after
  b_count_after=$(grep -c "BEGIN lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  e_count_after=$(grep -c "END lima-coding-sandbox agent-instructions" "${copilot_file}" || true)
  custom_after=$(grep -c "Custom Top Instruction" "${copilot_file}" || true)

  if [ "${has_custom_top}" -eq 1 ] && [ "${has_custom_bottom}" -eq 1 ] && \
     [ "${b_count_after}" -eq 0 ] && [ "${e_count_after}" -eq 0 ] && \
     [ "${custom_after}" -eq 1 ] && [ ! -f "${agy_file}" ]; then
    log_pass "${suite}: preserve custom instructions and cleanup managed block"
  else
    log_fail "${suite}: custom instructions lost or managed block not cleaned up"
  fi

  # 2.4 利用者の独自ルールファイル（agy_file）は false 時に削除されないこと
  log_test "${suite}: preserve user custom antigravity rules"
  mkdir -p "$(dirname "${agy_file}")"
  echo "# Custom Rule without marker" > "${agy_file}"
  (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="false"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  )
  if [ -f "${agy_file}" ] && grep -q "Custom Rule without marker" "${agy_file}"; then
    log_pass "${suite}: preserve user custom antigravity rules"
  else
    log_fail "${suite}: custom antigravity rule overwritten or deleted"
  fi

  # 2.5 不正な値の検証
  log_test "${suite}: reject invalid parameter"
  if (
    export HOME="${fake_home}"
    export PARAM_agentInstructions="invalid_value"
    bash "${REPO_ROOT}/provision/agent-instructions.sh" >/dev/null 2>&1
  ); then
    log_fail "${suite}: should fail on invalid param"
  else
    log_pass "${suite}: reject invalid parameter"
  fi
}
