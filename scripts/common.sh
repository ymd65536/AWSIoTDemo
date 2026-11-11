#!/usr/bin/env bash
# setup.sh / cleanup.sh が共有する設定とヘルパー。直接実行せず source して使う。
# リソース名をここで一元管理し、作成と削除の対象がずれないようにしている。
# shellcheck disable=SC2034  # 変数は source 元のスクリプトが使用する

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-northeast-1}}"
PREFIX="${PROJECT_PREFIX:-iot-handson}"
TOPIC_ROOT="${IOT_TOPIC_ROOT:-handson}"

if ! [[ "$PREFIX" =~ ^[a-z][a-z0-9-]{2,30}$ ]]; then
  echo "PROJECT_PREFIX は英小文字で始まる 3〜31 文字の英小文字・数字・ハイフンで指定してください: $PREFIX" >&2
  exit 1
fi
if ! [[ "$TOPIC_ROOT" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "IOT_TOPIC_ROOT は英数字・ハイフン・アンダースコアのみで指定してください: $TOPIC_ROOT" >&2
  exit 1
fi

PUBLISHER_THING="${PREFIX}-publisher"
SUBSCRIBER_THING="${PREFIX}-subscriber"
PUBLISHER_POLICY="${PREFIX}-publisher-policy"
SUBSCRIBER_POLICY="${PREFIX}-subscriber-policy"
RULE_NAME="${PREFIX//-/_}_telemetry_to_logs"
RULE_ROLE="${PREFIX}-rule-role"
RULE_ROLE_POLICY="write-rule-output"
RULE_LOG_GROUP="${PREFIX}-rule-output"
LOGGING_ROLE="${PREFIX}-logging-role"
LOGGING_ROLE_POLICY="write-iot-logs"
IOT_LOG_GROUP="AWSIotLogsV2"
LOG_RETENTION_DAYS=3

CERT_DIR="${REPO_ROOT}/certs"
ENV_FILE="${REPO_ROOT}/.env"

info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# すべての AWS CLI 呼び出しでリージョンを明示する。認証情報は AWS_PROFILE などの標準の仕組みに任せる。
awsx() { aws --region "$REGION" --output text "$@"; }

# retry <回数> <待機秒> <コマンド...>: IAM や IoT の結果整合性による一時的な失敗を吸収する
retry() {
  local attempts="$1" delay="$2" i
  shift 2
  for ((i = 1; i <= attempts; i++)); do
    if "$@"; then
      return 0
    fi
    if ((i < attempts)); then
      sleep "$delay"
    fi
  done
  return 1
}

load_account() {
  command -v aws >/dev/null 2>&1 || die "AWS CLI v2 が見つかりません。"
  local caller_arn
  caller_arn="$(awsx sts get-caller-identity --query Arn)" \
    || die "AWS の認証情報を取得できません。aws sso login や AWS_PROFILE を確認してください。"
  ACCOUNT_ID="$(awsx sts get-caller-identity --query Account)"
  PARTITION="$(echo "$caller_arn" | cut -d: -f2)"
  LOGGING_ROLE_ARN="arn:${PARTITION}:iam::${ACCOUNT_ID}:role/${LOGGING_ROLE}"
  info "アカウント: ${ACCOUNT_ID} / リージョン: ${REGION} / プレフィックス: ${PREFIX}"
  info "実行ユーザー: ${caller_arn}"
}
