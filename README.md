# lima-coding-sandbox

[Lima](https://lima-vm.io/) でコーディングエージェント用のサンドボックス VM を作るための設定ファイル一式です。
ホストのファイルにエージェントが直接触れないよう、VM の中で通常ユーザとしてエージェントを動かします。

- [初回のセットアップ（認証）と鍵・認証情報の管理](docs/authentication.md)
- [セキュリティと隔離設計](docs/security.md)
- [トラブルシューティング](docs/troubleshooting.md)

## 構成

| 項目 | 内容 |
|---|---|
| OS | Ubuntu 26.04 LTS（Lima 同梱の `template:_images/ubuntu-26.04`） |
| ホストのディレクトリ | マウントしない（`mounts: []`）。Lima のグローバル設定から混入した場合は、起動時に検出してエラーにする（[後述](#ホストのマウントが混入しないように) / [詳細](docs/security.md#ホストのマウントが混入しないように)） |
| ユーザ | ホストと同じ名前・UID の通常ユーザ（非 root）。ホームは `/home/<user>.guest`。パスワードなしで sudo できる（Lima の既定） |
| リソース | 4 CPU / 8 GiB メモリ / 100 GiB ディスク（ディスクはスパースファイルなので、実際に使った分だけ消費する） |
| ネットワーク | ゲストのポートをホストに自動で転送しない。VM から `host.lima.internal`（ホストの `127.0.0.1`）への接続を遮断する（[後述](#ネットワーク) / [詳細](docs/security.md#ネットワーク)） |
| 音声 | VM の中で再生した音を、ホストのスピーカーから鳴らす（再生のみ。マイクは使えない。[後述](#音声)） |

基本的なツールは Ubuntu のリポジトリから、それ以外の各ソフトウェアは公式ドキュメントの手順でインストールします。

| ソフトウェア | 公式手順 | スクリプト | インストール先 |
|---|---|---|---|
| 基本的なツール | Ubuntu のリポジトリ（apt） | `provision/apt-packages.sh`（root） | apt パッケージ（[後述](#基本的なツール)） |
| GitHub CLI | [Installing gh on Linux and BSD](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian)（apt リポジトリ） | `provision/github-cli.sh`（リポジトリ登録）、`provision/apt-packages.sh`（root） | apt パッケージ |
| Docker Engine | [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)（apt リポジトリ） | `provision/docker-engine.sh`（リポジトリ登録・ラッパー）、`provision/apt-packages.sh`（root） | apt パッケージ、`/usr/local/bin/docker`（ラッパー。[後述](#docker)） |
| ファイアウォール（nftables） | Ubuntu のリポジトリ（apt） | `provision/apt-packages.sh`（インストール）、`provision/host-loopback-firewall.sh`（ルール・サービス登録）（root） | apt パッケージ、`/etc/lima-coding-sandbox/host-loopback-firewall.nft`、`/etc/systemd/system/lima-coding-sandbox-firewall.service` |
| ターミナル（terminfo）の代替設定 | - | `provision/terminfo-fallback.sh`（root） | `/etc/profile.d/terminfo-fallback.sh`（[後述](#シェルに入る)） |
| 音声（alsa-utils, mpg123） | Ubuntu のリポジトリ（apt） | `provision/apt-packages.sh`（インストール）、`provision/audio.sh`（udev ルール設定）（root） | apt パッケージ、`/etc/udev/rules.d/70-lima-coding-sandbox-sound.rules` |
| Git 設定・コミット署名 | - | `provision/git-config.sh` | `~/.ssh/id_ed25519_signing`、`~/.gitconfig`（[後述](#git-のコミット署名)） |
| herdr | [Install](https://herdr.dev/docs/install/) | `provision/herdr.sh` | `~/.local/bin/herdr`（[後述](#herdr)） |
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
| nftables | `nft` |
| python3-venv、python3-pip、pipx | `python3 -m venv`、`pip3`、`pipx` |
| nodejs、npm | `node`、`npm`、`npx` |

1 行目のパッケージはイメージに最初から入っていますが、イメージが変わっても確実に入るように明記しています（新しい版があれば、初回の起動時に更新されます）。

- Ubuntu の仕様上、`fd-find` パッケージのコマンド名は `fdfind` ですが、コーディングエージェントやツールの互換性のため `/usr/local/bin/fd` にシンボリックリンクを作成しています（`fd` と `fdfind` のどちらでも実行できます）
- `pip3 install` で Python のパッケージをシステムに入れることはできません（`externally-managed-environment` のエラーになります）。`python3 -m venv` で作った仮想環境の中で使うか、コマンドとして使うツールは `pipx install` で入れてください（`~/.local/bin` に入ります）
- Node.js と npm は Ubuntu のリポジトリの版（Node.js 22 / npm 9）です。`npm install -g` は `/usr/local` に入れようとするため、そのままでは権限のエラー（`EACCES`）になります。先に `npm config set prefix ~/.local` を実行しておくと、`~/.local/bin` に入るようになります（`npx` はそのまま使えます）

ツールを追加するときは、`provision/apt-packages.sh` の `base_packages`、`coding-sandbox.yaml` の probe（`basic tools (git, gh, etc.) to be installed`）のコマンド一覧、および上の表に追加して（`make lint` で整合性を確認できます）、インスタンスを作り直してください（`make recreate`）。今の VM にだけ入れるなら、VM 内で `sudo apt-get install <パッケージ>` を実行します。
パッケージを削除するときは、`coding-sandbox.yaml` の probe のコマンド一覧および上の表からも削除してください（probe に残っていると、起動時の確認が終わらずにタイムアウトします）。

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
├── docs/                      # 詳細ドキュメント
│   ├── authentication.md      # 初回のセットアップ（認証）・Git 署名鍵・退避と復元の詳細
│   ├── security.md            # セキュリティ上の注意・マウント混入防止・ネットワーク隔離の詳細
│   ├── troubleshooting.md     # トラブルシューティング・プロビジョニング検証仕様の詳細
│   └── issue-prioritization.md # Issue 評価基準・優先順位ロードマップ
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
│   ├── lib.sh                 # 共通関数（状態取得・起動確認、入力値正規化、退避先・退避データ検証、鍵指紋抽出）
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
│   ├── lint.sh                # テンプレート・スクリプト・ドキュメント整合性の検査（CI でも実行する）
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
| `make help` | ターゲットの一覧を表示する |
| `make create` | インスタンスが無ければ作成する（作成前にはホストマウントの混入を自動検査する） |
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
| `make lint` | `scripts/lint.sh` を実行する（[後述](#開発)） |
| `make test` | `scripts/test.sh` を実行する（[後述](#開発)） |

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
- 値が反映されるのは**インスタンスを作成するときだけ**です。作成後に `.env` を変えても今の VM には反映されません。`make recreate` で作り直してください
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
起動時に `coding-sandbox.yaml` の `probes` で、ホストのディレクトリがマウントされていないこと、各ツールや Docker Engine・音声・ファイアウォール・Git のコミット署名などが正常に動作することを確認し、すべて満たされた時点で完了します（起動時に `Waiting for the optional requirement ...` から進まない場合は [トラブルシューティング](docs/troubleshooting.md) を参照してください）。

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
> - **エディタ側の自動ポート転送**: 本サンドボックスでは Lima による自動ポート転送を無効化していますが、VS Code / Cursor の Remote - SSH には、接続中に VM 内で待ち受けられたポートを検知してホストへ自動転送する独自機能（`remote.autoForwardPorts`、既定で有効）があります。意図しないポート転送を防ぎたい場合は、設定で `"remote.autoForwardPorts": false` を指定し、必要なポートのみエディタの Ports ビューまたは `make forward PORT=<ポート>` で手動転送してください（[ネットワーク](docs/security.md#ネットワーク)を参照）。
> - **エディタ側の GitHub / Git 認証情報の引き継ぎ**: VS Code / Cursor は既定で、ホスト側のエディタにサインインしている GitHub セッションの認証情報をリモート環境内の Git 操作や統合ターミナルへ引き継ぎます（`github.gitAuthentication` および `git.terminalAuthentication`、いずれも既定で有効）。VM 内のユーザはパスワードなしで `sudo` できるため、接続中はリモート拡張ホスト経由でこれらの認証情報に VM 内のエージェントからもアクセスしうると考える必要があります。Git 操作・統合ターミナルへの引き継ぎを止めたい場合や、VM 内の権限を `GH_TOKEN` 等で絞っている場合は、設定で `"github.gitAuthentication": false` と `"git.terminalAuthentication": false` を指定してください。なお、これら 2 つの設定は Git / ターミナル向けの認証引き継ぎを止めるものであり、VM 側（リモート拡張ホスト）で動作し GitHub セッションを使用する拡張機能（GitHub Copilot Chat や GitHub Pull Requests など）を有効にしている場合は、その拡張機能経由でもリモート側でトークンが扱われる点に注意してください（[セキュリティ上の注意](docs/security.md#セキュリティ上の注意)を参照）。
> - **SSH エージェントの転送**: Remote - SSH はホストの `~/.ssh/config` を参照するため、`Host *` などで `ForwardAgent yes` を設定しているとホストの SSH エージェントが VM に転送されることがあります。その場合は `lima-*` を対象から外してください（[セキュリティ上の注意](docs/security.md#セキュリティ上の注意)を参照）。

### 停止・削除

```sh
limactl stop coding-sandbox
limactl delete coding-sandbox
```

### インスタンスを作り直す（認証情報と作業データの退避・復元）

`coding-sandbox.yaml` や `provision/*.sh`、`.env` の変更を反映するために `make recreate`（または `limactl delete` → `limactl start`）を実行すると、VM 内のすべてのファイル・認証情報・Git 署名鍵が消去されます。

- **作業データの確認**: 未 push のコミット、未コミット・未追跡のファイル（`.env` など）、および Git 管理外の作業データは、新しく作った VM で `git clone` し直すだけでは復元できません。削除前に `git push` するか `limactl copy -r` でホストへ退避してください。
- **認証情報と署名鍵の退避・復元**: `make backup-auth` と `make restore-auth` を使うと、GitHub への Signing Key の再登録や CLI（`gh`・`copilot`）のブラウザ認証をやり直さずに作り直せます。

```sh
make backup-auth recreate restore-auth
```

退避対象ファイルや保存先（`AUTH_BACKUP_DIR`）の仕様・制限、不要になった退避データの削除手順などの詳細は、[docs/authentication.md の「インスタンスを作り直す（認証情報と作業データの退避・復元）」](docs/authentication.md#インスタンスを作り直す認証情報と作業データの退避復元)を参照してください。

## ホストのマウントが混入しないように

このテンプレートではホストのディレクトリをマウントしません（`mounts: []`）。ただし Lima のグローバル設定（`~/.lima/_config/default.yaml`・`override.yaml`・`base.yaml`）にマウント定義があると結合されるため、`make create` / `make start` による起動前の自動検査と、VM 起動時の probe（`no host directories to be mounted`）の二重の仕組みで検出・拒否しています。

マウントエラーが表示された場合の確認コマンドや修復手順の詳細は、[docs/security.md の「ホストのマウントが混入しないように」](docs/security.md#ホストのマウントが混入しないように)を参照してください。

## プロジェクトを VM に持ち込む

ホストのファイルはマウントされないため、次のいずれかの方法を使います。

1. **VM 内で `git clone` する（推奨）**
   Git の認証情報は VM 内で別途用意します。GitHub なら、`gh auth login` でログインすると、HTTPS での `git clone` / `git push` にも gh の認証情報が使われます（[docs/authentication.md](docs/authentication.md#github-cli) を参照）。ほかに、HTTPS + Personal Access Token や、VM 内で作った SSH 鍵なども使えます。
2. **`limactl shell --sync` を使う**
   ホストのカレントディレクトリをゲストにコピーし、シェルを終了するときに、変更をホストへ書き戻すかどうかを確認されます（差分を見てから選べます）。
   ```sh
   cd ~/src/my-project
   limactl shell --sync . coding-sandbox
   ```
   - ホストとゲストの両方に rsync が必要です（ゲストのイメージには同梱されています。ホストは macOS 標準の rsync（openrsync）で動作を確認しました）
   - ホスト側のディレクトリは 4 階層以上の深さが必要です（例: `/Users/<user>/src/my-project`）
   - インスタンスにホストのマウントがあると、Lima は `--sync` を拒否します。エラーメッセージでは `--mount-none` を付けて起動するよう案内されますが、`default.yaml` / `override.yaml` 由来のマウントはそれでは消えません（[ホストのマウントが混入しないように](docs/security.md#ホストのマウントが混入しないように)を参照）
   - ゲスト側では `~/<ホストの絶対パス>`（例: `/home/<user>.guest/Users/<user>/src/my-project`）に展開されます
   - ⚠️ `--tty=false`（`-y`）を付けたときやパイプ経由で実行したときは、**確認なしで**ホストに書き戻されます。`rsync --delete` で同期するため、ゲストで削除したファイルはホストからも削除されます
3. **`limactl copy` でコピーする**
   ```sh
   limactl copy -r ./my-project coding-sandbox:~/
   ```

## 初回のセットアップ（認証）

各 CLI の初回ログイン手順や、ヘッドレス環境での注意点（Antigravity CLI の Gemini API キー設定など）の詳細は **[docs/authentication.md](docs/authentication.md)** を参照してください。

- **GitHub CLI**: VM 内で `gh auth login`（`GitHub.com` → `HTTPS` → `Login with a web browser`）を実行
- **GitHub Copilot CLI**: VM 内で `copilot` を起動して `/login` を実行（または環境変数で PAT を指定）
- **Antigravity CLI**: VM 内で `agy` を起動してブラウザ認可（または `GEMINI_API_KEY` を設定）

### Git のコミット署名

VM 内の Git はすべてのコミットとタグを SSH 鍵（`~/.ssh/id_ed25519_signing`）で自動署名します。GitHub 上で **Verified** と表示させるには、ホストから `make register-key`（ホストの `gh` を使用）を実行するか、`make pubkey` で表示した公開鍵を GitHub の [SSH and GPG keys](https://github.com/settings/keys) に **Signing Key** として登録してください。

詳しい登録・削除手順やローカル検証方法、`--param` 未指定で作成した場合の手動設定手順は、[docs/authentication.md の「Git のコミット署名」](docs/authentication.md#git-のコミット署名)を参照してください。

## herdr

```sh
herdr
```

herdr のセッションが起動します（既にあれば接続します）。プレフィックスキーは `ctrl+b` で、`prefix+q` でデタッチ、もう一度 `herdr` を実行すると再接続します。
ホストからは `make herdr`（または `limactl shell coding-sandbox herdr`）で直接入れます。デタッチするとホストのシェルに戻ります。
ペインの中で `copilot` や `agy` を起動すると、herdr が自動でエージェントとして検出します。

### ホストの herdr からリモート接続する

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

### 通知音

herdr は、エージェントが入力を求めてきたとき（承認や質問）と、作業が終わったときに通知音を鳴らします。鳴る条件は種類によって違います。

- 入力を求める音: 常に鳴ります（今表示しているタブのエージェントでも鳴ります）
- 作業が終わった音: 今表示しているタブのエージェントでは鳴りません。同じワークスペースでも、別のタブのエージェントなら鳴ります。また、ターミナルのウィンドウからフォーカスが外れているときは、表示中のタブでも鳴ります（ターミナルがフォーカスの変化を herdr に伝えている場合）

VM の中で起動した場合は VM の herdr が `mpg123` で鳴らし（[音声](#音声)の仕組みで、ホストのスピーカーから出ます）、ホストからリモート接続した場合はホストの herdr が鳴らします。

### インテグレーション

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

- **ポート転送**: ゲストのポートはホストへ自動転送されません（`portForwards` で全面無効化）。VM 内の Web サーバ等にホストからアクセスするときは、必要なポートのみ手動で転送します:
  ```sh
  make forward PORT=3000                    # ホストの 127.0.0.1:3000 に転送（Ctrl-C で停止）
  make forward PORT=3000 HOST_PORT=13000    # ホスト側ポートを変える場合
  ```
- **ホストループバック（`host.lima.internal`）への接続遮断**: VM（Docker コンテナを含む）からホストの `127.0.0.1` につながる `host.lima.internal`（`192.168.5.2`）への通信は、VM 内の nftables で既定で遮断しています（DNS は維持）。ホスト側のローカルプロキシを経由する必要がある場合などは、`.env` またはコマンドラインで `BLOCK_HOST_LOOPBACK=false` を指定して無効化できます。

nftables ルールの仕組みや、インスタンス作成後に遮断設定を切り替える方法などの詳細は、[docs/security.md の「ネットワーク」](docs/security.md#ネットワーク)を参照してください。

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
- VM のカーネルには virtio-sound のドライバが含まれていて、自動で読み込まれます。`provision/apt-packages.sh` で alsa-utils（`aplay`、`speaker-test`）と `mpg123` をインストールし、`provision/audio.sh` で通常ユーザもサウンドデバイスを使えるようにしています
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

`limactl start` が `Waiting for the optional requirement ...` から進まない場合は、`make logs`（`/var/log/cloud-init-output.log`）でプロビジョニングのログを確認してください。一時的な通信障害で失敗した場合は `make restart` で再試行でき、回線が遅い場合は `make start TIMEOUT=30m` でタイムアウトを延長できます。

エラーメッセージ別の切り分けや、外部ダウンロードのタイムアウト・リトライ・チェックサム検証仕様の詳細は、**[docs/troubleshooting.md](docs/troubleshooting.md)** を参照してください。

## セキュリティ上の注意

- 隔離の境界は VM です。VM 内のユーザはパスワードなしで `sudo` できるため、エージェントも VM 内では root 相当の操作（nftables ルールの解除や、VM 内に保存されたトークン・署名鍵の利用を含む）が可能です。
- ホストディレクトリのマウント・SSH エージェント転送・自動ポート転送は無効化しています。ただしホストの `~/.ssh/config`（`ForwardAgent yes`）や、VS Code / Cursor の Remote - SSH の既定機能（自動ポート転送・GitHub 認証引き継ぎ）には注意が必要です。
- 不要になった VM を削除する際は、`make backup-auth` でホストに退避した認証データや、GitHub に登録した古い Signing Key も削除してください。

各リスクの詳しい説明や権限の絞り方（Fine-grained PAT の利用、古い Signing Key の削除コマンドなど）は、**[docs/security.md](docs/security.md)** を参照してください。

## 開発

### 静的検査とローカル回帰テスト

`scripts/lint.sh` で、テンプレートの検証（`limactl validate`）、スクリプト（`provision/*.sh`、`scripts/*.sh`）およびテンプレートに書いた probes の `shellcheck`、ならびにドキュメントと設定の整合性検査を実行します（shellcheck は `brew install shellcheck` でインストールする）。

```sh
make lint    # または ./scripts/lint.sh
```

`scripts/test.sh` で、外部ネットワークやホスト環境に依存しないスタブ中心の高速な回帰テストを実行します。各プロビジョニングスクリプトの冪等性・既存設定保持・途中失敗からの回復や、Makefile の入力値正規化・優先順位・ホストマウント検出・`lint.sh` の整合性検査を検証します。

```sh
make test    # または bash ./scripts/test.sh
```

### CI（GitHub Actions）

GitHub Actions（`.github/workflows/ci.yml`）では、以下の 2 段階で自動検証を行います。

1. **`lint` ジョブ**: main ブランチへの push・すべての pull request・定期実行（`schedule`）・手動実行（`workflow_dispatch`）で、`minimumLimaVersion` と最新リリースの 2 つの Lima バージョンで `scripts/lint.sh` および `scripts/test.sh` を実行します。
2. **`provision-vm` ジョブ**: `ubuntu-latest`（KVM ハードウェアアクセラレーションが有効な `x86_64` Linux ランナー）上で実際に Lima VM（QEMU）を作成・初回起動し、主要 CLI や Git 署名・ファイアウォール・エージェント指示ファイルの配置と全 probes を検証します。さらに VM の停止・再起動（`limactl stop` → `limactl start`）を行い、署名鍵の不変性や設定重複がないことを確認します（GitHub Actions の ARM ランナーでは `/dev/kvm` が利用できないため、CI の実 VM 検証は `x86_64` 環境が対象となり、Apple silicon 向けの `aarch64` 固有バイナリ差は対象外です）。アクション分数節約のため、定期実行（`schedule`）・手動実行（`workflow_dispatch`）、または `coding-sandbox.yaml`・`provision/`・`scripts/`・`ci.yml` に変更を含む push / pull request で実行されます。

push しない間に Lima の新しいリリースでテンプレートの検証が通らなくなったり、外部 URL の変更でプロビジョニングが壊れたりしても気づけるように、毎週火曜の 9:23（日本時間）にも同じ CI を定期実行します。失敗したときは、GitHub の通知（Settings → Notifications → Actions）で知らせが届きます。

`ci.yml` で使うアクションは、コミットの SHA で固定しています。Dependabot（`.github/dependabot.yml`）が毎週火曜に新しい版を確認し、公開から 7 日たった新しい版があれば、SHA と末尾のバージョンのコメントを更新する pull request を作ります。

probes は `file:` で別のファイルに分けず、`coding-sandbox.yaml` に直接書いています。Lima 2.2.0 では、probes の `file:` がインスタンスの作成時に取り込まれないためです（provision の `file:` は取り込まれます）。
