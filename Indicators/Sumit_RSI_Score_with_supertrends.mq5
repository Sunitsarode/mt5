//+------------------------------------------------------------------+
//|         Sumit_RSI_Score_SuperTrend_Merged.mq5                    |
//|  Merged: Sumit_RSI_Score_Indicator + SuperTrend_SS              |
//|  All 6 lines in one separate window, scale 0-100                 |
//+------------------------------------------------------------------+
#property copyright "Strategy Indicators"
#property version   "1.00"
#property indicator_separate_window
#property indicator_buffers 18
#property indicator_plots   6
#property indicator_minimum 0
#property indicator_maximum 100

#include <MovingAverages.mqh>

// Plot 1: Sumit RSI
#property indicator_label1  "Sumit RSI"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrCyan
#property indicator_width1  2

// Plot 2: Signal MA3
#property indicator_label2  "Signal MA3"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrLime
#property indicator_width2  1

// Plot 3: Signal MA11
#property indicator_label3  "Signal MA11"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrRed
#property indicator_width3  1

// Plot 4: RSI Smooth (Rsi1h)
#property indicator_label4  "RSI Smooth"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMagenta
#property indicator_width4  1

// Plot 5: Score
#property indicator_label5  "Score"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrGreen
#property indicator_width5  2

// Plot 6: ST Score (SuperTrend mapped 0-100)
#property indicator_label6  "ST Score"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrNavy
#property indicator_width6  3

// Levels
#property indicator_level1  10
#property indicator_level2  25
#property indicator_level3  30
#property indicator_level4  50
#property indicator_level5  70
#property indicator_level6  75
#property indicator_level7  90
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT

//==================================================================
// INPUT PARAMETERS
//==================================================================

// RSI Score inputs
input int Rsi1hPeriod           = 51;
input int SumitMaBuyThreshold   = 30;
input int SumitMaSellThreshold  = 70;
input int Rsi1hBuyThreshold     = 40;
input int Rsi1hSellThreshold    = 55;
input int SumitSma3Period       = 3;
input int SumitSma201Period     = 201;
input int SumitRsiPeriod        = 7;

// SuperTrend inputs
input bool            SuperTrend1       = true;
input int             ST1_ATR           = 51;
input ENUM_TIMEFRAMES ST1Timeframe      = PERIOD_CURRENT;
input bool            SuperTrend2       = true;
input int             ST2_ATR           = 51;
input ENUM_TIMEFRAMES ST2Timeframe      = PERIOD_M30;
input double          Multiplier        = 1.0;
input ENUM_APPLIED_PRICE SourcePrice    = PRICE_MEDIAN;
input bool            TakeWicksIntoAccount = true;

//==================================================================
// BUFFERS — all INDICATOR_DATA first (0-5), then INDICATOR_CALCULATIONS (6-17)
//==================================================================

// --- INDICATOR_DATA (plots, indices 0-5) ---
double SumitRsiBuffer[];    // 0 - Plot 1
double SignalMa3Buffer[];   // 1 - Plot 2
double SignalMa11Buffer[];  // 2 - Plot 3
double Rsi1hBuffer[];       // 3 - Plot 4
double ScoreBuffer[];       // 4 - Plot 5
double STScoreBuffer[];     // 5 - Plot 6

// --- INDICATOR_CALCULATIONS (indices 6-17) ---
double AvgGainBuffer[];
double AvgLossBuffer[];
double WorkRsi[];
double WorkMa3[];
double WorkMa201[];
double WorkMomentum[];
double SuperTrendColorBuffer[];
double ST1DirectionBuffer[];
double ST2DirectionBuffer[];
double ST1ScoreBuffer[];
double ST2ScoreBuffer[];
double ST2LineCalcBuffer[];

//==================================================================
// HANDLES
//==================================================================
int rsiHandle   = INVALID_HANDLE;
int ma3Handle   = INVALID_HANDLE;
int ma201Handle = INVALID_HANDLE;
int atrHandle1  = INVALID_HANDLE;
int atrHandle2  = INVALID_HANDLE;

//==================================================================
// RSI SCORE HELPER FUNCTIONS (unchanged from original)
//==================================================================

bool SeedWilderAverages(const double &src[], const int period, double &avg_gain, double &avg_loss)
{
   if(ArraySize(src) <= period) return false;
   double gain_sum = 0.0, loss_sum = 0.0;
   for(int i = 1; i <= period; i++)
   {
      if(src[i] == EMPTY_VALUE || src[i-1] == EMPTY_VALUE) return false;
      double change = src[i] - src[i-1];
      if(change > 0.0) gain_sum += change;
      else             loss_sum -= change;
   }
   avg_gain = gain_sum / period;
   avg_loss = loss_sum / period;
   return true;
}

void UpdateRsiWilderBuffer(const int rates_total, const int prev_calculated, const int period)
{
   if(period <= 0 || rates_total <= period) return;

   // Find first valid WorkMomentum index (MA201 creates EMPTY_VALUE for first 200 bars)
   int firstValid = -1;
   for(int i = 0; i < rates_total; i++)
   {
      if(WorkMomentum[i] != EMPTY_VALUE) { firstValid = i; break; }
   }
   if(firstValid < 0 || firstValid + period >= rates_total) return;

   int seedBar = firstValid + period; // first bar where we can seed Wilder avg

   int start = (prev_calculated > 1) ? (prev_calculated - 1) : 0;
   if(start < 0) start = 0;

   // Always re-seed if we haven't computed the seed bar yet
   if(prev_calculated == 0 || start <= seedBar)
   {
      // Clear everything up to seedBar
      for(int i = 0; i < seedBar && i < rates_total; i++)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i]  = EMPTY_VALUE;
         AvgLossBuffer[i]  = EMPTY_VALUE;
      }

      // Seed Wilder averages from firstValid to firstValid+period
      double gain_sum = 0.0, loss_sum = 0.0;
      bool ok = true;
      for(int i = firstValid + 1; i <= firstValid + period; i++)
      {
         if(WorkMomentum[i] == EMPTY_VALUE || WorkMomentum[i-1] == EMPTY_VALUE) { ok = false; break; }
         double ch = WorkMomentum[i] - WorkMomentum[i-1];
         if(ch > 0.0) gain_sum += ch; else loss_sum -= ch;
      }
      if(!ok) return;

      double avg_gain = gain_sum / period;
      double avg_loss = loss_sum / period;
      AvgGainBuffer[seedBar]  = avg_gain;
      AvgLossBuffer[seedBar]  = avg_loss;
      SumitRsiBuffer[seedBar] = (avg_loss == 0.0) ? 100.0 : 100.0 - (100.0 / (1.0 + avg_gain / avg_loss));
      start = seedBar + 1;
   }
   else
   {
      // Incremental: check prior state is valid
      if(AvgGainBuffer[start-1] == EMPTY_VALUE || AvgLossBuffer[start-1] == EMPTY_VALUE)
         start = seedBar + 1; // fallback: recompute from seed
   }

   for(int i = start; i < rates_total; i++)
   {
      if(WorkMomentum[i] == EMPTY_VALUE || WorkMomentum[i-1] == EMPTY_VALUE)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i]  = EMPTY_VALUE;
         AvgLossBuffer[i]  = EMPTY_VALUE;
         continue;
      }
      double prev_ag = AvgGainBuffer[i-1];
      double prev_al = AvgLossBuffer[i-1];
      if(prev_ag == EMPTY_VALUE || prev_al == EMPTY_VALUE)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i]  = EMPTY_VALUE;
         AvgLossBuffer[i]  = EMPTY_VALUE;
         continue;
      }
      double change  = WorkMomentum[i] - WorkMomentum[i-1];
      double gain    = (change > 0.0) ? change : 0.0;
      double loss    = (change < 0.0) ? -change : 0.0;
      AvgGainBuffer[i]  = ((prev_ag * (period-1)) + gain) / period;
      AvgLossBuffer[i]  = ((prev_al * (period-1)) + loss) / period;
      SumitRsiBuffer[i] = (AvgLossBuffer[i] == 0.0)
                          ? 100.0
                          : 100.0 - (100.0 / (1.0 + AvgGainBuffer[i] / AvgLossBuffer[i]));
   }
}

//==================================================================
// SUPERTREND HELPER FUNCTIONS (unchanged from original)
//==================================================================

double GetSourcePrice(const MqlRates &bar)
{
   switch(SourcePrice)
   {
      case PRICE_CLOSE:   return bar.close;
      case PRICE_OPEN:    return bar.open;
      case PRICE_HIGH:    return bar.high;
      case PRICE_LOW:     return bar.low;
      case PRICE_MEDIAN:  return (bar.high + bar.low) / 2.0;
      case PRICE_TYPICAL: return (bar.high + bar.low + bar.close) / 3.0;
      default:            return (bar.high + bar.low + bar.close + bar.close) / 4.0;
   }
}

void BuildSuperTrendSeries(const MqlRates &rates_tf[],
                           const double   &atr_tf[],
                           const int       total,
                           double         &line_out[],
                           double         &dir_out[])
{
   if(total <= 0) return;
   for(int i = 0; i < total; i++)
   {
      double atr = atr_tf[i];
      if(atr == EMPTY_VALUE || atr <= 0.0)
      {
         if(i == 0) { line_out[i] = (rates_tf[i].high + rates_tf[i].low) * 0.5; dir_out[i] = 1.0; }
         else       { line_out[i] = line_out[i-1]; dir_out[i] = dir_out[i-1]; }
         continue;
      }
      double srcPrice  = GetSourcePrice(rates_tf[i]);
      double highPrice = TakeWicksIntoAccount ? rates_tf[i].high : rates_tf[i].close;
      double lowPrice  = TakeWicksIntoAccount ? rates_tf[i].low  : rates_tf[i].close;

      double longStop     = srcPrice - Multiplier * atr;
      double prevStop     = (i > 0 && line_out[i-1] != EMPTY_VALUE) ? line_out[i-1] : longStop;
      double longStopPrev = prevStop;

      if(longStop > 0.0)
      {
         bool doji = (rates_tf[i].open == rates_tf[i].close && rates_tf[i].open == rates_tf[i].low && rates_tf[i].open == rates_tf[i].high);
         longStop = doji ? longStopPrev : (lowPrice > longStopPrev ? MathMax(longStop, longStopPrev) : longStop);
      }
      else longStop = longStopPrev;

      double shortStop     = srcPrice + Multiplier * atr;
      double shortStopPrev = prevStop;
      if(shortStop > 0.0)
      {
         bool doji = (rates_tf[i].open == rates_tf[i].close && rates_tf[i].open == rates_tf[i].low && rates_tf[i].open == rates_tf[i].high);
         shortStop = doji ? shortStopPrev : (highPrice < shortStopPrev ? MathMin(shortStop, shortStopPrev) : shortStop);
      }
      else shortStop = shortStopPrev;

      int dir = 1;
      if(i > 0 && dir_out[i-1] != EMPTY_VALUE) dir = (int)dir_out[i-1];
      if(dir == -1 && highPrice > shortStopPrev) dir = 1;
      else if(dir == 1 && lowPrice < longStopPrev) dir = -1;

      line_out[i] = (dir == 1) ? longStop : shortStop;
      dir_out[i]  = dir;
   }
}

//==================================================================
// OnInit
//==================================================================
int OnInit()
{
   // --- INDICATOR_DATA buffers: indices 0-5 (must match plot order) ---
   SetIndexBuffer(0, SumitRsiBuffer,   INDICATOR_DATA);
   SetIndexBuffer(1, SignalMa3Buffer,  INDICATOR_DATA);
   SetIndexBuffer(2, SignalMa11Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, Rsi1hBuffer,      INDICATOR_DATA);
   SetIndexBuffer(4, ScoreBuffer,      INDICATOR_DATA);
   SetIndexBuffer(5, STScoreBuffer,    INDICATOR_DATA);

   // --- INDICATOR_CALCULATIONS buffers: indices 6-17 ---
   SetIndexBuffer(6,  AvgGainBuffer,        INDICATOR_CALCULATIONS);
   SetIndexBuffer(7,  AvgLossBuffer,        INDICATOR_CALCULATIONS);
   SetIndexBuffer(8,  WorkRsi,              INDICATOR_CALCULATIONS);
   SetIndexBuffer(9,  WorkMa3,             INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, WorkMa201,           INDICATOR_CALCULATIONS);
   SetIndexBuffer(11, WorkMomentum,        INDICATOR_CALCULATIONS);
   SetIndexBuffer(12, SuperTrendColorBuffer,INDICATOR_CALCULATIONS);
   SetIndexBuffer(13, ST1DirectionBuffer,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(14, ST2DirectionBuffer,  INDICATOR_CALCULATIONS);
   SetIndexBuffer(15, ST1ScoreBuffer,      INDICATOR_CALCULATIONS);
   SetIndexBuffer(16, ST2ScoreBuffer,      INDICATOR_CALCULATIONS);
   SetIndexBuffer(17, ST2LineCalcBuffer,   INDICATOR_CALCULATIONS);

   // --- Non-series for all buffers ---
   ArraySetAsSeries(SumitRsiBuffer,     false);
   ArraySetAsSeries(SignalMa3Buffer,    false);
   ArraySetAsSeries(SignalMa11Buffer,   false);
   ArraySetAsSeries(Rsi1hBuffer,        false);
   ArraySetAsSeries(ScoreBuffer,        false);
   ArraySetAsSeries(STScoreBuffer,      false);
   ArraySetAsSeries(AvgGainBuffer,      false);
   ArraySetAsSeries(AvgLossBuffer,      false);
   ArraySetAsSeries(WorkRsi,            false);
   ArraySetAsSeries(WorkMa3,            false);
   ArraySetAsSeries(WorkMa201,          false);
   ArraySetAsSeries(WorkMomentum,       false);
   ArraySetAsSeries(SuperTrendColorBuffer, false);
   ArraySetAsSeries(ST1DirectionBuffer, false);
   ArraySetAsSeries(ST2DirectionBuffer, false);
   ArraySetAsSeries(ST1ScoreBuffer,     false);
   ArraySetAsSeries(ST2ScoreBuffer,     false);
   ArraySetAsSeries(ST2LineCalcBuffer,  false);

   // --- Plot draw begin points ---
   int sumit_begin    = SumitSma201Period + SumitRsiPeriod;
   int signal3_begin  = sumit_begin + 3 - 1;
   int signal11_begin = sumit_begin + 11 - 1;
   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, sumit_begin);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, signal3_begin);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, signal11_begin);
   PlotIndexSetInteger(3, PLOT_DRAW_BEGIN, Rsi1hPeriod);
   PlotIndexSetInteger(4, PLOT_DRAW_BEGIN, signal11_begin);
   PlotIndexSetInteger(5, PLOT_DRAW_BEGIN, 0);

   // --- Set EMPTY_VALUE for all data plots so gaps don't draw as zero ---
   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(3, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(4, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(5, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   // --- RSI Score handles ---
   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Rsi1hPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE) { Print("Failed to create RSI handle"); return INIT_FAILED; }

   ma3Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma3Period, 0, MODE_SMA, PRICE_TYPICAL);
   if(ma3Handle == INVALID_HANDLE) { Print("Failed to create MA3 handle"); return INIT_FAILED; }

   ma201Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma201Period, 0, MODE_SMA, PRICE_TYPICAL);
   if(ma201Handle == INVALID_HANDLE) { Print("Failed to create MA201 handle"); return INIT_FAILED; }

   // --- SuperTrend ATR handles ---
   if(SuperTrend1)
   {
      atrHandle1 = iATR(_Symbol, ST1Timeframe, ST1_ATR);
      if(atrHandle1 == INVALID_HANDLE) { Print("Error creating ST1 ATR. Code: ", GetLastError()); return INIT_FAILED; }
   }
   if(SuperTrend2)
   {
      atrHandle2 = iATR(_Symbol, ST2Timeframe, ST2_ATR);
      if(atrHandle2 == INVALID_HANDLE) { Print("Error creating ST2 ATR. Code: ", GetLastError()); return INIT_FAILED; }
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "RSI_Score_SuperTrend_Merged");
   IndicatorSetInteger(INDICATOR_DIGITS, 2);
   IndicatorSetDouble(INDICATOR_MINIMUM, 0.0);
   IndicatorSetDouble(INDICATOR_MAXIMUM, 100.0);

   return INIT_SUCCEEDED;
}

//==================================================================
// OnCalculate
//==================================================================
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   //================================================================
   // PART 1: RSI Score (unchanged logic from original)
   //================================================================
   int min_bars = MathMax(250, SumitSma201Period + SumitRsiPeriod + 11);
   if(rates_total < min_bars) return 0;

   int start = (prev_calculated > 1) ? (prev_calculated - 1) : 0;
   if(start < 0) start = 0;

   if(CopyBuffer(rsiHandle,   0, 0, rates_total, WorkRsi)   != rates_total) return prev_calculated;
   if(CopyBuffer(ma3Handle,   0, 0, rates_total, WorkMa3)   != rates_total) return prev_calculated;
   if(CopyBuffer(ma201Handle, 0, 0, rates_total, WorkMa201) != rates_total) return prev_calculated;

   if(prev_calculated == 0)
   {
      for(int i = 0; i < rates_total; i++)
      {
         SumitRsiBuffer[i]  = EMPTY_VALUE;
         SignalMa3Buffer[i] = EMPTY_VALUE;
         SignalMa11Buffer[i]= EMPTY_VALUE;
         ScoreBuffer[i]     = EMPTY_VALUE;
         AvgGainBuffer[i]   = EMPTY_VALUE;
         AvgLossBuffer[i]   = EMPTY_VALUE;
         STScoreBuffer[i]   = EMPTY_VALUE;
      }
   }

   for(int i = start; i < rates_total; i++)
   {
      Rsi1hBuffer[i] = WorkRsi[i];
      WorkMomentum[i] = (WorkMa3[i] == EMPTY_VALUE || WorkMa201[i] == EMPTY_VALUE)
                        ? EMPTY_VALUE
                        : WorkMa3[i] - WorkMa201[i];
   }

   UpdateRsiWilderBuffer(rates_total, prev_calculated, SumitRsiPeriod);
   // begin offset must account for MA201 warmup + RSI period so SimpleMAOnBuffer seeds correctly
   int rsi_begin = SumitSma201Period + SumitRsiPeriod;
   SimpleMAOnBuffer(rates_total, prev_calculated, rsi_begin, 3,  SumitRsiBuffer, SignalMa3Buffer);
   SimpleMAOnBuffer(rates_total, prev_calculated, rsi_begin, 11, SumitRsiBuffer, SignalMa11Buffer);

   int score_begin = rsi_begin + 11 - 1;
   int score_start = MathMax(start, score_begin);

   for(int i = score_start; i < rates_total && !IsStopped(); i++)
   {
      if(SumitRsiBuffer[i]  == EMPTY_VALUE || SignalMa3Buffer[i] == EMPTY_VALUE ||
         SignalMa11Buffer[i] == EMPTY_VALUE || Rsi1hBuffer[i]    == EMPTY_VALUE)
      { ScoreBuffer[i] = EMPTY_VALUE; continue; }

      int score = 50;
      if(SignalMa3Buffer[i]  > SumitMaSellThreshold) score += 10;
      if(SignalMa11Buffer[i] > SumitMaSellThreshold) score += 10;
      if(SumitRsiBuffer[i]   > SumitMaSellThreshold) score += 10;
      if(Rsi1hBuffer[i]      > Rsi1hSellThreshold)   score += 10;
      if(SignalMa3Buffer[i]  < SumitMaBuyThreshold)  score -= 10;
      if(SignalMa11Buffer[i] < SumitMaBuyThreshold)  score -= 10;
      if(SumitRsiBuffer[i]   < SumitMaBuyThreshold)  score -= 10;
      if(Rsi1hBuffer[i]      < Rsi1hBuyThreshold)    score -= 10;

      ScoreBuffer[i] = MathMax(0, MathMin(100, score));
   }

   //================================================================
   // PART 2: SuperTrend SS (unchanged logic from original)
   // ST total_score: -2 to +2  =>  mapped to 0-100: 50 - score*25
   //   +2 both bullish  => 0
   //   +1 one bullish   => 25
   //    0 neutral       => 50
   //   -1 one bearish   => 75
   //   -2 both bearish  =>100
   //================================================================

   ArraySetAsSeries(time, false);

   // Build ST1
   int    st1_total = 0;
   double st1_line_tf[], st1_dir_tf[];
   if(SuperTrend1)
   {
      int bars1 = Bars(_Symbol, ST1Timeframe);
      if(bars1 > 0)
      {
         MqlRates rates1[];
         double   atr1[];
         ArraySetAsSeries(rates1, false);
         ArraySetAsSeries(atr1,   false);
         int cr1 = CopyRates(_Symbol, ST1Timeframe, 0, bars1, rates1);
         int ca1 = CopyBuffer(atrHandle1, 0, 0, bars1, atr1);
         st1_total = MathMin(cr1, ca1);
         if(st1_total > 0)
         {
            ArrayResize(st1_line_tf, st1_total);
            ArrayResize(st1_dir_tf,  st1_total);
            ArraySetAsSeries(st1_line_tf, false);
            ArraySetAsSeries(st1_dir_tf,  false);
            BuildSuperTrendSeries(rates1, atr1, st1_total, st1_line_tf, st1_dir_tf);
         }
      }
   }

   // Build ST2
   int    st2_total = 0;
   double st2_line_tf[], st2_dir_tf[];
   if(SuperTrend2)
   {
      int bars2 = Bars(_Symbol, ST2Timeframe);
      if(bars2 > 0)
      {
         MqlRates rates2[];
         double   atr2[];
         ArraySetAsSeries(rates2, false);
         ArraySetAsSeries(atr2,   false);
         int cr2 = CopyRates(_Symbol, ST2Timeframe, 0, bars2, rates2);
         int ca2 = CopyBuffer(atrHandle2, 0, 0, bars2, atr2);
         st2_total = MathMin(cr2, ca2);
         if(st2_total > 0)
         {
            ArrayResize(st2_line_tf, st2_total);
            ArrayResize(st2_dir_tf,  st2_total);
            ArraySetAsSeries(st2_line_tf, false);
            ArraySetAsSeries(st2_dir_tf,  false);
            BuildSuperTrendSeries(rates2, atr2, st2_total, st2_line_tf, st2_dir_tf);
         }
      }
   }

   for(int i = start; i < rates_total; i++)
   {
      SuperTrendColorBuffer[i] = 0.0;
      ST1DirectionBuffer[i]    = EMPTY_VALUE;
      ST2DirectionBuffer[i]    = EMPTY_VALUE;
      ST1ScoreBuffer[i]        = EMPTY_VALUE;
      ST2ScoreBuffer[i]        = EMPTY_VALUE;
      ST2LineCalcBuffer[i]     = EMPTY_VALUE;

      double total_score = 0.0;

      // ST1
      if(SuperTrend1 && st1_total > 0)
      {
         int st1_shift = iBarShift(_Symbol, ST1Timeframe, time[i], false);
         int st1_idx   = st1_total - 1 - st1_shift;
         bool mapped   = (st1_shift >= 0 && st1_idx >= 0 && st1_idx < st1_total);
         if(mapped)
         {
            ST1DirectionBuffer[i] = st1_dir_tf[st1_idx];
            ST1ScoreBuffer[i]     = (ST1DirectionBuffer[i] == 1.0) ? 1.0 : -1.0;
         }
         else if(i > 0 && ST1ScoreBuffer[i-1] != EMPTY_VALUE)
         {
            ST1DirectionBuffer[i] = ST1DirectionBuffer[i-1];
            ST1ScoreBuffer[i]     = ST1ScoreBuffer[i-1];
         }
         if(ST1ScoreBuffer[i] == EMPTY_VALUE) { ST1DirectionBuffer[i] = 1.0; ST1ScoreBuffer[i] = 1.0; }
         total_score += ST1ScoreBuffer[i];
      }
      else if(SuperTrend1)
      {
         if(i > 0 && ST1ScoreBuffer[i-1] != EMPTY_VALUE) { ST1DirectionBuffer[i] = ST1DirectionBuffer[i-1]; ST1ScoreBuffer[i] = ST1ScoreBuffer[i-1]; }
         else { ST1DirectionBuffer[i] = 1.0; ST1ScoreBuffer[i] = 1.0; }
         total_score += ST1ScoreBuffer[i];
      }

      // ST2
      if(SuperTrend2 && st2_total > 0)
      {
         int st2_shift = iBarShift(_Symbol, ST2Timeframe, time[i], false);
         int st2_idx   = st2_total - 1 - st2_shift;
         bool mapped   = (st2_shift >= 0 && st2_idx >= 0 && st2_idx < st2_total);
         if(mapped)
         {
            ST2DirectionBuffer[i] = st2_dir_tf[st2_idx];
            ST2LineCalcBuffer[i]  = st2_line_tf[st2_idx];
            ST2ScoreBuffer[i]     = (ST2DirectionBuffer[i] == 1.0) ? 1.0 : -1.0;
         }
         else if(i > 0 && ST2ScoreBuffer[i-1] != EMPTY_VALUE)
         {
            ST2DirectionBuffer[i] = ST2DirectionBuffer[i-1];
            ST2LineCalcBuffer[i]  = ST2LineCalcBuffer[i-1];
            ST2ScoreBuffer[i]     = ST2ScoreBuffer[i-1];
         }
         if(ST2ScoreBuffer[i] == EMPTY_VALUE) { ST2DirectionBuffer[i] = 1.0; ST2ScoreBuffer[i] = 1.0; }
         total_score += ST2ScoreBuffer[i];
      }
      else if(SuperTrend2)
      {
         if(i > 0 && ST2ScoreBuffer[i-1] != EMPTY_VALUE) { ST2DirectionBuffer[i] = ST2DirectionBuffer[i-1]; ST2LineCalcBuffer[i] = ST2LineCalcBuffer[i-1]; ST2ScoreBuffer[i] = ST2ScoreBuffer[i-1]; }
         else { ST2DirectionBuffer[i] = 1.0; ST2ScoreBuffer[i] = 1.0; }
         total_score += ST2ScoreBuffer[i];
      }

      if(SuperTrend1 || SuperTrend2)
         STScoreBuffer[i] = MathMax(0.0, MathMin(100.0, 50.0 - (total_score * 25.0)));
   }

   return rates_total;
}

//==================================================================
// OnDeinit
//==================================================================
void OnDeinit(const int reason)
{
   if(rsiHandle   != INVALID_HANDLE) IndicatorRelease(rsiHandle);
   if(ma3Handle   != INVALID_HANDLE) IndicatorRelease(ma3Handle);
   if(ma201Handle != INVALID_HANDLE) IndicatorRelease(ma201Handle);
   if(atrHandle1  != INVALID_HANDLE) IndicatorRelease(atrHandle1);
   if(atrHandle2  != INVALID_HANDLE) IndicatorRelease(atrHandle2);
}
//+------------------------------------------------------------------+