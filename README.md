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

## News calendar input

- The Expert Advisor can now load high-impact events from either the MT5 Economic Calendar or a CSV/JSON file located under `MQL5/Files`.
- Configure the source via inputs:
  - `NewsCalendarSource` – `"file"` (default) or `"mt5"`
  - `NewsCalendarFilePath` – filename for on-disk calendars (e.g., `news_calendar.csv`)
  - `NewsBlockMinutesBefore/After` – symmetric buffers applied around each event
- File format (CSV example): `datetime,currency,impact,title` where `impact` accepts `high|medium|low`. See `experts/news_calendar_sample.csv` for a template.
- When an event blocks trading, the EA logs the event name, currency, time, and configured buffer for clearer backtests.
