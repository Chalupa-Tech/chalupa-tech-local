"""Historical replay of the climate-balance decision engine.

Reads exported HA recorder data (CSV: metadata_id,last_updated_ts,state)
for the six input sensors, forward-fills to align timestamps, and runs
decision_engine.evaluate() at each tick. Outputs a matplotlib chart
with the indoor/outside temp lines, target lines, and a color-coded
mode timeline at the top.

Run from `homeassistant/`:
    source .venv/bin/activate
    pip install matplotlib
    python scripts/backtest.py /tmp/ha_backtest/states.csv out.png

The metadata_id → entity mapping is hard-coded for this HAOS instance.
If you re-export from a different HA instance, regenerate the IDs via:
    SELECT metadata_id, entity_id FROM states_meta WHERE entity_id IN (...);
"""
from __future__ import annotations

import csv
import sys
from datetime import datetime, timezone
from pathlib import Path

# Make pyscript/modules/ importable when run from homeassistant/
sys.path.insert(0, str(Path(__file__).parent.parent / "pyscript" / "modules"))

from decision_engine import ClimateState, Config, Mode, evaluate  # noqa: E402


METADATA_TO_SENSOR = {
    100: "indoor_temp",
    102: "indoor_rh",
    8717: "outside_rh",
    8721: "outside_temp",
    9650: "attic_temp",
    9652: "attic_rh",
}

# Config snapshot used for the backtest. Mirrors the HA helper defaults.
CFG = Config(
    enabled=True,
    vacation=False,
    target_temp_f=70.0,
    whf_target_f=68.0,
    max_indoor_rh=45.0,
    max_attic_rh=45.0,
    max_dew_point_f=60.0,
)

MODE_COLOR = {
    Mode.OFF:           "#d9d9d9",
    Mode.WHF_ONLY:      "#74c476",
    Mode.COOLER_FULL:   "#2171b5",
    Mode.COOLER_QUIET:  "#6baed6",
    Mode.DEHUMIDIFY:    "#9e9ac8",
    Mode.RECIRCULATE:   "#fdae6b",
}


def parse_csv(path: Path):
    """Yield (ts_float, sensor_name, value_float) tuples in timestamp order."""
    with open(path) as f:
        for row in csv.reader(f):
            if len(row) != 3:
                continue
            md = int(row[0])
            name = METADATA_TO_SENSOR.get(md)
            if not name:
                continue
            try:
                ts = float(row[1])
                value = float(row[2])
            except ValueError:
                continue
            yield ts, name, value


def build_ticks(events):
    """Forward-fill sensor values; emit one (ts, state_dict) per event timestamp.

    Returns a list of (ts, ClimateState) tuples after all six sensors have
    been seen at least once (so we can build a full ClimateState).
    """
    latest: dict[str, float] = {}
    ticks = []
    seen_all = False
    required = set(METADATA_TO_SENSOR.values())
    for ts, name, value in events:
        latest[name] = value
        if not seen_all:
            if required.issubset(latest):
                seen_all = True
            else:
                continue
        ticks.append((ts, ClimateState(
            outside_temp_f=latest["outside_temp"],
            outside_rh_pct=latest["outside_rh"],
            indoor_temp_f=latest["indoor_temp"],
            indoor_rh_pct=latest["indoor_rh"],
            attic_temp_f=latest["attic_temp"],
            attic_rh_pct=latest["attic_rh"],
        )))
    return ticks


def replay_stateless(ticks):
    """Replay using the OLD evaluate() behavior (prev_mode=None always).

    Approximates what the engine would have done before adding asymmetric
    hysteresis. Useful as a comparison baseline.
    """
    out = []
    for ts, state in ticks:
        now = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone()
        d = evaluate(state, CFG, now.replace(tzinfo=None), prev_mode=None)
        out.append((ts, state, d))
    return out


def replay_with_hysteresis_and_min_runtime(ticks, min_runtime_seconds=600):
    """Replay with full production semantics:
    - Asymmetric hysteresis: prev_mode is the EFFECTIVE engaged mode (not the
      engine's raw last decision), so once min-runtime holds the device in a
      mode, the engine sees that mode on subsequent ticks.
    - 10-min minimum runtime: a wanted mode change is only applied if at least
      that long has passed since the last applied transition.
    """
    if not ticks:
        return [], []
    out = []
    transitions = []
    effective_mode = None
    effective_decision = None
    last_change_ts = ticks[0][0]
    for ts, state in ticks:
        now = datetime.fromtimestamp(ts, tz=timezone.utc).astimezone()
        d = evaluate(state, CFG, now.replace(tzinfo=None), prev_mode=effective_mode)

        cold_start = effective_mode is None
        cooldown_done = (ts - last_change_ts) >= min_runtime_seconds
        if cold_start or (d.mode != effective_mode and cooldown_done):
            effective_mode = d.mode
            effective_decision = d
            last_change_ts = ts
            transitions.append((ts, d))
        out.append((ts, state, effective_decision))
    return out, transitions


def find_transitions(replayed):
    """Return list of (ts, Decision) where mode changed from previous tick."""
    transitions = []
    last_mode: Mode | None = None
    for ts, _, d in replayed:
        if d.mode != last_mode:
            transitions.append((ts, d))
            last_mode = d.mode
    return transitions


MIN_RUNTIME_SECONDS = 10 * 60  # 10 minutes per spec


def mode_summary(replayed):
    """Return dict of mode → cumulative seconds spent in mode."""
    totals: dict[Mode, float] = {}
    last_ts = None
    last_mode = None
    for ts, _, d in replayed:
        if last_ts is not None and last_mode is not None:
            totals[last_mode] = totals.get(last_mode, 0.0) + (ts - last_ts)
        last_ts = ts
        last_mode = d.mode
    return totals


def plot(replayed, raw_transitions, effective_ticks, effective_transitions, out_path):
    import matplotlib.pyplot as plt
    import matplotlib.dates as mdates
    from matplotlib.patches import Patch

    ts_list = [datetime.fromtimestamp(ts) for ts, _, _ in replayed]
    indoor = [s.indoor_temp_f for _, s, _ in replayed]
    outside = [s.outside_temp_f for _, s, _ in replayed]
    attic = [s.attic_temp_f for _, s, _ in replayed]
    indoor_rh = [s.indoor_rh_pct for _, s, _ in replayed]
    outside_rh = [s.outside_rh_pct for _, s, _ in replayed]
    attic_rh = [s.attic_rh_pct for _, s, _ in replayed]

    fig, (ax_raw, ax_eff, ax_t, ax_rh) = plt.subplots(
        4, 1, figsize=(16, 11),
        gridspec_kw={"height_ratios": [0.5, 0.5, 2, 1.5]},
        sharex=True,
    )

    def shade(ax, transitions, end_ts):
        for i, (ts, d) in enumerate(transitions):
            seg_end = transitions[i + 1][0] if i + 1 < len(transitions) else end_ts
            ax.axvspan(
                datetime.fromtimestamp(ts), datetime.fromtimestamp(seg_end),
                color=MODE_COLOR[d.mode], alpha=0.9,
            )
        ax.set_ylim(0, 1)
        ax.set_yticks([])

    end_ts = replayed[-1][0]
    shade(ax_raw, raw_transitions, end_ts)
    shade(ax_eff, effective_transitions, end_ts)
    ax_raw.set_title("Climate Balance — 7-day backtest (replay against HA recorder history)")
    ax_raw.set_ylabel(f"No hysteresis\n({len(raw_transitions)} txns)", fontsize=8)
    ax_eff.set_ylabel(
        f"+ hysteresis\n+ 10-min min-runtime\n({len(effective_transitions)} txns)",
        fontsize=8,
    )

    # Temperature plot
    ax_t.plot(ts_list, outside, label="Outside", color="#c0392b", linewidth=1.0)
    ax_t.plot(ts_list, indoor, label="Indoor (avg)", color="#2c3e50", linewidth=1.5)
    ax_t.plot(ts_list, attic, label="Attic", color="#8e44ad", linewidth=0.7, alpha=0.5)
    ax_t.axhline(CFG.target_temp_f, color="#27ae60", linestyle="--", linewidth=0.8, alpha=0.7,
                 label=f"Cooling target ({CFG.target_temp_f:.0f}°F)")
    ax_t.axhline(CFG.whf_target_f, color="#16a085", linestyle=":", linewidth=0.8, alpha=0.7,
                 label=f"WHF target ({CFG.whf_target_f:.0f}°F)")
    ax_t.set_ylabel("Temperature (°F)")
    ax_t.legend(loc="upper left", fontsize=8)
    ax_t.grid(alpha=0.2)

    # Humidity plot
    ax_rh.plot(ts_list, outside_rh, label="Outside RH", color="#c0392b", linewidth=0.8)
    ax_rh.plot(ts_list, indoor_rh, label="Indoor RH", color="#2c3e50", linewidth=1.2)
    ax_rh.plot(ts_list, attic_rh, label="Attic RH", color="#8e44ad", linewidth=0.7, alpha=0.5)
    ax_rh.axhline(CFG.max_indoor_rh, color="#27ae60", linestyle="--", linewidth=0.8, alpha=0.7,
                  label=f"Max indoor RH ({CFG.max_indoor_rh:.0f}%)")
    ax_rh.axhline(CFG.max_attic_rh, color="#8e44ad", linestyle=":", linewidth=0.8, alpha=0.7,
                  label=f"Max attic RH ({CFG.max_attic_rh:.0f}%)")
    ax_rh.set_ylabel("Relative Humidity (%)")
    ax_rh.legend(loc="upper left", fontsize=8)
    ax_rh.grid(alpha=0.2)
    ax_rh.set_xlabel("Local time")

    # X-axis formatting
    ax_rh.xaxis.set_major_locator(mdates.DayLocator())
    ax_rh.xaxis.set_major_formatter(mdates.DateFormatter("%a %m-%d"))
    ax_rh.xaxis.set_minor_locator(mdates.HourLocator(interval=6))

    # Legend for mode colors
    mode_legend = [Patch(facecolor=c, label=m.value) for m, c in MODE_COLOR.items()]
    ax_raw.legend(handles=mode_legend, loc="upper left", fontsize=8, ncol=6, framealpha=0.9)

    plt.tight_layout()
    plt.savefig(out_path, dpi=120, bbox_inches="tight")
    print(f"saved: {out_path}")


def peak_cycles_per_hour(transitions):
    """Compute the worst 60-minute sliding-window cycle count.
    One cycle = 2 transitions (on then off), so cycles = transitions / 2.
    """
    if len(transitions) < 2:
        return 0.0
    timestamps = [ts for ts, _ in transitions]
    peak = 0
    for i in range(len(timestamps)):
        end = timestamps[i] + 3600
        count = sum(1 for ts in timestamps[i:] if ts < end)
        peak = max(peak, count)
    return peak / 2.0  # transitions → cycles


def print_summary(replayed, raw_transitions, effective_ticks, effective_transitions):
    raw_totals = mode_summary(replayed)
    eff_totals = mode_summary(effective_ticks)
    total_seconds = sum(raw_totals.values())
    print(f"\n=== Backtest summary ===")
    print(f"Window: {datetime.fromtimestamp(replayed[0][0])} → "
          f"{datetime.fromtimestamp(replayed[-1][0])}")
    print(f"Ticks evaluated: {len(replayed)}")
    print(f"Transitions — raw (stateless engine): {len(raw_transitions)}  "
          f"peak {peak_cycles_per_hour(raw_transitions):.1f} cycles/hr")
    print(f"Transitions — production (hysteresis + min-runtime): "
          f"{len(effective_transitions)}  "
          f"peak {peak_cycles_per_hour(effective_transitions):.1f} cycles/hr")
    print(f"\nTime in each mode (raw → with min-runtime):")
    for mode in Mode:
        raw_h = raw_totals.get(mode, 0.0) / 3600
        eff_h = eff_totals.get(mode, 0.0) / 3600
        raw_pct = 100 * raw_totals.get(mode, 0.0) / total_seconds if total_seconds else 0
        eff_pct = 100 * eff_totals.get(mode, 0.0) / total_seconds if total_seconds else 0
        print(f"  {mode.value:14s} {raw_h:6.1f} h ({raw_pct:5.1f}%)  →  "
              f"{eff_h:6.1f} h ({eff_pct:5.1f}%)")

    print(f"\nProduction-realistic transitions (after 10-min min-runtime):")
    for ts, d in effective_transitions:
        print(f"  {datetime.fromtimestamp(ts).strftime('%a %m-%d %H:%M:%S')}  "
              f"→ {d.mode.value:14s}  {d.reason}")


def main():
    if len(sys.argv) != 3:
        print("usage: backtest.py <states.csv> <out.png>", file=sys.stderr)
        sys.exit(2)
    csv_path = Path(sys.argv[1])
    out_path = Path(sys.argv[2])

    events = list(parse_csv(csv_path))
    print(f"parsed {len(events)} events")
    ticks = build_ticks(events)
    print(f"built {len(ticks)} ticks (after all sensors seen)")

    # Baseline: engine without hysteresis (stateless prev_mode=None), no min-runtime
    raw_replay = replay_stateless(ticks)
    raw_transitions = find_transitions(raw_replay)

    # Production: hysteresis + min-runtime
    effective_ticks, effective_transitions = replay_with_hysteresis_and_min_runtime(
        ticks, min_runtime_seconds=MIN_RUNTIME_SECONDS,
    )

    print_summary(raw_replay, raw_transitions, effective_ticks, effective_transitions)
    plot(raw_replay, raw_transitions, effective_ticks, effective_transitions, out_path)


if __name__ == "__main__":
    main()
