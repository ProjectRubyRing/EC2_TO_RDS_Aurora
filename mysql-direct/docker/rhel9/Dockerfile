# =========================================================================
# EC2 (RHEL 9) 相当のクライアントコンテナ
# RHEL 9 と互換 (バイナリ互換のリビルド) の AlmaLinux 9 を使用する (無償)。
# mysql-db-maintenance.sh の実行に必要なものを導入する:
#   - mysql            : MySQL 8.0 クライアント (--client mysql 用)
#   - java-17-openjdk  : Java ランナー実行用 (--client java 用)
#   - mysql-connector-j: Maven Central から取得して /usr/share/java/ へ配置
#                        (スクリプトの自動探索パスに合わせる)
# =========================================================================
FROM almalinux:9

RUN dnf -y install mysql java-17-openjdk-headless \
 && dnf clean all

# MySQL Connector/J (JDBC ドライバ)。RHEL9 の dnf では提供されないため
# Maven Central から取得する。8.4.0 は MySQL 8.0 / 8.4 サーバの両方に対応。
ARG CONNECTOR_J_VERSION=8.4.0
RUN mkdir -p /usr/share/java \
 && curl -fsSL -o /usr/share/java/mysql-connector-j-${CONNECTOR_J_VERSION}.jar \
      https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/${CONNECTOR_J_VERSION}/mysql-connector-j-${CONNECTOR_J_VERSION}.jar

WORKDIR /work/mysql-direct

CMD ["sleep", "infinity"]
