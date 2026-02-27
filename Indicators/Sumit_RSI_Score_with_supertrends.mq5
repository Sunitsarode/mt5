//+------------------------------------------------------------------+
//|                  Sumit_RSI_Score_with_supertrends.mq5            |
//| Deterministic combined indicator: Sumit score + ST1 + ST2        |
//+------------------------------------------------------------------+
#property copyright "Strategy Indicators"
#property version   "2.00"
#property indicator_separate_window
#property indicator_buffers 16
#property indicator_plots   8

#include <MovingAverages.mqh>

// Plot 1: Sumit RSI
#property indicator_label1  "Sumit RSI"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrCyan
#property indicator_width1  1

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

// Plot 4: RSI Smooth
#property indicator_label4  "RSI Smooth"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMagenta
#property indicator_width4  1

// Plot 5: Final Composite Score (buffer index 4)
#property indicator_label5  "Final Score"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrNavy
#property indicator_width5  2

// Plot 6: ST1 mapped score (e.g., 98/2/50)
#property indicator_label6  "ST1 Score"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrDarkGreen
#property indicator_width6  1

// Plot 7: ST2 mapped score (e.g., 95/5/50)
#property indicator_label7  "ST2 Score"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrSaddleBrown
#property indicator_width7  1

// Plot 8: Raw Sumit score
#property indicator_label8  "Sumit Raw Score"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrSteelBlue
#property indicator_width8  1

// Horizontal levels
#property indicator_level1 10
#property indicator_level2 30
#property indicator_level3 50
#property indicator_level4 70
#property indicator_level5 90
#property indicator_levelcolor clrGray
#property indicator_levelstyle STYLE_DOT

// Sumit inputs
input int Rsi1hPeriod = 51;
input int SumitMaBuyThreshold = 30;
input int SumitMaSellThreshold = 70;
input int Rsi1hBuyThreshold = 40;
input int Rsi1hSellThreshold = 55;
input int SumitSma3Period = 3;
input int SumitSma201Period = 201;
input int SumitRsiPeriod = 7;

// SuperTrend inputs
input bool UseSuperTrend1 = true;
input int ST1AtrP = 51;
input double ST1Mult = 1;
input ENUM_TIMEFRAMES ST1Timeframe = PERIOD_CURRENT;
input double ST1BullScore = 98.0;
input double ST1BearScore = 2.0;
input double ST1NeutralScore = 50.0;

input bool UseSuperTrend2 = true;
input int ST2AtrP = 51;
input double ST2Mult = 1;
input ENUM_TIMEFRAMES ST2Timeframe = PERIOD_M30;
input double ST2BullScore = 95.0;
input double ST2BearScore = 5.0;
input double ST2NeutralScore = 50.0;

input ENUM_APPLIED_PRICE SupertrendSourcePrice = PRICE_MEDIAN;
input bool SupertrendTakeWicksIntoAccount = true;

// Weighted combine
input double WeightSumit = 0.60;
input double WeightST1 = 0.20;
input double WeightST2 = 0.20;

// Indicator buffers (plots)
double SumitRsiBuffer[];
double SignalMa3Buffer[];
double SignalMa11Buffer[];
double Rsi1hBuffer[];
double FinalScoreBuffer[];      // Buffer index 4 (EA-friendly)
double ST1ScoreBuffer[];
double ST2ScoreBuffer[];
double SumitRawScoreBuffer[];

// Internal calculation buffers
double AvgGainBuffer[];
double AvgLossBuffer[];
double WorkRsi[];
double WorkMa3[];
double WorkMa201[];
double WorkMomentum[];
double ST1DirBuffer[];
double ST2DirBuffer[];

// Handles
int rsiHandle = INVALID_HANDLE;
int ma3Handle = INVALID_HANDLE;
int ma201Handle = INVALID_HANDLE;
int supertrend1Handle = INVALID_HANDLE;
int supertrend2Handle = INVALID_HANDLE;

double ClampScore(const double value)
{
   if(value < 0.0)
      return 0.0;
   if(value > 100.0)
      return 100.0;
   return value;
}

double NormalizeWeight(const double w)
{
   if(w <= 0.0)
      return 0.0;
   return w;
}

double DirectionToScore(const int dir, const double bull, const double bear, const double neutral)
{
   if(dir > 0)
      return ClampScore(bull);
   if(dir < 0)
      return ClampScore(bear);
   return ClampScore(neutral);
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
      SumitRsiBuffer[period] = (avg_loss == 0.0)
                               ? 100.0
                               : 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));
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

bool FillSuperTrendMappedScores(const int handle,
                                const ENUM_TIMEFRAMES timeframe,
                                const datetime &base_time[],
                                const int rates_total,
                                const int start,
                                const double bull_score,
                                const double bear_score,
                                const double neutral_score,
                                double &mapped_score_buffer[],
                                double &dir_buffer[])
{
   if(handle == INVALID_HANDLE)
      return false;
   if(rates_total <= 0)
      return false;

   int tf_sec = PeriodSeconds(timeframe);
   if(tf_sec <= 0)
      tf_sec = PeriodSeconds(PERIOD_CURRENT);
   if(tf_sec <= 0)
      tf_sec = 60;

   datetime from_time = base_time[0] - (datetime)(2 * tf_sec);
   datetime to_time = base_time[rates_total - 1];

   datetime st_time[];
   double st_dir[];
   ArraySetAsSeries(st_time, false);
   ArraySetAsSeries(st_dir, false);

   int copied_time = CopyTime(_Symbol, timeframe, from_time, to_time, st_time);
   int copied_dir = CopyBuffer(handle, 2, from_time, to_time, st_dir);
   if(copied_time <= 0 || copied_dir <= 0)
      return false;

   int count = MathMin(copied_time, copied_dir);
   if(count <= 0)
      return false;

   // Defensive: enforce ascending time order for deterministic pointer mapping.
   if(count > 1 && st_time[0] > st_time[count - 1])
   {
      for(int l = 0, r = count - 1; l < r; l++, r--)
      {
         datetime t = st_time[l];
         st_time[l] = st_time[r];
         st_time[r] = t;

         double v = st_dir[l];
         st_dir[l] = st_dir[r];
         st_dir[r] = v;
      }
   }

   int j = 0;
   while(j + 1 < count && st_time[j + 1] <= base_time[start])
      j++;

   for(int i = start; i < rates_total; i++)
   {
      while(j + 1 < count && st_time[j + 1] <= base_time[i])
         j++;

      int dir = 0;
      if(st_time[j] <= base_time[i] && st_dir[j] != EMPTY_VALUE)
      {
         if(st_dir[j] > 0.0)
            dir = 1;
         else if(st_dir[j] < 0.0)
            dir = -1;
      }

      dir_buffer[i] = dir;
      mapped_score_buffer[i] = DirectionToScore(dir, bull_score, bear_score, neutral_score);
   }

   return true;
}

int OnInit()
{
   SetIndexBuffer(0, SumitRsiBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, SignalMa3Buffer, INDICATOR_DATA);
   SetIndexBuffer(2, SignalMa11Buffer, INDICATOR_DATA);
   SetIndexBuffer(3, Rsi1hBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, FinalScoreBuffer, INDICATOR_DATA);
   SetIndexBuffer(5, ST1ScoreBuffer, INDICATOR_DATA);
   SetIndexBuffer(6, ST2ScoreBuffer, INDICATOR_DATA);
   SetIndexBuffer(7, SumitRawScoreBuffer, INDICATOR_DATA);

   SetIndexBuffer(8, AvgGainBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, AvgLossBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, WorkRsi, INDICATOR_CALCULATIONS);
   SetIndexBuffer(11, WorkMa3, INDICATOR_CALCULATIONS);
   SetIndexBuffer(12, WorkMa201, INDICATOR_CALCULATIONS);
   SetIndexBuffer(13, WorkMomentum, INDICATOR_CALCULATIONS);
   SetIndexBuffer(14, ST1DirBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(15, ST2DirBuffer, INDICATOR_CALCULATIONS);

   ArraySetAsSeries(SumitRsiBuffer, false);
   ArraySetAsSeries(SignalMa3Buffer, false);
   ArraySetAsSeries(SignalMa11Buffer, false);
   ArraySetAsSeries(Rsi1hBuffer, false);
   ArraySetAsSeries(FinalScoreBuffer, false);
   ArraySetAsSeries(ST1ScoreBuffer, false);
   ArraySetAsSeries(ST2ScoreBuffer, false);
   ArraySetAsSeries(SumitRawScoreBuffer, false);
   ArraySetAsSeries(AvgGainBuffer, false);
   ArraySetAsSeries(AvgLossBuffer, false);
   ArraySetAsSeries(WorkRsi, false);
   ArraySetAsSeries(WorkMa3, false);
   ArraySetAsSeries(WorkMa201, false);
   ArraySetAsSeries(WorkMomentum, false);
   ArraySetAsSeries(ST1DirBuffer, false);
   ArraySetAsSeries(ST2DirBuffer, false);

   int sumit_begin = SumitSma201Period + SumitRsiPeriod;
   int signal3_begin = sumit_begin + 3 - 1;
   int signal11_begin = sumit_begin + 11 - 1;
   int score_begin = SumitSma201Period + SumitRsiPeriod + 11 - 1;

   PlotIndexSetInteger(0, PLOT_DRAW_BEGIN, sumit_begin);
   PlotIndexSetInteger(1, PLOT_DRAW_BEGIN, signal3_begin);
   PlotIndexSetInteger(2, PLOT_DRAW_BEGIN, signal11_begin);
   PlotIndexSetInteger(3, PLOT_DRAW_BEGIN, Rsi1hPeriod);
   PlotIndexSetInteger(4, PLOT_DRAW_BEGIN, score_begin);
   PlotIndexSetInteger(5, PLOT_DRAW_BEGIN, 0);
   PlotIndexSetInteger(6, PLOT_DRAW_BEGIN, 0);
   PlotIndexSetInteger(7, PLOT_DRAW_BEGIN, score_begin);

   rsiHandle = iRSI(_Symbol, PERIOD_CURRENT, Rsi1hPeriod, PRICE_CLOSE);
   if(rsiHandle == INVALID_HANDLE)
   {
      Print("Failed to create RSI handle.");
      return(INIT_FAILED);
   }

   ma3Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma3Period, 0, MODE_SMA, PRICE_TYPICAL);
   ma201Handle = iMA(_Symbol, PERIOD_CURRENT, SumitSma201Period, 0, MODE_SMA, PRICE_TYPICAL);
   if(ma3Handle == INVALID_HANDLE || ma201Handle == INVALID_HANDLE)
   {
      Print("Failed to create MA handles.");
      return(INIT_FAILED);
   }

   if(UseSuperTrend1)
   {
      supertrend1Handle = iCustom(_Symbol,
                                  ST1Timeframe,
                                  "supertrend",
                                  ST1AtrP,
                                  ST1Mult,
                                  SupertrendSourcePrice,
                                  SupertrendTakeWicksIntoAccount);
      if(supertrend1Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create ST1 handle (%s). err=%d", EnumToString(ST1Timeframe), GetLastError());
         return(INIT_FAILED);
      }
   }

   if(UseSuperTrend2)
   {
      supertrend2Handle = iCustom(_Symbol,
                                  ST2Timeframe,
                                  "supertrend",
                                  ST2AtrP,
                                  ST2Mult,
                                  SupertrendSourcePrice,
                                  SupertrendTakeWicksIntoAccount);
      if(supertrend2Handle == INVALID_HANDLE)
      {
         PrintFormat("Failed to create ST2 handle (%s). err=%d", EnumToString(ST2Timeframe), GetLastError());
         return(INIT_FAILED);
      }
   }

   IndicatorSetString(INDICATOR_SHORTNAME, "Sumit_RSI_Score_with_supertrends");
   IndicatorSetInteger(INDICATOR_DIGITS, 2);
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
   ArraySetAsSeries(time, false);

   int min_bars = MathMax(250, SumitSma201Period + SumitRsiPeriod + 11);
   if(UseSuperTrend1)
      min_bars = MathMax(min_bars, ST1AtrP + 5);
   if(UseSuperTrend2)
      min_bars = MathMax(min_bars, ST2AtrP + 5);

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
      for(int i = 0; i < rates_total; i++)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         SignalMa3Buffer[i] = EMPTY_VALUE;
         SignalMa11Buffer[i] = EMPTY_VALUE;
         Rsi1hBuffer[i] = EMPTY_VALUE;
         FinalScoreBuffer[i] = EMPTY_VALUE;
         ST1ScoreBuffer[i] = EMPTY_VALUE;
         ST2ScoreBuffer[i] = EMPTY_VALUE;
         SumitRawScoreBuffer[i] = EMPTY_VALUE;
         AvgGainBuffer[i] = EMPTY_VALUE;
         AvgLossBuffer[i] = EMPTY_VALUE;
         ST1DirBuffer[i] = 0.0;
         ST2DirBuffer[i] = 0.0;
      }
   }

   for(int i = start; i < rates_total; i++)
   {
      Rsi1hBuffer[i] = WorkRsi[i];
      if(WorkMa3[i] == EMPTY_VALUE || WorkMa201[i] == EMPTY_VALUE)
         WorkMomentum[i] = EMPTY_VALUE;
      else
         WorkMomentum[i] = WorkMa3[i] - WorkMa201[i];
   }

   UpdateRsiWilderBuffer(rates_total, prev_calculated, SumitRsiPeriod);

   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, 3, SumitRsiBuffer, SignalMa3Buffer);
   SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, 11, SumitRsiBuffer, SignalMa11Buffer);

   int score_begin = SumitSma201Period + SumitRsiPeriod + 11 - 1;
   int score_start = MathMax(start, score_begin);

   for(int i = start; i < score_start && i < rates_total; i++)
      SumitRawScoreBuffer[i] = EMPTY_VALUE;

   for(int i = score_start; i < rates_total && !IsStopped(); i++)
   {
      if(SumitRsiBuffer[i] == EMPTY_VALUE ||
         SignalMa3Buffer[i] == EMPTY_VALUE ||
         SignalMa11Buffer[i] == EMPTY_VALUE ||
         Rsi1hBuffer[i] == EMPTY_VALUE)
      {
         SumitRawScoreBuffer[i] = EMPTY_VALUE;
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

      SumitRawScoreBuffer[i] = ClampScore((double)score);
   }

   if(UseSuperTrend1)
   {
      if(!FillSuperTrendMappedScores(supertrend1Handle,
                                     ST1Timeframe,
                                     time,
                                     rates_total,
                                     start,
                                     ST1BullScore,
                                     ST1BearScore,
                                     ST1NeutralScore,
                                     ST1ScoreBuffer,
                                     ST1DirBuffer))
      {
         return(prev_calculated);
      }
   }
   else
   {
      for(int i = start; i < rates_total; i++)
      {
         ST1ScoreBuffer[i] = ClampScore(ST1NeutralScore);
         ST1DirBuffer[i] = 0.0;
      }
   }

   if(UseSuperTrend2)
   {
      if(!FillSuperTrendMappedScores(supertrend2Handle,
                                     ST2Timeframe,
                                     time,
                                     rates_total,
                                     start,
                                     ST2BullScore,
                                     ST2BearScore,
                                     ST2NeutralScore,
                                     ST2ScoreBuffer,
                                     ST2DirBuffer))
      {
         return(prev_calculated);
      }
   }
   else
   {
      for(int i = start; i < rates_total; i++)
      {
         ST2ScoreBuffer[i] = ClampScore(ST2NeutralScore);
         ST2DirBuffer[i] = 0.0;
      }
   }

   double w_sumit = NormalizeWeight(WeightSumit);
   double w_st1 = UseSuperTrend1 ? NormalizeWeight(WeightST1) : 0.0;
   double w_st2 = UseSuperTrend2 ? NormalizeWeight(WeightST2) : 0.0;
   double w_total = w_sumit + w_st1 + w_st2;
   if(w_total <= 0.0)
   {
      w_sumit = 1.0;
      w_st1 = 0.0;
      w_st2 = 0.0;
      w_total = 1.0;
   }

   for(int i = start; i < rates_total; i++)
   {
      if(SumitRawScoreBuffer[i] == EMPTY_VALUE)
      {
         FinalScoreBuffer[i] = EMPTY_VALUE;
         continue;
      }

      double st1_score = (ST1ScoreBuffer[i] == EMPTY_VALUE) ? ClampScore(ST1NeutralScore) : ST1ScoreBuffer[i];
      double st2_score = (ST2ScoreBuffer[i] == EMPTY_VALUE) ? ClampScore(ST2NeutralScore) : ST2ScoreBuffer[i];

      double combined = ((SumitRawScoreBuffer[i] * w_sumit) +
                         (st1_score * w_st1) +
                         (st2_score * w_st2)) / w_total;

      FinalScoreBuffer[i] = ClampScore(combined);
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
   if(supertrend1Handle != INVALID_HANDLE)
      IndicatorRelease(supertrend1Handle);
   if(supertrend2Handle != INVALID_HANDLE)
      IndicatorRelease(supertrend2Handle);
}
//+------------------------------------------------------------------+
