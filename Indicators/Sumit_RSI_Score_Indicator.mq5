//+------------------------------------------------------------------+
//|                                   Sumit_RSI_Score_Trend.mq5      |
//+------------------------------------------------------------------+
#property copyright "Strategy Indicators"
#property version   "1.20"
#property indicator_separate_window
#property indicator_buffers 11
#property indicator_plots   5

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

// Indicator buffers
double SumitRsiBuffer[];
double SignalMa3Buffer[];
double SignalMa11Buffer[];
double Rsi1hBuffer[];
double ScoreBuffer[];

// Internal calculation buffers
double AvgGainBuffer[];
double AvgLossBuffer[];
double WorkRsi[];
double WorkMa3[];
double WorkMa201[];
double WorkMomentum[];

// Handles
int rsiHandle = INVALID_HANDLE;
int ma3Handle = INVALID_HANDLE;
int ma201Handle = INVALID_HANDLE;

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
   SetIndexBuffer(0, SumitRsiBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, SignalMa3Buffer, INDICATOR_DATA);
   SetIndexBuffer(2, SignalMa11Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, Rsi1hBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, ScoreBuffer, INDICATOR_DATA);
   SetIndexBuffer(5, AvgGainBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, AvgLossBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, WorkRsi, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, WorkMa3, INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, WorkMa201, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, WorkMomentum, INDICATOR_CALCULATIONS);

   // Use non-series indexing in calculations (oldest -> newest).
   ArraySetAsSeries(SumitRsiBuffer, false);
   ArraySetAsSeries(SignalMa3Buffer, false);
   ArraySetAsSeries(SignalMa11Buffer, false);
   ArraySetAsSeries(Rsi1hBuffer, false);
   ArraySetAsSeries(ScoreBuffer, false);
   ArraySetAsSeries(AvgGainBuffer, false);
   ArraySetAsSeries(AvgLossBuffer, false);
   ArraySetAsSeries(WorkRsi, false);
   ArraySetAsSeries(WorkMa3, false);
   ArraySetAsSeries(WorkMa201, false);
   ArraySetAsSeries(WorkMomentum, false);

   int sumit_begin = SumitSma201Period + SumitRsiPeriod;
   int signal3_begin = sumit_begin + 3 - 1;
   int signal11_begin = sumit_begin + 11 - 1;

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, sumit_begin);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, signal3_begin);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, signal11_begin);
   PlotIndexSetInteger(3, PLOT_DRAW_BEGIN, Rsi1hPeriod);
   PlotIndexSetInteger(4, PLOT_DRAW_BEGIN, signal11_begin);

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

   IndicatorSetString(INDICATOR_SHORTNAME, "Sumit_RSI_Score_Trend");
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
   int min_bars = MathMax(250, SumitSma201Period + SumitRsiPeriod + 11);
   if(rates_total < min_bars)
      return(0);

   int start = (prev_calculated > 0) ? (prev_calculated - 1) : 0;
   if(start < 0)
      start = 0;

   // Incremental copy logic
   int to_copy = rates_total - prev_calculated;
   if(to_copy > 0)
   {
      if(prev_calculated > 0) to_copy++; // Overlap one bar for safety
      
      double tempBuffer[];
      // Copy RSI
      if(CopyBuffer(rsiHandle, 0, 0, to_copy, tempBuffer) == to_copy)
         ArrayCopy(WorkRsi, tempBuffer, rates_total - to_copy, 0, to_copy);
      // Copy MA3
      if(CopyBuffer(ma3Handle, 0, 0, to_copy, tempBuffer) == to_copy)
         ArrayCopy(WorkMa3, tempBuffer, rates_total - to_copy, 0, to_copy);
      // Copy MA201
      if(CopyBuffer(ma201Handle, 0, 0, to_copy, tempBuffer) == to_copy)
         ArrayCopy(WorkMa201, tempBuffer, rates_total - to_copy, 0, to_copy);
   }

   if(prev_calculated == 0)
   {
      for(int i = 0; i < rates_total; i++)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         SignalMa3Buffer[i] = EMPTY_VALUE;
         SignalMa11Buffer[i] = EMPTY_VALUE;
         ScoreBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i] = EMPTY_VALUE;
         AvgLossBuffer[i] = EMPTY_VALUE;
      }
   }

   for(int i = start; i < rates_total; i++)
   {
      Rsi1hBuffer[i] = WorkRsi[i];
      WorkMomentum[i] = WorkMa3[i] - WorkMa201[i];
   }

   UpdateRsiWilderBuffer(rates_total, prev_calculated, SumitRsiPeriod);

   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, 3, SumitRsiBuffer, SignalMa3Buffer);
   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, 11, SumitRsiBuffer, SignalMa11Buffer);

   int score_begin = SumitRsiPeriod + 11 - 1;
   int score_start = MathMax(start, score_begin);

   for(int i = score_start; i < rates_total && !IsStopped(); i++)
   {
      if(SumitRsiBuffer[i] == EMPTY_VALUE ||
         SignalMa3Buffer[i] == EMPTY_VALUE ||
         SignalMa11Buffer[i] == EMPTY_VALUE ||
         Rsi1hBuffer[i] == EMPTY_VALUE)
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
}
//+------------------------------------------------------------------+
