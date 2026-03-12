//+---------------------ssBuySell_onScore+Score2+SuperTrend+TraillingScore.mq5------------------------------------+
//|
//   Combined Buy + Sell strategy with score + RSI-direction entry/exit                            |
//| Uses external indicators: Sumit_RSI_Score_Indicator + optional SuperTrend filter              |
// -------15 min ---                                  -------------
//     current   -------                        ------
//                  -----------        ----------------  
//                     10-10  ----BUY---   if (Supertrend == bullish)
// Exit : when score = 50 || when target == Reached || when supertrend flipped 
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

input group "Indicator - Sumit RSI Score"
int Rsi1hPeriod = 51;
 int Sumit_MaBuy = 30;
 int Sumit_MaSell = 70;
 int Rsi1hBuy = 40;
 int Rsi1hSell = 60;
 int SumitSma3Period = 3;
 int SumitSma201Period = 201;
 int SumitRsiPeriod = 7;
input ENUM_TIMEFRAMES SumitScore_1Period = PERIOD_M15;
input ENUM_TIMEFRAMES SumitScore_2Period = PERIOD_M15;

input group "Entry - Conditions"
input bool BuyEntry = true;
input bool SellEntry = true;
input int BUYEntryScore = 30;
input int BUYEntryScore2 = 30;
input int SELLEntryScore = 70;
input int SELLEntryScore2 = 70;

input bool STBasedEntry = false;
input double LotSize = 0.01;
input double LotStep = 0.01;
input double UpDownStep = 0.025;
input bool UseNewBar = false;

input group "Exit-Conditions (0 = disabled)"
input int BUYExitScore = 50;
input int BUYExitScore2 = 0;
input int SELLExitScore = 50;
input int SELLExitScore2 = 0;
input bool EntryScoreSLTrail = true;    // trail score exits in 10-point steps
input double TargetPercent = 0.075;
input bool STBasedExit = true;
input bool SetTargetWithEntry = true;   // broker-side TP set with entry
input double TrailingTargetPercent = 0.0; // 0 disables trailing mode

input group "Indicator - Supertrend"
input bool UseSuperTrend = true;
 int SupertrendAtrPeriod = 7;
 double SupertrendMultiplier = 2.1;
input ENUM_TIMEFRAMES Supertrend_Timeframe = PERIOD_M15;
 ENUM_APPLIED_PRICE SupertrendSourcePrice = PRICE_MEDIAN; // PRICE_CLOSE, PRICE_OPEN, PRICE_HIGH, PRICE_LOW, PRICE_MEDIAN, PRICE_TYPICAL, PRICE_WEIGHTED
 bool SupertrendTakeWicksIntoAccount = false; // true=use wick highs/lows, false=use candle body values

input group "Risk / Execution"
input ulong BuyMagicNumber = 1051;
input ulong SellMagicNumber = 2051;
input int Deviation = 30;
input bool RecoverExistingMagicPositions = true;

input group "Legacy Entry Filters (currently unused)"
input string chk_last_candle_breaks_buy = "0";
input string chk_last_candle_type_buy = "0";
input string chk_last_candle_breaks_sell = "0";
input string chk_last_candle_type_sell = "0";

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

double sell_last_entry_price_open = 0.0;
double sell_last_entry_lot = 0.0;

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

int NormalizeScoreLevel(const int level);

//+------------------------------------------------------------------+
//| Utility                                                          |
//+------------------------------------------------------------------+
bool IsHedging()
{
   return(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool IsTargetExitEnabled()
{
   return (TargetPercent > 0.0);
}

bool IsBuyEntryScoreConditionMet(const double score1, const double score2)
{
   int score1_trigger = NormalizeScoreLevel(BUYEntryScore);
   int score2_trigger = NormalizeScoreLevel(BUYEntryScore2);
   return (score1 <= score1_trigger && score2 <= score2_trigger);
}

bool IsSellEntryScoreConditionMet(const double score1, const double score2)
{
   int score1_trigger = NormalizeScoreLevel(SELLEntryScore);
   int score2_trigger = NormalizeScoreLevel(SELLEntryScore2);
   return (score1 >= score1_trigger && score2 >= score2_trigger);
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
   if(!SetTargetWithEntry || !RecoverExistingMagicPositions || !IsTargetExitEnabled())
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
   return true;
}

void CheckTargetsBuy(const bool hedging, const double current_price)
{
   if(!IsTargetExitEnabled())
      return;

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
   if(SetTargetWithEntry && IsTargetExitEnabled())
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

   double tranche_target = IsTargetExitEnabled() ? CalculateTargetPriceBuy(entry_price) : 0.0;

   if(SetTargetWithEntry && tranche_target > 0.0)
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
   if(!SetTargetWithEntry || !RecoverExistingMagicPositions || !IsTargetExitEnabled())
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
   return true;
}

void CheckTargetsSell(const bool hedging, const double current_price)
{
   if(!IsTargetExitEnabled())
      return;

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
   if(SetTargetWithEntry && IsTargetExitEnabled())
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

   double tranche_target = IsTargetExitEnabled() ? CalculateTargetPriceSell(entry_price) : 0.0;

   if(SetTargetWithEntry && tranche_target > 0.0)
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
void ProcessBuyScaleIns(const bool hedging, const double bid, const double ask, const double score1, const double score2, const int st_direction)
{
   // if STBasedEntry is enabled we require a bullish SuperTrend direction
   if(!BuyEntry || (STBasedEntry && st_direction <= 0))
      return;

   if(OpenTrancheCountBuy() <= 0)
      return;
   if(OpenTrancheCountSell() > 0)
      return;
   if(!IsBuyEntryScoreConditionMet(score1, score2))
      return;

   if(buy_last_entry_price_open > 0.0)
   {
      double step_distance = CalculateStepDistance(buy_last_entry_price_open);
      if(step_distance <= 0.0)
         return;
      if(bid > (buy_last_entry_price_open - step_distance))
         return;

      double next_lot = buy_last_entry_lot;
      if(next_lot <= 0.0)
         next_lot = LotSize;
      next_lot += LotStep;
      TryOpenEntryBuy(ask, next_lot, hedging);
   }
}

void ProcessSellScaleIns(const bool hedging, const double bid, const double ask, const double score1, const double score2, const int st_direction)
{
   // if STBasedEntry is enabled we require a bearish SuperTrend direction
   if(!SellEntry || (STBasedEntry && st_direction >= 0))
      return;

   if(OpenTrancheCountSell() <= 0)
      return;
   if(OpenTrancheCountBuy() > 0)
      return;
   if(!IsSellEntryScoreConditionMet(score1, score2))
      return;

   if(sell_last_entry_price_open > 0.0)
   {
      double step_distance = CalculateStepDistance(sell_last_entry_price_open);
      if(step_distance <= 0.0)
         return;
      if(ask < (sell_last_entry_price_open + step_distance))
         return;

      double next_lot = sell_last_entry_lot;
      if(next_lot <= 0.0)
         next_lot = LotSize;
      next_lot += LotStep;
      TryOpenEntrySell(bid, next_lot, hedging);
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

void ApplyScoreAndIndicatorExits(const bool hedging, const double score, const double score2)
{
   int buy_target = NormalizeScoreLevel(BUYExitScore);
   int buy_target2 = NormalizeScoreLevel(BUYExitScore2);
   int sell_target = NormalizeScoreLevel(SELLExitScore);
   int sell_target2 = NormalizeScoreLevel(SELLExitScore2);

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
   bool close_sells_by_score = (SELLExitScore > 0 && open_sell_count > 0 && EvaluateSellScoreExit(score, sell_target, g_sell_score_trail_stop, g_sell_score_trail_next, "Sell score1", sell_score_reason));
   bool close_sells_by_score2 = (SELLExitScore2 > 0 && open_sell_count > 0 && EvaluateSellScoreExit(score2, sell_target2, g_sell_score2_trail_stop, g_sell_score2_trail_next, "Sell score2", sell_score2_reason));

   if(close_buys_by_score || close_buys_by_score2)
   {
      string reason = StringFormat(
         "Buy exit: score1Hit=%s(%s) score2Hit=%s(%s) (score1=%.2f score2=%.2f)",
         close_buys_by_score ? "Y" : "N",
         buy_score_reason,
         close_buys_by_score2 ? "Y" : "N",
         buy_score2_reason,
         score,
         score2
      );

      if(CloseAllManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, reason) > 0)
      {
         SyncTranchesBuy(hedging);
         ResetBuyScoreTrailState();
         ResetBuyScore2TrailState();
      }
   }

   if(close_sells_by_score || close_sells_by_score2)
   {
      string reason = StringFormat(
         "Sell exit: score1Hit=%s(%s) score2Hit=%s(%s) (score1=%.2f score2=%.2f)",
         close_sells_by_score ? "Y" : "N",
         sell_score_reason,
         close_sells_by_score2 ? "Y" : "N",
         sell_score2_reason,
         score,
         score2
      );

      if(CloseAllManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, reason) > 0)
      {
         SyncTranchesSell(hedging);
         ResetSellScoreTrailState();
         ResetSellScore2TrailState();
      }
   }
}

void HandleSupertrendFlipEntryExit(const bool hedging,
                                   const int current_direction,
                                   const double bid,
                                   const double ask,
                                   const bool has_scores,
                                   const double score1,
                                   const double score2)
{
   if(!UseSuperTrend || supertrendH1Handle == INVALID_HANDLE)
      return;

   if(current_direction == 0)
      return;

   if(supertrend_last_direction == 0)
   {
      // first direction read – just store and exit
      supertrend_last_direction = current_direction;
      return;
   }

   if(current_direction == supertrend_last_direction)
      return; // no flip occurred

   // flip detected; handle exit and entry separately according to flags
   if(STBasedExit)
   {
      if(current_direction > 0)
      {
         if(CloseAllManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, "SuperTrend flipped bullish: closing sells") > 0)
         {
            SyncTranchesSell(hedging);
            ResetSellScoreTrailState();
            ResetSellScore2TrailState();
         }
      }
      else
      {
         if(CloseAllManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, "SuperTrend flipped bearish: closing buys") > 0)
         {
            SyncTranchesBuy(hedging);
            ResetBuyScoreTrailState();
            ResetBuyScore2TrailState();
         }
      }
   }

   if(STBasedEntry)
   {
      if(current_direction > 0)
      {
         if(BuyEntry &&
            OpenTrancheCountSell() == 0 &&
            OpenTrancheCountBuy() == 0 &&
            has_scores &&
            IsBuyEntryScoreConditionMet(score1, score2))
         {
            TryOpenEntryBuy(ask, LotSize, hedging);
         }
      }
      else
      {
         if(SellEntry &&
            OpenTrancheCountBuy() == 0 &&
            OpenTrancheCountSell() == 0 &&
            has_scores &&
            IsSellEntryScoreConditionMet(score1, score2))
         {
            TryOpenEntrySell(bid, LotSize, hedging);
         }
      }
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
      SumitScore_1Period,
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
   PrintFormat("Mode: STBasedEntry=%s STBasedExit=%s SetTargetWithEntry=%s TargetPercent=%.4f TargetEnabled=%s UpDownStep=%.4f TrailingTargetPercent=%.4f EntryScoreSLTrail=%s RecoverExistingMagicPositions=%s",
               STBasedEntry ? "true" : "false",
               STBasedExit ? "true" : "false",
               SetTargetWithEntry ? "true" : "false",
               TargetPercent,
               IsTargetExitEnabled() ? "true" : "false",
               UpDownStep,
               TrailingTargetPercent,
               EntryScoreSLTrail ? "true" : "false",
               RecoverExistingMagicPositions ? "true" : "false");
   PrintFormat("Score timeframes: score1=%s score2=%s", EnumToString(SumitScore_1Period), EnumToString(SumitScore_2Period));
   PrintFormat("SuperTrend timeframe: %s", EnumToString(Supertrend_Timeframe));
   PrintFormat("BUY thresholds: entry(score1<=%d,score2<=%d) exit(score1>=%d,score2>=%d)",
               BUYEntryScore, BUYEntryScore2, BUYExitScore, BUYExitScore2);
   PrintFormat("SELL thresholds: entry(score1>=%d,score2>=%d) exit(score1<=%d,score2<=%d)",
               SELLEntryScore, SELLEntryScore2, SELLExitScore, SELLExitScore2);
   PrintFormat("Entry lot config: base=%.4f step=%.4f", LotSize, LotStep);
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

   PrintFormat("Strategy: entry on %s, scale-ins by distance in same ST direction, exits by target/score%s.",
               STBasedEntry ? "ST flip + score1&score2" : "score1&score2",
               STBasedExit ? " and opposite ST flip" : "");

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

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(!SetTargetWithEntry)
   {
      CheckTargetsBuy(hedging, bid);
      CheckTargetsSell(hedging, ask);
   }

   if(UseNewBar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bar_time == 0 || bar_time == last_bar_time)
         return;
      last_bar_time = bar_time;
   }

   int score_shift = UseNewBar ? 1 : 0;
   double score1 = EMPTY_VALUE;
   double score2 = EMPTY_VALUE;
   bool has_score1 = GetScoreValue(score_shift, score1);
   bool has_score2 = GetScore2Value(score_shift, score2);
   bool has_scores = (has_score1 && has_score2);

   if(has_scores)
      ApplyScoreAndIndicatorExits(hedging, score1, score2);

   if(!UseSuperTrend || supertrendH1Handle == INVALID_HANDLE)
      return;

   int st_direction = GetSuperTrendDirection(1);
   if(st_direction == 0)
      return;

   // only perform flips if either entry or exit uses ST
   if(STBasedEntry || STBasedExit)
      HandleSupertrendFlipEntryExit(hedging, st_direction, bid, ask, has_scores, score1, score2);

   if(!has_scores)
      return;

   ProcessBuyScaleIns(hedging, bid, ask, score1, score2, st_direction);
   ProcessSellScaleIns(hedging, bid, ask, score1, score2, st_direction);
}
