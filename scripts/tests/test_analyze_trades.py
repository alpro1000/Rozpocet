from pathlib import Path

import math
import pytest

from scripts.analyze_trades import compute_stats, load_trades, print_report


@pytest.fixture()
def fixtures_dir() -> Path:
    return Path(__file__).parent / "fixtures"


def test_load_trades_filters_nan_and_sorts(fixtures_dir: Path) -> None:
    df = load_trades(fixtures_dir / "trades_sample.csv")

    assert len(df) == 4
    assert df["profit_money"].isna().sum() == 0
    assert df["datetime_close"].is_monotonic_increasing


def test_compute_stats_returns_expected_metrics(fixtures_dir: Path) -> None:
    df = load_trades(fixtures_dir / "trades_sample.csv")
    stats = compute_stats(df)

    assert stats["total_trades"] == 4
    assert stats["win_rate"] == pytest.approx(50.0)
    assert stats["total_profit_money"] == pytest.approx(100.0)
    assert stats["total_profit_r"] == pytest.approx(1.5)
    assert stats["avg_r_winners"] == pytest.approx(1.125)
    assert stats["avg_r_losers"] == pytest.approx(-0.375)
    assert stats["max_consecutive_losses"] == 2
    assert stats["max_drawdown_pct"] == pytest.approx(-0.74, rel=0.05)
    assert stats["weekday_counts"] == {"Tuesday": 1, "Wednesday": 2, "Thursday": 1}
    assert stats["hour_counts"] == {9: 1, 10: 1, 15: 1, 16: 1}


def test_compute_stats_handles_missing_optional_columns(fixtures_dir: Path) -> None:
    df = load_trades(fixtures_dir / "trades_missing_columns.csv")
    stats = compute_stats(df)

    assert stats["total_trades"] == 2
    assert math.isnan(stats["max_drawdown_pct"])
    assert stats["weekday_counts"] == {}
    assert stats["hour_counts"] == {}


def test_load_trades_errors_on_empty_file(fixtures_dir: Path) -> None:
    with pytest.raises(ValueError):
        load_trades(fixtures_dir / "trades_empty.csv")


def test_print_report_outputs_key_lines(fixtures_dir: Path, capsys: pytest.CaptureFixture[str]) -> None:
    stats = compute_stats(load_trades(fixtures_dir / "trades_sample.csv"))

    print_report(stats)
    captured = capsys.readouterr().out

    assert "EURUSD Trend Breakout – Trade Summary" in captured
    assert "Total trades: 4" in captured
    assert "Win rate: 50.00 %" in captured
    assert "Max equity drawdown: -0.74 %" in captured
    assert "Trades by weekday:" in captured
    assert "Trades by entry hour:" in captured
