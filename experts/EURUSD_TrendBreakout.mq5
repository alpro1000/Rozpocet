// Trend-following D1 Expert Advisor based on EMA slope, Donchian channels, and ATR risk control
#property copyright ""
#property link      ""
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

CTrade trade;
input ulong InpMagic = 20241118;

input double  RiskPerTradePercent    = 0.5;    // риск на сделку, % от equity
input double  MaxDailyLossPercent    = 2.0;    // дневной лимит просадки, %
input double  MaxWeeklyLossPercent   = 5.0;    // недельный лимит просадки, %

input int     TrendEMA_Period        = 100;    // период EMA тренда на D1
input int     TrendEMA_SlopeBars     = 3;      // сколько баров EMA должна расти/падать

input int     DonchianEntryPeriod    = 55;     // период входного канала
input int     DonchianExitPeriod     = 20;     // период выходного канала

input int     ATR_Period             = 20;     // период ATR
input double  ATR_Multiplier_SL      = 2.0;    // во сколько ATR ставим стоп

enum TradeModeEnum { TM_BOTH = 0, TM_LONGS_ONLY = 1, TM_SHORTS_ONLY = 2 };
input TradeModeEnum TradeMode        = TM_BOTH;

input string  LogFileName            = "trend_d1_log.csv";

struct TradeState
{
   bool     active;
   ulong    ticket;
   double   entryPrice;
   double   stopLoss;
   double   volume;
   datetime entryTime;
   int      direction;   // 1 = long, -1 = short, 0 = none
   double   riskMoney;
};

TradeState   g_trade = {false, 0, 0.0, 0.0, 0.0, 0, 0, 0.0};

MqlDateTime  g_dailyDate = {0};
MqlDateTime  g_weeklyDate = {0};
double       g_dailyStartEquity = 0.0;
double       g_weeklyStartEquity = 0.0;
double       g_dailyLoss = 0.0;
double       g_weeklyLoss = 0.0;

datetime     g_lastD1BarTime = 0;
bool         g_logHeaderWritten = false;

//--- forward declarations
void OnNewD1Bar();
void RefreshTradeState();
void CheckEntrySignals();
void CheckExitSignals();
void ResetRiskLimitsIfNeeded();
void UpdateDailyWeeklyLoss(double profit);
void EnsureLogHeader();
void LogCompletedTrade(ulong positionTicket,double riskMoney,datetime entryTime,int direction,double volume);
bool GetDonchianChannel(int period,int startShift,double &high,double &low);
bool CalculateTrendDirection(int &trendDir,double &atr);
bool CalculateVolumeAndSL(int direction,double entryPrice,double slDistance,double &volume,double &stopLoss);
double GetLastDealProfit(ulong positionTicket,datetime fromTime);
double CalculatePositionRisk(double entryPrice,double stopLoss,double volume);

//--- initialization
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);

   if(!SymbolSelect(_Symbol,true))
   {
      Print("Failed to select symbol ",_Symbol);
      return(INIT_FAILED);
   }

   RefreshTradeState();

   TimeToStruct(TimeCurrent(),g_dailyDate);
   g_weeklyDate = g_dailyDate;

   g_dailyStartEquity = g_weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyLoss = g_weeklyLoss = 0.0;

   g_lastD1BarTime = iTime(_Symbol,PERIOD_D1,0);

   EnsureLogHeader();

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
}

//--- main loop
void OnTick()
{
   ResetRiskLimitsIfNeeded();

   datetime d1Time = iTime(_Symbol,PERIOD_D1,0);
   if(d1Time != g_lastD1BarTime)
   {
      g_lastD1BarTime = d1Time;
      OnNewD1Bar();
   }
}

void OnNewD1Bar()
{
   RefreshTradeState();
   if(g_trade.active)
      CheckExitSignals();
   if(!g_trade.active)
      CheckEntrySignals();
}

//--- utilities
void RefreshTradeState()
{
   if(PositionSelect(_Symbol))
   {
      g_trade.active     = true;
      g_trade.ticket     = (ulong)PositionGetInteger(POSITION_TICKET);
      g_trade.entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      g_trade.stopLoss   = PositionGetDouble(POSITION_SL);
      g_trade.volume     = PositionGetDouble(POSITION_VOLUME);
      g_trade.entryTime  = (datetime)PositionGetInteger(POSITION_TIME);
      g_trade.direction  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
   }
   else
   {
      g_trade.active     = false;
      g_trade.ticket     = 0;
      g_trade.entryPrice = 0.0;
      g_trade.stopLoss   = 0.0;
      g_trade.volume     = 0.0;
      g_trade.entryTime  = 0;
      g_trade.direction  = 0;
      g_trade.riskMoney  = 0.0;
   }
}

void CheckEntrySignals()
{
   if(g_trade.active)
      return;

   double eqStartDay = g_dailyStartEquity;
   double eqStartWeek = g_weeklyStartEquity;
   if(g_dailyLoss >= eqStartDay * MaxDailyLossPercent/100.0)
      return;
   if(g_weeklyLoss >= eqStartWeek * MaxWeeklyLossPercent/100.0)
      return;

   int trendDir = 0;
   double atr = 0.0;
   if(!CalculateTrendDirection(trendDir,atr))
      return;

   double entryHigh = 0.0, entryLow = 0.0;
   if(!GetDonchianChannel(DonchianEntryPeriod,1,entryHigh,entryLow))
      return;

   int direction = 0;
   if(trendDir == 1 && (TradeMode == TM_BOTH || TradeMode == TM_LONGS_ONLY) && Close[1] > entryHigh)
      direction = 1;
   else if(trendDir == -1 && (TradeMode == TM_BOTH || TradeMode == TM_SHORTS_ONLY) && Close[1] < entryLow)
      direction = -1;

   if(direction == 0)
      return;

   double entryPrice = (direction == 1 ? SymbolInfoDouble(_Symbol,SYMBOL_ASK) : SymbolInfoDouble(_Symbol,SYMBOL_BID));
   double slDistance = ATR_Multiplier_SL * atr;
   double volume = 0.0;
   double stopLoss = 0.0;

   if(!CalculateVolumeAndSL(direction,entryPrice,slDistance,volume,stopLoss))
      return;

   bool result = false;
   if(direction == 1)
      result = trade.Buy(volume,_Symbol,0.0,stopLoss,0.0,"D1 trend entry");
   else
      result = trade.Sell(volume,_Symbol,0.0,stopLoss,0.0,"D1 trend entry");

   if(result)
   {
      RefreshTradeState();
      g_trade.riskMoney = CalculatePositionRisk(entryPrice,stopLoss,volume);
   }
}

void CheckExitSignals()
{
   if(!g_trade.active)
      return;

   double exitHigh = 0.0, exitLow = 0.0;
   if(!GetDonchianChannel(DonchianExitPeriod,1,exitHigh,exitLow))
      return;

   bool shouldClose = false;
   if(g_trade.direction == 1 && Close[1] < exitLow)
      shouldClose = true;
   else if(g_trade.direction == -1 && Close[1] > exitHigh)
      shouldClose = true;

   if(!shouldClose)
      return;

   ulong positionTicket = g_trade.ticket;
   double riskMoney = g_trade.riskMoney;
   datetime entryTime = g_trade.entryTime;
   double volume = g_trade.volume;
   int direction = g_trade.direction;

   if(trade.PositionClose(_Symbol))
   {
      double profit = GetLastDealProfit(positionTicket,entryTime);
      UpdateDailyWeeklyLoss(profit);
      LogCompletedTrade(positionTicket,riskMoney,entryTime,direction,volume);
      RefreshTradeState();
   }
}

bool CalculateTrendDirection(int &trendDir,double &atr)
{
   trendDir = 0;
   int emaSize = TrendEMA_SlopeBars + 3;
   double ema[];
   ArrayResize(ema,emaSize);

   int copiedEma = CopyBuffer(iMA(_Symbol,PERIOD_D1,TrendEMA_Period,0,MODE_EMA,PRICE_CLOSE),0,1,emaSize,ema);
   if(copiedEma != emaSize)
      return(false);

   double atrArr[1];
   int copiedAtr = CopyBuffer(iATR(_Symbol,PERIOD_D1,ATR_Period),0,1,1,atrArr);
   if(copiedAtr != 1)
      return(false);
   atr = atrArr[0];

   if(Close[1] > ema[0] && ema[0] > ema[1] && ema[1] > ema[2])
      trendDir = 1;
   else if(Close[1] < ema[0] && ema[0] < ema[1] && ema[1] < ema[2])
      trendDir = -1;

   return(trendDir != 0 && atr > 0.0);
}

bool GetDonchianChannel(int period,int startShift,double &high,double &low)
{
   if(period <= 0)
      return(false);

   double highs[];
   double lows[];
   ArrayResize(highs,period);
   ArrayResize(lows,period);

   int copiedHigh = CopyHigh(_Symbol,PERIOD_D1,startShift,period,highs);
   int copiedLow  = CopyLow(_Symbol,PERIOD_D1,startShift,period,lows);
   if(copiedHigh != period || copiedLow != period)
      return(false);

   high = highs[0];
   low = lows[0];
   for(int i=1;i<period;i++)
   {
      if(highs[i] > high)
         high = highs[i];
      if(lows[i] < low)
         low = lows[i];
   }

   return(true);
}

double CalculatePositionRisk(double entryPrice,double stopLoss,double volume)
{
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return(0.0);

   double priceDistance = MathAbs(entryPrice - stopLoss);
   double riskPerLot = (priceDistance / tickSize) * tickValue;
   return(riskPerLot * volume);
}

bool CalculateVolumeAndSL(int direction,double entryPrice,double slDistance,double &volume,double &stopLoss)
{
   double tickSize  = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol,SYMBOL_TRADE_TICK_VALUE);
   double minVolume = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN);
   double maxVolume = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MAX);
   double volStep   = SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_STEP);

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return(false);

   double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * RiskPerTradePercent/100.0;
   double costPerLot = (slDistance / tickSize) * tickValue;
   if(costPerLot <= 0.0)
      return(false);

   double rawVolume = riskMoney / costPerLot;
   if(rawVolume < minVolume)
      return(false);

   double steps = MathFloor(rawVolume / volStep);
   volume = steps * volStep;
   if(volume < minVolume)
      volume = minVolume;
   if(volume > maxVolume)
      volume = maxVolume;

   if(direction == 1)
      stopLoss = entryPrice - slDistance;
   else
      stopLoss = entryPrice + slDistance;

   return(true);
}

void ResetRiskLimitsIfNeeded()
{
   MqlDateTime nowStruct;
   TimeToStruct(TimeCurrent(),nowStruct);

   if(nowStruct.year != g_dailyDate.year || nowStruct.mon != g_dailyDate.mon || nowStruct.day != g_dailyDate.day)
   {
      g_dailyDate = nowStruct;
      g_dailyLoss = 0.0;
      g_dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }

   int currentWeekIndex = nowStruct.day_of_year / 7;
   int storedWeekIndex  = g_weeklyDate.day_of_year / 7;
   if(nowStruct.year != g_weeklyDate.year || currentWeekIndex != storedWeekIndex)
   {
      g_weeklyDate = nowStruct;
      g_weeklyLoss = 0.0;
      g_weeklyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

void UpdateDailyWeeklyLoss(double profit)
{
   if(profit < 0.0)
   {
      double loss = MathAbs(profit);
      g_dailyLoss  += loss;
      g_weeklyLoss += loss;
   }
}

void EnsureLogHeader()
{
   int handle = FileOpen(LogFileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(handle == INVALID_HANDLE)
      return;

   if(FileSize(handle) == 0)
   {
      FileWrite(handle,"open_time","close_time","symbol","direction","volume","entry_price","exit_price","profit","r_multiple","equity_after");
      g_logHeaderWritten = true;
   }
   else
   {
      g_logHeaderWritten = true;
   }

   FileClose(handle);
}

double GetLastDealProfit(ulong positionTicket,datetime fromTime)
{
   double profit = 0.0;
   if(!HistorySelect(fromTime,TimeCurrent()))
      return(0.0);

   int deals = HistoryDealsTotal();
   for(int i=deals-1;i>=0;i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      ulong posId = (ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID);
      if(posId != positionTicket)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
      {
         profit = HistoryDealGetDouble(ticket,DEAL_PROFIT);
         break;
      }
   }

   return(profit);
}

void LogCompletedTrade(ulong positionTicket,double riskMoney,datetime entryTime,int direction,double volume)
{
   if(!g_logHeaderWritten)
      EnsureLogHeader();

   if(!HistorySelect(entryTime,TimeCurrent()))
      return;

   double entryPrice = 0.0;
   double exitPrice  = 0.0;
   datetime openTime = 0;
   datetime closeTime = 0;

   int deals = HistoryDealsTotal();
   for(int i=0;i<deals;i++)
   {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(dealTicket == 0)
         continue;

      ulong posId = (ulong)HistoryDealGetInteger(dealTicket,DEAL_POSITION_ID);
      if(posId != positionTicket)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket,DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
      {
         openTime = (datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
         entryPrice = HistoryDealGetDouble(dealTicket,DEAL_PRICE);
      }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
      {
         closeTime = (datetime)HistoryDealGetInteger(dealTicket,DEAL_TIME);
         exitPrice = HistoryDealGetDouble(dealTicket,DEAL_PRICE);
      }
   }

   double profit = GetLastDealProfit(positionTicket,entryTime);
   double rMultiple = (riskMoney > 0.0 ? profit / riskMoney : 0.0);
   string dirText = (direction == 1 ? "LONG" : "SHORT");
   double equityAfter = AccountInfoDouble(ACCOUNT_EQUITY);

   int handle = FileOpen(LogFileName,FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI,',');
   if(handle == INVALID_HANDLE)
      return;

   FileSeek(handle,0,SEEK_END);
   FileWrite(handle,openTime,closeTime,_Symbol,dirText,DoubleToString(volume,2),entryPrice,exitPrice,profit,rMultiple,equityAfter);
   FileClose(handle);
}
