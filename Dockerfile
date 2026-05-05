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
//|                                           Cent_Scalper_10USD.mq5 |
//|                     Target: $2/day from $10 cent account         |
//|                                  High win rate, fast in/out      |
//+------------------------------------------------------------------+
#property copyright "Cent Scalper"
#property version   "2.10"
#property strict

// --- Inputs (aggressive but realistic for $10) ---
input string   t1 = "==== Risk & Money ====";
input double   RiskPercent       = 10.0;       // % of equity per trade (10% = $1 risk on $10)
input int      StopLossPoints    = 120;        // 12 pips (for 5-digit broker)
input int      TakeProfitPoints  = 60;         // 6 pips
input int      MaxConcurrentTrades = 2;        // Max positions at once
input int      MagicNumber       = 20260506;

input string   t2 = "==== Entry Filters ====";
input int      RsiPeriod         = 5;          // Very fast RSI
input int      RsiOversold       = 20;         // Oversold level
input int      RsiOverbought     = 80;         // Overbought level
input double   MinATRMultiplier  = 0.3;        // Min ATR in pips (avoid dead market)
input int      ATRPeriod         = 14;

input string   t3 = "==== Daily Limits (in cents) ====";
input double   DailyTargetUSD    = 2.0;        // Stop after $2 profit
input double   MaxDailyLossUSD   = 1.0;        // Stop after $1 loss
input int      MaxSpreadPoints   = 25;         // Max spread in points (2.5 pips)
input bool     UseTrailingStop   = true;
input int      TrailingStartPts  = 40;         // Activate at 4 pips profit
input int      TrailingStepPts   = 20;         // Trail by 2 pips

// --- Globals ---
CTrade trade;
int rsi_handle, atr_handle;
double rsi_buf[], atr_buf[];
datetime lastBarTime = 0;
double dailyProfitCents = 0.0;
double startingBalanceCents = 0.0;
bool tradingHalted = false;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_FOK);
   
   rsi_handle = iRSI(_Symbol, PERIOD_M1, RsiPeriod, PRICE_CLOSE);
   atr_handle = iATR(_Symbol, PERIOD_M1, ATRPeriod);
   if(rsi_handle == INVALID_HANDLE || atr_handle == INVALID_HANDLE) return INIT_FAILED;
   
   ArraySetAsSeries(rsi_buf, true);
   ArraySetAsSeries(atr_buf, true);
   
   // Convert to cents for tracking (balance is in USD, but cent account multiplies by 100)
   // Actually, AccountInfoDouble returns USD-equivalent, so we keep as USD but target $2.
   startingBalanceCents = AccountInfoDouble(ACCOUNT_BALANCE); // in USD
   tradingHalted = false;
   
   Print("==========================================");
   Print("💰 CENT ACCOUNT SCALPER ACTIVE");
   Print("   Balance: $", startingBalanceCents);
   Print("   Risk per trade: ", RiskPercent, "% ( ~$", startingBalanceCents*RiskPercent/100, ")");
   Print("   TP: ", TakeProfitPoints/10.0, " pips | SL: ", StopLossPoints/10.0, " pips");
   Print("   Daily Target: $", DailyTargetUSD, " | Stop Loss: $", MaxDailyLossUSD);
   Print("   Target: $2/day from $10 = 20% daily");
   Print("==========================================");
   
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(rsi_handle);
   IndicatorRelease(atr_handle);
}

//+------------------------------------------------------------------+
//| Tick function                                                   |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily profit/loss tracking in USD ---
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   dailyProfitCents = currentBalance - startingBalanceCents;
   
   if(dailyProfitCents >= DailyTargetUSD) {
      if(!tradingHalted) Print("🎯 Daily target reached: $", dailyProfitCents, " - Halted");
      tradingHalted = true;
      return;
   }
   if(dailyProfitCents <= -MaxDailyLossUSD) {
      if(!tradingHalted) Print("💀 Daily loss limit hit: $", dailyProfitCents, " - Halted");
      tradingHalted = true;
      return;
   }
   if(tradingHalted) {
      static datetime lastMidnight = 0;
      datetime now = TimeCurrent();
      MqlDateTime dt;
      TimeToStruct(now, dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      datetime midnight = StructToTime(dt);
      if(midnight != lastMidnight) {
         lastMidnight = midnight;
         tradingHalted = false;
         startingBalanceCents = currentBalance;
         Print("🔄 New day - Resuming");
      }
      return;
   }
   
   // --- Spread check ---
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > MaxSpreadPoints) return;
   
   // --- Indicator updates ---
   CopyBuffer(rsi_handle, 0, 0, 3, rsi_buf);
   CopyBuffer(atr_handle, 0, 0, 3, atr_buf);
   double rsi = rsi_buf[0];
   double atr = atr_buf[0];
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double atrPips = atr / point / 10.0;
   if(atrPips < MinATRMultiplier) return;
   
   // --- Count positions ---
   int posCount = 0;
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         posCount++;
   }
   if(posCount >= MaxConcurrentTrades) return;
   
   // --- Engulfing detection ---
   bool bullishEngulf = IsBullishEngulfing();
   bool bearishEngulf = IsBearishEngulfing();
   
   bool buySignal = (rsi < RsiOversold && bullishEngulf) || (rsi < RsiOversold-5);
   bool sellSignal = (rsi > RsiOverbought && bearishEngulf) || (rsi > RsiOverbought+5);
   
   // --- Trailing stop ---
   if(UseTrailingStop) ApplyTrailingStop();
   
   // --- Execute ---
   if(buySignal && posCount == 0) {
      double lot = CalculateLotSize(ORDER_TYPE_BUY);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl = ask - StopLossPoints * point;
      double tp = ask + TakeProfitPoints * point;
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      if(trade.Buy(lot, _Symbol, ask, sl, tp, "CentBuy")) {
         Print("🔥 BUY | RSI=", rsi, " | Lot=", lot, " | TP=", tp);
      }
   }
   else if(sellSignal && posCount == 0) {
      double lot = CalculateLotSize(ORDER_TYPE_SELL);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl = bid + StopLossPoints * point;
      double tp = bid - TakeProfitPoints * point;
      sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      if(trade.Sell(lot, _Symbol, bid, sl, tp, "CentSell")) {
         Print("🔥 SELL | RSI=", rsi, " | Lot=", lot, " | TP=", tp);
      }
   }
}

//+------------------------------------------------------------------+
//| Helper: Bullish Engulfing                                       |
//+------------------------------------------------------------------+
bool IsBullishEngulfing() {
   double c0 = iClose(_Symbol, PERIOD_M1, 0), o0 = iOpen(_Symbol, PERIOD_M1, 0);
   double c1 = iClose(_Symbol, PERIOD_M1, 1), o1 = iOpen(_Symbol, PERIOD_M1, 1);
   return (c0 > o0 && c1 < o1 && c0 > o1 && o0 < c1);
}

//+------------------------------------------------------------------+
//| Helper: Bearish Engulfing                                       |
//+------------------------------------------------------------------+
bool IsBearishEngulfing() {
   double c0 = iClose(_Symbol, PERIOD_M1, 0), o0 = iOpen(_Symbol, PERIOD_M1, 0);
   double c1 = iClose(_Symbol, PERIOD_M1, 1), o1 = iOpen(_Symbol, PERIOD_M1, 1);
   return (c0 < o0 && c1 > o1 && c0 < o1 && o0 > c1);
}

//+------------------------------------------------------------------+
//| Lot size calculation for cent account (minimum 0.01)            |
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
   lot = MathMax(0.01, lot);   // Ensure minimum 0.01 lot
   return lot;
}

//+------------------------------------------------------------------+
//| Trailing stop application                                       |
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
               if(newSL > currentSL)
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            } else {
               newSL = currentPrice + TrailingStepPts * _Point;
               if(newSL < currentSL || currentSL == 0)
                  trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
            }
         }
      }
   }
}
//+------------------------------------------------------------------+
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
