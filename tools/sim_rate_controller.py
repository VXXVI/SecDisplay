#!/usr/bin/env python3
"""Simulate SecDisplay RateController v2 control law (thresholds mirrored from Swift).

Purpose: verify that the probe/revert guard prevents the Phase 1 180->17 slide,
and that real congestion still decreases bitrate.

This is a logic simulation, not the actual Swift runtime.
"""

from dataclasses import dataclass


@dataclass
class Signals:
    capture_fps: float
    in_flight: int = 0
    encode_ms: float = 0.0
    present_drop: int = 0
    dropped_delta: int = 0
    win_queue_ms: float = 0.0


class RateController:
    def __init__(self, target_mbps: int, capture_hz: float):
        self.target = target_mbps
        self.capture_hz = max(1.0, capture_hz)
        self.current = target_mbps
        self.high_rounds = 0
        self.low_rounds = 0
        self.idle_rounds = 0
        self.last_down_at = -1e9
        self.down_cooldown = 10.0
        self.probe_mbps = None
        self.probe_health = 0.0
        self.probe_min_health = 0.0
        self.probe_at = -1e9
        self.revert_cooldown_until = -1e9
        self.log = []

    def tick(self, s: Signals, now: float) -> None:
        if s.capture_fps < 10:
            self.high_rounds = 0
            self.low_rounds = 0
            if s.in_flight >= 2 or s.dropped_delta > 0:
                self.idle_rounds = 0
                return
            if self.current >= self.target:
                self.idle_rounds = 0
                return
            self.idle_rounds += 1
            if self.idle_rounds < 3:
                return
            self.idle_rounds = 0
            nxt = min(self.target, int(self.current * 1.10) + 1)
            if abs(nxt - self.current) < max(2, int(self.current * 0.05)):
                self.idle_rounds = 0
                return
            self.current = nxt
            self.log.append((now, "idle-up", self.current, 0.0))
            return

        self.idle_rounds = 0
        budget = 1000.0 / self.capture_hz
        encode_load = s.encode_ms / budget
        inflight_load = s.in_flight / 2.0
        win_queue_load = s.win_queue_ms / 15.0
        drop_load = 1.5 if (s.present_drop + s.dropped_delta) >= 2 else 0.0
        encode_guard = encode_load if encode_load > 1.5 else 0.0
        health = max(win_queue_load, drop_load, inflight_load, encode_guard)

        if self.probe_mbps is not None:
            pm = self.probe_mbps
            if now - self.probe_at < 8.0:
                if health < self.probe_health * 0.90:
                    self.probe_mbps = None
                    self.log.append((now, "probe-ok", self.current, health))
                else:
                    self.probe_min_health = min(self.probe_min_health, health)
                return
            improved = self.probe_min_health < self.probe_health * 0.90
            self.probe_mbps = None
            if not improved:
                self.current = pm
                self.revert_cooldown_until = now + 60
                self.log.append((now, "revert", self.current, health))
            return

        if health > 1.15 and now >= self.revert_cooldown_until:
            self.high_rounds += 1
            self.low_rounds = 0
            if self.high_rounds < 2 or now - self.last_down_at < self.down_cooldown:
                return
            self.high_rounds = 0
            self.last_down_at = now
            floor = max(15, self.target // 3)
            nxt = max(floor, int(self.current * 0.90))
            if abs(nxt - self.current) < max(2, int(self.current * 0.05)):
                return
            self.probe_mbps = self.current
            self.probe_health = health
            self.probe_min_health = health
            self.probe_at = now
            self.current = nxt
            self.log.append((now, "down", self.current, health))
        elif health < 0.70:
            self.low_rounds += 1
            self.high_rounds = 0
            if self.low_rounds < 3 or self.current >= self.target:
                return
            self.low_rounds = 0
            nxt = min(self.target, int(self.current * 1.10) + 1)
            if abs(nxt - self.current) < max(2, int(self.current * 0.05)):
                return
            self.current = nxt
            self.log.append((now, "up", self.current, health))
        else:
            self.high_rounds = 0
            self.low_rounds = 0


def run(name, target, hz, signals, ticks=30):
    rc = RateController(target, hz)
    for i in range(ticks):
        rc.tick(signals(i), i * 2.0)
    print(f"\n== {name} ==")
    print(f"start {target} -> end {rc.current} Mbps")
    for t, kind, mbps, health in rc.log:
        print(f"  t={t:5.1f}s {kind:8s} -> {mbps:3d} Mbps health={health:.2f}")
    return rc.current


if __name__ == "__main__":
    # 1) Phase 1 failure: encode latency 36ms at 45fps budget 22.2ms, no queue/drops.
    # encodeLoad 1.62 -> one 10% drop, then probe reverts and cools down. No slide.
    end1 = run("45fps encode-heavy, no queue", 82, 45,
               lambda i: Signals(capture_fps=45, encode_ms=36.0))

    # 2) Real congestion: winQueue 30ms -> health 2.0. Decrease once; health improves
    # to 10ms -> probe keeps. Then health 0.3 for 3 ticks -> slow recovery.
    def congestion(i):
        if i < 4:
            return Signals(capture_fps=45, encode_ms=16.0, win_queue_ms=30.0)
        if i < 12:
            return Signals(capture_fps=45, encode_ms=16.0, win_queue_ms=10.0)
        return Signals(capture_fps=45, encode_ms=16.0, win_queue_ms=0.0)
    end2 = run("real queue congestion then recovery", 82, 45, congestion, ticks=24)

    # 3) Single transient drop should not trigger a decrease.
    end3 = run("single transient drop", 66, 60,
               lambda i: Signals(capture_fps=40, encode_ms=16.0, present_drop=1 if i == 2 else 0),
               ticks=12)

    # 4) Static desktop should recover 10% every 3 ticks, not jump immediately.
    def static(i):
        return Signals(capture_fps=2, in_flight=0, encode_ms=0.0)
    rc = RateController(66, 60)
    rc.current = 30
    for i in range(18):
        rc.tick(static(i), i * 2.0)
    print("\n== static recovery ==")
    print(f"start 30 -> end {rc.current} Mbps")
    for t, kind, mbps, health in rc.log:
        print(f"  t={t:5.1f}s {kind:8s} -> {mbps:3d} Mbps")

    print("\nSummary:")
    print(f"  45fps encode-heavy ends at {end1} Mbps (expect ~74, not 15)")
    print(f"  real congestion ends at {end2} Mbps (expect decrease then recovery)")
    print(f"  single drop ends at {end3} Mbps (expect unchanged 66)")
