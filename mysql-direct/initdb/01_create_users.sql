-- =========================================================================
-- 01_create_users.sql
-- MySQL 8.0 / 8.4 コンテナの初回起動時に実行される初期化スクリプト。
-- mysql-db-maintenance.sh の検証用に、認証プラグインの異なる 2 ユーザーと
-- サンプルテーブルを作成する。
--   native_user : mysql_native_password (8.4 では mysql_native_password=ON が前提)
--   sha2_user   : caching_sha2_password (8.0 / 8.4 の既定プラグイン)
-- ※ パスワードは検証環境専用。実環境ではこのファイルごと差し替えること。
-- =========================================================================

CREATE USER IF NOT EXISTS 'native_user'@'%'
  IDENTIFIED WITH mysql_native_password BY 'NativePass123!';

CREATE USER IF NOT EXISTS 'sha2_user'@'%'
  IDENTIFIED WITH caching_sha2_password BY 'Sha2Pass123!';

GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'native_user'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON appdb.* TO 'sha2_user'@'%';

-- サンプルテーブル (組み込みサンプル SQL の「テーブルサイズ上位」で表示される)
CREATE TABLE IF NOT EXISTS appdb.job_history (
  id         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  job_name   VARCHAR(100)    NOT NULL,
  status     VARCHAR(20)     NOT NULL,
  created_at DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE = InnoDB;

INSERT INTO appdb.job_history (job_name, status, created_at) VALUES
  ('nightly_maintenance', 'SUCCESS', NOW() - INTERVAL 2 DAY),
  ('nightly_maintenance', 'SUCCESS', NOW() - INTERVAL 1 DAY),
  ('nightly_maintenance', 'RUNNING', NOW());

FLUSH PRIVILEGES;
