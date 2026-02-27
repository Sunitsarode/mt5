//+------------------------------------------------------------------+
//|                                                   supertrend_ss.mq5 |

#property version   "1.01"
#property indicator_separate_window
#property indicator_plots 1
#property indicator_buffers 7
#property indicator_type1  DRAW_LINE
#property indicator_style1 STYLE_SOLID
#property indicator_width1 2
#property indicator_color1 clrGold
#property indicator_level1 -2
#property indicator_level2 -1
#property indicator_level3  0
#property indicator_level4  1
#property indicator_level5  2
#property indicator_levelstyle STYLE_DOT
#property indicator_levelcolor clrSilver

//--- Input Parameters ---
input bool   SuperTrend1     = true;            // SuperTrend-1
input int    ST1_ATR         = 51;              // ST1 ATR period
input ENUM_TIMEFRAMES ST1Timeframe = PERIOD_CURRENT;
input bool   SuperTrend2     = true;            // SuperTrend-2
input int    ST2_ATR         = 51;              // ST2 ATR period
input ENUM_TIMEFRAMES ST2Timeframe = PERIOD_M30;
input double Multiplier      = 1.0;             // ATR multiplier for band calculation
input ENUM_APPLIED_PRICE SourcePrice = PRICE_MEDIAN; // Price source for calculations
input bool   TakeWicksIntoAccount = true;       // Include wicks in calculations

//--- Indicator Handles ---
int    atrHandle1 = INVALID_HANDLE;             // ATR handle for ST1
int    atrHandle2 = INVALID_HANDLE;             // ATR handle for ST2

//--- Indicator Buffers ---
double SuperTrendBuffer[];                      // ST1 main SuperTrend line values
double SuperTrendColorBuffer[];                 // ST1 color index buffer (0 = Green, 1 = Red)
double ST1DirectionBuffer[];                    // ST1 direction buffer (1 = Up, -1 = Down)
double ST2DirectionBuffer[];                    // ST2 direction buffer (1 = Up, -1 = Down)
double ST1ScoreBuffer[];                        // ST1 score (+1 bullish, -1 bearish)
double ST2ScoreBuffer[];                        // ST2 score (+1 bullish, -1 bearish)
double ST2LineCalcBuffer[];                     // Internal ST2 line values

//+------------------------------------------------------------------+
//| Price source helper                                              |
//+------------------------------------------------------------------+
double GetSourcePrice(const MqlRates &bar)
{
    switch(SourcePrice)
    {
        case PRICE_CLOSE:
            return bar.close;
        case PRICE_OPEN:
            return bar.open;
        case PRICE_HIGH:
            return bar.high;
        case PRICE_LOW:
            return bar.low;
        case PRICE_MEDIAN:
            return (bar.high + bar.low) / 2.0;
        case PRICE_TYPICAL:
            return (bar.high + bar.low + bar.close) / 3.0;
        default: // PRICE_WEIGHTED
            return (bar.high + bar.low + bar.close + bar.close) / 4.0;
    }
}

//+------------------------------------------------------------------+
//| Build SuperTrend line/direction on one timeframe                 |
//+------------------------------------------------------------------+
void BuildSuperTrendSeries(const MqlRates &rates_tf[],
                           const double &atr_tf[],
                           const int total,
                           double &line_out[],
                           double &dir_out[])
{
    if(total <= 0)
        return;

    for(int i = 0; i < total; i++)
    {
        double atr = atr_tf[i];
        if(atr == EMPTY_VALUE || atr <= 0.0)
        {
            if(i == 0)
            {
                line_out[i] = (rates_tf[i].high + rates_tf[i].low) * 0.5;
                dir_out[i] = 1.0;
            }
            else
            {
                line_out[i] = line_out[i - 1];
                dir_out[i] = dir_out[i - 1];
            }
            continue;
        }

        double srcPrice = GetSourcePrice(rates_tf[i]);
        double highPrice = TakeWicksIntoAccount ? rates_tf[i].high : rates_tf[i].close;
        double lowPrice = TakeWicksIntoAccount ? rates_tf[i].low : rates_tf[i].close;

        double longStop = srcPrice - Multiplier * atr;
        double prevStop = (i > 0 && line_out[i - 1] != EMPTY_VALUE) ? line_out[i - 1] : longStop;
        double longStopPrev = prevStop;

        if(longStop > 0.0)
        {
            if(rates_tf[i].open == rates_tf[i].close &&
               rates_tf[i].open == rates_tf[i].low &&
               rates_tf[i].open == rates_tf[i].high)
            {
                longStop = longStopPrev;
            }
            else
            {
                longStop = (lowPrice > longStopPrev ? MathMax(longStop, longStopPrev) : longStop);
            }
        }
        else
        {
            longStop = longStopPrev;
        }

        double shortStop = srcPrice + Multiplier * atr;
        double shortStopPrev = prevStop;
        if(shortStop > 0.0)
        {
            if(rates_tf[i].open == rates_tf[i].close &&
               rates_tf[i].open == rates_tf[i].low &&
               rates_tf[i].open == rates_tf[i].high)
            {
                shortStop = shortStopPrev;
            }
            else
            {
                shortStop = (highPrice < shortStopPrev ? MathMin(shortStop, shortStopPrev) : shortStop);
            }
        }
        else
        {
            shortStop = shortStopPrev;
        }

        int supertrend_dir = 1;
        if(i > 0 && dir_out[i - 1] != EMPTY_VALUE)
            supertrend_dir = (int)dir_out[i - 1];

        if(supertrend_dir == -1 && highPrice > shortStopPrev)
            supertrend_dir = 1;
        else if(supertrend_dir == 1 && lowPrice < longStopPrev)
            supertrend_dir = -1;

        if(supertrend_dir == 1)
            line_out[i] = longStop;
        else
            line_out[i] = shortStop;

        dir_out[i] = supertrend_dir;
    }
}

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    IndicatorSetString(INDICATOR_SHORTNAME, "SuperTrend SS (ST1/ST2)");

    if(SuperTrend1)
    {
        atrHandle1 = iATR(_Symbol, ST1Timeframe, ST1_ATR);
        if(atrHandle1 == INVALID_HANDLE)
        {
            Print("Error creating ST1 ATR indicator. Error code: ", GetLastError());
            return INIT_FAILED;
        }
    }

    if(SuperTrend2)
    {
        atrHandle2 = iATR(_Symbol, ST2Timeframe, ST2_ATR);
        if(atrHandle2 == INVALID_HANDLE)
        {
            Print("Error creating ST2 ATR indicator. Error code: ", GetLastError());
            return INIT_FAILED;
        }
    }
    
    //--- Set indicator buffers mapping ---
    SetIndexBuffer(0, SuperTrendBuffer, INDICATOR_DATA);
    SetIndexBuffer(1, ST1DirectionBuffer, INDICATOR_CALCULATIONS);
    SetIndexBuffer(2, ST2DirectionBuffer, INDICATOR_CALCULATIONS);
    SetIndexBuffer(3, ST1ScoreBuffer, INDICATOR_CALCULATIONS);
    SetIndexBuffer(4, ST2ScoreBuffer, INDICATOR_CALCULATIONS);
    SetIndexBuffer(5, SuperTrendColorBuffer, INDICATOR_CALCULATIONS);
    SetIndexBuffer(6, ST2LineCalcBuffer, INDICATOR_CALCULATIONS);

    //--- Set the indicator labels ---
    PlotIndexSetString(0, PLOT_LABEL, "Total Score");
    
    //--- Set array direction ---
    ArraySetAsSeries(SuperTrendBuffer, false);
    ArraySetAsSeries(SuperTrendColorBuffer, false);
    ArraySetAsSeries(ST1DirectionBuffer, false);
    ArraySetAsSeries(ST2DirectionBuffer, false);
    ArraySetAsSeries(ST1ScoreBuffer, false);
    ArraySetAsSeries(ST2ScoreBuffer, false);
    ArraySetAsSeries(ST2LineCalcBuffer, false);

    //--- Initialization is finished ---
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    if(atrHandle1 != INVALID_HANDLE)
        IndicatorRelease(atrHandle1);
    if(atrHandle2 != INVALID_HANDLE)
        IndicatorRelease(atrHandle2);
}

//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(
    const int        rates_total,       // Size of input time series
    const int        prev_calculated,   // Number of handled bars at the previous call
    const datetime&  time[],            // Time array
    const double&    open[],            // Open array
    const double&    high[],            // High array
    const double&    low[],             // Low array
    const double&    close[],           // Close array
    const long&      tick_volume[],     // Tick Volume array
    const long&      volume[],          // Real Volume array
    const int&       spread[]           // Spread array
)
{
    // Set chart arrays as non-series (oldest -> newest indexing).
    ArraySetAsSeries(time, false);

    if(rates_total <= 1)
        return 0;

    int start = (prev_calculated > 1) ? (prev_calculated - 1) : 0;
    if(start < 0)
        start = 0;

    // Build ST1 on its own timeframe.
    int st1_total = 0;
    double st1_line_tf[];
    double st1_dir_tf[];
    if(SuperTrend1)
    {
        int bars1 = Bars(_Symbol, ST1Timeframe);
        if(bars1 > 0)
        {
            MqlRates rates1[];
            double atr1[];
            ArraySetAsSeries(rates1, false);
            ArraySetAsSeries(atr1, false);

            int copied_rates1 = CopyRates(_Symbol, ST1Timeframe, 0, bars1, rates1);
            int copied_atr1 = CopyBuffer(atrHandle1, 0, 0, bars1, atr1);
            st1_total = MathMin(copied_rates1, copied_atr1);

            if(st1_total > 0)
            {
                ArrayResize(st1_line_tf, st1_total);
                ArrayResize(st1_dir_tf, st1_total);
                ArraySetAsSeries(st1_line_tf, false);
                ArraySetAsSeries(st1_dir_tf, false);
                BuildSuperTrendSeries(rates1, atr1, st1_total, st1_line_tf, st1_dir_tf);
            }
        }
    }

    // Build ST2 on its own timeframe.
    int st2_total = 0;
    double st2_line_tf[];
    double st2_dir_tf[];
    if(SuperTrend2)
    {
        int bars2 = Bars(_Symbol, ST2Timeframe);
        if(bars2 > 0)
        {
            MqlRates rates2[];
            double atr2[];
            ArraySetAsSeries(rates2, false);
            ArraySetAsSeries(atr2, false);

            int copied_rates2 = CopyRates(_Symbol, ST2Timeframe, 0, bars2, rates2);
            int copied_atr2 = CopyBuffer(atrHandle2, 0, 0, bars2, atr2);
            st2_total = MathMin(copied_rates2, copied_atr2);

            if(st2_total > 0)
            {
                ArrayResize(st2_line_tf, st2_total);
                ArrayResize(st2_dir_tf, st2_total);
                ArraySetAsSeries(st2_line_tf, false);
                ArraySetAsSeries(st2_dir_tf, false);
                BuildSuperTrendSeries(rates2, atr2, st2_total, st2_line_tf, st2_dir_tf);
            }
        }
    }

    for(int i = start; i < rates_total; i++)
    {
        // Defaults
        SuperTrendBuffer[i] = EMPTY_VALUE;
        SuperTrendColorBuffer[i] = 0.0;
        ST1DirectionBuffer[i] = EMPTY_VALUE;
        ST2DirectionBuffer[i] = EMPTY_VALUE;
        ST1ScoreBuffer[i] = EMPTY_VALUE;
        ST2ScoreBuffer[i] = EMPTY_VALUE;
        ST2LineCalcBuffer[i] = EMPTY_VALUE;

        double total_score = 0.0;

        if(SuperTrend1 && st1_total > 0)
        {
            bool st1_mapped = false;
            int st1_shift = iBarShift(_Symbol, ST1Timeframe, time[i], false);
            int st1_idx = st1_total - 1 - st1_shift;
            if(st1_shift >= 0 && st1_idx >= 0 && st1_idx < st1_total)
            {
                ST1DirectionBuffer[i] = st1_dir_tf[st1_idx];
                ST1ScoreBuffer[i] = (ST1DirectionBuffer[i] == 1.0) ? 1.0 : -1.0;
                st1_mapped = true;
            }

            if(!st1_mapped && i > 0 && ST1ScoreBuffer[i - 1] != EMPTY_VALUE)
            {
                ST1DirectionBuffer[i] = ST1DirectionBuffer[i - 1];
                ST1ScoreBuffer[i] = ST1ScoreBuffer[i - 1];
            }

            // Seed first bar if no mapped/previous value was available.
            if(ST1ScoreBuffer[i] == EMPTY_VALUE)
            {
                ST1DirectionBuffer[i] = 1.0;
                ST1ScoreBuffer[i] = 1.0;
            }

            total_score += ST1ScoreBuffer[i];
        }
        else if(SuperTrend1 && i > 0 && ST1ScoreBuffer[i - 1] != EMPTY_VALUE)
        {
            ST1DirectionBuffer[i] = ST1DirectionBuffer[i - 1];
            ST1ScoreBuffer[i] = ST1ScoreBuffer[i - 1];
            total_score += ST1ScoreBuffer[i];
        }
        else if(SuperTrend1)
        {
            ST1DirectionBuffer[i] = 1.0;
            ST1ScoreBuffer[i] = 1.0;
            total_score += ST1ScoreBuffer[i];
        }

        if(SuperTrend2 && st2_total > 0)
        {
            bool st2_mapped = false;
            int st2_shift = iBarShift(_Symbol, ST2Timeframe, time[i], false);
            int st2_idx = st2_total - 1 - st2_shift;
            if(st2_shift >= 0 && st2_idx >= 0 && st2_idx < st2_total)
            {
                ST2DirectionBuffer[i] = st2_dir_tf[st2_idx];
                ST2LineCalcBuffer[i] = st2_line_tf[st2_idx];
                ST2ScoreBuffer[i] = (ST2DirectionBuffer[i] == 1.0) ? 1.0 : -1.0;
                st2_mapped = true;
            }

            if(!st2_mapped && i > 0 && ST2ScoreBuffer[i - 1] != EMPTY_VALUE)
            {
                ST2DirectionBuffer[i] = ST2DirectionBuffer[i - 1];
                ST2LineCalcBuffer[i] = ST2LineCalcBuffer[i - 1];
                ST2ScoreBuffer[i] = ST2ScoreBuffer[i - 1];
            }

            if(ST2ScoreBuffer[i] == EMPTY_VALUE)
            {
                ST2DirectionBuffer[i] = 1.0;
                ST2ScoreBuffer[i] = 1.0;
            }

            total_score += ST2ScoreBuffer[i];
        }
        else if(SuperTrend2 && i > 0 && ST2ScoreBuffer[i - 1] != EMPTY_VALUE)
        {
            ST2DirectionBuffer[i] = ST2DirectionBuffer[i - 1];
            ST2LineCalcBuffer[i] = ST2LineCalcBuffer[i - 1];
            ST2ScoreBuffer[i] = ST2ScoreBuffer[i - 1];
            total_score += ST2ScoreBuffer[i];
        }
        else if(SuperTrend2)
        {
            ST2DirectionBuffer[i] = 1.0;
            ST2ScoreBuffer[i] = 1.0;
            total_score += ST2ScoreBuffer[i];
        }

        if(SuperTrend1 || SuperTrend2)
            SuperTrendBuffer[i] = total_score; // both enabled -> -2/0/2
    }

    return rates_total;
}
