#!/usr/bin/env python3
"""Synthesize the v2 sound packs (P2) as small mono WAV files.

Generated cues land in Resources/Sounds/<pack>/ with these canonical names:
  coin.wav   — single small consumption
  coins.wav  — higher pulse tier
  chime.wav  — closing bell / startup chime

Pure stdlib synthesis (sine partials + exponential decay + tiny noise), so the
assets contain no third-party samples and are reproducible from this script.
The coin pack deliberately keeps the two user-provided flat MP3 cues and only
generates its missing chime. Re-run after tweaking:
    python3 scripts/gen_sound_packs.py
"""
import math
import os
import random
import struct
import wave

RATE = 22050
OUT_ROOT = os.path.join(os.path.dirname(__file__), "..", "Resources", "Sounds")


def write_wav(path: str, samples: list[float]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    peak = max(1e-9, max(abs(s) for s in samples))
    scale = 0.85 / peak if peak > 0.85 else 1.0
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(
            struct.pack("<h", int(max(-1.0, min(1.0, s * scale)) * 32767))
            for s in samples))


def silence(seconds: float) -> list[float]:
    return [0.0] * int(RATE * seconds)


def ping(freq: float, seconds: float, decay: float = 9.0, partials=((1.0, 1.0), (2.7, 0.35))) -> list[float]:
    """Bright struck-bar partials with exponential decay."""
    n = int(RATE * seconds)
    out = []
    for i in range(n):
        t = i / RATE
        env = math.exp(-decay * t)
        s = sum(amp * math.sin(2 * math.pi * freq * mult * t) for mult, amp in partials)
        out.append(s * env)
    return out


def mix_at(base: list[float], voice: list[float], at_seconds: float) -> None:
    start = int(RATE * at_seconds)
    need = start + len(voice)
    if need > len(base):
        base.extend([0.0] * (need - len(base)))
    for i, s in enumerate(voice):
        base[start + i] += s


def drop(seconds: float = 0.28, f0: float = 900.0, f1: float = 1500.0) -> list[float]:
    """Water drop: sine gliding up into a plop, fast decay."""
    n = int(RATE * seconds)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / RATE
        f = f0 + (f1 - f0) * (t / seconds) ** 2
        phase += 2 * math.pi * f / RATE
        env = math.exp(-7.0 * t) * (1.0 - math.exp(-220.0 * t))
        out.append(math.sin(phase) * env)
    return out


def noise_burst(seconds: float, decay: float = 30.0, seed: int = 7) -> list[float]:
    rnd = random.Random(seed)
    n = int(RATE * seconds)
    return [(rnd.random() * 2 - 1) * math.exp(-decay * i / RATE) for i in range(n)]


def seq(*voices: tuple[float, list[float]]) -> list[float]:
    out: list[float] = []
    for at, v in voices:
        mix_at(out, v, at)
    return out


E6 = 1318.5
B5 = 987.8
G6 = 1568.0
C6 = 1046.5

packs = {
    # Coin: preserve Resources/coin.mp3 and Resources/coins.mp3 supplied by the
    # project owner. Only the missing chime is synthesized here.
    "coin": {
        "chime": seq((0.0, ping(C6, 0.5, decay=4.0)), (0.18, ping(G6, 0.9, decay=3.0))),
    },
    # 水滴 Droplet: "花钱如流水" — drops for spend, a slow triple drip for the bell.
    "droplet": {
        "coin": drop(0.30),
        "coins": seq((0.00, drop(0.24, 1000, 1700)), (0.12, drop(0.24, 850, 1500)),
                     (0.26, drop(0.26, 1100, 1800)), (0.40, drop(0.30, 900, 1600))),
        "chime": seq((0.00, drop(0.35, 800, 1400)), (0.45, drop(0.35, 950, 1550)),
                     (0.95, drop(0.55, 700, 1500))),
    },
    # 收银机 Register: cha-ching for a sale, drawer + bells for a shower.
    "register": {
        "coin": seq((0.0, ping(2100.0, 0.18, decay=11.0, partials=((1.0, 1.0), (2.4, 0.5)))),
                    (0.06, noise_burst(0.10, decay=60.0)),
                    (0.10, ping(2800.0, 0.30, decay=8.0, partials=((1.0, 1.0), (1.8, 0.4))))),
        "coins": seq((0.00, noise_burst(0.22, decay=26.0)),
                     *[(0.10 + 0.09 * i, ping(f, 0.2, decay=10.0,
                                               partials=((1.0, 1.0), (2.4, 0.5))))
                       for i, f in enumerate((1800.0, 2100.0, 2600.0, 2100.0, 1800.0, 2600.0))]),
        "chime": seq((0.0, ping(1568.0, 0.7, decay=3.5)), (0.25, ping(1046.5, 1.1, decay=2.6))),
    },
}

for pack, cues in packs.items():
    for cue, samples in cues.items():
        path = os.path.join(OUT_ROOT, pack, f"{cue}.wav")
        write_wav(path, samples)
        print(f"{path}  ({len(samples) / RATE:.2f}s)")
