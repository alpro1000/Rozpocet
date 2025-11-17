#!/usr/bin/env python3
"""Trade log analytics for the EURUSD Trend Breakout EA.

Usage
-----
Run directly from the repository root:

```
python scripts/analyze_trades.py MQL5/Files/eurusd_trades_log.csv
```

Example output:

```
EURUSD Trend Breakout – Trade Summary
==================================================
Total trades: 120
Win rate: 48.33 %
Total profit (money): 354.20
Total profit (R): 36.50
Average R (winners): 1.35
Average R (losers): -0.42
Max consecutive losses: 3
Max equity drawdown: -6.20 %
```
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Dict, Any
import calendar

import pandas as pd


DEFAULT_LOG_PATH = Path(__file__).resolve().parents[1] / "MQL5" / "Files" / "eurusd_trades_log.csv"


def load_trades(path: Path) -> pd.DataFrame:
    """Load the trade CSV into a DataFrame."""
    if not path.exists():
        raise FileNotFoundError(f"CSV file not found: {path}")

    df = pd.read_csv(path)
    if df.empty:
        raise ValueError("CSV file contains no trades")

    # Ensure datetime parsing
    for col in ["datetime_open", "datetime_close"]:
        if col in df.columns:
            df[col] = pd.to_datetime(df[col])

    numeric_cols = [
        "entry_price",
        "stop_loss",
        "take_profit",
        "exit_price",
        "lot_size",
        "profit_money",
        "profit_pips",
        "R_multiple",
        "balance_after_trade",
        "equity_after_trade",
    ]
    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")

    df = df.dropna(subset=["profit_money"]).copy()
    df.sort_values("datetime_close", inplace=True)
    df.reset_index(drop=True, inplace=True)
    return df


def compute_stats(df: pd.DataFrame) -> Dict[str, Any]:
    """Compute core performance metrics."""
    total_trades = len(df)
    winners = df[df["profit_money"] > 0]
    losers = df[df["profit_money"] < 0]

    total_profit_money = df["profit_money"].sum()
    total_profit_r = df["R_multiple"].sum() if "R_multiple" in df else float("nan")

    win_rate = 100.0 * len(winners) / total_trades if total_trades else 0.0
    avg_r_winners = winners["R_multiple"].mean() if not winners.empty else 0.0
    avg_r_losers = losers["R_multiple"].mean() if not losers.empty else 0.0

    # Max consecutive losses
    loss_streak = 0
    max_loss_streak = 0
    for profit in df["profit_money"]:
        if profit < 0:
            loss_streak += 1
        else:
            max_loss_streak = max(max_loss_streak, loss_streak)
            loss_streak = 0
    max_loss_streak = max(max_loss_streak, loss_streak)

    # Equity drawdown based on equity_after_trade column
    if "equity_after_trade" in df:
        equity = df["equity_after_trade"].ffill()  # Fixed: removed deprecated method parameter
        peak = equity.cummax()
        denom = peak.replace(0, pd.NA)
        drawdowns = (equity - peak) / denom
        if drawdowns.dropna().empty:
            max_drawdown = float("nan")
        else:
            max_drawdown = drawdowns.min() * 100.0
    else:
        max_drawdown = float("nan")

    # Distribution by weekday/hour
    if "datetime_open" in df:
        weekday_series = df["datetime_open"].dt.dayofweek
        weekday_counts = {
            calendar.day_name[idx]: int(count)
            for idx, count in weekday_series.value_counts().sort_index().items()
        }
        hour_counts = {
            int(hour): int(count)
            for hour, count in df.groupby(df["datetime_open"].dt.hour).size().sort_index().items()
        }
    else:
        weekday_counts = {}
        hour_counts = {}

    return {
        "total_trades": total_trades,
        "win_rate": win_rate,
        "total_profit_money": total_profit_money,
        "total_profit_r": total_profit_r,
        "avg_r_winners": avg_r_winners,
        "avg_r_losers": avg_r_losers,
        "max_consecutive_losses": max_loss_streak,
        "max_drawdown_pct": max_drawdown,
        "weekday_counts": weekday_counts,
        "hour_counts": hour_counts,
    }


def print_report(stats: Dict[str, Any]) -> None:
    """Print a human-friendly report."""
    print("EURUSD Trend Breakout – Trade Summary")
    print("=" * 50)
    print(f"Total trades: {stats['total_trades']}")
    print(f"Win rate: {stats['win_rate']:.2f} %")
    print(f"Total profit (money): {stats['total_profit_money']:.2f}")
    print(f"Total profit (R): {stats['total_profit_r']:.2f}")
    print(f"Average R (winners): {stats['avg_r_winners']:.2f}")
    print(f"Average R (losers): {stats['avg_r_losers']:.2f}")
    print(f"Max consecutive losses: {stats['max_consecutive_losses']}")
    drawdown = stats['max_drawdown_pct']
    if pd.notna(drawdown):
        print(f"Max equity drawdown: {drawdown:.2f} %")
    else:
        print("Max equity drawdown: n/a")

    if stats["weekday_counts"]:
        print("\nTrades by weekday:")
        for day, count in stats["weekday_counts"].items():
            print(f"  {day}: {count}")

    if stats["hour_counts"]:
        print("\nTrades by entry hour:")
        for hour, count in sorted(stats["hour_counts"].items()):
            print(f"  {hour:02d}:00 – {count}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyse EURUSD Trend Breakout trade logs")
    parser.add_argument("path", nargs="?", default=str(DEFAULT_LOG_PATH), help="Path to the CSV file")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    path = Path(args.path).expanduser().resolve()

    try:
        df = load_trades(path)
    except Exception as exc:  # noqa: BLE001
        print(f"Error loading trades: {exc}", file=sys.stderr)
        return 1

    stats = compute_stats(df)
    print_report(stats)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
