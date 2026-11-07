# コーディングエージェント用サンドボックス VM の操作をまとめたもの（詳細は README.md を参照）
#
#   $ make start    # 作成（初回のみ）と起動
#   $ make shell    # シェルに入る（停止していれば起動する）
#   $ make herdr    # herdr のセッションに入る（停止していれば起動する）
#   $ make herdr-remote  # ホストの herdr から VM のセッションにリモート接続する
#   $ make ssh-config    # SSH 接続設定（VS Code / Cursor Remote - SSH 用）を表示する
#   $ make forward PORT=3000  # VM のポートをホストの 127.0.0.1 に転送する
#   $ make terminfo # ホストの terminfo を VM にコピーする
#   $ make help     # ターゲットの一覧
#
# 変数はコマンドラインで上書きできる:
#   $ make start NAME=sandbox2 CPUS=8 MEMORY=16 DISK=200 TIMEOUT=30m
#
# 作成時の設定（Git のユーザ名・メールアドレス、ホストループバック遮断の有無、エージェント指示配置の有無、CLI バージョン）は .env に書ける（.env.example を参照）

# インスタンス名
NAME := coding-sandbox
TEMPLATE := coding-sandbox.yaml

# 作成時だけ使う。空ならテンプレートの既定値（4 CPU / 8 GiB / 100 GiB）になる。MEMORY と DISK の単位は GiB
CPUS :=
MEMORY :=
DISK :=
# limactl start のタイムアウト（例: 30m）。空なら Lima の既定値（10 分）
TIMEOUT :=

# make forward で転送するポート（PORT は必須、HOST_PORT を省略したときは PORT と同じ）
PORT :=
HOST_PORT :=

# make terminfo で VM にコピーする terminfo の名前。既定はホストの $TERM（例: xterm-ghostty）
TERM_NAME := $(TERM)

# make backup-auth / make restore-auth で認証情報・署名鍵を退避するホスト側のディレクトリ。
# 空なら既定値（~/.local/share/lima-coding-sandbox/auth-backup/$(NAME)）を使う
AUTH_BACKUP_DIR :=

# 設定ファイル（make の書式で KEY=値 を書く。.env.example を参照）。
# 既定の .env が無ければ読まない。コマンドラインで指定したファイルが無ければエラーにする
ENV_FILE := .env
ifneq ($(wildcard $(ENV_FILE)),)
include $(ENV_FILE)
else ifeq ($(origin ENV_FILE),command line)
$(error $(ENV_FILE) が見つかりません)
endif

# scripts/*.sh に渡す設定値。
# 優先順位: コマンドライン > $(ENV_FILE) > 既定値（Git の設定が空のときは scripts/create.sh でホストの git config --global から補う）
export NAME TEMPLATE CPUS MEMORY DISK TIMEOUT PORT HOST_PORT TERM_NAME AUTH_BACKUP_DIR YES
export GIT_USER_NAME GIT_USER_EMAIL BLOCK_HOST_LOOPBACK AGENT_INSTRUCTIONS COPILOT_VERSION MISE_VERSION

.NOTPARALLEL:
.DEFAULT_GOAL := help
.PHONY: help create start shell herdr herdr-remote ssh-config forward _check-terminfo terminfo backup-auth _check-restore-auth restore-auth update versions stop restart status delete recreate pubkey _check-register-key register-key logs lint test

help: ## ターゲットの一覧を表示する
	@grep -E '^[a-z-]+:.*## ' $(firstword $(MAKEFILE_LIST)) | awk -F ':.*## ' '{ printf "  make %-12s %s\n", $$1, $$2 }'

create: ## インスタンスを作成する（作成済みなら何もしない）
	@./scripts/create.sh

start: create ## インスタンスを起動する（無ければ作成する）
	@./scripts/start.sh

shell: start ## シェルに入る（停止していれば起動する）
	@./scripts/shell.sh

# limactl shell はコマンドを指定してもログインシェルで実行するため、~/.local/bin の herdr が見つかる
herdr: start ## herdr のセッションに入る（無ければ作る。停止していれば起動する）
	@./scripts/shell.sh herdr

herdr-remote: start ## ホストの herdr から VM のセッションにリモート接続する（停止していれば起動する）
	@./scripts/herdr-remote.sh

ssh-config: ## SSH 接続設定（~/.ssh/config 用の Include と ssh.config の内容）を表示する（起動中のみ）
	@./scripts/ssh-config.sh

forward: start ## VM のポートをホストの 127.0.0.1 に転送する（PORT=<VM のポート> が必須。HOST_PORT で変えられる。Ctrl-C で終了）
	@./scripts/forward.sh

# terminfo の前提条件。起動処理に入る前にホストに terminfo があるかを検証する
_check-terminfo:
	@./scripts/terminfo.sh --check

terminfo: _check-terminfo start ## ホストの terminfo を VM にコピーする（既定は $TERM。TERM_NAME=<名前> で変えられる。停止していれば起動する）
	@./scripts/terminfo.sh

backup-auth: ## 認証情報（gh・copilot）と Git 署名鍵をホストに退避する（AUTH_BACKUP_DIR で退避先を変更可）
	@./scripts/backup-auth.sh

# restore-auth の前提条件。起動処理に入る前にホストに退避データがあるかを検証する
_check-restore-auth:
	@./scripts/restore-auth.sh --check

restore-auth: _check-restore-auth start ## 退避した認証情報と Git 署名鍵を VM に復元する（停止していれば起動する）
	@./scripts/restore-auth.sh

update: ## VM 内のツール（herdr・copilot・mise）と apt パッケージを一括更新する（起動中のみ）
	@./scripts/update.sh

versions: ## ホストと VM 内の主要ソフトウェアのバージョンを一覧表示する（起動中のみ）
	@./scripts/versions.sh

stop: ## インスタンスを停止する
	@./scripts/stop.sh

restart: stop start ## インスタンスを再起動する（失敗したプロビジョニングのやり直しにも使う）

status: ## インスタンスの状態を表示する
	@./scripts/status.sh

delete: ## インスタンスを削除する（確認あり。YES=1 で確認を省略）
	@./scripts/delete.sh

recreate: delete start ## インスタンスを作り直す（coding-sandbox.yaml や provision/*.sh の変更を反映する）

pubkey: ## Git のコミット署名用の公開鍵を表示する（ブラウザで手動登録するとき）
	@./scripts/shell.sh cat .ssh/id_ed25519_signing.pub

# register-key の前提条件。起動処理に入る前にホストに gh があるかを検証する
_check-register-key:
	@./scripts/register-key.sh --check

register-key: _check-register-key start ## Git のコミット署名用の公開鍵をホストの gh で GitHub に登録する（停止していれば起動する）
	@./scripts/register-key.sh

logs: ## プロビジョニングのログ（cloud-init）の末尾を表示する
	@./scripts/shell.sh sudo tail -n 100 /var/log/cloud-init-output.log

lint: ## テンプレートとスクリプトを検査する
	./scripts/lint.sh

test: ## プロビジョニングスクリプトと Makefile の回帰テストを実行する
	bash ./scripts/test.sh
