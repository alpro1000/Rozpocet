# Техническое задание: EURUSD Trend Breakout Strategy

## 1. Общий обзор

- **Инструмент:** EURUSD
- **Таймфреймы:**
  - H4 — фильтр тренда
  - H1 — поиск сигналов и ведение сделки
- **Тип стратегии:** трендовая, пробой диапазона + ретест уровня, вход лимитным ордером
- **Режим:** одновременно допускается только одна позиция (long или short) по EURUSD, без усреднений и доливок
- **Тип ордеров входа:** Buy Limit / Sell Limit (ретест уровня после пробоя)

## 2. Внешние параметры (Inputs)

| Параметр | Значение по умолчанию | Описание |
| --- | --- | --- |
| `RiskPerTradePercent` | 0.5 | риск на сделку в % от equity |
| `MaxDailyLossPercent` | 2.0 | лимит убытка за день, % от equity на начало дня |
| `MaxWeeklyLossPercent` | 5.0 | лимит убытка за неделю, % от equity на начало недели |
| `H4_EMA_Period` | 200 | период EMA на H4 |
| `H1_EMA_Fast_Period` | 50 | период EMA на H1 |
| `Donchian_Period` | 20 | количество закрытых H1 баров для уровня |
| `MACD_Fast` | 12 | быстрый период MACD |
| `MACD_Slow` | 26 | медленный период MACD |
| `MACD_Signal` | 9 | период сигнальной линии MACD |
| `ATR_Period` | 14 | период ATR |
| `BreakBufferPips` | 5 | минимальный «чистый» пробой уровня (в пипсах) |
| `EntryOffsetPips` | 1 | смещение цены лимитного ордера от уровня (в пипсах) |
| `SL_ATR_Multiplier` | 1.5 | множитель ATR для стоп-лосса |
| `MinSLDistancePips` | 8 | минимальное расстояние стопа в пипсах |
| `RR_Multiplier` | 2.0 | целевое соотношение TP:SL |
| `Min_ATR_Filter` | 4 | минимальное значение ATR(H1) в пипсах, ниже — не торгуем |
| `MaxRetestBars` | 5 | сколько H1 баров ждать срабатывания лимитного ордера |
| `BE_OffsetPips` | 1 | смещение стопа при переходе в безубыток |
| `TrailingBufferPips` | 2 | отступ при трейлинг-стопе (в пипсах) |
| `TradingStartHour` | 7 | начало торговли (по времени сервера) |
| `TradingEndHour` | 22 | конец торговли (по времени сервера) |
| `UseNewsFilter` | true/false | включение фильтра новостей |
| `NewsBlockMinutesBefore` | 30 | блокировка до новости |
| `NewsBlockMinutesAfter` | 30 | блокировка после новости |

**Пипсы:** для EURUSD считать, что 1 пип = 0.0001. В MQL4/5 требуется переводить пипсы в Points с учётом `Digits`.

## 3. Индикаторы

### 3.1. H4

- `EMA_H4_200` = EMA(Close, 200)
- `MACD_H4_main`, `MACD_H4_signal` = MACD(12, 26, 9) по Close
- `ATR_H4_14` = ATR(14)

### 3.2. H1

- `EMA_H1_50` = EMA(Close, 50)
- Donchian Channel (период `Donchian_Period`, по закрытым барам):
  - `R` = максимум High за последние `Donchian_Period` закрытых баров H1 (t-1 … t-Donchian_Period)
  - `S` = минимум Low за те же бары
- `MACD_H1_main`, `MACD_H1_signal` = MACD(12, 26, 9)
- `ATR_H1_14` = ATR(14)

## 4. Режим тренда (H4)

Режим обновляется по закрытию каждого H4 бара.

### 4.1. LONG-режим

1. `Close_H4[t] > EMA_H4_200[t]`
2. EMA_200 не снижается минимум на 4 из последних 5 баров (`EMA_H4_200[k] >= EMA_H4_200[k-1]` для k = t … t-4)
3. `MACD_H4_main[t] > MACD_H4_signal[t]`

Если все условия выполняются, режим = LONG.

### 4.2. SHORT-режим

1. `Close_H4[t] < EMA_H4_200[t]`
2. EMA_200 не растёт минимум на 4 из последних 5 баров (`EMA_H4_200[k] <= EMA_H4_200[k-1]` для k = t … t-4)
3. `MACD_H4_main[t] < MACD_H4_signal[t]`

Если все условия выполняются, режим = SHORT.

### 4.3. FLAT-режим

Если условия LONG и SHORT не выполняются, режим = FLAT, новые сделки не открываются.

### 4.4. Смена режима при открытой позиции

Если при закрытии H4 бара режим сменился противоположно текущей позиции, позицию закрыть по рынку на ближайшем закрытии H1 бара.

## 5. Логика входа на H1

### 5.1. Торговые часы

Сигналы игнорируются, если:

- Текущий час вне диапазона `[TradingStartHour, TradingEndHour)`.
- Превышены дневные или недельные лимиты убытков.
- Активен блок новостей (`UseNewsFilter = true`).

### 5.2. Расчёт уровней Donchian

Для каждого закрытого бара H1 (t):

- `R = max(High[t-1 … t-Donchian_Period])`
- `S = min(Low[t-1 … t-Donchian_Period])`

Используются только закрытые бары.

### 5.3. Фильтры H1

- Для LONG: `Close_H1[t] > EMA_H1_50[t]` и `MACD_H1_main[t] >= MACD_H1_signal[t]`
- Для SHORT: `Close_H1[t] < EMA_H1_50[t]` и `MACD_H1_main[t] <= MACD_H1_signal[t]`
- Общий фильтр волатильности: `ATR_pips = ATR_H1_14[t] / Point / 10`; если `ATR_pips < Min_ATR_Filter`, новые ордера не ставим.

## 6. Вход LONG

### 6.1. Предусловия

- TrendRegime = LONG
- Нет открытой позиции и активных лимитников
- Время в торговом диапазоне
- Нет блокировки по риску/новостям

### 6.2. Сигнал пробоя

- `BreakoutLevelLong = R`
- `P_Break = R + BreakBufferPips * PipValue`
- Условие: `Close_H1[t] >= P_Break`
- Фильтры H1: из п. 5.3
- ATR-фильтр выполнен
- Зафиксировать `BreakoutLevelLong` и `SignalBarTimeLong`

### 6.3. Buy Limit

- `EntryPriceLong = BreakoutLevelLong + EntryOffsetPips * PipValue`
- `SL_distance_price = max(SL_ATR_Multiplier * ATR_H1_14[t], MinSLDistancePips * PipValue)`
- `StopLossLong = EntryPriceLong - SL_distance_price`
- Рассчитать лот по риску (см. раздел 9)
- `TP_distance_price = RR_Multiplier * (EntryPriceLong - StopLossLong)`
- `TakeProfitLong = EntryPriceLong + TP_distance_price`
- Выставить Buy Limit с рассчитанными параметрами
- Запомнить `OrderPlacementTimeLong` и `OrderExpiryBarsLong = MaxRetestBars`

### 6.4. Истечение лимитника

По закрытию каждого H1 бара:

- Если ордер активен и прошло ≥ `MaxRetestBars` баров с `SignalBarTimeLong`, ордер отменить.

### 6.5. Прочие отмены

Удалить Buy Limit при смене режима, начале новостей, достижении лимитов убытков или выходе за торговые часы.

## 7. Ведение LONG-позиции

### 7.1. Переход в безубыток

- `Risk_per_trade_price = EntryPriceLong - StopLossLong`
- `Level_1R = EntryPriceLong + Risk_per_trade_price`
- При достижении цены уровня 1R перенести стоп на `EntryPriceLong + BE_OffsetPips * PipValue`

### 7.2. Трейлинг-стоп

- После перехода в BE каждые два закрытых H1 бара:
  - `RecentLow = min(Low` последних 3 закрытых баров`)
  - `CandidateStop = RecentLow - TrailingBufferPips * PipValue`
  - Обновлять стоп только если `CandidateStop > текущий стоп`

### 7.3. Принудительное закрытие

При смене TrendRegime на SHORT или FLAT закрыть позицию на ближайшем закрытии H1.

## 8. Вход SHORT

Зеркальная логика LONG:

- `BreakoutLevelShort = S`
- `P_Break = S - BreakBufferPips * PipValue`
- Условие пробоя: `Close_H1[t] <= P_Break`
- Фильтры H1: `Close_H1[t] < EMA_H1_50[t]`, `MACD_H1_main[t] <= MACD_H1_signal[t]`
- `EntryPriceShort = BreakoutLevelShort - EntryOffsetPips * PipValue`
- `SL_distance_price = max(SL_ATR_Multiplier * ATR_H1_14[t], MinSLDistancePips * PipValue)`
- `StopLossShort = EntryPriceShort + SL_distance_price`
- `TP_distance_price = RR_Multiplier * (StopLossShort - EntryPriceShort)`
- `TakeProfitShort = EntryPriceShort - TP_distance_price`
- Остальные правила — зеркальны LONG, включая истечение, отмены, безубыток и трейлинг.

## 9. Риск-менеджмент и размер позиции

### 9.1. Риск на сделку

- `AccountEquity` — текущий equity
- `RiskAmount = AccountEquity * RiskPerTradePercent / 100`
- `SL_pips = |EntryPrice - StopLoss| / PipValue`
- `PipValuePerLot` ≈ 10 USD для EURUSD на лот 1.0 (точное значение брать из спецификации символа)
- `LotSize = RiskAmount / (SL_pips * PipValuePerLot)`
- Округлить вниз до шага лота. Если результат < MinLot — ордер не ставить.

### 9.2. Лимит убытка за день

- В начале торгового дня: `DailyStartEquity = AccountEquity`, `DailyLoss = 0`
- При закрытии сделки: `DailyLoss += min(TradeResult, 0)`
- Если `|DailyLoss| >= DailyStartEquity * MaxDailyLossPercent / 100`, новые ордера не ставить до конца дня.

### 9.3. Лимит убытка за неделю

- Аналогично дневному лимиту, но для недели (`WeeklyStartEquity`, `WeeklyLoss`).
- При достижении лимита торговля блокируется до нового понедельника или ручного сброса.

## 10. Фильтр новостей

- Интерфейс: `bool IsHighImpactNewsNow(symbol, current_time);`
- При `UseNewsFilter = true` блокировать новые ордера и отменять активные лимитники в окнах `[NewsBlockMinutesBefore, NewsBlockMinutesAfter]` вокруг новостей.
- Реализация источника новостей на усмотрение разработчика (заглушка или API).

## 11. Основной алгоритм

### 11.1. OnTick (MQL/cTrader)

```
OnTick():
    Обновить время, цены, equity
    Если закрылся H4 бар:
        Обновить индикаторы H4 и TrendRegime
    Если закрылся H1 бар:
        Обновить индикаторы H1
        Обработать истечения ордеров, трейлинг, смену тренда
        Проверить новые сигналы
    На каждом тике сопровождать открытую позицию
```

### 11.2. ProcessNewH1Bar

```
ProcessNewH1Bar():
    Обновить дневные/недельные лимиты
    Если позиция открыта:
        Безубыток и трейлинг
        Проверка смены тренда
    Если есть лимитники:
        Проверка истечения и отмены
    Если нет позиции и лимитников:
        Проверить лимиты, часы, новости
        Рассчитать R и S
        В зависимости от TrendRegime ставить Buy/Sell Limit
```

## 12. Python-бэктест

- Использовать H1 данные (с отдельными значениями индикаторов H4)
- Обновление правил на закрытии H1
- Лимитные ордера исполняются, если `EntryPrice` попадает в диапазон бара `[Low, High]`
- При одновременном попадании SL и TP — приоритет за SL (консервативно)

