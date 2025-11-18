// FIX: corrected CalendarValueHistory calls
// FIX: proper StringToLower/StringToUpper usage
// FIX: added configurable MagicNumber handling
#property copyright "Quantitative prototype"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Calendar/Calendar.mqh>

enum TrendRegime
{
   TREND_FLAT  = 0,
   TREND_LONG  = 1,
   TREND_SHORT = -1
};

enum TradeDirection
{
   DIR_NONE  = 0,
   DIR_LONG  = 1,
   DIR_SHORT = -1
};

input double  RiskPerTradePercent      = 0.5;
input double  MaxDailyLossPercent      = 2.0;
input double  MaxWeeklyLossPercent     = 5.0;

input int     H4_EMA_Period            = 200;
input int     H4_EMA_MinRisingBars     = 3;    // Relaxed from 4 (was hardcoded)
input int     H1_EMA_Fast_Period       = 50;
input int     Donchian_Period          = 20;

input int     MACD_Fast                = 12;
input int     MACD_Slow                = 26;
input int     MACD_Signal              = 9;

input int     ATR_Period               = 14;

input double  BreakBufferPips          = 5.0;
input double  EntryOffsetPips          = 1.0;
input double  SL_ATR_Multiplier        = 1.5;
input double  MinSLDistancePips        = 8.0;
input bool    UseFixedTP               = false; // Use fixed TP or rely on trailing
input double  RR_Multiplier            = 2.0;
input double  Min_ATR_FilterPips       = 6.0;   // Increased from 4.0
input int     MaxRetestBars            = 5;

input double  BE_OffsetPips            = 1.0;
input double  BE_ActivationMultiplier  = 1.5;  // Activate BE at 1.5R (was 1R)
input double  TrailingBufferPips       = 2.0;

input int     TradingStartHour         = 7;
input int     TradingEndHour           = 22;

input bool    UseNewsFilter            = true;  // Changed default to true
input int     NewsBlockMinutesBefore   = 30;
input int     NewsBlockMinutesAfter    = 30;
input string  NewsCalendarSource       = "file"; // "file" or "mt5"
input string  NewsCalendarFilePath     = "news_calendar.csv"; // CSV/JSON stored in MQL5/Files
input int     NewsCalendarRefreshMinutes = 60;   // Reload cadence for on-disk/MT5 calendar
input ulong   InpMagic                 = 20240528;

//--- trade helper
CTrade        trade;
string        InpSymbol = "EURUSD";

//--- indicator handles
int           hEMA_H4 = INVALID_HANDLE;
int           hMACD_H4 = INVALID_HANDLE;
int           hATR_H4 = INVALID_HANDLE;
int           hEMA_H1 = INVALID_HANDLE;
int           hMACD_H1 = INVALID_HANDLE;
int           hATR_H1 = INVALID_HANDLE;

//--- state variables
TrendRegime   g_currentRegime = TREND_FLAT;
datetime      g_lastH1BarTime = 0;
datetime      g_lastH4BarTime = 0;
bool          g_closeOnNextH1 = false;

struct PendingContext
{
   bool     active;
   ulong    ticket;
   TradeDirection direction;
   double   entryPrice;
   double   stopLoss;
   double   takeProfit;
   datetime signalTime;
   datetime expiryTime;
   double   riskAmount;
   TrendRegime regimeOnSignal;
};

struct TradeContext
{
   bool     active;
   ulong    positionTicket;
   TradeDirection direction;
   double   entryPrice;
   double   stopLoss;
   double   takeProfit;
   double   initialStopLoss;
   double   initialTakeProfit;
   double   riskAmount;
   double   lotSize;
   TrendRegime regimeOnEntry;
   datetime entryTime;
   double   level1R;
   bool     movedToBE;
   datetime breakEvenTime;
   int      barsSinceBE;
};

PendingContext g_pending = {false, 0, DIR_NONE, 0.0, 0.0, 0.0, 0, 0, 0.0, TREND_FLAT};
TradeContext   g_trade   = {false, 0, DIR_NONE, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, TREND_FLAT, 0, 0.0, false, 0, 0};

//--- risk control
MqlDateTime g_dailyDate = {0};
MqlDateTime g_weeklyDate = {0};
double      g_dailyStartEquity = 0.0;
double      g_weeklyStartEquity = 0.0;
double      g_dailyLoss = 0.0;
double      g_weeklyLoss = 0.0;

//--- news calendar state
struct NewsEvent
{
   datetime time;
   string   currency;
   string   title;
   string   impact; // low/medium/high
};

NewsEvent   g_newsEvents[];
datetime    g_newsLastLoaded = 0;
string      g_lastNewsBlockReason = "";

//--- logging
string       g_logFileName = "eurusd_trades_log.csv";
bool         g_logHeaderWritten = false;

//--- forward declarations
bool     InitializeIndicators();
void     ReleaseIndicators();
void     RefreshTrendRegime();
TrendRegime CalculateTrendRegime();
void     OnNewH1Bar();
void     HandlePendingExpiry();
void     EvaluateSignals();
void     EvaluateLongBreakout(int shift);
void     EvaluateShortBreakout(int shift);
void     CancelPendingOrder(const string reason);
bool     PlaceLimitOrder(TradeDirection direction,double entry,double sl,double tp,double lot,double risk,datetime signalTime);
void     UpdatePositionManagementOnTick();
void     UpdatePositionManagementOnNewBar();
void     ResetRiskLimitsIfNeeded();
bool     IsTradingAllowedNow();
double   GetPipSize();
bool     IsHighImpactNewsNow(const string symbol,const datetime checkTime);
bool     LoadNewsCalendar(const datetime now);
bool     LoadNewsFromFile(const string filename);
bool     LoadNewsFromMt5(const string symbol);
bool     ParseJsonCalendar(const string content);
string   ExtractJsonValue(const string text, const string key);
bool     SymbolMatchesEvent(const string symbol, const string currency);
bool     IsHighImpactImpact(const string impact);
string   Trim(const string text);
void     UpdateDailyWeeklyLoss(double profit);
void     EnsureLogHeader();
void     LogCompletedTrade(ulong positionTicket);
void     ClosePositionDueToRegimeChange();
void     SyncPositionState();

//--- OnInit
int OnInit()
{
   if(_Symbol != InpSymbol)
   {
      Print("This expert is restricted to EURUSD only.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(!SymbolSelect(InpSymbol,true))
   {
      Print("Failed to select symbol ", InpSymbol);
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);

   if(!InitializeIndicators())
      return(INIT_FAILED);

   datetime currentH1 = iTime(_Symbol,PERIOD_H1,0);
   datetime currentH4 = iTime(_Symbol,PERIOD_H4,0);
   g_lastH1BarTime = currentH1;
   g_lastH4BarTime = currentH4;

   datetime now = TimeCurrent();
   TimeToStruct(now, g_dailyDate);
   g_weeklyDate = g_dailyDate;
   g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_weeklyStartEquity = g_dailyStartEquity;
   g_dailyLoss = 0.0;
   g_weeklyLoss = 0.0;

   RefreshTrendRegime();
   SyncPositionState();
   EnsureLogHeader();

   return(INIT_SUCCEEDED);
}

//--- OnDeinit
void OnDeinit(const int reason)
{
   ReleaseIndicators();
}

//--- OnTick
void OnTick()
{
   if(_Symbol != InpSymbol)
      return;

   ResetRiskLimitsIfNeeded();

   datetime currentH1 = iTime(_Symbol,PERIOD_H1,0);
   if(currentH1 != g_lastH1BarTime)
   {
      g_lastH1BarTime = currentH1;
      OnNewH1Bar();
   }

   datetime currentH4 = iTime(_Symbol,PERIOD_H4,0);
   if(currentH4 != g_lastH4BarTime)
   {
      g_lastH4BarTime = currentH4;
      RefreshTrendRegime();
      if(g_trade.active)
      {
         if((g_trade.direction == DIR_LONG && g_currentRegime != TREND_LONG) ||
            (g_trade.direction == DIR_SHORT && g_currentRegime != TREND_SHORT))
         {
            g_closeOnNextH1 = true;
         }
      }

      if(g_pending.active && g_currentRegime != g_pending.regimeOnSignal)
         CancelPendingOrder("regime change");
   }

   UpdatePositionManagementOnTick();
}

//--- OnTradeTransaction for logging and risk updates
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &request,const MqlTradeResult &result)
{
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
   {
      ulong dealTicket = trans.deal;
      if(HistoryDealSelect(dealTicket))
      {
         string symbol = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
         if(symbol != _Symbol)
            return;

         long entryType = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);

         if(entryType == DEAL_ENTRY_IN)
         {
            if(g_pending.active && trans.order == g_pending.ticket)
            {
               if(PositionSelect(_Symbol))
               {
                  g_trade.riskAmount = g_pending.riskAmount;
                  g_trade.regimeOnEntry = g_pending.regimeOnSignal;
                  g_trade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
                  g_trade.stopLoss = PositionGetDouble(POSITION_SL);
                  g_trade.takeProfit = PositionGetDouble(POSITION_TP);
                  g_trade.initialStopLoss = g_pending.stopLoss;
                  g_trade.initialTakeProfit = g_pending.takeProfit;
                  double riskDistance = MathAbs(g_trade.entryPrice - g_trade.stopLoss);
                  g_trade.level1R = (g_pending.direction == DIR_LONG ?
                                    g_trade.entryPrice + BE_ActivationMultiplier * riskDistance :
                                    g_trade.entryPrice - BE_ActivationMultiplier * riskDistance);
                  g_trade.direction = g_pending.direction;
                  g_trade.movedToBE = false;
                  g_trade.barsSinceBE = 0;
                  g_trade.breakEvenTime = 0;
               }
               g_pending.active = false;
               g_pending.ticket = 0;
               g_pending.direction = DIR_NONE;
               g_pending.entryPrice = 0.0;
               g_pending.stopLoss = 0.0;
               g_pending.takeProfit = 0.0;
               g_pending.signalTime = 0;
               g_pending.expiryTime = 0;
               g_pending.riskAmount = 0.0;
               g_pending.regimeOnSignal = TREND_FLAT;
            }
            SyncPositionState();
         }
         else if(entryType == DEAL_ENTRY_OUT)
         {
            ulong positionId = (ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
            UpdateDailyWeeklyLoss(profit);
            LogCompletedTrade(positionId);
            SyncPositionState();
         }
      }
   }
}

//--- indicator initialization
bool InitializeIndicators()
{
   hEMA_H4 = iMA(_Symbol, PERIOD_H4, H4_EMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   hMACD_H4 = iMACD(_Symbol, PERIOD_H4, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   hATR_H4 = iATR(_Symbol, PERIOD_H4, ATR_Period);
   hEMA_H1 = iMA(_Symbol, PERIOD_H1, H1_EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   hMACD_H1 = iMACD(_Symbol, PERIOD_H1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
   hATR_H1 = iATR(_Symbol, PERIOD_H1, ATR_Period);

   if(hEMA_H4 == INVALID_HANDLE || hMACD_H4 == INVALID_HANDLE || hATR_H4 == INVALID_HANDLE ||
      hEMA_H1 == INVALID_HANDLE || hMACD_H1 == INVALID_HANDLE || hATR_H1 == INVALID_HANDLE)
   {
      Print("Failed to create indicators");
      return(false);
   }

   return(true);
}

void ReleaseIndicators()
{
   if(hEMA_H4 != INVALID_HANDLE) IndicatorRelease(hEMA_H4);
   if(hMACD_H4 != INVALID_HANDLE) IndicatorRelease(hMACD_H4);
   if(hATR_H4 != INVALID_HANDLE) IndicatorRelease(hATR_H4);
   if(hEMA_H1 != INVALID_HANDLE) IndicatorRelease(hEMA_H1);
   if(hMACD_H1 != INVALID_HANDLE) IndicatorRelease(hMACD_H1);
   if(hATR_H1 != INVALID_HANDLE) IndicatorRelease(hATR_H1);
}

//--- trend regime calculation
void RefreshTrendRegime()
{
   g_currentRegime = CalculateTrendRegime();
}

TrendRegime CalculateTrendRegime()
{
   double ema[6];
   double macdMain[3];
   double macdSignal[3];

   if(CopyBuffer(hEMA_H4, 0, 1, 6, ema) != 6)
      return(TREND_FLAT);
   if(CopyBuffer(hMACD_H4, 0, 1, 3, macdMain) != 3)
      return(TREND_FLAT);
   if(CopyBuffer(hMACD_H4, 1, 1, 3, macdSignal) != 3)
      return(TREND_FLAT);

   double closePrice = iClose(_Symbol, PERIOD_H4, 1);
   int risingCount = 0;
   int fallingCount = 0;
   for(int i=1;i<5;i++)
   {
      if(ema[i-1] >= ema[i])
         risingCount++;
      if(ema[i-1] <= ema[i])
         fallingCount++;
   }

   if(closePrice > ema[0] && risingCount >= H4_EMA_MinRisingBars && macdMain[0] > macdSignal[0])
      return(TREND_LONG);
   if(closePrice < ema[0] && fallingCount >= H4_EMA_MinRisingBars && macdMain[0] < macdSignal[0])
      return(TREND_SHORT);

   return(TREND_FLAT);
}

//--- new H1 bar handler
void OnNewH1Bar()
{
   RefreshTrendRegime();
   ClosePositionDueToRegimeChange();
   HandlePendingExpiry();
   UpdatePositionManagementOnNewBar();
   EvaluateSignals();
}

void HandlePendingExpiry()
{
   if(!g_pending.active)
      return;

   datetime now = TimeCurrent();
   if(now >= g_pending.expiryTime)
   {
      CancelPendingOrder("expiry");
      return;
   }

   if(g_currentRegime != g_pending.regimeOnSignal)
   {
      CancelPendingOrder("regime change");
      return;
   }

   if(!IsTradingAllowedNow())
   {
      CancelPendingOrder("trading window closed");
      return;
   }

   if((g_dailyLoss >= g_dailyStartEquity * MaxDailyLossPercent / 100.0) ||
      (g_weeklyLoss >= g_weeklyStartEquity * MaxWeeklyLossPercent / 100.0))
   {
      CancelPendingOrder("risk block");
      return;
   }

   if(UseNewsFilter && IsHighImpactNewsNow(_Symbol, TimeCurrent()))
   {
      CancelPendingOrder("news filter");
      return;
   }
}

void EvaluateSignals()
{
   if(g_trade.active || g_pending.active)
      return;

   if(Bars(_Symbol, PERIOD_H1) < Donchian_Period + 5)
      return;

   if(g_dailyLoss >= g_dailyStartEquity * MaxDailyLossPercent / 100.0)
      return;
   if(g_weeklyLoss >= g_weeklyStartEquity * MaxWeeklyLossPercent / 100.0)
      return;
   if(!IsTradingAllowedNow())
      return;
   if(UseNewsFilter && IsHighImpactNewsNow(_Symbol, TimeCurrent()))
      return;

   double atr[1];
   if(CopyBuffer(hATR_H1,0,1,1,atr) != 1)
      return;

   double pipSize = GetPipSize();
   double atrPips = atr[0] / pipSize;
   if(atrPips < Min_ATR_FilterPips)
      return;

   if(g_currentRegime == TREND_LONG)
      EvaluateLongBreakout(1);
   else if(g_currentRegime == TREND_SHORT)
      EvaluateShortBreakout(1);
}

void EvaluateLongBreakout(int shift)
{
   double closePrice = iClose(_Symbol, PERIOD_H1, shift);
   double ema[1];
   if(CopyBuffer(hEMA_H1,0,shift,1,ema) != 1)
      return;

   double macdMain[1];
   double macdSignal[1];
   if(CopyBuffer(hMACD_H1,0,shift,1,macdMain) != 1)
      return;
   if(CopyBuffer(hMACD_H1,1,shift,1,macdSignal) != 1)
      return;

   if(closePrice <= ema[0])
      return;
   if(macdMain[0] < macdSignal[0])
      return;

   double highest = iHigh(_Symbol, PERIOD_H1, shift);
   for(int i=1;i<Donchian_Period;i++)
   {
      double h = iHigh(_Symbol, PERIOD_H1, shift + i);
      if(h > highest)
         highest = h;
   }

   double pipSize = GetPipSize();
   double breakLevel = highest;
   double breakPrice = breakLevel + BreakBufferPips * pipSize;

   if(closePrice < breakPrice)
      return;

   double entryPrice = breakLevel + EntryOffsetPips * pipSize;
   double atr[1];
   if(CopyBuffer(hATR_H1,0,shift,1,atr) != 1)
      return;
   double slDistance = MathMax(SL_ATR_Multiplier * atr[0], MinSLDistancePips * pipSize);
   double stopLoss = entryPrice - slDistance;
   double tpDistance = RR_Multiplier * (entryPrice - stopLoss);
   double takeProfit = entryPrice + tpDistance;

   double lotSize = 0.0;
   double riskAmount = 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pipValue = tickValue * pipSize / tickSize;
   if(pipValue <= 0.0)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   riskAmount = equity * RiskPerTradePercent / 100.0;
   double slPips = (entryPrice - stopLoss) / pipSize;
   if(slPips <= 0.0)
      return;
   lotSize = riskAmount / (slPips * pipValue);

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, 0.0);

   if(lotSize < minLot)
   {
      Print("Lot size below minimum, skipping order");
      return;
   }

   if(lotSize > maxLot)
      lotSize = maxLot;

   datetime signalTime = iTime(_Symbol, PERIOD_H1, shift);
   datetime expiry = signalTime + MaxRetestBars * 3600;

   if(PlaceLimitOrder(DIR_LONG, entryPrice, stopLoss, takeProfit, lotSize, riskAmount, signalTime))
   {
      g_pending.expiryTime = expiry;
   }
}

void EvaluateShortBreakout(int shift)
{
   double closePrice = iClose(_Symbol, PERIOD_H1, shift);
   double ema[1];
   if(CopyBuffer(hEMA_H1,0,shift,1,ema) != 1)
      return;

   double macdMain[1];
   double macdSignal[1];
   if(CopyBuffer(hMACD_H1,0,shift,1,macdMain) != 1)
      return;
   if(CopyBuffer(hMACD_H1,1,shift,1,macdSignal) != 1)
      return;

   if(closePrice >= ema[0])
      return;
   if(macdMain[0] > macdSignal[0])
      return;

   double lowest = iLow(_Symbol, PERIOD_H1, shift);
   for(int i=1;i<Donchian_Period;i++)
   {
      double l = iLow(_Symbol, PERIOD_H1, shift + i);
      if(l < lowest)
         lowest = l;
   }

   double pipSize = GetPipSize();
   double breakLevel = lowest;
   double breakPrice = breakLevel - BreakBufferPips * pipSize;

   if(closePrice > breakPrice)
      return;

   double entryPrice = breakLevel - EntryOffsetPips * pipSize;
   double atr[1];
   if(CopyBuffer(hATR_H1,0,shift,1,atr) != 1)
      return;
   double slDistance = MathMax(SL_ATR_Multiplier * atr[0], MinSLDistancePips * pipSize);
   double stopLoss = entryPrice + slDistance;
   double tpDistance = RR_Multiplier * (stopLoss - entryPrice);
   double takeProfit = entryPrice - tpDistance;

   double lotSize = 0.0;
   double riskAmount = 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double pipValue = tickValue * pipSize / tickSize;
   if(pipValue <= 0.0)
      return;

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   riskAmount = equity * RiskPerTradePercent / 100.0;
   double slPips = (stopLoss - entryPrice) / pipSize;
   if(slPips <= 0.0)
      return;
   lotSize = riskAmount / (slPips * pipValue);

   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   lotSize = MathFloor(lotSize / lotStep) * lotStep;
   lotSize = MathMax(lotSize, 0.0);

   if(lotSize < minLot)
   {
      Print("Lot size below minimum, skipping order");
      return;
   }

   if(lotSize > maxLot)
      lotSize = maxLot;

   datetime signalTime = iTime(_Symbol, PERIOD_H1, shift);
   datetime expiry = signalTime + MaxRetestBars * 3600;

   if(PlaceLimitOrder(DIR_SHORT, entryPrice, stopLoss, takeProfit, lotSize, riskAmount, signalTime))
   {
      g_pending.expiryTime = expiry;
   }
}

bool PlaceLimitOrder(TradeDirection direction,double entry,double sl,double tp,double lot,double risk,datetime signalTime)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

   req.action   = TRADE_ACTION_PENDING;
   req.symbol   = _Symbol;
   req.volume   = lot;
   req.price    = entry;
   req.sl       = sl;
   req.tp       = (UseFixedTP ? tp : 0);  // Use TP only if enabled
   req.deviation= 30;  // Increased from 10 (now 3 pips for better execution)
   req.magic    = InpMagic;
   req.type     = (direction == DIR_LONG ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   req.type_filling = ORDER_FILLING_RETURN;
   req.type_time    = ORDER_TIME_GTC;

   if(UseFixedTP)
      Print("Using fixed TP at ", tp);
   else
      Print("No fixed TP - relying on BE + trailing stop + regime change");

   if(!OrderSend(req,res))
   {
      Print("Failed to send pending order, code=", GetLastError());
      return(false);
   }

   if(res.retcode != TRADE_RETCODE_DONE)
   {
      Print("OrderSend retcode ", res.retcode);
      return(false);
   }

   g_pending.active = true;
   g_pending.ticket = res.order;
   g_pending.direction = direction;
   g_pending.entryPrice = entry;
   g_pending.stopLoss = sl;
   g_pending.takeProfit = tp;
   g_pending.signalTime = signalTime;
   g_pending.riskAmount = risk;
   g_pending.regimeOnSignal = g_currentRegime;

   Print("Placed pending order ", g_pending.ticket, " dir=", (direction==DIR_LONG?"LONG":"SHORT"));

   return(true);
}

void CancelPendingOrder(const string reason)
{
   if(!g_pending.active)
      return;

   if(OrderSelect(g_pending.ticket))
   {
      if(!trade.OrderDelete(g_pending.ticket))
      {
         Print("Failed to delete pending order ", g_pending.ticket, " reason=", reason);
      }
      else
      {
         Print("Pending order ", g_pending.ticket, " cancelled: ", reason);
      }
   }

   g_pending.active = false;
   g_pending.ticket = 0;
   g_pending.direction = DIR_NONE;
   g_pending.entryPrice = 0.0;
   g_pending.stopLoss = 0.0;
   g_pending.takeProfit = 0.0;
   g_pending.signalTime = 0;
   g_pending.expiryTime = 0;
   g_pending.riskAmount = 0.0;
   g_pending.regimeOnSignal = TREND_FLAT;
}

void UpdatePositionManagementOnTick()
{
   if(!g_trade.active)
      return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double pipSize = GetPipSize();

   if(!g_trade.movedToBE)
   {
      if(g_trade.direction == DIR_LONG && bid >= g_trade.level1R)
      {
         double newSL = g_trade.entryPrice + BE_OffsetPips * pipSize;
         if(newSL > g_trade.stopLoss)
         {
            if(trade.PositionModify(_Symbol, newSL, g_trade.takeProfit))
            {
               g_trade.stopLoss = newSL;
               g_trade.movedToBE = true;
               g_trade.breakEvenTime = TimeCurrent();
               g_trade.barsSinceBE = 0;
               Print("LONG position moved to breakeven");
            }
         }
      }
      else if(g_trade.direction == DIR_SHORT && ask <= g_trade.level1R)
      {
         double newSL = g_trade.entryPrice - BE_OffsetPips * pipSize;
         if(newSL < g_trade.stopLoss)
         {
            if(trade.PositionModify(_Symbol, newSL, g_trade.takeProfit))
            {
               g_trade.stopLoss = newSL;
               g_trade.movedToBE = true;
               g_trade.breakEvenTime = TimeCurrent();
               g_trade.barsSinceBE = 0;
               Print("SHORT position moved to breakeven");
            }
         }
      }
   }
}

void UpdatePositionManagementOnNewBar()
{
   if(!g_trade.active)
      return;

   if(g_trade.movedToBE)
      g_trade.barsSinceBE++;

   if(g_trade.movedToBE && g_trade.barsSinceBE >= 2)
   {
      double pipSize = GetPipSize();
      double candidateSL = g_trade.stopLoss;

      if(g_trade.direction == DIR_LONG)
      {
         double recentLow = iLow(_Symbol, PERIOD_H1, 1);
         for(int i=2;i<=3;i++)
         {
            double l = iLow(_Symbol, PERIOD_H1, i);
            if(l < recentLow)
               recentLow = l;
         }
         candidateSL = recentLow - TrailingBufferPips * pipSize;
         if(candidateSL > g_trade.stopLoss)
         {
            if(trade.PositionModify(_Symbol, candidateSL, g_trade.takeProfit))
            {
               g_trade.stopLoss = candidateSL;
               g_trade.barsSinceBE = 0;
               Print("Trailing stop updated (LONG)");
            }
         }
      }
      else if(g_trade.direction == DIR_SHORT)
      {
         double recentHigh = iHigh(_Symbol, PERIOD_H1, 1);
         for(int i=2;i<=3;i++)
         {
            double h = iHigh(_Symbol, PERIOD_H1, i);
            if(h > recentHigh)
               recentHigh = h;
         }
         candidateSL = recentHigh + TrailingBufferPips * pipSize;
         if(candidateSL < g_trade.stopLoss)
         {
            if(trade.PositionModify(_Symbol, candidateSL, g_trade.takeProfit))
            {
               g_trade.stopLoss = candidateSL;
               g_trade.barsSinceBE = 0;
               Print("Trailing stop updated (SHORT)");
            }
         }
      }
   }
}

void ClosePositionDueToRegimeChange()
{
   if(!g_trade.active)
      return;

   if(!g_closeOnNextH1)
      return;

   if((g_trade.direction == DIR_LONG && g_currentRegime != TREND_LONG) ||
      (g_trade.direction == DIR_SHORT && g_currentRegime != TREND_SHORT))
   {
      Print("Closing position due to H4 regime change");
      if(trade.PositionClose(_Symbol))
         g_closeOnNextH1 = false;
      else
         Print("Failed to close position on regime change, will retry");
   }
   else
   {
      g_closeOnNextH1 = false;
   }
}

void ResetRiskLimitsIfNeeded()
{
   datetime now = TimeCurrent();
   MqlDateTime nowStruct;
   TimeToStruct(now, nowStruct);

   // Daily reset
   if(nowStruct.day != g_dailyDate.day ||
      nowStruct.mon != g_dailyDate.mon ||
      nowStruct.year != g_dailyDate.year)
   {
      g_dailyDate = nowStruct;
      g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyLoss = 0.0;
      Print("Daily limits reset. New equity: ", g_dailyStartEquity);
   }

   // Weekly reset - calculate week number properly
   // This fixes the bug where weekly reset only worked on Mondays
   int currentWeek = (nowStruct.day_of_year - 1) / 7;
   int savedWeek = (g_weeklyDate.day_of_year - 1) / 7;

   if(currentWeek != savedWeek || nowStruct.year != g_weeklyDate.year)
   {
      g_weeklyDate = nowStruct;
      g_weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_weeklyLoss = 0.0;
      Print("Weekly limits reset. Week ", currentWeek, ", New equity: ", g_weeklyStartEquity);
   }
}

bool IsTradingAllowedNow()
{
   datetime now = TimeCurrent();
   MqlDateTime st;
   TimeToStruct(now, st);
   if(st.hour < TradingStartHour || st.hour >= TradingEndHour)
      return(false);
   return(true);
}

double GetPipSize()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      return(point * 10.0);
   return(point);
}

// Lightweight calendar-driven high impact filter with time-window fallback
bool IsHighImpactNewsNow(const string symbol,const datetime checkTime)
{
   g_lastNewsBlockReason = "";

   bool calendarLoaded = LoadNewsCalendar(checkTime);

   if(calendarLoaded)
   {
      int beforeWindow = NewsBlockMinutesBefore * 60;
      int afterWindow  = NewsBlockMinutesAfter * 60;

      for(int i=0;i<ArraySize(g_newsEvents);i++)
      {
         NewsEvent ev = g_newsEvents[i];
         if(!SymbolMatchesEvent(symbol, ev.currency))
            continue;

         if(checkTime >= ev.time - beforeWindow && checkTime <= ev.time + afterWindow)
         {
            if(IsHighImpactImpact(ev.impact))
            {
               g_lastNewsBlockReason = StringFormat(
                  "NEWS FILTER: %s [%s %s, impact=%s] within %d/%d min buffer", 
                  ev.title,
                  ev.currency,
                  TimeToString(ev.time, TIME_DATE|TIME_MINUTES),
                  ev.impact,
                  NewsBlockMinutesBefore,
                  NewsBlockMinutesAfter);
               Print(g_lastNewsBlockReason);
               return true;
            }
         }
      }
   }

   // Safety-net time windows in case the calendar cannot be loaded
   MqlDateTime dt;
   TimeToStruct(checkTime, dt);

   // 14:30 server time = 12:30 UTC (NFP, Retail Sales, CPI, etc.)
   if(dt.hour == 14 && dt.min >= 15 && dt.min <= 45)
   {
      Print("NEWS FILTER (fallback): Blocking 14:30 news window");
      return true;
   }

   // 16:00 server time = 14:00 UTC (FOMC decisions, etc.)
   if(dt.hour == 16 && dt.min >= 0 && dt.min <= 30)
   {
      Print("NEWS FILTER (fallback): Blocking 16:00 news window");
      return true;
   }

   // 16:30 server time = 14:30 UTC (Crude Oil inventories, etc.)
   if(dt.hour == 16 && dt.min >= 15 && dt.min <= 45)
   {
      Print("NEWS FILTER (fallback): Blocking 16:30 news window");
      return true;
   }

   // ECB press conference (typically Thursday 14:30 server time)
   if(dt.hour == 14 && dt.day_of_week == 4 && dt.min >= 15 && dt.min <= 45)
   {
      Print("NEWS FILTER (fallback): Blocking ECB press conference");
      return true;
   }

   // Friday evening - weekend gap risk
   if(dt.day_of_week == 5 && dt.hour >= 23)
   {
      Print("NEWS FILTER (fallback): Blocking Friday evening (weekend gap risk)");
      return true;
   }

   // Monday early morning - weekend gap processing
   if(dt.day_of_week == 1 && dt.hour <= 1)
   {
      Print("NEWS FILTER (fallback): Blocking Monday early morning (weekend gap)");
      return true;
   }

   return false;
}

bool LoadNewsCalendar(const datetime now)
{
   // Avoid reloading on every tick
   if(g_newsLastLoaded != 0 && (now - g_newsLastLoaded) < NewsCalendarRefreshMinutes * 60)
      return(ArraySize(g_newsEvents) > 0);

   ArrayResize(g_newsEvents, 0);
   g_newsLastLoaded = now;

   string calendarSource = NewsCalendarSource;
   StringToLower(calendarSource);

   if(StringCompare(calendarSource, "file") == 0)
   {
      if(LoadNewsFromFile(NewsCalendarFilePath))
         return(true);
   }
   else if(StringCompare(calendarSource, "mt5") == 0)
   {
      if(LoadNewsFromMt5(_Symbol))
         return(true);
   }

   Print("NEWS FILTER: Failed to load calendar from source '", NewsCalendarSource, "'. Using fallback schedule only.");
   return(false);
}

bool LoadNewsFromFile(const string filename)
{
   int handle = FileOpen(filename, FILE_READ|FILE_ANSI|FILE_TXT);
   if(handle == INVALID_HANDLE)
   {
      Print("NEWS FILTER: Unable to open calendar file ", filename);
      return(false);
   }

   string content = "";
   string firstNonEmpty = "";

   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      content += (StringLen(content) > 0 ? "\n" : "") + line;

      string trimmed = Trim(line);
      if(StringLen(trimmed) > 0 && StringLen(firstNonEmpty) == 0)
         firstNonEmpty = trimmed;
   }

   FileClose(handle);

   if(StringLen(firstNonEmpty) > 0)
   {
      ushort firstChar = StringGetCharacter(firstNonEmpty, 0);
      if(firstChar == '[' || firstChar == '{')
         return(ParseJsonCalendar(content));
   }

   string lines[];
   int totalLines = StringSplit(content, "\n", lines);
   for(int i=0;i<totalLines;i++)
   {
      string line = Trim(lines[i]);
      if(StringLen(line) == 0 || StringGetCharacter(line, 0) == '#')
         continue;

      string parts[];
      int count = StringSplit(line, ';', parts);
      if(count < 4)
         count = StringSplit(line, ',', parts);

      if(count < 4)
         continue;

      datetime eventTime = (datetime)StringToTime(Trim(parts[0]));
      string currency = Trim(parts[1]);
      string impact = Trim(parts[2]);
      StringToLower(impact);
      string title = Trim(parts[3]);

      if(eventTime <= 0)
         continue;

      int newIndex = ArraySize(g_newsEvents);
      ArrayResize(g_newsEvents, newIndex + 1);
      g_newsEvents[newIndex].time = eventTime;
      g_newsEvents[newIndex].currency = currency;
      g_newsEvents[newIndex].impact = impact;
      g_newsEvents[newIndex].title = title;
   }

   return(ArraySize(g_newsEvents) > 0);
}

bool LoadNewsFromMt5(const string symbol)
{
   string base = StringSubstr(symbol, 0, 3);
   string quote = StringSubstr(symbol, 3, 3);

   // Pull events in the near future for both legs of the pair
   datetime now = TimeCurrent();
   datetime from = now - NewsBlockMinutesBefore * 60;
   datetime horizon = now + 3 * 24 * 3600; // 3 days ahead

   MqlCalendarValue values[];
   int baseCount = CalendarValueHistory(values, from, horizon, NULL, base);

   MqlCalendarValue quoteValues[];
   int quoteCount = CalendarValueHistory(quoteValues, from, horizon, NULL, quote);

   if(baseCount <= 0 && quoteCount <= 0)
      return(false);

   int total = 0;
   if(baseCount > 0)
      total += baseCount;
   if(quoteCount > 0)
      total += quoteCount;

   ArrayResize(g_newsEvents, total);
   int idx = 0;

   if(baseCount > 0)
   {
      for(int i=0;i<baseCount && idx < total;i++, idx++)
      {
         g_newsEvents[idx].time = values[i].time;
         g_newsEvents[idx].currency = values[i].country;
         g_newsEvents[idx].title = values[i].event;
         g_newsEvents[idx].impact = (values[i].importance == CALENDAR_IMPORTANCE_HIGH ? "high" :
                                    values[i].importance == CALENDAR_IMPORTANCE_MEDIUM ? "medium" : "low");
      }
   }

   if(quoteCount > 0)
   {
      for(int i=0;i<quoteCount && idx < total;i++, idx++)
      {
         g_newsEvents[idx].time = quoteValues[i].time;
         g_newsEvents[idx].currency = quoteValues[i].country;
         g_newsEvents[idx].title = quoteValues[i].event;
         g_newsEvents[idx].impact = (quoteValues[i].importance == CALENDAR_IMPORTANCE_HIGH ? "high" :
                                    quoteValues[i].importance == CALENDAR_IMPORTANCE_MEDIUM ? "medium" : "low");
      }
   }

   return(ArraySize(g_newsEvents) > 0);
}

bool ParseJsonCalendar(const string content)
{
   string normalized = content;
   normalized = StringReplace(normalized, "\r", "");

   int searchStart = 0;
   while(true)
   {
      int objStart = StringFind(normalized, "{", searchStart);
      if(objStart < 0)
         break;

      int objEnd = StringFind(normalized, "}", objStart);
      if(objEnd < 0)
         break;

      string obj = StringSubstr(normalized, objStart, objEnd - objStart + 1);

      string timeStr = Trim(ExtractJsonValue(obj, "time"));
      if(StringLen(timeStr) == 0)
         timeStr = Trim(ExtractJsonValue(obj, "datetime"));

      string currency = Trim(ExtractJsonValue(obj, "currency"));
      if(StringLen(currency) == 0)
         currency = Trim(ExtractJsonValue(obj, "country"));

      string impact = Trim(ExtractJsonValue(obj, "impact"));
      StringToLower(impact);
      if(StringLen(impact) == 0)
      {
         impact = Trim(ExtractJsonValue(obj, "importance"));
         StringToLower(impact);
      }

      string title = Trim(ExtractJsonValue(obj, "title"));
      if(StringLen(title) == 0)
         title = Trim(ExtractJsonValue(obj, "event"));

      datetime eventTime = (datetime)StringToTime(timeStr);

      if(eventTime > 0)
      {
         int newIndex = ArraySize(g_newsEvents);
         ArrayResize(g_newsEvents, newIndex + 1);
         g_newsEvents[newIndex].time = eventTime;
         g_newsEvents[newIndex].currency = currency;
         g_newsEvents[newIndex].impact = impact;
         g_newsEvents[newIndex].title = title;
      }

      searchStart = objEnd + 1;
   }

   return(ArraySize(g_newsEvents) > 0);
}

string ExtractJsonValue(const string text, const string key)
{
   string pattern = "\"" + key + "\"";
   int start = StringFind(text, pattern);
   if(start < 0)
      return("");

   start = StringFind(text, ":", start);
   if(start < 0)
      return("");

   start = StringFind(text, "\"", start);
   if(start < 0)
      return("");
   start++;

   int end = StringFind(text, "\"", start);
   if(end < 0)
      return("");

   return(StringSubstr(text, start, end - start));
}

bool SymbolMatchesEvent(const string symbol, const string currency)
{
   if(StringLen(currency) == 0)
      return(false);

   string base = StringSubstr(symbol, 0, 3);
   string quote = StringSubstr(symbol, 3, 3);

   string curUpper = currency;
   StringToUpper(curUpper);

   string baseUpper = base;
   StringToUpper(baseUpper);
   string quoteUpper = quote;
   StringToUpper(quoteUpper);

   return(curUpper == baseUpper || curUpper == quoteUpper || curUpper == "ALL");
}

bool IsHighImpactImpact(const string impact)
{
   string val = impact;
   StringToLower(val);
   return(StringFind(val, "high") == 0 || val == "3" || val == "h");
}

string Trim(const string text)
{
   string tmp = text;
   tmp = StringTrimLeft(tmp);
   tmp = StringTrimRight(tmp);
   return(tmp);
}

void UpdateDailyWeeklyLoss(double profit)
{
   if(profit < 0.0)
   {
      g_dailyLoss += MathAbs(profit);
      g_weeklyLoss += MathAbs(profit);
   }
}

void EnsureLogHeader()
{
   int handle = FileOpen(g_logFileName, FILE_READ|FILE_CSV|FILE_ANSI, ',');
   if(handle != INVALID_HANDLE)
   {
      g_logHeaderWritten = !FileIsEnding(handle);
      FileClose(handle);
   }

   if(!g_logHeaderWritten)
   {
      int wh = FileOpen(g_logFileName, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
      if(wh != INVALID_HANDLE)
      {
         FileWrite(wh,
            "datetime_open",
            "datetime_close",
            "direction",
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
            "regime_on_entry",
            "regime_on_exit",
            "comment");
         FileClose(wh);
         g_logHeaderWritten = true;
      }
   }
}

void LogCompletedTrade(ulong positionTicket)
{
   HistorySelect(TimeCurrent()-86400*30, TimeCurrent());

   ulong dealEntry = 0;
   ulong dealExit = 0;

   int total = HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if((ulong)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID) != positionTicket)
         continue;

      long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
         dealEntry = dealTicket;
      else if(entry == DEAL_ENTRY_OUT)
         dealExit = dealTicket;
   }

   if(dealExit == 0 || dealEntry == 0)
      return;

   datetime entryTime = (datetime)HistoryDealGetInteger(dealEntry, DEAL_TIME);
   datetime exitTime  = (datetime)HistoryDealGetInteger(dealExit, DEAL_TIME);
   double entryPrice  = HistoryDealGetDouble(dealEntry, DEAL_PRICE);
   double exitPrice   = HistoryDealGetDouble(dealExit, DEAL_PRICE);
   double volume      = HistoryDealGetDouble(dealEntry, DEAL_VOLUME);
   double profit      = HistoryDealGetDouble(dealExit, DEAL_PROFIT);
   double balance     = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity      = AccountInfoDouble(ACCOUNT_EQUITY);
   double stopLoss    = (g_trade.initialStopLoss != 0.0 ? g_trade.initialStopLoss : g_trade.stopLoss);
   double takeProfit  = (g_trade.initialTakeProfit != 0.0 ? g_trade.initialTakeProfit : g_trade.takeProfit);

   string directionStr = (HistoryDealGetInteger(dealEntry, DEAL_TYPE) == DEAL_TYPE_BUY ? "LONG" : "SHORT");
   double pipSize = GetPipSize();
   double profitPips = (directionStr == "LONG" ? (exitPrice - entryPrice) : (entryPrice - exitPrice)) / pipSize;

   double riskAmount = g_trade.riskAmount;
   double rMultiple = (riskAmount != 0.0 ? profit / riskAmount : 0.0);

   TrendRegime exitRegime = g_currentRegime;

   string comment = HistoryDealGetString(dealExit, DEAL_COMMENT);

   int handle = FileOpen(g_logFileName, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
   if(handle == INVALID_HANDLE)
      return;
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle,
      TimeToString(entryTime, TIME_DATE|TIME_SECONDS),
      TimeToString(exitTime, TIME_DATE|TIME_SECONDS),
      directionStr,
      DoubleToString(entryPrice, _Digits),
      DoubleToString(stopLoss, _Digits),
      DoubleToString(takeProfit, _Digits),
      DoubleToString(exitPrice, _Digits),
      DoubleToString(volume, 2),
      DoubleToString(profit, 2),
      DoubleToString(profitPips, 1),
      DoubleToString(rMultiple, 2),
      DoubleToString(balance, 2),
      DoubleToString(equity, 2),
      (g_trade.regimeOnEntry == TREND_LONG ? "LONG" : g_trade.regimeOnEntry == TREND_SHORT ? "SHORT" : "FLAT"),
      (exitRegime == TREND_LONG ? "LONG" : exitRegime == TREND_SHORT ? "SHORT" : "FLAT"),
      comment);
   FileClose(handle);
}

void SyncPositionState()
{
   if(PositionSelect(_Symbol))
   {
      g_trade.active = true;
      g_trade.positionTicket = PositionGetInteger(POSITION_TICKET);
      g_trade.direction = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? DIR_LONG : DIR_SHORT);
      g_trade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_trade.stopLoss = PositionGetDouble(POSITION_SL);
      g_trade.takeProfit = PositionGetDouble(POSITION_TP);
      g_trade.lotSize = PositionGetDouble(POSITION_VOLUME);
      if(g_trade.initialStopLoss == 0.0)
         g_trade.initialStopLoss = g_trade.stopLoss;
      if(g_trade.initialTakeProfit == 0.0)
         g_trade.initialTakeProfit = g_trade.takeProfit;
      if(!g_trade.movedToBE)
      {
         double risk = MathAbs(g_trade.entryPrice - g_trade.stopLoss);
         g_trade.level1R = (g_trade.direction == DIR_LONG ?
                           g_trade.entryPrice + BE_ActivationMultiplier * risk :
                           g_trade.entryPrice - BE_ActivationMultiplier * risk);
      }
      g_trade.entryTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(g_trade.riskAmount <= 0.0)
         g_trade.riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPerTradePercent / 100.0;
      if(g_trade.regimeOnEntry == TREND_FLAT)
         g_trade.regimeOnEntry = g_currentRegime;
   }
   else
   {
      g_trade.active = false;
      g_trade.direction = DIR_NONE;
      g_trade.movedToBE = false;
      g_trade.barsSinceBE = 0;
      g_trade.initialStopLoss = 0.0;
      g_trade.initialTakeProfit = 0.0;
      g_trade.riskAmount = 0.0;
      g_closeOnNextH1 = false;
      g_trade.breakEvenTime = 0;
   }

   if(g_pending.active)
   {
      if(!OrderSelect(g_pending.ticket))
      {
         g_pending.active = false;
         g_pending.ticket = 0;
      }
   }
}

