#!/usr/bin/env bash
#
# rds-proxy-db-maintenance.sh
# ===========================
# EC2 (RHEL 9) 上の EBS に配置したメンテナンス系ジョブから、RDS Proxy を経由して
# Aurora Serverless v2 (Aurora MySQL 3 系 / MySQL 8.0 互換) へ接続し、SQL を実行して
# 結果を EBS 上のファイル (TSV) へ保存するスクリプトです。
#
# 接続クライアント（--client で切り替え）:
#   mysql : mysql コマンドラインクライアントで接続（既定）
#   java  : MySQL Connector/J (JDBC ドライバ) を使い、同梱の Java ランナー
#           (java/JdbcSqlRunner.java) 経由で接続。Java 11+ のシングルファイル
#           ソース起動を使うため事前コンパイルは不要。Connector/J の jar は
#           --jdbc-driver で指定（未指定なら lib/ と /usr/share/java/ を探索）。
#           接続情報 (URL/ユーザー/パスワード/SQL パス) は環境変数で Java 側へ
#           渡すため、コマンドライン引数にパスワードは載らない。
#
# 認証方式（--auth-plugin で切り替え）:
#   mysql_native_password   : パスワード認証（RDS Proxy の ClientPasswordAuthType =
#                             MYSQL_NATIVE_PASSWORD 相当）。TLS は推奨（既定で REQUIRED）。
#   caching_sha2_password   : パスワード認証（MySQL 8.0 の既定プラグイン）。
#                             安全な経路が必須のため TLS を強制（REQUIRED 以上）。
#   iam                     : パスワードレス。IAM 認証トークン
#                             (aws rds generate-db-auth-token) を使用。TLS 必須。
#                             RDS Proxy 側で IAMAuth=REQUIRED、IAM ロールに
#                             rds-db:connect 権限が必要。
#
# パスワードの取得元（--password-source で切り替え / iam 以外で使用）:
#   secretsmanager : AWS Secrets Manager から取得（推奨）。--secret-id 必須。
#                    SecretString が JSON なら .password キー、平文ならそのまま使用。
#   env            : 環境変数 DB_PASSWORD から取得（cron 等での一時利用向け）。
#   file           : --password-file で指定したファイル（EBS 上, 権限 600 推奨）の
#                    1 行目をパスワードとして使用。
#   ※ いずれの場合もパスワードはコマンドライン引数に載せず、mktemp で作成した
#      一時 defaults-extra-file (権限 600) 経由で mysql クライアントへ渡します
#      （ps コマンド等からの漏えい防止）。一時ファイルは終了時に必ず削除します。
#
# 実行前チェック:
#   1. aws login --remote による認証が済んでいるか（sts get-caller-identity で判定）。
#      未認証なら警告メッセージを出して終了コード 2 で終了します。
#   2. 必要な AWS 操作（Secrets Manager 取得等）の権限があるか。権限不足
#      （スイッチロールしたまま等）の場合:
#        - 既定           : スイッチバックを促す警告を出して終了コード 3 で終了
#        - --auto-switch-back : 別チーム提供のスイッチバック用シェルを source して
#                               自動でスイッチバックし、処理を 1 回だけリトライ
#      スイッチバック用シェルの配置場所は --switch-back-script <path> または
#      環境変数 SWITCH_BACK_SCRIPT で指定できます。
#
# 処理の流れ:
#   1. 引数解析・前提コマンド確認 (aws / mysql)
#   2. AWS 認証チェック（未認証なら警告して終了）
#   3. 認証情報の準備（Secrets Manager 取得 or IAM トークン生成。権限不足なら
#      スイッチバック警告終了 or 自動スイッチバック）
#   4. 一時 defaults-extra-file を作成して mysql で SQL を実行
#   5. 結果 (TSV) を EBS 上の出力ファイルへ保存し、サマリを表示
#
# 依存: bash, aws (CLI v2)。Secrets Manager の JSON 解析に jq または python3。
#       --client mysql : mysql (MySQL 8.0 クライアント推奨。RHEL9: `sudo dnf install mysql`)
#       --client java  : java 11+ (RHEL9: `sudo dnf install java-17-openjdk-headless`) と
#                        MySQL Connector/J の jar (`sudo dnf install mysql-connector-j`
#                        または lib/ に配置)
# 共通部品: common.sh
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. 共通部品(common.sh)の読み込み
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

if [[ ! -f "${SCRIPT_DIR}/common.sh" ]]; then
  echo "[${SCRIPT_NAME}][ERROR] common.sh が見つかりません: ${SCRIPT_DIR}/common.sh" >&2
  exit 1
fi
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
PROXY_ENDPOINT=""                        # RDS Proxy のエンドポイント (必須)
PORT="3306"                              # 接続ポート
DB_USER=""                               # DB ユーザー名 (必須)
DATABASE=""                              # 接続先データベース名 (任意)
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"  # AWS リージョン

CLIENT="mysql"                           # mysql | java (接続に使うクライアント)
JDBC_DRIVER=""                           # MySQL Connector/J の jar パス (--client java 用)
JAVA_RUNNER="${SCRIPT_DIR}/java/JdbcSqlRunner.java"  # JDBC 接続用 Java ランナー
JDBC_URL=""                              # 組み立てた JDBC 接続 URL (内部使用)

AUTH_PLUGIN="mysql_native_password"      # mysql_native_password | caching_sha2_password | iam
PASSWORD_SOURCE="secretsmanager"         # secretsmanager | env | file (iam では未使用)
SECRET_ID=""                             # Secrets Manager のシークレット ID / ARN
PASSWORD_FILE=""                         # パスワードファイル (EBS 上, 600 推奨)

SSL_CA=""                                # RDS CA バンドル (global-bundle.pem) のパス
DOWNLOAD_CA="false"                      # true なら CA バンドルを自動ダウンロード
CA_URL="https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"

SQL_FILE=""                              # 実行する SQL ファイル (EBS 上)
SQL_TEXT=""                              # 実行する SQL 文字列 (--sql)
OUTPUT_FILE=""                           # 結果出力先。未指定なら OUTPUT_DIR に自動命名
OUTPUT_DIR="${SCRIPT_DIR}/output"        # 既定の出力ディレクトリ (EBS 上)

# スイッチバック用スクリプト（別チーム提供。外から差し替え可能）
#   優先順位: コマンドライン > 環境変数 > 既定（このスクリプトと同階層）
SWITCH_BACK_SCRIPT="${SWITCH_BACK_SCRIPT:-${SCRIPT_DIR}/switch-back.sh}"
AUTO_SWITCH_BACK="false"                 # true なら権限不足時に自動でスイッチバック

CONNECT_TIMEOUT="10"                     # mysql 接続タイムアウト(秒)
DRY_RUN="false"                          # true なら接続せず実行内容の表示のみ
DEBUG="${DEBUG:-false}"
export DEBUG

MYSQL_CNF=""                             # 一時 defaults-extra-file (trap で削除)
TMP_SQL_FILE=""                          # 組み込みサンプル SQL の一時ファイル
SWITCHED_BACK="false"                    # 自動スイッチバックを実施済みか（リトライは 1 回だけ）

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --proxy-endpoint <host> --db-user <user> [オプション]

説明:
  RDS Proxy 経由で Aurora Serverless v2 (Aurora MySQL 3 系) へ接続し、SQL を実行して
  結果を TSV ファイルへ保存します。認証プラグインはパラメータで切り替えられます。

必須:
  --proxy-endpoint <host>   RDS Proxy のエンドポイント
                            (例: my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com)
  --db-user <user>          接続する DB ユーザー名

認証方式:
  --auth-plugin <plugin>    mysql_native_password (既定) | caching_sha2_password | iam
                              mysql_native_password : パスワード認証
                              caching_sha2_password : パスワード認証 (TLS 強制)
                              iam                   : パスワードレス (IAM 認証トークン)

接続クライアント:
  --client <client>         mysql (既定) | java
                              mysql : mysql コマンドラインクライアントで接続
                              java  : MySQL Connector/J (JDBC) + 同梱 Java ランナー
                                      (java/JdbcSqlRunner.java) で接続。Java 11+ 必須
  --jdbc-driver <path>      MySQL Connector/J の jar パス (--client java のとき使用。
                            未指定なら ${SCRIPT_DIR}/lib/ と /usr/share/java/ から
                            mysql-connector-j*.jar を自動探索)

パスワード取得元 (--auth-plugin が iam 以外のとき):
  --password-source <src>   secretsmanager (既定) | env | file
  --secret-id <id>          Secrets Manager のシークレット ID / ARN
                            (--password-source secretsmanager のとき必須)
  --password-file <path>    パスワードファイル (--password-source file のとき必須。
                            EBS 上に権限 600 で配置すること)
                            ※ env の場合は環境変数 DB_PASSWORD を使用

接続オプション:
  --port <port>             接続ポート (既定: 3306)
  --database <name>         接続先データベース名
  --region <region>         AWS リージョン (--auth-plugin iam のとき必須)
  --ssl-ca <path>           RDS CA バンドル (global-bundle.pem) のパス。
                            指定するとサーバ証明書を検証 (VERIFY_CA)
  --download-ca             CA バンドルが無ければ自動ダウンロードして使用
  --connect-timeout <sec>   mysql 接続タイムアウト (既定: 10)

SQL / 出力:
  --sql-file <path>         実行する SQL ファイル (EBS 上)
  --sql "<SQL>"             実行する SQL 文字列 (--sql-file と排他)
                            ※ どちらも未指定なら組み込みのメンテナンス用サンプル SQL
                              (接続情報確認 + テーブルサイズ上位 20) を実行
  --output-file <path>      結果 (TSV) の出力先 (既定: ${OUTPUT_DIR}/
                            maintenance_YYYYmmdd_HHMMSS.tsv)

スイッチバック (権限不足時の動作):
  --switch-back-script <path>  スイッチバック用スクリプト (source される。
                               既定: \$SWITCH_BACK_SCRIPT または ./switch-back.sh)
  --auto-switch-back           権限不足時に警告終了せず、自動でスイッチバックして
                               1 回だけリトライする (既定: 警告を出して終了)

その他:
  --dry-run                 DB へは接続せず、実行内容の表示のみ
  --debug                   デバッグログを出力する
  -h, --help                このヘルプを表示

環境変数:
  DB_PASSWORD               --password-source env のときに使用するパスワード
  SWITCH_BACK_SCRIPT        スイッチバック用スクリプトの既定パス
  AWS_REGION / AWS_DEFAULT_REGION  --region 未指定時の既定リージョン

例:
  # 1) mysql_native_password + Secrets Manager (推奨構成)
  ./${SCRIPT_NAME} \\
    --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \\
    --db-user batch_user --database appdb --region ap-northeast-1 \\
    --auth-plugin mysql_native_password \\
    --password-source secretsmanager --secret-id prod/appdb/batch_user

  # 2) caching_sha2_password + CA 検証 (TLS 必須)
  ./${SCRIPT_NAME} \\
    --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \\
    --db-user batch_user --database appdb --region ap-northeast-1 \\
    --auth-plugin caching_sha2_password \\
    --password-source secretsmanager --secret-id prod/appdb/batch_user \\
    --download-ca

  # 3) IAM 認証 (パスワードレス) + 自動スイッチバック + 独自 SQL
  ./${SCRIPT_NAME} \\
    --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \\
    --db-user iam_batch_user --database appdb --region ap-northeast-1 \\
    --auth-plugin iam --download-ca \\
    --sql-file /data/jobs/sql/nightly_maintenance.sql \\
    --auto-switch-back --switch-back-script /opt/iam/switch-back.sh

  # 4) MySQL Connector/J (JDBC ドライバ) 経由で接続 (caching_sha2_password の例)
  ./${SCRIPT_NAME} \\
    --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \\
    --db-user batch_user --database appdb --region ap-northeast-1 \\
    --client java --jdbc-driver /usr/share/java/mysql-connector-j.jar \\
    --auth-plugin caching_sha2_password \\
    --password-source secretsmanager --secret-id prod/appdb/batch_user

終了コード:
  0  成功
  1  エラー (引数不正・SQL 実行失敗など)
  2  AWS 未認証 (aws login --remote が未実行)
  3  AWS 権限不足 (スイッチバックが必要)
USAGE
}

# ---------------------------------------------------------------------------
# 3. 引数解析
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --proxy-endpoint)      PROXY_ENDPOINT="${2:?--proxy-endpoint に値がありません}"; shift 2 ;;
    --port)                PORT="${2:?--port に値がありません}"; shift 2 ;;
    --db-user)             DB_USER="${2:?--db-user に値がありません}"; shift 2 ;;
    --database)            DATABASE="${2:?--database に値がありません}"; shift 2 ;;
    --region)              REGION="${2:?--region に値がありません}"; shift 2 ;;
    --auth-plugin)         AUTH_PLUGIN="${2:?--auth-plugin に値がありません}"; shift 2 ;;
    --client)              CLIENT="${2:?--client に値がありません}"; shift 2 ;;
    --jdbc-driver)         JDBC_DRIVER="${2:?--jdbc-driver に値がありません}"; shift 2 ;;
    --password-source)     PASSWORD_SOURCE="${2:?--password-source に値がありません}"; shift 2 ;;
    --secret-id)           SECRET_ID="${2:?--secret-id に値がありません}"; shift 2 ;;
    --password-file)       PASSWORD_FILE="${2:?--password-file に値がありません}"; shift 2 ;;
    --ssl-ca)              SSL_CA="${2:?--ssl-ca に値がありません}"; shift 2 ;;
    --download-ca)         DOWNLOAD_CA="true"; shift ;;
    --sql-file)            SQL_FILE="${2:?--sql-file に値がありません}"; shift 2 ;;
    --sql)                 SQL_TEXT="${2:?--sql に値がありません}"; shift 2 ;;
    --output-file)         OUTPUT_FILE="${2:?--output-file に値がありません}"; shift 2 ;;
    --connect-timeout)     CONNECT_TIMEOUT="${2:?--connect-timeout に値がありません}"; shift 2 ;;
    --switch-back-script)  SWITCH_BACK_SCRIPT="${2:?--switch-back-script に値がありません}"; shift 2 ;;
    --auto-switch-back)    AUTO_SWITCH_BACK="true"; shift ;;
    --dry-run)             DRY_RUN="true"; shift ;;
    --debug)               DEBUG="true"; shift ;;
    -h | --help)           usage; exit 0 ;;
    *)                     log_error "不明な引数です: $1"; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 4. 入力検証・前提確認
# ---------------------------------------------------------------------------
[[ -n "$PROXY_ENDPOINT" ]] || { log_error "--proxy-endpoint は必須です"; usage; exit 1; }
[[ -n "$DB_USER"        ]] || { log_error "--db-user は必須です"; usage; exit 1; }

case "$AUTH_PLUGIN" in
  mysql_native_password | caching_sha2_password | iam) ;;
  *) die "--auth-plugin は mysql_native_password / caching_sha2_password / iam のいずれかを指定してください: $AUTH_PLUGIN" ;;
esac

if [[ "$AUTH_PLUGIN" != "iam" ]]; then
  case "$PASSWORD_SOURCE" in
    secretsmanager)
      [[ -n "$SECRET_ID" ]] || die "--password-source secretsmanager の場合は --secret-id が必須です"
      ;;
    env)
      [[ -n "${DB_PASSWORD:-}" ]] || die "--password-source env の場合は環境変数 DB_PASSWORD を設定してください"
      ;;
    file)
      [[ -n "$PASSWORD_FILE" ]] || die "--password-source file の場合は --password-file が必須です"
      [[ -f "$PASSWORD_FILE" ]] || die "パスワードファイルが見つかりません: $PASSWORD_FILE"
      ;;
    *) die "--password-source は secretsmanager / env / file のいずれかを指定してください: $PASSWORD_SOURCE" ;;
  esac
else
  [[ -n "$REGION" ]] || die "--auth-plugin iam の場合は --region (または AWS_REGION) が必須です"
fi

[[ -n "$SQL_FILE" && -n "$SQL_TEXT" ]] && die "--sql-file と --sql は同時に指定できません"
[[ -n "$SQL_FILE" && ! -f "$SQL_FILE" ]] && die "SQL ファイルが見つかりません: $SQL_FILE"

case "$CLIENT" in
  mysql | java) ;;
  *) die "--client は mysql / java のいずれかを指定してください: $CLIENT" ;;
esac

require_command aws

MYSQL_IS_MARIADB="false"
if [[ "$CLIENT" == "mysql" ]]; then
  require_command mysql

  # mysql クライアントの種別を確認 (RHEL9 では mariadb が mysql として入っている場合がある)
  if mysql --version 2>/dev/null | grep -qi mariadb; then
    MYSQL_IS_MARIADB="true"
  fi
  log_debug "mysql クライアント: $(mysql --version 2>/dev/null) (MariaDB: ${MYSQL_IS_MARIADB})"

  if [[ "$AUTH_PLUGIN" == "iam" && "$MYSQL_IS_MARIADB" == "true" ]]; then
    die "IAM 認証には MySQL 8.0 クライアント (--enable-cleartext-plugin 対応) が必要です。MariaDB クライアントでは接続できません。'sudo dnf install mysql' で MySQL クライアントを導入するか、--client java を使用してください。"
  fi
  if [[ "$AUTH_PLUGIN" == "caching_sha2_password" && "$MYSQL_IS_MARIADB" == "true" ]]; then
    log_warn "MariaDB クライアントを検出しました。caching_sha2_password は新しめの MariaDB クライアントでのみ動作します。問題が出る場合は MySQL 8.0 クライアントか --client java を使用してください。"
  fi
else
  # --client java : Java 11+ (シングルファイルソース起動) と Connector/J jar が必要
  require_command java
  [[ -f "$JAVA_RUNNER" ]] || die "JDBC 接続用 Java ランナーが見つかりません: $JAVA_RUNNER"

  if [[ -z "$JDBC_DRIVER" ]]; then
    # Connector/J の jar を既定の場所から自動探索する
    for candidate in \
      "${SCRIPT_DIR}"/lib/mysql-connector-j*.jar \
      /usr/share/java/mysql-connector-j*.jar \
      /usr/share/java/mysql-connector-java*.jar; do
      if [[ -f "$candidate" ]]; then
        JDBC_DRIVER="$candidate"
        break
      fi
    done
    [[ -n "$JDBC_DRIVER" ]] \
      || die "MySQL Connector/J の jar が見つかりません。--jdbc-driver <path> で指定するか、${SCRIPT_DIR}/lib/ に mysql-connector-j-x.y.z.jar を配置してください (入手: https://dev.mysql.com/downloads/connector/j/ または 'sudo dnf install mysql-connector-j')"
  fi
  [[ -f "$JDBC_DRIVER" ]] || die "JDBC ドライバの jar が見つかりません: $JDBC_DRIVER"
  log_debug "JDBC ドライバ: $JDBC_DRIVER / java: $(java -version 2>&1 | head -n 1)"
fi

# ---------------------------------------------------------------------------
# 5. 一時ファイル後始末 (パスワード入り defaults ファイルは必ず削除する)
# ---------------------------------------------------------------------------
cleanup() {
  [[ -n "$MYSQL_CNF"    && -f "$MYSQL_CNF"    ]] && rm -f "$MYSQL_CNF"
  [[ -n "$TMP_SQL_FILE" && -f "$TMP_SQL_FILE" ]] && rm -f "$TMP_SQL_FILE"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 6. AWS 認証チェック (aws login --remote 済みか)
# ---------------------------------------------------------------------------
log_info "AWS 認証状態を確認しています..."
if ! aws_is_authenticated ${REGION:+--region "$REGION"}; then
  log_error "AWS 未認証です。AWS の認証情報が確認できませんでした。"
  log_error "先に次のコマンドで認証を済ませてから、本スクリプトを再実行してください:"
  log_error "  aws login --remote"
  exit 2
fi
CALLER_ARN="$(aws_caller_arn ${REGION:+--region "$REGION"})"
log_success "AWS 認証済みです (呼び出し元: ${CALLER_ARN:-不明})"

# ---------------------------------------------------------------------------
# 7. スイッチバック処理
#    権限不足 (スイッチロールしたまま等) を検出したときに呼ばれる。
#      - AUTO_SWITCH_BACK=false : スイッチバックを促す警告を出して終了 (exit 3)
#      - AUTO_SWITCH_BACK=true  : 別チーム提供のスクリプトを source して自動で
#                                 スイッチバックし、呼び出し元でリトライさせる
# ---------------------------------------------------------------------------
do_switch_back() {
  [[ -f "$SWITCH_BACK_SCRIPT" ]] \
    || die "スイッチバック用スクリプトが見つかりません: $SWITCH_BACK_SCRIPT (--switch-back-script で指定してください)" 3
  log_info "スイッチバック用スクリプトを source します: $SWITCH_BACK_SCRIPT"
  # 別チーム提供のスクリプト。環境変数の変更を本スクリプトへ反映させるため source する。
  # shellcheck disable=SC1090
  source "$SWITCH_BACK_SCRIPT"
  if ! aws_is_authenticated ${REGION:+--region "$REGION"}; then
    die "スイッチバック後も AWS 認証が確認できません。'aws login --remote' からやり直してください。" 2
  fi
  CALLER_ARN="$(aws_caller_arn ${REGION:+--region "$REGION"})"
  log_success "スイッチバックしました (呼び出し元: ${CALLER_ARN:-不明})"
  SWITCHED_BACK="true"
}

# 権限不足を検出したときの共通ハンドラ。
#   自動スイッチバックできた場合のみ 0 を返す (呼び出し元で 1 回だけリトライする)。
# usage: handle_access_denied "<権限の説明>"
handle_access_denied() {
  local what="$1"
  log_warn "現在の操作権限では AWS への操作ができません: ${what}"
  log_warn "(呼び出し元: ${CALLER_ARN:-不明})"

  if [[ "$AUTO_SWITCH_BACK" == "true" && "$SWITCHED_BACK" == "false" ]]; then
    log_info "--auto-switch-back が指定されているため、自動でスイッチバックします。"
    do_switch_back
    return 0
  fi

  log_error "スイッチロールしたままの可能性があります。スイッチバックしてから再実行してください:"
  log_error "  source ${SWITCH_BACK_SCRIPT}"
  log_error "(または --auto-switch-back を付けて実行すると、自動でスイッチバックしてリトライします)"
  exit 3
}

# ---------------------------------------------------------------------------
# 8. 認証情報の準備 (パスワード取得 or IAM トークン生成)
# ---------------------------------------------------------------------------

# Secrets Manager の SecretString からパスワードを取り出す。
#   JSON ({"username":..,"password":..}) なら .password、平文ならそのまま。
parse_secret_password() {
  local secret="$1"
  if [[ "$secret" == \{* ]]; then
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "$secret" | jq -r '.password // empty'
    elif command -v python3 >/dev/null 2>&1; then
      printf '%s' "$secret" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("password",""))'
    else
      die "SecretString が JSON 形式ですが、解析に必要な jq / python3 が見つかりません"
    fi
  else
    printf '%s' "$secret"
  fi
}

# Secrets Manager からパスワードを取得する (権限不足ならスイッチバック処理へ)
get_password_from_secretsmanager() {
  local out rc
  log_info "Secrets Manager からパスワードを取得します (secret-id: ${SECRET_ID})"
  set +e
  out="$(aws secretsmanager get-secret-value \
           ${REGION:+--region "$REGION"} \
           --secret-id "$SECRET_ID" \
           --query SecretString --output text 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    if is_access_denied "$out"; then
      handle_access_denied "secretsmanager:GetSecretValue (${SECRET_ID})"
      # 自動スイッチバック済み。リトライ (1 回だけ)
      out="$(aws secretsmanager get-secret-value \
               ${REGION:+--region "$REGION"} \
               --secret-id "$SECRET_ID" \
               --query SecretString --output text 2>&1)" \
        || die "スイッチバック後も Secrets Manager から取得できませんでした: $out" 3
    else
      die "Secrets Manager からの取得に失敗しました: $out"
    fi
  fi
  DB_PASS="$(parse_secret_password "$out")"
  [[ -n "$DB_PASS" ]] || die "SecretString からパスワードを取り出せませんでした (JSON の場合は .password キーが必要です)"
  log_success "パスワードを取得しました"
}

# パスワードファイルから取得 (EBS 上。権限 600 を推奨)
get_password_from_file() {
  local perms
  perms="$(stat -c '%a' "$PASSWORD_FILE" 2>/dev/null || echo '')"
  if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
    log_warn "パスワードファイルの権限が ${perms} です。'chmod 600 ${PASSWORD_FILE}' を推奨します。"
  fi
  DB_PASS="$(head -n 1 "$PASSWORD_FILE")"
  [[ -n "$DB_PASS" ]] || die "パスワードファイルが空です: $PASSWORD_FILE"
  log_success "パスワードファイルから取得しました: $PASSWORD_FILE"
}

# IAM 認証トークンを生成する (パスワードレス接続)
#   generate-db-auth-token はローカル署名のため API 呼び出しは発生しない。
#   rds-db:connect 権限の不足は接続時 (Access denied) に判明する。
generate_iam_token() {
  log_info "IAM 認証トークンを生成します (endpoint: ${PROXY_ENDPOINT}:${PORT}, user: ${DB_USER})"
  DB_PASS="$(aws rds generate-db-auth-token \
               --hostname "$PROXY_ENDPOINT" \
               --port "$PORT" \
               --username "$DB_USER" \
               --region "$REGION")" \
    || die "IAM 認証トークンの生成に失敗しました"
  log_success "IAM 認証トークンを生成しました (有効期限: 15 分)"
}

DB_PASS=""
prepare_credentials() {
  if [[ "$AUTH_PLUGIN" == "iam" ]]; then
    generate_iam_token
  else
    case "$PASSWORD_SOURCE" in
      secretsmanager) get_password_from_secretsmanager ;;
      env)            DB_PASS="$DB_PASSWORD"; log_info "環境変数 DB_PASSWORD からパスワードを使用します" ;;
      file)           get_password_from_file ;;
    esac
  fi
}

# ---------------------------------------------------------------------------
# 9. TLS (CA バンドル) の準備
#    caching_sha2_password と iam は TLS 必須。CA が指定されていれば VERIFY_CA。
# ---------------------------------------------------------------------------
prepare_ca_bundle() {
  if [[ -z "$SSL_CA" && "$DOWNLOAD_CA" == "true" ]]; then
    SSL_CA="${SCRIPT_DIR}/certs/global-bundle.pem"
    if [[ ! -f "$SSL_CA" ]]; then
      require_command curl
      log_info "RDS CA バンドルをダウンロードします: $CA_URL"
      mkdir -p "${SCRIPT_DIR}/certs"
      curl -fsSL -o "$SSL_CA" "$CA_URL" || die "CA バンドルのダウンロードに失敗しました: $CA_URL"
      log_success "CA バンドルを保存しました: $SSL_CA"
    else
      log_info "既存の CA バンドルを使用します: $SSL_CA"
    fi
  fi
  [[ -n "$SSL_CA" && ! -f "$SSL_CA" ]] && die "CA バンドルが見つかりません: $SSL_CA"
  return 0
}

# ---------------------------------------------------------------------------
# 10. mysql 用 一時 defaults-extra-file の作成
#     パスワードをコマンドラインに載せない (ps から見えない) ようにするため、
#     権限 600 の一時ファイルへ書き出して --defaults-extra-file で渡す。
# ---------------------------------------------------------------------------
write_mysql_cnf() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  if [[ -z "$MYSQL_CNF" ]]; then
    MYSQL_CNF="$(mktemp "${TMPDIR:-/tmp}/rdsproxy_mysql.XXXXXX")"
  fi

  # my.cnf 形式では password="..." とし、" と \ をエスケープする
  local esc_pass
  esc_pass="${DB_PASS//\\/\\\\}"
  esc_pass="${esc_pass//\"/\\\"}"

  {
    echo "[client]"
    echo "host=${PROXY_ENDPOINT}"
    echo "port=${PORT}"
    echo "user=${DB_USER}"
    echo "password=\"${esc_pass}\""
    echo "connect-timeout=${CONNECT_TIMEOUT}"

    # --- 認証プラグイン別の設定 ---
    case "$AUTH_PLUGIN" in
      mysql_native_password)
        [[ "$MYSQL_IS_MARIADB" == "false" ]] && echo "default-auth=mysql_native_password"
        ;;
      caching_sha2_password)
        [[ "$MYSQL_IS_MARIADB" == "false" ]] && echo "default-auth=caching_sha2_password"
        ;;
      iam)
        # IAM トークンは平文パスワードとして送るため cleartext プラグインを有効化
        echo "enable-cleartext-plugin=1"
        ;;
    esac

    # --- TLS 設定 ---
    if [[ "$MYSQL_IS_MARIADB" == "true" ]]; then
      # MariaDB クライアントは ssl-mode 非対応
      if [[ -n "$SSL_CA" ]]; then
        echo "ssl-ca=${SSL_CA}"
        echo "ssl-verify-server-cert"
      elif [[ "$AUTH_PLUGIN" != "mysql_native_password" ]]; then
        echo "ssl"
      fi
    else
      if [[ -n "$SSL_CA" ]]; then
        echo "ssl-mode=VERIFY_CA"
        echo "ssl-ca=${SSL_CA}"
      else
        # RDS Proxy は TLS 対応。caching_sha2 / iam は TLS 必須のため REQUIRED、
        # mysql_native_password でも暗号化のため REQUIRED を既定とする。
        echo "ssl-mode=REQUIRED"
      fi
    fi
  } > "$MYSQL_CNF"

  umask "$old_umask"
  log_debug "defaults-extra-file を作成しました: $MYSQL_CNF"
}

# ---------------------------------------------------------------------------
# 10-2. JDBC 接続 URL の組み立て (--client java 用)
#       パスワードは URL に含めず、環境変数 DB_PASS で Java 側へ渡す。
# ---------------------------------------------------------------------------
build_jdbc_url() {
  local props
  # allowMultiQueries : SQL ファイル内の複数ステートメントを 1 回で実行するため
  # sslMode=REQUIRED  : RDS Proxy は TLS 対応。caching_sha2_password と IAM は
  #                     TLS 必須、mysql_native_password でも暗号化のため必須とする
  props="allowMultiQueries=true"
  props+="&connectTimeout=$((CONNECT_TIMEOUT * 1000))"
  props+="&socketTimeout=0"
  props+="&sslMode=REQUIRED"
  props+="&tcpKeepAlive=true"

  if [[ -n "$SSL_CA" ]]; then
    # Connector/J は PEM の CA バンドルを直接は読めない (JKS/PKCS12 トラストストアが必要)。
    # サーバ証明書の検証まで行いたい場合は keytool でトラストストアを作成し、
    # trustCertificateKeyStoreUrl を URL に追加すること (README 参照)。
    log_warn "--client java では --ssl-ca (PEM) は使用されません (暗号化のみの sslMode=REQUIRED で接続します)"
  fi

  JDBC_URL="jdbc:mysql://${PROXY_ENDPOINT}:${PORT}/${DATABASE}?${props}"
  log_debug "JDBC URL: $JDBC_URL"
}

# ---------------------------------------------------------------------------
# 11. 実行する SQL の決定 (未指定なら組み込みのメンテナンス用サンプル)
# ---------------------------------------------------------------------------
prepare_sql_file() {
  if [[ -n "$SQL_FILE" ]]; then
    return 0
  fi
  TMP_SQL_FILE="$(mktemp "${TMPDIR:-/tmp}/rdsproxy_maintenance_sql.XXXXXX")"
  if [[ -n "$SQL_TEXT" ]]; then
    printf '%s\n' "$SQL_TEXT" > "$TMP_SQL_FILE"
  else
    log_info "SQL が未指定のため、組み込みのメンテナンス用サンプル SQL を実行します"
    cat > "$TMP_SQL_FILE" <<'SQL'
-- メンテナンスジョブ サンプル 1: 接続確認 (どこに・誰で・どの経路でつながったか)
SELECT NOW()            AS executed_at,
       CURRENT_USER()   AS connected_as,
       @@hostname       AS server_hostname,
       @@version        AS mysql_version,
       @@aurora_version AS aurora_version;

-- メンテナンスジョブ サンプル 2: ユーザーテーブルのサイズ上位 20 (肥大化監視)
SELECT table_schema,
       table_name,
       table_rows,
       ROUND((data_length + index_length) / 1024 / 1024, 2) AS size_mb
  FROM information_schema.tables
 WHERE table_schema NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
 ORDER BY (data_length + index_length) DESC
 LIMIT 20;
SQL
  fi
  SQL_FILE="$TMP_SQL_FILE"
}

# ---------------------------------------------------------------------------
# 12. SQL 実行と結果取得
# ---------------------------------------------------------------------------

# SQL を 1 回実行する (stdout -> OUTPUT_FILE, stderr -> グローバル変数 SQL_ERR)
#   --client に応じて mysql コマンド / Java(JDBC) を切り替える。
# 戻り値: クライアントの終了コード
exec_sql_once() {
  local rc=0
  set +e
  if [[ "$CLIENT" == "java" ]]; then
    # 接続情報はすべて環境変数で Java ランナーへ渡す (引数にパスワードを載せない)。
    # Java 11+ のシングルファイルソース起動のため事前コンパイル不要。
    # -Dfile.encoding=UTF-8 : LANG=C の cron 環境でもソース(UTF-8)を正しく読むため
    SQL_ERR="$(JDBC_URL="$JDBC_URL" \
               DB_USER="$DB_USER" \
               DB_PASS="$DB_PASS" \
               SQL_FILE="$SQL_FILE" \
               java -Dfile.encoding=UTF-8 -cp "$JDBC_DRIVER" "$JAVA_RUNNER" \
               2>&1 >"$OUTPUT_FILE")"
    rc=$?
  else
    # --batch : タブ区切り(TSV)で出力
    SQL_ERR="$(mysql --defaults-extra-file="$MYSQL_CNF" \
                 --batch --comments \
                 ${DATABASE:+"$DATABASE"} \
                 < "$SQL_FILE" \
                 2>&1 >"$OUTPUT_FILE")"
    rc=$?
  fi
  set -e
  return "$rc"
}

SQL_ERR=""
run_sql() {
  local rc

  if [[ -z "$OUTPUT_FILE" ]]; then
    mkdir -p "$OUTPUT_DIR"
    OUTPUT_FILE="${OUTPUT_DIR}/maintenance_$(date +%Y%m%d_%H%M%S).tsv"
  else
    mkdir -p "$(dirname "$OUTPUT_FILE")"
  fi

  log_info "RDS Proxy 経由で Aurora へ接続し SQL を実行します"
  log_info "  endpoint    : ${PROXY_ENDPOINT}:${PORT}"
  log_info "  user        : ${DB_USER}"
  log_info "  database    : ${DATABASE:-（未指定）}"
  log_info "  auth-plugin : ${AUTH_PLUGIN}"
  log_info "  client      : ${CLIENT}$( [[ "$CLIENT" == "java" ]] && printf ' (Connector/J: %s)' "$JDBC_DRIVER" )"
  log_info "  sql-file    : ${SQL_FILE}"
  log_info "  output-file : ${OUTPUT_FILE}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "(dry-run のため接続・SQL 実行はスキップします)"
    return 0
  fi

  rc=0
  exec_sql_once || rc=$?

  # 接続時の Access denied (1045) は、スイッチロール中の IAM 権限不足
  # (rds-db:connect) が原因の可能性があるため、スイッチバックのリトライ対象とする
  if [[ $rc -ne 0 ]] && printf '%s' "$SQL_ERR" | grep -qi 'access denied' \
     && [[ "$AUTH_PLUGIN" == "iam" && "$SWITCHED_BACK" == "false" ]]; then
    log_warn "DB 接続が拒否されました: $SQL_ERR"
    handle_access_denied "rds-db:connect (IAM 認証での DB 接続)"
    # スイッチバック後の認証情報でトークンを作り直して 1 回だけリトライ
    generate_iam_token
    [[ "$CLIENT" == "mysql" ]] && write_mysql_cnf
    rc=0
    exec_sql_once || rc=$?
  fi

  if [[ $rc -ne 0 ]]; then
    rm -f "$OUTPUT_FILE"
    die "SQL の実行に失敗しました (exit=${rc}): ${SQL_ERR}"
  fi
  [[ -n "$SQL_ERR" ]] && log_warn "クライアントからの警告: $SQL_ERR"

  local lines
  lines="$(wc -l < "$OUTPUT_FILE" | tr -d '[:space:]')"
  log_success "SQL を実行し、結果を保存しました: ${OUTPUT_FILE} (${lines} 行)"
  log_info "---- 結果の先頭 10 行 ----"
  head -n 10 "$OUTPUT_FILE"
  log_info "--------------------------"
}

# ---------------------------------------------------------------------------
# 13. メイン処理
# ---------------------------------------------------------------------------
main() {
  prepare_ca_bundle
  prepare_credentials
  prepare_sql_file
  if [[ "$CLIENT" == "java" ]]; then
    build_jdbc_url
  elif [[ "$DRY_RUN" != "true" ]]; then
    write_mysql_cnf
  fi
  run_sql
  log_success "メンテナンスジョブが完了しました"
}

main
