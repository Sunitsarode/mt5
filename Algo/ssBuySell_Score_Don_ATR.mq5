//+------------------------------------------------------------------+
//|                                   ssBuySell_Score_Don_ATR.mq5    |
//| Momentum EA: Sumit Score + Donchian breakout + ATR risk          |
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// Sumit score indicator parameters
input int Rsi1hPeriod = 51;
input int SumitMaBuy = 30;
input int SumitMaSell = 70;
input int Rsi1hBuy = 40;
input int Rsi1hSell = 60;
input int SumitSma3Period = 3;
input int SumitSma201Period = 201;
input int SumitRsiPeriod = 7;

// Entry filters
input bool Use_Sumit_Score = true;
input int EntryScoreBuy = 50;   // Buy when score <= EntryScoreBuy
input int EntryScoreSell = 50;  // Sell when score >= EntryScoreSell

input int DonchianPeriod = 20;
input ENUM_TIMEFRAMES SignalTimeframe = PERIOD_CURRENT;
input int SignalCandleShift = 1;   // 0=current bar, 1=last closed bar
input double BreakoutBufferPoints = 0.0;

input int AtrPeriod = 14;
input double AtrMinPercent = 0.0;  // 0 disables ATR percent filter
input double StopAtrMult = 1.5;    // 0 disables SL
input double TargetAtrMult = 2.0;  // 0 disables TP

// Trading
input bool BuyEntry = true;
input bool SellEntry = true;
input double BuyLotSize = 0.01;
input double SellLotSize = 0.01;
input bool CloseOnOppositeSignal = true;

input ulong BuyMagicNumber = 3251;
input ulong SellMagicNumber = 4251;
input int Deviation = 30;
input bool UseNewBar = true;

CTrade trade;

int g_score_handle = INVALID_HANDLE;
int g_atr_handle = INVALID_HANDLE;

datetime g_last_bar_time = 0;
int g_signal_shift = 1;

double g_vol_min = 0.0;
double g_vol_max = 0.0;
double g_vol_step = 0.0;
double g_point = 0.0;
int g_digits = 0;

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, g_digits);
}

double NormalizeVolume(double vol)
{
   if(g_vol_step <= 0.0)
      return NormalizeDouble(vol, 2);

   if(vol < g_vol_min)
      vol = g_vol_min;

   double normalized = g_vol_min + MathFloor((vol - g_vol_min + 1e-8) / g_vol_step) * g_vol_step;
   if(normalized < g_vol_min)
      normalized = g_vol_min;
   if(normalized > g_vol_max)
      normalized = g_vol_max;

   return NormalizeDouble(normalized, 8);
}

bool ReadBufferValue(const int handle, const int buffer_index, const int shift, double &value)
{
   if(handle == INVALID_HANDLE)
      return false;

   double tmp[1];
   int copied = CopyBuffer(handle, buffer_index, shift, 1, tmp);
   if(copied != 1 || tmp[0] == EMPTY_VALUE)
      return false;

   value = tmp[0];
   return true;
}

bool GetScoreValue(const int shift, double &score)
{
   if(!Use_Sumit_Score)
   {
      score = 50.0;
      return true;
   }

   return ReadBufferValue(g_score_handle, 4, shift, score);
}

bool IsManagedPosition(const ulong magic, const int type)
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != magic)
      return false;
   if((int)PositionGetInteger(POSITION_TYPE) != type)
      return false;
   return true;
}

int CountManagedPositions(const ulong magic, const int type)
{
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(IsManagedPosition(magic, type))
         count++;
   }
   return count;
}

int CloseManagedPositions(const ulong magic, const int type, const string reason)
{
   int closed = 0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!IsManagedPosition(magic, type))
         continue;

      trade.SetExpertMagicNumber(magic);
      trade.SetDeviationInPoints(Deviation);
      if(trade.PositionClose(ticket))
         closed++;
      else
         PrintFormat("%s close failed. ticket=%I64u retcode=%d (%s)",
                     reason, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   if(closed > 0)
      PrintFormat("%s closed=%d", reason, closed);
   return closed;
}

bool GetDonchianLevels(const int signal_shift, double &upper, double &lower)
{
   int bars = Bars(_Symbol, SignalTimeframe);
   if(bars <= DonchianPeriod + signal_shift + 1)
      return false;

   int lookback_start = signal_shift + 1; // Exclude signal bar itself.
   int highest_shift = iHighest(_Symbol, SignalTimeframe, MODE_HIGH, DonchianPeriod, lookback_start);
   int lowest_shift = iLowest(_Symbol, SignalTimeframe, MODE_LOW, DonchianPeriod, lookback_start);
   if(highest_shift < 0 || lowest_shift < 0)
      return false;

   upper = iHigh(_Symbol, SignalTimeframe, highest_shift);
   lower = iLow(_Symbol, SignalTimeframe, lowest_shift);
   return (upper > 0.0 && lower > 0.0);
}

bool BuildAtrStops(const bool is_buy, const double ref_price, const double atr_value, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   if(atr_value <= 0.0)
      return false;

   double sl_dist = atr_value * StopAtrMult;
   if(sl_dist < g_point)
      sl_dist = g_point;

   double tp_dist = atr_value * TargetAtrMult;
   if(tp_dist < g_point)
      tp_dist = g_point;

   if(StopAtrMult > 0.0)
      sl = is_buy ? NormalizePrice(ref_price - sl_dist) : NormalizePrice(ref_price + sl_dist);
   if(TargetAtrMult > 0.0)
      tp = is_buy ? NormalizePrice(ref_price + tp_dist) : NormalizePrice(ref_price - tp_dist);

   return true;
}

bool OpenBuy(const double lot, const double atr_value)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = 0.0;
   double tp = 0.0;
   BuildAtrStops(true, ask, atr_value, sl, tp);

   trade.SetExpertMagicNumber(BuyMagicNumber);
   trade.SetDeviationInPoints(Deviation);
   if(!trade.Buy(vol, _Symbol, 0.0, sl, tp, "Score_Don_ATR_BUY"))
   {
      PrintFormat("Buy failed. lot=%.4f retcode=%d (%s)",
                  vol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool OpenSell(const double lot, const double atr_value)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0;
   double tp = 0.0;
   BuildAtrStops(false, bid, atr_value, sl, tp);

   trade.SetExpertMagicNumber(SellMagicNumber);
   trade.SetDeviationInPoints(Deviation);
   if(!trade.Sell(vol, _Symbol, 0.0, sl, tp, "Score_Don_ATR_SELL"))
   {
      PrintFormat("Sell failed. lot=%.4f retcode=%d (%s)",
                  vol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

int OnInit()
{
   g_vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   if(g_vol_min <= 0.0 || g_vol_max <= 0.0 || g_point <= 0.0 || g_digits <= 0)
      return INIT_FAILED;

   if(DonchianPeriod < 2 || AtrPeriod < 2)
      return INIT_PARAMETERS_INCORRECT;

   g_signal_shift = SignalCandleShift;
   if(g_signal_shift < 0)
      g_signal_shift = 0;
   if(g_signal_shift > 2)
      g_signal_shift = 2;

   if(Use_Sumit_Score)
   {
      g_score_handle = iCustom(
         _Symbol,
         PERIOD_CURRENT,
         "Sumit_RSI_Score_Indicator",
         Rsi1hPeriod,
         SumitMaBuy,
         SumitMaSell,
         Rsi1hBuy,
         Rsi1hSell,
         SumitSma3Period,
         SumitSma201Period,
         SumitRsiPeriod
      );
      if(g_score_handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create Sumit score handle. err=%d", GetLastError());
         return INIT_FAILED;
      }
   }

   g_atr_handle = iATR(_Symbol, SignalTimeframe, AtrPeriod);
   if(g_atr_handle == INVALID_HANDLE)
   {
      PrintFormat("Failed to create ATR handle. err=%d", GetLastError());
      return INIT_FAILED;
   }

   PrintFormat("Score_Don_ATR init: score=%s Don=%d ATR=%d SLx=%.2f TPx=%.2f shift=%d tf=%s",
               Use_Sumit_Score ? "on" : "off",
               DonchianPeriod,
               AtrPeriod,
               StopAtrMult,
               TargetAtrMult,
               g_signal_shift,
               EnumToString(SignalTimeframe));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_score_handle != INVALID_HANDLE)
      IndicatorRelease(g_score_handle);
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
}

void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   if(UseNewBar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bar_time == 0 || bar_time == g_last_bar_time)
         return;
      g_last_bar_time = bar_time;
   }

   double signal_close = iClose(_Symbol, SignalTimeframe, g_signal_shift);
   if(signal_close <= 0.0)
      return;

   double don_upper = 0.0;
   double don_lower = 0.0;
   if(!GetDonchianLevels(g_signal_shift, don_upper, don_lower))
      return;

   double atr_value = 0.0;
   if(!ReadBufferValue(g_atr_handle, 0, g_signal_shift, atr_value))
      return;

   if(atr_value <= 0.0)
      return;

   double score = 50.0;
   if(!GetScoreValue(g_signal_shift, score))
      return;

   if(AtrMinPercent > 0.0)
   {
      double atr_pct = (atr_value / signal_close) * 100.0;
      if(atr_pct < AtrMinPercent)
         return;
   }

   double breakout_buffer = BreakoutBufferPoints * g_point;
   bool breakout_buy = (signal_close > (don_upper + breakout_buffer));
   bool breakout_sell = (signal_close < (don_lower - breakout_buffer));

   bool buy_score_ok = (!Use_Sumit_Score || score <= EntryScoreBuy);
   bool sell_score_ok = (!Use_Sumit_Score || score >= EntryScoreSell);

   bool buy_signal = BuyEntry && breakout_buy && buy_score_ok;
   bool sell_signal = SellEntry && breakout_sell && sell_score_ok;

   if(CloseOnOppositeSignal)
   {
      if(sell_signal)
         CloseManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, "Donchian opposite sell signal");
      if(buy_signal)
         CloseManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, "Donchian opposite buy signal");
   }

   if(buy_signal && CountManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY) == 0)
      OpenBuy(BuyLotSize, atr_value);

   if(sell_signal && CountManagedPositions(SellMagicNumber, POSITION_TYPE_SELL) == 0)
      OpenSell(SellLotSize, atr_value);
}

