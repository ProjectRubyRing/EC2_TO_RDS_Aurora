-- =========================================================================
-- nightly_maintenance_sample.sql
-- メンテナンス系ジョブから RDS Proxy 経由で実行する SQL のサンプル。
-- rds-proxy-db-maintenance.sh の --sql-file で指定して使う。
--   例: --sql-file /data/jobs/sql/nightly_maintenance_sample.sql
-- 結果は --batch (TSV) で出力ファイルへ保存される。
-- =========================================================================

-- 1. 接続確認: 実行時刻・接続ユーザー・サーバ情報
SELECT NOW()            AS executed_at,
       CURRENT_USER()   AS connected_as,
       @@hostname       AS server_hostname,
       @@version        AS mysql_version,
       @@aurora_version AS aurora_version;

-- 2. 現在の接続数 (RDS Proxy の多重化状況の確認)
SELECT COUNT(*) AS current_connections
  FROM information_schema.processlist;

-- 3. ユーザーテーブルのサイズ上位 20 (肥大化監視)
SELECT table_schema,
       table_name,
       table_rows,
       ROUND((data_length + index_length) / 1024 / 1024, 2) AS size_mb,
       ROUND(data_free / 1024 / 1024, 2)                    AS free_mb
  FROM information_schema.tables
 WHERE table_schema NOT IN ('mysql', 'sys', 'information_schema', 'performance_schema')
 ORDER BY (data_length + index_length) DESC
 LIMIT 20;

-- 4. (例) 古いジョブ履歴の削除 — 更新系メンテナンスの例。
--    実際に使う場合はテーブル名を合わせてコメントを外すこと。
-- DELETE FROM job_history
--  WHERE created_at < NOW() - INTERVAL 90 DAY
--  LIMIT 10000;
-- SELECT ROW_COUNT() AS deleted_rows;
