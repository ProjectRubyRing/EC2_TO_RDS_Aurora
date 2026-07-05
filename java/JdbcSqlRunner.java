import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;

/**
 * JdbcSqlRunner
 * =============
 * MySQL Connector/J (JDBC) で RDS Proxy 経由の Aurora MySQL へ接続し、
 * SQL ファイルを実行して結果を TSV 形式で標準出力へ書き出すランナー。
 * rds-proxy-db-maintenance.sh の --client java から呼び出される。
 *
 * 接続情報はコマンドライン引数に載せず、すべて環境変数で受け取る
 * (ps コマンド等からの漏えい防止):
 *   JDBC_URL : 接続 URL (例: jdbc:mysql://proxy:3306/appdb?sslMode=REQUIRED&...)
 *   DB_USER  : 接続ユーザー名
 *   DB_PASS  : パスワード (IAM 認証の場合は認証トークン)
 *   SQL_FILE : 実行する SQL ファイルのパス
 *
 * 実行方法 (Java 11+ のシングルファイルソース起動。事前コンパイル不要):
 *   java -cp /path/to/mysql-connector-j-x.y.z.jar JdbcSqlRunner.java
 *
 * 認証プラグインとの関係:
 *   - mysql_native_password : Connector/J が自動でネゴシエートする
 *   - caching_sha2_password : TLS (sslMode=REQUIRED 以上) があれば自動で動作する
 *   - IAM 認証トークン      : サーバ側の要求に応じて cleartext プラグインで送信される
 *                             (TLS 必須。URL 側で sslMode=REQUIRED を指定すること)
 *
 * 出力形式:
 *   - SELECT 結果   : 1 行目にカラム名、以降にデータ行 (タブ区切り)
 *   - 更新系ステートメント : "rows_affected" ヘッダと件数
 *   - 複数ステートメント実行時は結果セットごとに空行で区切る
 *     (URL に allowMultiQueries=true が必要。シェル側で自動付与される)
 */
public class JdbcSqlRunner {

    public static void main(String[] args) {
        try {
            run();
        } catch (SQLException e) {
            // エラー内容 (Access denied 等) はシェル側で解析するため stderr へ出す
            System.err.println("[JdbcSqlRunner] SQLException: " + e.getMessage()
                    + " (SQLState=" + e.getSQLState() + ", ErrorCode=" + e.getErrorCode() + ")");
            System.exit(1);
        } catch (Exception e) {
            System.err.println("[JdbcSqlRunner] " + e.getClass().getSimpleName() + ": " + e.getMessage());
            System.exit(1);
        }
    }

    private static void run() throws Exception {
        String url     = requireEnv("JDBC_URL");
        String user    = requireEnv("DB_USER");
        String pass    = requireEnv("DB_PASS");
        String sqlFile = requireEnv("SQL_FILE");

        String script = new String(Files.readAllBytes(Paths.get(sqlFile)), StandardCharsets.UTF_8);

        // Windows/Linux どちらでも UTF-8 で出力する
        PrintStream out = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");

        try (Connection conn = DriverManager.getConnection(url, user, pass);
             Statement stmt = conn.createStatement()) {

            boolean hasResult = stmt.execute(script);
            int setIndex = 0;
            while (true) {
                if (hasResult) {
                    try (ResultSet rs = stmt.getResultSet()) {
                        if (setIndex++ > 0) {
                            out.println();
                        }
                        printResultSet(rs, out);
                    }
                } else {
                    int count = stmt.getUpdateCount();
                    if (count == -1) {
                        break;  // これ以上結果なし
                    }
                    if (setIndex++ > 0) {
                        out.println();
                    }
                    out.println("rows_affected");
                    out.println(count);
                }
                hasResult = stmt.getMoreResults();
            }
        }
    }

    /** ResultSet を TSV (1 行目カラム名) で出力する */
    private static void printResultSet(ResultSet rs, PrintStream out) throws SQLException {
        ResultSetMetaData meta = rs.getMetaData();
        int cols = meta.getColumnCount();

        StringBuilder header = new StringBuilder();
        for (int i = 1; i <= cols; i++) {
            if (i > 1) {
                header.append('\t');
            }
            header.append(meta.getColumnLabel(i));
        }
        out.println(header);

        StringBuilder row = new StringBuilder();
        while (rs.next()) {
            row.setLength(0);
            for (int i = 1; i <= cols; i++) {
                if (i > 1) {
                    row.append('\t');
                }
                row.append(formatValue(rs.getString(i)));
            }
            out.println(row);
        }
    }

    /** NULL は "NULL"、タブ・改行は mysql --batch と同様にエスケープする */
    private static String formatValue(String v) {
        if (v == null) {
            return "NULL";
        }
        return v.replace("\\", "\\\\")
                .replace("\t", "\\t")
                .replace("\n", "\\n")
                .replace("\r", "\\r");
    }

    private static String requireEnv(String name) {
        String v = System.getenv(name);
        if (v == null || v.isEmpty()) {
            throw new IllegalStateException("環境変数 " + name + " が設定されていません");
        }
        return v;
    }
}
