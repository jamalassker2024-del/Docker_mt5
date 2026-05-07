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
//|                                   Triangular_Arbitrage_VALETAX.mq5|
//|                     For .vx symbols, fast profit exit            |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex Arbitrage"
#property version   "3.0"
#property strict

// --- INPUTS (CHANGE THESE TO YOUR BROKER'S SYMBOLS) ---------------+
input string   Symbol1         = "GBPUSD.vx";     // Leg 1 (e.g., GBPUSD.vx)
input string   Symbol2         = "USDJPY.vx";     // Leg 2
input string   Symbol3         = "GBPJPY.vx";     // Synthetic cross
input double   RiskPercent     = 3.0;             // % equity per basket
input int      MinProfitPoints = 0;               // Any positive mispricing triggers trade (set to 0 for test)
input int      MaxOpenBaskets  = 2;               // Max concurrent baskets
input int      MagicNumber     = 888999;
input int      StartHour       = 0;               // 24/7 for testing
input int      EndHour         = 24;
input bool     DebugPrint      = true;            // Show prices every 5 sec

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime last_debug = 0;
datetime last_trade = 0;

struct Basket {
   ulong t1, t2, t3;
   bool closed;
};
Basket baskets[];
int activeBaskets = 0;

//+------------------------------------------------------------------+
//| Check if we are inside trading hours (simplified)               |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
//| Close a basket and mark as closed                               |
//+------------------------------------------------------------------+
void CloseBasket(int idx) {
   if(baskets[idx].t1 > 0) trade.PositionClose(baskets[idx].t1);
   if(baskets[idx].t2 > 0) trade.PositionClose(baskets[idx].t2);
   if(baskets[idx].t3 > 0) trade.PositionClose(baskets[idx].t3);
   baskets[idx].closed = true;
   Print("🕒 Closed basket #", idx);
}

//+------------------------------------------------------------------+
//| Calculate mispricing in POINTS directly (no percentage)         |
//| Returns: positive = synthetic cheaper -> buy synthetic; negative = synthetic dearer -> sell synthetic |
//+------------------------------------------------------------------+
double CalcMispricingPoints() {
   // Get bid/ask for each leg
   double bid1 = SymbolInfoDouble(Symbol1, SYMBOL_BID);
   double ask1 = SymbolInfoDouble(Symbol1, SYMBOL_ASK);
   double bid2 = SymbolInfoDouble(Symbol2, SYMBOL_BID);
   double ask2 = SymbolInfoDouble(Symbol2, SYMBOL_ASK);
   double bid3 = SymbolInfoDouble(Symbol3, SYMBOL_BID);
   double ask3 = SymbolInfoDouble(Symbol3, SYMBOL_ASK);
   
   if(bid1<=0 || ask1<=0 || bid2<=0 || ask2<=0 || bid3<=0 || ask3<=0) {
      if(DebugPrint && TimeCurrent()-last_debug>=5)
         Print("❌ Missing price data for one of the symbols");
      return 0;
   }
   
   // Synthetic bid (buying synthetic means buying leg1 and leg2)
   double synthetic_bid = bid1 * bid2;
   // Actual market mid
   double actual_mid = (bid3 + ask3) / 2.0;
   
   // Mispricing in price difference (NOT points yet)
   double mispricing_price = synthetic_bid - actual_mid;
   
   // Get point size for the cross (Symbol3). For JPY pairs, point = 0.001; for non-JPY, point = 0.00001 typically
   double point3 = SymbolInfoDouble(Symbol3, SYMBOL_POINT);
   if(point3 <= 0) {
      // Fallback: detect JPY pair
      if(StringFind(Symbol3, "JPY") >= 0) point3 = 0.001;
      else point3 = 0.00001;
   }
   
   double mispricing_points = mispricing_price / point3;
   return mispricing_points;
}

//+------------------------------------------------------------------+
//| OnInit                                                          |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   // Ensure symbols are visible in Market Watch
   SymbolSelect(Symbol1, true);
   SymbolSelect(Symbol2, true);
   SymbolSelect(Symbol3, true);
   Print("==============================================");
   Print("🔺 TRIANGULAR ARBITRAGE EA (for .vx symbols)");
   Print("   Triangle: ", Symbol1, " + ", Symbol2, " → ", Symbol3);
   Print("   MinProfitPoints = ", MinProfitPoints);
   Print("   Trading hours: ", StartHour, ":00 - ", EndHour, ":00");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnTick                                                          |
//+------------------------------------------------------------------+
void OnTick() {
   // Session filter
   if(!IsTradingTime()) {
      for(int i=0; i<ArraySize(baskets); i++) if(!baskets[i].closed) CloseBasket(i);
      return;
   }
   
   // --- Close any basket with positive total profit (fast out) ---
   for(int i=0; i<ArraySize(baskets); i++) {
      if(baskets[i].closed) continue;
      double profit = 0;
      if(PositionSelectByTicket(baskets[i].t1)) profit += PositionGetDouble(POSITION_PROFIT);
      if(PositionSelectByTicket(baskets[i].t2)) profit += PositionGetDouble(POSITION_PROFIT);
      if(PositionSelectByTicket(baskets[i].t3)) profit += PositionGetDouble(POSITION_PROFIT);
      if(profit > 0) {
         CloseBasket(i);
         Print("✅ Basket closed with profit: $", profit);
      }
   }
   // Remove closed baskets from array
   for(int i=ArraySize(baskets)-1; i>=0; i--) {
      if(baskets[i].closed) {
         for(int j=i; j<ArraySize(baskets)-1; j++) baskets[j] = baskets[j+1];
         ArrayResize(baskets, ArraySize(baskets)-1);
      }
   }
   
   // --- Position limit and cooldown ---
   if(ArraySize(baskets) >= MaxOpenBaskets) return;
   if(TimeCurrent() - last_trade < 5) return;
   
   // --- Calculate mispricing in points ---
   double mispricing = CalcMispricingPoints();
   
   // --- Debug print every 5 seconds ---
   if(DebugPrint && TimeCurrent() - last_debug >= 5) {
      last_debug = TimeCurrent();
      double bid1 = SymbolInfoDouble(Symbol1, SYMBOL_BID);
      double bid2 = SymbolInfoDouble(Symbol2, SYMBOL_BID);
      double bid3 = SymbolInfoDouble(Symbol3, SYMBOL_BID);
      double ask3 = SymbolInfoDouble(Symbol3, SYMBOL_ASK);
      double synthetic = bid1 * bid2;
      double actual_mid = (bid3 + ask3)/2.0;
      Print("========================================");
      Print("📊 ", Symbol1, " bid: ", bid1, " | ", Symbol2, " bid: ", bid2);
      Print("📊 ", Symbol3, " bid: ", bid3, " ask: ", ask3);
      Print("📊 Synthetic bid: ", synthetic, " | Actual mid: ", actual_mid);
      Print("📉 Mispricing: ", DoubleToString(mispricing,2), " points");
      Print("🔍 Active baskets: ", ArraySize(baskets));
      Print("========================================");
   }
   
   // Check if mispricing exceeds threshold
   if(MathAbs(mispricing) < MinProfitPoints) return;
   
   // Determine direction
   bool buySynthetic = (mispricing > MinProfitPoints);
   bool sellSynthetic = (mispricing < -MinProfitPoints);
   if(!buySynthetic && !sellSynthetic) return;
   
   // --- Calculate lot size ---
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = NormalizeDouble(equity / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   // Ensure lot is within broker limits
   double maxLot = SymbolInfoDouble(Symbol1, SYMBOL_VOLUME_MAX);
   lot = MathMin(lot, maxLot);
   
   Basket newBasket;
   newBasket.closed = false;
   newBasket.t1 = 0; newBasket.t2 = 0; newBasket.t3 = 0;
   
   if(buySynthetic) {
      // Synthetic cheaper → buy leg1 & leg2, sell leg3
      newBasket.t1 = trade.Buy(lot, Symbol1, SymbolInfoDouble(Symbol1, SYMBOL_ASK), 0, 0, "TriLeg1");
      newBasket.t2 = trade.Buy(lot, Symbol2, SymbolInfoDouble(Symbol2, SYMBOL_ASK), 0, 0, "TriLeg2");
      newBasket.t3 = trade.Sell(lot, Symbol3, SymbolInfoDouble(Symbol3, SYMBOL_BID), 0, 0, "TriLeg3");
   } else {
      // Synthetic overpriced → sell leg1 & leg2, buy leg3
      newBasket.t1 = trade.Sell(lot, Symbol1, SymbolInfoDouble(Symbol1, SYMBOL_BID), 0, 0, "TriLeg1");
      newBasket.t2 = trade.Sell(lot, Symbol2, SymbolInfoDouble(Symbol2, SYMBOL_BID), 0, 0, "TriLeg2");
      newBasket.t3 = trade.Buy(lot, Symbol3, SymbolInfoDouble(Symbol3, SYMBOL_ASK), 0, 0, "TriLeg3");
   }
   
   // Verify all three trades succeeded
   if(newBasket.t1 && newBasket.t2 && newBasket.t3) {
      int sz = ArraySize(baskets);
      ArrayResize(baskets, sz+1);
      baskets[sz] = newBasket;
      last_trade = TimeCurrent();
      Print("🔥 Basket opened! Mispricing: ", DoubleToString(mispricing,2), " points");
      Print("   Trades: ", (buySynthetic?"Buy Synthetic":"Sell Synthetic"));
   } else {
      // Partial fill – close any opened legs
      if(newBasket.t1) trade.PositionClose(newBasket.t1);
      if(newBasket.t2) trade.PositionClose(newBasket.t2);
      if(newBasket.t3) trade.PositionClose(newBasket.t3);
      Print("❌ Failed to execute full basket, retrying later.");
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
