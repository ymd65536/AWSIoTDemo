"""ダミーテレメトリ (温度・湿度・バッテリー残量) を生成する。

実在の機器や業務データは使わず、乱数によるランダムウォークで値を作る。
単体で実行するとサンプルを標準出力に表示する:

    python src/telemetry_generator.py --count 3
"""

from __future__ import annotations

import argparse
import json
import random
from datetime import datetime, timezone
from typing import Optional


class TelemetryGenerator:
    def __init__(self, device_id: str, seed: Optional[int] = None) -> None:
        self._device_id = device_id
        self._random = random.Random(seed)
        self._sequence = 0
        self._temperature_c = 25.0
        self._humidity_pct = 50.0
        self._battery_pct = 100.0

    def next(self) -> dict:
        self._sequence += 1
        self._temperature_c = _clamp(self._temperature_c + self._random.uniform(-1.5, 1.5), 15.0, 35.0)
        self._humidity_pct = _clamp(self._humidity_pct + self._random.uniform(-2.0, 2.0), 20.0, 90.0)
        self._battery_pct = max(0.0, self._battery_pct - self._random.uniform(0.0, 0.2))
        return {
            "device_id": self._device_id,
            "sequence": self._sequence,
            "timestamp": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
            "temperature_c": round(self._temperature_c, 1),
            "humidity_pct": round(self._humidity_pct, 1),
            "battery_pct": round(self._battery_pct, 1),
        }


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def main() -> None:
    parser = argparse.ArgumentParser(description="ダミーテレメトリのサンプルを表示します")
    parser.add_argument("--device-id", default="sample-device")
    parser.add_argument("--count", type=int, default=5)
    parser.add_argument("--seed", type=int, default=None, help="同じ値を再現したい場合に指定")
    args = parser.parse_args()

    generator = TelemetryGenerator(args.device_id, args.seed)
    for _ in range(args.count):
        print(json.dumps(generator.next()))


if __name__ == "__main__":
    main()
