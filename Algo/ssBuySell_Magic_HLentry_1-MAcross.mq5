//+---------------------ssBuySell_Magic_HLentry_1.mq5---------------------------------------------+
//|      
//   Combined Buy + Sell strategy with separate side controls   |
//| Uses external indicators: Sumit_RSI_Score_Indicator + 3by7 MA Cross |
//
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

enum ENUM_MACROSS_SIGNAL_MODE
{
   MACROSS_CONFIRMED = 0, // Use closed candle MA state (stable, later)
   MACROSS_INTRABAR = 1,  // Use current candle MA state (faster, noisier)
   MACROSS_PREDICTIVE = 2 // Anticipate near cross using MA gap + spread velocity
};

// Inputs for Sumit_RSI_Score_Indicator
input int Rsi1hPeriod = 51;
input int SumitMaBuyThreshold = 30;
input int SumitMaSellThreshold = 70;
input int Rsi1hBuyThreshold = 40;
input int Rsi1hSellThreshold = 55;
input int SumitSma3Period = 3;
input int SumitSma201Period = 201;
input int SumitRsiPeriod = 7;

// Side enable + score threshold
input bool BuyEntry = true;
input bool SellEntry = true;
input int EntryScoreThresholdBuy = 40;   // Buy condition: score <= threshold
input int EntryScoreThresholdSell = 60;  // Sell condition: score >= threshold

// SuperTrend filter (runtime-selectable timeframe)
input bool UseSuperTrend = false;
input int SupertrendAtrPeriod = 51;
input double SupertrendMultiplier = 0.5;
input ENUM_TIMEFRAMES Supertrend_Timeframe = PERIOD_M15; // e.g.  PERIOD_H1
input ENUM_APPLIED_PRICE SupertrendSourcePrice = PRICE_MEDIAN; // PRICE_CLOSE, PRICE_OPEN, PRICE_HIGH, PRICE_LOW, PRICE_MEDIAN, PRICE_TYPICAL, PRICE_WEIGHTED
input bool SupertrendTakeWicksIntoAccount = true; // true=use wick highs/lows, false=use candle body values
input bool SupetrendBasedSL = false; // Close opposite-direction trades when SuperTrend flips

// MA Cross filter (MA-1 vs MA-2)
input bool UseMACross = true;
input ENUM_TIMEFRAMES MATimeframe = PERIOD_CURRENT;
input int MA1Period = 3;
input ENUM_MA_METHOD MA1Method = MODE_EMA;
input ENUM_APPLIED_PRICE MA1Price = PRICE_CLOSE;
input int MA2Period = 7;
input ENUM_MA_METHOD MA2Method = MODE_EMA;
input ENUM_APPLIED_PRICE MA2Price = PRICE_CLOSE;
input ENUM_MACROSS_SIGNAL_MODE MACrossMode = MACROSS_CONFIRMED;
input bool MAPredictiveUseATR = true; // Predictive mode: derive gap from ATR so it scales by symbol volatility
input int MAPredictiveATRPeriod = 14;
input double MAPredictiveATRMultiplier = 0.10; // Effective predictive gap = ATR * multiplier
input double MAPredictiveGapPoints = 20.0; // Fallback fixed gap (points) when ATR mode is off/unavailable

// Trading logic (common)
double MinTargetPoints = 0.0;    // Not used in pure MA-cross mode
double TargetPercent = 0.0;      // Not used in pure MA-cross mode
bool SetTargetWithEntry = false; // Not used in pure MA-cross mode
double TrailingTargetPips = 0.0; // Not used in pure MA-cross mode
input bool RecoverExistingMagicPositions = true; // Rebuild and manage existing magic positions on restart

// Buy-side settings
input string chk_last_candle_breaks_buy = "0"; // 0=disabled, H/L/O/C = prev candle High/Low/Open/Close
input string chk_last_candle_type_buy = "0";   // 0=disabled, G=green candle, R=red candle
input double BuyLotSize = 0.01;
input double BuyLotStep = 0.01;
input int BuyMaxEntries = 0; // 0 = unlimited

// Sell-side settings
input string chk_last_candle_breaks_sell = "0"; // 0=disabled, H/L/O/C = prev candle High/Low/Open/Close
input string chk_last_candle_type_sell = "0";   // 0=disabled, G=green candle, R=red candle
input double SellLotSize = 0.01;
input double SellLotStep = 0.01;
input int SellMaxEntries = 0; // 0 = unlimited

// Execution
input ulong BuyMagicNumber = 1051;
input ulong SellMagicNumber = 2051;
input int Deviation = 30;
input bool UseNewBar = true;

CTrade trade;

struct Tranche
{
   int      seq;
   ulong    ticket;       // Position ticket for hedging (0 for netting)
   datetime time_open;
   double   entry_price;
   double   volume;
   double   target_price;
   bool     trailing_active;
   double   trailing_peak;
   bool     closed;
};

Tranche buy_tranches[];
Tranche sell_tranches[];

int buy_next_seq = 0;
int sell_next_seq = 0;

double buy_last_entry_price_open = 0.0;
double buy_last_entry_lot = 0.0;
double buy_last_entry_price_ref = 0.0;

double sell_last_entry_price_open = 0.0;
double sell_last_entry_lot = 0.0;
double sell_last_entry_price_ref = 0.0;

datetime last_bar_time = 0;

int sumitScoreHandle = INVALID_HANDLE;
int supertrendH1Handle = INVALID_HANDLE;
int ma1Handle = INVALID_HANDLE;
int ma2Handle = INVALID_HANDLE;
int maPredictiveAtrHandle = INVALID_HANDLE;
int supertrend_last_direction = 0; // +1 bullish, -1 bearish, 0 unknown

// Cached symbol properties (faster than repeated SymbolInfoDouble calls)
double g_vol_min = 0.0;
double g_vol_max = 0.0;
double g_vol_step = 0.0;
double g_point = 0.0;
double g_pip = 0.0;
int g_digits = 0;

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
bool IsHedging()
{
   return(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

double NormalizeVolume(double vol)
{
   double minv = g_vol_min;
   double maxv = g_vol_max;
   double step = g_vol_step;

   if(step <= 0.0)
      step = minv;

   if(vol < minv)
      vol = minv;

   // Avoid floating precision traps (e.g. 0.07 / 0.01 => 6.999999...)
   double normalized = minv + MathFloor((vol - minv + 1e-8) / step) * step;
   if(normalized < minv)
      normalized = minv;
   if(normalized > maxv)
      normalized = maxv;

   return NormalizeDouble(normalized, 8);
}

double NormalizePrice(const double price)
{
   return NormalizeDouble(price, g_digits);
}

double CalculatePipSize()
{
   // 5/3-digit symbols use 10 points per pip.
   if(g_digits == 3 || g_digits == 5)
      return g_point * 10.0;
   return g_point;
}

double CalculateTargetDistance(const double entry_price)
{
   double minDist = MinTargetPoints * g_point;
   double pctDist = entry_price * (TargetPercent / 100.0);
   return MathMax(minDist, pctDist);
}

double CalculateTargetPriceBuy(const double entry_price)
{
   return NormalizePrice(entry_price + CalculateTargetDistance(entry_price));
}

double CalculateTargetPriceSell(const double entry_price)
{
   return NormalizePrice(entry_price - CalculateTargetDistance(entry_price));
}

double CalculateTrailingDistance(const double reference_price)
{
   if(TrailingTargetPips <= 0.0 || reference_price <= 0.0)
      return 0.0;
   return reference_price * (TrailingTargetPips / 100.0);
}

double CalculateStepDistance(const double reference_price)
{
   return reference_price * (TargetPercent / 100.0);
}

bool GetScoreValue(const int shift, double &score)
{
   if(sumitScoreHandle == INVALID_HANDLE)
      return false;

   double score_value[1];
   int copied = CopyBuffer(sumitScoreHandle, 4, shift, 1, score_value);
   if(copied != 1)
      return false;

   if(score_value[0] == EMPTY_VALUE)
      return false;

   score = score_value[0];
   return true;
}

int GetSuperTrendDirection(const int shift)
{
   if(supertrendH1Handle == INVALID_HANDLE)
      return 0;

   double direction_value[1];
   int copied = CopyBuffer(supertrendH1Handle, 2, shift, 1, direction_value);
   if(copied != 1)
      return 0;

   if(direction_value[0] == EMPTY_VALUE)
      return 0;

   if(direction_value[0] > 0.0)
      return 1;
   if(direction_value[0] < 0.0)
      return -1;

   return 0;
}

bool IsSuperTrendBullishH1(const int shift)
{
   return (GetSuperTrendDirection(shift) > 0);
}

bool IsSuperTrendBearishH1(const int shift)
{
   return (GetSuperTrendDirection(shift) < 0);
}

bool GetMAValue(const int handle, const int shift, double &value)
{
   if(handle == INVALID_HANDLE)
      return false;

   double values[1];
   int copied = CopyBuffer(handle, 0, shift, 1, values);
   if(copied != 1)
      return false;
   if(values[0] == EMPTY_VALUE)
      return false;

   value = values[0];
   return true;
}

double GetMAPredictiveGapPrice()
{
   if(MAPredictiveUseATR && maPredictiveAtrHandle != INVALID_HANDLE)
   {
      double atr_values[1];
      int copied = CopyBuffer(maPredictiveAtrHandle, 0, 0, 1, atr_values);
      if(copied == 1 && atr_values[0] != EMPTY_VALUE && atr_values[0] > 0.0)
         return (atr_values[0] * MathMax(0.0, MAPredictiveATRMultiplier));
   }

   return (MathMax(0.0, MAPredictiveGapPoints) * g_point);
}

int GetMACrossDirection()
{
   if(!UseMACross || ma1Handle == INVALID_HANDLE || ma2Handle == INVALID_HANDLE)
      return 0;

   double ma1_0 = 0.0;
   double ma2_0 = 0.0;
   if(!GetMAValue(ma1Handle, 0, ma1_0) || !GetMAValue(ma2Handle, 0, ma2_0))
      return 0;

   if(MACrossMode == MACROSS_CONFIRMED)
   {
      double ma1_1 = 0.0;
      double ma2_1 = 0.0;
      if(!GetMAValue(ma1Handle, 1, ma1_1) || !GetMAValue(ma2Handle, 1, ma2_1))
         return 0;
      if(ma1_1 > ma2_1)
         return 1;
      if(ma1_1 < ma2_1)
         return -1;
      return 0;
   }

   if(MACrossMode == MACROSS_INTRABAR)
   {
      if(ma1_0 > ma2_0)
         return 1;
      if(ma1_0 < ma2_0)
         return -1;
      return 0;
   }

   double ma1_1 = 0.0;
   double ma2_1 = 0.0;
   if(!GetMAValue(ma1Handle, 1, ma1_1) || !GetMAValue(ma2Handle, 1, ma2_1))
      return 0;

   double spread0 = ma1_0 - ma2_0;
   double spread1 = ma1_1 - ma2_1;
   double spread_velocity = spread0 - spread1;
   double predictive_gap = GetMAPredictiveGapPrice();

   if(spread0 > 0.0)
   {
      // Fast MA is still above, but spread is shrinking near zero -> early bearish warning.
      if(predictive_gap > 0.0 && spread0 <= predictive_gap && spread_velocity < 0.0)
         return -1;
      return 1;
   }
   if(spread0 < 0.0)
   {
      // Fast MA is still below, but spread is closing near zero -> early bullish warning.
      if(predictive_gap > 0.0 && MathAbs(spread0) <= predictive_gap && spread_velocity > 0.0)
         return 1;
      return -1;
   }

   if(spread_velocity > 0.0)
      return 1;
   if(spread_velocity < 0.0)
      return -1;

   return 0;
}

bool IsMACrossBullish()
{
   return (GetMACrossDirection() > 0);
}

bool IsMACrossBearish()
{
   return (GetMACrossDirection() < 0);
}

int GetMACrossEventDirection()
{
   if(!UseMACross || ma1Handle == INVALID_HANDLE || ma2Handle == INVALID_HANDLE)
      return 0;

   int curr_shift = (MACrossMode == MACROSS_CONFIRMED) ? 1 : 0;
   int prev_shift = curr_shift + 1;

   double ma1_curr = 0.0;
   double ma2_curr = 0.0;
   double ma1_prev = 0.0;
   double ma2_prev = 0.0;

   if(!GetMAValue(ma1Handle, curr_shift, ma1_curr) || !GetMAValue(ma2Handle, curr_shift, ma2_curr))
      return 0;
   if(!GetMAValue(ma1Handle, prev_shift, ma1_prev) || !GetMAValue(ma2Handle, prev_shift, ma2_prev))
      return 0;

   double spread_curr = ma1_curr - ma2_curr;
   double spread_prev = ma1_prev - ma2_prev;

   if(spread_prev <= 0.0 && spread_curr > 0.0)
      return 1;  // upside cross
   if(spread_prev >= 0.0 && spread_curr < 0.0)
      return -1; // downside cross

   return 0;
}

bool IsLastCandleBreakConditionMet(const double price, const string break_input, const string type_input, const bool is_buy)
{
   string break_mode = break_input;
   StringTrimLeft(break_mode);
   StringTrimRight(break_mode);
   StringToUpper(break_mode);
   if(break_mode == "" || break_mode == "0")
      return true;

   string type_mode = type_input;
   StringTrimLeft(type_mode);
   StringTrimRight(type_mode);
   StringToUpper(type_mode);

   double prev_high = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double prev_low = iLow(_Symbol, PERIOD_CURRENT, 1);
   double prev_open = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double prev_close = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(prev_high <= 0.0 || prev_low <= 0.0 || prev_open <= 0.0 || prev_close <= 0.0)
      return false;

   if(type_mode == "G" && prev_close <= prev_open)
      return false;
   if(type_mode == "R" && prev_close >= prev_open)
      return false;

   double break_level = 0.0;
   if(break_mode == "H")
      break_level = prev_high;
   else if(break_mode == "L")
      break_level = prev_low;
   else if(break_mode == "O")
      break_level = prev_open;
   else if(break_mode == "C")
      break_level = prev_close;
   else
      return true; // Invalid value behaves like disabled

   if(is_buy)
      return (price < break_level);

   return (price > break_level);
}

bool IsManagedPosition(const ulong magic, const int position_type)
{
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != magic)
      return false;
   if((int)PositionGetInteger(POSITION_TYPE) != position_type)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Buy-side tranche management                                      |
//+------------------------------------------------------------------+
int OpenTrancheCountBuy()
{
   int count = 0;
   int total = ArraySize(buy_tranches);
   for(int i = 0; i < total; i++)
   {
      if(!buy_tranches[i].closed)
         count++;
   }
   return count;
}

void UpdateLastEntryFromOpenBuy()
{
   buy_last_entry_price_open = 0.0;
   buy_last_entry_lot = 0.0;
   datetime last_time = 0;
   int total = ArraySize(buy_tranches);
   for(int i = 0; i < total; i++)
   {
      if(buy_tranches[i].closed)
         continue;
      if(buy_tranches[i].time_open >= last_time)
      {
         last_time = buy_tranches[i].time_open;
         buy_last_entry_price_open = buy_tranches[i].entry_price;
         buy_last_entry_lot = buy_tranches[i].volume;
      }
   }
}

void EnsureServerTargetsForOpenPositionsBuy(const bool hedging)
{
   if(!SetTargetWithEntry || !RecoverExistingMagicPositions)
      return;

   int ptotal = PositionsTotal();
   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!IsManagedPosition(BuyMagicNumber, POSITION_TYPE_BUY))
         continue;
      if(PositionGetDouble(POSITION_TP) > 0.0)
         continue;

      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double target_price = CalculateTargetPriceBuy(entry_price);
      bool modified = hedging
                      ? trade.PositionModify(ticket, 0.0, target_price)
                      : trade.PositionModify(_Symbol, 0.0, target_price);

      if(!modified)
      {
         PrintFormat("Buy recovery TP set failed. ticket=%I64u target=%.5f retcode=%d (%s)",
                     ticket, target_price, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      else
      {
         PrintFormat("Buy recovery TP set. ticket=%I64u target=%.5f", ticket, target_price);
      }
   }
}

void SyncTranchesBuy(const bool hedging)
{
   int total = ArraySize(buy_tranches);
   if(total == 0)
      return;

   if(hedging)
   {
      for(int i = 0; i < total; i++)
      {
         if(buy_tranches[i].closed)
            continue;
         if(!PositionSelectByTicket(buy_tranches[i].ticket))
         {
            buy_tranches[i].closed = true;
            buy_last_entry_price_ref = buy_tranches[i].entry_price;
         }
      }
   }
   else
   {
      bool hasPosition = false;
      int ptotal = PositionsTotal();
      for(int i = 0; i < ptotal; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;

         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != BuyMagicNumber)
            continue;
         if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
            continue;

         hasPosition = true;
         break;
      }

      if(!hasPosition)
      {
         for(int i = 0; i < total; i++)
         {
            if(!buy_tranches[i].closed)
               buy_last_entry_price_ref = buy_tranches[i].entry_price;
            buy_tranches[i].closed = true;
         }
      }
   }

   UpdateLastEntryFromOpenBuy();
}
void RebuildTranchesFromPositionsBuy(const bool hedging)
{
   if(ArraySize(buy_tranches) > 0)
      return;

   int ptotal = PositionsTotal();
   if(ptotal <= 0)
      return;

   int valid_count = 0;
   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != BuyMagicNumber)
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      valid_count++;
   }

   if(valid_count == 0)
      return;

   ArrayResize(buy_tranches, valid_count);
   int idx = 0;

   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != BuyMagicNumber) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      Tranche t;
      t.seq = ++buy_next_seq;
      t.ticket = hedging ? (ulong)PositionGetInteger(POSITION_TICKET) : 0;
      t.time_open = (datetime)PositionGetInteger(POSITION_TIME);
      t.entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      t.volume = PositionGetDouble(POSITION_VOLUME);
      double broker_tp = PositionGetDouble(POSITION_TP);
      t.target_price = (broker_tp > 0.0) ? broker_tp : CalculateTargetPriceBuy(t.entry_price);
      t.trailing_active = false;
      t.trailing_peak = 0.0;
      t.closed = false;

      if(idx < valid_count)
         buy_tranches[idx++] = t;
   }

   UpdateLastEntryFromOpenBuy();
   if(buy_last_entry_price_open > 0.0)
      buy_last_entry_price_ref = buy_last_entry_price_open;
}

bool AddTrancheBuy(const double entry_price, const double volume, const ulong ticket, const double target_price = 0.0)
{
   Tranche t;
   t.seq = ++buy_next_seq;
   t.ticket = ticket;
   t.time_open = TimeCurrent();
   t.entry_price = entry_price;
   t.volume = volume;
   t.target_price = (target_price > 0.0) ? target_price : CalculateTargetPriceBuy(entry_price);
   t.trailing_active = false;
   t.trailing_peak = 0.0;
   t.closed = false;

   int sz = ArraySize(buy_tranches);
   ArrayResize(buy_tranches, sz + 1);
   buy_tranches[sz] = t;

   buy_last_entry_price_open = entry_price;
   buy_last_entry_lot = volume;
   buy_last_entry_price_ref = entry_price;
   return true;
}

void CheckTargetsBuy(const bool hedging, const double current_price)
{
   int total = ArraySize(buy_tranches);
   if(total == 0)
      return;

   bool use_trailing = (!SetTargetWithEntry && TrailingTargetPips > 0.0);

   for(int i = 0; i < total; i++)
   {
      if(buy_tranches[i].closed)
         continue;

      bool should_close = false;
      if(!use_trailing)
      {
         if(current_price >= buy_tranches[i].target_price)
            should_close = true;
      }
      else
      {
         if(!buy_tranches[i].trailing_active)
         {
            if(current_price >= buy_tranches[i].target_price)
            {
               buy_tranches[i].trailing_active = true;
               buy_tranches[i].trailing_peak = current_price;
            }
            continue;
         }

         if(current_price > buy_tranches[i].trailing_peak)
            buy_tranches[i].trailing_peak = current_price;

         double trailing_distance = CalculateTrailingDistance(buy_tranches[i].trailing_peak);
         if(trailing_distance <= 0.0)
            continue;
         double trailing_stop = buy_tranches[i].trailing_peak - trailing_distance;
         if(current_price <= trailing_stop)
            should_close = true;
      }

      if(!should_close)
         continue;

      bool closed_now = false;
      if(hedging)
      {
         if(PositionSelectByTicket(buy_tranches[i].ticket))
            closed_now = trade.PositionClose(buy_tranches[i].ticket);
      }
      else
      {
         if(PositionSelect(_Symbol) &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == BuyMagicNumber &&
            (int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            closed_now = trade.PositionClosePartial(_Symbol, buy_tranches[i].volume);
         }
      }

      if(closed_now)
      {
         buy_last_entry_price_ref = buy_tranches[i].entry_price;
         buy_tranches[i].closed = true;
      }
   }

   UpdateLastEntryFromOpenBuy();
}

bool TryOpenEntryBuy(const double price, const double lot, const bool hedging)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   if(MathAbs(vol - lot) > 1e-8)
   {
      PrintFormat("Buy lot normalized. reqLot=%.4f normLot=%.4f min=%.4f step=%.4f max=%.4f",
                  lot, vol, g_vol_min, g_vol_step, g_vol_max);
   }

   trade.SetExpertMagicNumber(BuyMagicNumber);
   trade.SetDeviationInPoints(Deviation);

   string comment = StringFormat("SB|lot=%.2f", vol);
   double request_target = 0.0;
   if(SetTargetWithEntry)
      request_target = CalculateTargetPriceBuy(price);

   if(!trade.Buy(vol, _Symbol, 0, 0, request_target, comment))
   {
      PrintFormat("Buy failed. reqLot=%.4f normLot=%.4f retcode=%d (%s)",
                  lot, vol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }

   double entry_price = trade.ResultPrice();
   if(entry_price <= 0.0)
      entry_price = price;

   ulong ticket = 0;
   if(hedging)
   {
      ulong deal = trade.ResultDeal();
      if(deal > 0 && HistoryDealSelect(deal))
         ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   }

   double tranche_target = CalculateTargetPriceBuy(entry_price);

   if(SetTargetWithEntry)
   {
      bool can_verify_position = false;
      bool modified = true;
      if(hedging && ticket > 0 && PositionSelectByTicket(ticket))
      {
         can_verify_position = true;
         double current_tp = PositionGetDouble(POSITION_TP);
         if(current_tp <= 0.0 || MathAbs(current_tp - tranche_target) > (g_point * 0.5))
            modified = trade.PositionModify(ticket, 0.0, tranche_target);
      }
      else if(!hedging && PositionSelect(_Symbol))
      {
         can_verify_position = true;
         double current_tp = PositionGetDouble(POSITION_TP);
         if((ulong)PositionGetInteger(POSITION_MAGIC) == BuyMagicNumber &&
            (int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            if(current_tp <= 0.0 || MathAbs(current_tp - tranche_target) > (g_point * 0.5))
               modified = trade.PositionModify(_Symbol, 0.0, tranche_target);
         }
      }

      if(can_verify_position && !modified)
      {
         PrintFormat("Buy post-entry TP attach failed. target=%.5f retcode=%d (%s)",
                     tranche_target, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }

   AddTrancheBuy(entry_price, vol, ticket, tranche_target);
   return true;
}

//+------------------------------------------------------------------+
//| Sell-side tranche management                                     |
//+------------------------------------------------------------------+
int OpenTrancheCountSell()
{
   int count = 0;
   int total = ArraySize(sell_tranches);
   for(int i = 0; i < total; i++)
   {
      if(!sell_tranches[i].closed)
         count++;
   }
   return count;
}

void UpdateLastEntryFromOpenSell()
{
   sell_last_entry_price_open = 0.0;
   sell_last_entry_lot = 0.0;
   datetime last_time = 0;
   int total = ArraySize(sell_tranches);
   for(int i = 0; i < total; i++)
   {
      if(sell_tranches[i].closed)
         continue;
      if(sell_tranches[i].time_open >= last_time)
      {
         last_time = sell_tranches[i].time_open;
         sell_last_entry_price_open = sell_tranches[i].entry_price;
         sell_last_entry_lot = sell_tranches[i].volume;
      }
   }
}

void EnsureServerTargetsForOpenPositionsSell(const bool hedging)
{
   if(!SetTargetWithEntry || !RecoverExistingMagicPositions)
      return;

   int ptotal = PositionsTotal();
   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!IsManagedPosition(SellMagicNumber, POSITION_TYPE_SELL))
         continue;
      if(PositionGetDouble(POSITION_TP) > 0.0)
         continue;

      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double target_price = CalculateTargetPriceSell(entry_price);
      bool modified = hedging
                      ? trade.PositionModify(ticket, 0.0, target_price)
                      : trade.PositionModify(_Symbol, 0.0, target_price);

      if(!modified)
      {
         PrintFormat("Sell recovery TP set failed. ticket=%I64u target=%.5f retcode=%d (%s)",
                     ticket, target_price, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      else
      {
         PrintFormat("Sell recovery TP set. ticket=%I64u target=%.5f", ticket, target_price);
      }
   }
}

void SyncTranchesSell(const bool hedging)
{
   int total = ArraySize(sell_tranches);
   if(total == 0)
      return;

   if(hedging)
   {
      for(int i = 0; i < total; i++)
      {
         if(sell_tranches[i].closed)
            continue;
         if(!PositionSelectByTicket(sell_tranches[i].ticket))
         {
            sell_tranches[i].closed = true;
            sell_last_entry_price_ref = sell_tranches[i].entry_price;
         }
      }
   }
   else
   {
      bool hasPosition = false;
      int ptotal = PositionsTotal();
      for(int i = 0; i < ptotal; i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;

         if(PositionGetString(POSITION_SYMBOL) != _Symbol)
            continue;
         if((ulong)PositionGetInteger(POSITION_MAGIC) != SellMagicNumber)
            continue;
         if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
            continue;

         hasPosition = true;
         break;
      }

      if(!hasPosition)
      {
         for(int i = 0; i < total; i++)
         {
            if(!sell_tranches[i].closed)
               sell_last_entry_price_ref = sell_tranches[i].entry_price;
            sell_tranches[i].closed = true;
         }
      }
   }

   UpdateLastEntryFromOpenSell();
}
void RebuildTranchesFromPositionsSell(const bool hedging)
{
   if(ArraySize(sell_tranches) > 0)
      return;

   int ptotal = PositionsTotal();
   if(ptotal <= 0)
      return;

   int valid_count = 0;
   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != SellMagicNumber)
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL)
         continue;

      valid_count++;
   }

   if(valid_count == 0)
      return;

   ArrayResize(sell_tranches, valid_count);
   int idx = 0;

   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != SellMagicNumber) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;

      Tranche t;
      t.seq = ++sell_next_seq;
      t.ticket = hedging ? (ulong)PositionGetInteger(POSITION_TICKET) : 0;
      t.time_open = (datetime)PositionGetInteger(POSITION_TIME);
      t.entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      t.volume = PositionGetDouble(POSITION_VOLUME);
      double broker_tp = PositionGetDouble(POSITION_TP);
      t.target_price = (broker_tp > 0.0) ? broker_tp : CalculateTargetPriceSell(t.entry_price);
      t.trailing_active = false;
      t.trailing_peak = 0.0;
      t.closed = false;

      if(idx < valid_count)
         sell_tranches[idx++] = t;
   }

   UpdateLastEntryFromOpenSell();
   if(sell_last_entry_price_open > 0.0)
      sell_last_entry_price_ref = sell_last_entry_price_open;
}

bool AddTrancheSell(const double entry_price, const double volume, const ulong ticket, const double target_price = 0.0)
{
   Tranche t;
   t.seq = ++sell_next_seq;
   t.ticket = ticket;
   t.time_open = TimeCurrent();
   t.entry_price = entry_price;
   t.volume = volume;
   t.target_price = (target_price > 0.0) ? target_price : CalculateTargetPriceSell(entry_price);
   t.trailing_active = false;
   t.trailing_peak = 0.0;
   t.closed = false;

   int sz = ArraySize(sell_tranches);
   ArrayResize(sell_tranches, sz + 1);
   sell_tranches[sz] = t;

   sell_last_entry_price_open = entry_price;
   sell_last_entry_lot = volume;
   sell_last_entry_price_ref = entry_price;
   return true;
}

void CheckTargetsSell(const bool hedging, const double current_price)
{
   int total = ArraySize(sell_tranches);
   if(total == 0)
      return;

   bool use_trailing = (!SetTargetWithEntry && TrailingTargetPips > 0.0);

   for(int i = 0; i < total; i++)
   {
      if(sell_tranches[i].closed)
         continue;

      bool should_close = false;
      if(!use_trailing)
      {
         if(current_price <= sell_tranches[i].target_price)
            should_close = true;
      }
      else
      {
         if(!sell_tranches[i].trailing_active)
         {
            if(current_price <= sell_tranches[i].target_price)
            {
               sell_tranches[i].trailing_active = true;
               sell_tranches[i].trailing_peak = current_price;
            }
            continue;
         }

         if(current_price < sell_tranches[i].trailing_peak)
            sell_tranches[i].trailing_peak = current_price;

         double trailing_distance = CalculateTrailingDistance(sell_tranches[i].trailing_peak);
         if(trailing_distance <= 0.0)
            continue;
         double trailing_stop = sell_tranches[i].trailing_peak + trailing_distance;
         if(current_price >= trailing_stop)
            should_close = true;
      }

      if(!should_close)
         continue;

      bool closed_now = false;
      if(hedging)
      {
         if(PositionSelectByTicket(sell_tranches[i].ticket))
            closed_now = trade.PositionClose(sell_tranches[i].ticket);
      }
      else
      {
         if(PositionSelect(_Symbol) &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == SellMagicNumber &&
            (int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         {
            closed_now = trade.PositionClosePartial(_Symbol, sell_tranches[i].volume);
         }
      }

      if(closed_now)
      {
         sell_last_entry_price_ref = sell_tranches[i].entry_price;
         sell_tranches[i].closed = true;
      }
   }

   UpdateLastEntryFromOpenSell();
}

bool TryOpenEntrySell(const double price, const double lot, const bool hedging)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   if(MathAbs(vol - lot) > 1e-8)
   {
      PrintFormat("Sell lot normalized. reqLot=%.4f normLot=%.4f min=%.4f step=%.4f max=%.4f",
                  lot, vol, g_vol_min, g_vol_step, g_vol_max);
   }

   trade.SetExpertMagicNumber(SellMagicNumber);
   trade.SetDeviationInPoints(Deviation);

   string comment = StringFormat("SS|lot=%.2f", vol);
   double request_target = 0.0;
   if(SetTargetWithEntry)
      request_target = CalculateTargetPriceSell(price);

   if(!trade.Sell(vol, _Symbol, 0, 0, request_target, comment))
   {
      PrintFormat("Sell failed. reqLot=%.4f normLot=%.4f retcode=%d (%s)",
                  lot, vol, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return false;
   }

   double entry_price = trade.ResultPrice();
   if(entry_price <= 0.0)
      entry_price = price;

   ulong ticket = 0;
   if(hedging)
   {
      ulong deal = trade.ResultDeal();
      if(deal > 0 && HistoryDealSelect(deal))
         ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   }

   double tranche_target = CalculateTargetPriceSell(entry_price);

   if(SetTargetWithEntry)
   {
      bool can_verify_position = false;
      bool modified = true;
      if(hedging && ticket > 0 && PositionSelectByTicket(ticket))
      {
         can_verify_position = true;
         double current_tp = PositionGetDouble(POSITION_TP);
         if(current_tp <= 0.0 || MathAbs(current_tp - tranche_target) > (g_point * 0.5))
            modified = trade.PositionModify(ticket, 0.0, tranche_target);
      }
      else if(!hedging && PositionSelect(_Symbol))
      {
         can_verify_position = true;
         double current_tp = PositionGetDouble(POSITION_TP);
         if((ulong)PositionGetInteger(POSITION_MAGIC) == SellMagicNumber &&
            (int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         {
            if(current_tp <= 0.0 || MathAbs(current_tp - tranche_target) > (g_point * 0.5))
               modified = trade.PositionModify(_Symbol, 0.0, tranche_target);
         }
      }

      if(can_verify_position && !modified)
      {
         PrintFormat("Sell post-entry TP attach failed. target=%.5f retcode=%d (%s)",
                     tranche_target, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }

   AddTrancheSell(entry_price, vol, ticket, tranche_target);
   return true;
}

//+------------------------------------------------------------------+
//| Trading flow per side                                            |
//+------------------------------------------------------------------+
void ProcessBuy(const bool hedging, const double bid, const double ask, const double score)
{
   if(!BuyEntry)
      return;

   if(UseSuperTrend && !IsSuperTrendBullishH1(1))
      return;
   if(UseMACross && !IsMACrossBullish())
      return;

   int openCount = OpenTrancheCountBuy();
   int scoreTrigger = EntryScoreThresholdBuy;
   if(EntryScoreThresholdBuy < 0)
      scoreTrigger = 50 + (EntryScoreThresholdBuy * 10);

   bool scoreOk = (score <= scoreTrigger);

   if(openCount == 0)
   {
      if(!scoreOk)
         return;

      if(!IsLastCandleBreakConditionMet(bid, chk_last_candle_breaks_buy, chk_last_candle_type_buy, true))
         return;

      if(buy_last_entry_price_ref > 0.0)
      {
         if(MathAbs(bid - buy_last_entry_price_ref) < CalculateStepDistance(buy_last_entry_price_ref))
            return;
      }

      TryOpenEntryBuy(ask, BuyLotSize, hedging);
      return;
   }

   if(BuyMaxEntries > 0 && openCount >= BuyMaxEntries)
      return;

   if(!scoreOk)
      return;

   if(!IsLastCandleBreakConditionMet(bid, chk_last_candle_breaks_buy, chk_last_candle_type_buy, true))
      return;

   if(buy_last_entry_price_open > 0.0 && bid <= (buy_last_entry_price_open - CalculateStepDistance(buy_last_entry_price_open)))
   {
      double nextLot = buy_last_entry_lot;
      if(nextLot <= 0.0)
         nextLot = BuyLotSize;
      nextLot += BuyLotStep;
      TryOpenEntryBuy(ask, nextLot, hedging);
   }
}

void ProcessSell(const bool hedging, const double bid, const double ask, const double score)
{
   if(!SellEntry)
      return;

   if(UseSuperTrend && !IsSuperTrendBearishH1(1))
      return;
   if(UseMACross && !IsMACrossBearish())
      return;

   int openCount = OpenTrancheCountSell();
   int scoreTrigger = EntryScoreThresholdSell;
   if(EntryScoreThresholdSell < 0)
      scoreTrigger = 50 + (EntryScoreThresholdSell * 10);

   bool scoreOk = (score >= scoreTrigger);

   if(openCount == 0)
   {
      if(!scoreOk)
         return;

      if(!IsLastCandleBreakConditionMet(ask, chk_last_candle_breaks_sell, chk_last_candle_type_sell, false))
         return;

      if(sell_last_entry_price_ref > 0.0)
      {
         if(MathAbs(ask - sell_last_entry_price_ref) < CalculateStepDistance(sell_last_entry_price_ref))
            return;
      }

      TryOpenEntrySell(bid, SellLotSize, hedging);
      return;
   }

   if(SellMaxEntries > 0 && openCount >= SellMaxEntries)
      return;

   if(!scoreOk)
      return;

   if(!IsLastCandleBreakConditionMet(ask, chk_last_candle_breaks_sell, chk_last_candle_type_sell, false))
      return;

   if(sell_last_entry_price_open > 0.0 && ask >= (sell_last_entry_price_open + CalculateStepDistance(sell_last_entry_price_open)))
   {
      double nextLot = sell_last_entry_lot;
      if(nextLot <= 0.0)
         nextLot = SellLotSize;
      nextLot += SellLotStep;
      TryOpenEntrySell(bid, nextLot, hedging);
   }
}

int CloseAllManagedPositions(const ulong magic, const int position_type, const string reason)
{
   int closed_count = 0;
   int ptotal = PositionsTotal();

   for(int i = ptotal - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!IsManagedPosition(magic, position_type))
         continue;

      trade.SetExpertMagicNumber(magic);
      trade.SetDeviationInPoints(Deviation);

      if(trade.PositionClose(ticket))
         closed_count++;
      else
      {
         PrintFormat("%s close failed. ticket=%I64u magic=%I64u retcode=%d (%s)",
                     reason, ticket, magic, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }

   if(closed_count > 0)
      PrintFormat("%s close count=%d magic=%I64u", reason, closed_count, magic);

   return closed_count;
}

void ApplySupertrendBasedSL(const bool hedging)
{
   if(!UseSuperTrend || !SupetrendBasedSL || supertrendH1Handle == INVALID_HANDLE)
      return;

   int current_direction = GetSuperTrendDirection(1);
   if(current_direction == 0)
      return;

   if(supertrend_last_direction == 0)
   {
      supertrend_last_direction = current_direction;
      return;
   }

   if(current_direction == supertrend_last_direction)
      return;

   if(current_direction > 0)
   {
      if(CloseAllManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, "SuperTrend flipped bullish: closing sells") > 0)
         SyncTranchesSell(hedging);
   }
   else
   {
      if(CloseAllManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, "SuperTrend flipped bearish: closing buys") > 0)
         SyncTranchesBuy(hedging);
   }

   supertrend_last_direction = current_direction;
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(BuyMagicNumber);
   trade.SetDeviationInPoints(Deviation);

   g_vol_min = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_vol_max = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_vol_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip = CalculatePipSize();

   if(g_vol_min <= 0.0 || g_vol_max <= 0.0 || g_point <= 0.0 || g_digits <= 0 || g_pip <= 0.0)
   {
      Print("Failed to read symbol properties.");
      return(INIT_FAILED);
   }

   sumitScoreHandle = iCustom(
      _Symbol,
      PERIOD_CURRENT,
      "Sumit_RSI_Score_Indicator",
      Rsi1hPeriod,
      SumitMaBuyThreshold,
      SumitMaSellThreshold,
      Rsi1hBuyThreshold,
      Rsi1hSellThreshold,
      SumitSma3Period,
      SumitSma201Period,
      SumitRsiPeriod
   );

   if(sumitScoreHandle == INVALID_HANDLE)
   {
      PrintFormat("Failed to create Sumit score indicator handle. err=%d", GetLastError());
      return(INIT_FAILED);
   }

   if(UseSuperTrend)
   {
      supertrendH1Handle = iCustom(
         _Symbol,
         Supertrend_Timeframe,
         "supertrend",
         SupertrendAtrPeriod,
         SupertrendMultiplier,
         SupertrendSourcePrice,
         SupertrendTakeWicksIntoAccount
      );

      if(supertrendH1Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create SuperTrend handle (%s). err=%d",
                     EnumToString(Supertrend_Timeframe),
                     GetLastError());
         return(INIT_FAILED);
      }

      supertrend_last_direction = GetSuperTrendDirection(1);
   }

   if(UseMACross)
   {
      if(MA1Period <= 0 || MA2Period <= 0)
      {
         PrintFormat("Invalid MA periods. MA1=%d MA2=%d", MA1Period, MA2Period);
         return(INIT_FAILED);
      }

      ma1Handle = iMA(_Symbol, MATimeframe, MA1Period, 0, MA1Method, MA1Price);
      if(ma1Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create MA-1 handle. period=%d timeframe=%s err=%d",
                     MA1Period, EnumToString(MATimeframe), GetLastError());
         return(INIT_FAILED);
      }

      ma2Handle = iMA(_Symbol, MATimeframe, MA2Period, 0, MA2Method, MA2Price);
      if(ma2Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create MA-2 handle. period=%d timeframe=%s err=%d",
                     MA2Period, EnumToString(MATimeframe), GetLastError());
         return(INIT_FAILED);
      }

      if(MA1Period == MA2Period)
         Print("Warning: MA1Period equals MA2Period; MA cross filtering will have weak differentiation.");

      if(MACrossMode == MACROSS_PREDICTIVE && MAPredictiveUseATR)
      {
         if(MAPredictiveATRPeriod <= 0)
         {
            PrintFormat("Invalid MAPredictiveATRPeriod=%d", MAPredictiveATRPeriod);
            return(INIT_FAILED);
         }

         maPredictiveAtrHandle = iATR(_Symbol, MATimeframe, MAPredictiveATRPeriod);
         if(maPredictiveAtrHandle == INVALID_HANDLE)
         {
            PrintFormat("Failed to create predictive ATR handle. period=%d timeframe=%s err=%d",
                        MAPredictiveATRPeriod, EnumToString(MATimeframe), GetLastError());
            return(INIT_FAILED);
         }
      }
   }

   PrintFormat("Volume constraints for %s: min=%.4f step=%.4f max=%.4f",
               _Symbol, g_vol_min, g_vol_step, g_vol_max);
   PrintFormat("Price format: digits=%d point=%.10f pip=%.10f", g_digits, g_point, g_pip);
   PrintFormat("Mode: SetTargetWithEntry=%s TrailingTargetPercent=%.4f RecoverExistingMagicPositions=%s",
               SetTargetWithEntry ? "true" : "false",
               TrailingTargetPips,
               RecoverExistingMagicPositions ? "true" : "false");
   PrintFormat("Side config: BuyEntry=%s SellEntry=%s BuyMagic=%I64u SellMagic=%I64u",
               BuyEntry ? "true" : "false",
               SellEntry ? "true" : "false",
               BuyMagicNumber,
               SellMagicNumber);

   if(RecoverExistingMagicPositions)
   {
      bool hedging = IsHedging();
      EnsureServerTargetsForOpenPositionsBuy(hedging);
      EnsureServerTargetsForOpenPositionsSell(hedging);
      RebuildTranchesFromPositionsBuy(hedging);
      RebuildTranchesFromPositionsSell(hedging);
   }

   PrintFormat("Filters: SuperTrend=%s(%s) MAcross=%s(mode=%s tf=%s MA1=%d MA2=%d).",
               UseSuperTrend ? "on" : "off",
               EnumToString(Supertrend_Timeframe),
               UseMACross ? "on" : "off",
               EnumToString(MACrossMode),
               EnumToString(MATimeframe),
               MA1Period,
               MA2Period);
   if(UseMACross && MACrossMode == MACROSS_PREDICTIVE)
   {
      PrintFormat("Predictive MA gap mode: ATR=%s period=%d mult=%.4f fallbackPoints=%.2f",
                  MAPredictiveUseATR ? "on" : "off",
                  MAPredictiveATRPeriod,
                  MAPredictiveATRMultiplier,
                  MAPredictiveGapPoints);
   }

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(sumitScoreHandle != INVALID_HANDLE)
      IndicatorRelease(sumitScoreHandle);
   if(supertrendH1Handle != INVALID_HANDLE)
      IndicatorRelease(supertrendH1Handle);
   if(ma1Handle != INVALID_HANDLE)
      IndicatorRelease(ma1Handle);
   if(ma2Handle != INVALID_HANDLE)
      IndicatorRelease(ma2Handle);
   if(maPredictiveAtrHandle != INVALID_HANDLE)
      IndicatorRelease(maPredictiveAtrHandle);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   bool hedging = IsHedging();

   SyncTranchesBuy(hedging);
   SyncTranchesSell(hedging);
   RebuildTranchesFromPositionsBuy(hedging);
   RebuildTranchesFromPositionsSell(hedging);
   EnsureServerTargetsForOpenPositionsBuy(hedging);
   EnsureServerTargetsForOpenPositionsSell(hedging);
   ApplySupertrendBasedSL(hedging);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Pure MA-cross mode: positions are managed by opposite MA cross / SuperTrend protection.

   bool gate_on_new_bar = UseNewBar;
   if(UseMACross && (MACrossMode == MACROSS_INTRABAR || MACrossMode == MACROSS_PREDICTIVE))
      gate_on_new_bar = false;

   if(gate_on_new_bar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bar_time == 0 || bar_time == last_bar_time)
         return;
      last_bar_time = bar_time;
   }

   int cross_event = GetMACrossEventDirection();
   if(cross_event == 0)
      return;

   if(cross_event > 0)
   {
      if(CloseAllManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, "MA upside cross: closing sells") > 0)
         SyncTranchesSell(hedging);

      if(BuyEntry && (!UseSuperTrend || IsSuperTrendBullishH1(1)) && OpenTrancheCountBuy() == 0)
         TryOpenEntryBuy(ask, BuyLotSize, hedging);
      return;
   }

   if(CloseAllManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, "MA downside cross: closing buys") > 0)
      SyncTranchesBuy(hedging);

   if(SellEntry && (!UseSuperTrend || IsSuperTrendBearishH1(1)) && OpenTrancheCountSell() == 0)
      TryOpenEntrySell(bid, SellLotSize, hedging);
}
