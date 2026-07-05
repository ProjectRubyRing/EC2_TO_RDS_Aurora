#!/usr/bin/env bash
#
# switch-back.sh （サンプル / 雛形）
# =================================
# スイッチロール時に設定した一時クレデンシャルの環境変数をすべて削除（unset）して
# 「スイッチバック」するスクリプトです。
# rds-proxy-db-maintenance.sh から **source** されることを前提とし、
# unset を呼び出し元シェル（=本体スクリプトのプロセス）へ反映させます。
#
# 環境変数を消すことで、AWS CLI / SDK はベースのクレデンシャル
# （EC2 インスタンスプロファイル等）へ自動的に戻ります。
#
#   使い方（本体スクリプト側で source される）:
#     source switch-back.sh
#
#   ※ これは雛形です。別のチームが用意している専用スクリプトを使う場合は、本体側の
#        --switch-back-script <path>   または   SWITCH_BACK_SCRIPT=<path>
#      でそちらを指すよう差し替えてください（このファイルは使われません）。
#
# 重要:
#   - source される前提のため、このファイルでは exit を使わず return で抜けます。

# このファイルが source ではなく直接実行された場合は意味がないので警告する。
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  echo "[switch-back.sh][ERROR] このスクリプトは source して使ってください: source switch-back.sh" >&2
  exit 1
fi

# スイッチロールで設定され得るクレデンシャル系の環境変数をすべて削除する。
# （これらが無くなると、SDK はベースの認証情報チェーンへ戻る）
unset AWS_ACCESS_KEY_ID
unset AWS_SECRET_ACCESS_KEY
unset AWS_SESSION_TOKEN
unset AWS_SECURITY_TOKEN          # 古い SDK 互換（AWS_SESSION_TOKEN の別名）
unset AWS_CREDENTIAL_EXPIRATION   # 一部ツールが参照する有効期限
unset AWS_PROFILE                 # プロファイル指定が残っていればそれも解除

echo "[switch-back.sh][OK] スイッチバックしました（スイッチロール時のクレデンシャル環境変数を破棄）。"
