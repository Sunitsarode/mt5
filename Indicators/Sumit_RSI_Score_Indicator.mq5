//+------------------------------------------------------------------+
//|                                   Sumit_RSI_Score_Trend.mq5        |
//+------------------------------------------------------------------+
#property copyright "Strategy Indicators"
#property version   "1.10"
#property indicator_separate_window
#property indicator_buffers 5
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

// Handles
int rsiHandle = INVALID_HANDLE;
int ma3Handle = INVALID_HANDLE;
int ma201Handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| Wilder RSI on array                                              |
//+------------------------------------------------------------------+
void CalcRsiWilderBuffer(const double &src[], const int rates_total, const int period, double &dst[])
{
   ArrayInitialize(dst, EMPTY_VALUE);

   if(period <= 0 || rates_total <= period)
      return;

   double gain_sum = 0.0;
   double loss_sum = 0.0;

   for(int i = 1; i <= period; i++)
   {
      if(src[i] == EMPTY_VALUE || src[i - 1] == EMPTY_VALUE)
         return;

      double change = src[i] - src[i - 1];
      if(change > 0.0)
         gain_sum += change;
      else
         loss_sum -= change;
   }

   double avg_gain = gain_sum / period;
   double avg_loss = loss_sum / period;

   if(avg_loss == 0.0)
      dst[period] = 100.0;
   else
      dst[period] = 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));

   for(int i = period + 1; i < rates_total; i++)
   {
      if(src[i] == EMPTY_VALUE || src[i - 1] == EMPTY_VALUE)
      {
         dst[i] = EMPTY_VALUE;
         continue;
      }

      double change = src[i] - src[i - 1];
      double gain = (change > 0.0) ? change : 0.0;
      double loss = (change < 0.0) ? -change : 0.0;

      avg_gain = ((avg_gain * (period - 1)) + gain) / period;
      avg_loss = ((avg_loss * (period - 1)) + loss) / period;

      if(avg_loss == 0.0)
         dst[i] = 100.0;
      else
         dst[i] = 100.0 - (100.0 / (1.0 + (avg_gain / avg_loss)));
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

   // Use non-series indexing in all calculations (oldest -> newest).
   ArraySetAsSeries(SumitRsiBuffer, false);
   ArraySetAsSeries(SignalMa3Buffer, false);
   ArraySetAsSeries(SignalMa11Buffer, false);
   ArraySetAsSeries(Rsi1hBuffer, false);
   ArraySetAsSeries(ScoreBuffer, false);

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

   double rsi[];
   double ma3[];
   double ma201[];
   double momentum[];

   ArrayResize(rsi, rates_total);
   ArrayResize(ma3, rates_total);
   ArrayResize(ma201, rates_total);
   ArrayResize(momentum, rates_total);

   ArraySetAsSeries(rsi, false);
   ArraySetAsSeries(ma3, false);
   ArraySetAsSeries(ma201, false);
   ArraySetAsSeries(momentum, false);

   int copied_rsi = CopyBuffer(rsiHandle, 0, 0, rates_total, rsi);
   int copied_ma3 = CopyBuffer(ma3Handle, 0, 0, rates_total, ma3);
   int copied_ma201 = CopyBuffer(ma201Handle, 0, 0, rates_total, ma201);

   if(copied_rsi != rates_total || copied_ma3 != rates_total || copied_ma201 != rates_total)
      return(prev_calculated);

   for(int i = 0; i < rates_total; i++)
   {
      Rsi1hBuffer[i] = rsi[i];
      momentum[i] = ma3[i] - ma201[i];
   }

   CalcRsiWilderBuffer(momentum, rates_total, SumitRsiPeriod, SumitRsiBuffer);

   int ma3_state = (prev_calculated > 0) ? prev_calculated : 0;
   int ma11_state = (prev_calculated > 0) ? prev_calculated : 0;
   SimpleMAOnBuffer(rates_total, ma3_state, SumitRsiPeriod, 3, SumitRsiBuffer, SignalMa3Buffer);
   SimpleMAOnBuffer(rates_total, ma11_state, SumitRsiPeriod, 11, SumitRsiBuffer, SignalMa11Buffer);

   int score_begin = SumitRsiPeriod + 11 - 1;
   int start = (prev_calculated > 0) ? (prev_calculated - 1) : 0;
   if(start < 0)
      start = 0;

   for(int i = start; i < rates_total && !IsStopped(); i++)
   {
      if(i < score_begin ||
         SumitRsiBuffer[i] == EMPTY_VALUE ||
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
