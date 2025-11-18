# EURUSD Trend Breakout Strategy

**Version 1.1.0** - [See CHANGELOG.md](CHANGELOG.md) for latest updates

This repository contains a complete prototype of a discretionary trend breakout strategy for EURUSD implemented for MetaTrader 5 and an accompanying Python analytics script. The system is built around a Donchian breakout with a higher time-frame trend filter and disciplined risk management.

## 🆕 Latest Updates (v1.1.0 - 2025-11-15)

### Critical Improvements
- ✅ **News filter implemented** - Protects against high-impact news events (now calendar-driven with MT5/file sources)
- ✅ **Weekly limits bug fixed** - Now works correctly regardless of EA start day
- ✅ **Optional fixed TP** - Can now let winners run (recommended: `UseFixedTP = false`)
- ✅ **Break-even at 1.5R** - Less aggressive, fewer premature exits
- ✅ **Relaxed H4 filter** - 2-3x more signals while maintaining quality

See [IMPROVEMENT_PLAN.md](docs/IMPROVEMENT_PLAN.md) for detailed roadmap and future enhancements.

## Project Structure

- `experts/EURUSD_TrendBreakout.mq5` – MetaTrader 5 Expert Advisor implementing the Donchian breakout with retest entries, H4 trend regime filter, risk controls, trade logging, and position management.
- `scripts/analyze_trades.py` – Offline analytics utility that reads the CSV trade log produced by the EA and summarises performance metrics.
- `README.md` – Strategy overview and repository guide.

## Strategy Highlights

1. **Trend Regime Detection (H4)** – EMA(200) slope and MACD alignment define bullish, bearish, or flat regimes. Open trades are closed on regime reversal.
2. **Signal Generation (H1)** – Donchian (20) breakout, EMA(50), MACD confirmation, ATR filter, and trading session window gate new signals.
3. **Retest Entry** – Upon confirmed breakout, a single limit order is placed with ATR-based stop, fixed 1:2 risk-reward target, and order expiry after a configurable number of bars.
4. **Risk Management** – Position size derived from 0.5% equity risk, plus daily and weekly drawdown blocks.
5. **Trade Handling** – Break-even promotion at 1R, trailing stop on local swings, and comprehensive CSV logging for downstream analytics.

Refer to each source file for detailed implementation notes.

## Analytics usage and tests

The Python analytics utility can be run directly from the repository root against a trade log CSV:

```
python scripts/analyze_trades.py MQL5/Files/eurusd_trades_log.csv
```

It prints a concise summary, for example:

```
EURUSD Trend Breakout – Trade Summary
Total trades: 120
Win rate: 48.33 %
Total profit (money): 354.20
Total profit (R): 36.50
Average R (winners): 1.35
Average R (losers): -0.42
Max consecutive losses: 3
Max equity drawdown: -6.20 %
```

Run the accompanying tests to validate the analytics helpers:

```
pip install -r requirements.txt
./scripts/run_tests.sh
```

or simply:

```
pip install -r requirements.txt
make test
```
