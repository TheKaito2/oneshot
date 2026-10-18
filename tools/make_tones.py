"""Lock feedback tones (Dash Cart idea: a bright beep = logged, a low double beep = check).

Writes OneShot/Resources/ok.wav and check.wav. Run: python3 tools/make_tones.py
"""
import math
import struct
import wave
from pathlib import Path

RATE = 44_100


def tone(freq: float, ms: int, volume: float = 0.45) -> list[int]:
    n = RATE * ms // 1000
    fade = RATE * 8 // 1000  # 8 ms in/out, so there's no click
    out = []
    for i in range(n):
        envelope = min(1.0, i / fade, (n - i) / fade)
        out.append(int(32767 * volume * envelope * math.sin(2 * math.pi * freq * i / RATE)))
    return out


def silence(ms: int) -> list[int]:
    return [0] * (RATE * ms // 1000)


def write(path: Path, samples: list[int]) -> None:
    with wave.open(str(path), "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(RATE)
        f.writeframes(struct.pack(f"<{len(samples)}h", *samples))


if __name__ == "__main__":
    out = Path(__file__).resolve().parent.parent / "OneShot" / "Resources"
    write(out / "ok.wav", tone(880, 80) + tone(1320, 140))                       # rising two-tone
    write(out / "check.wav", tone(440, 120) + silence(70) + tone(440, 120))      # low double beep
    print("wrote", out / "ok.wav", out / "check.wav")
