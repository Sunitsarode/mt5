//+------------------------------------------------------------------+
//|                                                   supertrend.mq5 |
//+------------------------------------------------------------------+
#property copyright "Salman Soltaniyan"
#property link      "https://www.mql5.com/en/users/salmansoltaniyan"
#property version   "1.03"
#property indicator_chart_window
#property indicator_plots 2
#property indicator_buffers 3
#property indicator_type1 DRAW_COLOR_LINE
#property indicator_style1  STYLE_SOLID
#property indicator_width1  1
#property indicator_color1  clrGreen, clrRed   // Green for uptrend, Red for downtrend

#property indicator_type2 DRAW_NONE


//--- Input Parameters ---
input int    ATRPeriod       = 51;              // Period for ATR calculation
input double Multiplier      = 1.5;             // ATR multiplier for band calculation
input ENUM_APPLIED_PRICE SourcePrice = PRICE_MEDIAN; // Price source for calculations
input bool   TakeWicksIntoAccount = true;            // Include wicks in calculations
input ENUM_TIMEFRAMES CalcTimeframe = PERIOD_CURRENT; // Timeframe used for calculations
input int CandleShift = 0;                           // 0=current candle, 1=previous candle
input double DistanceFactor = 1.0;                   // <1.0 brings line closer to candles

//--- Indicator Handles ---
int    atrHandle;                               // Handle for ATR indicator
ENUM_TIMEFRAMES g_calc_tf = PERIOD_CURRENT;
int g_candle_shift = 0;
double g_distance_factor = 1.0;

//--- Indicator Buffers ---
double SuperTrendBuffer[];                      // Main SuperTrend line values
double SuperTrendColorBuffer[];                 // Color index buffer (0 = Green, 1 = Red)
double SuperTrendDirectionBuffer[];             // Direction buffer (1 = Up, -1 = Down)

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    g_calc_tf = (CalcTimeframe == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : CalcTimeframe;
    g_candle_shift = CandleShift;
    if(g_candle_shift < 0)
        g_candle_shift = 0;
    if(g_candle_shift > 1)
        g_candle_shift = 1;
    g_distance_factor = DistanceFactor;
    if(g_distance_factor < 0.05)
        g_distance_factor = 0.05;
    if(g_distance_factor > 5.0)
        g_distance_factor = 5.0;

    // Create ATR indicator handle
    atrHandle = iATR(_Symbol, g_calc_tf, ATRPeriod);
    if(atrHandle == INVALID_HANDLE)
    {
        Print("Error creating ATR indicator. Error code: ", GetLastError());
        return INIT_FAILED;
    }
    
    //--- Set indicator buffers mapping ---
    SetIndexBuffer(0, SuperTrendBuffer, INDICATOR_DATA);
    SetIndexBuffer(1, SuperTrendColorBuffer, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(2, SuperTrendDirectionBuffer, INDICATOR_DATA);

    //--- Set the indicator labels ---
    PlotIndexSetString(0, PLOT_LABEL, "SuperTrend");
    PlotIndexSetString(2, PLOT_LABEL, "SuperTrend direction");
    
    //--- Set array direction ---
    ArraySetAsSeries(SuperTrendBuffer, false);
    ArraySetAsSeries(SuperTrendDirectionBuffer, false);
    ArraySetAsSeries(SuperTrendColorBuffer, false);

    PrintFormat("SuperTrend init: ATRPeriod=%d Multiplier=%.2f DistanceFactor=%.2f TF=%s Shift=%d",
                ATRPeriod, Multiplier, g_distance_factor, EnumToString(g_calc_tf), g_candle_shift);

    //--- Initialization is finished ---
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Release ATR handle to free resources ---
    IndicatorRelease(atrHandle);
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
    // Set all arrays as not series (default indexing)
    ArraySetAsSeries(time, false);
    ArraySetAsSeries(open, false);
    ArraySetAsSeries(high, false);
    ArraySetAsSeries(low, false);
    ArraySetAsSeries(close, false);

    if(rates_total <= 1)
        return 0;

    int tf_bars = Bars(_Symbol, g_calc_tf);
    if(tf_bars <= 1)
        return prev_calculated;

    // Pull calculation-timeframe series once (oldest->newest indexing).
    double atrBuffer[];
    double tfOpen[];
    double tfHigh[];
    double tfLow[];
    double tfClose[];
    ArraySetAsSeries(atrBuffer, false);
    ArraySetAsSeries(tfOpen, false);
    ArraySetAsSeries(tfHigh, false);
    ArraySetAsSeries(tfLow, false);
    ArraySetAsSeries(tfClose, false);

    int copiedAtr = CopyBuffer(atrHandle, 0, 0, tf_bars, atrBuffer);
    int copiedOpen = CopyOpen(_Symbol, g_calc_tf, 0, tf_bars, tfOpen);
    int copiedHigh = CopyHigh(_Symbol, g_calc_tf, 0, tf_bars, tfHigh);
    int copiedLow = CopyLow(_Symbol, g_calc_tf, 0, tf_bars, tfLow);
    int copiedClose = CopyClose(_Symbol, g_calc_tf, 0, tf_bars, tfClose);
    int tf_count = copiedAtr;
    if(copiedOpen < tf_count) tf_count = copiedOpen;
    if(copiedHigh < tf_count) tf_count = copiedHigh;
    if(copiedLow < tf_count) tf_count = copiedLow;
    if(copiedClose < tf_count) tf_count = copiedClose;
    if(tf_count <= 0)
        return prev_calculated;

    // Compute SuperTrend once on the selected timeframe.
    static double tfSuperTrend[];
    static double tfDirection[];
    ArrayResize(tfSuperTrend, tf_count);
    ArrayResize(tfDirection, tf_count);

    double effective_multiplier = Multiplier * g_distance_factor;

    for(int j = 0; j < tf_count; j++)
    {
        double tf_open = tfOpen[j];
        double tf_high = tfHigh[j];
        double tf_low = tfLow[j];
        double tf_close = tfClose[j];
        double atr = atrBuffer[j];

        if(atr == EMPTY_VALUE || atr <= 0.0)
        {
            if(j == 0)
            {
                tfSuperTrend[j] = (tf_high + tf_low) * 0.5;
                tfDirection[j] = 1.0;
            }
            else
            {
                tfSuperTrend[j] = tfSuperTrend[j - 1];
                tfDirection[j] = tfDirection[j - 1];
            }
            continue;
        }

        // 1) Source price by selected mode.
        double srcPrice;
        switch(SourcePrice)
        {
            case PRICE_CLOSE:
                srcPrice = tf_close;
                break;
            case PRICE_OPEN:
                srcPrice = tf_open;
                break;
            case PRICE_HIGH:
                srcPrice = tf_high;
                break;
            case PRICE_LOW:
                srcPrice = tf_low;
                break;
            case PRICE_MEDIAN:
                srcPrice = (tf_high + tf_low) / 2.0;
                break;
            case PRICE_TYPICAL:
                srcPrice = (tf_high + tf_low + tf_close) / 3.0;
                break;
            default: // PRICE_WEIGHTED
                srcPrice = (tf_high + tf_low + tf_close + tf_close) / 4.0;
                break;
        }

        // 2) High/Low source for trend flips.
        double highPrice = TakeWicksIntoAccount ? tf_high : tf_close;
        double lowPrice = TakeWicksIntoAccount ? tf_low : tf_close;

        // 3) Long/short stop calculation.
        double longStop = srcPrice - effective_multiplier * atr;
        double prevStop = (j > 0 && tfSuperTrend[j - 1] != EMPTY_VALUE) ? tfSuperTrend[j - 1] : longStop;
        double longStopPrev = prevStop;

        if(longStop > 0.0)
        {
            if(tf_open == tf_close && tf_open == tf_low && tf_open == tf_high)
                longStop = longStopPrev;
            else
                longStop = (lowPrice > longStopPrev ? MathMax(longStop, longStopPrev) : longStop);
        }
        else
            longStop = longStopPrev;

        double shortStop = srcPrice + effective_multiplier * atr;
        double shortStopPrev = prevStop;

        if(shortStop > 0.0)
        {
            if(tf_open == tf_close && tf_open == tf_low && tf_open == tf_high)
                shortStop = shortStopPrev;
            else
                shortStop = (highPrice < shortStopPrev ? MathMin(shortStop, shortStopPrev) : shortStop);
        }
        else
            shortStop = shortStopPrev;

        // 4) Direction change logic.
        int supertrend_dir = 1;
        if(j > 0 && tfDirection[j - 1] != EMPTY_VALUE)
            supertrend_dir = (int)tfDirection[j - 1];

        if(supertrend_dir == -1 && highPrice > shortStopPrev)
            supertrend_dir = 1;
        else if(supertrend_dir == 1 && lowPrice < longStopPrev)
            supertrend_dir = -1;

        // 5) Final selected line.
        if(supertrend_dir == 1)
        {
            tfSuperTrend[j] = longStop;
            tfDirection[j] = 1.0;
        }
        else
        {
            tfSuperTrend[j] = shortStop;
            tfDirection[j] = -1.0;
        }
    }

    int start = (prev_calculated > 1) ? (prev_calculated - 1) : 0;
    if(start < 0)
        start = 0;

    // Map selected-timeframe SuperTrend to current chart bars.
    for(int i = start; i < rates_total; i++)
    {
        int tf_shift = iBarShift(_Symbol, g_calc_tf, time[i], false);
        if(tf_shift < 0)
        {
            if(i == 0)
            {
                SuperTrendBuffer[i] = (high[i] + low[i]) * 0.5;
                SuperTrendDirectionBuffer[i] = 1.0;
                SuperTrendColorBuffer[i] = 0.0;
            }
            else
            {
                SuperTrendBuffer[i] = SuperTrendBuffer[i - 1];
                SuperTrendDirectionBuffer[i] = SuperTrendDirectionBuffer[i - 1];
                SuperTrendColorBuffer[i] = SuperTrendColorBuffer[i - 1];
            }
            continue;
        }

        tf_shift += g_candle_shift;
        int tf_index = (tf_count - 1) - tf_shift; // convert series shift -> non-series index

        if(tf_index < 0 || tf_index >= tf_count)
        {
            if(i == 0)
            {
                SuperTrendBuffer[i] = (high[i] + low[i]) * 0.5;
                SuperTrendDirectionBuffer[i] = 1.0;
                SuperTrendColorBuffer[i] = 0.0;
            }
            else
            {
                SuperTrendBuffer[i] = SuperTrendBuffer[i - 1];
                SuperTrendDirectionBuffer[i] = SuperTrendDirectionBuffer[i - 1];
                SuperTrendColorBuffer[i] = SuperTrendColorBuffer[i - 1];
            }
            continue;
        }

        SuperTrendBuffer[i] = tfSuperTrend[tf_index];
        SuperTrendDirectionBuffer[i] = tfDirection[tf_index];
        SuperTrendColorBuffer[i] = (tfDirection[tf_index] > 0.0) ? 0.0 : 1.0;
    }

    return rates_total;
}
