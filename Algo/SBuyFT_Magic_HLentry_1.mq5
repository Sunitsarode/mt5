//+------------------------------------------------------------------+
//|                         ScoreBuy with fixed target handle all position with magic no Strategy (EA)                   |
//| Uses external indicators: Sumit_RSI_Score_Indicator + supertrend |
//| Buy when sumit >=30 and prev candle low or close breaks
// prev_candle_breaks = 'low' or 'close'
// if low then entry as soon as low breaks
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.04"
#property strict

#include <Trade/Trade.mqh>

// Inputs for Sumit_RSI_Score_Indicator
input int Rsi1hPeriod = 51;
input int SumitMaBuyThreshold = 30;
input int SumitMaSellThreshold = 70;
input int Rsi1hBuyThreshold = 40;
input int Rsi1hSellThreshold = 55;
input int SumitSma3Period = 3;
input int SumitSma201Period = 201;
input int SumitRsiPeriod = 7;
input int EntryScoreThreshold = 30; // Score must be <= threshold

// SuperTrend filter (1H timeframe)
input bool UseSuperTrend = false;
input int SupertrendAtrPeriod = 22;
input double SupertrendMultiplier = 3.0;
input ENUM_APPLIED_PRICE SupertrendSourcePrice = PRICE_MEDIAN;
input bool SupertrendTakeWicksIntoAccount = true;

// Trading logic
input double MinTargetPoints = 10.0;   // Minimum TP distance in points
input double TargetPercent = 0.01;     // TP distance in percent of entry price
input bool SetTargetWithEntry = true;  // Place broker TP in the entry request
input double TrailingTargetPips = 5.0; // Used only when SetTargetWithEntry=false (0 disables trailing)
input bool RecoverExistingMagicPositions = true; // Rebuild and manage existing magic positions on restart
input double LotSize = 0.01;
input double LotStep = 0.01;
input int MaxEntries = 0;             // 0 = unlimited

// Execution
input ulong MagicNumber = 1051;
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

Tranche tranches[];
int next_seq = 0;
double last_entry_price_open = 0.0;
double last_entry_lot = 0.0;
double last_entry_price_ref = 0.0;
datetime last_bar_time = 0;

int sumitScoreHandle = INVALID_HANDLE;
int supertrendH1Handle = INVALID_HANDLE;

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

double CalculateTargetPrice(const double entry_price)
{
   return NormalizePrice(entry_price + CalculateTargetDistance(entry_price));
}

double CalculateTrailingDistance()
{
   if(TrailingTargetPips <= 0.0)
      return 0.0;
   return TrailingTargetPips * g_pip;
}

double CalculateStepDistance(const double reference_price)
{
   return reference_price * (TargetPercent / 100.0);
}

int OpenTrancheCount()
{
   int count = 0;
   int total = ArraySize(tranches);
   for(int i = 0; i < total; i++)
   {
      if(!tranches[i].closed)
         count++;
   }
   return count;
}

void UpdateLastEntryFromOpen()
{
   last_entry_price_open = 0.0;
   last_entry_lot = 0.0;
   datetime last_time = 0;
   int total = ArraySize(tranches);
   for(int i = 0; i < total; i++)
   {
      if(tranches[i].closed)
         continue;
      if(tranches[i].time_open >= last_time)
      {
         last_time = tranches[i].time_open;
         last_entry_price_open = tranches[i].entry_price;
         last_entry_lot = tranches[i].volume;
      }
   }
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

bool IsSuperTrendBullishH1(const int shift)
{
   if(supertrendH1Handle == INVALID_HANDLE)
      return false;

   double direction_value[1];
   int copied = CopyBuffer(supertrendH1Handle, 2, shift, 1, direction_value);
   if(copied != 1)
      return false;

   if(direction_value[0] == EMPTY_VALUE)
      return false;

   return (direction_value[0] > 0.0);
}

bool IsManagedBuyPosition()
{
   // Magic-only adoption scope.
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return false;
   if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
      return false;
   return true;
}

void EnsureServerTargetsForOpenPositions(const bool hedging)
{
   if(!SetTargetWithEntry || !RecoverExistingMagicPositions)
      return;

   int ptotal = PositionsTotal();
   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(!IsManagedBuyPosition())
         continue;
      if(PositionGetDouble(POSITION_TP) > 0.0)
         continue;

      double entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      double target_price = CalculateTargetPrice(entry_price);
      bool modified = hedging
                      ? trade.PositionModify(ticket, 0.0, target_price)
                      : trade.PositionModify(_Symbol, 0.0, target_price);

      if(!modified)
      {
         PrintFormat("Recovery TP set failed. ticket=%I64u target=%.5f retcode=%d (%s)",
                     ticket, target_price, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
      else
      {
         PrintFormat("Recovery TP set. ticket=%I64u target=%.5f", ticket, target_price);
      }
   }
}

//+------------------------------------------------------------------+
//| Tranche management                                               |
//+------------------------------------------------------------------+
void SyncTranches(const bool hedging)
{
   int total = ArraySize(tranches);
   if(total == 0)
      return;

   if(hedging)
   {
      for(int i = 0; i < total; i++)
      {
         if(tranches[i].closed)
            continue;
         if(!PositionSelectByTicket(tranches[i].ticket))
         {
            tranches[i].closed = true;
            last_entry_price_ref = tranches[i].entry_price;
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
         if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
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
            if(!tranches[i].closed)
               last_entry_price_ref = tranches[i].entry_price;
            tranches[i].closed = true;
         }
      }
   }

   UpdateLastEntryFromOpen();
}

void RebuildTranchesFromPositions(const bool hedging)
{
   if(ArraySize(tranches) > 0)
      return;

   int ptotal = PositionsTotal();
   if(ptotal <= 0)
      return;

   // First pass: Count valid positions to resize once
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
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
         continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY)
         continue;

      valid_count++;
   }

   if(valid_count == 0)
      return;

   ArrayResize(tranches, valid_count);
   int idx = 0;

   // Second pass: Fill data
   for(int i = 0; i < ptotal; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((int)PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_BUY) continue;

      Tranche t;
      t.seq = ++next_seq;
      t.ticket = hedging ? (ulong)PositionGetInteger(POSITION_TICKET) : 0;
      t.time_open = (datetime)PositionGetInteger(POSITION_TIME);
      t.entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      t.volume = PositionGetDouble(POSITION_VOLUME);
      double broker_tp = PositionGetDouble(POSITION_TP);
      t.target_price = (broker_tp > 0.0) ? broker_tp : CalculateTargetPrice(t.entry_price);
      t.trailing_active = false;
      t.trailing_peak = 0.0;
      t.closed = false;

      if(idx < valid_count)
         tranches[idx++] = t;
   }

   UpdateLastEntryFromOpen();
   if(last_entry_price_open > 0.0)
      last_entry_price_ref = last_entry_price_open;
}

bool AddTranche(const double entry_price, const double volume, const ulong ticket, const double target_price = 0.0)
{
   Tranche t;
   t.seq = ++next_seq;
   t.ticket = ticket;
   t.time_open = TimeCurrent();
   t.entry_price = entry_price;
   t.volume = volume;
   t.target_price = (target_price > 0.0) ? target_price : CalculateTargetPrice(entry_price);
   t.trailing_active = false;
   t.trailing_peak = 0.0;
   t.closed = false;

   int sz = ArraySize(tranches);
   ArrayResize(tranches, sz + 1);
   tranches[sz] = t;

   last_entry_price_open = entry_price;
   last_entry_lot = volume;
   last_entry_price_ref = entry_price;
   return true;
}

void CheckTargets(const bool hedging, const double current_price)
{
   int total = ArraySize(tranches);
   if(total == 0)
      return;

   double trailing_distance = CalculateTrailingDistance();
   bool use_trailing = (!SetTargetWithEntry && trailing_distance > 0.0);

   for(int i = 0; i < total; i++)
   {
      if(tranches[i].closed)
         continue;

      bool should_close = false;
      if(!use_trailing)
      {
         if(current_price >= tranches[i].target_price)
            should_close = true;
      }
      else
      {
         // First hit activates trailing instead of immediate close.
         if(!tranches[i].trailing_active)
         {
            if(current_price >= tranches[i].target_price)
            {
               tranches[i].trailing_active = true;
               tranches[i].trailing_peak = current_price;
            }
            continue;
         }

         if(current_price > tranches[i].trailing_peak)
            tranches[i].trailing_peak = current_price;

         double trailing_stop = tranches[i].trailing_peak - trailing_distance;
         if(current_price <= trailing_stop)
            should_close = true;
      }

      if(!should_close)
         continue;

      bool closed_now = false;
      if(hedging)
      {
         if(PositionSelectByTicket(tranches[i].ticket))
            closed_now = trade.PositionClose(tranches[i].ticket);
      }
      else
      {
         if(PositionSelect(_Symbol) &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            (int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            closed_now = trade.PositionClosePartial(_Symbol, tranches[i].volume);
         }
      }

      if(closed_now)
      {
         last_entry_price_ref = tranches[i].entry_price;
         tranches[i].closed = true;
      }
   }

   UpdateLastEntryFromOpen();
}

//+------------------------------------------------------------------+
//| Trading                                                          |
//+------------------------------------------------------------------+
bool TryOpenEntry(const double price, const double lot, const bool hedging)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   if(MathAbs(vol - lot) > 1e-8)
   {
      PrintFormat("Lot normalized. reqLot=%.4f normLot=%.4f min=%.4f step=%.4f max=%.4f",
                  lot, vol, g_vol_min, g_vol_step, g_vol_max);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Deviation);

   string comment = StringFormat("SB|lot=%.2f", vol);
   double request_target = 0.0;
   if(SetTargetWithEntry)
      request_target = CalculateTargetPrice(price);

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

   double tranche_target = CalculateTargetPrice(entry_price);

   // If broker TP was requested but missing, attach it immediately after fill.
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
         if(current_tp <= 0.0 || MathAbs(current_tp - tranche_target) > (g_point * 0.5))
            modified = trade.PositionModify(_Symbol, 0.0, tranche_target);
      }

      if(can_verify_position && !modified)
      {
         PrintFormat("Post-entry TP attach failed. target=%.5f retcode=%d (%s)",
                     tranche_target, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }

   AddTranche(entry_price, vol, ticket, tranche_target);
   return true;
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
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
         PERIOD_H1,
         "supertrend",
         SupertrendAtrPeriod,
         SupertrendMultiplier,
         SupertrendSourcePrice,
         SupertrendTakeWicksIntoAccount
      );

      if(supertrendH1Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create SuperTrend H1 handle. err=%d", GetLastError());
         return(INIT_FAILED);
      }
   }

   PrintFormat("Volume constraints for %s: min=%.4f step=%.4f max=%.4f",
               _Symbol, g_vol_min, g_vol_step, g_vol_max);
   PrintFormat("Price format: digits=%d point=%.10f pip=%.10f", g_digits, g_point, g_pip);
   PrintFormat("Mode: SetTargetWithEntry=%s TrailingTargetPips=%.2f RecoverExistingMagicPositions=%s",
               SetTargetWithEntry ? "true" : "false",
               TrailingTargetPips,
               RecoverExistingMagicPositions ? "true" : "false");

   if(RecoverExistingMagicPositions)
   {
      bool hedging = IsHedging();
      EnsureServerTargetsForOpenPositions(hedging);
      RebuildTranchesFromPositions(hedging);
   }

   Print("Strategy uses external score + H1 SuperTrend bullish filter.");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(sumitScoreHandle != INVALID_HANDLE)
      IndicatorRelease(sumitScoreHandle);
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
   SyncTranches(hedging);
   RebuildTranchesFromPositions(hedging);
   EnsureServerTargetsForOpenPositions(hedging);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(!SetTargetWithEntry)
      CheckTargets(hedging, bid);

   if(UseNewBar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bar_time == 0 || bar_time == last_bar_time)
         return;
      last_bar_time = bar_time;
   }

   // Buy gating condition: SuperTrend on H1 must be bullish.
   if(UseSuperTrend && !IsSuperTrendBullishH1(1))
      return;

   double score = EMPTY_VALUE;
   if(!GetScoreValue(1, score))
      return;

   int openCount = OpenTrancheCount();
   int scoreTrigger = EntryScoreThreshold;
   if(EntryScoreThreshold < 0)
      scoreTrigger = 50 + (EntryScoreThreshold * 10);

   bool scoreOk = (score <= scoreTrigger);

   if(openCount == 0)
   {
      if(!scoreOk)
         return;

      if(last_entry_price_ref > 0.0)
      {
         if(MathAbs(bid - last_entry_price_ref) < CalculateStepDistance(last_entry_price_ref))
            return;
      }

      TryOpenEntry(ask, LotSize, hedging);
      return;
   }

   if(MaxEntries > 0 && openCount >= MaxEntries)
      return;

   if(!scoreOk)
      return;

   if(last_entry_price_open > 0.0 && bid <= (last_entry_price_open - CalculateStepDistance(last_entry_price_open)))
   {
      double nextLot = last_entry_lot;
      if(nextLot <= 0.0)
         nextLot = LotSize;
      nextLot += LotStep;
      TryOpenEntry(ask, nextLot, hedging);
   }
}
