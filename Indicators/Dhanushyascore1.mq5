//+------------------------------------------------------------------+
//|                                   Dhanushyascore1.mq5              |
//+------------------------------------------------------------------+
#property copyright "Strategy Indicators"
#property version   "1.30"
#property indicator_separate_window
#property indicator_buffers 17
#property indicator_plots   7

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
#property indicator_width2  2

// Plot 3: Signal MA11
#property indicator_label3  "Signal MA11"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrRed
#property indicator_width3  2

// Plot 4: RSI Smooth
#property indicator_label4  "RSI Smooth"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMagenta
#property indicator_width4  2

// Plot 5: Score
#property indicator_label5  "Score"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrNavy
#property indicator_width5  3

// Plot 6: SuperTrend 1 State
#property indicator_label6  "ST1 State"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrDarkOrange
#property indicator_width6  1
#property indicator_style6  STYLE_DOT

// Plot 7: SuperTrend 2 State
#property indicator_label7  "ST2 State"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrBlueViolet
#property indicator_width7  1
#property indicator_style7  STYLE_DOT

// Add horizontal levels
#property indicator_level1 10
#property indicator_level2 30
#property indicator_level3 50
#property indicator_level4 70
#property indicator_level5 90
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT

// Input Parameters
input int Rsi1hPeriod = 51;
input int SumitMaBuyThreshold = 30;
input int SumitMaSellThreshold = 70;
input int Rsi1hBuyThreshold = 40;
input int Rsi1hSellThreshold = 55;
input int SumitSma3Period = 3;          // Sumit SMA3 Period
input int SumitSma201Period = 201;      // Sumit SMA201 Period
input int SumitRsiPeriod = 7;           // RSI period on momentum
input int SumitSma11Period = 11;        // Sumit SMA11 Period

// SuperTrend 1 Inputs
input bool UseSuperTrend1 = true;
input int ST1AtrP = 51;
input double ST1Mult = 1.0;
input ENUM_TIMEFRAMES ST1Timeframe = PERIOD_CURRENT;

// SuperTrend 2 Inputs
input bool UseSuperTrend2 = true;
input int ST2AtrP = 51;
input double ST2Mult = 1.0;
input ENUM_TIMEFRAMES ST2Timeframe = PERIOD_M30;

// Indicator buffers
double SumitRsiBuffer[];
double SignalMa3Buffer[];
double SignalMa11Buffer[];
double Rsi1hBuffer[];
double ScoreBuffer[];
double St1StateBuffer[];
double St2StateBuffer[];

// Internal calculation buffers
double AvgGainBuffer[];
double AvgLossBuffer[];
double WorkRsi[];
double WorkMa3[];
double WorkMa201[];
double WorkMomentum[];
double WorkSt1Buffer[];
double WorkSt2Buffer[];
double St1Temp[];
double St2Temp[];

// Handles
int rsiHandle = INVALID_HANDLE;
int ma3Handle = INVALID_HANDLE;
int ma201Handle = INVALID_HANDLE;
int st1Handle = INVALID_HANDLE;
int st2Handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Seed Wilder averages at the first calculable bar                 |
//+------------------------------------------------------------------+
bool SeedWilderAverages(const double &src[], const int period, double &avg_gain, double &avg_loss)
{
   if(ArraySize(src) <= period)
      return false;

   double gain_sum = 0.0;
   double loss_sum = 0.0;

   for(int i = 1; i <= period; i++)
   {
      if(src[i] == EMPTY_VALUE || src[i - 1] == EMPTY_VALUE)
         return false;

      double change = src[i] - src[i - 1];
      if(change > 0.0)
         gain_sum += change;
      else
         loss_sum -= change;
   }

   avg_gain = gain_sum / period;
   avg_loss = loss_sum / period;
   return true;
}

//+------------------------------------------------------------------+
//| Incremental Wilder RSI on array                                  |
//+------------------------------------------------------------------+
void UpdateRsiWilderBuffer(const int rates_total, const int prev_calculated, const int period)
{
   if(period <= 0 || rates_total <= period)
      return;

   int start = (prev_calculated > 0) ? (prev_calculated - 1) : 0;
   if(start < 0)
      start = 0;

   if(start <= period)
   {
      for(int i = 0; i < MathMin(period, rates_total); i++)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i] = EMPTY_VALUE;
         AvgLossBuffer[i] = EMPTY_VALUE;
      }

      double avg_gain = 0.0;
      double avg_loss = 0.0;
      if(!SeedWilderAverages(WorkMomentum, period, avg_gain, avg_loss))
         return;

      AvgGainBuffer[period] = avg_gain;
      AvgLossBuffer[period] = avg_loss;
      SumitRsiBuffer[period] = (avg_loss == 0.0)
                               ? 100.0
                               : 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));

      start = period + 1;
   }
   else
   {
      // If prior state is unavailable (rare on history reset), rebuild from seed.
      if(AvgGainBuffer[start - 1] == EMPTY_VALUE || AvgLossBuffer[start - 1] == EMPTY_VALUE)
      {
         double avg_gain = 0.0;
         double avg_loss = 0.0;
         if(!SeedWilderAverages(WorkMomentum, period, avg_gain, avg_loss))
            return;

         AvgGainBuffer[period] = avg_gain;
         AvgLossBuffer[period] = avg_loss;
         SumitRsiBuffer[period] = (avg_loss == 0.0)
                                  ? 100.0
                                  : 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));

         if(start < period + 1)
            start = period + 1;
      }
   }

   for(int i = start; i < rates_total; i++)
   {
      if(WorkMomentum[i] == EMPTY_VALUE || WorkMomentum[i - 1] == EMPTY_VALUE)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i] = EMPTY_VALUE;
         AvgLossBuffer[i] = EMPTY_VALUE;
         continue;
      }

      double prev_avg_gain = AvgGainBuffer[i - 1];
      double prev_avg_loss = AvgLossBuffer[i - 1];
      if(prev_avg_gain == EMPTY_VALUE || prev_avg_loss == EMPTY_VALUE)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i] = EMPTY_VALUE;
         AvgLossBuffer[i] = EMPTY_VALUE;
         continue;
      }

      double change = WorkMomentum[i] - WorkMomentum[i - 1];
      double gain = (change > 0.0) ? change : 0.0;
      double loss = (change < 0.0) ? -change : 0.0;

      double avg_gain = ((prev_avg_gain * (period - 1)) + gain) / period;
      double avg_loss = ((prev_avg_loss * (period - 1)) + loss) / period;

      AvgGainBuffer[i] = avg_gain;
      AvgLossBuffer[i] = avg_loss;

      SumitRsiBuffer[i] = (avg_loss == 0.0)
                          ? 100.0
                          : 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));
   }
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   if(Rsi1hPeriod <= 0 || SumitSma3Period <= 0 || SumitSma201Period <= 0 || SumitRsiPeriod <= 0)
   {
      Print("Invalid input parameters");
      return(INIT_FAILED);
   }

   SetIndexBuffer(0, SumitRsiBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, SignalMa3Buffer, INDICATOR_DATA);
   SetIndexBuffer(2, SignalMa11Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, Rsi1hBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, ScoreBuffer, INDICATOR_DATA);
   SetIndexBuffer(5, St1StateBuffer, INDICATOR_DATA);
   SetIndexBuffer(6, St2StateBuffer, INDICATOR_DATA);
   SetIndexBuffer(7, AvgGainBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, AvgLossBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, WorkRsi, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, WorkMa3, INDICATOR_CALCULATIONS);
   SetIndexBuffer(11, WorkMa201, INDICATOR_CALCULATIONS);
   SetIndexBuffer(12, WorkMomentum, INDICATOR_CALCULATIONS);
   SetIndexBuffer(13, WorkSt1Buffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(14, WorkSt2Buffer, INDICATOR_CALCULATIONS); 
   SetIndexBuffer(15, St1Temp, INDICATOR_CALCULATIONS);
   SetIndexBuffer(16, St2Temp, INDICATOR_CALCULATIONS);

   // Use non-series indexing in calculations (oldest -> newest).
   ArraySetAsSeries(SumitRsiBuffer, false);
   ArraySetAsSeries(SignalMa3Buffer, false);
   ArraySetAsSeries(SignalMa11Buffer, false);
   ArraySetAsSeries(Rsi1hBuffer, false);
   ArraySetAsSeries(ScoreBuffer, false);
   ArraySetAsSeries(St1StateBuffer, false);
   ArraySetAsSeries(St2StateBuffer, false);
   ArraySetAsSeries(AvgGainBuffer, false);
   ArraySetAsSeries(AvgLossBuffer, false);
   ArraySetAsSeries(WorkRsi, false);
   ArraySetAsSeries(WorkMa3, false);
   ArraySetAsSeries(WorkMa201, false);
   ArraySetAsSeries(WorkMomentum, false);
   ArraySetAsSeries(WorkSt1Buffer, false);
   ArraySetAsSeries(WorkSt2Buffer, false);
   ArraySetAsSeries(St1Temp, false);
   ArraySetAsSeries(St2Temp, false);

   int sumit_begin = SumitSma201Period + SumitRsiPeriod;
   int signal3_begin = sumit_begin + SumitSma3Period - 1;
   int signal11_begin = sumit_begin + SumitSma11Period - 1;

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, sumit_begin);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, signal3_begin);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, signal11_begin);
   PlotIndexSetInteger(3, PLOT_DRAW_BEGIN, Rsi1hPeriod);
   PlotIndexSetInteger(4, PLOT_DRAW_BEGIN, signal11_begin);
   PlotIndexSetInteger(5, PLOT_DRAW_BEGIN, ST1AtrP);
   PlotIndexSetInteger(6, PLOT_DRAW_BEGIN, ST2AtrP);

   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Rsi1hPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create RSI indicator");
      return(INIT_FAILED);
   }

   ma3Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma3Period, 0, MODE_SMA, PRICE_TYPICAL);
   ma201Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma201Period, 0, MODE_SMA, PRICE_TYPICAL);
   if(ma3Handle == INVALID_HANDLE || ma201Handle == INVALID_HANDLE)
   {
      Print("Failed to create SMA indicators");
      return(INIT_FAILED);
   }

   if(UseSuperTrend1)
   {
      st1Handle = iCustom(_Symbol, ST1Timeframe, "SuperTrend", ST1AtrP, ST1Mult);
      if(st1Handle == INVALID_HANDLE)
      {
         Print("Failed to create SuperTrend 1 indicator. Ensure 'SuperTrend.ex5' is in the Indicators folder.");
         return(INIT_FAILED);
      }
   }

   if(UseSuperTrend2)
   {
      st2Handle = iCustom(_Symbol, ST2Timeframe, "SuperTrend", ST2AtrP, ST2Mult);
      if(st2Handle == INVALID_HANDLE)
      {
         Print("Failed to create SuperTrend 2 indicator. Ensure 'SuperTrend.ex5' is in the Indicators folder.");
         return(INIT_FAILED);
      }
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "Dhanushya_Score");
   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   // Ensure we have enough data to calculate
   int min_bars = MathMax(SumitSma201Period + SumitRsiPeriod + SumitSma11Period, 10);
   if(rates_total < min_bars) 
      return(0);

   // 1. Initialize buffers on first run
   if(prev_calculated == 0)
   {
      ArrayInitialize(SumitRsiBuffer, EMPTY_VALUE);
      ArrayInitialize(SignalMa3Buffer, EMPTY_VALUE);
      ArrayInitialize(SignalMa11Buffer, EMPTY_VALUE);
      ArrayInitialize(Rsi1hBuffer, EMPTY_VALUE);
      ArrayInitialize(ScoreBuffer, EMPTY_VALUE);
      ArrayInitialize(St1StateBuffer, EMPTY_VALUE);
      ArrayInitialize(St2StateBuffer, EMPTY_VALUE);
      ArrayInitialize(WorkSt1Buffer, EMPTY_VALUE);
      ArrayInitialize(WorkSt2Buffer, EMPTY_VALUE);
   }

   // 2. Fetch Core Data (Allow partial copies to prevent blank screen)
   if(CopyBuffer(rsiHandle, 0, 0, rates_total, WorkRsi) <= 0) return(prev_calculated);
   if(CopyBuffer(ma3Handle, 0, 0, rates_total, WorkMa3) <= 0) return(prev_calculated);
   if(CopyBuffer(ma201Handle, 0, 0, rates_total, WorkMa201) <= 0) return(prev_calculated);

   // 3. Fetch SuperTrend Data
   int st1_total = 0, st2_total = 0;
   if(UseSuperTrend1 && st1Handle != INVALID_HANDLE)
   {
      st1_total = CopyBuffer(st1Handle, 2, 0, rates_total, St1Temp);
      // Note: St1Temp is NOT series. Index 0 is oldest.
   }
   if(UseSuperTrend2 && st2Handle != INVALID_HANDLE)
   {
      st2_total = CopyBuffer(st2Handle, 2, 0, rates_total, St2Temp);
   }

   int start = (prev_calculated > 0) ? prev_calculated - 1 : 0;

   // 4. Primary Calculation Loop
   for(int i = start; i < rates_total; i++)
   {
      Rsi1hBuffer[i] = WorkRsi[i];
      
      if(WorkMa3[i] != EMPTY_VALUE && WorkMa201[i] != EMPTY_VALUE)
         WorkMomentum[i] = WorkMa3[i] - WorkMa201[i];
      else
         WorkMomentum[i] = EMPTY_VALUE;
      
      // SuperTrend 1 Mapping
      if(UseSuperTrend1 && st1_total > 0)
      {
         int shift = iBarShift(_Symbol, ST1Timeframe, time[i]);
         // iBarShift returns index where 0 is newest. Convert to our non-series index.
         int internal_idx = st1_total - 1 - shift;
         if(shift >= 0 && internal_idx >= 0 && internal_idx < st1_total)
         {
            WorkSt1Buffer[i] = St1Temp[internal_idx];
            St1StateBuffer[i] = (WorkSt1Buffer[i] == -1) ? 100.0 : 0.0;
         }
         else WorkSt1Buffer[i] = EMPTY_VALUE;
      }
      else St1StateBuffer[i] = EMPTY_VALUE;

      // SuperTrend 2 Mapping
      if(UseSuperTrend2 && st2_total > 0)
      {
         int shift = iBarShift(_Symbol, ST2Timeframe, time[i]);
         int internal_idx = st2_total - 1 - shift;
         if(shift >= 0 && internal_idx >= 0 && internal_idx < st2_total)
         {
            WorkSt2Buffer[i] = St2Temp[internal_idx];
            St2StateBuffer[i] = (WorkSt2Buffer[i] == -1) ? 100.0 : 0.0;
         }
         else WorkSt2Buffer[i] = EMPTY_VALUE;
      }
      else St2StateBuffer[i] = EMPTY_VALUE;
   }

   // 5. Technical Indicator Logic
   UpdateRsiWilderBuffer(rates_total, prev_calculated, SumitRsiPeriod);
   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, SumitSma3Period, SumitRsiBuffer, SignalMa3Buffer);
   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, SumitSma11Period, SumitRsiBuffer, SignalMa11Buffer);

   int score_begin = MathMax(SumitSma201Period + SumitRsiPeriod + SumitSma11Period - 1, 
                             MathMax(ST1AtrP, ST2AtrP));
   int score_start = MathMax(start, score_begin);

   // 6. Final Scoring Loop
   for(int i = score_start; i < rates_total && !IsStopped(); i++)
   {
      // If core data is missing, skip score but keep the line continuous
      if(SumitRsiBuffer[i] == EMPTY_VALUE || SignalMa3Buffer[i] == EMPTY_VALUE || SignalMa11Buffer[i] == EMPTY_VALUE)
      {
         ScoreBuffer[i] = EMPTY_VALUE;
         continue;
      }

      int score = 50;
      
      if(SignalMa3Buffer[i] > SumitMaSellThreshold) score += 10;
      if(SignalMa11Buffer[i] > SumitMaSellThreshold) score += 10;
      if(SumitRsiBuffer[i] > SumitMaSellThreshold) score += 10;
      if(Rsi1hBuffer[i] > Rsi1hSellThreshold) score += 10;

      if(SignalMa3Buffer[i] < SumitMaBuyThreshold) score -= 10;
      if(SignalMa11Buffer[i] < SumitMaBuyThreshold) score -= 10;
      if(SumitRsiBuffer[i] < SumitMaBuyThreshold) score -= 10;
      if(Rsi1hBuffer[i] < Rsi1hBuyThreshold) score -= 10;

      // SuperTrend 1 Score Contribution
      if(UseSuperTrend1 && WorkSt1Buffer[i] != EMPTY_VALUE)
      {
         if(WorkSt1Buffer[i] == -1) score += 10; // Bearish
         else score -= 10; // Bullish
      }

      // SuperTrend 2 Score Contribution
      if(UseSuperTrend2 && WorkSt2Buffer[i] != EMPTY_VALUE)
      {
         if(WorkSt2Buffer[i] == -1) score += 10; // Bearish
         else score -= 10; // Bullish
      }

      // Clamp score to valid range
      if(score > 100) score = 100;
      if(score < 0) score = 0;

      ScoreBuffer[i] = score;
   }

   return(rates_total);
}

//+------------------------------------------------------------------+
//| Indicator deinitialization function                              |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(rsiHandle != INVALID_HANDLE)
      IndicatorRelease(rsiHandle);
   if(ma3Handle != INVALID_HANDLE)
      IndicatorRelease(ma3Handle);
   if(ma201Handle != INVALID_HANDLE)
      IndicatorRelease(ma201Handle);
   if(st1Handle != INVALID_HANDLE)
      IndicatorRelease(st1Handle);
   if(st2Handle != INVALID_HANDLE)
      IndicatorRelease(st2Handle);
}
//+------------------------------------------------------------------+
