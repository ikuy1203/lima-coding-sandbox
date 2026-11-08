#!/bin/bash
# scripts/test.sh から読み込まれるテストスイート
# shellcheck disable=SC2030,SC2031,SC2329

# -----------------------------------------------------------------------------
# Test Suite 4c: Host helper scripts (stop, delete, herdr-remote, forward, terminfo, update, versions, ssh-config)
# -----------------------------------------------------------------------------
test_host_helper_scripts() {
  local suite="Makefile rules and safety checks"
  local test_dir="${MASTER_TEST_DIR}/host_helper_scripts"
  setup_makefile_test_env "${test_dir}"
  local fake_bin="${test_dir}/bin"
  local lima_log="${test_dir}/limactl.log"
  local empty_env="${test_dir}/empty.env"
  local default_path
  default_path=$(command -p getconf PATH 2>/dev/null || echo "/usr/bin:/bin:/usr/sbin:/sbin")

  # 4.12 make stop (scripts/stop.sh): Running 時の停止、Stopped 時のスキップ、状態照会失敗時のエラー伝播
  log_test "${suite}: make stop stops running instance, skips stopped, and fails on status error"
  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    make -f "${REPO_ROOT}/Makefile" stop ENV_FILE="${empty_env}" >/dev/null 2>&1
  )
  local stop_when_running
  stop_when_running=$(grep -cx "stop" "${lima_log}" || true)

  : > "${lima_log}"
  local stop_msg
  stop_msg=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    make -f "${REPO_ROOT}/Makefile" stop ENV_FILE="${empty_env}" 2>&1
  )
  local stop_when_stopped
  stop_when_stopped=$(grep -cx "stop" "${lima_log}" || true)

  : > "${lima_log}"
  local stop_list_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_LIST_FAIL=1
    make -f "${REPO_ROOT}/Makefile" stop ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || stop_list_fail_rc=$?
  local stop_on_list_fail
  stop_on_list_fail=$(grep -cx "stop" "${lima_log}" || true)

  if [ "${stop_when_running}" -eq 1 ] && [ "${stop_when_stopped}" -eq 0 ] && \
     printf '%s\n' "${stop_msg}" | grep -q "動いていません" && \
     [ "${stop_list_fail_rc}" -ne 0 ] && [ "${stop_on_list_fail}" -eq 0 ]; then
    log_pass "${suite}: make stop stops running instance, skips stopped, and fails on status error"
  else
    log_fail "${suite}: make stop behavior failed"
  fi

  # 4.13 make delete (scripts/delete.sh): 未作成・確認中止・確認承認・YES=1・停止失敗時の削除中止
  log_test "${suite}: make delete confirmation prompt, YES=1, and abort when stop fails"
  : > "${lima_log}"
  local del_nonexistent_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=""
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) && del_nonexistent_ok=1
  local del_nonexistent_calls
  del_nonexistent_calls=$(grep -cx "delete" "${lima_log}" || true)

  # 確認プロンプトで n を入力して中止（未 push 作業データおよび make backup-auth の案内表示も検証）
  : > "${lima_log}"
  local del_aborted=0 del_prompt_out=""
  del_prompt_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    printf 'n\n' | make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" 2>&1
  ) || del_aborted=1
  local del_aborted_calls
  del_aborted_calls=$(grep -cx "delete" "${lima_log}" || true)

  # Running 状態で y を入力して stop -> delete（ゲスト内の署名鍵の指紋表示と stdin 保護も検証）
  local del_guest_home="${test_dir}/del_guest_home"
  mkdir -p "${del_guest_home}/.ssh"
  ssh-keygen -q -t ed25519 -N '' -C "git-signing test@lima-coding-sandbox 2026-11-06" -f "${del_guest_home}/.ssh/id_ed25519_signing"
  local del_expected_fp
  del_expected_fp=$(ssh-keygen -lf "${del_guest_home}/.ssh/id_ed25519_signing.pub" | awk '{print $2}')

  : > "${lima_log}"
  local del_confirmed_ok=0 del_running_out=""
  del_running_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${del_guest_home}"
    printf 'y\n' | make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" 2>&1
  ) && del_confirmed_ok=1
  local del_confirmed_stops del_confirmed_deletes
  del_confirmed_stops=$(grep -cx "stop" "${lima_log}" || true)
  del_confirmed_deletes=$(grep -cx "delete" "${lima_log}" || true)

  # Running 状態で YES=1 の場合も削除前に署名鍵の指紋と削除案内が出力されること
  : > "${lima_log}"
  local del_running_yes_ok=0 del_running_yes_out=""
  del_running_yes_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${del_guest_home}"
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" YES=1 </dev/null 2>&1
  ) && del_running_yes_ok=1

  # Running 状態で limactl stop が失敗した場合は limactl delete を呼ばずに異常終了すること
  : > "${lima_log}"
  local del_stop_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_STOP_FAIL=1
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" YES=1 >/dev/null 2>&1
  ) || del_stop_fail_rc=$?
  local del_after_stop_fail
  del_after_stop_fail=$(grep -cx "delete" "${lima_log}" || true)

  # YES="1"（引用符付き）でもプロンプトなし削除が動き、Stopped 時も削除案内（タイトルと /user/ssh_signing_keys）が出力されること
  : > "${lima_log}"
  local del_yes_ok=0 del_yes_out=""
  del_yes_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" 'YES="1"' </dev/null 2>&1
  ) && del_yes_ok=1
  local del_yes_deletes
  del_yes_deletes=$(grep -cx "delete" "${lima_log}" || true)

  # ゲスト側 ssh-keygen が非 UTF-8 バイト列（\xff）や制御文字を返しても UTF-8 ロケール下で中断せず削除が完走すること
  local del_badbytes_bin="${test_dir}/del_badbytes_bin"
  mkdir -p "${del_badbytes_bin}"
  cat > "${del_badbytes_bin}/ssh-keygen" << 'EOF'
#!/bin/sh
printf '256 SHA256:AbCdEf123456 \377\376\233 bad-comment (ED25519)\n'
EOF
  chmod +x "${del_badbytes_bin}/ssh-keygen"
  : > "${lima_log}"
  local del_badbytes_ok=0 del_badbytes_out=""
  del_badbytes_out=$(
    export LC_ALL=en_US.UTF-8
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${del_guest_home}"
    export STUB_LIMA_GUEST_PATH="${del_badbytes_bin}:${PATH}"
    make -f "${REPO_ROOT}/Makefile" delete ENV_FILE="${empty_env}" YES=1 </dev/null 2>&1
  ) && del_badbytes_ok=1
  local del_badbytes_deletes
  del_badbytes_deletes=$(grep -cx "delete" "${lima_log}" || true)

  if [ "${del_nonexistent_ok}" -eq 1 ] && [ "${del_nonexistent_calls}" -eq 0 ] && \
     [ "${del_aborted}" -eq 1 ] && [ "${del_aborted_calls}" -eq 0 ] && \
     printf '%s\n' "${del_prompt_out}" | grep -q "clone し直すだけでは復元できません" && \
     printf '%s\n' "${del_prompt_out}" | grep -q "make backup-auth" && \
     printf '%s\n' "${del_prompt_out}" | grep -q "/user/ssh_signing_keys" && \
     [ "${del_confirmed_ok}" -eq 1 ] && [ "${del_confirmed_stops}" -eq 1 ] && [ "${del_confirmed_deletes}" -eq 1 ] && \
     printf '%s\n' "${del_running_out}" | grep -qF "${del_expected_fp}" && \
     [ "${del_running_yes_ok}" -eq 1 ] && \
     printf '%s\n' "${del_running_yes_out}" | grep -qF "${del_expected_fp}" && \
     printf '%s\n' "${del_running_yes_out}" | grep -q "/user/ssh_signing_keys" && \
     [ "${del_stop_fail_rc}" -ne 0 ] && [ "${del_after_stop_fail}" -eq 0 ] && \
     [ "${del_yes_ok}" -eq 1 ] && [ "${del_yes_deletes}" -eq 1 ] && \
     printf '%s\n' "${del_yes_out}" | grep -q "タイトル: coding-sandbox <日付>" && \
     printf '%s\n' "${del_yes_out}" | grep -q "/user/ssh_signing_keys" && \
     [ "${del_badbytes_ok}" -eq 1 ] && [ "${del_badbytes_deletes}" -eq 1 ] && \
     printf '%s\n' "${del_badbytes_out}" | grep -qF "SHA256:AbCdEf123456"; then
    log_pass "${suite}: make delete confirmation prompt, YES=1, and abort when stop fails"
  else
    log_fail "${suite}: make delete behavior failed"
  fi

  # 4.14 scripts/herdr-remote.sh: herdr 未導入・ssh 未設定の拒否と正常接続
  log_test "${suite}: scripts/herdr-remote.sh prerequisite checks and remote invocation"
  local herdr_log="${test_dir}/herdr.log"
  cat > "${fake_bin}/ssh" << 'EOF'
#!/bin/bash
set -eu
if [ "${1:-}" = "-G" ]; then
  if [ "${STUB_SSH_G_FAIL:-0}" = "1" ]; then
    exit 255
  fi
  echo "hostname ${STUB_SSH_G_HOSTNAME:-127.0.0.1}"
  if [ -n "${STUB_SSH_G_PORT:-}" ]; then
    echo "port ${STUB_SSH_G_PORT}"
  fi
  exit 0
fi
printf '%s\n' "$@" > "${STUB_SSH_LOG}"
if [ "${STUB_SSH_FAIL:-0}" = "1" ]; then
  exit 255
fi
exit 0
EOF
  chmod +x "${fake_bin}/ssh"

  # herdr が PATH に無い状態で失敗すること
  local no_herdr_failed=0
  (
    export PATH="${fake_bin}:/usr/bin:/bin"
    if command -v herdr >/dev/null 2>&1; then
      exit 1
    fi
    bash "${REPO_ROOT}/scripts/herdr-remote.sh" >/dev/null 2>&1
  ) || no_herdr_failed=1

  cat > "${fake_bin}/herdr" << 'EOF'
#!/bin/bash
set -eu
printf '%s\n' "$*" > "${STUB_HERDR_LOG}"
exit 0
EOF
  chmod +x "${fake_bin}/herdr"

  # ssh -G がホスト名をそのまま返す（Include 未設定）ときに失敗すること（大文字を含む NAME で ssh -G が小文字化した場合も含む）
  local unconf_ssh_failed=0 unconf_upper_ssh_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_HERDR_LOG="${herdr_log}"
    export STUB_SSH_G_HOSTNAME="lima-coding-sandbox"
    bash "${REPO_ROOT}/scripts/herdr-remote.sh" >/dev/null 2>&1
  ) || unconf_ssh_failed=1

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_HERDR_LOG="${herdr_log}"
    export STUB_SSH_G_HOSTNAME="lima-mybox"
    NAME="MyBox" bash "${REPO_ROOT}/scripts/herdr-remote.sh" >/dev/null 2>&1
  ) || unconf_upper_ssh_failed=1

  # ssh -G が 127.0.0.1 を返すときに herdr --remote lima-<NAME> が呼ばれること
  : > "${herdr_log}"
  local herdr_remote_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_HERDR_LOG="${herdr_log}"
    export STUB_SSH_G_HOSTNAME="127.0.0.1"
    export STUB_LIMA_STATUS_OUTPUT="sandbox2 Running"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" herdr-remote ENV_FILE="${empty_env}" 'NAME="sandbox2"' >/dev/null 2>&1
  ) && herdr_remote_ok=1

  if [ "${no_herdr_failed}" -eq 1 ] && [ "${unconf_ssh_failed}" -eq 1 ] && \
     [ "${unconf_upper_ssh_failed}" -eq 1 ] && \
     [ "${herdr_remote_ok}" -eq 1 ] && grep -qx -- "--remote lima-sandbox2" "${herdr_log}"; then
    log_pass "${suite}: scripts/herdr-remote.sh prerequisite checks and remote invocation"
  else
    log_fail "${suite}: scripts/herdr-remote.sh checks failed"
  fi

  # 4.15 make forward (scripts/forward.sh): PORT / HOST_PORT 検証、ControlMaster 無効化オプション、ssh 失敗伝播
  log_test "${suite}: make forward port validation, ControlMaster options, and ssh error propagation"
  local ssh_log="${test_dir}/ssh.log"
  local no_port_failed=0 bad_port_failed=0 bad_host_port_failed=0 forward_ok=0 forward_ssh_fail_rc=0

  (
    export PATH="${fake_bin}:${PATH}"
    bash "${REPO_ROOT}/scripts/forward.sh" >/dev/null 2>&1
  ) || no_port_failed=1

  (
    export PATH="${fake_bin}:${PATH}"
    PORT="abc" bash "${REPO_ROOT}/scripts/forward.sh" >/dev/null 2>&1
  ) || bad_port_failed=1

  (
    export PATH="${fake_bin}:${PATH}"
    PORT="3000" HOST_PORT="abc" bash "${REPO_ROOT}/scripts/forward.sh" >/dev/null 2>&1
  ) || bad_host_port_failed=1

  : > "${ssh_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_DIR_OUTPUT="/tmp/test-lima-instance"
    export STUB_SSH_LOG="${ssh_log}"
    make -f "${REPO_ROOT}/Makefile" forward ENV_FILE="${empty_env}" 'PORT="3000"' 'HOST_PORT="13000"' >/dev/null 2>&1
  ) && forward_ok=1

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_DIR_OUTPUT="/tmp/test-lima-instance"
    export STUB_SSH_LOG="${test_dir}/ssh_fail.log"
    export STUB_SSH_FAIL=1
    make -f "${REPO_ROOT}/Makefile" forward ENV_FILE="${empty_env}" PORT=3000 >/dev/null 2>&1
  ) || forward_ssh_fail_rc=$?

  if [ "${no_port_failed}" -eq 1 ] && [ "${bad_port_failed}" -eq 1 ] && \
     [ "${bad_host_port_failed}" -eq 1 ] && [ "${forward_ok}" -eq 1 ] && \
     [ "${forward_ssh_fail_rc}" -ne 0 ] && \
     grep -qx "/tmp/test-lima-instance/ssh.config" "${ssh_log}" && \
     grep -qx "ControlMaster=no" "${ssh_log}" && \
     grep -qx "ControlPath=none" "${ssh_log}" && \
     grep -qx "ExitOnForwardFailure=yes" "${ssh_log}" && \
     grep -qx -- "-N" "${ssh_log}" && \
     grep -qx "127.0.0.1:13000:127.0.0.1:3000" "${ssh_log}" && \
     grep -qx "lima-coding-sandbox" "${ssh_log}"; then
    log_pass "${suite}: make forward port validation, ControlMaster options, and ssh error propagation"
  else
    log_fail "${suite}: make forward validation or ssh invocation failed"
  fi

  # 4.16 make terminfo (scripts/terminfo.sh): 事前検証（起動前失敗）、tic -x - 引数検証、tic 失敗伝播
  log_test "${suite}: make terminfo pre-start check, tic arguments, and tic failure propagation"
  cat > "${fake_bin}/infocmp" << 'EOF'
#!/bin/bash
set -eu
if [ "${STUB_INFOCMP_FAIL:-0}" = "1" ]; then
  exit 1
fi
echo "fake-terminfo-data-for-$*"
EOF
  chmod +x "${fake_bin}/infocmp"

  # TERM_NAME が空、または infocmp 失敗時は start (limactl) が呼ばれる前に失敗すること
  : > "${lima_log}"
  local empty_term_failed=0 missing_term_failed=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" TERM_NAME="" >/dev/null 2>&1
  ) || empty_term_failed=1

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_INFOCMP_FAIL=1
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" TERM_NAME="xterm-ghostty" >/dev/null 2>&1
  ) || missing_term_failed=1

  local lima_calls_on_term_fail
  lima_calls_on_term_fail=$(wc -l < "${lima_log}" | tr -d ' ')

  # 正常時は infocmp の出力が limactl shell <NAME> tic -x - の標準入力に渡ること
  local tic_stdin="${test_dir}/tic.stdin"
  : > "${lima_log}"
  local terminfo_ok=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_SHELL_STDIN="${tic_stdin}"
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" 'TERM_NAME="xterm-ghostty"' >/dev/null 2>&1
  ) && terminfo_ok=1

  # tic (limactl shell) が失敗した場合は非ゼロ終了すること
  local tic_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_SHELL_STDIN="${tic_stdin}"
    export STUB_LIMA_SHELL_FAIL=1
    make -f "${REPO_ROOT}/Makefile" terminfo ENV_FILE="${empty_env}" TERM_NAME="xterm-ghostty" >/dev/null 2>&1
  ) || tic_fail_rc=$?

  if [ "${empty_term_failed}" -eq 1 ] && [ "${missing_term_failed}" -eq 1 ] && \
     [ "${lima_calls_on_term_fail}" -eq 0 ] && [ "${terminfo_ok}" -eq 1 ] && \
     [ "${tic_fail_rc}" -ne 0 ] && \
     grep -q "fake-terminfo-data-for--x xterm-ghostty" "${tic_stdin}" && \
     grep -qx "tic" "${lima_log}" && grep -qx -- "-x" "${lima_log}" && grep -qx -- "-" "${lima_log}"; then
    log_pass "${suite}: make terminfo pre-start check, tic arguments, and tic failure propagation"
  else
    log_fail "${suite}: make terminfo check or tic piping failed"
  fi

  # 4.21 make update (scripts/update.sh): 未作成・停止中拒否・非対話一括更新・HERDR_ENV 解除・herdr スキップ通知・再起動要否通知・途中失敗伝播
  log_test "${suite}: make update non-interactive execution, herdr skip notice, reboot notice, and error propagation"
  local update_guest_home="${test_dir}/update_guest_home"
  local update_guest_bin="${test_dir}/update_guest_bin"
  local update_cmd_log="${test_dir}/update_cmd.log"
  local update_reboot_file="${test_dir}/reboot-required"
  mkdir -p "${update_guest_home}/.local/bin" "${update_guest_bin}"

  cat > "${update_guest_home}/.local/bin/herdr" << 'EOF'
#!/bin/bash
set -eu
if [ -n "${HERDR_ENV:-}" ]; then
  echo >&2 "error: HERDR_ENV must be unset before running herdr update"
  exit 1
fi
printf 'herdr %s\n' "$*" >> "${STUB_UPDATE_CMD_LOG}"
if [ "${STUB_HERDR_UPDATE_FAIL:-0}" = "1" ]; then
  echo >&2 "herdr update error"
  exit 1
fi
if [ "${STUB_HERDR_SESSION_RUNNING:-0}" = "1" ]; then
  echo >&2 "Herdr was not updated."
  echo >&2 "Stop running Herdr sessions when ready, then run \`herdr update\` again."
  exit 0
fi
echo "Updated herdr to 0.9.5."
EOF
  chmod +x "${update_guest_home}/.local/bin/herdr"

  cat > "${update_guest_home}/.local/bin/copilot" << 'EOF'
#!/bin/bash
set -eu
printf 'copilot %s\n' "$*" >> "${STUB_UPDATE_CMD_LOG}"
if [ "${STUB_COPILOT_UPDATE_FAIL:-0}" = "1" ]; then
  exit 1
fi
echo "GitHub Copilot CLI updated."
EOF
  chmod +x "${update_guest_home}/.local/bin/copilot"

  cat > "${update_guest_home}/.local/bin/mise" << 'EOF'
#!/bin/bash
set -eu
printf 'mise %s\n' "$*" >> "${STUB_UPDATE_CMD_LOG}"
echo "mise self-updated."
EOF
  chmod +x "${update_guest_home}/.local/bin/mise"

  create_noop_stubs "${update_guest_bin}" fdfind

  cat > "${update_guest_bin}/sudo" << 'EOF'
#!/bin/bash
set -eu
printf 'sudo %s\n' "$*" >> "${STUB_UPDATE_CMD_LOG}"
case "$*" in
  *"apt-get"*update)
    if [ "${STUB_APT_UPDATE_NONLOCK_FAIL:-0}" = "1" ]; then
      echo >&2 "E: Failed to fetch https://example.com/dists/stable/InRelease"
      exit 100
    fi
    if [ "${STUB_APT_UPDATE_ALWAYS_FAIL:-0}" = "1" ]; then
      echo >&2 "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1234 (apt-get)"
      exit 100
    fi
    if [ -n "${STUB_APT_UPDATE_FAIL_ONCE_FILE:-}" ] && [ -f "${STUB_APT_UPDATE_FAIL_ONCE_FILE}" ]; then
      rm -f "${STUB_APT_UPDATE_FAIL_ONCE_FILE}"
      echo >&2 "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1234 (apt-get)"
      exit 100
    fi
    ;;
esac
exit 0
EOF
  chmod +x "${update_guest_bin}/sudo"

  # 1) 未作成・停止中・空 NAME の拒否（空 NAME は limactl を呼ぶ前に拒否されること）
  local upd_missing_rc=0 upd_stopped_rc=0 upd_badname_rc=0 upd_badname_lima_calls=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=""
    make -f "${REPO_ROOT}/Makefile" update ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || upd_missing_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    make -f "${REPO_ROOT}/Makefile" update ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || upd_stopped_rc=$?

  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    make -f "${REPO_ROOT}/Makefile" update ENV_FILE="${empty_env}" NAME=' "" ' >/dev/null 2>&1
  ) || upd_badname_rc=$?
  upd_badname_lima_calls=$(wc -l < "${lima_log}" | tr -d ' ')

  # 2) 正常更新（HERDR_ENV=1 がホストから渡されても解除され、再起動不要・herdr スキップなし）
  : > "${update_cmd_log}"
  rm -f "${update_reboot_file}"
  local upd_normal_ok=0 upd_normal_out=""
  upd_normal_out=$(
    export PATH="${fake_bin}:${PATH}"
    export HERDR_ENV=1
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${update_guest_home}"
    export STUB_LIMA_GUEST_PATH="${update_guest_bin}:${default_path}:${PATH}"
    export STUB_UPDATE_CMD_LOG="${update_cmd_log}"
    export LIMA_SANDBOX_REBOOT_REQUIRED_FILE="${update_reboot_file}"
    make -f "${REPO_ROOT}/Makefile" update ENV_FILE="${empty_env}" 2>&1
  ) && upd_normal_ok=1
  local upd_normal_cmds
  upd_normal_cmds=$(cat "${update_cmd_log}")

  # 3) herdr セッション稼働中（Herdr was not updated. 出力時）・apt-get update 1 回目ロック失敗からの再試行回復・再起動必要（reboot-required 存在時）の案内表示
  : > "${update_cmd_log}"
  touch "${update_reboot_file}"
  local apt_fail_once_file="${test_dir}/apt_fail_once"
  touch "${apt_fail_once_file}"
  local upd_notice_ok=0 upd_notice_out=""
  upd_notice_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${update_guest_home}"
    export STUB_LIMA_GUEST_PATH="${update_guest_bin}:${default_path}:${PATH}"
    export STUB_UPDATE_CMD_LOG="${update_cmd_log}"
    export STUB_HERDR_SESSION_RUNNING=1
    export STUB_APT_UPDATE_FAIL_ONCE_FILE="${apt_fail_once_file}"
    export LIMA_SANDBOX_APT_UPDATE_SLEEP=0
    export LIMA_SANDBOX_REBOOT_REQUIRED_FILE="${update_reboot_file}"
    make -f "${REPO_ROOT}/Makefile" update ENV_FILE="${empty_env}" 2>&1
  ) && upd_notice_ok=1
  local upd_notice_apt_update_calls
  upd_notice_apt_update_calls=$(grep -cx "sudo -n apt-get --error-on=any update" "${update_cmd_log}" || true)

  # 4) 途中コマンド（herdr update・copilot update・apt-get update 再試行上限到達）失敗時は後続を実行せず非ゼロ終了すること
  : > "${update_cmd_log}"
  local upd_herdr_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${update_guest_home}"
    export STUB_LIMA_GUEST_PATH="${update_guest_bin}:${default_path}:${PATH}"
    export STUB_UPDATE_CMD_LOG="${update_cmd_log}"
    export STUB_HERDR_UPDATE_FAIL=1
    make -f "${REPO_ROOT}/Makefile" update ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || upd_herdr_fail_rc=$?
  local upd_herdr_fail_cmds
  upd_herdr_fail_cmds=$(cat "${update_cmd_log}")

  : > "${update_cmd_log}"
  local upd_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${update_guest_home}"
    export STUB_LIMA_GUEST_PATH="${update_guest_bin}:${default_path}:${PATH}"
    export STUB_UPDATE_CMD_LOG="${update_cmd_log}"
    export STUB_COPILOT_UPDATE_FAIL=1
    make -f "${REPO_ROOT}/Makefile" update ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || upd_fail_rc=$?
  local upd_fail_cmds
  upd_fail_cmds=$(cat "${update_cmd_log}")

  : > "${update_cmd_log}"
  local upd_apt_fail_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${update_guest_home}"
    export STUB_LIMA_GUEST_PATH="${update_guest_bin}:${default_path}:${PATH}"
    export STUB_UPDATE_CMD_LOG="${update_cmd_log}"
    export STUB_APT_UPDATE_ALWAYS_FAIL=1
    export LIMA_SANDBOX_APT_UPDATE_ATTEMPTS=2
    export LIMA_SANDBOX_APT_UPDATE_SLEEP=0
    bash "${REPO_ROOT}/scripts/update.sh" >/dev/null 2>&1
  ) || upd_apt_fail_rc=$?
  local upd_apt_fail_cmds upd_apt_fail_calls
  upd_apt_fail_cmds=$(cat "${update_cmd_log}")
  upd_apt_fail_calls=$(grep -cx "sudo -n apt-get --error-on=any update" "${update_cmd_log}" || true)

  : > "${update_cmd_log}"
  local upd_apt_nonlock_rc=0
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${update_guest_home}"
    export STUB_LIMA_GUEST_PATH="${update_guest_bin}:${default_path}:${PATH}"
    export STUB_UPDATE_CMD_LOG="${update_cmd_log}"
    export STUB_APT_UPDATE_NONLOCK_FAIL=1
    export LIMA_SANDBOX_APT_UPDATE_ATTEMPTS=5
    export LIMA_SANDBOX_APT_UPDATE_SLEEP=0
    bash "${REPO_ROOT}/scripts/update.sh" >/dev/null 2>&1
  ) || upd_apt_nonlock_rc=$?
  local upd_apt_nonlock_cmds upd_apt_nonlock_calls
  upd_apt_nonlock_cmds=$(cat "${update_cmd_log}")
  upd_apt_nonlock_calls=$(grep -cx "sudo -n apt-get --error-on=any update" "${update_cmd_log}" || true)

  if [ "${upd_missing_rc}" -ne 0 ] && [ "${upd_stopped_rc}" -ne 0 ] && [ "${upd_badname_rc}" -ne 0 ] && \
     [ "${upd_badname_lima_calls}" -eq 0 ] && \
     [ "${upd_normal_ok}" -eq 1 ] && \
     printf '%s\n' "${upd_normal_cmds}" | grep -qx "herdr update" && \
     printf '%s\n' "${upd_normal_cmds}" | grep -qx "copilot update" && \
     printf '%s\n' "${upd_normal_cmds}" | grep -qx "mise self-update -y" && \
     printf '%s\n' "${upd_normal_cmds}" | grep -qx "sudo -n apt-get --error-on=any update" && \
     printf '%s\n' "${upd_normal_cmds}" | grep -q "sudo -n DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 upgrade -y --with-new-pkgs" && \
     printf '%s\n' "${upd_normal_cmds}" | grep -q "sudo -n ln -sf .* /usr/local/bin/fd" && \
     ! printf '%s\n' "${upd_normal_out}" | grep -q "herdr のバイナリ更新はスキップされました" && \
     ! printf '%s\n' "${upd_normal_out}" | grep -q "make restart" && \
     [ "${upd_notice_ok}" -eq 1 ] && \
     [ "${upd_notice_apt_update_calls}" -eq 2 ] && \
     printf '%s\n' "${upd_notice_out}" | grep -q "herdr のバイナリ更新はスキップされました" && \
     printf '%s\n' "${upd_notice_out}" | grep -q "make restart" && \
     [ "${upd_herdr_fail_rc}" -ne 0 ] && \
     ! printf '%s\n' "${upd_herdr_fail_cmds}" | grep -q "copilot update" && \
     [ "${upd_fail_rc}" -ne 0 ] && \
     ! printf '%s\n' "${upd_fail_cmds}" | grep -q "mise self-update" && \
     [ "${upd_apt_fail_rc}" -eq 100 ] && \
     [ "${upd_apt_fail_calls}" -eq 2 ] && \
     ! printf '%s\n' "${upd_apt_fail_cmds}" | grep -q "upgrade" && \
     [ "${upd_apt_nonlock_rc}" -eq 100 ] && \
     [ "${upd_apt_nonlock_calls}" -eq 1 ] && \
     ! printf '%s\n' "${upd_apt_nonlock_cmds}" | grep -q "upgrade"; then
    log_pass "${suite}: make update non-interactive execution, herdr skip notice, reboot notice, and error propagation"
  else
    log_fail "${suite}: make update checks failed (missing=${upd_missing_rc}, stopped=${upd_stopped_rc}, badname_calls=${upd_badname_lima_calls}, normal=${upd_normal_ok}, notice=${upd_notice_ok}, apt_calls=${upd_notice_apt_update_calls}, herdr_fail=${upd_herdr_fail_rc}, fail_rc=${upd_fail_rc}, apt_fail_rc=${upd_apt_fail_rc}, nonlock_rc=${upd_apt_nonlock_rc})"
  fi

  # 4.22 make versions (scripts/versions.sh) および make help: 全 14 項目のバージョン一覧表示とターゲット一覧
  log_test "${suite}: make versions outputs all 14 environment items and make help lists update/versions"
  local ver_guest_home="${test_dir}/ver_guest_home"
  local ver_guest_bin="${test_dir}/ver_guest_bin"
  local fake_os_release="${test_dir}/os-release"
  mkdir -p "${ver_guest_home}/.local/bin" "${ver_guest_bin}"

  cat > "${fake_os_release}" << 'EOF'
PRETTY_NAME="Ubuntu 26.04 LTS"
VERSION="26.04 LTS (Resolute Raccoon)"
EOF

  cat > "${ver_guest_bin}/uname" << 'EOF'
#!/bin/bash
if [ "${1:-}" = "-r" ]; then
  echo "7.0.0-11-generic"
else
  echo "Linux 7.0.0-11-generic"
fi
EOF
  chmod +x "${ver_guest_bin}/uname"

  cat > "${ver_guest_bin}/git" << 'EOF'
#!/bin/bash
echo "git version 2.53.0"
EOF
  chmod +x "${ver_guest_bin}/git"

  cat > "${ver_guest_bin}/gh" << 'EOF'
#!/bin/bash
echo "gh version 2.102.0 (2026-10-01)"
EOF
  chmod +x "${ver_guest_bin}/gh"

  cat > "${ver_guest_bin}/python3" << 'EOF'
#!/bin/bash
echo "Python 3.14.4"
EOF
  chmod +x "${ver_guest_bin}/python3"

  cat > "${ver_guest_bin}/node" << 'EOF'
#!/bin/bash
echo "v22.22.1"
EOF
  chmod +x "${ver_guest_bin}/node"

  cat > "${ver_guest_bin}/docker" << 'EOF'
#!/bin/bash
if [ "${1:-}" = "version" ]; then
  if [ "${STUB_DOCKER_DAEMON_DOWN:-0}" = "1" ]; then
    exit 1
  fi
  echo "29.8.2"
else
  echo "Docker version 29.8.2, build 1234567"
fi
EOF
  chmod +x "${ver_guest_bin}/docker"

  cat > "${ver_guest_bin}/mpg123" << 'EOF'
#!/bin/bash
echo "mpg123 1.33.3"
EOF
  chmod +x "${ver_guest_bin}/mpg123"

  cat > "${ver_guest_home}/.local/bin/herdr" << 'EOF'
#!/bin/bash
echo "herdr 0.9.3"
EOF
  chmod +x "${ver_guest_home}/.local/bin/herdr"

  cat > "${ver_guest_home}/.local/bin/agy" << 'EOF'
#!/bin/bash
echo "1.2.16"
EOF
  chmod +x "${ver_guest_home}/.local/bin/agy"

  cat > "${ver_guest_home}/.local/bin/copilot" << 'EOF'
#!/bin/bash
echo "GitHub Copilot CLI 1.0.91."
EOF
  chmod +x "${ver_guest_home}/.local/bin/copilot"

  cat > "${ver_guest_home}/.local/bin/mise" << 'EOF'
#!/bin/bash
echo "2026.10.7 linux-arm64 (2026-10-07)"
EOF
  chmod +x "${ver_guest_home}/.local/bin/mise"

  local ver_missing_rc=0 ver_stopped_rc=0 ver_ok=0 ver_out="" help_out=""
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=""
    make -f "${REPO_ROOT}/Makefile" versions ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || ver_missing_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    make -f "${REPO_ROOT}/Makefile" versions ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || ver_stopped_rc=$?

  ver_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_VERSION_OUTPUT="2.2.0"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${ver_guest_home}"
    export STUB_LIMA_GUEST_PATH="${ver_guest_bin}:${default_path}:${PATH}"
    export LIMA_SANDBOX_OS_RELEASE_FILE="${fake_os_release}"
    export LIMA_SANDBOX_PYTHON3_BIN="${ver_guest_bin}/python3"
    export LIMA_SANDBOX_NODE_BIN="${ver_guest_bin}/node"
    make -f "${REPO_ROOT}/Makefile" versions ENV_FILE="${empty_env}" 2>&1
  ) && ver_ok=1

  # 個別ツール（例: agy）欠落時や Docker デーモン停止時でも他項目の出力が継続し、(取得失敗) / (クライアント) が表示されること
  rm -f "${ver_guest_home}/.local/bin/agy"
  local ver_partial_ok=0 ver_partial_out=""
  ver_partial_out=$(
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_VERSION_OUTPUT="2.2.0"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_GUEST_HOME="${ver_guest_home}"
    export STUB_LIMA_GUEST_PATH="${ver_guest_bin}:${default_path}:${PATH}"
    export STUB_DOCKER_DAEMON_DOWN=1
    export LIMA_SANDBOX_OS_RELEASE_FILE="${fake_os_release}"
    export LIMA_SANDBOX_PYTHON3_BIN="${ver_guest_bin}/python3"
    export LIMA_SANDBOX_NODE_BIN="${ver_guest_bin}/node"
    make -f "${REPO_ROOT}/Makefile" versions ENV_FILE="${empty_env}" 2>&1
  ) && ver_partial_ok=1

  help_out=$(make -f "${REPO_ROOT}/Makefile" help ENV_FILE="${empty_env}" 2>&1)

  if [ "${ver_missing_rc}" -ne 0 ] && [ "${ver_stopped_rc}" -ne 0 ] && [ "${ver_ok}" -eq 1 ] && \
     [ "${ver_partial_ok}" -eq 1 ] && \
     printf '%s\n' "${ver_out}" | grep -Eq '^(macOS|Linux)[[:space:]]+.+' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^Lima[[:space:]]+2\.2\.0$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^Ubuntu[[:space:]]+26\.04 LTS$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^カーネル {13}7\.0\.0-11-generic$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^git[[:space:]]+2\.53\.0$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^GitHub CLI[[:space:]]+2\.102\.0$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^Python[[:space:]]+3\.14\.4$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^Node\.js[[:space:]]+22\.22\.1$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^Docker Engine[[:space:]]+29\.8\.2$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^herdr[[:space:]]+0\.9\.3$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^mpg123[[:space:]]+1\.33\.3$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^Antigravity CLI[[:space:]]+1\.2\.16$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^GitHub Copilot CLI[[:space:]]+1\.0\.91$' && \
     printf '%s\n' "${ver_out}" | grep -Eq '^mise[[:space:]]+2026\.10\.7$' && \
     printf '%s\n' "${ver_partial_out}" | grep -Eq '^Docker Engine[[:space:]]+29\.8\.2 \(クライアント\)$' && \
     printf '%s\n' "${ver_partial_out}" | grep -Eq '^Antigravity CLI[[:space:]]+\(取得失敗\)$' && \
     printf '%s\n' "${ver_partial_out}" | grep -Eq '^mise[[:space:]]+2026\.10\.7$' && \
     printf '%s\n' "${help_out}" | grep -q "make update" && \
     printf '%s\n' "${help_out}" | grep -q "make versions"; then
    log_pass "${suite}: make versions outputs all 14 environment items and make help lists update/versions"
  else
    log_fail "${suite}: make versions or make help checks failed (missing=${ver_missing_rc}, stopped=${ver_stopped_rc}, ok=${ver_ok})"
  fi

  # 4.23 make ssh-config (scripts/ssh-config.sh): 起動状態確認・Include パス算出・ssh -G 状態判定・ssh.config 出力
  log_test "${suite}: make ssh-config status checks, Include snippet, ssh -G detection, and ssh.config output"
  local ssh_cfg_home="${test_dir}/ssh_cfg_home"
  local ssh_cfg_default_dir="${ssh_cfg_home}/.lima/coding-sandbox"
  local ssh_cfg_upper_dir="${ssh_cfg_home}/.lima/MyBox"
  local ssh_cfg_home_sub_dir="${ssh_cfg_home}/custom-lima/sandbox3"
  local ssh_cfg_custom_dir="${test_dir}/custom lima/sandbox2"
  mkdir -p "${ssh_cfg_default_dir}" "${ssh_cfg_upper_dir}" "${ssh_cfg_home_sub_dir}" "${ssh_cfg_custom_dir}"

  local ssh_cfg_badname_rc=0 ssh_cfg_missing_rc=0 ssh_cfg_stopped_rc=0 ssh_cfg_nofile_rc=0 ssh_cfg_emptyfile_rc=0
  : > "${lima_log}"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" NAME="" >/dev/null 2>&1
  ) || ssh_cfg_badname_rc=$?
  local ssh_cfg_badname_calls
  ssh_cfg_badname_calls=$(wc -l < "${lima_log}" | tr -d ' ')

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT=""
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || ssh_cfg_missing_rc=$?

  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Stopped"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || ssh_cfg_stopped_rc=$?

  # ssh.config が存在しない場合・空ファイルの場合は失敗すること
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_DIR_OUTPUT="${ssh_cfg_default_dir}"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || ssh_cfg_nofile_rc=$?

  : > "${ssh_cfg_default_dir}/ssh.config"
  (
    export PATH="${fake_bin}:${PATH}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_DIR_OUTPUT="${ssh_cfg_default_dir}"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" >/dev/null 2>&1
  ) || ssh_cfg_emptyfile_rc=$?

  cat > "${ssh_cfg_default_dir}/ssh.config" << 'EOF'
Host lima-coding-sandbox
  IdentityFile "/Users/test/.lima/_config/user"
  User test
  Hostname 127.0.0.1
  Port 60022
EOF

  cat > "${ssh_cfg_upper_dir}/ssh.config" << 'EOF'
Host lima-MyBox
  IdentityFile "/Users/test/.lima/_config/user"
  User test
  Hostname 127.0.0.1
  Port 60024
EOF

  cat > "${ssh_cfg_home_sub_dir}/ssh.config" << 'EOF'
Host lima-sandbox3
  IdentityFile "/Users/test/.lima/_config/user"
  User test
  Hostname 127.0.0.1
  Port 60025
EOF

  cat > "${ssh_cfg_custom_dir}/ssh.config" << 'EOF'
Host lima-sandbox2
  IdentityFile "/Users/test/.lima/_config/user"
  User test
  Hostname 127.0.0.1
  Port 60023
EOF

  # 未設定状態（ssh -G がホスト名をそのまま返す）+ 既定 ~/.lima/<NAME> ディレクトリ
  local ssh_cfg_unconf_ok=0 ssh_cfg_unconf_out=""
  ssh_cfg_unconf_out=$(
    export PATH="${fake_bin}:${PATH}"
    export HOME="${ssh_cfg_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="coding-sandbox Running"
    export STUB_LIMA_DIR_OUTPUT="${ssh_cfg_default_dir}"
    export STUB_SSH_G_HOSTNAME="lima-coding-sandbox"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" 2>&1
  ) && ssh_cfg_unconf_ok=1

  # 大文字を含む NAME（ssh -G は小文字化した lima-mybox を返す）で「設定済み」と誤判定せず「未設定」になること
  local ssh_cfg_upper_ok=0 ssh_cfg_upper_out=""
  ssh_cfg_upper_out=$(
    export PATH="${fake_bin}:${PATH}"
    export HOME="${ssh_cfg_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="MyBox Running"
    export STUB_LIMA_DIR_OUTPUT="${ssh_cfg_upper_dir}"
    export STUB_SSH_G_HOSTNAME="lima-mybox"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" NAME="MyBox" 2>&1
  ) && ssh_cfg_upper_ok=1

  # HOME 配下の非既定ディレクトリ（~/custom-lima/sandbox3）+ ssh -G 失敗時（「状態: 不明」）
  local ssh_cfg_unknown_ok=0 ssh_cfg_unknown_out=""
  ssh_cfg_unknown_out=$(
    export PATH="${fake_bin}:${PATH}"
    export HOME="${ssh_cfg_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="sandbox3 Running"
    export STUB_LIMA_DIR_OUTPUT="${ssh_cfg_home_sub_dir}"
    export STUB_SSH_G_FAIL=1
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" NAME="sandbox3" 2>&1
  ) && ssh_cfg_unknown_ok=1

  # 設定済み状態（ssh -G が 127.0.0.1 を返す）+ カスタム NAME + 空白を含むディレクトリパス
  local ssh_cfg_conf_ok=0 ssh_cfg_conf_out=""
  ssh_cfg_conf_out=$(
    export PATH="${fake_bin}:${PATH}"
    export HOME="${ssh_cfg_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="sandbox2 Running"
    export STUB_LIMA_DIR_OUTPUT="${ssh_cfg_custom_dir}"
    export STUB_SSH_G_HOSTNAME="127.0.0.1"
    export STUB_SSH_G_PORT="60023"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" 'NAME="sandbox2"' 2>&1
  ) && ssh_cfg_conf_ok=1

  # 古いポートが ~/.ssh/config に残っている場合（「状態: ポート不一致」）
  local ssh_cfg_mismatch_ok=0 ssh_cfg_mismatch_out=""
  ssh_cfg_mismatch_out=$(
    export PATH="${fake_bin}:${PATH}"
    export HOME="${ssh_cfg_home}"
    export STUB_LIMACTL_LOG="${lima_log}"
    export STUB_LIMA_STATUS_OUTPUT="sandbox2 Running"
    export STUB_LIMA_DIR_OUTPUT="${ssh_cfg_custom_dir}"
    export STUB_SSH_G_HOSTNAME="127.0.0.1"
    export STUB_SSH_G_PORT="59999"
    make -f "${REPO_ROOT}/Makefile" ssh-config ENV_FILE="${empty_env}" 'NAME="sandbox2"' 2>&1
  ) && ssh_cfg_mismatch_ok=1

  if [ "${ssh_cfg_badname_rc}" -ne 0 ] && [ "${ssh_cfg_badname_calls}" -eq 0 ] && \
     [ "${ssh_cfg_missing_rc}" -ne 0 ] && [ "${ssh_cfg_stopped_rc}" -ne 0 ] && \
     [ "${ssh_cfg_nofile_rc}" -ne 0 ] && [ "${ssh_cfg_emptyfile_rc}" -ne 0 ] && \
     [ "${ssh_cfg_unconf_ok}" -eq 1 ] && [ "${ssh_cfg_upper_ok}" -eq 1 ] && \
     [ "${ssh_cfg_unknown_ok}" -eq 1 ] && [ "${ssh_cfg_conf_ok}" -eq 1 ] && \
     [ "${ssh_cfg_mismatch_ok}" -eq 1 ] && \
     printf '%s\n' "${ssh_cfg_unconf_out}" | grep -qx "# ホスト名: lima-coding-sandbox" && \
     printf '%s\n' "${ssh_cfg_unconf_out}" | grep -qx "# 設定ファイル: ~/.lima/coding-sandbox/ssh.config" && \
     printf '%s\n' "${ssh_cfg_unconf_out}" | grep -q "^# 状態: 未設定" && \
     printf '%s\n' "${ssh_cfg_unconf_out}" | grep -qx "#   Include ~/.lima/\*/ssh.config" && \
     printf '%s\n' "${ssh_cfg_unconf_out}" | grep -qx "Host lima-coding-sandbox" && \
     printf '%s\n' "${ssh_cfg_unconf_out}" | grep -qx "  Port 60022" && \
     printf '%s\n' "${ssh_cfg_upper_out}" | grep -qx "# ホスト名: lima-MyBox" && \
     printf '%s\n' "${ssh_cfg_upper_out}" | grep -q "^# 状態: 未設定" && \
     printf '%s\n' "${ssh_cfg_upper_out}" | grep -qx "Host lima-MyBox" && \
     printf '%s\n' "${ssh_cfg_unknown_out}" | grep -qx "# 設定ファイル: ~/custom-lima/sandbox3/ssh.config" && \
     printf '%s\n' "${ssh_cfg_unknown_out}" | grep -q "^# 状態: 不明（ssh -G lima-sandbox3" && \
     printf '%s\n' "${ssh_cfg_unknown_out}" | grep -qx "#   Include ~/custom-lima/\*/ssh.config" && \
     printf '%s\n' "${ssh_cfg_unknown_out}" | grep -qx "Host lima-sandbox3" && \
     printf '%s\n' "${ssh_cfg_conf_out}" | grep -qx "# ホスト名: lima-sandbox2" && \
     printf '%s\n' "${ssh_cfg_conf_out}" | grep -q "^# 状態: 設定済み" && \
     ! printf '%s\n' "${ssh_cfg_conf_out}" | grep -q "Include 行を追加する（初回のみ）" && \
     printf '%s\n' "${ssh_cfg_conf_out}" | grep -Fqx "#   Include \"${test_dir}/custom lima/*/ssh.config\"" && \
     printf '%s\n' "${ssh_cfg_conf_out}" | grep -qx "Host lima-sandbox2" && \
     printf '%s\n' "${ssh_cfg_conf_out}" | grep -qx "  Port 60023" && \
     printf '%s\n' "${ssh_cfg_mismatch_out}" | grep -q "^# 状態: ポート不一致" && \
     printf '%s\n' "${help_out}" | grep -q "make ssh-config"; then
    log_pass "${suite}: make ssh-config status checks, Include snippet, ssh -G detection, and ssh.config output"
  else
    log_fail "${suite}: make ssh-config checks failed (badname=${ssh_cfg_badname_rc}, calls=${ssh_cfg_badname_calls}, missing=${ssh_cfg_missing_rc}, stopped=${ssh_cfg_stopped_rc}, nofile=${ssh_cfg_nofile_rc}, empty=${ssh_cfg_emptyfile_rc}, unconf=${ssh_cfg_unconf_ok}, upper=${ssh_cfg_upper_ok}, unknown=${ssh_cfg_unknown_ok}, conf=${ssh_cfg_conf_ok}, mismatch=${ssh_cfg_mismatch_ok})"
  fi
}
