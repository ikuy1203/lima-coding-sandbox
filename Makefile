# コーディングエージェント用サンドボックス VM の操作をまとめたもの（詳細は README.md を参照）
#
#   $ make start    # 作成（初回のみ）と起動
#   $ make shell    # シェルに入る（停止していれば起動する）
#   $ make herdr    # herdr のセッションに入る（停止していれば起動する）
#   $ make herdr-remote  # ホストの herdr から VM のセッションにリモート接続する
#   $ make help     # ターゲットの一覧
#
# 変数はコマンドラインで上書きできる:
#   $ make start NAME=sandbox2 CPUS=8 MEMORY=16 DISK=200 TIMEOUT=30m
#
# Git のユーザ名とメールアドレスは .env に書ける（.env.example を参照）

# インスタンス名
NAME := coding-sandbox
TEMPLATE := coding-sandbox.yaml

# 作成時だけ使う。空ならテンプレートの既定値（4 CPU / 8 GiB / 100 GiB）になる。MEMORY と DISK の単位は GiB
CPUS :=
MEMORY :=
DISK :=
# limactl start のタイムアウト（例: 30m）。空なら Lima の既定値（10 分）
TIMEOUT :=

# 設定ファイル（make の書式で KEY=値 を書く。.env.example を参照）。
# 既定の .env が無ければ読まない。コマンドラインで指定したファイルが無ければエラーにする
ENV_FILE := .env
ifneq ($(wildcard $(ENV_FILE)),)
include $(ENV_FILE)
else ifeq ($(origin ENV_FILE),command line)
$(error $(ENV_FILE) が見つかりません)
endif

# Git のユーザ名とメールアドレス（作成時に --param で渡す）。
# 優先順位: コマンドライン > $(ENV_FILE) > ホストの git config --global（最後のものは create のレシピで補う）。
# 名前に空白や記号が含まれても壊れないよう、レシピの中では環境変数（"$$GIT_USER_NAME"）として参照する
export GIT_USER_NAME GIT_USER_EMAIL

# インスタンスの状態（Running / Stopped など）を取得してシェル変数 st に格納する。
# インスタンスが無ければ空文字列、照会失敗時はエラーで終了する。
define get-status
	out=$$(limactl --log-level=error list --format '{{.Name}} {{.Status}}') || exit $$?; \
	st=$$(printf '%s\n' "$$out" | awk -v name="$(NAME)" '$$1 == name { print $$2 }')
endef

.NOTPARALLEL:
.DEFAULT_GOAL := help
.PHONY: help create start shell herdr herdr-remote stop restart status delete recreate pubkey logs lint

help: ## ターゲットの一覧を表示する
	@grep -E '^[a-z-]+:.*## ' $(firstword $(MAKEFILE_LIST)) | awk -F ':.*## ' '{ printf "  make %-12s %s\n", $$1, $$2 }'

# Git の値は、前後の空白と、両端を囲む引用符（" または ' の 1 組）を取り除いてから使う。
# 空ならホストの git config --global の値を使う
create: ## インスタンスを作成する（作成済みなら何もしない）
	@$(get-status); \
	if [ -n "$$st" ]; then \
	  echo "インスタンス $(NAME) は作成済みです"; \
	  exit 0; \
	fi; \
	normalize() { \
	  v=$$1; \
	  v=$${v#"$${v%%[![:space:]]*}"}; \
	  v=$${v%"$${v##*[![:space:]]}"}; \
	  case "$$v" in \"*\"|\'*\') v=$${v#?}; v=$${v%?} ;; esac; \
	  printf '%s' "$$v"; \
	}; \
	name=$$(normalize "$$GIT_USER_NAME"); \
	email=$$(normalize "$$GIT_USER_EMAIL"); \
	[ -n "$$name" ] || name=$$(git config --global user.name 2>/dev/null || true); \
	[ -n "$$email" ] || email=$$(git config --global user.email 2>/dev/null || true); \
	if [ -z "$$name" ] || [ -z "$$email" ]; then \
	  echo >&2 "注意: Git のユーザ名またはメールアドレスが空です。VM の中で手動で設定してください（README.md の「Git のコミット署名」を参照）"; \
	fi; \
	set -x; \
	limactl create --tty=false --name=$(NAME) \
	  $(if $(CPUS),--cpus=$(CPUS)) $(if $(MEMORY),--memory=$(MEMORY)) $(if $(DISK),--disk=$(DISK)) \
	  --param "gitUserName=$$name" --param "gitUserEmail=$$email" \
	  ./$(TEMPLATE)

# limactl start --param は値をカンマで区切ってしまうため、--param は limactl create で渡す
start: create ## インスタンスを起動する（無ければ作成する）
	limactl start $(if $(TIMEOUT),--timeout=$(TIMEOUT)) $(NAME)

shell: start ## シェルに入る（停止していれば起動する）
	limactl shell $(NAME)

# limactl shell はコマンドを指定してもログインシェルで実行するため、~/.local/bin の herdr が見つかる
herdr: start ## herdr のセッションに入る（無ければ作る。停止していれば起動する）
	limactl shell $(NAME) herdr

# Lima はインスタンスごとに ~/.lima/<名前>/ssh.config（Host lima-<名前>、HostName 127.0.0.1）を作る。
# ~/.ssh/config がそれを Include していないと、ssh -G は HostName としてホスト名をそのまま返す
herdr-remote: start ## ホストの herdr から VM のセッションにリモート接続する（停止していれば起動する）
	@if ! command -v herdr >/dev/null 2>&1; then \
	  echo >&2 "エラー: ホストに herdr がインストールされていません（brew install herdr。ほかの方法は https://herdr.dev/docs/install/ を参照）"; \
	  exit 1; \
	fi; \
	host=lima-$(NAME); \
	out=$$(ssh -G "$$host") || exit $$?; \
	if [ "$$(printf '%s\n' "$$out" | awk '$$1 == "hostname" { print $$2 }')" = "$$host" ]; then \
	  echo >&2 "エラー: ssh で $$host に接続する設定がありません。ホストの ~/.ssh/config の先頭に次の 1 行を追加してください:"; \
	  echo >&2 "  Include ~/.lima/*/ssh.config"; \
	  exit 1; \
	fi; \
	herdr --remote "$$host"

stop: ## インスタンスを停止する
	@$(get-status); \
	if [ "$$st" = Running ]; then \
	  set -x; limactl stop $(NAME); \
	else \
	  echo "インスタンス $(NAME) は動いていません"; \
	fi

restart: stop start ## インスタンスを再起動する（失敗したプロビジョニングのやり直しにも使う）

status: ## インスタンスの状態を表示する
	limactl list $(NAME)

delete: ## インスタンスを削除する（確認あり。YES=1 で確認を省略）
	@$(get-status); \
	if [ -z "$$st" ]; then \
	  echo "インスタンス $(NAME) はありません"; \
	  exit 0; \
	fi; \
	if [ "$(YES)" != 1 ]; then \
	  printf 'インスタンス %s を削除します。VM 内のファイルと認証情報もすべて消えます。よろしいですか？ [y/N] ' '$(NAME)'; \
	  read -r answer; \
	  case "$$answer" in [yY]*) ;; *) echo "中止しました"; exit 1 ;; esac; \
	fi; \
	if [ "$$st" = Running ]; then \
	  (set -x; limactl stop $(NAME)); \
	fi; \
	set -x; limactl delete $(NAME)

recreate: delete start ## インスタンスを作り直す（coding-sandbox.yaml や provision/*.sh の変更を反映する）

pubkey: ## Git のコミット署名用の公開鍵を表示する（GitHub に Signing Key として登録する）
	@limactl shell $(NAME) cat .ssh/id_ed25519_signing.pub

logs: ## プロビジョニングのログ（cloud-init）の末尾を表示する
	limactl shell $(NAME) sudo tail -n 100 /var/log/cloud-init-output.log

lint: ## テンプレートとスクリプトを検査する
	./scripts/lint.sh
