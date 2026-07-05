# EC2 (RHEL9) → RDS Proxy → Aurora Serverless v2 (Aurora MySQL 3 系) 接続ジョブ

EC2 の EBS 上に配置するメンテナンス系ジョブのサンプルです。RDS Proxy を経由して
Aurora Serverless v2 (Aurora MySQL 3 系 / MySQL 8.0 互換) へ接続し、SQL を実行して
結果を TSV ファイルとして EBS 上へ保存します。

## ファイル構成

| ファイル | 役割 |
|---|---|
| `rds-proxy-db-maintenance.sh` | 本体スクリプト（認証プラグイン・接続クライアントをパラメータで切替） |
| `common.sh` | 共通関数（ログ / AWS 認証チェック / 権限エラー判定など。CodeCommit_Git_branch_local_Create の common.sh がベース） |
| `switch-back.sh` | スイッチバック用スクリプトの雛形（別チーム提供のものに差し替え可能） |
| `java/JdbcSqlRunner.java` | `--client java` 用の JDBC 接続ランナー（MySQL Connector/J 使用・事前コンパイル不要） |
| `sql/nightly_maintenance_sample.sql` | メンテナンスジョブ用サンプル SQL |
| `lib/` | MySQL Connector/J の jar 置き場（`--client java` 用・自動探索対象） |
| `output/` | 実行結果 (TSV) の既定出力先（自動作成） |
| `certs/global-bundle.pem` | RDS CA バンドル（`--download-ca` 指定時に自動取得） |

## 前提

- RHEL 9 の EC2、MySQL 8.0 クライアント: `sudo dnf install mysql`
  - IAM 認証 (`--auth-plugin iam`) は `--enable-cleartext-plugin` が必要なため
    **MySQL クライアント必須**（MariaDB クライアント不可。スクリプトが検出して停止します）
- AWS CLI v2、（Secrets Manager の JSON 解析用に）`jq` または `python3`
- 実行前に `aws login --remote` で認証済みであること
  - スクリプト開始時に `sts get-caller-identity` でチェックし、未認証なら
    警告メッセージを表示して **終了コード 2** で終了します

## 認証方式（`--auth-plugin` で切替）

### 1. mysql_native_password（パスワード認証）

Aurora MySQL 3 系の既定プラグイン。RDS Proxy 側は `ClientPasswordAuthType =
MYSQL_NATIVE_PASSWORD`（既定）で受け付けます。TLS は必須ではありませんが、
本スクリプトは既定で `ssl-mode=REQUIRED` を設定します。

```bash
./rds-proxy-db-maintenance.sh \
  --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \
  --db-user batch_user --database appdb --region ap-northeast-1 \
  --auth-plugin mysql_native_password \
  --password-source secretsmanager --secret-id prod/appdb/batch_user
```

DB ユーザー作成例:

```sql
CREATE USER 'batch_user'@'%' IDENTIFIED WITH mysql_native_password BY '********';
```

### 2. caching_sha2_password（パスワード認証・TLS 強制）

MySQL 8.0 の標準的な既定プラグイン。安全な経路（TLS）が必要なため、本スクリプトは
TLS を強制します（`--ssl-ca` 指定時は `VERIFY_CA`、未指定時は `REQUIRED`）。
RDS Proxy 側は `ClientPasswordAuthType = MYSQL_CACHING_SHA2_PASSWORD` の設定が必要です。

```bash
./rds-proxy-db-maintenance.sh \
  --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \
  --db-user batch_user --database appdb --region ap-northeast-1 \
  --auth-plugin caching_sha2_password \
  --password-source secretsmanager --secret-id prod/appdb/batch_user \
  --download-ca
```

DB ユーザー作成例:

```sql
CREATE USER 'batch_user'@'%' IDENTIFIED WITH caching_sha2_password BY '********';
```

### 3. iam（パスワードレス / IAM 認証トークン）

パスワードを一切管理しない方式。`aws rds generate-db-auth-token` で 15 分有効の
トークンを生成し、パスワードの代わりに使います（TLS 必須・cleartext プラグイン使用）。

```bash
./rds-proxy-db-maintenance.sh \
  --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \
  --db-user iam_batch_user --database appdb --region ap-northeast-1 \
  --auth-plugin iam --download-ca \
  --sql-file ./sql/nightly_maintenance_sample.sql
```

必要な設定:

1. RDS Proxy の認証設定で `IAMAuth = REQUIRED`
2. EC2 のインスタンスプロファイル（またはスイッチ先ロール）に `rds-db:connect` 権限

   ```json
   {
     "Effect": "Allow",
     "Action": "rds-db:connect",
     "Resource": "arn:aws:rds-db:ap-northeast-1:<account-id>:dbuser:<proxy-resource-id>/iam_batch_user"
   }
   ```

   ※ RDS Proxy 経由の場合、Resource にはクラスタ ID ではなく **プロキシの
   リソース ID（`prx-` で始まる ID）** を指定します。

3. DB 側のユーザーは通常のパスワードユーザーで可（プロキシ→DB 間は Secrets Manager
   の認証情報が使われるため、`AWSAuthenticationPlugin` は不要）

## 接続クライアント（`--client` で切替）

### mysql（既定）

mysql コマンドラインクライアントで接続します。パスワードは権限 600 の一時
`defaults-extra-file` 経由で渡します。

### java（MySQL Connector/J = JDBC ドライバ経由）

シェルスクリプトから同梱の Java ランナー `java/JdbcSqlRunner.java` を起動し、
MySQL Connector/J (JDBC) で接続する方式です。mysql クライアントを EC2 に
インストールできない場合や、Java アプリと同じドライバ・同じ経路で接続確認
したい場合に使います。

- **仕組み**: Java 11+ の「シングルファイルソース起動」を使うため事前コンパイルは
  不要です。シェルが JDBC URL を組み立て、接続情報（URL / ユーザー / パスワード /
  SQL ファイルパス）を **環境変数** で Java プロセスへ渡します（コマンドライン
  引数にパスワードを載せない）。結果は Java 側が TSV で標準出力へ書き出し、
  シェルが出力ファイルへ保存します。
- **前提** (RHEL9):

  ```bash
  sudo dnf install java-17-openjdk-headless mysql-connector-j
  # または https://dev.mysql.com/downloads/connector/j/ から jar を取得して lib/ に配置
  ```

- **jar の探索順**: `--jdbc-driver <path>` → `./lib/mysql-connector-j*.jar` →
  `/usr/share/java/mysql-connector-j*.jar`
- **認証プラグインとの対応**: 3 方式すべて利用できます。
  - `mysql_native_password` / `caching_sha2_password`: Connector/J が自動で
    ネゴシエートします（TLS は URL の `sslMode=REQUIRED` で常時有効）
  - `iam`: トークンをパスワードとして渡すと、Connector/J が TLS 上で cleartext
    プラグインを使って送信します（mysql クライアントの
    `--enable-cleartext-plugin` 相当。MariaDB クライアント問題の回避策にもなる）
- **TLS の注意**: Connector/J は PEM の CA バンドル（global-bundle.pem）を直接
  読めないため、`--ssl-ca` は java クライアントでは使われません（暗号化のみの
  `sslMode=REQUIRED` で接続）。サーバ証明書の検証まで行う場合はトラストストアを
  作成し、`build_jdbc_url()` に `trustCertificateKeyStoreUrl` を追加してください:

  ```bash
  keytool -importcert -alias rds-ca -file certs/global-bundle.pem \
    -keystore certs/rds-truststore.p12 -storetype PKCS12 -storepass changeit -noprompt
  # URL 例: &sslMode=VERIFY_CA&trustCertificateKeyStoreUrl=file:certs/rds-truststore.p12
  #         &trustCertificateKeyStorePassword=changeit
  ```

実行例:

```bash
# JDBC ドライバ経由 + caching_sha2_password + Secrets Manager
./rds-proxy-db-maintenance.sh \
  --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \
  --db-user batch_user --database appdb --region ap-northeast-1 \
  --client java --jdbc-driver /usr/share/java/mysql-connector-j.jar \
  --auth-plugin caching_sha2_password \
  --password-source secretsmanager --secret-id prod/appdb/batch_user

# JDBC ドライバ経由 + IAM 認証 (パスワードレス)
./rds-proxy-db-maintenance.sh \
  --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \
  --db-user iam_batch_user --database appdb --region ap-northeast-1 \
  --client java --auth-plugin iam \
  --sql-file ./sql/nightly_maintenance_sample.sql
```

## パスワードの管理方法（`--password-source` で切替）

| 方式 | 指定 | 用途 / 注意 |
|---|---|---|
| Secrets Manager（**推奨**） | `--password-source secretsmanager --secret-id <id>` | ローテーション可能・監査可能。SecretString は JSON（`.password` キー）でも平文でも可 |
| 環境変数 | `--password-source env` + `DB_PASSWORD=...` | cron 等での一時利用向け。プロセス環境に残る点に注意 |
| ファイル | `--password-source file --password-file <path>` | EBS 上に `chmod 600` で配置。600/400 以外だと警告 |

いずれの方式でも、パスワードは **コマンドライン引数には載せず**、権限 600 の
一時 `defaults-extra-file` 経由で mysql クライアントへ渡します（`ps` からの漏えい防止）。
一時ファイルは trap で必ず削除されます。

## AWS 権限不足時のスイッチバック

このジョブは CodeCommit の操作は不要ですが、Secrets Manager / RDS への操作権限が
必要です。スイッチロールしたまま（CodeCommit 用ロール等）実行して権限不足
（AccessDenied）を検出した場合の動作:

- **既定**: スイッチバックを促す警告メッセージを表示して **終了コード 3** で終了

  ```text
  [ERROR] スイッチロールしたままの可能性があります。スイッチバックしてから再実行してください:
  [ERROR]   source /opt/iam/switch-back.sh
  ```

- **`--auto-switch-back` 指定時**: 別チーム提供のスイッチバック用シェルを `source`
  して自動でスイッチバックし、処理を **1 回だけ** リトライ

スイッチバック用シェルの配置場所は次のいずれかで指定します（優先順位順）:

1. `--switch-back-script /opt/iam/switch-back.sh`
2. 環境変数 `SWITCH_BACK_SCRIPT=/opt/iam/switch-back.sh`
3. 既定: スクリプトと同階層の `./switch-back.sh`（同梱の雛形）

## cron からの実行例（メンテナンスジョブ）

```cron
# 毎日 02:00 に IAM 認証で夜間メンテナンス SQL を実行（自動スイッチバック有効）
0 2 * * * /data/jobs/rds-proxy-db-maintenance.sh \
  --proxy-endpoint my-proxy.proxy-xxxx.ap-northeast-1.rds.amazonaws.com \
  --db-user iam_batch_user --database appdb --region ap-northeast-1 \
  --auth-plugin iam --download-ca \
  --sql-file /data/jobs/sql/nightly_maintenance_sample.sql \
  --output-file /data/jobs/output/nightly_$(date +\%Y\%m\%d).tsv \
  --auto-switch-back --switch-back-script /opt/iam/switch-back.sh \
  >> /data/jobs/log/nightly_maintenance.log 2>&1
```

## 終了コード

| コード | 意味 |
|---|---|
| 0 | 成功 |
| 1 | エラー（引数不正・SQL 実行失敗など） |
| 2 | AWS 未認証（`aws login --remote` が未実行） |
| 3 | AWS 権限不足（スイッチバックが必要） |
