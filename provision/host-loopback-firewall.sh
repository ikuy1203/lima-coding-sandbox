#!/bin/bash
# VM から host.lima.internal（ホストのループバック）への接続を遮断する（mode: system / root で実行）
#
# Lima のユーザモードネットワーク（gvisor-tap-vsock）では、ゲートウェイ（host.lima.internal、既定では 192.168.5.2）
# 宛ての通信が、ホストの 127.0.0.1 宛てに変換される（Lima の pkg/networks/usernet/gvproxy.go の NAT。設定では無効にできない）。
# そのため、ホストで 127.0.0.1 に bind しているサービス（ローカルのデータベースや開発サーバなど）に VM から接続できてしまう。
# これを VM の中の nftables で拒否する。
#
# - VM のユーザはパスワードなしで sudo できるため、エージェントはこのルールを解除できる（誤操作の防止にとどまる。README を参照）
# - Lima はゲストの DNS（192.168.5.3:53）宛ての通信を、iptables の DNAT で 192.168.5.2:<ホストエージェントの DNS のポート> に
#   転送している（Lima の boot.Linux/09-host-dns-setup.sh）。DNAT の後の宛先で判定すると名前解決も止まるため、
#   conntrack の変換前の宛先（ct original ip daddr）で判定する
# - Docker のコンテナからの通信は forward のフックを通るため、output と forward の両方で拒否する
# - Docker や Lima の iptables のルールに干渉しないよう、専用のテーブル（inet lima_coding_sandbox）だけを作り直す
#   （nftables.service が読む /etc/nftables.conf は flush ruleset で Docker のルールも消すため使わない）
# - 起動のたびに、provision より前（network-pre.target の前）から有効にするため、systemd のユニットで読み込む
# - param の blockHostLoopback が false のときは、テーブル・ユニット・ルールのファイルを削除する
#
# Lima は起動のたびにこのスクリプトを実行するため、冪等に作ってある。
set -eux -o pipefail

table=lima_coding_sandbox
rules=/etc/lima-coding-sandbox/host-loopback-firewall.nft
service=lima-coding-sandbox-firewall.service
unit=/etc/systemd/system/${service}

# $PARAM_* は Lima が param から設定する
case "${PARAM_blockHostLoopback:-true}" in
true) ;;
false)
  if [ -f "${unit}" ]; then
    systemctl disable "${service}" || true
    rm -f "${unit}"
    systemctl daemon-reload
  fi
  nft delete table inet "${table}" 2>/dev/null || true
  rm -f "${rules}"
  exit 0
  ;;
*)
  echo >&2 "error: param blockHostLoopback must be \"true\" or \"false\": ${PARAM_blockHostLoopback}"
  exit 1
  ;;
esac

# host.lima.internal のアドレス（Lima の既定のネットワークでは 192.168.5.2）。
# ルールのファイルに書き込むため、起動時（ユニットの実行時）には名前解決しない
host_ip=$(getent ahostsv4 host.lima.internal | awk 'NR == 1 { print $1 }')
if ! [[ "${host_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo >&2 "error: failed to resolve host.lima.internal to an IPv4 address: '${host_ip}'"
  exit 1
fi

# 変更があったときだけ置き換える（一時ファイルに作り、nft -c で検査してから置く）
install_if_changed() {
  local src=$1 dst=$2
  if ! cmp -s "${src}" "${dst}"; then
    install -m 0644 -D "${src}" "${dst}"
  fi
  rm -f "${src}"
}

out=$(mktemp)
cat >"${out}" <<EOF
# lima-coding-sandbox の provision/host-loopback-firewall.sh が作成したファイル（起動のたびに上書きされる）。
# VM（Docker のコンテナを含む）から host.lima.internal（${host_ip}、ホストの 127.0.0.1 につながる）への接続を拒否する。
# - 判定は conntrack の変換前の宛先（ct original ip daddr）で行い、192.168.5.3:53 宛てから ${host_ip} へ DNAT される名前解決を通す
# - また、ゲストから直接 ${host_ip}:53 へ送られる DNS 通信も明示的に許可する
table inet ${table}
delete table inet ${table}
table inet ${table} {
  chain output {
    type filter hook output priority filter; policy accept;
    ip daddr ${host_ip} udp dport 53 accept
    ip daddr ${host_ip} tcp dport 53 accept
    ct original ip daddr ${host_ip} counter reject
  }
  chain forward {
    type filter hook forward priority filter; policy accept;
    ip daddr ${host_ip} udp dport 53 accept
    ip daddr ${host_ip} tcp dport 53 accept
    ct original ip daddr ${host_ip} counter reject
  }
}
EOF
if command -v nft >/dev/null; then
  nft -c -f "${out}"
fi
install_if_changed "${out}" "${rules}"

out=$(mktemp)
cat >"${out}" <<EOF
# lima-coding-sandbox の provision/host-loopback-firewall.sh が作成したファイル（起動のたびに上書きされる）
[Unit]
Description=Block connections to the host loopback (host.lima.internal) for lima-coding-sandbox
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${rules}

[Install]
WantedBy=sysinit.target
EOF
install_if_changed "${out}" "${unit}"

systemctl daemon-reload
systemctl enable "${service}"
# 今の起動にも適用する（テーブルの作り直しは 1 回のトランザクションで行われるため、遮断が途切れない）
systemctl restart "${service}"
