#!/bin/bash
# VM の中で再生した音をホストのスピーカーから鳴らせるようにする（mode: system / root で実行）
#
# coding-sandbox.yaml の audio.device: vz で、VM に virtio-sound の再生専用のデバイスが追加される
# （録音用のデバイスは無いため、VM からホストのマイクは使えない）。
# ドライバ（virtio_snd）は Ubuntu のカーネルに含まれていて自動で読み込まれる。
#
# alsa-utils（aplay / speaker-test）と mpg123（MP3 再生）のパッケージは、apt-get update を 1 回に集約するため
# provision/apt-packages.sh でインストールする。
# このスクリプトでは、/dev/snd/* を通常ユーザも読み書きできるようにする udev ルールを設定する:
#   /dev/snd/* は root:audio の 0660 で作られ、通常ユーザは audio グループに入っていない。
#   usermod -aG audio で追加しても、Lima はプロビジョニングより前に ssh の ControlMaster を張っていて、
#   limactl shell のセッションはその接続のグループを引き継ぐため、VM を再起動するまで反映されない。
#   そこで、udev ルールでデバイスのパーミッションを 0666 にする（VM のユーザは 1 人で、sudo もできるため権限は変わらない）。
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

rules=/etc/udev/rules.d/70-lima-coding-sandbox-sound.rules
out=$(mktemp)
cat >"${out}" <<'EOF'
# lima-coding-sandbox の provision/audio.sh が作成したファイル（起動のたびに上書きされる）。
# 通常ユーザ（audio グループに入っていない）も、サウンドデバイスで音を再生できるようにする
SUBSYSTEM=="sound", MODE="0666"
EOF
if ! cmp -s "${out}" "${rules}"; then
  install -m 0644 "${out}" "${rules}"
fi
rm -f "${out}"

# 作成済みのデバイスにも適用する（ルールが変わっていなくても、毎回適用しておく）
udevadm control --reload
udevadm trigger --subsystem-match=sound --action=change
udevadm settle
