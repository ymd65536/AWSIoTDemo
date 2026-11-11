#!/usr/bin/env bash
# setup.sh が作成したリソースを依存関係の順に削除する (途中で失敗しても再実行できる)。
#
#   export AWS_REGION=ap-northeast-1      # setup.sh と同じ値を指定する
#   export AWS_PROFILE=<プロファイル名>    # 任意
#   ./scripts/cleanup.sh [--yes] [--keep-local] [--delete-iot-logs]
#
# --yes             確認プロンプトを省略する
# --keep-local      ローカルの certs/ と .env を残す
# --delete-iot-logs AWS IoT Core のログ用ロググループ (AWSIotLogsV2) も削除する
#                   ※ ハンズオン以前から使っているアカウントでは指定しないこと

set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ASSUME_YES=false
KEEP_LOCAL=false
DELETE_IOT_LOGS=false
for arg in "$@"; do
  case "$arg" in
    -y | --yes) ASSUME_YES=true ;;
    --keep-local) KEEP_LOCAL=true ;;
    --delete-iot-logs) DELETE_IOT_LOGS=true ;;
    -h | --help)
      sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "不明なオプションです: $arg" ;;
  esac
done

load_account
IOT_ARN_PREFIX="arn:${PARTITION}:iot:${REGION}:${ACCOUNT_ID}"

cat <<EOF

以下を削除します:
  Thing      : ${PUBLISHER_THING}, ${SUBSCRIBER_THING} (アタッチされた証明書を含む)
  IoT Policy : ${PUBLISHER_POLICY}, ${SUBSCRIBER_POLICY}
  IoT Rule   : ${RULE_NAME}
  IAM ロール : ${RULE_ROLE}, ${LOGGING_ROLE}
  ロググループ: ${RULE_LOG_GROUP}$([[ "$DELETE_IOT_LOGS" == true ]] && echo ", ${IOT_LOG_GROUP}")
  ローカル   : $([[ "$KEEP_LOCAL" == true ]] && echo "(残す)" || echo "certs/ と .env")
EOF
if [[ "$ASSUME_YES" != true ]]; then
  read -r -p "続行しますか? [y/N] " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "中止しました。"
fi

# --output text の結果 (タブ・改行区切り、空は None) を 1 行 1 件に整形する
lines() { tr '\t' '\n' | sed -e '/^$/d' -e '/^None$/d'; }

delete_rule() {
  if awsx iot get-topic-rule --rule-name "$RULE_NAME" --query ruleArn >/dev/null 2>&1; then
    awsx iot delete-topic-rule --rule-name "$RULE_NAME"
    info "IoT Rule を削除しました: $RULE_NAME"
  else
    info "IoT Rule はありません: $RULE_NAME"
  fi
}

delete_role() {
  local role="$1" policy
  if ! awsx iam get-role --role-name "$role" --query Role.RoleName >/dev/null 2>&1; then
    info "IAM ロールはありません: $role"
    return 0
  fi
  while read -r policy; do
    awsx iam delete-role-policy --role-name "$role" --policy-name "$policy"
  done < <(awsx iam list-role-policies --role-name "$role" --query 'PolicyNames[]' | lines)
  awsx iam delete-role --role-name "$role"
  info "IAM ロールを削除しました: $role"
}

delete_log_group() {
  local name="$1" found
  found="$(awsx logs describe-log-groups --log-group-name-prefix "$name" \
    --query "logGroups[?logGroupName=='${name}'].logGroupName" | lines)"
  if [[ "$found" == "$name" ]]; then
    awsx logs delete-log-group --log-group-name "$name"
    info "ロググループを削除しました: $name"
  else
    info "ロググループはありません: $name"
  fi
}

# このハンズオンのロールで有効化したログ設定だけを無効化する (他の設定には触れない)
disable_iot_logging() {
  local current_role
  current_role="$(awsx iot get-v2-logging-options --query roleArn 2>/dev/null | lines || true)"
  if [[ "$current_role" == "$LOGGING_ROLE_ARN" ]]; then
    awsx iot set-v2-logging-options --disable-all-logs
    info "AWS IoT Core のログ出力を無効化しました"
  elif [[ -n "$current_role" ]]; then
    info "AWS IoT Core のログ設定はハンズオン以外のロールを使っているため変更しません: $current_role"
  fi
}

# 証明書は「Policy をデタッチ → INACTIVE → 削除」の順でないと削除できない
delete_certificate() {
  local cert_arn="$1" cert_id="${1##*/}" policy
  if ! awsx iot describe-certificate --certificate-id "$cert_id" \
    --query certificateDescription.certificateId >/dev/null 2>&1; then
    return 0
  fi
  while read -r policy; do
    awsx iot detach-policy --policy-name "$policy" --target "$cert_arn"
  done < <(awsx iot list-attached-policies --target "$cert_arn" --query 'policies[].policyName' | lines)
  awsx iot update-certificate --certificate-id "$cert_id" --new-status INACTIVE || true
  retry 6 5 awsx iot delete-certificate --certificate-id "$cert_id" --force-delete \
    || die "証明書を削除できませんでした。少し待ってから再実行してください: $cert_id"
  info "証明書を無効化して削除しました: ${cert_id:0:12}..."
}

delete_device() {
  local role="$1" thing="$2" principal
  local id_file="${CERT_DIR}/${role}/certificate-id.txt"
  local -a cert_arns=()

  while read -r principal; do
    awsx iot detach-thing-principal --thing-name "$thing" --principal "$principal"
    if [[ "$principal" == *":cert/"* ]]; then
      cert_arns+=("$principal")
    fi
  done < <(awsx iot list-thing-principals --thing-name "$thing" --query 'principals[]' 2>/dev/null | lines || true)

  # Thing へのアタッチ前に setup.sh が中断した場合に備え、ローカルに記録した証明書 ID も対象にする
  if [[ -s "$id_file" ]]; then
    cert_arns+=("${IOT_ARN_PREFIX}:cert/$(cat "$id_file")")
  fi

  local cert_arn
  for cert_arn in ${cert_arns[@]+"${cert_arns[@]}"}; do
    delete_certificate "$cert_arn"
  done

  if ! awsx iot describe-thing --thing-name "$thing" --query thingName >/dev/null 2>&1; then
    info "Thing はありません: $thing"
    return 0
  fi
  # デタッチは非同期に反映されるため再試行する
  retry 6 5 awsx iot delete-thing --thing-name "$thing" \
    || die "Thing を削除できませんでした。少し待ってから再実行してください: $thing"
  info "Thing を削除しました: $thing"
}

delete_policy() {
  local name="$1" target version
  if ! awsx iot get-policy --policy-name "$name" --query policyName >/dev/null 2>&1; then
    info "IoT Policy はありません: $name"
    return 0
  fi
  while read -r target; do
    awsx iot detach-policy --policy-name "$name" --target "$target"
  done < <(awsx iot list-targets-for-policy --policy-name "$name" --query 'targets[]' | lines)
  while read -r version; do
    awsx iot delete-policy-version --policy-name "$name" --policy-version-id "$version"
  done < <(awsx iot list-policy-versions --policy-name "$name" \
    --query 'policyVersions[?!isDefaultVersion].versionId' | lines)
  # デタッチ直後は削除できないことがあるため再試行する
  retry 10 6 awsx iot delete-policy --policy-name "$name" \
    || die "IoT Policy を削除できませんでした。数分待ってから再実行してください: $name"
  info "IoT Policy を削除しました: $name"
}

info "=== 1/5 IoT Rule と転送先 ==="
delete_rule
delete_role "$RULE_ROLE"
delete_log_group "$RULE_LOG_GROUP"

info "=== 2/5 AWS IoT Core のログ出力 ==="
disable_iot_logging
delete_role "$LOGGING_ROLE"
if [[ "$DELETE_IOT_LOGS" == true ]]; then
  delete_log_group "$IOT_LOG_GROUP"
fi

info "=== 3/5 Thing と証明書 ==="
delete_device publisher "$PUBLISHER_THING"
delete_device subscriber "$SUBSCRIBER_THING"

info "=== 4/5 IoT Policy ==="
delete_policy "$PUBLISHER_POLICY"
delete_policy "$SUBSCRIBER_POLICY"

info "=== 5/5 ローカルの秘密鍵・証明書・.env ==="
if [[ "$KEEP_LOCAL" == true ]]; then
  info "ローカルファイルは残しました (--keep-local)"
else
  # 証明書は AWS 側で削除済みのため、鍵が復元されても接続には使えない
  rm -rf "$CERT_DIR"
  rm -f "$ENV_FILE"
  info "certs/ と .env を削除しました"
fi

cat <<EOF

クリーンアップが完了しました。残存リソースの確認 (すべて空であること):
  aws iot list-things --region ${REGION} --query "things[?starts_with(thingName, '${PREFIX}-')].thingName"
  aws iot list-policies --region ${REGION} --query "policies[?starts_with(policyName, '${PREFIX}-')].policyName"
  aws iot list-topic-rules --region ${REGION} --query "rules[?starts_with(ruleName, '${PREFIX//-/_}_')].ruleName"
  aws iam list-roles --query "Roles[?starts_with(RoleName, '${PREFIX}-')].RoleName"
  aws logs describe-log-groups --region ${REGION} --log-group-name-prefix ${PREFIX}- --query "logGroups[].logGroupName"
EOF
