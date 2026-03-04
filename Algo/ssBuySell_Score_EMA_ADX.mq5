//+------------------------------------------------------------------+
//|                                   ssBuySell_Score_EMA_ADX.mq5    |
//| Momentum EA: Sumit Score + EMA trend + ADX strength              |
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
input int EntryScoreBuy = 50;    // Buy when score <= EntryScoreBuy
input int EntryScoreSell = 50;   // Sell when score >= EntryScoreSell

input int FastEmaPeriod = 21;
input int SlowEmaPeriod = 55;
input ENUM_TIMEFRAMES TrendTimeframe = PERIOD_CURRENT;

input int AdxPeriod = 14;
input double AdxMin = 18.0;
input bool UseDiDirection = true; // Buy: +DI>-DI, Sell: -DI>+DI

input int SignalCandleShift = 1; // 0=current bar, 1=last closed bar

// Trading
input bool BuyEntry = true;
input bool SellEntry = true;
input double BuyLotSize = 0.01;
input double SellLotSize = 0.01;

input bool UseStopLoss = true;
input double StopPercent = 0.20;   // Percent of entry price
input bool UseTakeProfit = true;
input double TargetPercent = 0.30; // Percent of entry price

input bool CloseOnOppositeSignal = true;

input ulong BuyMagicNumber = 3151;
input ulong SellMagicNumber = 4151;
input int Deviation = 30;
input bool UseNewBar = true;

CTrade trade;

int g_score_handle = INVALID_HANDLE;
int g_ema_fast_handle = INVALID_HANDLE;
int g_ema_slow_handle = INVALID_HANDLE;
int g_adx_handle = INVALID_HANDLE;

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

double PercentDistance(const double price, const double pct)
{
   if(price <= 0.0 || pct <= 0.0)
      return 0.0;

   double dist = price * (pct / 100.0);
   if(dist < g_point)
      dist = g_point;
   return dist;
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

void BuildStops(const bool is_buy, const double ref_price, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   if(UseStopLoss && StopPercent > 0.0)
   {
      double dist = PercentDistance(ref_price, StopPercent);
      sl = is_buy ? NormalizePrice(ref_price - dist) : NormalizePrice(ref_price + dist);
   }

   if(UseTakeProfit && TargetPercent > 0.0)
   {
      double dist = PercentDistance(ref_price, TargetPercent);
      tp = is_buy ? NormalizePrice(ref_price + dist) : NormalizePrice(ref_price - dist);
   }
}

bool OpenBuy(const double lot)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = 0.0;
   double tp = 0.0;
   BuildStops(true, ask, sl, tp);

   trade.SetExpertMagicNumber(BuyMagicNumber);
   trade.SetDeviationInPoints(Deviation);

   if(!trade.Buy(vol, _Symbol, 0.0, sl, tp, "Score_EMA_ADX_BUY"))
   {
      PrintFormat("Buy failed. lot=%.4f retcode=%d (%s)",
                  vol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool OpenSell(const double lot)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0.0;
   double tp = 0.0;
   BuildStops(false, bid, sl, tp);

   trade.SetExpertMagicNumber(SellMagicNumber);
   trade.SetDeviationInPoints(Deviation);

   if(!trade.Sell(vol, _Symbol, 0.0, sl, tp, "Score_EMA_ADX_SELL"))
   {
      PrintFormat("Sell failed. lot=%.4f retcode=%d (%s)",
                  vol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }
   return true;
}

bool ReadSignalData(const int shift,
                    double &score,
                    double &ema_fast,
                    double &ema_slow,
                    double &adx,
                    double &di_plus,
                    double &di_minus)
{
   if(!GetScoreValue(shift, score))
      return false;
   if(!ReadBufferValue(g_ema_fast_handle, 0, shift, ema_fast))
      return false;
   if(!ReadBufferValue(g_ema_slow_handle, 0, shift, ema_slow))
      return false;
   if(!ReadBufferValue(g_adx_handle, 0, shift, adx))
      return false;
   if(!ReadBufferValue(g_adx_handle, 1, shift, di_plus))
      return false;
   if(!ReadBufferValue(g_adx_handle, 2, shift, di_minus))
      return false;
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

   if(FastEmaPeriod <= 1 || SlowEmaPeriod <= 1 || FastEmaPeriod >= SlowEmaPeriod)
   {
      Print("EMA settings invalid. Require FastEmaPeriod < SlowEmaPeriod.");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(AdxPeriod <= 1)
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

   g_ema_fast_handle = iMA(_Symbol, TrendTimeframe, FastEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_ema_slow_handle = iMA(_Symbol, TrendTimeframe, SlowEmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_adx_handle = iADX(_Symbol, TrendTimeframe, AdxPeriod);
   if(g_ema_fast_handle == INVALID_HANDLE || g_ema_slow_handle == INVALID_HANDLE || g_adx_handle == INVALID_HANDLE)
   {
      PrintFormat("Failed to create EMA/ADX handles. err=%d", GetLastError());
      return INIT_FAILED;
   }

   PrintFormat("Score_EMA_ADX init: score=%s EMA=%d/%d ADX=%d min=%.2f shift=%d tf=%s",
               Use_Sumit_Score ? "on" : "off",
               FastEmaPeriod,
               SlowEmaPeriod,
               AdxPeriod,
               AdxMin,
               g_signal_shift,
               EnumToString(TrendTimeframe));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_score_handle != INVALID_HANDLE)
      IndicatorRelease(g_score_handle);
   if(g_ema_fast_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_fast_handle);
   if(g_ema_slow_handle != INVALID_HANDLE)
      IndicatorRelease(g_ema_slow_handle);
   if(g_adx_handle != INVALID_HANDLE)
      IndicatorRelease(g_adx_handle);
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

   double score = 50.0;
   double ema_fast = 0.0;
   double ema_slow = 0.0;
   double adx = 0.0;
   double di_plus = 0.0;
   double di_minus = 0.0;
   if(!ReadSignalData(g_signal_shift, score, ema_fast, ema_slow, adx, di_plus, di_minus))
      return;

   bool buy_score_ok = (!Use_Sumit_Score || score <= EntryScoreBuy);
   bool sell_score_ok = (!Use_Sumit_Score || score >= EntryScoreSell);
   bool adx_ok = (adx >= AdxMin);

   bool buy_di_ok = (!UseDiDirection || di_plus > di_minus);
   bool sell_di_ok = (!UseDiDirection || di_minus > di_plus);

   bool buy_signal = BuyEntry && buy_score_ok && adx_ok && (ema_fast > ema_slow) && buy_di_ok;
   bool sell_signal = SellEntry && sell_score_ok && adx_ok && (ema_fast < ema_slow) && sell_di_ok;

   if(CloseOnOppositeSignal)
   {
      if(sell_signal)
         CloseManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, "EMA+ADX opposite sell signal");
      if(buy_signal)
         CloseManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, "EMA+ADX opposite buy signal");
   }

   if(buy_signal && CountManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY) == 0)
      OpenBuy(BuyLotSize);

   if(sell_signal && CountManagedPositions(SellMagicNumber, POSITION_TYPE_SELL) == 0)
      OpenSell(SellLotSize);
}

