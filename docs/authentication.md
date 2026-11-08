# 初回のセットアップ（認証）と鍵・認証情報の管理

VM を作成・起動した後の各ツールの認証手順、Git コミット署名鍵の登録手順、および VM 再作成時の退避・復元手順を説明します。基本的な使い方は [README.md](../README.md) を参照してください。

## GitHub CLI

```sh
gh auth login
```

対話形式で聞かれるので、`GitHub.com` と `HTTPS` を選び、`Authenticate Git with your GitHub credentials?` には `Yes` と答えます（VM 内の git が、GitHub への HTTPS のアクセスに gh の認証情報を使うようになります）。
認証方法で `Login with a web browser` を選ぶと、ワンタイムコードが表示されます。Enter を押すと、VM にはブラウザが無いため開けなかったというメッセージが出ますが、そのまま待っている間に、表示された URL（`https://github.com/login/device`）をホストのブラウザで開いてコードを入力してください。
VM にはキーリング（Secret Service）が無いため、トークンはファイルに平文で保存されます（`Authentication credentials saved in plain text` と表示されます。保存先は `gh auth status` で確認できます）。

Git のユーザ名とメールアドレスは作成時に `--param`（または `.env`）で渡していれば設定済みです。未指定で作成した場合は [Git のコミット署名](#git-のコミット署名) を参照して設定してください。

## Git のコミット署名

VM 内の Git は、すべてのコミットとタグに署名するよう設定されています（`commit.gpgsign=true`、署名鍵は `~/.ssh/id_ed25519_signing`）。
鍵のコメントにはインスタンス名と作成日（`git-signing <user>@lima-<NAME> <YYYY-MM-DD>`）が入ります。
GitHub 上でコミットに **Verified** バッジを表示させるには、公開鍵を GitHub に Signing Key として登録し、設定したメールアドレス（`git config --global user.email`）が GitHub アカウントで検証済み（Verified）になっていることを確認してください。

### ホストの `gh`（GitHub CLI）で登録する（`make register-key`）

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

### ブラウザから手動で登録する（`make pubkey`）

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

## GitHub Copilot CLI

```sh
copilot
```

起動したら `/login` を実行します。SSH 経由の環境ではデバイスコードフローになるので、表示された URL をホストのブラウザで開き、コードを入力してください。
VM にはキーリング（libsecret）が入っていないため、トークンを `~/.copilot/config.json` に平文で保存するかどうか確認されます。
Fine-grained PAT を環境変数（`COPILOT_GITHUB_TOKEN` など）で渡す方法もあります（[認証のドキュメント](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli)）。
ほかに認証情報（環境変数や `/login` で保存したトークン）が無いときは、Copilot CLI は gh のトークンを自動で使います（優先度は最も低い）。

## Antigravity CLI

```sh
agy
```

SSH 経由だと判定されると、認可用の URL が表示されます。ホストのブラウザで開いてサインインし、表示されたコードを CLI に貼り付けてください。

> [!NOTE]
> Linux 版の Antigravity CLI は、ログイン情報の保存に Secret Service（GNOME Keyring など）と D-Bus セッションを使います（[Troubleshooting](https://antigravity.google/docs/cli/troubleshooting)）。
> この VM には Secret Service を提供するキーリングは入れていませんが、一度ログインすれば CLI の終了・再起動や VM の停止・再起動（`make stop` → `make shell`）の後もログイン状態が維持されることを確認しています。
> もしキーリングに関するエラーが出たり毎回ログインを求められたりする場合は、次の Gemini API キー方式を使ってください。

キーリングを使わない方法として、Gemini API キーでも認証できます（[Installation and auth](https://antigravity.google/docs/cli/install)）。

```sh
mkdir -p ~/.gemini/antigravity-cli
echo '{"modelProvider": "gemini"}' > ~/.gemini/antigravity-cli/settings.json
export GEMINI_API_KEY="<API キー>"   # 毎回設定するなら ~/.bashrc に追記する
agy
```

## インスタンスを作り直す（認証情報と作業データの退避・復元）

`coding-sandbox.yaml` や `provision/*.sh`、`.env` の変更を反映するために `make recreate`（または `limactl delete` → `limactl start`）を実行すると、VM 内のすべてのファイル・認証情報・Git 署名鍵が消去されます。

### 1. 削除前の作業データの確認と退避

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

### 2. 認証情報と Git コミット署名鍵の退避・復元（`make backup-auth` / `make restore-auth`）

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
- **署名鍵を復元しない場合**: `make backup-auth` / `make restore-auth` を使わずに VM を作り直した場合は、新しい署名鍵が生成されます。[Git のコミット署名](#git-のコミット署名) の手順（`make register-key` など）で新しい公開鍵を登録し、GitHub の [SSH and GPG keys](https://github.com/settings/keys)（またはホストの `gh api`）から古い VM の Signing Key を削除してください（[セキュリティ上の注意](security.md#セキュリティ上の注意)を参照）。
