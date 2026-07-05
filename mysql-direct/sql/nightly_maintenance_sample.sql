-- =========================================================================
-- nightly_maintenance_sample.sql (MySQL 直結版)
-- メンテナンス系ジョブから MySQL 8.0 / 8.4 に対して実行する SQL のサンプル。
-- mysql-db-maintenance.sh の --sql-file で指定して使う。
--   例: --sql-file sql/nightly_maintenance_sample.sql
-- 結果は --batch (TSV) で出力ファイルへ保存される。
-- ※ Aurora 版との違い: @@aurora_version は存在しないため @@version_comment を使用。
-- =========================================================================

-- 1. 接続確認: 実行時刻・接続ユーザー・サーバ情報
SELECT NOW()              AS executed_at,
       CURRENT_USER()     AS connected_as,
       @@hostname         AS server_hostname,
       @@version          AS mysql_version,
       @@version_comment  AS version_comment;

-- 2. 現在の接続数
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
--    検証環境の appdb.job_history に合わせてある。実環境ではテーブル名を合わせること。
-- DELETE FROM job_history
--  WHERE created_at < NOW() - INTERVAL 90 DAY
--  LIMIT 10000;
-- SELECT ROW_COUNT() AS deleted_rows;
