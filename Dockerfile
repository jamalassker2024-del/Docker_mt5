FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# =========================================================
# V16.3 - PROFIT-MAX VELOCITY BOT (ULTRA PROFITABILITY)
# =========================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                        Aggressive_Scalper_200usd |
//|                                           Target: $200/day on $1k|
//|                                                   High Win Rate  |
//+------------------------------------------------------------------+
#property copyright "Scalper Pro"
#property version   "2.00"
#property strict

// --- Inputs (Configure for maximum aggression) ---
input string   t1 = "==== Risk & Money ====";
input double   RiskPercent       = 5.0;        // Risk per trade (% of equity)
input int      StopLossPoints    = 120;        // Stop Loss in points (12 pips for 5-digit broker)
input int      TakeProfitPoints  = 60;         // Take Profit in points (6 pips)
input int      MaxConcurrentTrades = 3;        // Max positions at once
input int      MagicNumber       = 20260505;

input string   t2 = "==== Entry Filters ====";
input int      RsiPeriod         = 6;          // Fast RSI for scalping
input int      RsiOversold       = 25;         // Buy when RSI < 25
input int      RsiOverbought     = 75;         // Sell when RSI > 75
input double   MinATRMultiplier  = 0.5;        // Minimum ATR (avoid chop)
input int      ATRPeriod         = 14;

input string   t3 = "==== Risk Management ====";
input double   DailyTargetUSD    = 200.0;      // Stop trading after $200 profit (optional)
input double   MaxDailyLossUSD   = 100.0;      // Stop after $100 loss
input int      MaxSpreadPoints   = 20;         // Max spread in points (2 pips)
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 50;         // Activate at 5 pips profit
input int      TrailingStepPts   = 30;         // Step 3 pips

// --- Globals ---
CTrade trade;
int rsi_handle, atr_handle;
double rsi_buf[], atr_buf[];
datetime lastBarTime = 0;
double dailyProfit = 0.0;
double startingEquity = 0.0;
bool tradingHalted = false;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   // Indicator handles
   rsi_handle = iRSI(_Symbol, PERIOD_CURRENT, RsiPeriod, PRICE_CLOSE);
   atr_handle = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);
   if(rsi_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE) {
      Print("Error creating indicators");
      return INIT_FAILED;
   }
   
   ArraySetAsSeries(rsi_buf, true);
   ArraySetAsSeries(atr_buf, true);
   
   startingEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   tradingHalted = false;
   
   Print("==========================================");
   Print("🚀 AGGRESSIVE SCALPER ACTIVE");
   Print("   Risk per trade: ", RiskPercent, "%");
   Print("   TP: ", TakeProfitPoints/10.0, " pips | SL: ", StopLossPoints/10.0, " pips");
   Print("   Daily Target: $", DailyTargetUSD, " | Max Loss: $", MaxDailyLossUSD);
   Print("   Target return: $200/day on $1000 = 20% daily (HIGH RISK)");
   Print("==========================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                               |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(rsi_handle);
   IndicatorRelease(atr_handle);
}

//+------------------------------------------------------------------+
//| Main tick function (fast scalping)                              |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily profit/loss tracking ---
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   dailyProfit = currentEquity - startingEquity;
   
   if(dailyProfit >= DailyTargetUSD) {
      if(!tradingHalted) Print("🎯 Daily target reached: $", dailyProfit, " - Trading halted");
      tradingHalted = true;
      return;
   }
   if(dailyProfit <= -MaxDailyLossUSD) {
      if(!tradingHalted) Print("💀 Daily loss limit reached: $", dailyProfit, " - Trading halted");
      tradingHalted = true;
      return;
   }
   if(tradingHalted) {
      // Reset at midnight (broker time)
      static datetime lastMidnight = 0;
      datetime now = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(now, dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime midnight = StructToTime(dt);
      if(midnight != lastMidnight) {
         lastMidnight = midnight;
         tradingHalted = false;
         startingEquity = currentEquity;
         Print("🔄 New day - Trading resumed");
      }
      return;
   }
   
   // --- Spread check ---
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   // --- Update indicators (every tick) ---
   CopyBuffer(rsi_handle, 0, 0, 3, rsi_buf);
   CopyBuffer(atr_handle, 0, 0, 3, atr_buf);
   double rsi = rsi_buf[0];
   double atr = atr_buf[0];
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atrPips = atr / point / 10.0;
   
   // Skip if volatility too low
   if(atrPips < MinATRMultiplier) return;
   
   // --- Count open positions ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      if(PositionSelectByTicket(PositionGetTicket(i))) {
         if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) posCount++;
      }
   }
   if(posCount >= MaxConcurrentTrades) return;
   
   // --- Detect engulfing patterns (price action) ---
   bool bullishEngulf = IsBullishEngulfing();
   bool bearishEngulf = IsBearishEngulfing();
   
   // --- Signal logic ---
   bool buySignal = (rsi < RsiOversold && bullishEngulf) || (rsi < RsiOversold-5);
   bool sellSignal = (rsi > RsiOverbought && bearishEngulf) || (rsi > RsiOverbought+5);
   
   // --- Apply trailing stop to existing positions (fast exit)---
   if(UseTrailingStop) ApplyTrailingStop();
   
   // --- Execute trades ---
   if(buySignal && posCount == 0) {  // Only enter if no positions to avoid overloading
      double lot = CalculateLotSize(ORDER_TYPE_BUY);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = ask - StopLossPoints * point;
      double tp = ask + TakeProfitPoints * point;
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      if(trade.Buy(lot, _Symbol, ask, sl, tp, "AggScalp BUY")) {
         Print("🔥 BUY | RSI=", rsi, " | Lot=", lot, " | TP=", tp, " | SL=", sl);
      }
   }
   else if(sellSignal && posCount == 0) {
      double lot = CalculateLotSize(ORDER_TYPE_SELL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = bid + StopLossPoints * point;
      double tp = bid - TakeProfitPoints * point;
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      
      if(trade.Sell(lot, _Symbol, bid, sl, tp, "AggScalp SELL")) {
         Print("🔥 SELL | RSI=", rsi, " | Lot=", lot, " | TP=", tp, " | SL=", sl);
      }
   }
}

//+------------------------------------------------------------------+
//| Detect Bullish Engulfing (current candle closes above previous high) |
//+------------------------------------------------------------------+
bool IsBullishEngulfing() {
   double close0 = iClose(_Symbol, PERIOD_CURRENT, 0);
   double open0 = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   
   if(close0 > open0 && close1 < open1) {   // current bullish, previous bearish
      if(close0 > open1 && open0 < close1) // engulfing condition
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Detect Bearish Engulfing                                          |
//+------------------------------------------------------------------+
bool IsBearishEngulfing() {
   double close0 = iClose(_Symbol, PERIOD_CURRENT, 0);
   double open0 = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double close1 = iClose(_Symbol, PERIOD_CURRENT, 1);
   double open1 = iOpen(_Symbol, PERIOD_CURRENT, 1);
   
   if(close0 < open0 && close1 > open1) {   // current bearish, previous bullish
      if(close0 < open1 && open0 > close1) // engulfing
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percent                         |
//+------------------------------------------------------------------+
double CalculateLotSize(int orderType) {
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double stopDistPoints = StopLossPoints;
   double stopLossValue = stopDistPoints * tickValue;
   double lot = riskAmount / stopLossValue;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathMax(minLot, MathMin(maxLot, lot));
   lot = MathRound(lot / stepLot) * stepLot;
   return lot;
}

//+------------------------------------------------------------------+
//| Apply trailing stop to all open positions                        |
//+------------------------------------------------------------------+
void ApplyTrailingStop() {
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double currentSL = PositionGetDouble(POSITION_SL);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ?
                               SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                               SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPoints = (currentPrice - openPrice) / _Point;
         if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
            profitPoints = -profitPoints;
         
         if(profitPoints >= TrailingStartPts) {
            double newSL = 0;
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
               newSL = currentPrice - TrailingStepPts * _Point;
               if(newSL > currentSL) {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            } else {
               newSL = currentPrice + TrailingStepPts * _Point;
               if(newSL < currentSL || currentSL == 0) {
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
               }
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 3. INSTALLATION & ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT_V16.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" /log:"/root/compile.log"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
