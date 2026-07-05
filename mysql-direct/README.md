# EC2 (RHEL9) → MySQL 8.0 / 8.4 直接続ジョブ + コンテナ検証環境

`rds-proxy-db-maintenance.sh`（RDS Proxy + Aurora Serverless v2 版）の **MySQL 直接続版** です。
共通部品 `common.sh` と JDBC ランナー `java/JdbcSqlRunner.java` はリポジトリ直下のものを共用し、
MySQL 8.0 / MySQL 8.4 のサーバへ直接接続して SQL を実行、結果を TSV ファイルへ保存します。

あわせて、動作検証用のコンテナ環境（`compose.yml`）を同梱しています:

| サービス | 内容 |
|---|---|
| `rhel9` | EC2 (RHEL 9) 相当のクライアント。**AlmaLinux 9**（RHEL 9 バイナリ互換・無償）に mysql クライアント / Java 17 / MySQL Connector/J を導入 |
| `mysql80` | 接続先の MySQL 8.0 サーバ |
| `mysql84` | 接続先の MySQL 8.4 サーバ（`mysql_native_password=ON` で起動） |

## ファイル構成

| ファイル | 役割 |
|---|---|
| `mysql-db-maintenance.sh` | 本体スクリプト（認証プラグイン・接続クライアントをパラメータで切替） |
| `verify-connections.sh` | rhel9 コンテナ内で 8 パターン（8.0/8.4 × native/sha2 × mysql/java）の接続を総当たり検証 |
| `compose.yml` | 検証環境（rhel9 / mysql80 / mysql84） |
| `docker/rhel9/Dockerfile` | RHEL9 相当クライアントコンテナのビルド定義 |
| `initdb/01_create_users.sql` | MySQL 初回起動時の検証用ユーザー・サンプルテーブル作成 |
| `sql/nightly_maintenance_sample.sql` | メンテナンスジョブ用サンプル SQL（MySQL 直結版） |
| `../common.sh` | 共通関数（Aurora / RDS Proxy 版と共用） |
| `../java/JdbcSqlRunner.java` | `--client java` 用 JDBC ランナー（Aurora / RDS Proxy 版と共用） |
| `output/` | 実行結果 (TSV) の既定出力先（自動作成） |

## Aurora / RDS Proxy 版との違い

- 接続先が RDS Proxy ではなく MySQL サーバ直結（`--proxy-endpoint` → `--host`）
- AWS 固有機能（Secrets Manager / IAM 認証トークン / `aws login` チェック / スイッチバック）は
  直結 MySQL では使わないため **なし**。パスワードは `env`（環境変数 `DB_PASSWORD`）または
  `file`（`--password-file`）から取得
- `--ssl-mode` を明示指定可能（既定 `PREFERRED`。`--ssl-ca` 指定時は `VERIFY_CA`）
- `caching_sha2_password` で TLS が無い経路の場合は RSA 公開鍵取得
  （mysql: `get-server-public-key` / Connector/J: `allowPublicKeyRetrieval=true`）を自動設定
- 組み込みサンプル SQL は `@@aurora_version` の代わりに `@@version_comment` を使用

## コンテナでの動作検証

前提: Docker (Docker Desktop など) + docker compose v2

```bash
cd mysql-direct

# 1. 起動 (mysql80 / mysql84 が healthy になるまで待ってから rhel9 が起動する)
docker compose up -d --build

# 2. 8 パターンの接続検証を一括実行
docker compose exec rhel9 ./verify-connections.sh

# 3. 個別実行の例 (MySQL 8.4 へ caching_sha2_password + JDBC で接続)
docker compose exec -e DB_PASSWORD='Sha2Pass123!' rhel9 \
  ./mysql-db-maintenance.sh --host mysql84 --db-user sha2_user \
  --database appdb --auth-plugin caching_sha2_password --client java

# 4. 後片付け
docker compose down -v
```

`rhel9` コンテナにはリポジトリのルートが `/work` にマウントされるため、
`common.sh` / `java/JdbcSqlRunner.java` は EC2 実機と同じ相対配置で参照されます。
実行結果 (TSV) はホスト側の `mysql-direct/output/` にそのまま残ります。

検証用ユーザー（`initdb/01_create_users.sql` で作成。パスワードは検証環境専用）:

| ユーザー | 認証プラグイン | パスワード |
|---|---|---|
| `native_user` | `mysql_native_password` | `NativePass123!` |
| `sha2_user` | `caching_sha2_password` | `Sha2Pass123!` |

> MySQL 8.4 では `mysql_native_password` が既定で無効のため、`compose.yml` で
> `mysqld --mysql-native-password=ON` を付けて起動しています（MySQL 9.0 以降は削除済みのため不可）。

## 実機 (EC2 RHEL9) での使い方

```bash
# 前提パッケージ
sudo dnf install mysql                            # --client mysql 用
sudo dnf install java-17-openjdk-headless         # --client java 用
# Connector/J は lib/ に配置するか --jdbc-driver で指定

# 1) mysql_native_password + 環境変数パスワード
DB_PASSWORD='********' ./mysql-db-maintenance.sh \
  --host db.example.internal --db-user batch_user --database appdb \
  --auth-plugin mysql_native_password

# 2) caching_sha2_password + パスワードファイル + TLS 必須
./mysql-db-maintenance.sh \
  --host db.example.internal --db-user batch_user --database appdb \
  --auth-plugin caching_sha2_password \
  --password-source file --password-file /data/secret/db_password.txt \
  --ssl-mode REQUIRED

# 3) サーバ証明書検証 (CA を指定すると VERIFY_CA)
DB_PASSWORD='********' ./mysql-db-maintenance.sh \
  --host db.example.internal --db-user batch_user --database appdb \
  --ssl-ca /etc/pki/tls/certs/db-ca.pem

# 4) JDBC (MySQL Connector/J) 経由 + 独自 SQL
DB_PASSWORD='********' ./mysql-db-maintenance.sh \
  --host db.example.internal --db-user batch_user --database appdb \
  --client java --jdbc-driver /usr/share/java/mysql-connector-j.jar \
  --sql-file sql/nightly_maintenance_sample.sql
```

終了コード: `0` 成功 / `1` エラー（引数不正・接続失敗・SQL 実行失敗など）

### 補足: `--client java` でサーバ証明書まで検証する場合

Connector/J は PEM の CA を直接読めないため、keytool でトラストストアを作成し
JDBC URL に `trustCertificateKeyStoreUrl` を追加してください:

```bash
keytool -importcert -alias db-ca -file db-ca.pem \
  -keystore truststore.p12 -storetype PKCS12 -storepass changeit -noprompt
```
