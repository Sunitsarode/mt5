//+---------------------ssBuySell_onScore+Score2+SuperTrend+TraillingScore.mq5------------------------------------+
//|
//   Combined Buy + Sell strategy with score + Sumit/Signal threshold entry/exit                  |
//| Uses external indicators: Sumit_RSI_Score_Indicator + optional SuperTrend filter              |
//
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// Inputs for Sumit_RSI_Score_Indicator
 int Rsi1hPeriod = 31;
 int Sumit_MaBuy = 30;
 int Sumit_MaSell = 70;
 int Rsi1hBuy = 35;
 int Rsi1hSell = 65;
 int SumitSma3Period = 3;
 int SumitSma201Period = 201;
 int SumitRsiPeriod = 7;
input ENUM_TIMEFRAMES SumitScore_2Period = PERIOD_M15;

// BUYEntrySumitRSI = -1=use BUYEntryScore, 0=disabled, 1..100=manual, BUY entry when SumitRSI <= level
//BuyRSIDirectionMode RSI direction modes: 0=disabled, 1=RisingOrSideways, 2=FallingOrSideways, 3=RisingOnly, 4=FallingOnly, 5=SidewaysOnly
//SupetrendBasedSL = false; // Close opposite-direction trades when SuperTrend flips
//chk_last_candle_breaks_buy = "0"; // 0=disabled, H/L/O/C = prev candle High/Low/Open/close
// chk_last_candle_type_buy = "0";  //  G=green candle, R=red candle  0=disabled
//SupetrendBasedSL = false; // Close opposite-direction trades when SuperTrend flips



input bool BuyEntry = true;
input int BUYEntryScore = 20; 
input int BUYExitScore = 60;   
input int BUYEntryScore2 = 20;
input int BUYExitScore2 = 60;
input int BUYEntrySumitRSI = 0;    
input int BUYExitSumitRSI = 0;     
input int BUYEntrySignalMA3 = 0;   
input int BUYExitSignalMA3 = 0; 
input int BuyRSIDirectionMode = 1;  
input string chk_last_candle_breaks_buy = "0"; 
input string chk_last_candle_type_buy = "0";  
input double BuyLotSize = 0.01;
input double BuyLotStep = 0.01;
input int BuyMaxEntries = 0;  

input bool SellEntry = true;
input int SELLEntryScore = 80;  
input int SELLExitScore = 40;  
input int SELLEntryScore2 = 80;
input int SELLExitScore2 = 40;
input int SELLEntrySumitRSI =0;   
input int SELLExitSumitRSI = 0;    
input int SELLEntrySignalMA3 = 0;  
input int SELLExitSignalMA3 = 0;   
input int SellRSIDirectionMode = 2;
input string chk_last_candle_breaks_sell = "0"; 
input string chk_last_candle_type_sell = "0";   
input double SellLotSize = 0.01;
input double SellLotStep = 0.01;
input int SellMaxEntries = 0;



input int RSIDirectionLookbackBars = 3;
input double RSISidewaysDelta = 1.0; 


input bool UseSuperTrend = true;
input int SupertrendAtrPeriod = 51;
input double SupertrendMultiplier = 1.5;
input ENUM_TIMEFRAMES Supertrend_Timeframe = PERIOD_H1; 
ENUM_APPLIED_PRICE SupertrendSourcePrice = PRICE_MEDIAN; // PRICE_CLOSE, PRICE_OPEN, PRICE_HIGH, PRICE_LOW, PRICE_MEDIAN, PRICE_TYPICAL, PRICE_WEIGHTED
bool SupertrendTakeWicksIntoAccount = false; // true=use wick highs/lows, false=use candle body values
input bool SupetrendBasedSL = false; 

// Trading logic (common)
input double TargetPercent = 0.175;      
input double UpDownStep = 0.025;         
input bool SetTargetWithEntry = false;  // brokerside SetTargetWithEntry
input double TrailingTargetPercent = 0.02; //TrailingTargetPercent (0 disables)
input bool EntryScoreSLTrail = true;    // trail score exits in 10-point steps

bool RecoverExistingMagicPositions = true; 


input ulong BuyMagicNumber = 1051;
input ulong SellMagicNumber = 2051;
int Deviation = 30;
input bool UseNewBar = false;

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
int sumitScore2Handle = INVALID_HANDLE;
int supertrendH1Handle = INVALID_HANDLE;
int supertrend_last_direction = 0; // +1 bullish, -1 bearish, 0 unknown

// Cached symbol properties (faster than repeated SymbolInfoDouble calls)
double g_vol_min = 0.0;
double g_vol_max = 0.0;
double g_vol_step = 0.0;
double g_point = 0.0;
double g_pip = 0.0;
int g_digits = 0;
double g_target_percent_to_pips_factor = 0.0;
double g_step_percent_to_pips_factor = 0.0;
double g_trailing_percent_to_pips_factor = 0.0;
int g_buy_score_trail_stop = 0;
int g_buy_score_trail_next = 0;
int g_sell_score_trail_stop = 0;
int g_sell_score_trail_next = 0;
int g_buy_score2_trail_stop = 0;
int g_buy_score2_trail_next = 0;
int g_sell_score2_trail_stop = 0;
int g_sell_score2_trail_next = 0;

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

double CalculatePercentDistanceInPips(const double reference_price, const double percent_to_pips_factor)
{
   if(reference_price <= 0.0 || percent_to_pips_factor <= 0.0)
      return 0.0;

   return reference_price * percent_to_pips_factor;
}

double CalculateTargetDistance(const double entry_price)
{
   double pctDistPips = CalculatePercentDistanceInPips(entry_price, g_target_percent_to_pips_factor);
   return pctDistPips * g_pip;
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
   if(TrailingTargetPercent <= 0.0 || reference_price <= 0.0)
      return 0.0;
   double trailingDistPips = CalculatePercentDistanceInPips(reference_price, g_trailing_percent_to_pips_factor);
   return trailingDistPips * g_pip;
}

double CalculateStepDistance(const double reference_price)
{
   double stepDistPips = CalculatePercentDistanceInPips(reference_price, g_step_percent_to_pips_factor);
   return stepDistPips * g_pip;
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

bool GetScore2Value(const int shift, double &score)
{
   if(sumitScore2Handle == INVALID_HANDLE)
      return false;

   double score_value[1];
   int copied = CopyBuffer(sumitScore2Handle, 4, shift, 1, score_value);
   if(copied != 1)
      return false;

   if(score_value[0] == EMPTY_VALUE)
      return false;

   score = score_value[0];
   return true;
}

int NormalizeScoreLevel(const int level)
{
   if(level < 0)
      return 50 + (level * 10);
   return level;
}

int ResolveLinkedThresholdLevel(const int input_level, const int linked_score_level)
{
   if(input_level < 0)
      return MathMax(0, MathMin(100, linked_score_level));

   if(input_level > 0)
      return MathMin(100, input_level);

   return 0;
}

int NormalizeScoreTrailStartBuy(const int level)
{
   int clamped = MathMax(10, MathMin(90, level));
   return (clamped / 10) * 10;
}

int NormalizeScoreTrailStartSell(const int level)
{
   int clamped = MathMax(10, MathMin(90, level));
   int rem = clamped % 10;
   if(rem != 0)
      clamped += (10 - rem);
   if(clamped > 90)
      clamped = 90;
   return clamped;
}

void ResetBuyScoreTrailState()
{
   g_buy_score_trail_stop = 0;
   g_buy_score_trail_next = 0;
}

void ResetSellScoreTrailState()
{
   g_sell_score_trail_stop = 0;
   g_sell_score_trail_next = 0;
}

void ResetBuyScore2TrailState()
{
   g_buy_score2_trail_stop = 0;
   g_buy_score2_trail_next = 0;
}

void ResetSellScore2TrailState()
{
   g_sell_score2_trail_stop = 0;
   g_sell_score2_trail_next = 0;
}

bool EvaluateBuyScoreExit(const double score, const int raw_target, int &trail_stop, int &trail_next, const string label, string &reason)
{
   if(!EntryScoreSLTrail)
   {
      if(score >= raw_target)
      {
         reason = StringFormat("score %.2f >= target %d", score, raw_target);
         return true;
      }
      return false;
   }

   int trail_start = NormalizeScoreTrailStartBuy(raw_target);

   if(trail_start >= 90)
   {
      if(score >= trail_start)
      {
         reason = StringFormat("trail finished at %d (score %.2f)", trail_start, score);
         return true;
      }
      return false;
   }

   if(trail_stop <= 0)
   {
      if(score >= trail_start)
      {
         trail_stop = trail_start;
         trail_next = trail_start + 10;
         PrintFormat("%s trail started. stop=%d next=%d score=%.2f",
                     label, trail_stop, trail_next, score);
      }
      return false;
   }

   while(trail_next > 0 && trail_next <= 90 && score >= trail_next)
   {
      trail_stop = trail_next;
      trail_next = (trail_stop >= 90) ? 0 : (trail_stop + 10);
      PrintFormat("%s trail advanced. stop=%d next=%d score=%.2f",
                  label, trail_stop, trail_next, score);
   }

   if(trail_stop >= 90)
   {
      reason = StringFormat("trail finished at 90 (score %.2f)", score);
      return true;
   }

   if(score < trail_stop)
   {
      reason = StringFormat("trail stop hit (score %.2f < %d)", score, trail_stop);
      return true;
   }

   return false;
}

bool EvaluateSellScoreExit(const double score, const int raw_target, int &trail_stop, int &trail_next, const string label, string &reason)
{
   if(!EntryScoreSLTrail)
   {
      if(score <= raw_target)
      {
         reason = StringFormat("score %.2f <= target %d", score, raw_target);
         return true;
      }
      return false;
   }

   int trail_start = NormalizeScoreTrailStartSell(raw_target);

   if(trail_start <= 10)
   {
      if(score <= trail_start)
      {
         reason = StringFormat("trail finished at %d (score %.2f)", trail_start, score);
         return true;
      }
      return false;
   }

   if(trail_stop <= 0)
   {
      if(score <= trail_start)
      {
         trail_stop = trail_start;
         trail_next = trail_start - 10;
         PrintFormat("%s trail started. stop=%d next=%d score=%.2f",
                     label, trail_stop, trail_next, score);
      }
      return false;
   }

   while(trail_next >= 10 && score <= trail_next)
   {
      trail_stop = trail_next;
      trail_next = (trail_stop <= 10) ? 0 : (trail_stop - 10);
      PrintFormat("%s trail advanced. stop=%d next=%d score=%.2f",
                  label, trail_stop, trail_next, score);
   }

   if(trail_stop <= 10)
   {
      reason = StringFormat("trail finished at 10 (score %.2f)", score);
      return true;
   }

   if(score > trail_stop)
   {
      reason = StringFormat("trail stop hit (score %.2f > %d)", score, trail_stop);
      return true;
   }

   return false;
}

int GetRsiDirectionLookback()
{
   if(RSIDirectionLookbackBars < 1)
      return 1;
   return RSIDirectionLookbackBars;
}

double GetRsiSidewaysDelta()
{
   return MathMax(0.0, RSISidewaysDelta);
}

bool GetSumitIndicatorValue(const int buffer_index, const int shift, double &value);

bool GetSumitRsiDirectionDelta(const int shift, double &delta)
{
   double sumit_curr = 0.0;
   double sumit_prev = 0.0;
   int lookback = GetRsiDirectionLookback();

   if(!GetSumitIndicatorValue(0, shift, sumit_curr))
      return false;
   if(!GetSumitIndicatorValue(0, shift + lookback, sumit_prev))
      return false;

   delta = sumit_curr - sumit_prev;
   return true;
}

bool IsRsiDirectionAllowed(const int mode, const double delta)
{
   if(mode <= 0)
      return true;

   double sideways_delta = GetRsiSidewaysDelta();
   bool rising = (delta > sideways_delta);
   bool falling = (delta < -sideways_delta);
   bool sideways = (!rising && !falling);

   switch(mode)
   {
      case 1: return (rising || sideways); // RisingOrSideways
      case 2: return (falling || sideways); // FallingOrSideways
      case 3: return rising; // RisingOnly
      case 4: return falling; // FallingOnly
      case 5: return sideways; // SidewaysOnly
      default: return true;
   }
}

bool GetSumitIndicatorValue(const int buffer_index, const int shift, double &value)
{
   if(sumitScoreHandle == INVALID_HANDLE)
      return false;

   double indicator_value[1];
   int copied = CopyBuffer(sumitScoreHandle, buffer_index, shift, 1, indicator_value);
   if(copied != 1)
      return false;
   if(indicator_value[0] == EMPTY_VALUE)
      return false;

   value = indicator_value[0];
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

   bool use_trailing = (!SetTargetWithEntry && TrailingTargetPercent > 0.0);

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

   bool use_trailing = (!SetTargetWithEntry && TrailingTargetPercent > 0.0);

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
void ProcessBuy(const bool hedging, const double bid, const double ask, const double score, const double score2, const double sumit_rsi, const double signal_ma3, const bool has_rsi_direction, const double rsi_direction_delta)
{
   if(!BuyEntry)
      return;

   if(UseSuperTrend && !IsSuperTrendBullishH1(1))
      return;
   if(BuyRSIDirectionMode > 0)
   {
      if(!has_rsi_direction)
         return;
      if(!IsRsiDirectionAllowed(BuyRSIDirectionMode, rsi_direction_delta))
         return;
   }

   int openCount = OpenTrancheCountBuy();
   int scoreTrigger = NormalizeScoreLevel(BUYEntryScore);
   int scoreTrigger2 = NormalizeScoreLevel(BUYEntryScore2);
   int entrySumitLevel = ResolveLinkedThresholdLevel(BUYEntrySumitRSI, scoreTrigger);
   int entrySignalLevel = ResolveLinkedThresholdLevel(BUYEntrySignalMA3, scoreTrigger);
   bool scoreOk = (score <= scoreTrigger);
   bool score2Ok = (score2 <= scoreTrigger2);
   bool sumitOk = (entrySumitLevel == 0 || sumit_rsi <= entrySumitLevel);
   bool signalOk = (entrySignalLevel == 0 || signal_ma3 <= entrySignalLevel);
   bool entryOk = (scoreOk && score2Ok && sumitOk && signalOk);

   if(openCount == 0)
   {
      if(!entryOk)
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

   if(!entryOk)
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

void ProcessSell(const bool hedging, const double bid, const double ask, const double score, const double score2, const double sumit_rsi, const double signal_ma3, const bool has_rsi_direction, const double rsi_direction_delta)
{
   if(!SellEntry)
      return;

   if(UseSuperTrend && !IsSuperTrendBearishH1(1))
      return;
   if(SellRSIDirectionMode > 0)
   {
      if(!has_rsi_direction)
         return;
      if(!IsRsiDirectionAllowed(SellRSIDirectionMode, rsi_direction_delta))
         return;
   }

   int openCount = OpenTrancheCountSell();
   int scoreTrigger = NormalizeScoreLevel(SELLEntryScore);
   int scoreTrigger2 = NormalizeScoreLevel(SELLEntryScore2);
   int entrySumitLevel = ResolveLinkedThresholdLevel(SELLEntrySumitRSI, scoreTrigger);
   int entrySignalLevel = ResolveLinkedThresholdLevel(SELLEntrySignalMA3, scoreTrigger);
   bool scoreOk = (score >= scoreTrigger);
   bool score2Ok = (score2 >= scoreTrigger2);
   bool sumitOk = (entrySumitLevel == 0 || sumit_rsi >= entrySumitLevel);
   bool signalOk = (entrySignalLevel == 0 || signal_ma3 >= entrySignalLevel);
   bool entryOk = (scoreOk && score2Ok && sumitOk && signalOk);

   if(openCount == 0)
   {
      if(!entryOk)
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

   if(!entryOk)
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

void ApplyScoreAndIndicatorExits(const bool hedging, const double score, const double score2, const double sumit_rsi, const double signal_ma3)
{
   int buy_target = NormalizeScoreLevel(BUYExitScore);
   int buy_target2 = NormalizeScoreLevel(BUYExitScore2);
   int sell_target = NormalizeScoreLevel(SELLExitScore);
   int sell_target2 = NormalizeScoreLevel(SELLExitScore2);
   int buyExitSumitLevel = ResolveLinkedThresholdLevel(BUYExitSumitRSI, buy_target);
   int buyExitSignalLevel = ResolveLinkedThresholdLevel(BUYExitSignalMA3, buy_target);
   int sellExitSumitLevel = ResolveLinkedThresholdLevel(SELLExitSumitRSI, sell_target);
   int sellExitSignalLevel = ResolveLinkedThresholdLevel(SELLExitSignalMA3, sell_target);

   int open_buy_count = OpenTrancheCountBuy();
   int open_sell_count = OpenTrancheCountSell();
   if(open_buy_count <= 0)
   {
      ResetBuyScoreTrailState();
      ResetBuyScore2TrailState();
   }
   if(open_sell_count <= 0)
   {
      ResetSellScoreTrailState();
      ResetSellScore2TrailState();
   }

   string buy_score_reason = "";
   string buy_score2_reason = "";
   string sell_score_reason = "";
   string sell_score2_reason = "";
   bool close_buys_by_score = (BUYExitScore > 0 && open_buy_count > 0 && EvaluateBuyScoreExit(score, buy_target, g_buy_score_trail_stop, g_buy_score_trail_next, "Buy score1", buy_score_reason));
   bool close_buys_by_score2 = (BUYExitScore2 > 0 && open_buy_count > 0 && EvaluateBuyScoreExit(score2, buy_target2, g_buy_score2_trail_stop, g_buy_score2_trail_next, "Buy score2", buy_score2_reason));
   bool close_buys_by_sumit = (buyExitSumitLevel > 0 && sumit_rsi >= buyExitSumitLevel);
   bool close_buys_by_signal = (buyExitSignalLevel > 0 && signal_ma3 >= buyExitSignalLevel);
   bool close_sells_by_score = (SELLExitScore > 0 && open_sell_count > 0 && EvaluateSellScoreExit(score, sell_target, g_sell_score_trail_stop, g_sell_score_trail_next, "Sell score1", sell_score_reason));
   bool close_sells_by_score2 = (SELLExitScore2 > 0 && open_sell_count > 0 && EvaluateSellScoreExit(score2, sell_target2, g_sell_score2_trail_stop, g_sell_score2_trail_next, "Sell score2", sell_score2_reason));
   bool close_sells_by_sumit = (sellExitSumitLevel > 0 && sumit_rsi <= sellExitSumitLevel);
   bool close_sells_by_signal = (sellExitSignalLevel > 0 && signal_ma3 <= sellExitSignalLevel);

   if(close_buys_by_score || close_buys_by_score2 || close_buys_by_sumit || close_buys_by_signal)
   {
      string reason = StringFormat(
         "Buy exit: score1Hit=%s(%s) score2Hit=%s(%s) sumitHit=%s signalHit=%s (score1=%.2f score2=%.2f sumit=%.2f signal=%.2f)",
         close_buys_by_score ? "Y" : "N",
         buy_score_reason,
         close_buys_by_score2 ? "Y" : "N",
         buy_score2_reason,
         close_buys_by_sumit ? "Y" : "N",
         close_buys_by_signal ? "Y" : "N",
         score,
         score2,
         sumit_rsi,
         signal_ma3
      );

      if(CloseAllManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, reason) > 0)
      {
         SyncTranchesBuy(hedging);
         ResetBuyScoreTrailState();
         ResetBuyScore2TrailState();
      }
   }

   if(close_sells_by_score || close_sells_by_score2 || close_sells_by_sumit || close_sells_by_signal)
   {
      string reason = StringFormat(
         "Sell exit: score1Hit=%s(%s) score2Hit=%s(%s) sumitHit=%s signalHit=%s (score1=%.2f score2=%.2f sumit=%.2f signal=%.2f)",
         close_sells_by_score ? "Y" : "N",
         sell_score_reason,
         close_sells_by_score2 ? "Y" : "N",
         sell_score2_reason,
         close_sells_by_sumit ? "Y" : "N",
         close_sells_by_signal ? "Y" : "N",
         score,
         score2,
         sumit_rsi,
         signal_ma3
      );

      if(CloseAllManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, reason) > 0)
      {
         SyncTranchesSell(hedging);
         ResetSellScoreTrailState();
         ResetSellScore2TrailState();
      }
   }
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

   double target_percent_factor = MathMax(0.0, TargetPercent) / 100.0;
   double step_percent_factor = MathMax(0.0, UpDownStep) / 100.0;
   double trailing_percent_factor = MathMax(0.0, TrailingTargetPercent) / 100.0;
   double pip_inv = 1.0 / g_pip;

   g_target_percent_to_pips_factor = target_percent_factor * pip_inv;
   g_step_percent_to_pips_factor = step_percent_factor * pip_inv;
   g_trailing_percent_to_pips_factor = trailing_percent_factor * pip_inv;

   sumitScoreHandle = iCustom(
      _Symbol,
      PERIOD_CURRENT,
      "Sumit_RSI_Score_Indicator",
      Rsi1hPeriod,
      Sumit_MaBuy,
      Sumit_MaSell,
      Rsi1hBuy,
      Rsi1hSell,
      SumitSma3Period,
      SumitSma201Period,
      SumitRsiPeriod
   );

   if(sumitScoreHandle == INVALID_HANDLE)
   {
      PrintFormat("Failed to create Sumit score indicator handle. err=%d", GetLastError());
      return(INIT_FAILED);
   }

   sumitScore2Handle = iCustom(
      _Symbol,
      SumitScore_2Period,
      "Sumit_RSI_Score_Indicator",
      Rsi1hPeriod,
      Sumit_MaBuy,
      Sumit_MaSell,
      Rsi1hBuy,
      Rsi1hSell,
      SumitSma3Period,
      SumitSma201Period,
      SumitRsiPeriod
   );

   if(sumitScore2Handle == INVALID_HANDLE)
   {
      PrintFormat("Failed to create Sumit score2 indicator handle (%s). err=%d",
                  EnumToString(SumitScore_2Period),
                  GetLastError());
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

   PrintFormat("Volume constraints for %s: min=%.4f step=%.4f max=%.4f",
               _Symbol, g_vol_min, g_vol_step, g_vol_max);
   PrintFormat("Price format: digits=%d point=%.10f pip=%.10f", g_digits, g_point, g_pip);
   PrintFormat("Mode: SetTargetWithEntry=%s TargetPercent=%.4f UpDownStep=%.4f TrailingTargetPercent=%.4f EntryScoreSLTrail=%s RecoverExistingMagicPositions=%s",
               SetTargetWithEntry ? "true" : "false",
               TargetPercent,
               UpDownStep,
               TrailingTargetPercent,
               EntryScoreSLTrail ? "true" : "false",
               RecoverExistingMagicPositions ? "true" : "false");
   PrintFormat("Score2 timeframe: %s", EnumToString(SumitScore_2Period));
   PrintFormat("BUY thresholds (-1=>use score): entry(score1<=%d,score2<=%d,sumit<=%d,signal<=%d) exit(score1>=%d,score2>=%d,sumit>=%d,signal>=%d)",
               BUYEntryScore, BUYEntryScore2, BUYEntrySumitRSI, BUYEntrySignalMA3,
               BUYExitScore, BUYExitScore2, BUYExitSumitRSI, BUYExitSignalMA3);
   PrintFormat("SELL thresholds (-1=>use score): entry(score1>=%d,score2>=%d,sumit>=%d,signal>=%d) exit(score1<=%d,score2<=%d,sumit<=%d,signal<=%d)",
               SELLEntryScore, SELLEntryScore2, SELLEntrySumitRSI, SELLEntrySignalMA3,
               SELLExitScore, SELLExitScore2, SELLExitSumitRSI, SELLExitSignalMA3);
   PrintFormat("RSI direction: BuyMode=%d SellMode=%d Lookback=%d SidewaysDelta=%.2f",
               BuyRSIDirectionMode, SellRSIDirectionMode, GetRsiDirectionLookback(), GetRsiSidewaysDelta());
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

   PrintFormat("Strategy uses external score + optional SuperTrend filters for both sides (timeframe=%s).",
               EnumToString(Supertrend_Timeframe));

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(sumitScoreHandle != INVALID_HANDLE)
      IndicatorRelease(sumitScoreHandle);
   if(sumitScore2Handle != INVALID_HANDLE)
      IndicatorRelease(sumitScore2Handle);
   if(supertrendH1Handle != INVALID_HANDLE)
      IndicatorRelease(supertrendH1Handle);
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

   int score_shift = UseNewBar ? 1 : 0;
   double score = EMPTY_VALUE;
   double score2 = EMPTY_VALUE;
   double sumit_rsi = EMPTY_VALUE;
   double signal_ma3 = EMPTY_VALUE;
   double rsi_direction_delta = 0.0;
   bool has_score = GetScoreValue(score_shift, score);
   bool has_score2 = GetScore2Value(score_shift, score2);
   bool has_sumit = GetSumitIndicatorValue(0, score_shift, sumit_rsi);
   bool has_signal = GetSumitIndicatorValue(1, score_shift, signal_ma3);
   bool need_rsi_direction = (BuyRSIDirectionMode > 0 || SellRSIDirectionMode > 0);
   bool has_rsi_direction = true;
   if(need_rsi_direction)
      has_rsi_direction = GetSumitRsiDirectionDelta(score_shift, rsi_direction_delta);

   if(!SetTargetWithEntry)
   {
      CheckTargetsBuy(hedging, bid);
      CheckTargetsSell(hedging, ask);
   }

   if(has_score && has_score2 && has_sumit && has_signal)
      ApplyScoreAndIndicatorExits(hedging, score, score2, sumit_rsi, signal_ma3);

   if(UseNewBar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bar_time == 0 || bar_time == last_bar_time)
         return;
      last_bar_time = bar_time;
   }

   if(!has_score || !has_score2 || !has_sumit || !has_signal)
      return;

   ProcessBuy(hedging, bid, ask, score, score2, sumit_rsi, signal_ma3, has_rsi_direction, rsi_direction_delta);
   ProcessSell(hedging, bid, ask, score, score2, sumit_rsi, signal_ma3, has_rsi_direction, rsi_direction_delta);
}
