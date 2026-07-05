#!/usr/bin/env bash
#
# verify-connections.sh
# =====================
# rhel9 コンテナ内で実行し、mysql-db-maintenance.sh の接続パターンを総当たりで
# 検証するスクリプト。
#
#   接続先        : mysql80 (MySQL 8.0) / mysql84 (MySQL 8.4)
#   認証プラグイン : mysql_native_password / caching_sha2_password
#   クライアント   : mysql / java (MySQL Connector/J)
#
# の 2 x 2 x 2 = 8 パターンを実行し、最後に結果サマリを表示する。
# 1 つでも失敗があれば終了コード 1 で終了する。
#
# 使い方 (ホスト側から):
#   docker compose up -d --build
#   docker compose exec rhel9 ./verify-connections.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

COMMON_SH=""
for candidate in "${SCRIPT_DIR}/common.sh" "${SCRIPT_DIR}/../common.sh"; do
  [[ -f "$candidate" ]] && { COMMON_SH="$candidate"; break; }
done
[[ -n "$COMMON_SH" ]] || { echo "[ERROR] common.sh が見つかりません" >&2; exit 1; }
# shellcheck source=../common.sh
source "$COMMON_SH"

MAINTENANCE_SH="${SCRIPT_DIR}/mysql-db-maintenance.sh"
[[ -f "$MAINTENANCE_SH" ]] || die "mysql-db-maintenance.sh が見つかりません: $MAINTENANCE_SH"

# 検証対象 (initdb/01_create_users.sql で作成されるユーザーと対応)
HOSTS=("mysql80" "mysql84")
CLIENTS=("mysql" "java")
declare -A PLUGIN_USER=(
  [mysql_native_password]="native_user"
  [caching_sha2_password]="sha2_user"
)
declare -A PLUGIN_PASS=(
  [mysql_native_password]="NativePass123!"
  [caching_sha2_password]="Sha2Pass123!"
)

RESULTS=()   # "PASS|FAIL <説明>" を蓄積
FAILED=0

run_case() {
  local host="$1" plugin="$2" client="$3"
  local user="${PLUGIN_USER[$plugin]}"
  local pass="${PLUGIN_PASS[$plugin]}"
  local label="${host} / ${plugin} / client=${client}"
  local log rc=0

  log_info "=============================================================="
  log_info "検証: ${label}"
  log_info "=============================================================="

  set +e
  log="$(DB_PASSWORD="$pass" bash "$MAINTENANCE_SH" \
           --host "$host" \
           --db-user "$user" \
           --database appdb \
           --auth-plugin "$plugin" \
           --client "$client" \
           --password-source env 2>&1)"
  rc=$?
  set -e

  printf '%s\n' "$log"

  if [[ $rc -eq 0 ]]; then
    RESULTS+=("PASS ${label}")
    log_success "OK: ${label}"
  else
    RESULTS+=("FAIL ${label} (exit=${rc})")
    FAILED=1
    log_error "NG: ${label} (exit=${rc})"
  fi
  echo
}

main() {
  local host plugin client
  for host in "${HOSTS[@]}"; do
    for plugin in "${!PLUGIN_USER[@]}"; do
      for client in "${CLIENTS[@]}"; do
        run_case "$host" "$plugin" "$client"
      done
    done
  done

  log_info "=============================================================="
  log_info "接続検証サマリ (${#RESULTS[@]} パターン)"
  log_info "=============================================================="
  local r
  for r in "${RESULTS[@]}"; do
    if [[ "$r" == PASS* ]]; then
      log_success "${r#PASS }"
    else
      log_error "${r#FAIL }"
    fi
  done

  if [[ $FAILED -ne 0 ]]; then
    die "接続検証に失敗したパターンがあります"
  fi
  log_success "全パターンの接続検証に成功しました"
}

main
