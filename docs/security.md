# セキュリティと隔離設計

本サンドボックスのセキュリティ境界、ホストディレクトリのマウント混入防止、およびネットワーク隔離（ポート転送とホストループバック接続遮断）の詳細を説明します。基本的な使い方は [README.md](../README.md) を参照してください。

## セキュリティ上の注意

- 隔離の境界は VM です。VM 内のユーザはパスワードなしで sudo できるため、エージェントも VM 内では root 相当の操作ができます
- テンプレートでは、ホストのディレクトリのマウント、SSH エージェントの転送、ホストの `~/.ssh/*.pub` の読み込みを、いずれも無効にしています。マウントだけは Lima のグローバル設定から混入しうるため、起動時に検出しています（[ホストのマウントが混入しないように](#ホストのマウントが混入しないように)）
- ホストの herdr からリモート接続（`make herdr-remote`）したり、VS Code / Cursor の Remote - SSH で接続したりしても、Lima の設定（`~/.lima/<NAME>/ssh.config`）自体は SSH エージェントを転送しません（VM 内では `SSH_AUTH_SOCK` が設定されません）。ただし、これらの接続はホストの `~/.ssh/config` を使うため、`Host *` などで `ForwardAgent yes` を設定していると転送されることがあります。その場合は `lima-*` を対象から外してください
- ポートの自動転送は無効化しています（`portForwards` 設定）。この設定はホスト側の Lima（hostagent）が適用するため、VM 内のユーザが sudo を使っても回避できません。ホストからアクセスしたいポートがあるときは `make forward PORT=<ポート>` を使用してください（[ネットワーク](#ネットワーク)）。なお、VS Code / Cursor の Remote - SSH で接続している間は、エディタ自身の自動ポート転送機能（`remote.autoForwardPorts`）が既定で働く点に注意してください（[VS Code / Cursor から接続する（Remote - SSH）](../README.md#vs-code--cursor-から接続するremote---ssh)）
- VM からはインターネットに接続できます。また、Lima の仕様上 `host.lima.internal`（`192.168.5.2`）はホストのループバックアドレスにつながっていますが、本サンドボックスでは VM 内の nftables により既定で接続を遮断しています。ただし VM 内のユーザはパスワードなしで sudo できるため、エージェントが意図してファイアウォールを解除することは防げません（誤操作の防止にとどまります）。また、Lima の NAT 仕様やホストのパケットフィルタ（pf）では VM からのループバック接続のみを識別して止めることができないため、認証のない機密サービスをホストで稼働させている場合は引き続き注意してください
- 各 CLI の認証情報は VM 内に保存されます（Copilot CLI と gh は平文で保存される場合があります）。不要になったら `limactl delete` で VM ごと削除してください。また、`make backup-auth` でホストに退避した認証情報・署名鍵（既定は `~/.local/share/lima-coding-sandbox/auth-backup/<NAME>`）も、不要になったらホストから削除してください
- gh でログインすると、そのトークン（既定のスコープは `repo`・`read:org`・`gist`）は、VM 内で同じユーザとして動くエージェントからも使えます。エージェントは、あなたの GitHub アカウントでアクセスできるリポジトリに push したり、issue や PR を作ったりできます。権限を絞りたいときは、対象のリポジトリと権限を限定した fine-grained PAT を、`gh auth login` の代わりに環境変数 `GH_TOKEN` で渡してください（`GH_TOKEN` は Copilot CLI の `/login` で保存したトークンよりも優先されるため、Copilot CLI が使うトークンも変わる点に注意してください）。また、VS Code / Cursor の Remote - SSH で接続すると、既定ではホスト側エディタの GitHub 認証情報がリモート環境の Git / ターミナルやリモート拡張ホスト上の拡張機能へ引き継がれるため、権限を絞る場合はエディタ側の `"github.gitAuthentication": false`・`"git.terminalAuthentication": false` の設定や、VM 側で動作する GitHub 連携拡張機能の扱いに注意してください（[VS Code / Cursor から接続する（Remote - SSH）](../README.md#vs-code--cursor-から接続するremote---ssh)）
- Git のコミット署名鍵（`~/.ssh/id_ed25519_signing`）には、エージェントが非対話でコミットできるようパスフレーズを付けていません。そのため VM 内のエージェントもあなたの署名付きコミットを作成できます。GitHub の Verified バッジは「この VM で作成されたコミットである」ことを示し、人間が直接書いたことの証明にはなりません。不要になった VM を削除する際（または `make restore-auth` で鍵を引き継がずに作り直した際）は、GitHub の [SSH and GPG keys](https://github.com/settings/keys) から対応する古い Signing Key も削除してください（`make delete` は起動中の VM を削除する前に `ssh-keygen -lf ~/.ssh/id_ed25519_signing.pub` で鍵の指紋を表示します）。ホストの `gh` で削除する場合、`gh ssh-key delete` は認証用の鍵（`/user/keys`）しか扱わないため、`gh api` で Signing Key の指紋・ID・タイトルを一覧して削除します（`admin:ssh_signing_key` スコープが必要。`gh auth refresh -h github.com -s admin:ssh_signing_key` で追加できます）:
  ```sh
  gh api --paginate /user/ssh_signing_keys --jq '.[] | "\(.key) id=\(.id) \(.title)"' | ssh-keygen -lf -
  gh api -X DELETE /user/ssh_signing_keys/<ID>
  ```

## ホストのマウントが混入しないように

このテンプレートではマウントを定義していません（`mounts: []`）。ただし Lima は、次のグローバル設定にあるマウントをすべてのインスタンスに結合します。

| ファイル | 反映されるタイミング |
|---|---|
| `~/.lima/_config/default.yaml` | 起動のたび |
| `~/.lima/_config/override.yaml` | 起動のたび |
| `~/.lima/_config/base.yaml` | インスタンスの作成時（`~/.lima/coding-sandbox/lima.yaml` に取り込まれる） |

（`LIMA_HOME` を設定している場合は、`~/.lima` をそのディレクトリに読み替えてください）

これらにマウントの設定があると、この VM にもホストのディレクトリがマウントされます。
本プロジェクトでは、意図しないホストマウントの混入を防ぐため、多層防御の仕組みを備えています。

### 1. make による起動前の自動検査・防止（推奨）

`Makefile` 経由で操作する場合（`make start`、`make shell`、`make herdr` など）、VM の作成前および起動前にマウント設定の有無を自動検査します。

- **作成前（`make create`）**: `limactl template yq` でグローバル設定をマージしたテンプレートを検査し、マウントが検出された場合はインスタンスを作成せずにエラー終了します。
- **起動前（`make start`）**: `limactl list` でインスタンスに反映されるマウント設定を検査し、マウントが検出された場合は起動せずにエラー終了します。既に VM が起動中の状態でマウントが確認された場合は、安全のため自動で `limactl stop` を実行して停止します。
- **起動失敗時の保護**: 万一マウントが存在する状態で `limactl start` が失敗した場合、マウント混入を検知して自動で VM を停止し、検出されたマウントと設定確認を案内します（※単なる回線遅延等によるプロビジョニングタイムアウト時は VM を停止せず、バックグラウンド処理を継続させます。自動停止に失敗した場合も手動停止を案内します）。

マウントが検出された場合は、次のようにマウント元のパスが表示されて停止します:

```text
エラー: ホストのディレクトリをマウントする設定があります（docs/security.md の「ホストのマウントが混入しないように」を参照）:
- location: /Users/<user>/...
```

### 2. limactl 直接実行時の probe による多層防御

`limactl` コマンドを直接使って起動した場合でも、テンプレート内の最初の probe（`no host directories to be mounted`）がゲスト内の `/proc/self/mounts` を直接調べ、ホストのマウント（virtiofs / 9p / sshfs）が見つかったら起動をエラーにします。

このとき `limactl start` は次の表示から先に進まず、タイムアウト（既定は 10 分）後にエラー（終了コード 1）で終了します。

```text
Waiting for the optional requirement 1 of 9: `no host directories to be mounted`
...
did not receive an event with the `running` status
```

⚠️ この probe は**検出するだけ**です。`limactl` を直接使った場合、エラー終了後も VM はマウントされた状態のまま動いています。エージェントを使わずに `limactl stop coding-sandbox` で VM を停止し、設定を直してください。

### 手動でのマウント確認コマンド

作成前や起動前に手動で確認したい場合は、次のコマンドを使います（グローバル設定をマージした後の値が表示されます）。

```sh
# 作成前: マウント設定がある場所が表示される（何も表示されなければマウントなし）
limactl template yq ./coding-sandbox.yaml '.mounts[] | "- location: " + .location'

# 作成後: マウント設定がある場所が表示される（何も表示されなければマウントなし）
limactl list coding-sandbox --format '{{range .Config.Mounts}}- location: {{.Location}}{{"\n"}}{{end}}'
```

マウントが見つかったときの直し方:

- `default.yaml` / `override.yaml` が原因の場合: 該当するマウントの設定を消してから、`limactl stop coding-sandbox` → `limactl start coding-sandbox` で起動し直す
- `base.yaml` や `limactl start --mount` が原因の場合: インスタンスの `lima.yaml` に取り込まれているので、`limactl stop coding-sandbox` → `limactl edit coding-sandbox --mount-none` → `limactl start coding-sandbox` で、インスタンスの設定からマウントを消す（またはインスタンスを作り直す）

## ネットワーク

### ポート転送

Lima の既定動作では、VM 内で listen した全ポート（`127.0.0.1` や `0.0.0.0` に bind されたもの）がホストの `127.0.0.1` の同じポート番号に自動で転送されます。
しかし本サンドボックスでは、エージェントが意図せず起動したサーバや悪意あるプロセスへのホスト側からの誤アクセスを防ぎ、ポート競合やポート横取りによる機密漏洩（ホストの別ツールが VM 内のサービスに認証情報等を送ってしまうリスク）を避けるため、`coding-sandbox.yaml` の `portForwards` 設定で**自動転送を全面的に無効化（ignore）**しています。

開発中の Web サーバなどをホストのブラウザで確認したいときは、必要なポートだけを手動で一時的に転送します。

```sh
# VM の 3000 番ポートをホストの http://127.0.0.1:3000 に転送する（フォアグラウンドで実行。Ctrl-C で停止）
make forward PORT=3000

# ホスト側の待受ポートを変えたい場合（例: ホストの 13000 番に転送）
make forward PORT=3000 HOST_PORT=13000
```

`make forward` は `ssh -L` を使用して転送を行います。ControlMaster を無効化して専用接続を張るため、Ctrl-C でコマンドを終了すると同時にポート転送も確実に切断されます。

`make` を使わずに `ssh` コマンドで直接転送することもできます:

```sh
ssh -F ~/.lima/coding-sandbox/ssh.config -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes -N -L 127.0.0.1:3000:127.0.0.1:3000 lima-coding-sandbox
```

> [!TIP]
> 特定のポートを常に自動転送させたい場合は、作成後に `limactl edit coding-sandbox` で `.portForwards` の先頭（ignore ルールより前）に転送ルールを追加してください。

### ホストループバック（host.lima.internal）への接続遮断

Lima のユーザモードネットワーク（gvisor-tap-vsock）では、`host.lima.internal`（`192.168.5.2`）宛ての通信がホストマシンのループバックアドレス（`127.0.0.1`）に自動で変換されます（Lima 本体の NAT 実装によるものであり、設定で無効化することはできません）。
そのため通常は、ホスト上で動作しているローカルデータベースや各種開発サーバ、管理ポート等に VM から接続できてしまいます。

本サンドボックスでは、VM 起動時に `provision/host-loopback-firewall.sh` により **nftables の専用テーブル（`inet lima_coding_sandbox`）** を設定し、VM（Docker コンテナを含む）から `host.lima.internal`（`192.168.5.2`）への通信を即座に拒否（`reject`。TCP では `Connection refused`、その他は ICMP unreachable）します。

```sh
# VM 内からホストのループバックサービスへアクセスを試みても即座に拒否される
limactl shell coding-sandbox curl -m 5 http://host.lima.internal:8080/
# => curl: (7) Failed to connect to host.lima.internal port 8080: Connection refused
```

- **DNS への影響なし**: conntrack の変換前の宛先（`ct original ip daddr`）で判定して Lima の DNS DNAT（`192.168.5.3:53` から `192.168.5.2` への変換）を通すとともに、ゲストから直接 `192.168.5.2:53` へ送られる DNS 問い合わせも明示的に許可（accept）しているため、通常およびコンテナ内の名前解決（インターネットへのアクセス等）は一切阻害されません
- **Docker コンテナも保護**: nftables の `output` チェインだけでなく `forward` チェインにもルールを配置しているため、`docker run` で立ち上げたコンテナ内からの通信も遮断されます
- **systemd サービスによる早期保護**: `lima-coding-sandbox-firewall.service` ユニットを登録することで、VM の再起動時にもプロビジョニング実行を待たずにネットワーク初期化（`network-pre.target`）の段階からルールが有効になります
- **遮断範囲**: 遮断対象はホストのループバックにつながる `host.lima.internal`（`192.168.5.2`）のみです。ホストの LAN 側 IP アドレスや同一 LAN 内の機器への通信は遮断されません

#### 遮断を無効化（オプトアウト）する方法

社内環境でホストマシンのローカルプロキシ（例: `http_proxy=http://127.0.0.1:3128`）を経由して外部に接続している場合、Lima はプロキシ環境変数の IP を自動的に `192.168.5.2` に変換して VM に渡すため、遮断が有効だと VM から外部ネットワークに接続できなくなります。
このような場合は、遮断機能を無効化してインスタンスを作成してください。

```sh
# .env で無効化する場合
BLOCK_HOST_LOOPBACK=false

# コマンドライン引数で無効化する場合
make start BLOCK_HOST_LOOPBACK=false
```

インスタンス作成後に切り替える場合は、一度停止してから設定を更新して起動します:

```sh
make stop
limactl edit --tty=false coding-sandbox --set '.param.blockHostLoopback = "false"'
make start
```

> [!WARNING]
> [セキュリティ上の注意](#セキュリティ上の注意)にも記載のとおり、VM 内の通常ユーザはパスワードなしで `sudo` を実行できるため、エージェントが意図して `sudo nft delete table inet lima_coding_sandbox` 等を実行した場合は遮断を解除できてしまいます。本機能は**エージェントやユーザの誤操作・意図しない接続の防止**を目的としており、敵対的な意図を持つエージェントによる意図的な回避を完全に防ぐものではありません。
