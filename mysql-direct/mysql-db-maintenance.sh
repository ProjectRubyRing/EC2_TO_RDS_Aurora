#!/usr/bin/env bash
#
# mysql-db-maintenance.sh
# =======================
# EC2 (RHEL 9) 上の EBS に配置したメンテナンス系ジョブから、MySQL サーバ
# (MySQL 8.0 / MySQL 8.4) へ「直接」接続し、SQL を実行して結果を EBS 上の
# ファイル (TSV) へ保存するスクリプトです。
#
# rds-proxy-db-maintenance.sh (RDS Proxy + Aurora Serverless v2 版) の直結 MySQL 版で、
# 共通部品 common.sh を共用します。AWS 固有の機能 (Secrets Manager / IAM 認証 /
# スイッチバック) は、直結 MySQL では使わないため本スクリプトには含まれません。
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
#   mysql_native_password   : パスワード認証（MySQL 8.0 以前の従来プラグイン。
#                             MySQL 8.4 では既定で無効のため、サーバ側で
#                             mysql_native_password=ON が必要）。
#   caching_sha2_password   : パスワード認証（MySQL 8.0 / 8.4 の既定プラグイン）。
#                             TLS が無い経路では RSA 公開鍵で保護される
#                             (get-server-public-key / allowPublicKeyRetrieval)。
#
# パスワードの取得元（--password-source で切り替え）:
#   env  : 環境変数 DB_PASSWORD から取得（既定。cron 等での利用向け）。
#   file : --password-file で指定したファイル（EBS 上, 権限 600 推奨）の
#          1 行目をパスワードとして使用。
#   ※ いずれの場合もパスワードはコマンドライン引数に載せず、mktemp で作成した
#      一時 defaults-extra-file (権限 600) 経由で mysql クライアントへ渡します
#      （ps コマンド等からの漏えい防止）。一時ファイルは終了時に必ず削除します。
#
# 処理の流れ:
#   1. 引数解析・前提コマンド確認 (mysql / java)
#   2. パスワードの準備 (env or file)
#   3. 一時 defaults-extra-file を作成して mysql で SQL を実行
#      (--client java の場合は JDBC URL を組み立てて Java ランナーで実行)
#   4. 結果 (TSV) を EBS 上の出力ファイルへ保存し、サマリを表示
#
# 依存: bash
#       --client mysql : mysql (MySQL 8.0 クライアント推奨。RHEL9: `sudo dnf install mysql`)
#       --client java  : java 11+ (RHEL9: `sudo dnf install java-17-openjdk-headless`) と
#                        MySQL Connector/J の jar
# 共通部品: common.sh (このディレクトリ、または 1 つ上のディレクトリから読み込み)
#
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 0. 共通部品(common.sh)の読み込み
#    Aurora / RDS Proxy 版と共通のものを使う。同じディレクトリに無ければ
#    リポジトリ直下 (1 つ上のディレクトリ) を探す。
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

COMMON_SH=""
for candidate in "${SCRIPT_DIR}/common.sh" "${SCRIPT_DIR}/../common.sh"; do
  if [[ -f "$candidate" ]]; then
    COMMON_SH="$candidate"
    break
  fi
done
if [[ -z "$COMMON_SH" ]]; then
  echo "[${SCRIPT_NAME}][ERROR] common.sh が見つかりません: ${SCRIPT_DIR}/common.sh または ${SCRIPT_DIR}/../common.sh" >&2
  exit 1
fi
# shellcheck source=../common.sh
source "$COMMON_SH"

# ---------------------------------------------------------------------------
# 1. 既定値
# ---------------------------------------------------------------------------
DB_HOST=""                               # MySQL サーバのホスト名 (必須)
PORT="3306"                              # 接続ポート
DB_USER=""                               # DB ユーザー名 (必須)
DATABASE=""                              # 接続先データベース名 (任意)

CLIENT="mysql"                           # mysql | java (接続に使うクライアント)
JDBC_DRIVER=""                           # MySQL Connector/J の jar パス (--client java 用)
JDBC_URL=""                              # 組み立てた JDBC 接続 URL (内部使用)

# JDBC 接続用 Java ランナー (Aurora / RDS Proxy 版と共通のものを使う)
JAVA_RUNNER=""
for candidate in "${SCRIPT_DIR}/java/JdbcSqlRunner.java" "${SCRIPT_DIR}/../java/JdbcSqlRunner.java"; do
  if [[ -f "$candidate" ]]; then
    JAVA_RUNNER="$candidate"
    break
  fi
done

AUTH_PLUGIN="mysql_native_password"      # mysql_native_password | caching_sha2_password
PASSWORD_SOURCE="env"                    # env | file
PASSWORD_FILE=""                         # パスワードファイル (EBS 上, 600 推奨)

SSL_MODE="PREFERRED"                     # DISABLED | PREFERRED | REQUIRED | VERIFY_CA
SSL_CA=""                                # サーバ証明書検証用の CA ファイル (PEM)

SQL_FILE=""                              # 実行する SQL ファイル (EBS 上)
SQL_TEXT=""                              # 実行する SQL 文字列 (--sql)
OUTPUT_FILE=""                           # 結果出力先。未指定なら OUTPUT_DIR に自動命名
OUTPUT_DIR="${SCRIPT_DIR}/output"        # 既定の出力ディレクトリ (EBS 上)

CONNECT_TIMEOUT="10"                     # mysql 接続タイムアウト(秒)
DRY_RUN="false"                          # true なら接続せず実行内容の表示のみ
DEBUG="${DEBUG:-false}"
export DEBUG

MYSQL_CNF=""                             # 一時 defaults-extra-file (trap で削除)
TMP_SQL_FILE=""                          # 組み込みサンプル SQL の一時ファイル

# ---------------------------------------------------------------------------
# 2. 使い方
# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<USAGE
使い方:
  ${SCRIPT_NAME} --host <host> --db-user <user> [オプション]

説明:
  MySQL サーバ (MySQL 8.0 / 8.4) へ直接接続し、SQL を実行して結果を TSV ファイルへ
  保存します。認証プラグイン・接続クライアントはパラメータで切り替えられます。

必須:
  --host <host>             MySQL サーバのホスト名または IP
                            (例: mysql80 / db.example.internal)
  --db-user <user>          接続する DB ユーザー名

認証方式:
  --auth-plugin <plugin>    mysql_native_password (既定) | caching_sha2_password
                              mysql_native_password : 従来のパスワード認証
                                (MySQL 8.4 ではサーバ側 mysql_native_password=ON が必要)
                              caching_sha2_password : MySQL 8.0 / 8.4 の既定プラグイン

接続クライアント:
  --client <client>         mysql (既定) | java
                              mysql : mysql コマンドラインクライアントで接続
                              java  : MySQL Connector/J (JDBC) + 同梱 Java ランナー
                                      (java/JdbcSqlRunner.java) で接続。Java 11+ 必須
  --jdbc-driver <path>      MySQL Connector/J の jar パス (--client java のとき使用。
                            未指定なら ${SCRIPT_DIR}/lib/ と /usr/share/java/ から
                            mysql-connector-j*.jar を自動探索)

パスワード取得元:
  --password-source <src>   env (既定) | file
  --password-file <path>    パスワードファイル (--password-source file のとき必須。
                            EBS 上に権限 600 で配置すること)
                            ※ env の場合は環境変数 DB_PASSWORD を使用

接続オプション:
  --port <port>             接続ポート (既定: 3306)
  --database <name>         接続先データベース名
  --ssl-mode <mode>         DISABLED | PREFERRED (既定) | REQUIRED | VERIFY_CA
  --ssl-ca <path>           サーバ証明書検証用の CA ファイル (PEM)。
                            指定すると --ssl-mode は VERIFY_CA になる
  --connect-timeout <sec>   mysql 接続タイムアウト (既定: 10)

SQL / 出力:
  --sql-file <path>         実行する SQL ファイル (EBS 上)
  --sql "<SQL>"             実行する SQL 文字列 (--sql-file と排他)
                            ※ どちらも未指定なら組み込みのメンテナンス用サンプル SQL
                              (接続情報確認 + テーブルサイズ上位 20) を実行
  --output-file <path>      結果 (TSV) の出力先 (既定: ${OUTPUT_DIR}/
                            maintenance_<host>_YYYYmmdd_HHMMSS.tsv)

その他:
  --dry-run                 DB へは接続せず、実行内容の表示のみ
  --debug                   デバッグログを出力する
  -h, --help                このヘルプを表示

環境変数:
  DB_PASSWORD               --password-source env のときに使用するパスワード

例:
  # 1) MySQL 8.0 へ mysql_native_password で接続 (パスワードは環境変数)
  DB_PASSWORD='********' ./${SCRIPT_NAME} \\
    --host mysql80 --db-user native_user --database appdb \\
    --auth-plugin mysql_native_password

  # 2) MySQL 8.4 へ caching_sha2_password で接続
  DB_PASSWORD='********' ./${SCRIPT_NAME} \\
    --host mysql84 --db-user sha2_user --database appdb \\
    --auth-plugin caching_sha2_password

  # 3) パスワードファイル + 独自 SQL + TLS 必須
  ./${SCRIPT_NAME} \\
    --host mysql80 --db-user batch_user --database appdb \\
    --password-source file --password-file /data/secret/db_password.txt \\
    --ssl-mode REQUIRED --sql-file /data/jobs/sql/nightly_maintenance.sql

  # 4) MySQL Connector/J (JDBC ドライバ) 経由で接続
  DB_PASSWORD='********' ./${SCRIPT_NAME} \\
    --host mysql84 --db-user sha2_user --database appdb \\
    --client java --auth-plugin caching_sha2_password

終了コード:
  0  成功
  1  エラー (引数不正・接続失敗・SQL 実行失敗など)
USAGE
}

# ---------------------------------------------------------------------------
# 3. 引数解析
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)                DB_HOST="${2:?--host に値がありません}"; shift 2 ;;
    --port)                PORT="${2:?--port に値がありません}"; shift 2 ;;
    --db-user)             DB_USER="${2:?--db-user に値がありません}"; shift 2 ;;
    --database)            DATABASE="${2:?--database に値がありません}"; shift 2 ;;
    --auth-plugin)         AUTH_PLUGIN="${2:?--auth-plugin に値がありません}"; shift 2 ;;
    --client)              CLIENT="${2:?--client に値がありません}"; shift 2 ;;
    --jdbc-driver)         JDBC_DRIVER="${2:?--jdbc-driver に値がありません}"; shift 2 ;;
    --password-source)     PASSWORD_SOURCE="${2:?--password-source に値がありません}"; shift 2 ;;
    --password-file)       PASSWORD_FILE="${2:?--password-file に値がありません}"; shift 2 ;;
    --ssl-mode)            SSL_MODE="${2:?--ssl-mode に値がありません}"; shift 2 ;;
    --ssl-ca)              SSL_CA="${2:?--ssl-ca に値がありません}"; shift 2 ;;
    --sql-file)            SQL_FILE="${2:?--sql-file に値がありません}"; shift 2 ;;
    --sql)                 SQL_TEXT="${2:?--sql に値がありません}"; shift 2 ;;
    --output-file)         OUTPUT_FILE="${2:?--output-file に値がありません}"; shift 2 ;;
    --connect-timeout)     CONNECT_TIMEOUT="${2:?--connect-timeout に値がありません}"; shift 2 ;;
    --dry-run)             DRY_RUN="true"; shift ;;
    --debug)               DEBUG="true"; shift ;;
    -h | --help)           usage; exit 0 ;;
    *)                     log_error "不明な引数です: $1"; usage; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# 4. 入力検証・前提確認
# ---------------------------------------------------------------------------
[[ -n "$DB_HOST" ]] || { log_error "--host は必須です"; usage; exit 1; }
[[ -n "$DB_USER" ]] || { log_error "--db-user は必須です"; usage; exit 1; }

case "$AUTH_PLUGIN" in
  mysql_native_password | caching_sha2_password) ;;
  *) die "--auth-plugin は mysql_native_password / caching_sha2_password のいずれかを指定してください: $AUTH_PLUGIN" ;;
esac

case "$PASSWORD_SOURCE" in
  env)
    [[ -n "${DB_PASSWORD:-}" ]] || die "--password-source env の場合は環境変数 DB_PASSWORD を設定してください"
    ;;
  file)
    [[ -n "$PASSWORD_FILE" ]] || die "--password-source file の場合は --password-file が必須です"
    [[ -f "$PASSWORD_FILE" ]] || die "パスワードファイルが見つかりません: $PASSWORD_FILE"
    ;;
  *) die "--password-source は env / file のいずれかを指定してください: $PASSWORD_SOURCE" ;;
esac

# --ssl-ca が指定されたらサーバ証明書を検証する
[[ -n "$SSL_CA" ]] && SSL_MODE="VERIFY_CA"
case "$SSL_MODE" in
  DISABLED | PREFERRED | REQUIRED | VERIFY_CA) ;;
  *) die "--ssl-mode は DISABLED / PREFERRED / REQUIRED / VERIFY_CA のいずれかを指定してください: $SSL_MODE" ;;
esac
[[ -n "$SSL_CA" && ! -f "$SSL_CA" ]] && die "CA ファイルが見つかりません: $SSL_CA"

[[ -n "$SQL_FILE" && -n "$SQL_TEXT" ]] && die "--sql-file と --sql は同時に指定できません"
[[ -n "$SQL_FILE" && ! -f "$SQL_FILE" ]] && die "SQL ファイルが見つかりません: $SQL_FILE"

case "$CLIENT" in
  mysql | java) ;;
  *) die "--client は mysql / java のいずれかを指定してください: $CLIENT" ;;
esac

MYSQL_IS_MARIADB="false"
if [[ "$CLIENT" == "mysql" ]]; then
  require_command mysql

  # mysql クライアントの種別を確認 (RHEL9 では mariadb が mysql として入っている場合がある)
  if mysql --version 2>/dev/null | grep -qi mariadb; then
    MYSQL_IS_MARIADB="true"
  fi
  log_debug "mysql クライアント: $(mysql --version 2>/dev/null) (MariaDB: ${MYSQL_IS_MARIADB})"

  if [[ "$AUTH_PLUGIN" == "caching_sha2_password" && "$MYSQL_IS_MARIADB" == "true" ]]; then
    log_warn "MariaDB クライアントを検出しました。caching_sha2_password は新しめの MariaDB クライアントでのみ動作します。問題が出る場合は MySQL 8.0 クライアントか --client java を使用してください。"
  fi
else
  # --client java : Java 11+ (シングルファイルソース起動) と Connector/J jar が必要
  require_command java
  [[ -n "$JAVA_RUNNER" && -f "$JAVA_RUNNER" ]] \
    || die "JDBC 接続用 Java ランナーが見つかりません: ${SCRIPT_DIR}/java/JdbcSqlRunner.java または ${SCRIPT_DIR}/../java/JdbcSqlRunner.java"

  if [[ -z "$JDBC_DRIVER" ]]; then
    # Connector/J の jar を既定の場所から自動探索する
    for candidate in \
      "${SCRIPT_DIR}"/lib/mysql-connector-j*.jar \
      "${SCRIPT_DIR}"/../lib/mysql-connector-j*.jar \
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
# 6. パスワードの準備 (env or file)
# ---------------------------------------------------------------------------
DB_PASS=""

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

prepare_credentials() {
  case "$PASSWORD_SOURCE" in
    env)  DB_PASS="$DB_PASSWORD"; log_info "環境変数 DB_PASSWORD からパスワードを使用します" ;;
    file) get_password_from_file ;;
  esac
}

# ---------------------------------------------------------------------------
# 7. mysql 用 一時 defaults-extra-file の作成
#    パスワードをコマンドラインに載せない (ps から見えない) ようにするため、
#    権限 600 の一時ファイルへ書き出して --defaults-extra-file で渡す。
# ---------------------------------------------------------------------------
write_mysql_cnf() {
  local old_umask
  old_umask="$(umask)"
  umask 077
  if [[ -z "$MYSQL_CNF" ]]; then
    MYSQL_CNF="$(mktemp "${TMPDIR:-/tmp}/mysql_direct.XXXXXX")"
  fi

  # my.cnf 形式では password="..." とし、" と \ をエスケープする
  local esc_pass
  esc_pass="${DB_PASS//\\/\\\\}"
  esc_pass="${esc_pass//\"/\\\"}"

  {
    echo "[client]"
    echo "host=${DB_HOST}"
    echo "port=${PORT}"
    echo "user=${DB_USER}"
    echo "password=\"${esc_pass}\""
    echo "connect-timeout=${CONNECT_TIMEOUT}"

    # --- 認証プラグイン別の設定 ---
    if [[ "$MYSQL_IS_MARIADB" == "false" ]]; then
      echo "default-auth=${AUTH_PLUGIN}"
      if [[ "$AUTH_PLUGIN" == "caching_sha2_password" ]]; then
        # TLS の無い経路では RSA 公開鍵をサーバから取得してパスワードを保護する
        echo "get-server-public-key"
      fi
    fi

    # --- TLS 設定 ---
    if [[ "$MYSQL_IS_MARIADB" == "true" ]]; then
      # MariaDB クライアントは ssl-mode 非対応
      case "$SSL_MODE" in
        VERIFY_CA)
          echo "ssl-ca=${SSL_CA}"
          echo "ssl-verify-server-cert"
          ;;
        REQUIRED)
          echo "ssl"
          ;;
      esac
    else
      echo "ssl-mode=${SSL_MODE}"
      [[ "$SSL_MODE" == "VERIFY_CA" ]] && echo "ssl-ca=${SSL_CA}"
    fi
  } > "$MYSQL_CNF"

  umask "$old_umask"
  log_debug "defaults-extra-file を作成しました: $MYSQL_CNF"
}

# ---------------------------------------------------------------------------
# 7-2. JDBC 接続 URL の組み立て (--client java 用)
#      パスワードは URL に含めず、環境変数 DB_PASS で Java 側へ渡す。
# ---------------------------------------------------------------------------
build_jdbc_url() {
  local props ssl_mode_jdbc
  ssl_mode_jdbc="$SSL_MODE"

  if [[ "$SSL_MODE" == "VERIFY_CA" ]]; then
    # Connector/J は PEM の CA を直接は読めない (JKS/PKCS12 トラストストアが必要)。
    # サーバ証明書の検証まで行いたい場合は keytool でトラストストアを作成し、
    # trustCertificateKeyStoreUrl を URL に追加すること (README 参照)。
    log_warn "--client java では --ssl-ca (PEM) は使用されません (暗号化のみの sslMode=REQUIRED で接続します)"
    ssl_mode_jdbc="REQUIRED"
  fi

  # allowMultiQueries : SQL ファイル内の複数ステートメントを 1 回で実行するため
  props="allowMultiQueries=true"
  props+="&connectTimeout=$((CONNECT_TIMEOUT * 1000))"
  props+="&socketTimeout=0"
  props+="&sslMode=${ssl_mode_jdbc}"
  props+="&tcpKeepAlive=true"

  if [[ "$AUTH_PLUGIN" == "caching_sha2_password" && "$ssl_mode_jdbc" != "REQUIRED" ]]; then
    # TLS の無い経路で caching_sha2_password の初回認証を通すため、
    # サーバから RSA 公開鍵を取得する (検証環境向け。TLS があれば不要)
    props+="&allowPublicKeyRetrieval=true"
  fi

  JDBC_URL="jdbc:mysql://${DB_HOST}:${PORT}/${DATABASE}?${props}"
  log_debug "JDBC URL: $JDBC_URL"
}

# ---------------------------------------------------------------------------
# 8. 実行する SQL の決定 (未指定なら組み込みのメンテナンス用サンプル)
# ---------------------------------------------------------------------------
prepare_sql_file() {
  if [[ -n "$SQL_FILE" ]]; then
    return 0
  fi
  TMP_SQL_FILE="$(mktemp "${TMPDIR:-/tmp}/mysql_direct_maintenance_sql.XXXXXX")"
  if [[ -n "$SQL_TEXT" ]]; then
    printf '%s\n' "$SQL_TEXT" > "$TMP_SQL_FILE"
  else
    log_info "SQL が未指定のため、組み込みのメンテナンス用サンプル SQL を実行します"
    cat > "$TMP_SQL_FILE" <<'SQL'
-- メンテナンスジョブ サンプル 1: 接続確認 (どこに・誰で・どのプラグインでつながったか)
SELECT NOW()              AS executed_at,
       CURRENT_USER()     AS connected_as,
       @@hostname         AS server_hostname,
       @@version          AS mysql_version,
       @@version_comment  AS version_comment;

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
# 9. SQL 実行と結果取得
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
  local rc host_slug

  if [[ -z "$OUTPUT_FILE" ]]; then
    mkdir -p "$OUTPUT_DIR"
    host_slug="$(printf '%s' "$DB_HOST" | tr -c 'A-Za-z0-9' '_')"
    OUTPUT_FILE="${OUTPUT_DIR}/maintenance_${host_slug}_$(date +%Y%m%d_%H%M%S).tsv"
  else
    mkdir -p "$(dirname "$OUTPUT_FILE")"
  fi

  log_info "MySQL へ接続し SQL を実行します"
  log_info "  endpoint    : ${DB_HOST}:${PORT}"
  log_info "  user        : ${DB_USER}"
  log_info "  database    : ${DATABASE:-（未指定）}"
  log_info "  auth-plugin : ${AUTH_PLUGIN}"
  log_info "  ssl-mode    : ${SSL_MODE}"
  log_info "  client      : ${CLIENT}$( [[ "$CLIENT" == "java" ]] && printf ' (Connector/J: %s)' "$JDBC_DRIVER" )"
  log_info "  sql-file    : ${SQL_FILE}"
  log_info "  output-file : ${OUTPUT_FILE}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "(dry-run のため接続・SQL 実行はスキップします)"
    return 0
  fi

  rc=0
  exec_sql_once || rc=$?

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
# 10. メイン処理
# ---------------------------------------------------------------------------
main() {
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
