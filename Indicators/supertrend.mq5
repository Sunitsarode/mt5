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
input bool   TakeWicksIntoAccount = false;            // Include wicks in calculations
input ENUM_TIMEFRAMES CalcTimeframe = PERIOD_CURRENT; // Timeframe used for calculations
input int CandleShift = 0;                           // 0=current candle, 1=previous candle

//--- Indicator Handles ---
int    atrHandle;                               // Handle for ATR indicator
ENUM_TIMEFRAMES g_calc_tf = PERIOD_CURRENT;
int g_candle_shift = 0;

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

    PrintFormat("SuperTrend init: ATRPeriod=%d Multiplier=%.2f TF=%s Shift=%d",
                ATRPeriod, Multiplier, EnumToString(g_calc_tf), g_candle_shift);

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
    static double tfUpperBand[];
    static double tfLowerBand[];
    ArrayResize(tfSuperTrend, tf_count);
    ArrayResize(tfDirection, tf_count);
    ArrayResize(tfUpperBand, tf_count);
    ArrayResize(tfLowerBand, tf_count);

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
                double fallback = (tf_high + tf_low) * 0.5;
                tfSuperTrend[j] = fallback;
                tfDirection[j] = -1.0;
                tfLowerBand[j] = fallback;
                tfUpperBand[j] = fallback;
            }
            else
            {
                tfSuperTrend[j] = tfSuperTrend[j - 1];
                tfDirection[j] = tfDirection[j - 1];
                tfLowerBand[j] = tfLowerBand[j - 1];
                tfUpperBand[j] = tfUpperBand[j - 1];
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

        // 2) Compute raw bands for this bar.
        double lowerBandRaw = srcPrice - Multiplier * atr;
        double upperBandRaw = srcPrice + Multiplier * atr;

        if(j == 0)
        {
            tfLowerBand[j] = lowerBandRaw;
            tfUpperBand[j] = upperBandRaw;

            // TradingView's ta.supertrend starts with direction=+1 (downtrend).
            // Keep internal output convention: +1 bullish, -1 bearish.
            int tvDir0 = 1;
            tfDirection[j] = (tvDir0 == -1) ? 1.0 : -1.0;
            tfSuperTrend[j] = (tvDir0 == -1) ? tfLowerBand[j] : tfUpperBand[j];
            continue;
        }

        // 3) Carry forward final bands like TradingView's ta.supertrend logic.
        double prevLower = tfLowerBand[j - 1];
        double prevUpper = tfUpperBand[j - 1];
        double prevClose = tfClose[j - 1];
        double prevLow = tfLow[j - 1];
        double prevHigh = tfHigh[j - 1];

        double carryCloseLower = TakeWicksIntoAccount ? prevLow : prevClose;
        double carryCloseUpper = TakeWicksIntoAccount ? prevHigh : prevClose;

        // TV lower: lowerRaw if (lowerRaw > prevLower) or (close[1] < prevLower), else prevLower.
        if(lowerBandRaw > prevLower || carryCloseLower < prevLower)
            tfLowerBand[j] = lowerBandRaw;
        else
            tfLowerBand[j] = prevLower;

        // TV upper: upperRaw if (upperRaw < prevUpper) or (close[1] > prevUpper), else prevUpper.
        if(upperBandRaw < prevUpper || carryCloseUpper > prevUpper)
            tfUpperBand[j] = upperBandRaw;
        else
            tfUpperBand[j] = prevUpper;

        // 4) Direction logic matching TradingView's ta.supertrend.
        // TV convention: -1 = uptrend, +1 = downtrend.
        int prevTvDir = (tfDirection[j - 1] > 0.0) ? -1 : 1; // convert from internal sign
        int tvDir = prevTvDir;

        if(atrBuffer[j - 1] == EMPTY_VALUE || atrBuffer[j - 1] <= 0.0)
        {
            tvDir = 1; // downtrend during warmup
        }
        else if(prevTvDir == 1) // previous supertrend was upper band (downtrend)
        {
            double flipUpSource = TakeWicksIntoAccount ? tf_high : tf_close;
            tvDir = (flipUpSource > tfUpperBand[j]) ? -1 : 1;
        }
        else // previous supertrend was lower band (uptrend)
        {
            double flipDownSource = TakeWicksIntoAccount ? tf_low : tf_close;
            tvDir = (flipDownSource < tfLowerBand[j]) ? 1 : -1;
        }

        // 5) Final selected line + keep original output direction sign for EA compatibility.
        tfSuperTrend[j] = (tvDir == -1) ? tfLowerBand[j] : tfUpperBand[j];
        tfDirection[j] = (tvDir == -1) ? 1.0 : -1.0; // +1 bullish, -1 bearish
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

