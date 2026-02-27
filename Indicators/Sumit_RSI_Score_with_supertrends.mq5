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
int st1AtrHandle = INVALID_HANDLE;
int st2AtrHandle = INVALID_HANDLE;
bool g_st1_enabled = false;
bool g_st2_enabled = false;

bool CopyBufferAligned(const int handle, const int buffer_num, const int rates_total, double &dst[])
{
   double tmp[];
   ArraySetAsSeries(tmp, false);
   int copied = CopyBuffer(handle, buffer_num, 0, rates_total, tmp);
   if(copied <= 0)
      return false;

   int offset = rates_total - copied;
   if(offset < 0)
      offset = 0;

   for(int i = 0; i < offset; i++)
      dst[i] = EMPTY_VALUE;

   int limit = MathMin(copied, rates_total - offset);
   for(int i = 0; i < limit; i++)
      dst[offset + i] = tmp[i];

   return true;
}

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

double SelectSourcePrice(const double openv,
                         const double highv,
                         const double lowv,
                         const double closev,
                         const ENUM_APPLIED_PRICE mode)
{
   switch(mode)
   {
      case PRICE_CLOSE:   return closev;
      case PRICE_OPEN:    return openv;
      case PRICE_HIGH:    return highv;
      case PRICE_LOW:     return lowv;
      case PRICE_MEDIAN:  return (highv + lowv) * 0.5;
      case PRICE_TYPICAL: return (highv + lowv + closev) / 3.0;
      default:            return (highv + lowv + closev + closev) * 0.25; // PRICE_WEIGHTED
   }
}

bool FillSuperTrendMappedScores(const int atr_handle,
                                const ENUM_TIMEFRAMES timeframe,
                                const int atr_period,
                                const double multiplier,
                                const ENUM_APPLIED_PRICE source_mode,
                                const bool take_wicks,
                                const datetime &base_time[],
                                const int rates_total,
                                const int start,
                                const double bull_score,
                                const double bear_score,
                                const double neutral_score,
                                double &mapped_score_buffer[],
                                double &dir_buffer[])
{
   if(atr_handle == INVALID_HANDLE || rates_total <= 0)
      return false;

   int tf_bars = Bars(_Symbol, timeframe);
   if(tf_bars <= atr_period + 2)
      return false;

   int request = MathMin(tf_bars, rates_total + 4096);
   if(request <= atr_period + 2)
      return false;

   datetime tf_time[];
   double tf_open[], tf_high[], tf_low[], tf_close[], tf_atr[];
   ArraySetAsSeries(tf_time, true);
   ArraySetAsSeries(tf_open, true);
   ArraySetAsSeries(tf_high, true);
   ArraySetAsSeries(tf_low, true);
   ArraySetAsSeries(tf_close, true);
   ArraySetAsSeries(tf_atr, true);

   int c_time = CopyTime(_Symbol, timeframe, 0, request, tf_time);
   int c_open = CopyOpen(_Symbol, timeframe, 0, request, tf_open);
   int c_high = CopyHigh(_Symbol, timeframe, 0, request, tf_high);
   int c_low = CopyLow(_Symbol, timeframe, 0, request, tf_low);
   int c_close = CopyClose(_Symbol, timeframe, 0, request, tf_close);
   int c_atr = CopyBuffer(atr_handle, 0, 0, request, tf_atr);

   int copied = MathMin(MathMin(MathMin(c_time, c_open), MathMin(c_high, c_low)), MathMin(c_close, c_atr));
   if(copied <= atr_period + 2)
      return false;

   double st_line[];
   double st_dir[];
   ArrayResize(st_line, copied);
   ArrayResize(st_dir, copied);
   ArraySetAsSeries(st_line, true);
   ArraySetAsSeries(st_dir, true);

   for(int i = copied - 1; i >= 0; i--)
   {
      double atr = tf_atr[i];
      double openv = tf_open[i];
      double highv = tf_high[i];
      double lowv = tf_low[i];
      double closev = tf_close[i];

      if(atr == EMPTY_VALUE || atr <= 0.0)
      {
         if(i == copied - 1)
         {
            st_line[i] = (highv + lowv) * 0.5;
            st_dir[i] = 1.0;
         }
         else
         {
            st_line[i] = st_line[i + 1];
            st_dir[i] = st_dir[i + 1];
         }
         continue;
      }

      double src = SelectSourcePrice(openv, highv, lowv, closev, source_mode);
      double high_price = take_wicks ? highv : closev;
      double low_price = take_wicks ? lowv : closev;

      double long_stop = src - (multiplier * atr);
      double prev_stop = (i < copied - 1 && st_line[i + 1] != EMPTY_VALUE) ? st_line[i + 1] : long_stop;
      double long_prev = prev_stop;

      if(long_stop > 0.0)
      {
         if(openv == closev && openv == lowv && openv == highv)
            long_stop = long_prev;
         else
            long_stop = (low_price > long_prev) ? MathMax(long_stop, long_prev) : long_stop;
      }
      else
         long_stop = long_prev;

      double short_stop = src + (multiplier * atr);
      double short_prev = prev_stop;
      if(short_stop > 0.0)
      {
         if(openv == closev && openv == lowv && openv == highv)
            short_stop = short_prev;
         else
            short_stop = (high_price < short_prev) ? MathMin(short_stop, short_prev) : short_stop;
      }
      else
         short_stop = short_prev;

      int dir = 1;
      if(i < copied - 1 && st_dir[i + 1] != EMPTY_VALUE)
         dir = (int)st_dir[i + 1];

      if(dir == -1 && high_price > short_prev)
         dir = 1;
      else if(dir == 1 && low_price < long_prev)
         dir = -1;

      st_dir[i] = (double)dir;
      st_line[i] = (dir == 1) ? long_stop : short_stop;
   }

   for(int i = start; i < rates_total; i++)
   {
      int dir = 0;
      int shift = iBarShift(_Symbol, timeframe, base_time[i], false);
      if(shift >= 0 && shift < copied && st_dir[shift] != EMPTY_VALUE)
         dir = (int)st_dir[shift];

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
   PlotIndexSetInteger(4, PLOT_DRAW_BEGIN, 0);
   PlotIndexSetInteger(5, PLOT_DRAW_BEGIN, 0);
   PlotIndexSetInteger(6, PLOT_DRAW_BEGIN, 0);
   PlotIndexSetInteger(7, PLOT_DRAW_BEGIN, 0);

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

   g_st1_enabled = UseSuperTrend1;
   g_st2_enabled = UseSuperTrend2;

   if(g_st1_enabled)
   {
      st1AtrHandle = iATR(_Symbol, ST1Timeframe, ST1AtrP);
      if(st1AtrHandle == INVALID_HANDLE)
      {
         PrintFormat("Warning: ST1 ATR handle unavailable (%s). Falling back to neutral ST1 score. err=%d",
                     EnumToString(ST1Timeframe), GetLastError());
         g_st1_enabled = false;
      }
   }

   if(g_st2_enabled)
   {
      st2AtrHandle = iATR(_Symbol, ST2Timeframe, ST2AtrP);
      if(st2AtrHandle == INVALID_HANDLE)
      {
         PrintFormat("Warning: ST2 ATR handle unavailable (%s). Falling back to neutral ST2 score. err=%d",
                     EnumToString(ST2Timeframe), GetLastError());
         g_st2_enabled = false;
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
   if(g_st1_enabled)
      min_bars = MathMax(min_bars, ST1AtrP + 5);
   if(g_st2_enabled)
      min_bars = MathMax(min_bars, ST2AtrP + 5);

   if(rates_total < min_bars)
   {
      for(int i = 0; i < rates_total; i++)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         SignalMa3Buffer[i] = EMPTY_VALUE;
         SignalMa11Buffer[i] = EMPTY_VALUE;
         Rsi1hBuffer[i] = 50.0;
         SumitRawScoreBuffer[i] = 50.0;
         ST1ScoreBuffer[i] = ClampScore(ST1NeutralScore);
         ST2ScoreBuffer[i] = ClampScore(ST2NeutralScore);
         FinalScoreBuffer[i] = 50.0;
      }
      return(rates_total);
   }

   int start = (prev_calculated > 1) ? (prev_calculated - 1) : 0;
   if(start < 0)
      start = 0;

   bool rsi_ok = CopyBufferAligned(rsiHandle, 0, rates_total, WorkRsi);
   bool ma3_ok = CopyBufferAligned(ma3Handle, 0, rates_total, WorkMa3);
   bool ma201_ok = CopyBufferAligned(ma201Handle, 0, rates_total, WorkMa201);

   if(prev_calculated == 0)
   {
      for(int i = 0; i < rates_total; i++)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         SignalMa3Buffer[i] = EMPTY_VALUE;
         SignalMa11Buffer[i] = EMPTY_VALUE;
         Rsi1hBuffer[i] = EMPTY_VALUE;
         FinalScoreBuffer[i] = 50.0;
         ST1ScoreBuffer[i] = ClampScore(ST1NeutralScore);
         ST2ScoreBuffer[i] = ClampScore(ST2NeutralScore);
         SumitRawScoreBuffer[i] = 50.0;
         AvgGainBuffer[i] = EMPTY_VALUE;
         AvgLossBuffer[i] = EMPTY_VALUE;
         ST1DirBuffer[i] = 0.0;
         ST2DirBuffer[i] = 0.0;
      }
   }

   for(int i = start; i < rates_total; i++)
   {
      Rsi1hBuffer[i] = rsi_ok ? WorkRsi[i] : 50.0;
      if(!ma3_ok || !ma201_ok || WorkMa3[i] == EMPTY_VALUE || WorkMa201[i] == EMPTY_VALUE)
         WorkMomentum[i] = EMPTY_VALUE;
      else
         WorkMomentum[i] = WorkMa3[i] - WorkMa201[i];
   }

   if(ma3_ok && ma201_ok)
   {
      UpdateRsiWilderBuffer(rates_total, prev_calculated, SumitRsiPeriod);
      SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, 3, SumitRsiBuffer, SignalMa3Buffer);
      SimpleMAOnBuffer(rates_total, prev_calculated, SumitRsiPeriod, 11, SumitRsiBuffer, SignalMa11Buffer);
   }
   else
   {
      for(int i = start; i < rates_total; i++)
      {
         SumitRsiBuffer[i] = EMPTY_VALUE;
         SignalMa3Buffer[i] = EMPTY_VALUE;
         SignalMa11Buffer[i] = EMPTY_VALUE;
      }
   }

   int score_begin = SumitSma201Period + SumitRsiPeriod + 11 - 1;
   int score_start = MathMax(start, score_begin);

   for(int i = start; i < score_start && i < rates_total; i++)
      SumitRawScoreBuffer[i] = EMPTY_VALUE;

   for(int i = score_start; i < rates_total && !IsStopped(); i++)
   {
      if(!rsi_ok || !ma3_ok || !ma201_ok ||
         SumitRsiBuffer[i] == EMPTY_VALUE ||
         SignalMa3Buffer[i] == EMPTY_VALUE ||
         SignalMa11Buffer[i] == EMPTY_VALUE ||
         Rsi1hBuffer[i] == EMPTY_VALUE)
      {
         SumitRawScoreBuffer[i] = 50.0;
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

   if(g_st1_enabled && st1AtrHandle != INVALID_HANDLE && BarsCalculated(st1AtrHandle) > 0)
   {
      if(!FillSuperTrendMappedScores(st1AtrHandle,
                                     ST1Timeframe,
                                     ST1AtrP,
                                     ST1Mult,
                                     SupertrendSourcePrice,
                                     SupertrendTakeWicksIntoAccount,
                                     time,
                                     rates_total,
                                     start,
                                     ST1BullScore,
                                     ST1BearScore,
                                     ST1NeutralScore,
                                     ST1ScoreBuffer,
                                     ST1DirBuffer))
      {
         for(int i = start; i < rates_total; i++)
         {
            ST1ScoreBuffer[i] = ClampScore(ST1NeutralScore);
            ST1DirBuffer[i] = 0.0;
         }
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

   if(g_st2_enabled && st2AtrHandle != INVALID_HANDLE && BarsCalculated(st2AtrHandle) > 0)
   {
      if(!FillSuperTrendMappedScores(st2AtrHandle,
                                     ST2Timeframe,
                                     ST2AtrP,
                                     ST2Mult,
                                     SupertrendSourcePrice,
                                     SupertrendTakeWicksIntoAccount,
                                     time,
                                     rates_total,
                                     start,
                                     ST2BullScore,
                                     ST2BearScore,
                                     ST2NeutralScore,
                                     ST2ScoreBuffer,
                                     ST2DirBuffer))
      {
         for(int i = start; i < rates_total; i++)
         {
            ST2ScoreBuffer[i] = ClampScore(ST2NeutralScore);
            ST2DirBuffer[i] = 0.0;
         }
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
   double w_st1 = g_st1_enabled ? NormalizeWeight(WeightST1) : 0.0;
   double w_st2 = g_st2_enabled ? NormalizeWeight(WeightST2) : 0.0;
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
   if(st1AtrHandle != INVALID_HANDLE)
      IndicatorRelease(st1AtrHandle);
   if(st2AtrHandle != INVALID_HANDLE)
      IndicatorRelease(st2AtrHandle);
}
//+------------------------------------------------------------------+
