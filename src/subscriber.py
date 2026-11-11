"""AWS IoT Core の Topic を Subscribe し、受信したテレメトリを表示する。

    python src/subscriber.py

既定の Topic フィルターは handson/+/telemetry。
デバイスごとの sequence を追跡し、欠落と重複を検出して表示する (QoS 比較用)。
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
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


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="AWS IoT Core の Topic を Subscribe します")
    parser.add_argument("--topic-filter", default=None, help="Topic フィルター (既定: <root>/+/telemetry)")
    parser.add_argument("--qos", type=int, choices=(0, 1), default=1, help="Subscribe 時の最大 QoS")
    parser.add_argument("--client-id", default=None, help="MQTT クライアント ID (既定: Thing 名)")
    parser.add_argument("--duration", type=float, default=0, help="受信を続ける秒数 (0 で Ctrl+C まで)")
    parser.add_argument(
        "--session-expiry",
        type=int,
        default=0,
        help="永続セッションの有効期間 (秒)。0 はクリーンセッション",
    )
    parser.add_argument("--connect-timeout", type=float, default=30.0, help="初回接続の待ち時間 (秒)")
    return parser.parse_args()


class Receiver:
    def __init__(self) -> None:
        self.received = 0
        self.duplicates = 0
        self.missing = 0
        self._last_sequence: dict[str, int] = {}
        self._lock = threading.Lock()

    def on_publish_received(self, data: mqtt5.PublishReceivedData) -> None:
        packet = data.publish_packet
        raw = packet.payload or b""
        text = raw.decode("utf-8", errors="replace") if isinstance(raw, (bytes, bytearray)) else str(raw)
        note = ""
        try:
            message = json.loads(text)
            if isinstance(message, dict):
                note = self._check_sequence(message)
        except json.JSONDecodeError:
            note = " (JSON ではありません)"
        with self._lock:
            self.received += 1
        log(f"[受信] topic={packet.topic} qos={int(packet.qos)}{note} payload={text}")

    def _check_sequence(self, message: dict) -> str:
        device_id = message.get("device_id")
        sequence = message.get("sequence")
        if not isinstance(device_id, str) or not isinstance(sequence, int):
            return ""
        with self._lock:
            last = self._last_sequence.get(device_id)
            if last is not None and sequence == last:
                self.duplicates += 1
                return " [重複]"
            # sequence が小さくなった場合は Publisher の再起動とみなして追跡をやり直す
            self._last_sequence[device_id] = sequence
            if last is not None and sequence > last + 1:
                gap = sequence - last - 1
                self.missing += gap
                return f" [欠落 {gap}件]"
        return ""


def subscribe(client: mqtt5.Client, topic_filter: str, qos: mqtt5.QoS) -> bool:
    log(f"[Subscribe] filter={topic_filter} qos={int(qos)}")
    try:
        suback = client.subscribe(
            mqtt5.SubscribePacket(subscriptions=[mqtt5.Subscription(topic_filter=topic_filter, qos=qos)])
        ).result(OPERATION_TIMEOUT_SEC)
    except Exception as error:  # 認可失敗が SUBACK ではなく切断として現れる場合がある
        log(f"[Subscribe] 失敗: {error!r}")
        return False

    codes = list(suback.reason_codes or [])
    log(f"[Subscribe] SUBACK={[reason_name(code) for code in codes]}")
    granted = (mqtt5.SubackReasonCode.GRANTED_QOS_0, mqtt5.SubackReasonCode.GRANTED_QOS_1)
    if not codes or any(code not in granted for code in codes):
        log("[Subscribe] 拒否されました。IoT Policy の iot:Subscribe (topicfilter) を確認してください。")
        return False
    return True


def main() -> int:
    args = parse_args()
    settings = load_settings("subscriber")
    client_id = args.client_id or settings.thing_name
    topic_filter = args.topic_filter or f"{settings.topic_root}/+/telemetry"
    qos = mqtt5.QoS.AT_LEAST_ONCE if args.qos == 1 else mqtt5.QoS.AT_MOST_ONCE
    receiver = Receiver()

    client, state = build_client(
        settings,
        client_id,
        on_publish_received=receiver.on_publish_received,
        session_expiry_sec=args.session_expiry or None,
    )
    client.start()

    try:
        if not wait_until(state.connected, args.connect_timeout):
            log("[エラー] 接続できませんでした。上の [接続] 失敗ログを確認してください。")
            return 1

        deadline = time.monotonic() + args.duration if args.duration > 0 else None
        while deadline is None or time.monotonic() < deadline:
            # 初回接続時と、SDK による自動再接続のたびに Subscribe する
            if state.connected.is_set() and state.subscribe_needed.is_set():
                state.subscribe_needed.clear()
                if not subscribe(client, topic_filter, qos):
                    return 1
                log("[待機] メッセージを待っています (Ctrl+C で終了)")
            time.sleep(0.2)
    except KeyboardInterrupt:
        log("[中断] Ctrl+C を受け取りました")
    finally:
        stop_client(client, state)
        log(
            f"[結果] 受信={receiver.received} 重複={receiver.duplicates} 欠落={receiver.missing} "
            f"接続試行={state.connect_attempts} 切断={state.disconnections}"
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
