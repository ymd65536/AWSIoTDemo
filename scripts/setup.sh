#!/usr/bin/env bash
# AWS IoT Core ハンズオン用リソースを作成する (何度実行しても同じ状態になる)。
#
#   export AWS_REGION=ap-northeast-1      # 省略時は ap-northeast-1
#   export AWS_PROFILE=<プロファイル名>    # 任意
#   ./scripts/setup.sh [--with-logging]
#
# 作成するもの: Thing x2, X.509 証明書 x2, IoT Policy x2, IoT Rule, IAM ロール, ロググループ
# --with-logging: AWS IoT Core のログ出力 (アカウント・リージョン単位の設定) も有効化する

set -euo pipefail
# shellcheck source=scripts/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

WITH_LOGGING=false
for arg in "$@"; do
  case "$arg" in
    --with-logging) WITH_LOGGING=true ;;
    -h | --help)
      sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) die "不明なオプションです: $arg" ;;
  esac
done

load_account
IOT_ARN_PREFIX="arn:${PARTITION}:iot:${REGION}:${ACCOUNT_ID}"
LOGS_ARN_PREFIX="arn:${PARTITION}:logs:${REGION}:${ACCOUNT_ID}"

# AWS IoT がロールを引き受けるための信頼ポリシー。
# aws:SourceAccount / aws:SourceArn で「混乱した代理」問題を防ぐ。
iot_trust_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": { "Service": "iot.amazonaws.com" },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": { "aws:SourceAccount": "${ACCOUNT_ID}" },
        "ArnLike": { "aws:SourceArn": "${IOT_ARN_PREFIX}:*" }
      }
    }
  ]
}
EOF
}

# \${iot:Connection.Thing.ThingName} は IoT Policy 変数 (シェル変数ではない)。
# 「証明書にアタッチされた Thing の名前 = クライアント ID」の場合だけ許可される。
publisher_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iot:Connect",
      "Resource": "${IOT_ARN_PREFIX}:client/\${iot:Connection.Thing.ThingName}"
    },
    {
      "Effect": "Allow",
      "Action": "iot:Publish",
      "Resource": "${IOT_ARN_PREFIX}:topic/${TOPIC_ROOT}/\${iot:Connection.Thing.ThingName}/telemetry"
    }
  ]
}
EOF
}

subscriber_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": "iot:Connect",
      "Resource": "${IOT_ARN_PREFIX}:client/\${iot:Connection.Thing.ThingName}"
    },
    {
      "Effect": "Allow",
      "Action": "iot:Subscribe",
      "Resource": "${IOT_ARN_PREFIX}:topicfilter/${TOPIC_ROOT}/+/telemetry"
    },
    {
      "Effect": "Allow",
      "Action": "iot:Receive",
      "Resource": "${IOT_ARN_PREFIX}:topic/${TOPIC_ROOT}/*/telemetry"
    }
  ]
}
EOF
}

rule_role_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:DescribeLogStreams", "logs:PutLogEvents"],
      "Resource": "${LOGS_ARN_PREFIX}:log-group:${RULE_LOG_GROUP}:*"
    }
  ]
}
EOF
}

logging_role_policy() {
  cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:PutMetricFilter",
        "logs:PutRetentionPolicy"
      ],
      "Resource": [
        "${LOGS_ARN_PREFIX}:log-group:${IOT_LOG_GROUP}",
        "${LOGS_ARN_PREFIX}:log-group:${IOT_LOG_GROUP}:*"
      ]
    }
  ]
}
EOF
}

# 単位変換・Topic からのデバイス ID 抽出・処理時刻の付与を行い、25℃以上のデータだけを転送する
rule_payload() {
  cat <<EOF
{
  "sql": "SELECT topic(2) AS device_id, sequence, temperature_c, temperature_c * 9 / 5 + 32 AS temperature_f, humidity_pct, timestamp() AS processed_at_ms FROM '${TOPIC_ROOT}/+/telemetry' WHERE temperature_c >= 25",
  "description": "AWS IoT Core hands-on: transform telemetry and send it to CloudWatch Logs",
  "awsIotSqlVersion": "2016-03-23",
  "ruleDisabled": false,
  "actions": [
    {
      "cloudwatchLogs": {
        "roleArn": "arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${RULE_ROLE}",
        "logGroupName": "${RULE_LOG_GROUP}"
      }
    }
  ]
}
EOF
}

ensure_policy() {
  local name="$1" document="$2"
  if awsx iot get-policy --policy-name "$name" --query policyName >/dev/null 2>&1; then
    info "IoT Policy は作成済みです (内容を変えたい場合は cleanup.sh 実行後にやり直してください): $name"
  else
    awsx iot create-policy --policy-name "$name" --policy-document "$document" --query policyArn >/dev/null
    info "IoT Policy を作成しました: $name"
  fi
}

# Thing・証明書を用意し、Policy と Thing を証明書にアタッチする
ensure_device() {
  local role="$1" thing="$2" policy="$3"
  local dir="${CERT_DIR}/${role}"
  local id_file="${dir}/certificate-id.txt" cert_file="${dir}/certificate.pem.crt" key_file="${dir}/private.pem.key"
  local cert_id="" status=""

  awsx iot create-thing --thing-name "$thing" --query thingArn >/dev/null
  info "Thing を用意しました: $thing"

  mkdir -p "$dir"
  chmod 700 "$CERT_DIR" "$dir"
  if [[ -s "$id_file" && -s "$cert_file" && -s "$key_file" ]]; then
    cert_id="$(cat "$id_file")"
    status="$(awsx iot describe-certificate --certificate-id "$cert_id" \
      --query certificateDescription.status 2>/dev/null || true)"
  fi

  if [[ -z "$status" ]]; then
    # 秘密鍵を取得できるのはこの 1 回だけ。umask で所有者のみ読み書き可能にして保存する。
    cert_id="$(
      umask 077
      awsx iot create-keys-and-certificate --set-as-active \
        --certificate-pem-outfile "$cert_file" \
        --private-key-outfile "$key_file" \
        --query certificateId
    )"
    (umask 077 && echo "$cert_id" >"$id_file")
    info "証明書を発行しました: ${cert_id:0:12}... -> ${dir}"
  elif [[ "$status" != "ACTIVE" ]]; then
    awsx iot update-certificate --certificate-id "$cert_id" --new-status ACTIVE
    info "既存の証明書を ACTIVE に戻しました (元の状態: ${status}): ${cert_id:0:12}..."
  else
    info "既存の証明書を再利用します: ${cert_id:0:12}..."
  fi

  local cert_arn="${IOT_ARN_PREFIX}:cert/${cert_id}"
  awsx iot attach-policy --policy-name "$policy" --target "$cert_arn"
  awsx iot attach-thing-principal --thing-name "$thing" --principal "$cert_arn"
  info "証明書に Policy (${policy}) と Thing (${thing}) をアタッチしました"
}

ensure_role() {
  local role="$1" policy_name="$2" policy_document="$3"
  if awsx iam get-role --role-name "$role" --query Role.RoleName >/dev/null 2>&1; then
    awsx iam update-assume-role-policy --role-name "$role" --policy-document "$(iot_trust_policy)"
  else
    awsx iam create-role --role-name "$role" --assume-role-policy-document "$(iot_trust_policy)" \
      --description "AWS IoT Core hands-on" --query Role.Arn >/dev/null
  fi
  awsx iam put-role-policy --role-name "$role" --policy-name "$policy_name" --policy-document "$policy_document"
  info "IAM ロールを用意しました: $role"
}

log_group_exists() {
  local name="$1" found
  found="$(awsx logs describe-log-groups --log-group-name-prefix "$name" \
    --query "logGroups[?logGroupName=='${name}'].logGroupName")"
  [[ "$found" == "$name" ]]
}

# 保持期間を短く設定し、ログの保管料金が残り続けないようにする
ensure_log_group() {
  local name="$1"
  if log_group_exists "$name"; then
    info "ロググループは作成済みです: $name"
  else
    awsx logs create-log-group --log-group-name "$name"
    awsx logs put-retention-policy --log-group-name "$name" --retention-in-days "$LOG_RETENTION_DAYS"
    info "ロググループを作成しました (保持 ${LOG_RETENTION_DAYS} 日): $name"
  fi
}

ensure_rule() {
  local payload
  payload="$(rule_payload)"
  if awsx iot get-topic-rule --rule-name "$RULE_NAME" --query ruleArn >/dev/null 2>&1; then
    awsx iot replace-topic-rule --rule-name "$RULE_NAME" --topic-rule-payload "$payload"
    info "IoT Rule を更新しました: $RULE_NAME"
  else
    # 作成直後の IAM ロールは反映に数秒かかることがあるため再試行する
    retry 6 5 awsx iot create-topic-rule --rule-name "$RULE_NAME" --topic-rule-payload "$payload" \
      || die "IoT Rule を作成できませんでした: $RULE_NAME"
    info "IoT Rule を作成しました: $RULE_NAME"
  fi
}

enable_iot_logging() {
  local current_role
  current_role="$(awsx iot get-v2-logging-options --query roleArn 2>/dev/null || true)"
  if [[ -n "$current_role" && "$current_role" != "None" && "$current_role" != "$LOGGING_ROLE_ARN" ]]; then
    die "このアカウント・リージョンには既に別のログ設定があります (${current_role})。既存設定を壊さないため変更しません。"
  fi
  ensure_role "$LOGGING_ROLE" "$LOGGING_ROLE_POLICY" "$(logging_role_policy)"
  ensure_log_group "$IOT_LOG_GROUP"
  retry 6 5 awsx iot set-v2-logging-options --role-arn "$LOGGING_ROLE_ARN" \
    --default-log-level INFO --no-disable-all-logs \
    || die "AWS IoT Core のログ出力を有効化できませんでした。"
  info "AWS IoT Core のログ出力を有効化しました (INFO, ロググループ: ${IOT_LOG_GROUP})"
}

download_root_ca() {
  local ca_file="${CERT_DIR}/AmazonRootCA1.pem"
  mkdir -p "$CERT_DIR"
  if [[ -s "$ca_file" ]]; then
    return 0
  fi
  if command -v curl >/dev/null 2>&1 \
    && curl -fsS --max-time 30 -o "$ca_file" https://www.amazontrust.com/repository/AmazonRootCA1.pem \
    && grep -q "BEGIN CERTIFICATE" "$ca_file"; then
    info "Amazon Root CA 1 を取得しました: $ca_file"
  else
    rm -f "$ca_file"
    warn "Amazon Root CA 1 を取得できませんでした。OS の信頼ストアを使用します (IOT_CA_FILE は空)。"
    return 1
  fi
}

write_env_file() {
  local endpoint="$1" ca_value="$2"
  (
    umask 077
    cat >"$ENV_FILE" <<EOF
# scripts/setup.sh が生成しました ($(date -u +%Y-%m-%dT%H:%M:%SZ), ${REGION})。コミットしないでください。
IOT_ENDPOINT=${endpoint}
IOT_PORT=8883
IOT_CA_FILE=${ca_value}
IOT_TOPIC_ROOT=${TOPIC_ROOT}
PUBLISHER_THING_NAME=${PUBLISHER_THING}
PUBLISHER_CERT_FILE=certs/publisher/certificate.pem.crt
PUBLISHER_KEY_FILE=certs/publisher/private.pem.key
SUBSCRIBER_THING_NAME=${SUBSCRIBER_THING}
SUBSCRIBER_CERT_FILE=certs/subscriber/certificate.pem.crt
SUBSCRIBER_KEY_FILE=certs/subscriber/private.pem.key
EOF
  )
  info ".env を生成しました: $ENV_FILE"
}

info "=== 1/4 IoT Policy ==="
ensure_policy "$PUBLISHER_POLICY" "$(publisher_policy)"
ensure_policy "$SUBSCRIBER_POLICY" "$(subscriber_policy)"

info "=== 2/4 Thing と X.509 証明書 ==="
ensure_device publisher "$PUBLISHER_THING" "$PUBLISHER_POLICY"
ensure_device subscriber "$SUBSCRIBER_THING" "$SUBSCRIBER_POLICY"

info "=== 3/4 IoT Rule -> CloudWatch Logs ==="
ensure_role "$RULE_ROLE" "$RULE_ROLE_POLICY" "$(rule_role_policy)"
ensure_log_group "$RULE_LOG_GROUP"
ensure_rule

if [[ "$WITH_LOGGING" == true ]]; then
  info "=== (任意) AWS IoT Core のログ出力 ==="
  enable_iot_logging
fi

info "=== 4/4 エンドポイントと .env ==="
ENDPOINT="$(awsx iot describe-endpoint --endpoint-type iot:Data-ATS --query endpointAddress)"
CA_VALUE=""
if download_root_ca; then
  CA_VALUE="certs/AmazonRootCA1.pem"
fi
write_env_file "$ENDPOINT" "$CA_VALUE"

cat <<EOF

セットアップが完了しました。
  エンドポイント : ${ENDPOINT}
  Publisher      : ${PUBLISHER_THING}  (Topic: ${TOPIC_ROOT}/${PUBLISHER_THING}/telemetry)
  Subscriber     : ${SUBSCRIBER_THING} (フィルター: ${TOPIC_ROOT}/+/telemetry)
  IoT Rule       : ${RULE_NAME} -> ロググループ ${RULE_LOG_GROUP}

次の手順:
  python src/subscriber.py          # ターミナル 1
  python src/publisher.py --count 10  # ターミナル 2
片付け:
  ./scripts/cleanup.sh
EOF
