//+---------------------ssBuySell_Magic_HLentry_1-ST.mq5---------------------------------------------+
//|      
// Dual-side EA: buys/sells with optional Sumit score + 2x SuperTrend filters.
// Supports staged entries, per-side lot scaling, and TP/trailing management.
// On SuperTrend flip, optional protection sets opposite-side SL near entry (or closes on modify failure).

//
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// Inputs for Sumit_RSI_Score_Indicator
 int Rsi1hPeriod = 51;
 int SumitMaBuyThreshold = 30;
 int SumitMaSellThreshold = 70;
 int Rsi1hBuyThreshold = 40;
 int Rsi1hSellThreshold = 55;
 int SumitSma3Period = 3;
 int SumitSma201Period = 201;
 int SumitRsiPeriod = 7;

input int EntryScoreThresholdBuy = 90;   // Buy condition: score <= threshold
input int EntryScoreThresholdSell = 10;  // Sell condition: score >= threshold
input bool Use_Sumit_Score = true;
// Side enable + score threshold
input bool BuyEntry = true;
input bool SellEntry = true;


// SuperTrend filter (runtime-selectable timeframe)
input bool UseSuperTrend1 = true;
input int ST1AtrP = 51;
input double ST1Mult = 0.5;
input ENUM_TIMEFRAMES ST1Timeframe = PERIOD_CURRENT; // e.g. PERIOD_H1

input bool UseSuperTrend2 = true;
input int ST2AtrP = 51;
input double ST2Mult = 0.5;
input ENUM_TIMEFRAMES ST2Timeframe = PERIOD_M30;
input bool SupetrendBasedSL = true; // 1. Close opposite-direction trades when SuperTrend flips 2. Set target of opp-directioned trades to entry point (Zero Loss) 0r 0.001%
input int SelectSTbasedSL = 0; // 0=any (ST-1 or ST-2), 1=ST-1 only, 2=ST-2 only
input bool SupetrendBasedSLCloseNow = true; // true=immediate close on selected ST flip; if target=0 then apply break-even SL instead
input double SupetrendBasedSLTarget = 0.0; // 0=entry, -0.001 => buy SL=entry-0.001%, sell SL=entry+0.001%

input ENUM_APPLIED_PRICE SupertrendSourcePrice = PRICE_MEDIAN; // PRICE_CLOSE, PRICE_OPEN, PRICE_HIGH, PRICE_LOW, PRICE_MEDIAN, PRICE_TYPICAL, PRICE_WEIGHTED
input bool SupertrendTakeWicksIntoAccount = true; // true=use wick highs/lows, false=use candle body values

// Trading logic (common)
input double MinTargetPoints = 10.0;    // Minimum TP distance in points
input double TargetPercent = 0.021;      // TP distance in percent of entry price
input bool SetTargetWithEntry = false;  // Place broker TP in the entry request
input double TrailingTargetPips = 0.002; // Used only when SetTargetWithEntry=false, interpreted as percent (0 disables trailing)
input bool RecoverExistingMagicPositions = true; // Rebuild and manage existing magic positions on restart

// Buy-side settings
input string chk_last_candle_type_buy = "0";   // 0=disabled, G=green candle, R=red candle
input string chk_last_candle_breaks_buy = "0"; // 0=disabled, H/L/O/C = prev candle High/Low/Open/Close
input double BuyLotSize = 0.01;
input double BuyLotStep = 0.01;
input int BuyMaxEntries = 0; // 0 = unlimited

// Sell-side settings
input string chk_last_candle_type_sell = "0";   // 0=disabled, G=green candle, R=red candle
input string chk_last_candle_breaks_sell = "0"; // 0=disabled, H/L/O/C = prev candle High/Low/Open/Close
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
   long     time_open_msc;
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
int supertrend1Handle = INVALID_HANDLE;
int supertrend2Handle = INVALID_HANDLE;
int supertrend1_last_direction = 0; // +1 bullish, -1 bearish, 0 unknown
int supertrend2_last_direction = 0; // +1 bullish, -1 bearish, 0 unknown

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

bool IsIndicatorHandleReady(const int handle, const int required_bars)
{
   if(handle == INVALID_HANDLE)
      return false;

   int calculated = BarsCalculated(handle);
   if(calculated < 0)
      return false;

   return(calculated >= required_bars);
}

bool GetScoreValue(const int shift, double &score)
{
   if(sumitScoreHandle == INVALID_HANDLE)
      return false;
   if(!IsIndicatorHandleReady(sumitScoreHandle, shift + 2))
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

int GetSuperTrendDirectionFromHandle(const int handle, const int shift)
{
   if(handle == INVALID_HANDLE)
      return 0;
   if(!IsIndicatorHandleReady(handle, shift + 2))
      return 0;

   double direction_value[1];
   int copied = CopyBuffer(handle, 2, shift, 1, direction_value);
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

int GetCombinedSuperTrendDirection(const int shift)
{
   bool any_enabled = false;
   int st1_direction = 0;
   int st2_direction = 0;

   if(UseSuperTrend1)
   {
      any_enabled = true;
      st1_direction = GetSuperTrendDirectionFromHandle(supertrend1Handle, shift);
      if(st1_direction == 0)
         return 0;
   }

   if(UseSuperTrend2)
   {
      any_enabled = true;
      st2_direction = GetSuperTrendDirectionFromHandle(supertrend2Handle, shift);
      if(st2_direction == 0)
         return 0;
   }

   if(!any_enabled)
      return 0;

   if(UseSuperTrend1 && UseSuperTrend2 && st1_direction != st2_direction)
      return 0;

   return UseSuperTrend1 ? st1_direction : st2_direction;
}

bool IsSuperTrendBullish(const int shift)
{
   return (GetCombinedSuperTrendDirection(shift) > 0);
}

bool IsSuperTrendBearish(const int shift)
{
   return (GetCombinedSuperTrendDirection(shift) < 0);
}

bool IsLastCandleBreakConditionMet(const double price, const string break_input, const string type_input, const bool is_buy)
{
   string break_mode = break_input;
   StringTrimLeft(break_mode);
   StringTrimRight(break_mode);
   StringToUpper(break_mode);

   string type_mode = type_input;
   StringTrimLeft(type_mode);
   StringTrimRight(type_mode);
   StringToUpper(type_mode);

   bool use_break = (break_mode != "" && break_mode != "0");
   bool use_type = (type_mode != "" && type_mode != "0");
   if(!use_break && !use_type)
      return true;

   double prev_high = iHigh(_Symbol, PERIOD_CURRENT, 1);
   double prev_low = iLow(_Symbol, PERIOD_CURRENT, 1);
   double prev_open = iOpen(_Symbol, PERIOD_CURRENT, 1);
   double prev_close = iClose(_Symbol, PERIOD_CURRENT, 1);

   if(prev_high <= 0.0 || prev_low <= 0.0 || prev_open <= 0.0 || prev_close <= 0.0)
      return false;

   bool type_ok = true;
   if(use_type)
   {
      if(type_mode == "G" && prev_close <= prev_open)
         type_ok = false;
      else if(type_mode == "R" && prev_close >= prev_open)
         type_ok = false;
   }

   bool break_ok = true;
   if(use_break)
   {
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
         break_ok = true; // Invalid value behaves like disabled

      if(break_level > 0.0)
      {
         if(is_buy)
            break_ok = (price < break_level);
         else
            break_ok = (price > break_level);
      }
   }

   return (type_ok && break_ok);
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
   long last_time_msc = -1;
   ulong last_ticket = 0;
   int last_seq = -1;
   int total = ArraySize(buy_tranches);
   for(int i = 0; i < total; i++)
   {
      if(buy_tranches[i].closed)
         continue;

      bool newer = false;
      if(buy_tranches[i].time_open_msc > last_time_msc)
      {
         newer = true;
      }
      else if(buy_tranches[i].time_open_msc == last_time_msc)
      {
         if(buy_tranches[i].ticket > last_ticket)
            newer = true;
         else if(buy_tranches[i].ticket == last_ticket && buy_tranches[i].seq > last_seq)
            newer = true;
      }

      if(newer)
      {
         last_time_msc = buy_tranches[i].time_open_msc;
         last_ticket = buy_tranches[i].ticket;
         last_seq = buy_tranches[i].seq;
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
      t.time_open_msc = (long)PositionGetInteger(POSITION_TIME_MSC);
      if(t.time_open_msc <= 0)
         t.time_open_msc = ((long)t.time_open) * 1000;
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

bool AddTrancheBuy(const double entry_price, const double volume, const ulong ticket, const double target_price = 0.0, const long time_open_msc = 0)
{
   Tranche t;
   t.seq = ++buy_next_seq;
   t.ticket = ticket;
   if(time_open_msc > 0)
   {
      t.time_open_msc = time_open_msc;
      t.time_open = (datetime)(time_open_msc / 1000);
   }
   else
   {
      t.time_open = TimeCurrent();
      t.time_open_msc = ((long)t.time_open) * 1000;
   }
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
   ulong deal = trade.ResultDeal();
   long deal_time_msc = 0;
   if(hedging)
   {
      if(deal > 0 && HistoryDealSelect(deal))
      {
         ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
         deal_time_msc = (long)HistoryDealGetInteger(deal, DEAL_TIME_MSC);
      }
   }
   else if(deal > 0 && HistoryDealSelect(deal))
   {
      deal_time_msc = (long)HistoryDealGetInteger(deal, DEAL_TIME_MSC);
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

   AddTrancheBuy(entry_price, vol, ticket, tranche_target, deal_time_msc);
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
   long last_time_msc = -1;
   ulong last_ticket = 0;
   int last_seq = -1;
   int total = ArraySize(sell_tranches);
   for(int i = 0; i < total; i++)
   {
      if(sell_tranches[i].closed)
         continue;

      bool newer = false;
      if(sell_tranches[i].time_open_msc > last_time_msc)
      {
         newer = true;
      }
      else if(sell_tranches[i].time_open_msc == last_time_msc)
      {
         if(sell_tranches[i].ticket > last_ticket)
            newer = true;
         else if(sell_tranches[i].ticket == last_ticket && sell_tranches[i].seq > last_seq)
            newer = true;
      }

      if(newer)
      {
         last_time_msc = sell_tranches[i].time_open_msc;
         last_ticket = sell_tranches[i].ticket;
         last_seq = sell_tranches[i].seq;
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
      t.time_open_msc = (long)PositionGetInteger(POSITION_TIME_MSC);
      if(t.time_open_msc <= 0)
         t.time_open_msc = ((long)t.time_open) * 1000;
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

bool AddTrancheSell(const double entry_price, const double volume, const ulong ticket, const double target_price = 0.0, const long time_open_msc = 0)
{
   Tranche t;
   t.seq = ++sell_next_seq;
   t.ticket = ticket;
   if(time_open_msc > 0)
   {
      t.time_open_msc = time_open_msc;
      t.time_open = (datetime)(time_open_msc / 1000);
   }
   else
   {
      t.time_open = TimeCurrent();
      t.time_open_msc = ((long)t.time_open) * 1000;
   }
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
   ulong deal = trade.ResultDeal();
   long deal_time_msc = 0;
   if(hedging)
   {
      if(deal > 0 && HistoryDealSelect(deal))
      {
         ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
         deal_time_msc = (long)HistoryDealGetInteger(deal, DEAL_TIME_MSC);
      }
   }
   else if(deal > 0 && HistoryDealSelect(deal))
   {
      deal_time_msc = (long)HistoryDealGetInteger(deal, DEAL_TIME_MSC);
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

   AddTrancheSell(entry_price, vol, ticket, tranche_target, deal_time_msc);
   return true;
}

//+------------------------------------------------------------------+
//| Trading flow per side                                            |
//+------------------------------------------------------------------+
void ProcessBuy(const bool hedging, const double bid, const double ask, const double score)
{
   if(!BuyEntry)
      return;

   if((UseSuperTrend1 || UseSuperTrend2) && !IsSuperTrendBullish(1))
      return;

   int openCount = OpenTrancheCountBuy();
   bool scoreOk = true;
   if(Use_Sumit_Score)
   {
      int scoreTrigger = EntryScoreThresholdBuy;
      if(EntryScoreThresholdBuy < 0)
         scoreTrigger = 50 + (EntryScoreThresholdBuy * 10);
      scoreOk = (score <= scoreTrigger);
   }

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

   if((UseSuperTrend1 || UseSuperTrend2) && !IsSuperTrendBearish(1))
      return;

   int openCount = OpenTrancheCountSell();
   bool scoreOk = true;
   if(Use_Sumit_Score)
   {
      int scoreTrigger = EntryScoreThresholdSell;
      if(EntryScoreThresholdSell < 0)
         scoreTrigger = 50 + (EntryScoreThresholdSell * 10);
      scoreOk = (score >= scoreTrigger);
   }

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

int ApplySupertrendFlipSLToManagedPositions(const ulong magic,
                                            const int position_type,
                                            const bool hedging,
                                            const double signed_target_percent,
                                            const string reason)
{
   int protected_count = 0;
   int fallback_closed_count = 0;
   int ptotal = PositionsTotal();

   for(int i = ptotal - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!IsManagedPosition(magic, position_type))
         continue;

      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      if(entry_price <= 0.0)
         continue;

      double sl_price = entry_price;
      if(position_type == POSITION_TYPE_BUY)
         sl_price = entry_price * (1.0 + (signed_target_percent / 100.0));
      else
         sl_price = entry_price * (1.0 - (signed_target_percent / 100.0));
      sl_price = NormalizePrice(sl_price);

      double current_tp = PositionGetDouble(POSITION_TP);

      trade.SetExpertMagicNumber(magic);
      trade.SetDeviationInPoints(Deviation);

      bool modified = hedging
                      ? trade.PositionModify(ticket, sl_price, current_tp)
                      : trade.PositionModify(_Symbol, sl_price, current_tp);

      if(modified)
      {
         protected_count++;
         continue;
      }

      PrintFormat("%s SL set failed. ticket=%I64u entry=%.5f sl=%.5f retcode=%d (%s)",
                  reason, ticket, entry_price, sl_price, trade.ResultRetcode(), trade.ResultRetcodeDescription());

      if(trade.PositionClose(ticket))
         fallback_closed_count++;
      else
      {
         PrintFormat("%s fallback close failed. ticket=%I64u retcode=%d (%s)",
                     reason, ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }

   if(protected_count > 0)
      PrintFormat("%s SL-protected count=%d magic=%I64u targetPercent=%.6f",
                  reason, protected_count, magic, signed_target_percent);

   if(fallback_closed_count > 0)
      PrintFormat("%s fallback close count=%d magic=%I64u",
                  reason, fallback_closed_count, magic);

   return(protected_count + fallback_closed_count);
}

void ApplySupertrendBasedSL(const bool hedging)
{
   if(!(UseSuperTrend1 || UseSuperTrend2) || !SupetrendBasedSL)
      return;

   int selected = SelectSTbasedSL;
   if(selected < 0 || selected > 2)
      selected = 0;

   int st1_current = 0;
   int st2_current = 0;
   if(UseSuperTrend1)
      st1_current = GetSuperTrendDirectionFromHandle(supertrend1Handle, 1);
   if(UseSuperTrend2)
      st2_current = GetSuperTrendDirectionFromHandle(supertrend2Handle, 1);

   bool st1_flipped = false;
   bool st2_flipped = false;

   if(UseSuperTrend1 && st1_current != 0 && supertrend1_last_direction != 0 && st1_current != supertrend1_last_direction)
      st1_flipped = true;
   if(UseSuperTrend2 && st2_current != 0 && supertrend2_last_direction != 0 && st2_current != supertrend2_last_direction)
      st2_flipped = true;

   int flip_direction = 0;
   if(selected == 1)
   {
      if(st1_flipped)
         flip_direction = st1_current;
   }
   else if(selected == 2)
   {
      if(st2_flipped)
         flip_direction = st2_current;
   }
   else
   {
      // Any selected: trigger on first clear flip signal. If both flip opposite, skip as ambiguous.
      if(st1_flipped && st2_flipped)
      {
         if(st1_current == st2_current)
            flip_direction = st1_current;
      }
      else if(st1_flipped)
         flip_direction = st1_current;
      else if(st2_flipped)
         flip_direction = st2_current;
   }

   if(st1_current != 0)
      supertrend1_last_direction = st1_current;
   if(st2_current != 0)
      supertrend2_last_direction = st2_current;

   if(flip_direction == 0)
      return;

   // Backward-compatible override: closeNow=true with target=0.0 means move SL to entry (break-even),
   // which is a common requested setup for SuperTrend flip protection.
   bool use_close_now = SupetrendBasedSLCloseNow;
   if(use_close_now && MathAbs(SupetrendBasedSLTarget) <= 1e-12)
      use_close_now = false;

   if(flip_direction > 0)
   {
      if(use_close_now)
      {
         if(CloseAllManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, "SuperTrend flipped bullish: closing sells") > 0)
            SyncTranchesSell(hedging);
      }
      else
      {
         if(ApplySupertrendFlipSLToManagedPositions(SellMagicNumber,
                                                    POSITION_TYPE_SELL,
                                                    hedging,
                                                    SupetrendBasedSLTarget,
                                                    "SuperTrend flipped bullish: protecting sells") > 0)
            SyncTranchesSell(hedging);
      }
   }
   else
   {
      if(use_close_now)
      {
         if(CloseAllManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, "SuperTrend flipped bearish: closing buys") > 0)
            SyncTranchesBuy(hedging);
      }
      else
      {
         if(ApplySupertrendFlipSLToManagedPositions(BuyMagicNumber,
                                                    POSITION_TYPE_BUY,
                                                    hedging,
                                                    SupetrendBasedSLTarget,
                                                    "SuperTrend flipped bearish: protecting buys") > 0)
            SyncTranchesBuy(hedging);
      }
   }
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(BuyMagicNumber);
   trade.SetDeviationInPoints(Deviation);

   bool hedging = IsHedging();
   int margin_mode = (int)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   int leverage = (int)AccountInfoInteger(ACCOUNT_LEVERAGE);
   bool tester_mode = (MQLInfoInteger(MQL_TESTER) != 0);
   bool visual_mode = (MQLInfoInteger(MQL_VISUAL_MODE) != 0);
   PrintFormat("Environment: hedging=%s marginMode=%d leverage=%d tester=%s visual=%s",
               hedging ? "true" : "false",
               margin_mode,
               leverage,
               tester_mode ? "true" : "false",
               visual_mode ? "true" : "false");

   if(BuyEntry && SellEntry && !hedging)
   {
      Print("Invalid configuration: dual-side mode needs hedging account. Disable one side or use a hedging account.");
      return(INIT_PARAMETERS_INCORRECT);
   }

   if(UseNewBar && (!SetTargetWithEntry || TrailingTargetPips > 0.0 || SupetrendBasedSL))
   {
      Print("Modeling warning: entries are new-bar based but exits/protection are tick-based. Use 'Every tick based on real ticks' for stable tester comparisons.");
   }

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

   if(Use_Sumit_Score)
   {
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
   }

   if(UseSuperTrend1)
   {
      supertrend1Handle = iCustom(
         _Symbol,
         ST1Timeframe,
         "supertrend",
         ST1AtrP,
         ST1Mult,
         SupertrendSourcePrice,
         SupertrendTakeWicksIntoAccount
      );

      if(supertrend1Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create SuperTrend-1 handle (%s). err=%d",
                     EnumToString(ST1Timeframe),
                     GetLastError());
         return(INIT_FAILED);
      }
   }

   if(UseSuperTrend2)
   {
      supertrend2Handle = iCustom(
         _Symbol,
         ST2Timeframe,
         "supertrend",
         ST2AtrP,
         ST2Mult,
         SupertrendSourcePrice,
         SupertrendTakeWicksIntoAccount
      );

      if(supertrend2Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create SuperTrend-2 handle (%s). err=%d",
                     EnumToString(ST2Timeframe),
                     GetLastError());
         return(INIT_FAILED);
      }
   }

   if(UseSuperTrend1)
      supertrend1_last_direction = GetSuperTrendDirectionFromHandle(supertrend1Handle, 1);
   if(UseSuperTrend2)
      supertrend2_last_direction = GetSuperTrendDirectionFromHandle(supertrend2Handle, 1);

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
      EnsureServerTargetsForOpenPositionsBuy(hedging);
      EnsureServerTargetsForOpenPositionsSell(hedging);
      RebuildTranchesFromPositionsBuy(hedging);
      RebuildTranchesFromPositionsSell(hedging);
   }

   PrintFormat("Strategy uses score=%s + ST1=%s(%s) + ST2=%s(%s).",
               Use_Sumit_Score ? "on" : "off",
               UseSuperTrend1 ? "on" : "off",
               EnumToString(ST1Timeframe),
               UseSuperTrend2 ? "on" : "off",
               EnumToString(ST2Timeframe));
   PrintFormat("SuperTrend flip protection: enabled=%s select=%d closeNow=%s targetPercent=%.6f",
               SupetrendBasedSL ? "true" : "false",
               SelectSTbasedSL,
               SupetrendBasedSLCloseNow ? "true" : "false",
               SupetrendBasedSLTarget);

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(sumitScoreHandle != INVALID_HANDLE)
      IndicatorRelease(sumitScoreHandle);
   if(supertrend1Handle != INVALID_HANDLE)
      IndicatorRelease(supertrend1Handle);
   if(supertrend2Handle != INVALID_HANDLE)
      IndicatorRelease(supertrend2Handle);
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

   double score = EMPTY_VALUE;
   if(Use_Sumit_Score && !GetScoreValue(1, score))
      return;

   ProcessBuy(hedging, bid, ask, score);
   ProcessSell(hedging, bid, ask, score);
}
