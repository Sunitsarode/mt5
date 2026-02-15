//+------------------------------------------------------------------+
//|                         ScoreBuy Strategy (EA) with EMA200       |
// Based on SUMIT_RSI_Score.. Target 5points for XAU-USD
// Added: EMA200 bullish filter with slope confirmation
//+------------------------------------------------------------------+
#property copyright "Strategy EA"
#property version   "1.01"
#property strict

#include <Trade/Trade.mqh>

// Inputs (indicator logic)
input int Rsi1hPeriod = 51;
input int SumitMaBuyThreshold = 30;
input int SumitMaSellThreshold = 70;
input int Rsi1hBuyThreshold = 40;
input int Rsi1hSellThreshold = 55;
input int SumitSma3Period = 3;
input int SumitSma201Period = 201;
input int EntryScoreThreshold = -2; // score <= 30 (score < -1 in Python scale)

// MA201 Filter (uses existing SMA201 handle)
input bool UseEma200Filter = true;       // Enable MA201 bullish filter
input bool CheckEmaSlope = true;          // Check if MA201 is sloping up
input int EmaSlopeBars = 5;               // Bars to check slope (current vs X bars ago)

// Trading logic
input double MinTargetPoints = 5.0;   // Minimum TP distance in points
input double TargetPercent = 0.01;    // TP distance in percent of entry price
input double StepPoints = 5.0;
input double LotSize = 0.01;
input double LotStep = 0.01;
input int MaxEntries = 0;        // 0 = unlimited

// Execution
input ulong MagicNumber = 20260212;
input int Deviation = 30;
input bool UseNewBar = true;

CTrade trade;

struct Tranche
{
   int      seq;
   ulong    ticket;       // position ticket for hedging (0 for netting)
   datetime time_open;
   double   entry_price;
   double   volume;
   double   target_price;
   bool     closed;
};

Tranche tranches[];
int next_seq = 0;
double last_entry_price_open = 0.0;
double last_entry_lot = 0.0;
double last_entry_price_ref = 0.0; // last entry price even after close
datetime last_bar_time = 0;

int rsiHandle = INVALID_HANDLE;
int ma3Handle = INVALID_HANDLE;
int ma201Handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Utility                                                         |
//+------------------------------------------------------------------+
bool IsHedging()
{
   return(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

double NormalizeVolume(double vol)
{
   double minv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxv = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = minv;
   double normalized = MathFloor(vol / step) * step;
   if(normalized < minv)
      normalized = minv;
   if(normalized > maxv)
      normalized = maxv;
   return normalized;
}

double CalculateTargetDistance(const double entry_price)
{
   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = MinTargetPoints * pt;
   double pctDist = entry_price * (TargetPercent / 100.0);
   return MathMax(minDist, pctDist);
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

//+------------------------------------------------------------------+
//| MA201 Bullish Confirmation                                      |
//+------------------------------------------------------------------+
bool IsBullishConfirmed()
{
   if(!UseEma200Filter)
      return true;  // Filter disabled, always allow trading
   
   // Get close prices
   double close[];
   ArraySetAsSeries(close, true);
   if(CopyClose(_Symbol, PERIOD_CURRENT, 0, 10, close) <= 0)
   {
      Print("Failed to get close prices for MA201 filter");
      return false;
   }
   
   // Get MA201 values
   double ma201[];
   ArraySetAsSeries(ma201, true);
   int copyBars = MathMax(10, EmaSlopeBars + 5);
   if(CopyBuffer(ma201Handle, 0, 0, copyBars, ma201) <= 0)
   {
      Print("Failed to get MA201 values");
      return false;
   }
   
   // Check 1: Current close price must be ABOVE MA201
   if(close[1] <= ma201[1])  // Using bar 1 (completed bar)
   {
      return false;  // Price not above MA201
   }
   
   // Check 2: MA201 must be sloping UP (optional)
   if(CheckEmaSlope)
   {
      if(EmaSlopeBars < 2)
      {
         Print("EmaSlopeBars must be >= 2 for slope check");
         return false;
      }
      
      double ma_current = ma201[1];
      double ma_past = ma201[EmaSlopeBars];
      
      if(ma_current <= ma_past)
      {
         return false;  // MA201 is not sloping up
      }
   }
   
   return true;  // All bullish conditions met
}

//+------------------------------------------------------------------+
//| Indicator math                                                  |
//+------------------------------------------------------------------+
bool CalcRsiAt(const double &arr[], const int index, const int period, double &out)
{
   int size = ArraySize(arr);
   if(index + period >= size)
      return false;

   double gains = 0.0, losses = 0.0;
   for(int j = 1; j <= period; j++)
   {
      double a = arr[index + j - 1];
      double b = arr[index + j];
      if(a == EMPTY_VALUE || b == EMPTY_VALUE)
         return false;
      double change = a - b;
      if(change > 0)
         gains += change;
      else
         losses -= change;
   }

   if(losses == 0.0)
      out = 100.0;
   else
      out = 100.0 - (100.0 / (1.0 + (gains / losses)));

   return true;
}

bool CalcSmaAt(const double &arr[], const int index, const int period, double &out)
{
   int size = ArraySize(arr);
   if(index + period > size)
      return false;

   double sum = 0.0;
   for(int j = 0; j < period; j++)
   {
      double v = arr[index + j];
      if(v == EMPTY_VALUE)
         return false;
      sum += v;
   }

   out = sum / period;
   return true;
}

bool CalculateScore(const int shift, int &score, double &sumitRsi, double &signalMa3, double &signalMa11, double &rsiVal)
{
   int bars = Bars(_Symbol, PERIOD_CURRENT);
   int minBars = MathMax(250, SumitSma201Period + 20);
   if(bars < minBars + shift)
      return false;

   int count = MathMin(bars, MathMax(300, minBars));

   double rsi[];
   double ma3[];
   double ma201[];
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(ma3, true);
   ArraySetAsSeries(ma201, true);

   if(CopyBuffer(rsiHandle, 0, 0, count, rsi) <= 0)
      return false;
   if(CopyBuffer(ma3Handle, 0, 0, count, ma3) <= 0)
      return false;
   if(CopyBuffer(ma201Handle, 0, 0, count, ma201) <= 0)
      return false;

   double momentum[];
   double rsiMomentum[];
   ArrayResize(momentum, count);
   ArrayResize(rsiMomentum, count);
   ArraySetAsSeries(momentum, true);
   ArraySetAsSeries(rsiMomentum, true);

   for(int i = count - 1; i >= 0; i--)
      momentum[i] = ma3[i] - ma201[i];

   for(int i = count - 1; i >= 0; i--)
   {
      double r;
      if(CalcRsiAt(momentum, i, 7, r))
         rsiMomentum[i] = r;
      else
         rsiMomentum[i] = EMPTY_VALUE;
   }

   sumitRsi = rsiMomentum[shift];
   if(sumitRsi == EMPTY_VALUE)
      return false;
   if(!CalcSmaAt(rsiMomentum, shift, 3, signalMa3))
      return false;
   if(!CalcSmaAt(rsiMomentum, shift, 11, signalMa11))
      return false;

   rsiVal = rsi[shift];
   if(rsiVal == EMPTY_VALUE)
      return false;

   score = 50;
   if(signalMa3 > SumitMaSellThreshold) score += 10;
   if(signalMa11 > SumitMaSellThreshold) score += 10;
   if(sumitRsi > SumitMaSellThreshold) score += 10;
   if(rsiVal > Rsi1hSellThreshold) score += 10;

   if(signalMa3 < SumitMaBuyThreshold) score -= 10;
   if(signalMa11 < SumitMaBuyThreshold) score -= 10;
   if(sumitRsi < SumitMaBuyThreshold) score -= 10;
   if(rsiVal < Rsi1hBuyThreshold) score -= 10;

   return true;
}

//+------------------------------------------------------------------+
//| Tranche management                                              |
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
      // If no position for this symbol/magic, clear all tranches
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

      Tranche t;
      t.seq = ++next_seq;
      t.ticket = hedging ? (ulong)PositionGetInteger(POSITION_TICKET) : 0;
      t.time_open = (datetime)PositionGetInteger(POSITION_TIME);
      t.entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
      t.volume = PositionGetDouble(POSITION_VOLUME);
      t.target_price = t.entry_price + CalculateTargetDistance(t.entry_price);
      t.closed = false;

      int sz = ArraySize(tranches);
      ArrayResize(tranches, sz + 1);
      tranches[sz] = t;
   }

   UpdateLastEntryFromOpen();
   if(last_entry_price_open > 0.0)
      last_entry_price_ref = last_entry_price_open;
}

bool AddTranche(const double entry_price, const double volume, const ulong ticket)
{
   Tranche t;
   t.seq = ++next_seq;
   t.ticket = ticket;
   t.time_open = TimeCurrent();
   t.entry_price = entry_price;
   t.volume = volume;
   t.target_price = entry_price + CalculateTargetDistance(entry_price);
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

   for(int i = 0; i < total; i++)
   {
      if(tranches[i].closed)
         continue;
      if(current_price < tranches[i].target_price)
         continue;

      if(hedging)
      {
         if(PositionSelectByTicket(tranches[i].ticket))
            trade.PositionClose(tranches[i].ticket);
      }
      else
      {
         if(PositionSelect(_Symbol) &&
            (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
            (int)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         {
            trade.PositionClosePartial(_Symbol, tranches[i].volume);
         }
      }

      last_entry_price_ref = tranches[i].entry_price;
      tranches[i].closed = true;
   }

   UpdateLastEntryFromOpen();
}

//+------------------------------------------------------------------+
//| Trading                                                         |
//+------------------------------------------------------------------+
bool TryOpenEntry(const double price, const double lot, const bool hedging)
{
   double vol = NormalizeVolume(lot);
   if(vol <= 0.0)
      return false;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Deviation);

   string comment = StringFormat("SB|lot=%.2f", vol);
   if(!trade.Buy(vol, _Symbol, 0, 0, 0, comment))
      return false;

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

   AddTranche(entry_price, vol, ticket);
   return true;
}

//+------------------------------------------------------------------+
//| Init / Deinit                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(Deviation);

   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Rsi1hPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle");
      return(INIT_FAILED);
   }

   ma3Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma3Period, 0, MODE_SMA, PRICE_TYPICAL);
   ma201Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma201Period, 0, MODE_SMA, PRICE_TYPICAL);
   if(ma3Handle == INVALID_HANDLE || ma201Handle == INVALID_HANDLE)
   {
      Print("Failed to create SMA handles");
      return(INIT_FAILED);
   }

   if(UseEma200Filter)
      Print("MA201 filter enabled with slope check: ", CheckEmaSlope ? "Yes" : "No");

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   if(ma3Handle != INVALID_HANDLE)
      IndicatorRelease(ma3Handle);
   if(ma201Handle != INVALID_HANDLE)
      IndicatorRelease(ma201Handle);
}

//+------------------------------------------------------------------+
//| Tick                                                            |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;

   bool hedging = IsHedging();
   SyncTranches(hedging);
   RebuildTranchesFromPositions(hedging);

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   CheckTargets(hedging, bid);

   // *** CHECK BULLISH CONFIRMATION FIRST ***
   if(!IsBullishConfirmed())
   {
      // Price is below EMA200 or EMA200 is not sloping up - no new entries
      return;
   }

   if(UseNewBar)
   {
      datetime bar_time = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(bar_time == 0 || bar_time == last_bar_time)
         return;
      last_bar_time = bar_time;
   }

   int score;
   double sumitRsi, signalMa3, signalMa11, rsiVal;
   if(!CalculateScore(1, score, sumitRsi, signalMa3, signalMa11, rsiVal))
      return;

   int openCount = OpenTrancheCount();
   int scoreTrigger = 50 + (EntryScoreThreshold * 10);
   bool scoreOk = (score <= scoreTrigger);

   if(openCount == 0)
   {
      if(!scoreOk)
         return;

      if(last_entry_price_ref > 0.0)
      {
         double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);  // Get point value
         if(MathAbs(bid - last_entry_price_ref) < StepPoints * pt)  // Fixed with point multiplication
            return;
      }

      TryOpenEntry(ask, LotSize, hedging);
      return;
   }

   if(MaxEntries > 0 && openCount >= MaxEntries)
      return;

   if(!scoreOk)
      return;

   double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);  // Get point value
   if(last_entry_price_open > 0.0 && bid <= (last_entry_price_open - StepPoints * pt))  // Fixed with point multiplication
   {
      double nextLot = last_entry_lot;
      if(nextLot <= 0.0)
         nextLot = LotSize;
      nextLot += LotStep;
      TryOpenEntry(ask, nextLot, hedging);
   }
}
