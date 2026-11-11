"""ダミーテレメトリを AWS IoT Core へ Publish する。

    python src/publisher.py --count 10 --qos 1

既定の Topic は handson/<PUBLISHER_THING_NAME>/telemetry。
--topic / --client-id を変えると、IoT Policy による認可失敗を再現できる。
"""

from __future__ import annotations

import argparse
import json
import sys
import time

from awscrt import mqtt5

from common import (
    OPERATION_TIMEOUT_SEC,
    build_client,
    load_settings,
    log,
    reason_name,
    stop_client,
    wait_until,
)
from telemetry_generator import TelemetryGenerator


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="AWS IoT Core へダミーテレメトリを Publish します")
    parser.add_argument("--count", type=int, default=10, help="送信件数 (0 で Ctrl+C まで継続)")
    parser.add_argument("--interval", type=float, default=1.0, help="送信間隔 (秒)")
    parser.add_argument("--qos", type=int, choices=(0, 1), default=1, help="MQTT QoS")
    parser.add_argument("--topic", default=None, help="Publish 先 Topic (既定: <root>/<thing>/telemetry)")
    parser.add_argument("--client-id", default=None, help="MQTT クライアント ID (既定: Thing 名)")
    parser.add_argument("--seed", type=int, default=None, help="乱数シード")
    parser.add_argument("--connect-timeout", type=float, default=30.0, help="初回接続の待ち時間 (秒)")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    settings = load_settings("publisher")
    client_id = args.client_id or settings.thing_name
    topic = args.topic or f"{settings.topic_root}/{settings.thing_name}/telemetry"
    qos = mqtt5.QoS.AT_LEAST_ONCE if args.qos == 1 else mqtt5.QoS.AT_MOST_ONCE
    generator = TelemetryGenerator(settings.thing_name, args.seed)

    client, state = build_client(settings, client_id)
    client.start()

    sent = acked = rejected = failed = 0
    try:
        if not wait_until(state.connected, args.connect_timeout):
            log("[エラー] 接続できませんでした。上の [接続] 失敗ログを確認してください。")
            return 1

        log(f"[Publish] topic={topic} qos={args.qos} count={args.count or '無制限'}")
        while args.count == 0 or sent < args.count:
            payload = generator.next()
            sent += 1
            started = time.monotonic()
            try:
                future = client.publish(
                    mqtt5.PublishPacket(topic=topic, payload=json.dumps(payload), qos=qos)
                )
                result = future.result(OPERATION_TIMEOUT_SEC)
            except Exception as error:  # SDK は切断・タイムアウト等を例外で通知する
                failed += 1
                log(f"[Publish] seq={payload['sequence']} 失敗: {error!r}")
            else:
                elapsed_ms = (time.monotonic() - started) * 1000
                puback = getattr(result, "puback", None)
                if args.qos == 0 or puback is None:
                    # QoS 0 は PUBACK が無く、ブローカーに届いたかを送信側は確認できない
                    log(f"[Publish] seq={payload['sequence']} 送信のみ (QoS 0: 確認応答なし)")
                elif puback.reason_code == mqtt5.PubackReasonCode.SUCCESS:
                    acked += 1
                    log(
                        f"[Publish] seq={payload['sequence']} PUBACK={reason_name(puback.reason_code)} "
                        f"{elapsed_ms:.0f}ms temperature_c={payload['temperature_c']}"
                    )
                else:
                    rejected += 1
                    log(
                        f"[Publish] seq={payload['sequence']} 拒否: PUBACK={reason_name(puback.reason_code)} "
                        f"reason_string={puback.reason_string}"
                    )
            if args.count == 0 or sent < args.count:
                time.sleep(args.interval)
    except KeyboardInterrupt:
        log("[中断] Ctrl+C を受け取りました")
    finally:
        stop_client(client, state)

    log(
        f"[結果] 送信={sent} PUBACK成功={acked} 拒否={rejected} 失敗={failed} "
        f"接続試行={state.connect_attempts} 切断={state.disconnections}"
    )
    return 1 if (rejected or failed) else 0


if __name__ == "__main__":
    sys.exit(main())
