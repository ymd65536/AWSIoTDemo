"""publisher.py / subscriber.py 共通の設定読み込みと MQTT 5 クライアント生成。

デバイス側は X.509 クライアント証明書だけで AWS IoT Core に接続するため、
このモジュールは AWS アクセスキーや AWS CLI のプロファイルを一切参照しない。
"""

from __future__ import annotations

import os
import sys
import threading
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

from awscrt import mqtt5
from awsiot import mqtt5_client_builder

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ENV_FILE = REPO_ROOT / ".env"
DEFAULT_PORT = 8883
DEFAULT_TOPIC_ROOT = "handson"
OPERATION_TIMEOUT_SEC = 20


def log(message: str) -> None:
    now = datetime.now(timezone.utc).strftime("%H:%M:%S.%f")[:-3]
    print(f"[{now}Z] {message}", flush=True)


def load_env_file(path: Path = DEFAULT_ENV_FILE) -> None:
    """KEY=VALUE 形式の .env を読み込む。既に設定済みの環境変数は上書きしない。"""
    if not path.is_file():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key, value)


@dataclass(frozen=True)
class Settings:
    endpoint: str
    port: int
    ca_file: Optional[Path]
    cert_file: Path
    key_file: Path
    thing_name: str
    topic_root: str


def _resolve_path(value: str) -> Path:
    path = Path(value).expanduser()
    return path if path.is_absolute() else REPO_ROOT / path


def load_settings(role: str) -> Settings:
    """role は "publisher" または "subscriber"。.env と環境変数から設定を組み立てる。"""
    load_env_file()
    prefix = role.upper()
    names = {
        "endpoint": "IOT_ENDPOINT",
        "thing_name": f"{prefix}_THING_NAME",
        "cert_file": f"{prefix}_CERT_FILE",
        "key_file": f"{prefix}_KEY_FILE",
    }
    values = {key: os.environ.get(name, "").strip() for key, name in names.items()}
    missing = [names[key] for key, value in values.items() if not value]
    if missing:
        sys.exit(
            "設定が不足しています: " + ", ".join(missing)
            + "\n.env.example を参考に .env を作成するか、scripts/setup.sh を実行してください。"
        )

    cert_file = _resolve_path(values["cert_file"])
    key_file = _resolve_path(values["key_file"])
    ca_value = os.environ.get("IOT_CA_FILE", "").strip()
    ca_file = _resolve_path(ca_value) if ca_value else None
    for path in (cert_file, key_file, ca_file):
        if path is not None and not path.is_file():
            sys.exit(f"ファイルが見つかりません: {path}")

    return Settings(
        endpoint=values["endpoint"],
        port=int(os.environ.get("IOT_PORT", "").strip() or DEFAULT_PORT),
        ca_file=ca_file,
        cert_file=cert_file,
        key_file=key_file,
        thing_name=values["thing_name"],
        topic_root=os.environ.get("IOT_TOPIC_ROOT", "").strip() or DEFAULT_TOPIC_ROOT,
    )


def reason_name(code) -> str:
    """MQTT 5 の Reason Code を "NOT_AUTHORIZED(135)" のような表記にする。"""
    if code is None:
        return "なし"
    name = getattr(code, "name", None)
    value = getattr(code, "value", code)
    return f"{name}({value})" if name else str(value)


@dataclass
class ClientState:
    connected: threading.Event = field(default_factory=threading.Event)
    stopped: threading.Event = field(default_factory=threading.Event)
    # 接続が成立するたびにセットされる。SDK は再接続しても再 Subscribe はしないため、
    # Subscriber はこれを見て Subscribe をやり直す。
    subscribe_needed: threading.Event = field(default_factory=threading.Event)
    connect_attempts: int = 0
    connect_failures: int = 0
    disconnections: int = 0


def build_client(
    settings: Settings,
    client_id: str,
    on_publish_received: Optional[Callable] = None,
    session_expiry_sec: Optional[int] = None,
) -> tuple[mqtt5.Client, ClientState]:
    """mTLS (X.509) で接続する MQTT 5 クライアントを生成する。

    接続状態の変化 (ライフサイクルイベント) をすべて標準出力に記録し、
    SDK が自動で行う再接続を観察できるようにしている。
    """
    state = ClientState()

    def on_attempting_connect(_data: mqtt5.LifecycleAttemptingConnectData) -> None:
        state.connect_attempts += 1
        log(
            f"[接続] 試行 #{state.connect_attempts}: {settings.endpoint}:{settings.port} "
            f"client_id={client_id}"
        )

    def on_connection_success(data: mqtt5.LifecycleConnectSuccessData) -> None:
        connack = data.connack_packet
        negotiated = data.negotiated_settings
        log(
            f"[接続] 成功: CONNACK reason={reason_name(connack.reason_code)} "
            f"session_present={connack.session_present} "
            f"session_expiry={negotiated.session_expiry_interval_sec}s "
            f"keep_alive={negotiated.server_keep_alive_sec}s"
        )
        state.subscribe_needed.set()
        state.connected.set()

    def on_connection_failure(data: mqtt5.LifecycleConnectFailureData) -> None:
        state.connect_failures += 1
        connack = data.connack_packet
        detail = f"CONNACK reason={reason_name(connack.reason_code)}" if connack else "CONNACK 未受信"
        log(f"[接続] 失敗 #{state.connect_failures}: {detail} / {data.exception!r}")

    def on_disconnection(data: mqtt5.LifecycleDisconnectData) -> None:
        state.connected.clear()
        if getattr(data.exception, "name", "") == "AWS_ERROR_MQTT5_USER_REQUESTED_STOP":
            log("[切断] クライアント側の終了処理により切断しました")
            return
        state.disconnections += 1
        packet = data.disconnect_packet
        detail = (
            f"DISCONNECT reason={reason_name(packet.reason_code)} reason_string={packet.reason_string}"
            if packet
            else "DISCONNECT パケットなし"
        )
        log(f"[切断] {detail} / {data.exception!r}")

    def on_stopped(_data: mqtt5.LifecycleStoppedData) -> None:
        log("[停止] クライアントを停止しました")
        state.stopped.set()

    options = dict(
        endpoint=settings.endpoint,
        port=settings.port,
        cert_filepath=str(settings.cert_file),
        pri_key_filepath=str(settings.key_file),
        client_id=client_id,
        on_publish_received=on_publish_received,
        on_lifecycle_attempting_connect=on_attempting_connect,
        on_lifecycle_connection_success=on_connection_success,
        on_lifecycle_connection_failure=on_connection_failure,
        on_lifecycle_disconnection=on_disconnection,
        on_lifecycle_stopped=on_stopped,
    )
    if settings.ca_file is not None:
        options["ca_filepath"] = str(settings.ca_file)
    if session_expiry_sec:
        # 永続セッション: 切断中の QoS 1 メッセージをブローカー側に保持させる
        options["session_expiry_interval_sec"] = session_expiry_sec
        options["session_behavior"] = mqtt5.ClientSessionBehaviorType.REJOIN_ALWAYS

    return mqtt5_client_builder.mtls_from_path(**options), state


def wait_until(event: threading.Event, timeout_sec: float) -> bool:
    """Ctrl+C を受け付けられるよう短い間隔で待機する (Windows 対策)。"""
    waited = 0.0
    while waited < timeout_sec:
        if event.wait(0.2):
            return True
        waited += 0.2
    return event.is_set()


def stop_client(client: mqtt5.Client, state: ClientState) -> None:
    client.stop()
    state.stopped.wait(OPERATION_TIMEOUT_SEC)
