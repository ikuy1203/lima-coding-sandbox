# lima-coding-sandbox

[Lima](https://lima-vm.io/) でコーディングエージェント用のサンドボックス VM を作るための設定ファイル一式です。
ホストのファイルにエージェントが直接触れないよう、VM の中で通常ユーザとしてエージェントを動かします。

## 構成

| 項目 | 内容 |
|---|---|
| OS | Ubuntu 26.04 LTS（Lima 同梱の `template:_images/ubuntu-26.04`） |
| ホストのディレクトリ | マウントしない（`mounts: []`）。Lima のグローバル設定から混入した場合は、起動時に検出してエラーにする（[後述](#ホストのマウントが混入しないように)） |
| ユーザ | ホストと同じ名前・UID の通常ユーザ（非 root）。ホームは `/home/<user>.guest`。パスワードなしで sudo できる（Lima の既定） |
| リソース | 4 CPU / 8 GiB メモリ / 100 GiB ディスク（ディスクはスパースファイルなので、実際に使った分だけ消費する） |
| ソフトウェア | herdr、Antigravity CLI（`agy`）、GitHub Copilot CLI（`copilot`）、Docker Engine（`sudo docker` で使う） |

各ソフトウェアは公式ドキュメントの手順でインストールします。

| ソフトウェア | 公式手順 | スクリプト | インストール先 |
|---|---|---|---|
| Docker Engine | [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)（apt リポジトリ） | `provision/docker-engine.sh`（root） | apt パッケージ |
| herdr | [Install](https://herdr.dev/docs/install/) | `provision/herdr.sh` | `~/.local/bin/herdr` |
| Antigravity CLI | [Installation and auth](https://antigravity.google/docs/cli/install) | `provision/antigravity-cli.sh` | `~/.local/bin/agy` |
| GitHub Copilot CLI | [Installing GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)（install スクリプト） | `provision/copilot-cli.sh` | `~/.local/bin/copilot` |

> [!NOTE]
> Antigravity CLI だけは、公式のコマンドに `curl --compressed` を追加しています。
> `antigravity.google` が、クライアントが要求していないのに gzip 圧縮した本文を返すことがあり、そのままだとインストールに失敗するためです（詳しくは `provision/antigravity-cli.sh` のコメントを参照）。

### 動作確認した環境

macOS 26.7.1（Apple M2）、Lima 2.2.0、Ubuntu 26.04 LTS（カーネル 7.0）、Docker Engine 29.8.2、herdr 0.9.3、Antigravity CLI 1.2.16、GitHub Copilot CLI 1.0.91

## ファイル構成

```
.
├── README.md
├── coding-sandbox.yaml        # Lima テンプレート（probes もここに書いてある）
├── provision/                 # プロビジョニングスクリプト（起動のたびに実行されるため冪等に作ってある）
│   ├── docker-engine.sh       # mode: system  Docker Engine
│   ├── herdr.sh               # mode: user
│   ├── antigravity-cli.sh     # mode: user
│   └── copilot-cli.sh         # mode: user
├── scripts/
│   └── lint.sh                # テンプレートとスクリプトの検査（CI でも実行する）
└── .github/workflows/ci.yml   # GitHub Actions（scripts/lint.sh を実行する）
```

## 前提

- macOS（Apple silicon で動作確認）
- Lima 2.2.0 以上（`brew install lima`）

## 使い方

### 作成・起動

```sh
limactl start ./coding-sandbox.yaml
```

インスタンス名は `coding-sandbox` です（変えるときは `--name=<名前>` を付ける）。
初回はイメージのダウンロードとプロビジョニングがあるため数分かかります。
起動時に `probes` で次の 3 点を確認し、すべて満たされた時点で完了します。

1. ホストのディレクトリがマウントされていないこと
2. herdr / Antigravity CLI / GitHub Copilot CLI がインストールされていること
3. Docker Engine が動いていること

> [!NOTE]
> `coding-sandbox.yaml` と `provision/*.sh` の内容は、インスタンスの作成時に `~/.lima/coding-sandbox/lima.yaml` に取り込まれます。
> 変更を反映するには、インスタンスを作り直してください（`limactl delete coding-sandbox` → `limactl start ./coding-sandbox.yaml`）。

### CPU・メモリ・ディスクを変える

既定は 4 CPU / 8 GiB メモリ / 100 GiB ディスクです。作成時に変えるには、`limactl start` にオプションを付けます（メモリとディスクの単位は GiB）。

```sh
limactl start --cpus=8 --memory=16 --disk=200 ./coding-sandbox.yaml
```

作成後に CPU とメモリを変えるには、VM を停止してから `limactl edit` を使います。

```sh
limactl stop coding-sandbox
limactl edit coding-sandbox --cpus=8 --memory=16
limactl start coding-sandbox
```

### シェルに入る

```sh
limactl shell coding-sandbox
```

ホストのディレクトリはマウントしていないので、ゲストのホーム（`/home/<user>.guest`）でログインシェルが起動します。
`~/.local/bin` は Ubuntu 既定の `~/.profile` によって PATH に追加されます。

### 停止・削除

```sh
limactl stop coding-sandbox
limactl delete coding-sandbox
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
そこで起動時の最初の probe で、ゲスト内にホストのマウント（virtiofs / 9p / sshfs）が無いかを調べ、見つかったら起動をエラーにしています。
このとき `limactl start` は次の表示から先に進まず、タイムアウト（既定は 10 分）後にエラー（終了コード 1）で終了します。

```text
Waiting for the optional requirement 1 of 3: `no host directories to be mounted`
...
did not receive an event with the `running` status
```

これは**検出するだけ**です。エラーで終了した後も、VM はマウントされた状態のまま動いています。その場合はエージェントを使わずに `limactl stop coding-sandbox` で VM を停止し、設定を直してください。

作成前や起動前に確認するには、次のコマンドを使います（グローバル設定をマージした後の値が表示されます）。

```sh
# 作成前: 何も表示されなければマウントは無い
limactl validate --fill ./coding-sandbox.yaml 2>/dev/null | grep -A3 '^mounts:'

# 作成後: [] と表示されればマウントは無い
limactl list coding-sandbox --format '{{json .Config.Mounts}}'
```

マウントが見つかったときの直し方:

- `default.yaml` / `override.yaml` が原因の場合: 該当するマウントの設定を消してから、`limactl stop coding-sandbox` → `limactl start coding-sandbox` で起動し直す
- `base.yaml` や `limactl start --mount` が原因の場合: インスタンスの `lima.yaml` に取り込まれているので、`limactl stop coding-sandbox` → `limactl edit coding-sandbox --mount-none` → `limactl start coding-sandbox` で、インスタンスの設定からマウントを消す（またはインスタンスを作り直す）

## プロジェクトを VM に持ち込む

ホストのファイルはマウントされないため、次のいずれかの方法を使います。

1. **VM 内で `git clone` する（推奨）**
   Git の認証情報は VM 内で別途用意します（HTTPS + Personal Access Token、VM 内で作った SSH 鍵など）。
2. **`limactl shell --sync` を使う**
   ホストのカレントディレクトリをゲストにコピーし、シェルを終了するときに、変更をホストへ書き戻すかどうかを確認されます（差分を見てから選べます）。
   ```sh
   cd ~/src/my-project
   limactl shell --sync . coding-sandbox
   ```
   - ホストとゲストの両方に rsync が必要です（ゲストのイメージには同梱されています。ホストは macOS 標準の rsync（openrsync）で動作を確認しました）
   - ホスト側のディレクトリは 4 階層以上の深さが必要です（例: `/Users/<user>/src/my-project`）
   - インスタンスにホストのマウントがあると、Lima は `--sync` を拒否します。エラーメッセージでは `--mount-none` を付けて起動するよう案内されますが、`default.yaml` / `override.yaml` 由来のマウントはそれでは消えません（[ホストのマウントが混入しないように](#ホストのマウントが混入しないように)を参照）
   - ゲスト側では `~/<ホストの絶対パス>`（例: `/home/<user>.guest/Users/<user>/src/my-project`）に展開されます
   - ⚠️ `--tty=false`（`-y`）を付けたときやパイプ経由で実行したときは、**確認なしで**ホストに書き戻されます。`rsync --delete` で同期するため、ゲストで削除したファイルはホストからも削除されます
3. **`limactl copy` でコピーする**
   ```sh
   limactl copy -r ./my-project coding-sandbox:~/
   ```

## 初回のセットアップ（認証）

### GitHub Copilot CLI

```sh
copilot
```

起動したら `/login` を実行します。SSH 経由の環境ではデバイスコードフローになるので、表示された URL をホストのブラウザで開き、コードを入力してください。
VM にはキーリング（libsecret）が入っていないため、トークンを `~/.copilot/config.json` に平文で保存するかどうか確認されます。
Fine-grained PAT を環境変数（`COPILOT_GITHUB_TOKEN` など）で渡す方法もあります（[認証のドキュメント](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli)）。

### Antigravity CLI

```sh
agy
```

SSH 経由だと判定されると、認可用の URL が表示されます。ホストのブラウザで開いてサインインし、表示されたコードを CLI に貼り付けてください。

> [!WARNING]
> Linux 版の Antigravity CLI は、ログイン情報の保存に Secret Service（GNOME Keyring など）と D-Bus セッションを使います（[Troubleshooting](https://antigravity.google/docs/cli/troubleshooting)）。
> この VM には D-Bus セッションはありますが、Secret Service を提供するキーリングは入れていません。
> キーリングが無くても認証フロー（URL の表示とコードの貼り付け）が始まることは確認しましたが、ログイン情報が保存されるかどうかは未確認です。
> 毎回ログインを求められる場合は、次の Gemini API キー方式を使ってください。

キーリングを使わない方法として、Gemini API キーでも認証できます（[Installation and auth](https://antigravity.google/docs/cli/install)）。

```sh
mkdir -p ~/.gemini/antigravity-cli
echo '{"modelProvider": "gemini"}' > ~/.gemini/antigravity-cli/settings.json
export GEMINI_API_KEY="<API キー>"   # 毎回設定するなら ~/.bashrc に追記する
agy
```

### herdr

```sh
herdr
```

herdr のセッションが起動します（既にあれば接続します）。プレフィックスキーは `ctrl+b` で、`prefix+q` でデタッチ、もう一度 `herdr` を実行すると再接続します。
ペインの中で `copilot` や `agy` を起動すると、herdr が自動でエージェントとして検出します。

herdr のサーバを再起動しても同じセッションを再開できるようにするには、[インテグレーション](https://herdr.dev/docs/integrations/)をインストールします。
各エージェントを一度起動して、その設定ディレクトリが作られてから実行してください。

```sh
herdr integration install copilot
herdr integration install antigravity-cli
```

## Docker

```sh
sudo docker run --rm hello-world
```

- Docker Engine は公式手順どおりの通常の構成です。デーモンは root 権限のシステムサービス（`docker.service`）として動き、VM の起動時に自動で起動します
- 通常ユーザは `docker` グループに入れていないので、`docker` コマンドには `sudo` を付けます（付けないと `/var/run/docker.sock` に接続できず permission denied になります）。エージェントに Docker を使わせるときも `sudo docker ...` を使うよう指示してください
- VM 内のユーザはもともとパスワードなしで sudo できるため、`docker` グループに入れた場合と権限は変わりません

## 更新

| ソフトウェア | 方法 |
|---|---|
| herdr | `herdr update` |
| Antigravity CLI | 自動で更新される |
| GitHub Copilot CLI | `copilot update` |
| Docker Engine | `sudo apt-get update && sudo apt-get upgrade` |

## トラブルシューティング

`limactl start` が `Waiting for the optional requirement ...` から進まないとき（タイムアウトの既定値の 10 分が過ぎるとエラーで終了します）は、表示されている requirement を確認してください。

- `no host directories to be mounted`: ホストのディレクトリがマウントされています。[ホストのマウントが混入しないように](#ホストのマウントが混入しないように)を参照してください
- それ以外: プロビジョニングスクリプトが失敗している可能性があります。Lima はスクリプトが失敗しても起動処理を続けるため、`probes` でツールのインストールと Docker の起動を確認しています。ゲストのログを確認してください

```sh
limactl shell coding-sandbox sudo tail -n 100 /var/log/cloud-init-output.log
```

プロビジョニングスクリプトは VM を起動するたびに実行され、インストール済みのソフトウェアは飛ばすように作ってあります。ネットワークの一時的な障害などで失敗したときは、VM を起動し直すと、インストールされていないものだけをもう一度インストールします。

```sh
limactl stop coding-sandbox
limactl start coding-sandbox
```

回線が遅く、初回のプロビジョニングが 10 分以内に終わらないときは、タイムアウトを延ばして作成してください。

```sh
limactl start --timeout=30m ./coding-sandbox.yaml
```

タイムアウトでエラーになった後も VM は動き続け、プロビジョニングも続きます。終わったかどうかは上のログで確認できます。

## セキュリティ上の注意

- 隔離の境界は VM です。VM 内のユーザはパスワードなしで sudo できるため、エージェントも VM 内では root 相当の操作ができます
- テンプレートでは、ホストのディレクトリのマウント、SSH エージェントの転送、ホストの `~/.ssh/*.pub` の読み込みを、いずれも無効にしています。マウントだけは Lima のグローバル設定から混入しうるため、起動時に検出しています（[ホストのマウントが混入しないように](#ホストのマウントが混入しないように)）
- Lima の既定動作により、ゲスト内で `127.0.0.1` や `0.0.0.0` に bind されたポートは、ホストの `127.0.0.1` に転送されます（開発中の Web アプリをホストのブラウザで確認できますが、エージェントが起動したサーバにもホストからアクセスできる状態になります）
- VM からはインターネットに接続できます。また、`host.lima.internal`（`192.168.5.2`）はホストのループバックアドレスにつながっているため、ホストで `127.0.0.1` に bind しているサービス（ローカルのデータベースや開発サーバ、ほかの Lima インスタンスから転送されているポートなど）にも VM から接続できます。認証のないサービスをホストで動かしているときは注意してください（VM 内のファイアウォールで遮断しても、エージェントは sudo で解除できます）
- 各 CLI の認証情報は VM 内に保存されます（Copilot CLI は平文で保存される場合があります）。不要になったら `limactl delete` で VM ごと削除してください

## 開発

`scripts/lint.sh` で、テンプレートの検証（`limactl validate`）と、provision スクリプトおよびテンプレートに書いた probes の shellcheck を実行します（shellcheck は `brew install shellcheck` でインストールする）。

```sh
./scripts/lint.sh
```

GitHub Actions（`.github/workflows/ci.yml`）でも、main ブランチへの push と pull request のたびに同じスクリプトを実行します。Lima は、`minimumLimaVersion` のバージョンと最新のリリースの 2 つで確認します。

probes は `file:` で別のファイルに分けず、`coding-sandbox.yaml` に直接書いています。Lima 2.2.0 では、probes の `file:` がインスタンスの作成時に取り込まれないためです（provision の `file:` は取り込まれます）。
