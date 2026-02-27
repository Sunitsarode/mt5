//+------------------------------------------------------------------+
//| Dhanushyascore.mq5                                               |
//| Stable 0-100 Sumit RSI Score Indicator                           |
//+------------------------------------------------------------------+
#property copyright "Strategy Indicators"
#property version   "2.03"
#property strict
#property indicator_separate_window
#property indicator_buffers 11
#property indicator_plots   5

#include <MovingAverages.mqh>

#property indicator_label1  "Sumit RSI"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrCyan
#property indicator_width1  2

#property indicator_label2  "Signal MA3"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrLime
#property indicator_width2  2

#property indicator_label3  "Signal MA11"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrRed
#property indicator_width3  2

#property indicator_label4  "RSI Smooth"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMagenta
#property indicator_width4  2

#property indicator_label5  "Score"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrNavy
#property indicator_width5  3

#property indicator_level1  10
#property indicator_level2  30
#property indicator_level3  50
#property indicator_level4  70
#property indicator_level5  90
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT

input int Rsi1hPeriod          = 51;
input int SumitMaBuyThreshold  = 30;
input int SumitMaSellThreshold = 70;
input int Rsi1hBuyThreshold    = 40;
input int Rsi1hSellThreshold   = 55;
input int SumitSma3Period      = 3;
input int SumitSma201Period    = 201;
input int SumitRsiPeriod       = 7;
input int SumitSma11Period     = 11;
input bool DebugPrints         = false;

double SumitRsiBuffer[];
double SignalMa3Buffer[];
double SignalMa11Buffer[];
double RsiSmoothBuffer[];
double ScoreBuffer[];

double AvgGainBuffer[];
double AvgLossBuffer[];
double WorkRsi[];
double WorkMa3[];
double WorkMa201[];
double WorkMomentum[];

int rsiHandle = INVALID_HANDLE;
int ma3Handle = INVALID_HANDLE;
int ma201Handle = INVALID_HANDLE;

double ClampPlotValue(const double value)
{
   if(value == EMPTY_VALUE || !MathIsValidNumber(value))
      return EMPTY_VALUE;
   if(value < 0.0)
      return 0.0;
   if(value > 100.0)
      return 100.0;
   return value;
}

double ClampScoreValue(const double value)
{
   if(value == EMPTY_VALUE || !MathIsValidNumber(value))
      return 50.0;
   if(value < 0.0)
      return 0.0;
   if(value > 100.0)
      return 100.0;
   return value;
}

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
      if(!MathIsValidNumber(src[i]) || !MathIsValidNumber(src[i - 1]))
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
      double seed = (avg_loss == 0.0) ? 100.0 : 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));
      SumitRsiBuffer[period] = ClampPlotValue(seed);
      start = period + 1;
   }
   else
   {
      if(AvgGainBuffer[start - 1] == EMPTY_VALUE || AvgLossBuffer[start - 1] == EMPTY_VALUE)
      {
         double avg_gain = 0.0;
         double avg_loss = 0.0;
         if(!SeedWilderAverages(WorkMomentum, period, avg_gain, avg_loss))
            return;

         AvgGainBuffer[period] = avg_gain;
         AvgLossBuffer[period] = avg_loss;
         double seed = (avg_loss == 0.0) ? 100.0 : 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));
         SumitRsiBuffer[period] = ClampPlotValue(seed);

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

      if(!MathIsValidNumber(prev_avg_gain) || !MathIsValidNumber(prev_avg_loss))
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

      double rsi = (avg_loss == 0.0) ? 100.0 : 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));
      SumitRsiBuffer[i] = ClampPlotValue(rsi);
   }
}

int OnInit()
{
   SetIndexBuffer(0, SumitRsiBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, SignalMa3Buffer, INDICATOR_DATA);
   SetIndexBuffer(2, SignalMa11Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, RsiSmoothBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, ScoreBuffer, INDICATOR_DATA);

   SetIndexBuffer(5, AvgGainBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(6, AvgLossBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, WorkRsi, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, WorkMa3, INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, WorkMa201, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, WorkMomentum, INDICATOR_CALCULATIONS);

   ArraySetAsSeries(SumitRsiBuffer, false);
   ArraySetAsSeries(SignalMa3Buffer, false);
   ArraySetAsSeries(SignalMa11Buffer, false);
   ArraySetAsSeries(RsiSmoothBuffer, false);
   ArraySetAsSeries(ScoreBuffer, false);
   ArraySetAsSeries(AvgGainBuffer, false);
   ArraySetAsSeries(AvgLossBuffer, false);
   ArraySetAsSeries(WorkRsi, false);
   ArraySetAsSeries(WorkMa3, false);
   ArraySetAsSeries(WorkMa201, false);
   ArraySetAsSeries(WorkMomentum, false);

   int sumit_begin = SumitSma201Period + SumitRsiPeriod;
   int signal3_begin = sumit_begin + SumitSma3Period - 1;
   int signal11_begin = sumit_begin + SumitSma11Period - 1;

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, sumit_begin);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, signal3_begin);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, signal11_begin);
   PlotIndexSetInteger(3, PLOT_DRAW_BEGIN, Rsi1hPeriod);
   PlotIndexSetInteger(4, PLOT_DRAW_BEGIN, signal11_begin);

   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Rsi1hPeriod, PRICE_CLOSE);
   ma3Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma3Period, 0, MODE_SMA, PRICE_TYPICAL);
   ma201Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma201Period, 0, MODE_SMA, PRICE_TYPICAL);

   if(rsiHandle == INVALID_HANDLE || ma3Handle == INVALID_HANDLE || ma201Handle == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles.");
      return(INIT_FAILED);
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "Dhanushya Score Stable");
   IndicatorSetInteger(INDICATOR_DIGITS, 2);

   if(DebugPrints)
      Print("Dhanushya Score initialized.");

   return(INIT_SUCCEEDED);
}

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
   int min_bars = MathMax(250, SumitSma201Period + SumitRsiPeriod + SumitSma11Period);
   if(rates_total < min_bars)
      return(0);

   int start = (prev_calculated > 1) ? (prev_calculated - 1) : 0;
   if(start < 0)
      start = 0;

   if(CopyBuffer(rsiHandle, 0, 0, rates_total, WorkRsi) != rates_total)
      return(prev_calculated);
   if(CopyBuffer(ma3Handle, 0, 0, rates_total, WorkMa3) != rates_total)
      return(prev_calculated);
   if(CopyBuffer(ma201Handle, 0, 0, rates_total, WorkMa201) != rates_total)
      return(prev_calculated);

   if(prev_calculated == 0)
   {
      ArrayInitialize(SumitRsiBuffer, EMPTY_VALUE);
      ArrayInitialize(SignalMa3Buffer, EMPTY_VALUE);
      ArrayInitialize(SignalMa11Buffer, EMPTY_VALUE);
      ArrayInitialize(RsiSmoothBuffer, EMPTY_VALUE);
      ArrayInitialize(ScoreBuffer, EMPTY_VALUE);
      ArrayInitialize(AvgGainBuffer, EMPTY_VALUE);
      ArrayInitialize(AvgLossBuffer, EMPTY_VALUE);
      ArrayInitialize(WorkMomentum, EMPTY_VALUE);
   }

   for(int i = start; i < rates_total; i++)
   {
      RsiSmoothBuffer[i] = ClampPlotValue(WorkRsi[i]);

      if(WorkMa3[i] == EMPTY_VALUE || WorkMa201[i] == EMPTY_VALUE ||
         !MathIsValidNumber(WorkMa3[i]) || !MathIsValidNumber(WorkMa201[i]))
      {
         WorkMomentum[i] = EMPTY_VALUE;
      }
      else
      {
         WorkMomentum[i] = WorkMa3[i] - WorkMa201[i];
      }
   }

   UpdateRsiWilderBuffer(rates_total, prev_calculated, SumitRsiPeriod);

   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, SumitSma3Period, SumitRsiBuffer, SignalMa3Buffer);
   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, SumitSma11Period, SumitRsiBuffer, SignalMa11Buffer);

   for(int i = start; i < rates_total; i++)
   {
      SignalMa3Buffer[i] = ClampPlotValue(SignalMa3Buffer[i]);
      SignalMa11Buffer[i] = ClampPlotValue(SignalMa11Buffer[i]);
   }

   int score_begin = SumitSma201Period + SumitRsiPeriod + SumitSma11Period - 1;
   int score_start = MathMax(start, score_begin);

   for(int i = score_start; i < rates_total; i++)
   {
      if(SumitRsiBuffer[i] == EMPTY_VALUE ||
         SignalMa3Buffer[i] == EMPTY_VALUE ||
         SignalMa11Buffer[i] == EMPTY_VALUE ||
         RsiSmoothBuffer[i] == EMPTY_VALUE)
      {
         ScoreBuffer[i] = EMPTY_VALUE;
         continue;
      }

      int score = 50;
      if(SignalMa3Buffer[i] > SumitMaSellThreshold) score += 10;
      if(SignalMa11Buffer[i] > SumitMaSellThreshold) score += 10;
      if(SumitRsiBuffer[i] > SumitMaSellThreshold) score += 10;
      if(RsiSmoothBuffer[i] > Rsi1hSellThreshold) score += 10;

      if(SignalMa3Buffer[i] < SumitMaBuyThreshold) score -= 10;
      if(SignalMa11Buffer[i] < SumitMaBuyThreshold) score -= 10;
      if(SumitRsiBuffer[i] < SumitMaBuyThreshold) score -= 10;
      if(RsiSmoothBuffer[i] < Rsi1hBuyThreshold) score -= 10;

      ScoreBuffer[i] = ClampScoreValue((double)score);
   }

   return(rates_total);
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
