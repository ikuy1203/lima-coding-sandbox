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
| ネットワーク | ゲストのポートをホストに自動で転送しない。VM から `host.lima.internal`（ホストの `127.0.0.1`）への接続を遮断する（[後述](#ネットワーク)） |
| 音声 | VM の中で再生した音を、ホストのスピーカーから鳴らす（再生のみ。マイクは使えない。[後述](#音声)） |
| ソフトウェア | 基本的なツール（git、gh、build-essential、ripgrep、Python の venv・pipx、Node.js など。[後述](#基本的なツール)）、herdr、Antigravity CLI（`agy`）、GitHub Copilot CLI（`copilot`）、mise、Docker Engine、ファイアウォール（nftables）、Git のユーザ設定・コミット署名鍵、ターミナル（`$TERM`）の terminfo の代替設定 |

基本的なツールは Ubuntu のリポジトリから、それ以外の各ソフトウェアは公式ドキュメントの手順でインストールします。

| ソフトウェア | 公式手順 | スクリプト | インストール先 |
|---|---|---|---|
| 基本的なツール | Ubuntu のリポジトリ（apt） | `provision/apt-packages.sh`（root） | apt パッケージ |
| GitHub CLI | [Installing gh on Linux and BSD](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian)（apt リポジトリ） | `provision/github-cli.sh`（リポジトリ登録）、`provision/apt-packages.sh`（root） | apt パッケージ |
| Docker Engine | [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)（apt リポジトリ） | `provision/docker-engine.sh`（リポジトリ登録・ラッパー）、`provision/apt-packages.sh`（root） | apt パッケージ、`/usr/local/bin/docker`（ラッパー） |
| ファイアウォール（nftables） | Ubuntu のリポジトリ（apt） | `provision/apt-packages.sh`（インストール）、`provision/host-loopback-firewall.sh`（ルール・サービス登録）（root） | apt パッケージ、`/etc/lima-coding-sandbox/host-loopback-firewall.nft`、`/etc/systemd/system/lima-coding-sandbox-firewall.service` |
| 音声（alsa-utils, mpg123） | Ubuntu のリポジトリ（apt） | `provision/apt-packages.sh`（インストール）、`provision/audio.sh`（udev ルール設定）（root） | apt パッケージ、`/etc/udev/rules.d/70-lima-coding-sandbox-sound.rules` |
| Git 設定・コミット署名 | - | `provision/git-config.sh` | `~/.ssh/id_ed25519_signing`、`~/.gitconfig` |
| herdr | [Install](https://herdr.dev/docs/install/) | `provision/herdr.sh` | `~/.local/bin/herdr` |
| Antigravity CLI | [Installation and auth](https://antigravity.google/docs/cli/install) | `provision/antigravity-cli.sh` | `~/.local/bin/agy` |
| GitHub Copilot CLI | [Installing GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)（install スクリプト） | `provision/copilot-cli.sh` | `~/.local/bin/copilot` |
| mise | [Installing mise](https://mise.jdx.dev/installing-mise.html)（`https://mise.run`） | `provision/mise.sh` | `~/.local/bin/mise`、`~/.profile`（shims を PATH に追加する行を追記。[後述](#mise)） |

> [!NOTE]
> 初回起動時間を短縮するため、GitHub CLI や Docker Engine の公式手順にある個別の `apt update && apt install` は行わず、先にリポジトリを登録してから `provision/apt-packages.sh` で `apt-get update` と全 apt パッケージのインストールを 1 回に集約しています（通常時は 1 回のみ。ベースイメージに curl / wget / CA 証明書が不足している場合のみ例外的に事前実行されます。万が一の外部リポジトリ障害時も個別フォールバックにより基本ツール等は導入されます）。

> [!NOTE]
> Antigravity CLI だけは、公式のコマンドに `curl --compressed` を追加しています。
> `antigravity.google` が、クライアントが要求していないのに gzip 圧縮した本文を返すことがあり、そのままだとインストールに失敗するためです（詳しくは `provision/antigravity-cli.sh` のコメントを参照）。

> [!NOTE]
> GitHub CLI は、Ubuntu のリポジトリ（universe）にも `gh` パッケージがありますが、Ubuntu 26.04 の版（2.46）は廃止された GitHub の API を使っているため動かないと、GitHub CLI の公式ドキュメントに書かれています。
> そのため公式の apt リポジトリ（`cli.github.com`）を登録して、そこから入れています（`apt-cache policy gh` で確認できます）。

### 基本的なツール

`provision/apt-packages.sh` で、次のパッケージをインストールします（gh と Docker Engine は公式のリポジトリから、それ以外は Ubuntu のリポジトリから入れます）。

| パッケージ | 主なコマンド |
|---|---|
| git、curl、wget、jq、less、openssh-client、ca-certificates | `git`、`curl`、`wget`、`jq`、`less`、`ssh` |
| gh（GitHub CLI） | `gh` |
| build-essential | `gcc`、`g++`、`make` |
| ripgrep、fd-find、unzip、zip、tree | `rg`、`fd`（`fdfind`）、`unzip`、`zip`、`tree` |
| shellcheck | `shellcheck` |
| python3-venv、python3-pip、pipx | `python3 -m venv`、`pip3`、`pipx` |
| nodejs、npm | `node`、`npm`、`npx` |

1 行目のパッケージはイメージに最初から入っていますが、イメージが変わっても確実に入るように明記しています（新しい版があれば、初回の起動時に更新されます）。

- Ubuntu の仕様上、`fd-find` パッケージのコマンド名は `fdfind` ですが、コーディングエージェントやツールの互換性のため `/usr/local/bin/fd` にシンボリックリンクを作成しています（`fd` と `fdfind` のどちらでも実行できます）
- `pip3 install` で Python のパッケージをシステムに入れることはできません（`externally-managed-environment` のエラーになります）。`python3 -m venv` で作った仮想環境の中で使うか、コマンドとして使うツールは `pipx install` で入れてください（`~/.local/bin` に入ります）
- Node.js と npm は Ubuntu のリポジトリの版（Node.js 22 / npm 9）です。`npm install -g` は `/usr/local` に入れようとするため、そのままでは権限のエラー（`EACCES`）になります。先に `npm config set prefix ~/.local` を実行しておくと、`~/.local/bin` に入るようになります（`npx` はそのまま使えます）

ツールを追加するときは、`provision/apt-packages.sh` の `base_packages` に追加して、インスタンスを作り直してください。今の VM にだけ入れるなら、VM 内で `sudo apt-get install <パッケージ>` を実行します。
パッケージを削除するときは、`coding-sandbox.yaml` の probe（`basic tools (git, gh, etc.) to be installed`）のコマンド一覧からも、そのパッケージのコマンドを削除してください（残っていると、起動時の確認が終わらずにタイムアウトします）。

### 動作確認した環境

macOS 26.7.1（Apple M2）、Lima 2.2.0、Ubuntu 26.04 LTS（カーネル 7.0）、git 2.53.0、GitHub CLI 2.102.0、Python 3.14.4、Node.js 22.22.1、Docker Engine 29.8.2、herdr 0.9.3、mpg123 1.33.3、Antigravity CLI 1.2.16、GitHub Copilot CLI 1.0.91、mise 2026.10.7

## ファイル構成

```
.
├── README.md
├── Makefile                   # よく使う limactl の操作をまとめたもの（make help で一覧を表示）
├── .env.example               # Makefile が読む設定（作成時の設定）のひな形。.env にコピーして使う
├── .gitignore                 # .env を除外する
├── coding-sandbox.yaml        # Lima テンプレート（probes もここに書いてある）
├── provision/                 # プロビジョニングスクリプト（起動のたびに実行されるため冪等に作ってある）
│   ├── github-cli.sh          # mode: system  GitHub CLI の apt リポジトリ登録
│   ├── docker-engine.sh       # mode: system  Docker Engine の apt リポジトリ登録・ラッパー
│   ├── apt-packages.sh        # mode: system  apt パッケージの一括インストール（基本的なツール・gh・Docker・alsa-utils/mpg123・nftables）
│   ├── host-loopback-firewall.sh # mode: system host.lima.internal への接続の遮断
│   ├── terminfo-fallback.sh   # mode: system  $TERM の terminfo が無いときの代替
│   ├── audio.sh               # mode: system  音声（サウンドデバイスのパーミッション）
│   ├── git-config.sh          # mode: user    Git のユーザ設定とコミット署名
│   ├── herdr.sh               # mode: user
│   ├── antigravity-cli.sh     # mode: user
│   ├── copilot-cli.sh         # mode: user
│   └── mise.sh                # mode: user
├── scripts/
│   └── lint.sh                # テンプレートとスクリプトの検査（CI でも実行する）
└── .github/
    ├── dependabot.yml         # GitHub Actions のアクションの更新を週 1 回確認する
    └── workflows/ci.yml       # GitHub Actions（scripts/lint.sh を実行する）
```

## 前提

- macOS（Apple silicon で動作確認）
- Lima 2.2.0 以上（`brew install lima`）

## 使い方

### make で操作する

よく使う操作は `Makefile` にまとめてあります。リポジトリのディレクトリで実行してください（`make help` で一覧を表示します）。

```sh
make start    # 作成（初回のみ）と起動
make shell    # シェルに入る（停止していれば起動する）
make stop     # 停止
```

| ターゲット | 内容 |
|---|---|
| `make start` | インスタンスが無ければ作成してから起動する。作成時には、Git のユーザ名とメールアドレスを `--param` で渡す（[後述](#作成時の設定git-ユーザ情報ホストループバック遮断を-env-で指定する)）。作成前・起動前にホストマウントの混入を自動検査し、設定されている場合は起動を拒否する（[後述](#ホストのマウントが混入しないように)） |
| `make shell` | シェルに入る（停止していれば先に起動する） |
| `make herdr` | herdr のセッションに入る（無ければ作る。停止していれば先に起動する） |
| `make herdr-remote` | ホストの herdr から VM のセッションにリモート接続する（停止していれば先に起動する。[後述](#herdr)） |
| `make forward` | VM のポートをホストの `127.0.0.1` に転送する（`PORT=<VMのポート>` が必須。`HOST_PORT=<ホスト側ポート>` で変えられる。Ctrl-C で終了。[後述](#ネットワーク)） |
| `make terminfo` | ホストの terminfo を VM にコピーする（既定はホストの `$TERM`。`TERM_NAME=<名前>` で変えられる。停止していれば先に起動する。[後述](#シェルに入る)） |
| `make stop` / `make restart` | 停止 / 再起動（再起動は、失敗したプロビジョニングのやり直しにも使える） |
| `make status` | 状態を表示する |
| `make delete` | 削除する（確認あり。`YES=1` を付けると確認を省略） |
| `make recreate` | 削除してから作り直す（`coding-sandbox.yaml` や `provision/*.sh` の変更を反映するとき） |
| `make pubkey` | Git のコミット署名用の公開鍵を表示する |
| `make logs` | プロビジョニングのログ（cloud-init）の末尾を表示する |
| `make lint` | `scripts/lint.sh` を実行する |

変数をコマンドラインで指定すると、インスタンス名・リソース（作成時のみ有効）・タイムアウト・Git の設定・ホストループバック遮断を変えられます。

```sh
make start NAME=sandbox2 CPUS=8 MEMORY=16 DISK=200 TIMEOUT=30m
make start GIT_USER_NAME="<名前>" GIT_USER_EMAIL="<メールアドレス>" BLOCK_HOST_LOOPBACK=false
```

`--param` は `limactl create` で渡しているため、名前にカンマが含まれていても問題ありません。

#### 作成時の設定（Git ユーザ情報・ホストループバック遮断）を .env で指定する

`.env.example` をコピーして `.env` を作り、値を書きます（`.env` は `.gitignore` で除外しています）。

```sh
cp .env.example .env
```

```sh
# .env
GIT_USER_NAME=Taro Yamada
GIT_USER_EMAIL=taro@example.com
BLOCK_HOST_LOOPBACK=true
```

- `.env` を読むのは Makefile だけです。VM には `limactl create --param` で値だけを渡し、`.env` 自体はコピーしません
- 値は次の順で決まります: コマンドライン（`make start GIT_USER_NAME=...`） ＞ `.env` ＞ ホストの `git config --global`（Git 情報の場合）。`.env` が無いときや値が空のときは既定値を使います
- `BLOCK_HOST_LOOPBACK` は、VM から `host.lima.internal`（ホストの `127.0.0.1`）への通信を遮断するかを指定します（`true` / `false`、空なら既定値の `true`。[後述](#ネットワーク)）
- make の書式で読み込むため、値に空白やカンマがあってもクォートは要りません（両端を `"` か `'` で囲んだときは、その 1 組を取り除きます）。`#` から行末はコメントになります
- 別のファイルを使うには `ENV_FILE` を指定します（例: `make start ENV_FILE=work.env`。指定したファイルが無いとエラーになります）。`*.env` も `.gitignore` で除外しています
- 値が反映されるのは**インスタンスを作成するときだけ**です。作成後に `.env` を変えても今の VM にには反映されません。`make recreate` で作り直してください
- Makefile の変数（`NAME`、`CPUS` など）も `.env` に書けます（コマンドラインで指定した値が優先されます）

以下では、`make` を使わずに `limactl` で直接操作する方法を説明します。

### 作成・起動

```sh
limactl start ./coding-sandbox.yaml
```

Git のユーザ名とメールアドレス、およびホストループバック遮断をあらかじめ設定するには、作成時に `--param` で渡します（ホストの Git 設定をそのまま渡すこともできます）:

```sh
limactl start \
  --param "gitUserName=$(git config --global user.name)" \
  --param "gitUserEmail=$(git config --global user.email)" \
  --param "blockHostLoopback=true" \
  ./coding-sandbox.yaml
```

> [!NOTE]
> `limactl start --param` はカンマで値を区切るため、名前にカンマが含まれる場合は `limactl create --param "gitUserName=..." --param "gitUserEmail=..." ./coding-sandbox.yaml` で作成してから `limactl start coding-sandbox` で起動してください。

インスタンス名は `coding-sandbox` です（変えるときは `--name=<名前>` を付ける）。
初回はイメージのダウンロードとプロビジョニングがあるため数分かかります。
起動時に `probes` で次の 8 点を確認し、すべて満たされた時点で完了します。

1. ホストのディレクトリがマウントされていないこと
2. 基本的なツール（git、gh など）がインストールされていること
3. ホストのループバック（host.lima.internal）への接続が遮断されていること（`blockHostLoopback` が true の場合）
4. herdr / Antigravity CLI / GitHub Copilot CLI / mise がインストールされていること
5. ログインシェルの PATH の先頭が mise の shims になっていること
6. Docker Engine が動いていること
7. 音声を再生できること（`aplay` と `mpg123` がインストールされていて、音声が有効なときは通常ユーザが再生デバイスに書き込めること）
8. Git のコミット署名用 SSH 鍵が作成されていること

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

ホストの `$TERM`（環境変数）は ssh 経由でそのまま VM に渡されます。VM に terminfo が無い値（Ghostty の `xterm-ghostty` など）のときは、`less`（`git log` や `man` のページャ）が `WARNING: terminal is not fully functional` と表示するのを防ぐため、`/etc/profile.d/terminfo-fallback.sh` が自動で `TERM=xterm-256color` に置き換えます（herdr のペインの中はもともと `xterm-256color` なので置き換えません）。

Ghostty 固有の機能まで使いたいときは、ホストの terminfo を VM にコピーしてください（`~/.terminfo` に保存され、以後は置き換えなくなります。VM を作り直したときは再実行してください）。Ghostty で `make terminfo` を実行すると、ホストの `$TERM`（`xterm-ghostty`）の terminfo をコピーします。別のターミナルから実行するときなどは `make terminfo TERM_NAME=xterm-ghostty` のように名前を指定します。

make を使わないときは、次のコマンドでコピーできます:

```sh
infocmp -x xterm-ghostty | limactl shell coding-sandbox tic -x -
```

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
本プロジェクトでは、意図しないホストマウントの混入を防ぐため、多層防御の仕組みを備えています。

### 1. make による起動前の自動検査・防止（推奨）

`Makefile` 経由で操作する場合（`make start`、`make shell`、`make herdr` など）、VM の作成前および起動前にマウント設定の有無を自動検査します。

- **作成前（`make create`）**: `limactl template yq` でグローバル設定をマージしたテンプレートを検査し、マウントが検出された場合はインスタンスを作成せずにエラー終了します。
- **起動前（`make start`）**: `limactl list` でインスタンスに反映されるマウント設定を検査し、マウントが検出された場合は起動せずにエラー終了します。既に VM が起動中の状態でマウントが確認された場合は、安全のため自動で `limactl stop` を実行して停止します。
- **起動失敗時の保護**: 万一マウントが存在する状態で `limactl start` が失敗した場合、マウント混入を検知して自動で VM を停止し、検出されたマウントと設定確認を案内します（※単なる回線遅延等によるプロビジョニングタイムアウト時は VM を停止せず、バックグラウンド処理を継続させます。自動停止に失敗した場合も手動停止を案内します）。

マウントが検出された場合は、次のようにマウント元のパスが表示されて停止します:

```text
エラー: ホストのディレクトリをマウントする設定があります（README.md の「ホストのマウントが混入しないように」を参照）:
- location: /Users/<user>/...
```

### 2. limactl 直接実行時の probe による多層防御

`limactl` コマンドを直接使って起動した場合でも、テンプレート内の最初の probe（`no host directories to be mounted`）がゲスト内の `/proc/self/mounts` を直接調べ、ホストのマウント（virtiofs / 9p / sshfs）が見つかったら起動をエラーにします。

このとき `limactl start` は次の表示から先に進まず、タイムアウト（既定は 10 分）後にエラー（終了コード 1）で終了します。

```text
Waiting for the optional requirement 1 of 3: `no host directories to be mounted`
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

## プロジェクトを VM に持ち込む

ホストのファイルはマウントされないため、次のいずれかの方法を使います。

1. **VM 内で `git clone` する（推奨）**
   Git の認証情報は VM 内で別途用意します。GitHub なら、`gh auth login` でログインすると、HTTPS での `git clone` / `git push` にも gh の認証情報が使われます（[GitHub CLI](#github-cli) を参照）。ほかに、HTTPS + Personal Access Token や、VM 内で作った SSH 鍵なども使えます。
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

### GitHub CLI

```sh
gh auth login
```

対話形式で聞かれるので、`GitHub.com` と `HTTPS` を選び、`Authenticate Git with your GitHub credentials?` には `Yes` と答えます（VM 内の git が、GitHub への HTTPS のアクセスに gh の認証情報を使うようになります）。
認証方法で `Login with a web browser` を選ぶと、ワンタイムコードが表示されます。Enter を押すと、VM にはブラウザが無いため開けなかったというメッセージが出ますが、そのまま待っている間に、表示された URL（`https://github.com/login/device`）をホストのブラウザで開いてコードを入力してください。
VM にはキーリング（Secret Service）が無いため、トークンはファイルに平文で保存されます（`Authentication credentials saved in plain text` と表示されます。保存先は `gh auth status` で確認できます）。

Git のユーザ名とメールアドレスは作成時に `--param` で渡していれば設定済みです。未指定で作成した場合は [Git のコミット署名](#git-のコミット署名) を参照して設定してください。

### Git のコミット署名

VM 内の Git は、すべてのコミットとタグに署名するよう設定されています（`commit.gpgsign=true`、署名鍵は `~/.ssh/id_ed25519_signing`）。
GitHub 上でコミットに **Verified** バッジを表示させるには、公開鍵を GitHub に Signing Key として登録します。

1. ホストから次のコマンドで公開鍵を表示します:
   ```sh
   limactl shell coding-sandbox cat .ssh/id_ed25519_signing.pub
   ```
2. ホストのブラウザで GitHub の [SSH and GPG keys](https://github.com/settings/keys) を開き、**New SSH key** をクリックします。
3. **Key type** で **Signing Key** を選択し（Authentication Key ではなく Signing Key）、表示された公開鍵を貼り付けて登録します。
4. 設定したメールアドレス（`git config --global user.email`）が、GitHub アカウントに登録され検証済み（Verified）になっていることを確認してください。

VM 内での署名の検証確認:

```sh
# テスト用リポジトリでコミットを作成して検証する
cd "$(mktemp -d)" && git init -q && git commit -q --allow-empty -m "test commit"
git log --show-signature -1
```

`Good "git" signature ...` と表示されれば、VM 内での署名とローカル検証が正常に機能しています。GitHub に push すると、GitHub 上でも **Verified** と表示されます。

> [!NOTE]
> VM 作成時に `--param` を指定しなかった場合は、VM 内で手動でユーザ名・メールアドレスを設定し、ローカル検証用設定を作成してください:
> ```sh
> git config --global user.name "<名前>"
> git config --global user.email "<メールアドレス>"
> mkdir -p ~/.config/git
> printf '%s namespaces="git" %s\n' "$(git config --global user.email)" "$(cat ~/.ssh/id_ed25519_signing.pub)" > ~/.config/git/allowed_signers
> git config --global gpg.ssh.allowedSignersFile ~/.config/git/allowed_signers
> ```

### GitHub Copilot CLI

```sh
copilot
```

起動したら `/login` を実行します。SSH 経由の環境ではデバイスコードフローになるので、表示された URL をホストのブラウザで開き、コードを入力してください。
VM にはキーリング（libsecret）が入っていないため、トークンを `~/.copilot/config.json` に平文で保存するかどうか確認されます。
Fine-grained PAT を環境変数（`COPILOT_GITHUB_TOKEN` など）で渡す方法もあります（[認証のドキュメント](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli)）。
ほかに認証情報（環境変数や `/login` で保存したトークン）が無いときは、Copilot CLI は gh のトークンを自動で使います（優先度は最も低い）。

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
ホストからは `make herdr`（または `limactl shell coding-sandbox herdr`）で直接入れます。デタッチするとホストのシェルに戻ります。
ペインの中で `copilot` や `agy` を起動すると、herdr が自動でエージェントとして検出します。

#### ホストの herdr からリモート接続する

ホスト（macOS）にも herdr を入れておくと、ホストの herdr から VM の herdr のセッションに SSH で接続できます。
ペインやエージェントは VM の中で動いたまま、画面の表示はホストの herdr が行うため、ホストのキーバインドやテーマがそのまま使えます。

1. 事前準備（ホストで 1 回だけ）
   - herdr をインストールします（`brew install herdr`。ほかの方法は[公式手順](https://herdr.dev/docs/install/)を参照）
   - ホストの `~/.ssh/config` の先頭に次の 1 行を追加して、`ssh lima-coding-sandbox` で VM に接続できるようにします（Lima がインスタンスごとに作る SSH の設定を読み込みます）:
     ```ssh-config
     Include ~/.lima/*/ssh.config
     ```
2. 接続する
   ```sh
   make herdr-remote   # herdr --remote lima-coding-sandbox と同じ
   ```
   ホストのワークスペースと VM のワークスペースを 1 つのウィンドウで行き来したいときは、VM を保存済みのマシンとして登録します（以後はホストで `herdr` を起動するとサイドバーに表示されます）:
   ```sh
   herdr machine add lima-coding-sandbox
   ```

#### 通知音

herdr は、エージェントが入力を求めてきたとき（承認や質問）と、作業が終わったときに通知音を鳴らします。鳴る条件は種類によって違います。

- 入力を求める音: 常に鳴ります（今表示しているタブのエージェントでも鳴ります）
- 作業が終わった音: 今表示しているタブのエージェントでは鳴りません。同じワークスペースでも、別のタブのエージェントなら鳴ります。また、ターミナルのウィンドウからフォーカスが外れているときは、表示中のタブでも鳴ります（ターミナルがフォーカスの変化を herdr に伝えている場合）

VM の中で起動した場合は VM の herdr が `mpg123` で鳴らし（[音声](#音声)の仕組みで、ホストのスピーカーから出ます）、ホストからリモート接続した場合はホストの herdr が鳴らします。

#### インテグレーション

herdr のサーバを再起動しても同じセッションを再開できるようにするには、[インテグレーション](https://herdr.dev/docs/integrations/)をインストールします。
各エージェントを一度起動して、その設定ディレクトリが作られてから実行してください。

```sh
herdr integration install copilot
herdr integration install antigravity-cli
```

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

## Docker

```sh
docker run --rm hello-world
```

- Docker Engine は公式手順どおりの通常の構成です。デーモンは root 権限のシステムサービス（`docker.service`）として動き、VM の起動時に自動で起動します
- 通常ユーザやエージェントが `sudo` を意識せずに Docker を利用できるよう、`/usr/local/bin/docker` にラッパースクリプト（`exec sudo -n /usr/bin/docker "$@"`）を配置しています。これにより、`docker` や `docker compose` コマンドをそのまま実行できます
- VM 内のユーザはもともとパスワードなしで sudo できるため、権限上の差異はありません

> [!NOTE]
> このラッパーは `sudo` を介して実行するため、Ubuntu の `sudo` の既定動作により、呼び出し元の環境変数（`TAG=dev docker compose up` など）や `HOME` は保持されません。
> Docker Compose で環境変数を使うときはカレントディレクトリの `.env` ファイルに記述するか、コマンドの引数で渡してください。また、`docker login` で保存される認証情報や Docker の設定は `/root/.docker` に保存・参照されます。

## mise

[mise](https://mise.jdx.dev/) で、プロジェクトごとに言語やツールのバージョンを切り替えられます。

```sh
mise use -g node@lts   # グローバル（~/.config/mise/config.toml）に設定してインストールする
cd my-project && mise use python@3.13   # このディレクトリの mise.toml に設定してインストールする
```

`provision/mise.sh` で、`~/.profile` に mise の shims ディレクトリ（`~/.local/share/mise/shims`）を `PATH` の先頭に追加する設定を追記しています。
shim は実行されるたびにカレントディレクトリの設定（`mise.toml` や `.tool-versions`）を読み込んでバージョンを決めます。そのため、対話シェルでも、エージェントが実行する非対話のサブシェル（`bash -c '...'` など）や `limactl shell coding-sandbox <コマンド>` でも、`mise exec` を使わずにそのディレクトリのバージョンが使われます。

```sh
mise use -g node@22
mkdir -p ~/p1 && cd ~/p1 && mise use node@20
cd ~ && bash -c 'cd ~/p1 && node -v'   # v20.x（mise exec なしで自動切替）
```

有効な mise 設定がどこにもないツール（カレントディレクトリ・上位ディレクトリ・グローバル設定のいずれにも未指定のツール）は、shim が `PATH` 上の後続コマンド（Ubuntu のリポジトリから apt でインストールしたシステム標準の `/usr/bin/node` など）に自動でフォールバックします。

> [!NOTE]
> - **環境変数（`[env]`）の反映**: shims 経由で実行されたコマンドとその子プロセスには `mise.toml` の `[env]` が渡されますが、現在のシェル自体の環境変数としては展開されません（`echo $NODE_ENV` のようなシェルの参照には反映されません）。
> - **hooks**: `cd` や `enter` / `leave` などの mise フックは実行されません。
> - **コマンドのパス（`which`）**: `which node` は shim のパス（`~/.local/share/mise/shims/node`）を返します。実体の実行ファイルパスを調べるには `mise which node` を使用してください。
> - **設定ファイルの信頼（trust）**: 単純なバージョン指定（`[tools]`）のみの `mise.toml` は自動で読み込まれますが、環境変数の設定などを含む設定ファイルは、初回に `mise trust` で明示的に信頼するまで shim による読み込みがブロックされます。
> - **自動インストール**: 対象コマンドの shim が存在する場合（過去に `mise use` や `mise install` でそのツールを入れたことがある場合）、設定されたバージョンが未インストールでも shim がその場で自動ダウンロードしてインストールします（mise の `not_found_auto_install` の既定の動作）。なお、作成直後の VM には各ツールの shim がまだ無いため、プロジェクトを clone して作業を開始する際は `mise install`（信頼が必要な場合は先に `mise trust`）を実行してツールと shim を準備してください。自動インストールを止めたいときは `mise settings not_found_auto_install=false` を実行します。
> - **実行オーバーヘッド**: shim はコマンド呼び出しのたびに設定を解決します。スクリプト内のループなどでコマンドを何百回も連続で呼び出す場合は、`mise exec -- <スクリプト>` を使うことで最初の 1 回のみ解決が行われるため高速に実行できます。

> [!WARNING]
> 人間が対話シェルでフックやシェル変数への環境変数自動反映を使いたい場合、`~/.bashrc` に `eval "$(~/.local/bin/mise activate bash)"` を追記することも可能です。
> ただし、activate を有効にするとツールの実体ディレクトリが `PATH` の先頭に配置されるため、そのシェルから起動したエージェントでは、サブシェルで別のディレクトリに移っても起動時のバージョンが使われ、上記の自動切替が効かなくなります。

## 音声

VM の中で再生した音は、ホストのスピーカーから鳴ります。次のコマンドで確認できます（「Front Center」と聞こえます）。

```sh
limactl shell coding-sandbox aplay /usr/share/sounds/alsa/Front_Center.wav
```

- `coding-sandbox.yaml` の `audio.device: vz` で、VM に virtio-sound のデバイスが追加されます（Lima では EXPERIMENTAL の機能です）。再生専用で、録音用のデバイスは無いため、VM からホストのマイクは使えません
- `audio.interface` は QEMU 用の設定です。VZ（macOS での Lima の既定）では常に virtio-sound になるため、指定していません
- VM のカーネルには virtio-sound のドライバが含まれていて、自動で読み込まれます。`provision/audio.sh` で alsa-utils（`aplay`、`speaker-test`）と `mpg123` をインストールし、通常ユーザもサウンドデバイスを使えるようにしています
- `mpg123` は herdr の通知音のために入れています。herdr の通知音は MP3 で、Linux では MP3 を再生できるプレイヤー（`pw-play`、`ffplay`、`mpg123`、`mpv` のいずれか）を使います。`aplay` は MP3 を再生できないため、`mpg123` が無いと herdr の通知音は鳴りません（エラーも表示されません）
- サウンドデバイス（`/dev/snd/*`）は root:audio の 0660 で作られます。通常ユーザを `audio` グループに入れても、Lima はプロビジョニングより前に ssh の接続（ControlMaster）を張っていて、`limactl shell` はその接続のグループを引き継ぐため、VM を再起動するまで反映されません。そのため、udev ルールでパーミッションを 0666 にしています
- `provision/audio.sh` が失敗しても Lima は起動処理を続けるため、probe（`audio playback to be available to the user`）で確認しています。`aplay` と `mpg123` が入っていることに加え、VM に virtio-sound のデバイスが追加されているとき（音声が有効なとき）は、再生デバイスが 1 つ以上あり、通常ユーザが書き込めることを確認します
- PulseAudio や PipeWire は入れていないため、音は ALSA で直接再生します
- ターミナルのベル（`\a`）は、この設定と関係なく、ssh を通ってホストのターミナルに届きます（鳴るかどうかはターミナルの設定によります）

鳴らしたくないときは、`coding-sandbox.yaml` の `audio.device` を空にして（`device: ""`）、インスタンスを作り直してください。`audio:` ごと削除すると、`$LIMA_HOME/_config/default.yaml` に音声の設定があった場合に、そちらが使われます。また、`override.yaml` に音声の設定があると、テンプレートの値よりも優先されるため、そちらも確認してください。

## 更新

| ソフトウェア | 方法 |
|---|---|
| herdr | `herdr update` |
| Antigravity CLI | 自動で更新される |
| GitHub Copilot CLI | `copilot update` |
| mise | `mise self-update` |
| 基本的なツール・GitHub CLI・Docker Engine（apt パッケージ） | `sudo apt-get update && sudo apt-get upgrade` |

## トラブルシューティング

`limactl start` が `Waiting for the optional requirement ...` から進まないとき（タイムアウトの既定値の 10 分が過ぎるとエラーで終了します）は、表示されている requirement を確認してください。

- `no host directories to be mounted`: ホストのディレクトリがマウントされています。[ホストのマウントが混入しないように](#ホストのマウントが混入しないように)を参照してください
- `connections to the host loopback ...`: ホストループバック遮断用ルール（nftables）の読み込みに失敗している可能性があります。VM 内で `sudo systemctl status lima-coding-sandbox-firewall` およびログを確認してください
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
- ホストの herdr からリモート接続（`make herdr-remote`）しても、SSH エージェントは転送されません（VM のペインでは `SSH_AUTH_SOCK` が設定されません）。この接続はホストの `~/.ssh/config` を使うため、`Host *` などで `ForwardAgent yes` を設定していると転送されることがあります。その場合は `lima-*` を対象から外してください
- ポートの自動転送は無効化しています（`portForwards` 設定）。この設定はホスト側の Lima（hostagent）が適用するため、VM 内のユーザが sudo を使っても回避できません。ホストからアクセスしたいポートがあるときは `make forward PORT=<ポート>` を使用してください（[ネットワーク](#ネットワーク)）
- VM からはインターネットに接続できます。また、Lima の仕様上 `host.lima.internal`（`192.168.5.2`）はホストのループバックアドレスにつながっていますが、本サンドボックスでは VM 内の nftables により既定で接続を遮断しています。ただし VM 内のユーザはパスワードなしで sudo できるため、エージェントが意図してファイアウォールを解除することは防げません（誤操作の防止にとどまります）。また、Lima の NAT 仕様やホストのパケットフィルタ（pf）では VM からのループバック接続のみを識別して止めることができないため、認証のない機密サービスをホストで稼働させている場合は引き続き注意してください
- 各 CLI の認証情報は VM 内に保存されます（Copilot CLI と gh は平文で保存される場合があります）。不要になったら `limactl delete` で VM ごと削除してください
- gh でログインすると、そのトークン（既定のスコープは `repo`・`read:org`・`gist`）は、VM 内で同じユーザとして動くエージェントからも使えます。エージェントは、あなたの GitHub アカウントでアクセスできるリポジトリに push したり、issue や PR を作ったりできます。権限を絞りたいときは、対象のリポジトリと権限を限定した fine-grained PAT を、`gh auth login` の代わりに環境変数 `GH_TOKEN` で渡してください（`GH_TOKEN` は Copilot CLI の `/login` で保存したトークンよりも優先されるため、Copilot CLI が使うトークンも変わる点に注意してください）
- Git のコミット署名鍵（`~/.ssh/id_ed25519_signing`）には、エージェントが非対話でコミットできるようパスフレーズを付けていません。そのため VM 内のエージェントもあなたの署名付きコミットを作成できます。GitHub の Verified バッジは「この VM で作成されたコミットである」ことを示し、人間が直接書いたことの証明にはなりません。不要になった VM を削除する際は、GitHub の [SSH and GPG keys](https://github.com/settings/keys) から対応する Signing Key も削除してください

## 開発

`scripts/lint.sh` で、テンプレートの検証（`limactl validate`）と、provision スクリプトおよびテンプレートに書いた probes の shellcheck を実行します（shellcheck は `brew install shellcheck` でインストールする）。

```sh
./scripts/lint.sh
```

GitHub Actions（`.github/workflows/ci.yml`）でも、main ブランチへの push と pull request のたびに同じスクリプトを実行します。Lima は、`minimumLimaVersion` のバージョンと最新のリリースの 2 つで確認します。

push しない間に Lima の新しいリリースでテンプレートの検証が通らなくなっても気づけるように、毎週火曜の 9:23（日本時間）にも同じ CI を実行します。失敗したときは、GitHub の通知（Settings → Notifications → Actions）で知らせが届きます。

`ci.yml` で使うアクションは、コミットの SHA で固定しています。Dependabot（`.github/dependabot.yml`）が毎週火曜に新しい版を確認し、公開から 7 日たった新しい版があれば、SHA と末尾のバージョンのコメントを更新する pull request を作ります。

probes は `file:` で別のファイルに分けず、`coding-sandbox.yaml` に直接書いています。Lima 2.2.0 では、probes の `file:` がインスタンスの作成時に取り込まれないためです（provision の `file:` は取り込まれます）。
