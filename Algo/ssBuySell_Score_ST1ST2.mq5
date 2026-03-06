//+---------------------ssBuySell_Score_ST1ST2.mq5---------------------------------------+
//|
//   Combined Buy + Sell strategy with score + Sumit/Signal threshold entry/exit                  |
//| Uses external indicators: Sumit_RSI_Score_Indicator + optional SuperTrend filter              |
// TO DO FOR NEXT TELL IF WE CAN ADD FOLLOWING
//FOR EXAMPLE I ENTERED BULLISH AS PER CONDITION
//THEN CAN WE EXIT IF
//IF LONG TREND GOING BUT NO MOVEMENT
//MEANS MARKET IS BULLISH BUT SIDEWAYS
//LAST CANDLES = 21 MEANS (21MIN FOR 1M TIMEFRAME)
//IF GAIN IS BELOW THAN 0.5% THEN CLOSE THE TRADE...
//BUT IT WILL AFFECT THE CURRENT TARGET.. IF CURRENT TARGET IS SET THEN FORCE EXIT THE ENTRY 
//usoil, btc, eurusd = 0.1 lot size else 0.01 lot size
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>

// Inputs for Sumit_RSI_Score_Indicator
 int Rsi1hPeriod = 51;
 int Sumit_MaBuy = 30;

 int Sumit_MaSell = 70;
 int Rsi1hBuy = 40;
 int Rsi1hSell = 60;
 int SumitSma3Period = 3;
 int SumitSma201Period = 201;
 int SumitRsiPeriod = 7;
input bool BuyEntry = true;
input int EntryScoreBuy = 10; // Set 0 to disable score filter for buy entries
input string chk_last_candle_breaks_buy = "0"; 
input string chk_last_candle_type_buy = "0";  
input double BuyLotSize = 0.01;
input double BuyLotStep = 0.01;
input int BuyMaxEntries = 0;  

input bool SellEntry = true;
input int EntryScoreSell = 90; // Set 0 to disable score filter for sell entries
input string chk_last_candle_breaks_sell = "0"; 
input string chk_last_candle_type_sell = "0";   
input double SellLotSize = 0.01;
input double SellLotStep = 0.01;
input int SellMaxEntries = 0;

enum ExitByTrendMode
{
   EXIT_BY_ST1 = 0,
   EXIT_BY_ST2 = 1,
   EXIT_BY_ANY = 2
};
input ExitByTrendMode exitbytrend = EXIT_BY_ST1; // st1 | st2 | any


input int SupertrendAtrPeriod = 51;
input double SupertrendMultiplier = 1.5;
input ENUM_TIMEFRAMES ST2Timeframe = PERIOD_CURRENT; // PERIOD_CURRENT (0) disables ST2
ENUM_APPLIED_PRICE SupertrendSourcePrice = PRICE_MEDIAN; // PRICE_CLOSE, PRICE_OPEN, PRICE_HIGH, PRICE_LOW, PRICE_MEDIAN, PRICE_TYPICAL, PRICE_WEIGHTED
bool SupertrendTakeWicksIntoAccount = false; // true=use wick highs/lows, false=use candle body values

// Trading logic (common)
input double TargetPercent = 0.31;      
input double UpDownStep = 0.025;         
input bool SetTargetWithEntry = true;  // brokerside SetTargetWithEntry
input double TrailingTargetPercent = 0; //TrailingTargetPercent (0 disables)
input bool FastExecutionOnTick = true; // FastExecutionOnTick true/false=(current bar/closed bar)
input bool ExitTrendOnCurrentBar = true; // true=trend exits use current bar even if entry uses closed bar
input bool EnableIntrabarExitInTester = false; // false=fast tester (new-bar exits), true=intrabar exits in tester (slower)
input bool EntryOnFlipOnly = false;  
input bool RequireST2ForEntry = false; 
input double MaxSpreadPoints = 0.0; 
input int AtrFilterPeriod = 14;
input double MinAtrPercent = 0.0;  

bool RecoverExistingMagicPositions = true; 

input ulong BuyMagicNumber = 131;
input ulong SellMagicNumber = 121;
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
int supertrendH1Handle = INVALID_HANDLE;
int supertrendM5Handle = INVALID_HANDLE;
int atrFilterHandle = INVALID_HANDLE;

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

double ResolveTargetPriceBuy(const double entry_price)
{
   if(TargetPercent <= 0.0 || entry_price <= 0.0)
      return 0.0;
   return CalculateTargetPriceBuy(entry_price);
}

double ResolveTargetPriceSell(const double entry_price)
{
   if(TargetPercent <= 0.0 || entry_price <= 0.0)
      return 0.0;
   return CalculateTargetPriceSell(entry_price);
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

int NormalizeScoreLevel(const int level)
{
   if(level < 0)
      return 50 + (level * 10);
   return level;
}

bool IsBuyScoreFilterEnabled()
{
   return (EntryScoreBuy != 0);
}

bool IsSellScoreFilterEnabled()
{
   return (EntryScoreSell != 0);
}

bool IsAnyScoreFilterEnabled()
{
   return (IsBuyScoreFilterEnabled() || IsSellScoreFilterEnabled());
}

bool IsST2Enabled()
{
   return (ST2Timeframe != PERIOD_CURRENT);
}

bool IsTargetEnabled()
{
   return (TargetPercent > 0.0);
}

bool IsTrailingEnabled()
{
   return (!SetTargetWithEntry && TrailingTargetPercent > 0.0);
}

int GetSignalShift()
{
   return FastExecutionOnTick ? 0 : 1;
}

bool IsSpreadFilterPassed(const double bid, const double ask)
{
   if(MaxSpreadPoints <= 0.0)
      return true;

   double spread_points = (ask - bid) / g_point;
   return (spread_points <= MaxSpreadPoints);
}

bool IsAtrFilterPassed(const int shift, const double reference_price)
{
   if(MinAtrPercent <= 0.0)
      return true;
   if(reference_price <= 0.0 || atrFilterHandle == INVALID_HANDLE)
      return false;

   double atr_value[1];
   int copied = CopyBuffer(atrFilterHandle, 0, shift, 1, atr_value);
   if(copied != 1)
      return false;
   if(atr_value[0] == EMPTY_VALUE || atr_value[0] <= 0.0)
      return false;

   double atr_percent = (atr_value[0] / reference_price) * 100.0;
   return (atr_percent >= MinAtrPercent);
}

int GetSuperTrendDirectionFromHandle(const int handle, const int shift)
{
   if(handle == INVALID_HANDLE)
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

int GetSuperTrendDirection(const int shift)
{
   return GetSuperTrendDirectionFromHandle(supertrendH1Handle, shift);
}

int GetSuperTrendDirectionST2(const int shift)
{
   return GetSuperTrendDirectionFromHandle(supertrendM5Handle, shift);
}

bool ShouldExitBuysByTrend(const int st1, const int st2)
{
   if(!IsST2Enabled())
      return (st1 < 0);

   if(exitbytrend == EXIT_BY_ST1)
      return (st1 < 0);
   if(exitbytrend == EXIT_BY_ST2)
      return (st2 < 0);

   return (st1 < 0 || st2 < 0);
}

bool ShouldExitSellsByTrend(const int st1, const int st2)
{
   if(!IsST2Enabled())
      return (st1 > 0);

   if(exitbytrend == EXIT_BY_ST1)
      return (st1 > 0);
   if(exitbytrend == EXIT_BY_ST2)
      return (st2 > 0);

   return (st1 > 0 || st2 > 0);
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

void CompactClosedTranchesBuy()
{
   int total = ArraySize(buy_tranches);
   if(total <= 0)
      return;

   int open_count = 0;
   for(int i = 0; i < total; i++)
   {
      if(!buy_tranches[i].closed)
         open_count++;
   }

   if(open_count == total)
      return;

   if(open_count == 0)
   {
      ArrayResize(buy_tranches, 0);
      return;
   }

   Tranche open_only[];
   ArrayResize(open_only, open_count);
   int idx = 0;
   for(int i = 0; i < total; i++)
   {
      if(!buy_tranches[i].closed)
         open_only[idx++] = buy_tranches[i];
   }

   ArrayResize(buy_tranches, open_count);
   for(int i = 0; i < open_count; i++)
      buy_tranches[i] = open_only[i];
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
   if(!SetTargetWithEntry || !RecoverExistingMagicPositions || !IsTargetEnabled())
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
      double target_price = ResolveTargetPriceBuy(entry_price);
      if(target_price <= 0.0)
         continue;
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
   CompactClosedTranchesBuy();
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
      t.target_price = (broker_tp > 0.0) ? broker_tp : ResolveTargetPriceBuy(t.entry_price);
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
   t.target_price = (target_price > 0.0) ? target_price : ResolveTargetPriceBuy(entry_price);
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

   bool use_trailing = IsTrailingEnabled();
   bool target_enabled = IsTargetEnabled();
   if(!target_enabled && !use_trailing)
      return;

   for(int i = 0; i < total; i++)
   {
      if(buy_tranches[i].closed)
         continue;

      bool should_close = false;
      if(!use_trailing)
      {
         if(target_enabled && buy_tranches[i].target_price > 0.0 && current_price >= buy_tranches[i].target_price)
            should_close = true;
      }
      else
      {
         if(!buy_tranches[i].trailing_active)
         {
            bool can_activate = false;
            if(target_enabled && buy_tranches[i].target_price > 0.0)
               can_activate = (current_price >= buy_tranches[i].target_price);
            else
               can_activate = (current_price > buy_tranches[i].entry_price);

            if(can_activate)
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
   CompactClosedTranchesBuy();
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
   if(SetTargetWithEntry && IsTargetEnabled())
      request_target = ResolveTargetPriceBuy(price);

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

   double tranche_target = ResolveTargetPriceBuy(entry_price);

   if(SetTargetWithEntry && IsTargetEnabled() && tranche_target > 0.0)
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

void CompactClosedTranchesSell()
{
   int total = ArraySize(sell_tranches);
   if(total <= 0)
      return;

   int open_count = 0;
   for(int i = 0; i < total; i++)
   {
      if(!sell_tranches[i].closed)
         open_count++;
   }

   if(open_count == total)
      return;

   if(open_count == 0)
   {
      ArrayResize(sell_tranches, 0);
      return;
   }

   Tranche open_only[];
   ArrayResize(open_only, open_count);
   int idx = 0;
   for(int i = 0; i < total; i++)
   {
      if(!sell_tranches[i].closed)
         open_only[idx++] = sell_tranches[i];
   }

   ArrayResize(sell_tranches, open_count);
   for(int i = 0; i < open_count; i++)
      sell_tranches[i] = open_only[i];
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
   if(!SetTargetWithEntry || !RecoverExistingMagicPositions || !IsTargetEnabled())
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
      double target_price = ResolveTargetPriceSell(entry_price);
      if(target_price <= 0.0)
         continue;
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
   CompactClosedTranchesSell();
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
      t.target_price = (broker_tp > 0.0) ? broker_tp : ResolveTargetPriceSell(t.entry_price);
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
   t.target_price = (target_price > 0.0) ? target_price : ResolveTargetPriceSell(entry_price);
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

   bool use_trailing = IsTrailingEnabled();
   bool target_enabled = IsTargetEnabled();
   if(!target_enabled && !use_trailing)
      return;

   for(int i = 0; i < total; i++)
   {
      if(sell_tranches[i].closed)
         continue;

      bool should_close = false;
      if(!use_trailing)
      {
         if(target_enabled && sell_tranches[i].target_price > 0.0 && current_price <= sell_tranches[i].target_price)
            should_close = true;
      }
      else
      {
         if(!sell_tranches[i].trailing_active)
         {
            bool can_activate = false;
            if(target_enabled && sell_tranches[i].target_price > 0.0)
               can_activate = (current_price <= sell_tranches[i].target_price);
            else
               can_activate = (current_price < sell_tranches[i].entry_price);

            if(can_activate)
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
   CompactClosedTranchesSell();
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
   if(SetTargetWithEntry && IsTargetEnabled())
      request_target = ResolveTargetPriceSell(price);

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

   double tranche_target = ResolveTargetPriceSell(entry_price);

   if(SetTargetWithEntry && IsTargetEnabled() && tranche_target > 0.0)
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
void ProcessBuy(
   const bool hedging,
   const double bid,
   const double ask,
   const double score,
   const int st1_direction,
   const int st2_direction,
   const bool is_flip_to_buy,
   const bool common_entry_filters_ok
)
{
   if(!BuyEntry)
      return;

   if(st1_direction <= 0)
      return;
   if(RequireST2ForEntry && IsST2Enabled() && st2_direction <= 0)
      return;
   if(EntryOnFlipOnly && !is_flip_to_buy)
      return;
   if(!common_entry_filters_ok)
      return;

   int openCount = OpenTrancheCountBuy();
   bool entryOk = true;
   if(IsBuyScoreFilterEnabled())
   {
      int scoreTrigger = NormalizeScoreLevel(EntryScoreBuy);
      entryOk = (score <= scoreTrigger);
   }

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

void ProcessSell(
   const bool hedging,
   const double bid,
   const double ask,
   const double score,
   const int st1_direction,
   const int st2_direction,
   const bool is_flip_to_sell,
   const bool common_entry_filters_ok
)
{
   if(!SellEntry)
      return;

   if(st1_direction >= 0)
      return;
   if(RequireST2ForEntry && IsST2Enabled() && st2_direction >= 0)
      return;
   if(EntryOnFlipOnly && !is_flip_to_sell)
      return;
   if(!common_entry_filters_ok)
      return;

   int openCount = OpenTrancheCountSell();
   bool entryOk = true;
   if(IsSellScoreFilterEnabled())
   {
      int scoreTrigger = NormalizeScoreLevel(EntryScoreSell);
      entryOk = (score >= scoreTrigger);
   }

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

int CloseAllManagedPositions(const ulong magic, const int position_type, const string reason, const bool hedging)
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

      bool closed = trade.PositionClose(ticket);
      if(!closed && !hedging)
      {
         if(PositionSelect(_Symbol) &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == magic &&
            (int)PositionGetInteger(POSITION_TYPE) == position_type)
         {
            closed = trade.PositionClose(_Symbol);
         }
      }

      if(closed)
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

void ApplyExitByTrend(const bool hedging, const int st1_direction, const int st2_direction)
{
   if(ShouldExitBuysByTrend(st1_direction, st2_direction))
   {
      if(CloseAllManagedPositions(BuyMagicNumber, POSITION_TYPE_BUY, "Trend exit: selected SuperTrend is bearish for buys", hedging) > 0)
      {
         SyncTranchesBuy(hedging);
      }
   }

   if(ShouldExitSellsByTrend(st1_direction, st2_direction))
   {
      if(CloseAllManagedPositions(SellMagicNumber, POSITION_TYPE_SELL, "Trend exit: selected SuperTrend is bullish for sells", hedging) > 0)
      {
         SyncTranchesSell(hedging);
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

   if(MinAtrPercent > 0.0 && AtrFilterPeriod < 2)
      return(INIT_PARAMETERS_INCORRECT);

   if(IsAnyScoreFilterEnabled())
   {
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
   }

   supertrendH1Handle = iCustom(
      _Symbol,
      PERIOD_CURRENT,
      "supertrend",
      SupertrendAtrPeriod,
      SupertrendMultiplier,
      SupertrendSourcePrice,
      SupertrendTakeWicksIntoAccount
   );
   if(supertrendH1Handle == INVALID_HANDLE)
   {
      PrintFormat("Failed to create ST1 handle (%s). err=%d", EnumToString(PERIOD_CURRENT), GetLastError());
      return(INIT_FAILED);
   }

   supertrendM5Handle = INVALID_HANDLE;
   if(IsST2Enabled())
   {
      supertrendM5Handle = iCustom(
         _Symbol,
         ST2Timeframe,
         "supertrend",
         SupertrendAtrPeriod,
         SupertrendMultiplier,
         SupertrendSourcePrice,
         SupertrendTakeWicksIntoAccount
      );
      if(supertrendM5Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create ST2 handle (%s). err=%d", EnumToString(ST2Timeframe), GetLastError());
         return(INIT_FAILED);
      }
   }

   atrFilterHandle = INVALID_HANDLE;
   if(MinAtrPercent > 0.0)
   {
      atrFilterHandle = iATR(_Symbol, PERIOD_CURRENT, AtrFilterPeriod);
      if(atrFilterHandle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create ATR filter handle. period=%d err=%d", AtrFilterPeriod, GetLastError());
         return(INIT_FAILED);
      }
   }

   PrintFormat("Volume constraints for %s: min=%.4f step=%.4f max=%.4f",
               _Symbol, g_vol_min, g_vol_step, g_vol_max);
   PrintFormat("Price format: digits=%d point=%.10f pip=%.10f", g_digits, g_point, g_pip);
   PrintFormat("Mode: SetTargetWithEntry=%s TargetPercent=%.4f UpDownStep=%.4f TrailingTargetPercent=%.4f RecoverExistingMagicPositions=%s",
               SetTargetWithEntry ? "true" : "false",
               TargetPercent,
               UpDownStep,
               TrailingTargetPercent,
               RecoverExistingMagicPositions ? "true" : "false");
   if(IsAnyScoreFilterEnabled())
      PrintFormat("Entry scores: buy<=%d sell>=%d (0 disables per side)", EntryScoreBuy, EntryScoreSell);
   else
      Print("Entry scores: disabled (EntryScoreBuy=0 and EntryScoreSell=0)");
   if(IsST2Enabled())
      PrintFormat("Trend filters: ST1(current)=%s ST2(user)=%s exitbytrend=%s",
                  EnumToString(PERIOD_CURRENT), EnumToString(ST2Timeframe), EnumToString(exitbytrend));
   else
      PrintFormat("Trend filters: ST1(current)=%s ST2=disabled (ST2Timeframe=PERIOD_CURRENT) exitbytrend=%s",
                  EnumToString(PERIOD_CURRENT), EnumToString(exitbytrend));
   PrintFormat("Side config: BuyEntry=%s SellEntry=%s BuyMagic=%I64u SellMagic=%I64u",
               BuyEntry ? "true" : "false",
               SellEntry ? "true" : "false",
               BuyMagicNumber,
               SellMagicNumber);
   PrintFormat("Signal mode: FastExecutionOnTick=%s ExitTrendOnCurrentBar=%s EnableIntrabarExitInTester=%s UseNewBar=%s EntryOnFlipOnly=%s RequireST2ForEntry=%s MaxSpreadPoints=%.1f MinAtrPercent=%.3f",
                 FastExecutionOnTick ? "true" : "false",
                 ExitTrendOnCurrentBar ? "true" : "false",
                 EnableIntrabarExitInTester ? "true" : "false",
                 UseNewBar ? "true" : "false",
                 EntryOnFlipOnly ? "true" : "false",
                 RequireST2ForEntry ? "true" : "false",
                MaxSpreadPoints,
                MinAtrPercent);

   if(RecoverExistingMagicPositions)
   {
      bool hedging = IsHedging();
      EnsureServerTargetsForOpenPositionsBuy(hedging);
      EnsureServerTargetsForOpenPositionsSell(hedging);
      RebuildTranchesFromPositionsBuy(hedging);
      RebuildTranchesFromPositionsSell(hedging);
   }

   Print("Strategy: ST1(current)-driven entry/exit + optional score filter + target/trailing exits.");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(sumitScoreHandle != INVALID_HANDLE)
      IndicatorRelease(sumitScoreHandle);
   if(supertrendH1Handle != INVALID_HANDLE)
      IndicatorRelease(supertrendH1Handle);
   if(supertrendM5Handle != INVALID_HANDLE)
      IndicatorRelease(supertrendM5Handle);
   if(atrFilterHandle != INVALID_HANDLE)
      IndicatorRelease(atrFilterHandle);
}

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   bool run_entry_logic = true;
   bool is_tester = (MQLInfoInteger(MQL_TESTER) != 0 || MQLInfoInteger(MQL_OPTIMIZATION) != 0);
   bool allow_intrabar_exit = (!UseNewBar || !is_tester || EnableIntrabarExitInTester);
   if(UseNewBar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bar_time == 0)
         return;
      if(bar_time == last_bar_time)
      {
         if(!allow_intrabar_exit)
            return;
         run_entry_logic = false;
      }
      else
         last_bar_time = bar_time;
   }

   bool hedging = IsHedging();

   SyncTranchesBuy(hedging);
   SyncTranchesSell(hedging);
   RebuildTranchesFromPositionsBuy(hedging);
   RebuildTranchesFromPositionsSell(hedging);
   EnsureServerTargetsForOpenPositionsBuy(hedging);
   EnsureServerTargetsForOpenPositionsSell(hedging);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   int signal_shift = GetSignalShift();
   int exit_shift = ExitTrendOnCurrentBar ? 0 : signal_shift;

   int st1_direction_exit = GetSuperTrendDirection(exit_shift);
   int st2_direction_exit = IsST2Enabled() ? GetSuperTrendDirectionST2(exit_shift) : 0;

   ApplyExitByTrend(hedging, st1_direction_exit, st2_direction_exit);

   if(!SetTargetWithEntry)
   {
      CheckTargetsBuy(hedging, bid);
      CheckTargetsSell(hedging, ask);
   }

   if(!run_entry_logic)
      return;

   int st1_direction = GetSuperTrendDirection(signal_shift);
   int st2_direction = IsST2Enabled() ? GetSuperTrendDirectionST2(signal_shift) : 0;

   double score = 50.0;
   bool has_score = true;
   if(IsAnyScoreFilterEnabled())
   {
      has_score = GetScoreValue(signal_shift, score);
   }

   if(!has_score)
      return;

   bool spread_ok = IsSpreadFilterPassed(bid, ask);
   double mid_price = (bid + ask) * 0.5;
   bool atr_ok = IsAtrFilterPassed(signal_shift, mid_price);
   bool common_entry_filters_ok = (spread_ok && atr_ok);

   bool flip_to_buy = false;
   bool flip_to_sell = false;
   if(EntryOnFlipOnly)
   {
      int prev_direction = GetSuperTrendDirection(signal_shift + 1);
      flip_to_buy = (st1_direction > 0 && prev_direction < 0);
      flip_to_sell = (st1_direction < 0 && prev_direction > 0);
   }

   ProcessBuy(hedging, bid, ask, score, st1_direction, st2_direction, flip_to_buy, common_entry_filters_ok);
   ProcessSell(hedging, bid, ask, score, st1_direction, st2_direction, flip_to_sell, common_entry_filters_ok);
}
