//+------------------------------------------------------------------+
//|                                  Supertrend Multi-Timeframe.mq5 |
//|                                  Copyright 2024, EarnForex.com  |
//|                                       https://www.earnforex.com |
//+------------------------------------------------------------------+
#property copyright "EarnForex.com - 2019-2024"
#property link      "https://www.earnforex.com/metatrader-indicators/supertrend-multi-timeframe/"
#property version   "1.00"
#property description "This Indicator shows the status of the Supertrend indicator on multiple timeframes."
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   2

//--- plot TrendUp
#property indicator_label1  "Trend Up"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGreen
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2
//--- plot TrendDown
#property indicator_label2  "Trend Down"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrRed
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

enum enum_candle_to_check
{
    Current,
    Previous
};

input string Comment_1 = "====================";  // Indicator Settings
input double ATRMultiplier = 2.0;                 // ATR multiplier
input int ATRPeriod = 100;                        // ATR period
input int ATRMaxBars = 1000;                      // ATR max bars
input int Shift = 0;                              // Indicator shift
input enum_candle_to_check TriggerCandle = Previous; // Candle to check values
input string SupertrendFileName = "SuperTrend";   // Supertrend indicator's file name (.ex5)
input int DirectionBufferIndex = 2;               // Buffer index for direction (usually 2 or 4)
input string Comment_2b = "===================="; // Enabled Timeframes
input bool TFM1 = true;                           // Enable M1
input bool TFM5 = true;                           // Enable M5
input bool TFM15 = true;                          // Enable M15
input bool TFM30 = true;                          // Enable M30
input bool TFH1 = true;                           // Enable H1
input bool TFH4 = true;                           // Enable H4
input bool TFD1 = true;                           // Enable D1
input bool TFW1 = true;                           // Enable W1
input bool TFMN1 = true;                          // Enable MN1
input string Comment_3 = "====================";  // Notification Options
input bool EnableNotify = false;                  // Enable notifications feature
input bool SendAlert = false;                     // Send alert notification
input bool SendApp = false;                       // Send notification to mobile
input bool SendEmail = false;                     // Send notification via email
input string Comment_4 = "====================";  // Graphical Objects
input bool DrawLinesEnabled = true;               // Draw Supertrend line
input bool DrawWindowEnabled = true;              // Draw panel
input bool DrawArrowSignal = true;                // Draw arrow signals
input int ArrowCodeUp = 233;                      // Arrow code Buy (SYMBOL_ARROWUP)
input int ArrowCodeDown = 234;                    // Arrow code Sell (SYMBOL_ARROWDOWN)
input int Xoff = 20;                              // Horizontal spacing
input int Yoff = 20;                              // Vertical spacing
input string IndicatorName = "MQLTA-SMTF";        // Indicator prefix

// Buffers
double TrendUp[], TrendDown[], TrendDirection[];

// Internal State
bool UpTrend = false;
bool DownTrend = false;
bool TFEnabled[9];
ENUM_TIMEFRAMES TFValues[9];
string TFText[9];
int TFTrend[9];
double TFSTValue[9];
int TFHandles[9];

int LastAlertDirection = 2;
double DPIScale;
int PanelMovX, PanelMovY, PanelLabX, PanelLabY, PanelRecX, PanelBaseButtonHeight, PanelBaseButtonWidth, PanelWideButtonWidth, PanelWB_DPI;

//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
{
    IndicatorSetString(INDICATOR_SHORTNAME, IndicatorName);

    TFEnabled[0] = TFM1;  TFValues[0] = PERIOD_M1;  TFText[0] = "M1";
    TFEnabled[1] = TFM5;  TFValues[1] = PERIOD_M5;  TFText[1] = "M5";
    TFEnabled[2] = TFM15; TFValues[2] = PERIOD_M15; TFText[2] = "M15";
    TFEnabled[3] = TFM30; TFValues[3] = PERIOD_M30; TFText[3] = "M30";
    TFEnabled[4] = TFH1;  TFValues[4] = PERIOD_H1;  TFText[4] = "H1";
    TFEnabled[5] = TFH4;  TFValues[5] = PERIOD_H4;  TFText[5] = "H4";
    TFEnabled[6] = TFD1;  TFValues[6] = PERIOD_D1;  TFText[6] = "D1";
    TFEnabled[7] = TFW1;  TFValues[7] = PERIOD_W1;  TFText[7] = "W1";
    TFEnabled[8] = TFMN1; TFValues[8] = PERIOD_MN1; TFText[8] = "MN1";

    SetIndexBuffer(0, TrendUp, INDICATOR_DATA);
    SetIndexBuffer(1, TrendDown, INDICATOR_DATA);
    SetIndexBuffer(2, TrendDirection, INDICATOR_CALCULATIONS);

    ArraySetAsSeries(TrendUp, true);
    ArraySetAsSeries(TrendDown, true);
    ArraySetAsSeries(TrendDirection, true);

    for(int i=0; i<9; i++)
    {
        TFHandles[i] = INVALID_HANDLE;
        if(TFEnabled[i])
        {
            TFHandles[i] = iCustom(_Symbol, TFValues[i], SupertrendFileName, ATRPeriod, ATRMultiplier);
            if(TFHandles[i] == INVALID_HANDLE)
                Print("Failed to create handle for ", TFText[i], ". Check if ", SupertrendFileName, ".ex5 exists.");
        }
    }

    DPIScale = (double)TerminalInfoInteger(TERMINAL_SCREEN_DPI) / 96.0;
    PanelBaseButtonHeight = 20;
    PanelBaseButtonWidth = 50;
    PanelWideButtonWidth = 75;
    PanelMovX = (int)MathRound(PanelBaseButtonWidth * DPIScale);
    PanelMovY = (int)MathRound(PanelBaseButtonHeight * DPIScale);
    PanelLabX = (int)MathRound((2 * PanelBaseButtonWidth + PanelWideButtonWidth + 4) * DPIScale);
    PanelLabY = PanelMovY;
    PanelRecX = PanelLabX + (int)MathRound(4 * DPIScale);
    PanelWB_DPI = (int)MathRound(PanelWideButtonWidth * DPIScale);

    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Custom indicator deinitialization function                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    for(int i=0; i<9; i++)
    {
        if(TFHandles[i] != INVALID_HANDLE)
            IndicatorRelease(TFHandles[i]);
    }
    ObjectsDeleteAll(0, IndicatorName);
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
    if(rates_total < ATRPeriod + 2) return 0;

    int limit = rates_total - prev_calculated;
    if(limit > ATRMaxBars) limit = ATRMaxBars;
    
    // 1. Update Current Timeframe Lines
    if(DrawLinesEnabled)
    {
        ENUM_TIMEFRAMES currentTF = _Period;
        int currentIdx = -1;
        for(int i=0; i<9; i++) if(TFValues[i] == currentTF) { currentIdx = i; break; }

        if(currentIdx != -1 && TFHandles[currentIdx] != INVALID_HANDLE)
        {
            CopyBuffer(TFHandles[currentIdx], 0, 0, rates_total, TrendUp);
            CopyBuffer(TFHandles[currentIdx], 1, 0, rates_total, TrendDown);
        }
    }

    // 2. Calculate Multi-Timeframe Status
    CalculateLevels(time[rates_total-1]);

    // 3. UI and Notifications
    Notify();
    if(DrawArrowSignal) DrawArrow(time[rates_total-1], low[rates_total-1], high[rates_total-1]);
    if(DrawWindowEnabled) DrawPanel();

    return(rates_total);
}

//+------------------------------------------------------------------+
//| Calculate multi-timeframe trend status                           |
//+------------------------------------------------------------------+
void CalculateLevels(datetime currentBarTime)
{
    int EnabledCount = 0;
    int UpCount = 0;
    int DownCount = 0;
    UpTrend = false;
    DownTrend = false;

    for(int i=0; i<9; i++)
    {
        TFTrend[i] = 0;
        TFSTValue[i] = 0;
        if(!TFEnabled[i] || TFHandles[i] == INVALID_HANDLE) continue;

        EnabledCount++;
        
        int shift = iBarShift(_Symbol, TFValues[i], currentBarTime);
        int targetIdx = shift + (int)TriggerCandle;

        double dirBuffer[];
        if(CopyBuffer(TFHandles[i], DirectionBufferIndex, targetIdx, 1, dirBuffer) > 0)
        {
            TFTrend[i] = (int)dirBuffer[0];
        }

        double upBuf[], dnBuf[];
        if(CopyBuffer(TFHandles[i], 0, targetIdx, 1, upBuf) > 0 && upBuf[0] != EMPTY_VALUE)
            TFSTValue[i] = upBuf[0];
        else if(CopyBuffer(TFHandles[i], 1, targetIdx, 1, dnBuf) > 0 && dnBuf[0] != EMPTY_VALUE)
            TFSTValue[i] = dnBuf[0];

        if(TFTrend[i] > 0) UpCount++;
        else if(TFTrend[i] < 0) DownCount++;
    }

    if(UpCount == EnabledCount) UpTrend = true;
    else if(DownCount == EnabledCount) DownTrend = true;
}

//+------------------------------------------------------------------+
//| Notifications                                                    |
//+------------------------------------------------------------------+
void Notify()
{
    if(!EnableNotify) return;
    int currentSignal = (UpTrend ? 1 : (DownTrend ? -1 : 0));
    
    if(LastAlertDirection == 2) { LastAlertDirection = currentSignal; return; }
    if(currentSignal == LastAlertDirection) return;
    
    LastAlertDirection = currentSignal;
    string trendStr = (UpTrend ? "Uptrend" : (DownTrend ? "Downtrend" : "No trend"));
    string msg = IndicatorName + " - " + _Symbol + ": Pair is in " + trendStr;

    if(SendAlert) Alert(msg);
    if(SendEmail) SendMail(IndicatorName + " " + _Symbol, msg);
    if(SendApp)   SendNotification(msg);
}

//+------------------------------------------------------------------+
//| Draw Arrows                                                      |
//+------------------------------------------------------------------+
void DrawArrow(datetime time, double low, double high)
{
    if(!UpTrend && !DownTrend) return;
    
    string name = IndicatorName + "-ARW-" + TimeToString(time);
    if(ObjectFind(0, name) >= 0) return;

    ENUM_OBJECT type = (UpTrend ? OBJ_ARROW_UP : OBJ_ARROW_DOWN);
    double price = (UpTrend ? low : high);
    color clr = (UpTrend ? clrGreen : clrRed);
    int code = (UpTrend ? ArrowCodeUp : ArrowCodeDown);

    if(ObjectCreate(0, name, OBJ_ARROW, 0, time, price))
    {
        ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
        ObjectSetInteger(0, name, OBJPROP_BACK, false);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
    }
}

//+------------------------------------------------------------------+
//| Draw Dashboard Panel                                             |
//+------------------------------------------------------------------+
void DrawPanel()
{
    string base = IndicatorName + "-P-BAS";
    string label = IndicatorName + "-P-LAB";
    string sig = IndicatorName + "-P-SIG";
    int rows = 1;

    CreateEdit(label, Xoff + 2, Yoff + 2, PanelLabX, PanelLabY, "MT SUPERTREND", clrNavy, clrKhaki, 10);

    for(int i=0; i<9; i++)
    {
        if(!TFEnabled[i]) continue;
        
        string rowTxt = IndicatorName + "-P-TR-" + TFText[i];
        string rowVal = IndicatorName + "-P-TRV-" + TFText[i];
        string rowST  = IndicatorName + "-P-TRST-" + TFText[i];
        
        color back = clrKhaki, text = clrNavy;
        string dir = "-";
        
        if(TFTrend[i] == 1)  { dir = "UP";   back = clrDarkGreen; text = clrWhite; }
        if(TFTrend[i] == -1) { dir = "DOWN"; back = clrDarkRed;   text = clrWhite; }

        int yPos = Yoff + (int)MathRound(((PanelBaseButtonHeight + 1) * rows + 2) * DPIScale);
        
        CreateEdit(rowTxt, Xoff + 2, yPos, PanelMovX, PanelLabY, TFText[i], clrNavy, clrKhaki, 8);
        CreateEdit(rowVal, Xoff + (int)MathRound((PanelBaseButtonWidth + 4) * DPIScale), yPos, PanelMovX, PanelLabY, dir, text, back, 8);
        CreateEdit(rowST,  Xoff + (int)MathRound((PanelBaseButtonWidth * 2 + 6) * DPIScale), yPos, PanelWB_DPI, PanelLabY, DoubleToString(TFSTValue[i], _Digits), clrNavy, clrKhaki, 8);
        
        rows++;
    }

    string sigTxt = "Uncertain";
    color sigBack = clrKhaki, sigText = clrNavy;
    if(UpTrend)   { sigTxt = "Uptrend";   sigBack = clrDarkGreen; sigText = clrWhite; }
    if(DownTrend) { sigTxt = "Downtrend"; sigBack = clrDarkRed;   sigText = clrWhite; }

    int sigY = Yoff + (int)MathRound(((PanelBaseButtonHeight + 1) * rows + 2) * DPIScale);
    CreateEdit(sig, Xoff + 2, sigY, PanelLabX, PanelLabY, sigTxt, sigText, sigBack, 8);
    rows++;

    // Background Rectangle
    if(ObjectCreate(0, base, OBJ_RECTANGLE_LABEL, 0, 0, 0))
    {
        ObjectSetInteger(0, base, OBJPROP_XDISTANCE, Xoff);
        ObjectSetInteger(0, base, OBJPROP_YDISTANCE, Yoff);
        ObjectSetInteger(0, base, OBJPROP_XSIZE, PanelRecX);
        ObjectSetInteger(0, base, OBJPROP_YSIZE, (int)MathRound(((PanelBaseButtonHeight + 1) * rows + 3) * DPIScale));
        ObjectSetInteger(0, base, OBJPROP_BGCOLOR, clrWhite);
        ObjectSetInteger(0, base, OBJPROP_BORDER_TYPE, BORDER_FLAT);
        ObjectSetInteger(0, base, OBJPROP_COLOR, clrBlack);
        ObjectSetInteger(0, base, OBJPROP_HIDDEN, true);
        ObjectSetInteger(0, base, OBJPROP_SELECTABLE, false);
    }
}

// Helper to create panel elements
void CreateEdit(string name, int x, int y, int w, int h, string txt, color clr, color bg, int fontSize)
{
    if(ObjectCreate(0, name, OBJ_EDIT, 0, 0, 0))
    {
        ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
        ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
        ObjectSetInteger(0, name, OBJPROP_XSIZE, w);
        ObjectSetInteger(0, name, OBJPROP_YSIZE, h);
        ObjectSetString(0, name, OBJPROP_TEXT, txt);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
        ObjectSetInteger(0, name, OBJPROP_FONTSIZE, fontSize);
        ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
        ObjectSetInteger(0, name, OBJPROP_ALIGN, ALIGN_CENTER);
        ObjectSetInteger(0, name, OBJPROP_READONLY, true);
        ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
        ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        ObjectSetInteger(0, name, OBJPROP_BORDER_COLOR, clrBlack);
    }
    else
    {
        ObjectSetString(0, name, OBJPROP_TEXT, txt);
        ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
        ObjectSetInteger(0, name, OBJPROP_BGCOLOR, bg);
    }
}