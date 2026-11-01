# コーディングエージェント用サンドボックス VM の操作をまとめたもの（詳細は README.md を参照）
#
#   $ make start    # 作成（初回のみ）と起動
#   $ make shell    # シェルに入る（停止していれば起動する）
#   $ make herdr    # herdr のセッションに入る（停止していれば起動する）
#   $ make herdr-remote  # ホストの herdr から VM のセッションにリモート接続する
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

# 設定ファイル（make の書式で KEY=値 を書く。.env.example を参照）。
# 既定の .env が無ければ読まない。コマンドラインで指定したファイルが無ければエラーにする
ENV_FILE := .env
ifneq ($(wildcard $(ENV_FILE)),)
include $(ENV_FILE)
else ifeq ($(origin ENV_FILE),command line)
$(error $(ENV_FILE) が見つかりません)
endif

# Git のユーザ名・メールアドレス、ホストループバック遮断設定、エージェント指示設定、CLI バージョン（作成時に --param で渡す）。
# 優先順位: コマンドライン > $(ENV_FILE) > ホストの git config --global（最後のものは create のレシピで補う）。
# 名前に空白や記号が含まれても壊れないよう、レシピの中では環境変数（"$$GIT_USER_NAME"）として参照する
export GIT_USER_NAME GIT_USER_EMAIL BLOCK_HOST_LOOPBACK AGENT_INSTRUCTIONS COPILOT_VERSION MISE_VERSION TERM_NAME

# インスタンスの状態（Running / Stopped など）を取得してシェル変数 st に格納する。
# インスタンスが無ければ空文字列、照会失敗時はエラーで終了する。
define get-status
	out=$$(limactl --log-level=error list --format '{{.Name}} {{.Status}}') || exit $$?; \
	st=$$(printf '%s\n' "$$out" | awk -v name="$(NAME)" '$$1 == name { print $$2 }')
endef

.NOTPARALLEL:
.DEFAULT_GOAL := help
.PHONY: help create start shell herdr herdr-remote forward _check-terminfo terminfo stop restart status delete recreate pubkey logs lint test

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
	mounts=$$(limactl template yq ./$(TEMPLATE) '.mounts[] | "- location: " + .location') || { \
	  echo >&2 "エラー: テンプレートまたは設定の検証に失敗しました"; \
	  exit 1; \
	}; \
	if [ -n "$$mounts" ]; then \
	  echo >&2 "エラー: ホストのディレクトリをマウントする設定があります（README.md の「ホストのマウントが混入しないように」を参照）:"; \
	  printf '%s\n' "$$mounts" >&2; \
	  exit 1; \
	fi; \
	normalize() { \
	  v=$$1; \
	  v=$${v#"$${v%%[![:space:]]*}"}; \
	  v=$${v%"$${v##*[![:space:]]}"}; \
	  case "$$v" in \"*\"|\'*\') v=$${v#?}; v=$${v%?} ;; esac; \
	  v=$${v#"$${v%%[![:space:]]*}"}; \
	  v=$${v%"$${v##*[![:space:]]}"}; \
	  printf '%s' "$$v"; \
	}; \
	name=$$(normalize "$$GIT_USER_NAME"); \
	email=$$(normalize "$$GIT_USER_EMAIL"); \
	block=$$(normalize "$$BLOCK_HOST_LOOPBACK"); \
	case "$$block" in ""|true|false) ;; *) echo >&2 "エラー: BLOCK_HOST_LOOPBACK は true か false を指定してください: $$block"; exit 1 ;; esac; \
	instr=$$(normalize "$$AGENT_INSTRUCTIONS"); \
	case "$$instr" in ""|true|false) ;; *) echo >&2 "エラー: AGENT_INSTRUCTIONS は true か false を指定してください: $$instr"; exit 1 ;; esac; \
	copilot_ver=$$(normalize "$$COPILOT_VERSION"); \
	case "$$copilot_ver" in ""|latest) copilot_ver="" ;; prerelease) ;; *) \
	  printf '%s\n' "$$copilot_ver" | grep -Eq '^[vV]?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z._-]+)?$$' || { \
	    echo >&2 "エラー: COPILOT_VERSION はバージョン（例: 1.0.91）または prerelease を指定してください: $$copilot_ver"; exit 1; \
	  } ;; \
	esac; \
	mise_ver=$$(normalize "$$MISE_VERSION"); \
	case "$$mise_ver" in ""|latest) mise_ver="" ;; *) \
	  printf '%s\n' "$$mise_ver" | grep -Eq '^[vV]?[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z._-]+)?$$' || { \
	    echo >&2 "エラー: MISE_VERSION はバージョン（例: 2026.10.7）を指定してください: $$mise_ver"; exit 1; \
	  } ;; \
	esac; \
	[ -n "$$name" ] || name=$$(git config --global user.name 2>/dev/null || true); \
	[ -n "$$email" ] || email=$$(git config --global user.email 2>/dev/null || true); \
	if [ -z "$$name" ] || [ -z "$$email" ]; then \
	  echo >&2 "注意: Git のユーザ名またはメールアドレスが空です。VM の中で手動で設定してください（README.md の「Git のコミット署名」を参照）"; \
	fi; \
	set -x; \
	limactl create --tty=false --name=$(NAME) \
	  $(if $(CPUS),--cpus=$(CPUS)) $(if $(MEMORY),--memory=$(MEMORY)) $(if $(DISK),--disk=$(DISK)) \
	  --param "gitUserName=$$name" --param "gitUserEmail=$$email" \
	  $${block:+--param "blockHostLoopback=$$block"} \
	  $${instr:+--param "agentInstructions=$$instr"} \
	  $${copilot_ver:+--param "copilotVersion=$$copilot_ver"} \
	  $${mise_ver:+--param "miseVersion=$$mise_ver"} \
	  ./$(TEMPLATE)

# limactl start --param は値をカンマで区切ってしまうため、--param は limactl create で渡す
start: create ## インスタンスを起動する（無ければ作成する）
	@mounts=$$(limactl list $(NAME) --format '{{range .Config.Mounts}}- location: {{.Location}}{{"\n"}}{{end}}') || { \
	  echo >&2 "エラー: インスタンス $(NAME) の設定確認に失敗しました"; \
	  exit 1; \
	}; \
	if [ -n "$$mounts" ]; then \
	  echo >&2 "エラー: ホストのディレクトリをマウントする設定があります（README.md の「ホストのマウントが混入しないように」を参照）:"; \
	  printf '%s\n' "$$mounts" >&2; \
	  $(get-status); \
	  if [ "$$st" = Running ]; then \
	    echo >&2 "インスタンス $(NAME) を停止します..."; \
	    limactl stop $(NAME); \
	  fi; \
	  exit 1; \
	fi; \
	if limactl start $(if $(TIMEOUT),--timeout=$(TIMEOUT)) $(NAME); then \
	  :; \
	else \
	  ret=$$?; \
	  if mounts=$$(limactl list $(NAME) --format '{{range .Config.Mounts}}- location: {{.Location}}{{"\n"}}{{end}}'); then \
	    if [ -n "$$mounts" ]; then \
	      echo >&2 "エラー: 起動後にホストのマウントが検出されました。インスタンス $(NAME) を停止します..."; \
	      if ! limactl stop $(NAME); then \
	        echo >&2 "警告: インスタンス $(NAME) の自動停止に失敗しました。手動で limactl stop $(NAME) を実行してください"; \
	      fi; \
	      echo >&2 "検出されたマウント:"; \
	      printf '%s\n' "$$mounts" >&2; \
	    fi; \
	  else \
	    echo >&2 "警告: 起動失敗後のマウント設定の再確認に失敗しました"; \
	  fi; \
	  exit $$ret; \
	fi

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

# Lima がインスタンスごとに作る ssh.config（ホストの ~/.ssh/config への Include は不要）で ssh -L する。
# ControlMaster を使うと、ssh は転送を Lima の既存の接続に登録してすぐ終了し、転送が残り続けるため使わない
# （ControlMaster=no で専用の接続を張るので、Ctrl-C で ssh を終了すると転送も止まる）
forward: start ## VM のポートをホストの 127.0.0.1 に転送する（PORT=<VM のポート> が必須。HOST_PORT で変えられる。Ctrl-C で終了）
	@case "$(PORT)" in ''|*[!0-9]*) echo >&2 "エラー: PORT=<VM のポート> を指定してください（例: make forward PORT=3000）"; exit 1 ;; esac; \
	dir=$$(limactl list $(NAME) --format '{{.Dir}}') || exit $$?; \
	host_port=$(or $(HOST_PORT),$(PORT)); \
	echo "VM の 127.0.0.1:$(PORT) を http://127.0.0.1:$$host_port に転送します（Ctrl-C で終了）"; \
	exec ssh -F "$$dir/ssh.config" -o ControlMaster=no -o ControlPath=none -o ExitOnForwardFailure=yes \
	  -N -L "127.0.0.1:$$host_port:127.0.0.1:$(PORT)" lima-$(NAME)

# terminfo の前提条件。ホストに入力されたターミナルの terminfo があるかを事前に検証する
_check-terminfo:
	@if [ -z "$$TERM_NAME" ]; then \
	  echo >&2 "エラー: TERM_NAME が空です（例: make terminfo TERM_NAME=xterm-ghostty）"; \
	  exit 1; \
	fi; \
	infocmp -x "$$TERM_NAME" >/dev/null || { \
	  echo >&2 "エラー: ホストに $$TERM_NAME の terminfo がありません"; \
	  exit 1; \
	}

# ホストの infocmp の出力を VM の tic に渡す。tic は root 以外で実行すると ~/.terminfo に書き込む。
# パイプでつなぐと /bin/sh では infocmp の失敗を検出できないため、いったん変数に入れてから渡す
terminfo: _check-terminfo start ## ホストの terminfo を VM にコピーする（既定は $TERM。TERM_NAME=<名前> で変えられる。停止していれば起動する）
	@src=$$(infocmp -x "$$TERM_NAME") || exit $$?; \
	printf '%s\n' "$$src" | limactl shell $(NAME) tic -x - || exit $$?; \
	echo "$$TERM_NAME の terminfo を VM の ~/.terminfo にコピーしました（次に入るシェルから TERM が置き換えられなくなります）"

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

test: ## プロビジョニングスクリプトと Makefile の回帰テストを実行する
	bash ./scripts/test.sh
