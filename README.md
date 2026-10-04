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
| ソフトウェア | 基本的なツール（git、gh、build-essential、ripgrep、Python の venv・pipx、Node.js など。[後述](#基本的なツール)）、herdr、Antigravity CLI（`agy`）、GitHub Copilot CLI（`copilot`）、Docker Engine（`sudo docker` で使う）、Git のユーザ設定・コミット署名鍵、ターミナル（`$TERM`）の terminfo の代替設定 |

基本的なツールは Ubuntu のリポジトリから、それ以外の各ソフトウェアは公式ドキュメントの手順でインストールします。

| ソフトウェア | 公式手順 | スクリプト | インストール先 |
|---|---|---|---|
| 基本的なツール | Ubuntu のリポジトリ（apt） | `provision/base-packages.sh`（root） | apt パッケージ |
| GitHub CLI | [Installing gh on Linux and BSD](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#debian)（apt リポジトリ） | `provision/github-cli.sh`（root） | apt パッケージ |
| Docker Engine | [Install Docker Engine on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)（apt リポジトリ） | `provision/docker-engine.sh`（root） | apt パッケージ |
| Git 設定・コミット署名 | - | `provision/git-config.sh` | `~/.ssh/id_ed25519_signing`、`~/.gitconfig` |
| herdr | [Install](https://herdr.dev/docs/install/) | `provision/herdr.sh` | `~/.local/bin/herdr` |
| Antigravity CLI | [Installation and auth](https://antigravity.google/docs/cli/install) | `provision/antigravity-cli.sh` | `~/.local/bin/agy` |
| GitHub Copilot CLI | [Installing GitHub Copilot CLI](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/install-copilot-cli)（install スクリプト） | `provision/copilot-cli.sh` | `~/.local/bin/copilot` |

> [!NOTE]
> Antigravity CLI だけは、公式のコマンドに `curl --compressed` を追加しています。
> `antigravity.google` が、クライアントが要求していないのに gzip 圧縮した本文を返すことがあり、そのままだとインストールに失敗するためです（詳しくは `provision/antigravity-cli.sh` のコメントを参照）。

> [!NOTE]
> GitHub CLI は、Ubuntu のリポジトリ（universe）にも `gh` パッケージがありますが、Ubuntu 26.04 の版（2.46）は廃止された GitHub の API を使っているため動かないと、GitHub CLI の公式ドキュメントに書かれています。
> そのため公式の apt リポジトリ（`cli.github.com`）を登録して、そこから入れています（`apt-cache policy gh` で確認できます）。

### 基本的なツール

`provision/base-packages.sh` で、次のパッケージを Ubuntu のリポジトリからインストールします（gh だけは `provision/github-cli.sh` で公式のリポジトリから入れます）。

| パッケージ | 主なコマンド |
|---|---|
| git、curl、wget、jq、less、openssh-client、ca-certificates | `git`、`curl`、`wget`、`jq`、`less`、`ssh` |
| gh（GitHub CLI） | `gh` |
| build-essential | `gcc`、`g++`、`make` |
| ripgrep、fd-find、unzip、zip、tree | `rg`、`fdfind`、`unzip`、`zip`、`tree` |
| shellcheck | `shellcheck` |
| python3-venv、python3-pip、pipx | `python3 -m venv`、`pip3`、`pipx` |
| nodejs、npm | `node`、`npm`、`npx` |

1 行目のパッケージはイメージに最初から入っていますが、イメージが変わっても確実に入るように明記しています（新しい版があれば、初回の起動時に更新されます）。

- fd-find のコマンド名は `fd` ではなく `fdfind` です（Ubuntu のパッケージの仕様）。`fd` で使いたいときは `ln -s "$(command -v fdfind)" ~/.local/bin/fd` を実行してください
- `pip3 install` で Python のパッケージをシステムに入れることはできません（`externally-managed-environment` のエラーになります）。`python3 -m venv` で作った仮想環境の中で使うか、コマンドとして使うツールは `pipx install` で入れてください（`~/.local/bin` に入ります）
- Node.js と npm は Ubuntu のリポジトリの版（Node.js 22 / npm 9）です。`npm install -g` は `/usr/local` に入れようとするため、そのままでは権限のエラー（`EACCES`）になります。先に `npm config set prefix ~/.local` を実行しておくと、`~/.local/bin` に入るようになります（`npx` はそのまま使えます）

ツールを追加するときは、`provision/base-packages.sh` の `base_packages` に追加して、インスタンスを作り直してください。今の VM にだけ入れるなら、VM 内で `sudo apt-get install <パッケージ>` を実行します。
パッケージを削除するときは、`coding-sandbox.yaml` の probe（`basic tools (git, gh, etc.) to be installed`）のコマンド一覧からも、そのパッケージのコマンドを削除してください（残っていると、起動時の確認が終わらずにタイムアウトします）。

### 動作確認した環境

macOS 26.7.1（Apple M2）、Lima 2.2.0、Ubuntu 26.04 LTS（カーネル 7.0）、git 2.53.0、GitHub CLI 2.102.0、Python 3.14.4、Node.js 22.22.1、Docker Engine 29.8.2、herdr 0.9.3、Antigravity CLI 1.2.16、GitHub Copilot CLI 1.0.91

## ファイル構成

```
.
├── README.md
├── Makefile                   # よく使う limactl の操作をまとめたもの（make help で一覧を表示）
├── .env.example               # Makefile が読む設定（Git のユーザ名・メールアドレス）のひな形。.env にコピーして使う
├── .gitignore                 # .env を除外する
├── coding-sandbox.yaml        # Lima テンプレート（probes もここに書いてある）
├── provision/                 # プロビジョニングスクリプト（起動のたびに実行されるため冪等に作ってある）
│   ├── base-packages.sh       # mode: system  基本的なツール（Ubuntu のリポジトリ）
│   ├── terminfo-fallback.sh   # mode: system  $TERM の terminfo が無いときの代替
│   ├── github-cli.sh          # mode: system  GitHub CLI
│   ├── docker-engine.sh       # mode: system  Docker Engine
│   ├── git-config.sh          # mode: user    Git のユーザ設定とコミット署名
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

### make で操作する

よく使う操作は `Makefile` にまとめてあります。リポジトリのディレクトリで実行してください（`make help` で一覧を表示します）。

```sh
make start    # 作成（初回のみ）と起動
make shell    # シェルに入る（停止していれば起動する）
make stop     # 停止
```

| ターゲット | 内容 |
|---|---|
| `make start` | インスタンスが無ければ作成してから起動する。作成時には、Git のユーザ名とメールアドレスを `--param` で渡す（[後述](#git-のユーザ名とメールアドレスを-env-で指定する)） |
| `make shell` | シェルに入る（停止していれば先に起動する） |
| `make stop` / `make restart` | 停止 / 再起動（再起動は、失敗したプロビジョニングのやり直しにも使える） |
| `make status` | 状態を表示する |
| `make delete` | 削除する（確認あり。`YES=1` を付けると確認を省略） |
| `make recreate` | 削除してから作り直す（`coding-sandbox.yaml` や `provision/*.sh` の変更を反映するとき） |
| `make pubkey` | Git のコミット署名用の公開鍵を表示する |
| `make logs` | プロビジョニングのログ（cloud-init）の末尾を表示する |
| `make lint` | `scripts/lint.sh` を実行する |

変数をコマンドラインで指定すると、インスタンス名・リソース（作成時のみ有効）・タイムアウト・Git の設定を変えられます。

```sh
make start NAME=sandbox2 CPUS=8 MEMORY=16 DISK=200 TIMEOUT=30m
make start GIT_USER_NAME="<名前>" GIT_USER_EMAIL="<メールアドレス>"
```

`--param` は `limactl create` で渡しているため、名前にカンマが含まれていても問題ありません。

#### Git のユーザ名とメールアドレスを .env で指定する

`.env.example` をコピーして `.env` を作り、値を書きます（`.env` は `.gitignore` で除外しています）。

```sh
cp .env.example .env
```

```sh
# .env
GIT_USER_NAME=Taro Yamada
GIT_USER_EMAIL=taro@example.com
```

- `.env` を読むのは Makefile だけです。VM には `limactl create --param` で値だけを渡し、`.env` 自体はコピーしません
- 値は次の順で決まります: コマンドライン（`make start GIT_USER_NAME=...`） ＞ `.env` ＞ ホストの `git config --global`。`.env` が無いときや値が空のときは、ホストの Git の設定を使います
- make の書式で読み込むため、値に空白やカンマがあってもクォートは要りません（両端を `"` か `'` で囲んだときは、その 1 組を取り除きます）。`#` から行末はコメントになります
- 別のファイルを使うには `ENV_FILE` を指定します（例: `make start ENV_FILE=work.env`。指定したファイルが無いとエラーになります）。`*.env` も `.gitignore` で除外しています
- 値が反映されるのは**インスタンスを作成するときだけ**です。作成後に `.env` を変えても今の VM には反映されません。`make recreate` で作り直すか、VM 内で `git config --global user.name ...` を実行してください（`provision/git-config.sh` は、VM 内で変えた設定を戻さないよう、設定済みの値を上書きしません）
- Makefile の変数（`NAME`、`CPUS` など）も `.env` に書けます（コマンドラインで指定した値が優先されます）

以下では、`make` を使わずに `limactl` で直接操作する方法を説明します。

### 作成・起動

```sh
limactl start ./coding-sandbox.yaml
```

Git のユーザ名とメールアドレスをあらかじめ設定するには、作成時に `--param` で渡します（ホストの Git 設定をそのまま渡すこともできます）:

```sh
limactl start \
  --param "gitUserName=$(git config --global user.name)" \
  --param "gitUserEmail=$(git config --global user.email)" \
  ./coding-sandbox.yaml
```

> [!NOTE]
> `limactl start --param` はカンマで値を区切るため、名前にカンマが含まれる場合は `limactl create --param "gitUserName=..." --param "gitUserEmail=..." ./coding-sandbox.yaml` で作成してから `limactl start coding-sandbox` で起動してください。

インスタンス名は `coding-sandbox` です（変えるときは `--name=<名前>` を付ける）。
初回はイメージのダウンロードとプロビジョニングがあるため数分かかります。
起動時に `probes` で次の 5 点を確認し、すべて満たされた時点で完了します。

1. ホストのディレクトリがマウントされていないこと
2. 基本的なツール（git、gh など）がインストールされていること
3. herdr / Antigravity CLI / GitHub Copilot CLI がインストールされていること
4. Docker Engine が動いていること
5. Git のコミット署名用 SSH 鍵が作成されていること

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

Ghostty 固有の機能まで使いたいときは、ホストの terminfo を VM にコピーしてください（`~/.terminfo` に保存され、以後は置き換えなくなります。VM を作り直したときは再実行してください）:

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
| 基本的なツール・GitHub CLI・Docker Engine（apt パッケージ） | `sudo apt-get update && sudo apt-get upgrade` |

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
- 各 CLI の認証情報は VM 内に保存されます（Copilot CLI と gh は平文で保存される場合があります）。不要になったら `limactl delete` で VM ごと削除してください
- gh でログインすると、そのトークン（既定のスコープは `repo`・`read:org`・`gist`）は、VM 内で同じユーザとして動くエージェントからも使えます。エージェントは、あなたの GitHub アカウントでアクセスできるリポジトリに push したり、issue や PR を作ったりできます。権限を絞りたいときは、対象のリポジトリと権限を限定した fine-grained PAT を、`gh auth login` の代わりに環境変数 `GH_TOKEN` で渡してください（`GH_TOKEN` は Copilot CLI の `/login` で保存したトークンよりも優先されるため、Copilot CLI が使うトークンも変わる点に注意してください）
- Git のコミット署名鍵（`~/.ssh/id_ed25519_signing`）には、エージェントが非対話でコミットできるようパスフレーズを付けていません。そのため VM 内のエージェントもあなたの署名付きコミットを作成できます。GitHub の Verified バッジは「この VM で作成されたコミットである」ことを示し、人間が直接書いたことの証明にはなりません。不要になった VM を削除する際は、GitHub の [SSH and GPG keys](https://github.com/settings/keys) から対応する Signing Key も削除してください

## 開発

`scripts/lint.sh` で、テンプレートの検証（`limactl validate`）と、provision スクリプトおよびテンプレートに書いた probes の shellcheck を実行します（shellcheck は `brew install shellcheck` でインストールする）。

```sh
./scripts/lint.sh
```

GitHub Actions（`.github/workflows/ci.yml`）でも、main ブランチへの push と pull request のたびに同じスクリプトを実行します。Lima は、`minimumLimaVersion` のバージョンと最新のリリースの 2 つで確認します。

probes は `file:` で別のファイルに分けず、`coding-sandbox.yaml` に直接書いています。Lima 2.2.0 では、probes の `file:` がインスタンスの作成時に取り込まれないためです（provision の `file:` は取り込まれます）。
