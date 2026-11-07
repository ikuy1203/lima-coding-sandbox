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
| ソフトウェア | 基本的なツール（git、gh、build-essential、ripgrep、Python の venv・pipx、Node.js など。[後述](#基本的なツール)）、herdr、Antigravity CLI（`agy`）、GitHub Copilot CLI（`copilot`）、mise、Docker Engine、ファイアウォール（nftables）、Git のユーザ設定・コミット署名鍵、ターミナル（`$TERM`）の terminfo の代替設定、エージェント向けの指示ファイル（既定は無効。[後述](#エージェント向けの指示ファイル)） |

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
| エージェント指示ファイル | - | `provision/agent-instructions.sh` | `~/.copilot/copilot-instructions.md`、`~/.gemini/config/rules/lima-coding-sandbox.md`（有効化時のみ。[後述](#エージェント向けの指示ファイル)） |

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

> [!TIP]
> 上記のうち、GitHub Copilot CLI と mise は `.env`（または `--param`）でバージョンを指定してインスタンスを作成することで、動作確認済みのバージョンを再現できます（[後述](#作成時の設定git-ユーザ情報ホストループバック遮断エージェント指示配置cli-バージョンを-env-で指定する)）。
> 実際にホストと VM に導入されたソフトウェアのバージョンは、`make versions` で一覧確認できます。

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
│   ├── mise.sh                # mode: user
│   └── agent-instructions.sh  # mode: user    エージェント向け指示ファイル（既定は無効）
├── scripts/                   # Makefile から呼び出す操作スクリプトと、検査・テストスクリプト
│   ├── lib.sh                 # 共通関数（インスタンスの状態取得、入力値の正規化、NAME・AUTH_BACKUP_DIR 検証）
│   ├── create.sh              # make create（マウント検証・入力値正規化・インスタンス作成）
│   ├── start.sh               # make start（マウント検証・インスタンス起動）
│   ├── shell.sh               # make shell / herdr / pubkey / logs（インスタンス内でシェルまたはコマンドを実行）
│   ├── status.sh              # make status（インスタンス状態表示）
│   ├── stop.sh                # make stop（インスタンス停止）
│   ├── delete.sh              # make delete（確認付きインスタンス削除）
│   ├── herdr-remote.sh        # make herdr-remote（ホストの herdr から VM へリモート接続）
│   ├── ssh-config.sh          # make ssh-config（SSH 接続設定と ~/.ssh/config 用 Include の表示）
│   ├── forward.sh             # make forward（VM のポートをホストへ SSH 転送）
│   ├── terminfo.sh            # make terminfo（ホストの terminfo を検証して VM へコピー）
│   ├── backup-auth.sh         # make backup-auth（認証情報・Git 署名鍵をホストへ退避・検証）
│   ├── restore-auth.sh        # make restore-auth（退避した認証情報・Git 署名鍵を VM へ復元）
│   ├── update.sh              # make update（VM 内のツールと apt パッケージを一括更新）
│   ├── versions.sh            # make versions（ホストと VM 内の主要ソフトウェアのバージョンを一覧表示）
│   ├── register-key.sh        # make register-key（Git 署名鍵をホストの gh で GitHub に登録）
│   ├── lint.sh                # テンプレートとスクリプトの検査（CI でも実行する）
│   └── test.sh                # プロビジョニングスクリプトと Makefile / scripts の回帰テスト（CI でも実行する）
└── .github/
    ├── dependabot.yml         # GitHub Actions のアクションの更新を週 1 回確認する
    └── workflows/ci.yml       # GitHub Actions（lint・回帰テスト・実 VM 起動テストを実行する）
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
| `make start` | インスタンスが無ければ作成してから起動する。作成時には、Git のユーザ名とメールアドレスを `--param` で渡す（[後述](#作成時の設定git-ユーザ情報ホストループバック遮断エージェント指示配置cli-バージョンを-env-で指定する)）。ホストループバック遮断、エージェント向け指示ファイルの配置の有無、CLI ツールの固定バージョンも指定できる（[後述](#作成時の設定git-ユーザ情報ホストループバック遮断エージェント指示配置cli-バージョンを-env-で指定する)）。作成前・起動前にホストマウントの混入を自動検査し、設定されている場合は起動を拒否する（[後述](#ホストのマウントが混入しないように)） |
| `make shell` | シェルに入る（停止していれば先に起動する） |
| `make herdr` | herdr のセッションに入る（無ければ作る。停止していれば先に起動する） |
| `make herdr-remote` | ホストの herdr から VM のセッションにリモート接続する（停止していれば先に起動する。[後述](#herdr)） |
| `make ssh-config` | 起動中の VM の SSH 接続設定（`~/.ssh/config` に追加する `Include` 行と `~/.lima/<NAME>/ssh.config` の内容）を表示する（[後述](#vs-code--cursor-から接続するremote---ssh)） |
| `make forward` | VM のポートをホストの `127.0.0.1` に転送する（`PORT=<VMのポート>` が必須。`HOST_PORT=<ホスト側ポート>` で変えられる。Ctrl-C で終了。[後述](#ネットワーク)） |
| `make terminfo` | ホストの terminfo を VM にコピーする（既定はホストの `$TERM`。`TERM_NAME=<名前>` で変えられる。停止していれば先に起動する。[後述](#シェルに入る)） |
| `make backup-auth` | VM 内の認証情報（`gh`・`copilot`）と Git コミット署名鍵をホストに退避する（既定は `~/.local/share/lima-coding-sandbox/auth-backup/<NAME>`。`AUTH_BACKUP_DIR=<パス>` で変えられる。[後述](#インスタンスを作り直す認証情報と作業データの退避復元)） |
| `make restore-auth` | ホストに退避した認証情報と Git コミット署名鍵を VM に復元する（停止していれば先に起動する。[後述](#インスタンスを作り直す認証情報と作業データの退避復元)） |
| `make update` | 起動中の VM 内のツール（`herdr`・`copilot`・`mise`）と `apt` パッケージを一括更新する（[後述](#更新)） |
| `make versions` | ホストと起動中の VM 内の主要ソフトウェアのバージョンを一覧表示する |
| `make stop` / `make restart` | 停止 / 再起動（再起動は、失敗したプロビジョニングのやり直しにも使える） |
| `make status` | 状態を表示する |
| `make delete` | 削除する（確認あり。起動中なら署名鍵の指紋を表示。`YES=1` を付けると確認を省略。[後述](#インスタンスを作り直す認証情報と作業データの退避復元)） |
| `make recreate` | 削除してから作り直す（`coding-sandbox.yaml` や `provision/*.sh` の変更を反映するとき。[後述](#インスタンスを作り直す認証情報と作業データの退避復元)） |
| `make pubkey` | Git のコミット署名用の公開鍵を表示する（[後述](#git-のコミット署名)） |
| `make register-key` | Git のコミット署名用の公開鍵を、ホストの `gh` で GitHub に Signing Key として登録する（停止していれば先に起動する。[後述](#git-のコミット署名)） |
| `make logs` | プロビジョニングのログ（cloud-init）の末尾を表示する |
| `make lint` | `scripts/lint.sh` を実行する |

変数をコマンドラインで指定すると、インスタンス名・リソース（作成時のみ有効）・タイムアウト・Git の設定・ホストループバック遮断・エージェント指示配置・CLI バージョンを変えられます。

```sh
make start NAME=sandbox2 CPUS=8 MEMORY=16 DISK=200 TIMEOUT=30m
make start GIT_USER_NAME="<名前>" GIT_USER_EMAIL="<メールアドレス>" BLOCK_HOST_LOOPBACK=false AGENT_INSTRUCTIONS=true
make start COPILOT_VERSION=1.0.91 MISE_VERSION=2026.10.7
```

`--param` は `limactl create` で渡しているため、名前にカンマが含まれていても問題ありません。

#### 作成時の設定（Git ユーザ情報・ホストループバック遮断・エージェント指示配置・CLI バージョン）を .env で指定する

`.env.example` をコピーして `.env` を作り、値を書きます（`.env` は `.gitignore` で除外しています）。

```sh
cp .env.example .env
```

```sh
# .env
GIT_USER_NAME=Taro Yamada
GIT_USER_EMAIL=taro@example.com
BLOCK_HOST_LOOPBACK=true
AGENT_INSTRUCTIONS=false
COPILOT_VERSION=1.0.91
MISE_VERSION=2026.10.7
```

- `.env` を読むのは Makefile だけです。VM には `limactl create --param` で値だけを渡し、`.env` 自体はコピーしません
- 値は次の順で決まります: コマンドライン（`make start GIT_USER_NAME=...`） ＞ `.env` ＞ ホストの `git config --global`（Git 情報の場合）。`.env` が無いときや値が空のときは既定値を使います
- `BLOCK_HOST_LOOPBACK` は、VM から `host.lima.internal`（ホストの `127.0.0.1`）への通信を遮断するかを指定します（`true` / `false`、空なら既定値の `true`。[後述](#ネットワーク)）
- `AGENT_INSTRUCTIONS` は、VM の前提をまとめたエージェント向けの指示ファイルを配置するかを指定します（`true` / `false`、空なら既定値の `false`。[後述](#エージェント向けの指示ファイル)）
- `COPILOT_VERSION`・`MISE_VERSION` は、GitHub Copilot CLI と mise の初回インストール時のバージョンを指定します（空なら最新版。`COPILOT_VERSION` には `prerelease` も指定可能）。指定が効くのはインスタンス作成時のみで、以後の更新は各ツールの更新コマンドに任せます（herdr と Antigravity CLI は公式インストーラが未対応のため対象外）
- make の書式で読み込むため、値に空白やカンマがあってもクォートは要りません（両端を `"` か `'` で囲んだときは、その 1 組を取り除きます）。`#` から行末はコメントになります
- 別のファイルを使うには `ENV_FILE` を指定します（例: `make start ENV_FILE=work.env`。指定したファイルが無いとエラーになります）。`*.env` も `.gitignore` で除外しています
- 値が反映されるのは**インスタンスを作成するときだけ**です。作成後に `.env` を変えても今の VM にには反映されません。`make recreate` で作り直してください
- Makefile の変数（`NAME`、`CPUS` など）も `.env` に書けます（コマンドラインで指定した値が優先されます）

以下では、`make` を使わずに `limactl` で直接操作する方法を説明します。

### 作成・起動

```sh
limactl start ./coding-sandbox.yaml
```

Git のユーザ名とメールアドレス、ホストループバック遮断、およびツールの固定バージョンをあらかじめ設定するには、作成時に `--param` で渡します（ホストの Git 設定をそのまま渡すこともできます）:

```sh
limactl start \
  --param "gitUserName=$(git config --global user.name)" \
  --param "gitUserEmail=$(git config --global user.email)" \
  --param "blockHostLoopback=true" \
  --param "agentInstructions=false" \
  --param "copilotVersion=1.0.91" \
  --param "miseVersion=2026.10.7" \
  ./coding-sandbox.yaml
```

> [!NOTE]
> `limactl start --param` はカンマで値を区切るため、名前にカンマが含まれる場合は `limactl create --param "gitUserName=..." --param "gitUserEmail=..." ./coding-sandbox.yaml` で作成してから `limactl start coding-sandbox` で起動してください。

インスタンス名は `coding-sandbox` です（変えるときは `--name=<名前>` を付ける）。
初回はイメージのダウンロードとプロビジョニングがあるため数分かかります。
起動時に `probes` で次の 9 点を確認し、すべて満たされた時点で完了します。

1. ホストのディレクトリがマウントされていないこと
2. 基本的なツール（git、gh など）がインストールされており、GitHub CLI（`gh`）が公式 apt リポジトリから導入されて正常に起動できること
3. ホストのループバック（host.lima.internal）への接続が遮断されていること（`blockHostLoopback` が true の場合）
4. herdr / Antigravity CLI / GitHub Copilot CLI / mise がインストールされており、各 CLI が正常に起動できること（`--version` のタイムアウト付き実動作確認）
5. ログインシェルの PATH の先頭が mise の shims になっていること
6. Docker Engine が動いていること
7. 音声を再生できること（`aplay` と `mpg123` がインストールされていて、音声が有効なときは通常ユーザが再生デバイスに書き込めること）
8. Git のコミット署名（SSH 鍵ペアの整合性および一時リポジトリでの署名・検証）が設定されていること
9. エージェント向けの指示ファイルが作成されていること（`agentInstructions` が true の場合）

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

### VS Code / Cursor から接続する（Remote - SSH）

ホストの VS Code や Cursor に **Remote - SSH** 拡張機能を入れておくと、VM 内のディレクトリ（`/home/<user>.guest/...`）を直接ワークスペースとして開けます。

1. **SSH 設定の確認と `~/.ssh/config` の準備（初回のみ）**
   VM が起動している状態で `make ssh-config` を実行すると、ホスト名（`lima-coding-sandbox`）、`~/.ssh/config` に追加すべき `Include` 行、現在の設定状態、および `~/.lima/coding-sandbox/ssh.config` の内容が表示されます。
   ```sh
   make ssh-config
   ```
   ホストの `~/.ssh/config` にまだ設定していない場合は、**先頭**に次の 1 行を追加します（Lima がインスタンスごとに生成する `ssh.config` を読み込みます。`make herdr-remote` と共通の設定です。なお、SSH のポート番号は VM の起動のたびに変わることがあるため、`ssh.config` の中身を `~/.ssh/config` に直接コピーせず、必ず `Include` を使ってください）:
   ```ssh-config
   Include ~/.lima/*/ssh.config
   ```
2. **エディタから接続する**
   - コマンドパレット（`Cmd+Shift+P`）から **Remote-SSH: Connect to Host...** を実行し、一覧から **`lima-coding-sandbox`**（`NAME` を変えた場合は `lima-<NAME>`）を選択します。
   - 新しいウィンドウが開いたら、**Open Folder**（またはコマンドライン）から VM 内のプロジェクトディレクトリ（例: `/home/<user>.guest/my-project`）を開きます。
   - ホストのターミナルから直接開く場合は、次のコマンドを使います:
     ```sh
     # VS Code の場合
     code --remote ssh-remote+lima-coding-sandbox /home/<user>.guest/my-project

     # Cursor の場合
     cursor --remote ssh-remote+lima-coding-sandbox /home/<user>.guest/my-project
     ```

> [!NOTE]
> - **エディタ側の自動ポート転送**: 本サンドボックスでは Lima による自動ポート転送を無効化していますが、VS Code / Cursor の Remote - SSH には、接続中に VM 内で待ち受けられたポートを検知してホストへ自動転送する独自機能（`remote.autoForwardPorts`、既定で有効）があります。意図しないポート転送を防ぎたい場合は、設定で `"remote.autoForwardPorts": false` を指定し、必要なポートのみエディタの Ports ビューまたは `make forward PORT=<ポート>` で手動転送してください（[ネットワーク](#ネットワーク)を参照）。
> - **エディタ側の GitHub / Git 認証情報の引き継ぎ**: VS Code / Cursor は既定で、ホスト側のエディタにサインインしている GitHub セッションの認証情報をリモート環境内の Git 操作や統合ターミナルへ引き継ぎます（`github.gitAuthentication` および `git.terminalAuthentication`、いずれも既定で有効）。VM 内のユーザはパスワードなしで `sudo` できるため、接続中はリモート拡張ホスト経由でこれらの認証情報に VM 内のエージェントからもアクセスしうると考える必要があります。Git 操作・統合ターミナルへの引き継ぎを止めたい場合や、VM 内の権限を `GH_TOKEN` 等で絞っている場合は、設定で `"github.gitAuthentication": false` と `"git.terminalAuthentication": false` を指定してください。なお、これら 2 つの設定は Git / ターミナル向けの認証引き継ぎを止めるものであり、VM 側（リモート拡張ホスト）で動作し GitHub セッションを使用する拡張機能（GitHub Copilot Chat や GitHub Pull Requests など）を有効にしている場合は、その拡張機能経由でもリモート側でトークンが扱われる点に注意してください（[セキュリティ上の注意](#セキュリティ上の注意)を参照）。
> - **SSH エージェントの転送**: Remote - SSH はホストの `~/.ssh/config` を参照するため、`Host *` などで `ForwardAgent yes` を設定しているとホストの SSH エージェントが VM に転送されることがあります。その場合は `lima-*` を対象から外してください（[セキュリティ上の注意](#セキュリティ上の注意)を参照）。

### 停止・削除

```sh
limactl stop coding-sandbox
limactl delete coding-sandbox
```

### インスタンスを作り直す（認証情報と作業データの退避・復元）

`coding-sandbox.yaml` や `provision/*.sh`、`.env` の変更を反映するために `make recreate`（または `limactl delete` → `limactl start`）を実行すると、VM 内のすべてのファイル・認証情報・Git 署名鍵が消去されます。

#### 1. 削除前の作業データの確認と退避

> [!WARNING]
> **未 push のコミット、未コミット・未追跡のファイル（`.env` など）、および Git 管理外の作業データは、新しく作った VM で `git clone` し直すだけでは復元できません。**
> インスタンスを削除・再作成する前に、必要な変更をリモートリポジトリへ `git push` するか、ホストへ退避してください。

VM 内の作業ディレクトリをホスト側へ手動で退避・復元する例:

```sh
# 削除前: VM 内の作業ディレクトリをホストの一時ディレクトリにコピーする
mkdir -p ~/lima-workspace-backup
limactl copy -r coding-sandbox:~/my-project ~/lima-workspace-backup/

# 再作成後: 新しい VM に書き戻す
limactl copy -r ~/lima-workspace-backup/my-project coding-sandbox:~/
```

#### 2. 認証情報と Git コミット署名鍵の退避・復元（`make backup-auth` / `make restore-auth`）

`make backup-auth` と `make restore-auth` を使うと、GitHub への Signing Key の再登録や CLI のブラウザ認証をやり直さずに VM を作り直せます。

```sh
# 1. 現在の VM（起動中）から認証情報と署名鍵をホストへ退避する
make backup-auth

# 2. インスタンスを削除して作り直す
make recreate

# 3. 新しい VM に認証情報と署名鍵を復元する
make restore-auth
```

1 コマンドで連続実行することもできます（`make backup-auth` が失敗した場合は `recreate` に進まず中断します）:

```sh
make backup-auth recreate restore-auth
```

対象となる VM 内のファイル:
- `~/.ssh/id_ed25519_signing`、`~/.ssh/id_ed25519_signing.pub`（Git コミット署名用 SSH 鍵。復元時に `~/.config/git/allowed_signers` の更新と署名検証も自動で行われるため、GitHub への公開鍵の再登録は不要です）
- `~/.config/gh`（GitHub CLI の認証情報・設定。復元時に `gh auth setup-git` も実行し、Git の HTTPS 認証連携を再設定します）
- `~/.copilot/config.json`（GitHub Copilot CLI の設定・平文保存された認証情報。`provision/agent-instructions.sh` が管理する `~/.copilot/copilot-instructions.md` やセッションログは対象外のため、新しい VM の設定と競合しません）

退避先とセキュリティ・運用上の注意点:
- **退避先ディレクトリと権限**: 既定の退避先は `~/.local/share/lima-coding-sandbox/auth-backup/<NAME>` です（`AUTH_BACKUP_DIR=<パス>` で変更可能）。秘密鍵や平文トークンを保護するため、ディレクトリは `0700`、ファイルは `0600`（所有者のみ読み書き可）で保存されます。
- **保存場所の制限**: 誤コミットや情報漏洩を防ぐため、このリポジトリ内のパスやシンボリックリンク先は `AUTH_BACKUP_DIR` に指定できません。別パスを指定する場合も、Git リポジトリ内やクラウド同期フォルダ・共有ディレクトリは避けてください。
- **退避データの削除**: 退避データは `make restore-auth` の後もホストに残ります。不要になった場合は削除してください:
  ```sh
  rm -rf ~/.local/share/lima-coding-sandbox/auth-backup/coding-sandbox
  ```
- **再ログインが必要なケース**: 退避した設定ファイルを復元しても、トークンの有効期限切れ・失効や CLI 側の保存仕様によっては認証エラーになる場合があります。その場合は VM 内で `gh auth login` や `copilot` の `/login` を再実行してください（Antigravity CLI は対象外のため、必要に応じて [Antigravity CLI](#antigravity-cli) の手順で再設定してください）。
- **署名鍵を復元しない場合**: `make backup-auth` / `make restore-auth` を使わずに VM を作り直した場合は、新しい署名鍵が生成されます。[Git のコミット署名](#git-のコミット署名) の手順（`make register-key` など）で新しい公開鍵を登録し、GitHub の [SSH and GPG keys](https://github.com/settings/keys)（またはホストの `gh api`）から古い VM の Signing Key を削除してください（[セキュリティ上の注意](#セキュリティ上の注意)を参照）。

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
鍵のコメントにはインスタンス名と作成日（`git-signing <user>@lima-<NAME> <YYYY-MM-DD>`）が入ります。
GitHub 上でコミットに **Verified** バッジを表示させるには、公開鍵を GitHub に Signing Key として登録し、設定したメールアドレス（`git config --global user.email`）が GitHub アカウントで検証済み（Verified）になっていることを確認してください。

#### ホストの `gh`（GitHub CLI）で登録する（`make register-key`）

VM 内の `gh` ではなくホスト側の `gh` を使って登録することで、VM 内のトークン（エージェントも利用可能）に鍵を管理する強い権限を与えずに済みます。

1. 初回のみ、ホストの `gh` のトークンに署名鍵を扱うスコープ（一覧に `read:ssh_signing_key`、登録に `write:ssh_signing_key`）を追加します（削除までホストの `gh` で行う場合は `admin:ssh_signing_key` も追加してください）:
   ```sh
   gh auth refresh -h github.com -s read:ssh_signing_key,write:ssh_signing_key
   ```
2. ホストから `make register-key` を実行します（タイトル `<NAME> <YYYY-MM-DD>` で Signing Key として登録されます。日付には鍵のコメントの作成日が使われ、コメントに日付が無ければ今日の日付になります。同じ鍵が登録済みなら何もしません）:
   ```sh
   make register-key
   ```
   `make` を使わない場合は次のコマンドで登録できます:
   ```sh
   limactl shell coding-sandbox cat .ssh/id_ed25519_signing.pub \
     | gh ssh-key add --type signing --title "coding-sandbox $(date +%Y-%m-%d)"
   ```

#### ブラウザから手動で登録する（`make pubkey`）

1. ホストから次のコマンドで公開鍵を表示します:
   ```sh
   make pubkey   # または limactl shell coding-sandbox cat .ssh/id_ed25519_signing.pub
   ```
2. ホストのブラウザで GitHub の [SSH and GPG keys](https://github.com/settings/keys) を開き、**New SSH key** をクリックします。
3. **Key type** で **Signing Key** を選択し（Authentication Key ではなく Signing Key）、表示された公開鍵を貼り付けて登録します。

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

## エージェント向けの指示ファイル

コーディングエージェント（GitHub Copilot CLI や Antigravity CLI 等）はサンドボックスリポジトリ自体の README を読まないため、ホストディレクトリがマウントされていないことや、Docker ラッパーの制約、mise shims の仕様、ポート自動転送が無効であることなどの前提を知らないまま作業してエラーや手戻りを起こすことがあります。

本サンドボックスでは、VM の前提仕様をまとめた指示ファイルを各エージェントのグローバル設定パスに配置する機能（`provision/agent-instructions.sh`）を用意しています。

> [!NOTE]
> エージェントの振る舞いをむやみに変更したくない利用者のために、**既定では指示ファイルを配置しません（`agentInstructions: "false"`）**。
> エージェントに VM の前提を自動共有させたい場合のみ、以下の方法で有効化（オプトイン）してください。

### 指示ファイルの配置先

有効化すると、`mode: user` のプロビジョニングにより次のパスに指示が配置されます:

| ソフトウェア | 配置先 | 形式・管理方針 |
|---|---|---|
| GitHub Copilot CLI | `~/.copilot/copilot-instructions.md` | `<!-- BEGIN lima-coding-sandbox agent-instructions -->` 〜 `<!-- END lima-coding-sandbox agent-instructions -->` のマーカーコメントで囲まれたブロックとして配置。利用者が独自に記述した内容はそのまま保持され、マーカーブロックのみが更新されます（※マーカーコメントが欠落・重複・破損している場合は、既存内容の消失を防ぐため更新・削除をスキップして警告を出力します。またシンボリックリンクの場合は参照先の実体を更新し、リンク構造を維持します） |
| Antigravity CLI | `~/.gemini/config/rules/lima-coding-sandbox.md` | YAML フロントマター（`trigger: always_on`）付きの専用ルールファイルとして配置。`~/.gemini/AGENTS.md` や他のルールファイルとは完全に分離して管理されます（※同名ファイルが既に存在し、本スクリプトの管理マーカーがない場合は、利用者の独自ルールを保護するため上書き・削除をスキップして警告を出力します） |

### 指示ファイルに記載される主な内容

1. **ファイルシステムと権限**: ホストのファイルはマウントされていないこと、パスワードなしで `sudo` が利用可能であること
2. **Docker**: `docker` / `docker compose` を `sudo` なしで実行できること、ただしラッパー経由のため呼び出し元の環境変数や `HOME` は保持されない制約（`.env` ファイルやオプションで渡す必要があること）
3. **ランタイムとパッケージ管理**: `mise` の shims により `mise exec` 不要で自動バージョン切替が効くこと（初回は `mise install` / `mise trust` が必要なこと）、システムの Python（`pip3 install` 不可。venv / pipx を使用）や Node.js（`npm install -g` の権限エラー。npx や mise を使用）の注意点
4. **ネットワークとブラウザ**: VM 内にブラウザが無いこと、ポートはホストに自動転送されないため `make forward PORT=<ポート>` が必要なこと、`host.lima.internal`（ホストの `127.0.0.1`）へのアクセス遮断（nftables）を勝手に解除しないこと
5. **Git と GitHub**: コミット・タグは SSH 署名鍵で自動署名されること、`git push` や `gh` の操作は利用者の GitHub アカウントの権限で行われるため指示された範囲に限定すべきこと

### 有効化（オプトイン）する方法

作成時に有効化するには、`.env` に `AGENT_INSTRUCTIONS=true` を記述するか、`make start` または `limactl start` にパラメータを渡します。

```sh
# .env で有効化する場合
AGENT_INSTRUCTIONS=true

# コマンドラインで有効化する場合
make start AGENT_INSTRUCTIONS=true
```

`make` を使わない場合:

```sh
limactl start --param "agentInstructions=true" ./coding-sandbox.yaml
```

### 作成後に切り替える方法

インスタンス作成後に有効化または無効化する場合は、VM を停止してから設定を更新して再起動します:

```sh
# 有効化する場合
make stop
limactl edit --tty=false coding-sandbox --set '.param.agentInstructions = "true"'
make start

# 無効化する場合
make stop
limactl edit --tty=false coding-sandbox --set '.param.agentInstructions = "false"'
make start
```

無効化（`agentInstructions: "false"`）にして起動すると、`~/.gemini/config/rules/lima-coding-sandbox.md` は自動削除され、`~/.copilot/copilot-instructions.md` は管理マーカーブロックのみが取り除かれます（利用者が独自に追記していた内容は保持され、管理ブロックのみで空になった場合はファイル自体が削除されます。ただしシンボリックリンクの場合はリンクを削除せず参照先を空にしてリンク構造を維持します。またマーカー破損や管理外ファイルが存在する場合は警告を出力して削除をスキップします）。

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

ホストから `make update` を実行すると、起動中の VM 内の `herdr`・`GitHub Copilot CLI`・`mise`・`apt` パッケージを非対話で一括更新できます（`Antigravity CLI` はバックグラウンドで自動更新されるため対象外です）。

```sh
make update
```

- VM 内で `herdr` のセッションが稼働中で、かつ稼働中の `herdr` サーバーの停止・再起動を伴う更新である場合、稼働中のセッションやペインを止めないよう `herdr` のバイナリ更新はスキップされ、メッセージが表示されます。セッションを終了してから再度 `make update`（または VM 内で `herdr update`）を実行してください（サーバー再起動を伴わない更新はセッション稼働中でもそのまま反映されます）
- 稼働中の `copilot` プロセスには影響せず、次回起動時から新しいバージョンが使われます。また、作成時に `COPILOT_VERSION` や `MISE_VERSION` でバージョンを固定していた場合も、`make update` を実行すると最新版に更新されます
- `apt` で `docker-ce` パッケージが更新されると Docker デーモンが再起動し、稼働中のコンテナが停止する点に注意してください
- カーネルの更新などで VM の再起動が必要な場合（`/var/run/reboot-required` がある場合）は、完了時に案内が表示されます。案内に従って `make restart` を実行してください

VM 内で個別に更新する場合は、以下のコマンドを実行します。

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

プロビジョニングスクリプトは VM を起動するたびに実行され、インストール済みのソフトウェアは飛ばすように作ってあります。外部インストーラスクリプト（herdr, agy, copilot, mise）や apt リポジトリの鍵（GitHub CLI, Docker Engine）の取得には、接続タイムアウト（既定 10 秒）・試行上限（既定 60 秒）・総時間上限（既定 180 秒）・限定回数のリトライ（既定 3 回、2/4/8 秒の指数バックオフ）を設けており、一時的な通信障害（タイムアウトや HTTP 5xx、接続切断等）からは自動で回復します。また、すべての外部スクリプト・鍵は一時ファイルへのダウンロードが完了してから実行・配置されるため、通信切断などで壊れたスクリプトが実行されたり既存の鍵ファイルが破損したりすることはありません。

各 CLI ツール（herdr, agy, copilot, mise）および GitHub CLI（gh）は、単なるファイルの存在確認だけでなく、タイムアウト付きの `--version` 実行により実動作を確認します。既存のバイナリが破損していた場合（実行不可、タイムアウト、非ゼロ終了）は自動で除去されて再インストールが行われます。また、`COPILOT_VERSION` や `MISE_VERSION` でバージョンを指定して作成した場合は、導入直後に `--version` の出力と指定版の完全一致を検証します。存在しないバージョンの指定や、指定が無視されて最新版へ暗黙にフォールバックされた場合はエラーとなり、未検証のバイナリを残さず安全に失敗します（指定したバージョンが効くのは初回インストール時のみで、以後に `copilot update` や `mise self-update` で手動更新されたバージョンは再起動時にも維持されます）。

また Git のコミット署名についても、秘密鍵・公開鍵のペア整合性と一時リポジトリでの署名・ローカル検証をプロビジョニングおよび起動時 probes の双方で確認し、意図しない設定破損や起動失敗を防止します。

各配布方式のチェックサム・署名検証の仕組みと制約は以下のとおりです:
- **GitHub Copilot CLI**: 公式インストーラが GitHub Releases からアーカイブと `SHA256SUMS.txt` を取得し、`sha256sum` で SHA-256 チェックサムを検証します（不一致時は中断）。ただし `SHA256SUMS.txt` の取得自体が失敗した場合は検証をスキップして続行する制約（fail-open）があるため、本サンドボックスでは導入後のバージョン一致・実動作確認を厳格に行います。
- **mise**: 公式インストーラが解決したバージョンとスクリプト自身の埋め込みバージョンを比較し、同一であれば埋め込みチェックサム、異なる場合は GitHub Releases から `SHASUMS256.txt` を取得して照合します。チェックサムが取得できない場合や不一致時は即座に中断します（fail-closed）。
- **herdr**: 公式インストーラが `latest.json` に記載された `sha256` と取得バイナリを照合して検証します（独立した署名ファイルは公開されていません）。バージョン指定には未対応です。
- **Antigravity CLI**: 公式インストーラが Google Cloud Storage から `checksums.txt` を取得して照合します（`checksums.txt` 不在時はスキップされる制約があります）。バージョン指定には未対応で、バックグラウンドで自動更新されます。
- **apt パッケージ（gh, docker）**: 公式リポジトリの GPG 公開鍵リング（`githubcli-archive-keyring.gpg`、`docker.asc`）を登録し、APT パッケージマネージャ自身の暗号署名検証（InRelease / Release.gpg）によって改ざん防止と完全性を担保しています。

> [!NOTE]
> スクリプトが設けているタイムアウト・リトライおよび一時ファイル管理は、本プロジェクトが直接取得する**インストーラスクリプト自体の取得および apt 鍵の取得**を対象としています。各ツールの公式インストーラ内部で行われる本体アーカイブ等のダウンロードの挙動（タイムアウト設定の有無、失敗時の終了コード、部分配置や残存ファイルの後始末）は、各上流ツールの実装に依存します（外側の `curl` オプションは引き継がれません）。上流インストーラ内部の取得で失敗した場合は、`/var/log/cloud-init-output.log` のエラーログを確認してください。

ネットワークの一時的な障害などで失敗したときは、VM を起動し直すと、インストールされていないものだけをもう一度インストールします。

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
- ホストの herdr からリモート接続（`make herdr-remote`）したり、VS Code / Cursor の Remote - SSH で接続したりしても、Lima の設定（`~/.lima/<NAME>/ssh.config`）自体は SSH エージェントを転送しません（VM 内では `SSH_AUTH_SOCK` が設定されません）。ただし、これらの接続はホストの `~/.ssh/config` を使うため、`Host *` などで `ForwardAgent yes` を設定していると転送されることがあります。その場合は `lima-*` を対象から外してください
- ポートの自動転送は無効化しています（`portForwards` 設定）。この設定はホスト側の Lima（hostagent）が適用するため、VM 内のユーザが sudo を使っても回避できません。ホストからアクセスしたいポートがあるときは `make forward PORT=<ポート>` を使用してください（[ネットワーク](#ネットワーク)）。なお、VS Code / Cursor の Remote - SSH で接続している間は、エディタ自身の自動ポート転送機能（`remote.autoForwardPorts`）が既定で働く点に注意してください（[VS Code / Cursor から接続する（Remote - SSH）](#vs-code--cursor-から接続するremote---ssh)）
- VM からはインターネットに接続できます。また、Lima の仕様上 `host.lima.internal`（`192.168.5.2`）はホストのループバックアドレスにつながっていますが、本サンドボックスでは VM 内の nftables により既定で接続を遮断しています。ただし VM 内のユーザはパスワードなしで sudo できるため、エージェントが意図してファイアウォールを解除することは防げません（誤操作の防止にとどまります）。また、Lima の NAT 仕様やホストのパケットフィルタ（pf）では VM からのループバック接続のみを識別して止めることができないため、認証のない機密サービスをホストで稼働させている場合は引き続き注意してください
- 各 CLI の認証情報は VM 内に保存されます（Copilot CLI と gh は平文で保存される場合があります）。不要になったら `limactl delete` で VM ごと削除してください。また、`make backup-auth` でホストに退避した認証情報・署名鍵（既定は `~/.local/share/lima-coding-sandbox/auth-backup/<NAME>`）も、不要になったらホストから削除してください
- gh でログインすると、そのトークン（既定のスコープは `repo`・`read:org`・`gist`）は、VM 内で同じユーザとして動くエージェントからも使えます。エージェントは、あなたの GitHub アカウントでアクセスできるリポジトリに push したり、issue や PR を作ったりできます。権限を絞りたいときは、対象のリポジトリと権限を限定した fine-grained PAT を、`gh auth login` の代わりに環境変数 `GH_TOKEN` で渡してください（`GH_TOKEN` は Copilot CLI の `/login` で保存したトークンよりも優先されるため、Copilot CLI が使うトークンも変わる点に注意してください）。また、VS Code / Cursor の Remote - SSH で接続すると、既定ではホスト側エディタの GitHub 認証情報がリモート環境の Git / ターミナルやリモート拡張ホスト上の拡張機能へ引き継がれるため、権限を絞る場合はエディタ側の `"github.gitAuthentication": false`・`"git.terminalAuthentication": false` の設定や、VM 側で動作する GitHub 連携拡張機能の扱いに注意してください（[VS Code / Cursor から接続する（Remote - SSH）](#vs-code--cursor-から接続するremote---ssh)）
- Git のコミット署名鍵（`~/.ssh/id_ed25519_signing`）には、エージェントが非対話でコミットできるようパスフレーズを付けていません。そのため VM 内のエージェントもあなたの署名付きコミットを作成できます。GitHub の Verified バッジは「この VM で作成されたコミットである」ことを示し、人間が直接書いたことの証明にはなりません。不要になった VM を削除する際（または `make restore-auth` で鍵を引き継がずに作り直した際）は、GitHub の [SSH and GPG keys](https://github.com/settings/keys) から対応する古い Signing Key も削除してください（`make delete` は起動中の VM を削除する前に `ssh-keygen -lf ~/.ssh/id_ed25519_signing.pub` で鍵の指紋を表示します）。ホストの `gh` で削除する場合、`gh ssh-key delete` は認証用の鍵（`/user/keys`）しか扱わないため、`gh api` で Signing Key の指紋・ID・タイトルを一覧して削除します（`admin:ssh_signing_key` スコープが必要。`gh auth refresh -h github.com -s admin:ssh_signing_key` で追加できます）:
  ```sh
  gh api --paginate /user/ssh_signing_keys --jq '.[] | "\(.key) id=\(.id) \(.title)"' | ssh-keygen -lf -
  gh api -X DELETE /user/ssh_signing_keys/<ID>
  ```

## 開発

### 静的検査とローカル回帰テスト

`scripts/lint.sh` で、テンプレートの検証（`limactl validate`）と、スクリプト（`provision/*.sh`、`scripts/*.sh`）およびテンプレートに書いた probes の shellcheck を実行します（shellcheck は `brew install shellcheck` でインストールする）。

```sh
make lint    # または ./scripts/lint.sh
```

`scripts/test.sh` で、外部ネットワークやホスト環境に依存しないスタブ中心の高速な回帰テストを実行します。各プロビジョニングスクリプトの冪等性・既存設定保持・途中失敗からの回復や、Makefile の入力値正規化・優先順位・ホストマウント検出を検証します。

```sh
make test    # または bash ./scripts/test.sh
```

### CI（GitHub Actions）

GitHub Actions（`.github/workflows/ci.yml`）では、以下の 2 段階で自動検証を行います。

1. **`lint` ジョブ**: main ブランチへの push とすべての pull request で、`minimumLimaVersion` と最新リリースの 2 つの Lima バージョンで `scripts/lint.sh` および `scripts/test.sh` を実行します。
2. **`provision-vm` ジョブ**: `ubuntu-latest`（KVM ハードウェアアクセラレーションが有効な `x86_64` Linux ランナー）上で実際に Lima VM（QEMU）を作成・初回起動し、主要 CLI や Git 署名・ファイアウォール・エージェント指示ファイルの配置と全 probes を検証します。さらに VM の停止・再起動（`limactl stop` → `limactl start`）を行い、署名鍵の不変性や設定重複がないことを確認します（GitHub Actions の ARM ランナーでは `/dev/kvm` が利用できないため、CI の実 VM 検証は `x86_64` 環境が対象となり、Apple silicon 向けの `aarch64` 固有バイナリ差は対象外です）。
   - アクション分数節約のため、週 1 回の定期実行（schedule: 毎週火曜 9:23 JST）、手動実行（`workflow_dispatch`）、または `coding-sandbox.yaml`・`provision/`・`scripts/`・`ci.yml` に変更を含む push / pull request で実行されます。

push しない間に Lima の新しいリリースでテンプレートの検証が通らなくなったり、外部 URL の変更でプロビジョニングが壊れたりしても気づけるように、毎週火曜の 9:23（日本時間）にも同じ CI を定期実行します。失敗したときは、GitHub の通知（Settings → Notifications → Actions）で知らせが届きます。

`ci.yml` で使うアクションは、コミットの SHA で固定しています。Dependabot（`.github/dependabot.yml`）が毎週火曜に新しい版を確認し、公開から 7 日たった新しい版があれば、SHA と末尾のバージョンのコメントを更新する pull request を作ります。

probes は `file:` で別のファイルに分けず、`coding-sandbox.yaml` に直接書いています。Lima 2.2.0 では、probes の `file:` がインスタンスの作成時に取り込まれないためです（provision の `file:` は取り込まれます）。
