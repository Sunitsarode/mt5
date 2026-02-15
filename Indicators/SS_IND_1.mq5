//+------------------------------------------------------------------+
//|                                        DhanushyaIndicator.mq5    |
//|                                                                  |
//+------------------------------------------------------------------+
#property copyright "Custom"
#property link      ""
#property version   "1.00"
#property indicator_chart_window
#property indicator_buffers 14
#property indicator_plots   6

// Main Chart: EMA Lines
#property indicator_label1  "EMA 3 Close"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "EMA 3 Open"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

// Score Labels on Chart
#property indicator_label3  "Score Bullish"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrLime
#property indicator_width3  2

#property indicator_label4  "Score Bearish"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_width4  2

#property indicator_label5  "Score Neutral Up"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrYellow
#property indicator_width5  1

#property indicator_label6  "Score Neutral Down"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrOrange
#property indicator_width6  1

// Input Parameters
input int    InpRSI1HPeriod = 51;           // RSI 1H Period
input int    InpSumitMaBuyThreshold = 30;   // Sumit MA Buy Threshold
input int    InpSumitMaSellThreshold = 70;  // Sumit MA Sell Threshold
input int    InpRSI1HBuyThreshold = 45;     // RSI 1H Buy Threshold
input int    InpRSI1HSellThreshold = 55;    // RSI 1H Sell Threshold
input bool   InpShowScoreText = true;       // Show Score Numbers
input int    InpArrowOffset = 20;           // Arrow Offset (points)

// Indicator Buffers
double EMA3CloseBuffer[];
double EMA3OpenBuffer[];
double ScoreBullishBuffer[];
double ScoreBearishBuffer[];
double ScoreNeutralUpBuffer[];
double ScoreNeutralDownBuffer[];

// Working buffers
double SumitRSIBuffer[];
double SignalMA3Buffer[];
double SignalMA11Buffer[];
double RSI1HSmoothBuffer[];
double ScoreBuffer[];
double MomentumBuffer[];
double TPBuffer[];
double EMACloseTemp[];

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
   // Set indicator buffers
   SetIndexBuffer(0, EMA3CloseBuffer, INDICATOR_DATA);
   SetIndexBuffer(1, EMA3OpenBuffer, INDICATOR_DATA);
   SetIndexBuffer(2, ScoreBullishBuffer, INDICATOR_DATA);
   SetIndexBuffer(3, ScoreBearishBuffer, INDICATOR_DATA);
   SetIndexBuffer(4, ScoreNeutralUpBuffer, INDICATOR_DATA);
   SetIndexBuffer(5, ScoreNeutralDownBuffer, INDICATOR_DATA);
   
   SetIndexBuffer(6, SumitRSIBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(7, SignalMA3Buffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(8, SignalMA11Buffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(9, RSI1HSmoothBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(10, ScoreBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(11, MomentumBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(12, TPBuffer, INDICATOR_CALCULATIONS);
   SetIndexBuffer(13, EMACloseTemp, INDICATOR_CALCULATIONS);
   
   // Set arrow codes
   PlotIndexSetInteger(2, PLOT_ARROW, 233);  // Down arrow for bullish (below candle)
   PlotIndexSetInteger(3, PLOT_ARROW, 234);  // Up arrow for bearish (above candle)
   PlotIndexSetInteger(4, PLOT_ARROW, 159);  // Small circle for neutral up
   PlotIndexSetInteger(5, PLOT_ARROW, 159);  // Small circle for neutral down
   
   // Set indicator digits
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   
   // Set indicator name
   IndicatorSetString(INDICATOR_SHORTNAME, "Dhanushya Strategy");
   
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
   int start = prev_calculated > 0 ? prev_calculated - 1 : 201;
   
   // Calculate indicators from start to end
   for(int i = start; i < rates_total; i++)
   {
      // Initialize arrow buffers
      ScoreBullishBuffer[i] = EMPTY_VALUE;
      ScoreBearishBuffer[i] = EMPTY_VALUE;
      ScoreNeutralUpBuffer[i] = EMPTY_VALUE;
      ScoreNeutralDownBuffer[i] = EMPTY_VALUE;
      
      // Calculate EMA 3 Close
      if(i >= 2)
      {
         double alpha = 2.0 / (3.0 + 1.0);
         if(i == 2)
            EMA3CloseBuffer[i] = close[i];
         else
            EMA3CloseBuffer[i] = close[i] * alpha + EMA3CloseBuffer[i-1] * (1.0 - alpha);
      }
      
      // Calculate EMA 3 Open
      if(i >= 2)
      {
         double alpha = 2.0 / (3.0 + 1.0);
         if(i == 2)
            EMA3OpenBuffer[i] = open[i];
         else
            EMA3OpenBuffer[i] = open[i] * alpha + EMA3OpenBuffer[i-1] * (1.0 - alpha);
      }
      
      // Calculate Typical Price for Sumit MA-RSI
      TPBuffer[i] = (open[i] + high[i] + low[i] + close[i]) / 4.0;
      
      // Calculate SMA3 and SMA201 for momentum
      if(i >= 2)
      {
         double sma3 = 0, sma201 = 0;
         
         // SMA 3
         for(int j = 0; j < 3; j++)
            sma3 += TPBuffer[i - j];
         sma3 /= 3.0;
         
         // SMA 201
         if(i >= 200)
         {
            for(int j = 0; j < 201; j++)
               sma201 += TPBuffer[i - j];
            sma201 /= 201.0;
            
            MomentumBuffer[i] = sma3 - sma201;
         }
         else
         {
            MomentumBuffer[i] = 0;
         }
      }
      
      // Calculate Sumit RSI (RSI of momentum with period 7)
      if(i >= 207)
      {
         double avgGain = 0, avgLoss = 0;
         
         for(int j = 1; j <= 7; j++)
         {
            double change = MomentumBuffer[i - j + 1] - MomentumBuffer[i - j];
            if(change > 0)
               avgGain += change;
            else
               avgLoss -= change;
         }
         
         avgGain /= 7.0;
         avgLoss /= 7.0;
         
         if(avgLoss != 0)
            SumitRSIBuffer[i] = 100.0 - (100.0 / (1.0 + avgGain / avgLoss));
         else
            SumitRSIBuffer[i] = 100.0;
      }
      
      // Calculate Signal MA3 (SMA of Sumit RSI with period 3)
      if(i >= 209)
      {
         double sum = 0;
         for(int j = 0; j < 3; j++)
            sum += SumitRSIBuffer[i - j];
         SignalMA3Buffer[i] = sum / 3.0;
      }
      
      // Calculate Signal MA11 (SMA of Sumit RSI with period 11)
      if(i >= 217)
      {
         double sum = 0;
         for(int j = 0; j < 11; j++)
            sum += SumitRSIBuffer[i - j];
         SignalMA11Buffer[i] = sum / 11.0;
      }
      
      // Calculate RSI 1H Smooth
      if(i >= InpRSI1HPeriod)
      {
         double avgGain = 0, avgLoss = 0;
         
         for(int j = 1; j <= InpRSI1HPeriod; j++)
         {
            double change = close[i - j + 1] - close[i - j];
            if(change > 0)
               avgGain += change;
            else
               avgLoss -= change;
         }
         
         avgGain /= InpRSI1HPeriod;
         avgLoss /= InpRSI1HPeriod;
         
         if(avgLoss != 0)
            RSI1HSmoothBuffer[i] = 100.0 - (100.0 / (1.0 + avgGain / avgLoss));
         else
            RSI1HSmoothBuffer[i] = 100.0;
      }
      
      // Calculate Score
      if(i >= 217)
      {
         int score = 0;
         
         // Add points for sell conditions
         if(SignalMA3Buffer[i] > InpSumitMaSellThreshold) score++;
         if(SignalMA11Buffer[i] > InpSumitMaSellThreshold) score++;
         if(SumitRSIBuffer[i] > InpSumitMaSellThreshold) score++;
         if(RSI1HSmoothBuffer[i] > InpRSI1HSellThreshold) score++;
         
         // Subtract points for buy conditions
         if(SignalMA3Buffer[i] < InpSumitMaBuyThreshold) score--;
         if(SignalMA11Buffer[i] < InpSumitMaBuyThreshold) score--;
         if(SumitRSIBuffer[i] < InpSumitMaBuyThreshold) score--;
         if(RSI1HSmoothBuffer[i] < InpRSI1HBuyThreshold) score--;
         
         ScoreBuffer[i] = (double)score;
         
         // Place arrows based on score
         double offset = InpArrowOffset * _Point;
         
         if(score <= -3)  // Strong bullish - arrow below candle
         {
            ScoreBullishBuffer[i] = low[i] - offset;
            if(InpShowScoreText)
               CreateScoreLabel(time[i], low[i] - offset * 2, IntegerToString(score), clrLime);
         }
         else if(score >= 3)  // Strong bearish - arrow above candle
         {
            ScoreBearishBuffer[i] = high[i] + offset;
            if(InpShowScoreText)
               CreateScoreLabel(time[i], high[i] + offset * 2, IntegerToString(score), clrRed);
         }
         else if(score < 0)  // Weak bullish
         {
            ScoreNeutralUpBuffer[i] = low[i] - offset * 0.5;
            if(InpShowScoreText)
               CreateScoreLabel(time[i], low[i] - offset * 1.5, IntegerToString(score), clrYellow);
         }
         else if(score > 0)  // Weak bearish
         {
            ScoreNeutralDownBuffer[i] = high[i] + offset * 0.5;
            if(InpShowScoreText)
               CreateScoreLabel(time[i], high[i] + offset * 1.5, IntegerToString(score), clrOrange);
         }
      }
   }
   
   return(rates_total);
}

//+------------------------------------------------------------------+
//| Create text label for score                                      |
//+------------------------------------------------------------------+
void CreateScoreLabel(datetime time, double price, string text, color clr)
{
   string objName = "Score_" + TimeToString(time, TIME_DATE|TIME_MINUTES);
   
   if(ObjectFind(0, objName) < 0)
   {
      ObjectCreate(0, objName, OBJ_TEXT, 0, time, price);
      ObjectSetString(0, objName, OBJPROP_TEXT, text);
      ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, objName, OBJPROP_ANCHOR, ANCHOR_CENTER);
   }
}

//+------------------------------------------------------------------+
//| Cleanup old labels on deinit                                     |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Clean up score labels
   for(int i = ObjectsTotal(0, 0, OBJ_TEXT) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, 0, OBJ_TEXT);
      if(StringFind(name, "Score_") == 0)
         ObjectDelete(0, name);
   }
}
//+------------------------------------------------------------------+