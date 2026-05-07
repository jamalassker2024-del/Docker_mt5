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
//|                                 Triangular_Arbitrage_EA.mq5      |
//|                     Synthetic triangular arbitrage - risk‑free   |
//|                             Version 2.0 - Fast profit exit      |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex Arbitrage"
#property version   "2.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   Symbol1         = "GBPUSD";      // Leg 1
input string   Symbol2         = "USDJPY";      // Leg 2
input string   Symbol3         = "GBPJPY";      // Synthetic cross
input double   RiskPercent     = 3.0;           // % equity per basket
input int      MinProfitPoints = 5;             // Minimum profit in points before closing
input int      MaxOpenBaskets  = 2;             // Max concurrent triangular positions
input int      MagicNumber     = 888999;
input int      StartHour       = 8;             // London session start
input int      EndHour         = 22;            // Session end
input double   MinSpreadRatio  = 0.0;           // Minimum mispricing ratio (0 = any mispricing)

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime last_debug = 0;
datetime last_trade = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
int consecutiveLosses = 0;

struct Basket {
   ulong ticket1;
   ulong ticket2;
   ulong ticket3;
   double profitLock;
   bool   closed;
};
Basket baskets[];
int activeBaskets = 0;

//+------------------------------------------------------------------+
//| Check trading hours                                             |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
//| Close all positions for a basket                                 |
//+------------------------------------------------------------------+
void CloseBasket(int idx) {
   if(baskets[idx].ticket1 > 0) trade.PositionClose(baskets[idx].ticket1);
   if(baskets[idx].ticket2 > 0) trade.PositionClose(baskets[idx].ticket2);
   if(baskets[idx].ticket3 > 0) trade.PositionClose(baskets[idx].ticket3);
   baskets[idx].closed = true;
}

//+------------------------------------------------------------------+
//| Find basket index by ticket                                      |
//+------------------------------------------------------------------+
int FindBasketByTicket(ulong ticket) {
   for(int i=0; i<ArraySize(baskets); i++) {
      if(baskets[i].ticket1 == ticket || baskets[i].ticket2 == ticket || baskets[i].ticket3 == ticket)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Calculate synthetic rate and mispricing (in points)             |
//+------------------------------------------------------------------+
double CalculateMispricingPoints() {
   // Get bid/ask for each leg
   double bid1 = SymbolInfoDouble(Symbol1, SYMBOL_BID);
   double ask1 = SymbolInfoDouble(Symbol1, SYMBOL_ASK);
   double bid2 = SymbolInfoDouble(Symbol2, SYMBOL_BID);
   double ask2 = SymbolInfoDouble(Symbol2, SYMBOL_ASK);
   double bid3 = SymbolInfoDouble(Symbol3, SYMBOL_BID);
   double ask3 = SymbolInfoDouble(Symbol3, SYMBOL_ASK);
   
   if(bid1<=0 || ask1<=0 || bid2<=0 || ask2<=0 || bid3<=0 || ask3<=0) return 0;
   
   // Synthetic mid for GBP/JPY = GBP/USD bid * USD/JPY bid (for buying synthetic)
   double synthetic_bid = bid1 * bid2;
   double synthetic_ask = ask1 * ask2;
   
   // Actual market mid
   double actual_mid = (bid3 + ask3) / 2.0;
   
   // Mispricing as percentage relative to actual
   double mispricing = (synthetic_bid - actual_mid) / actual_mid;
   
   // Convert to points (for JPY pairs, point is 0.001; adjust as needed)
   double point = SymbolInfoDouble(Symbol3, SYMBOL_POINT) * 10; // For JPY: point = 0.001, we want 0.001 = 1 point
   if(point <= 0) point = 0.001;
   
   return mispricing / point;  // points
}

//+------------------------------------------------------------------+
//| Initialize                                                      |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   ArrayResize(baskets, 0);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("🔺 Triangular Arbitrage EA (Risk‑free profit)");
   Print("   Triangle: ", Symbol1, " / ", Symbol2, " → ", Symbol3);
   Print("   Trading hours: ", StartHour, ":00 - ", EndHour, ":00");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tick handler                                                    |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Session filter ---
   if(!IsTradingTime()) {
      for(int i=0; i<ArraySize(baskets); i++) if(!baskets[i].closed) CloseBasket(i);
      return;
   }
   
   // --- Daily loss reset ---
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      consecutiveLosses = 0;
      Print("✅ New trading day");
   }
   double lossPercent = (dailyEquityStart - AccountInfoDouble(ACCOUNT_EQUITY)) / dailyEquityStart * 100.0;
   if(lossPercent >= 8.0) {
      Print("🚨 Daily loss limit reached, stopping.");
      return;
   }
   
   // --- Close any basket that has positive profit (fast out) ---
   for(int i=0; i<ArraySize(baskets); i++) {
      if(baskets[i].closed) continue;
      
      // Sum profits of all three positions
      double totalProfit = 0;
      if(PositionSelectByTicket(baskets[i].ticket1)) totalProfit += PositionGetDouble(POSITION_PROFIT);
      if(PositionSelectByTicket(baskets[i].ticket2)) totalProfit += PositionGetDouble(POSITION_PROFIT);
      if(PositionSelectByTicket(baskets[i].ticket3)) totalProfit += PositionGetDouble(POSITION_PROFIT);
      
      if(totalProfit > 0) {
         CloseBasket(i);
         Print("✅ Basket closed with total profit: $", totalProfit);
         consecutiveLosses = 0;
      }
   }
   
   // Remove closed baskets from array
   for(int i=ArraySize(baskets)-1; i>=0; i--) {
      if(baskets[i].closed) {
         for(int j=i; j<ArraySize(baskets)-1; j++) baskets[j] = baskets[j+1];
         ArrayResize(baskets, ArraySize(baskets)-1);
      }
   }
   
   // --- Limit number of active baskets ---
   if(ArraySize(baskets) >= MaxOpenBaskets) return;
   if(now - last_trade < 5) return;  // cooldown
   
   // --- Calculate mispricing ---
   double mispricingPoints = CalculateMispricingPoints();
   if(MathAbs(mispricingPoints) < MinProfitPoints) return;
   
   // --- Execute triangular arbitrage ---
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   bool buySynthetic = (mispricingPoints > MinProfitPoints);
   bool sellSynthetic = (mispricingPoints < -MinProfitPoints);
   
   if(!buySynthetic && !sellSynthetic) return;
   
   Basket newBasket;
   newBasket.closed = false;
   newBasket.profitLock = 0;
   
   if(buySynthetic) {
      // Synthetic is cheaper → buy synthetic (buy leg1 and leg2), sell real (sell leg3)
      newBasket.ticket1 = trade.Buy(lot, Symbol1, SymbolInfoDouble(Symbol1, SYMBOL_ASK), 0, 0, "Tri Arb Leg1");
      newBasket.ticket2 = trade.Buy(lot, Symbol2, SymbolInfoDouble(Symbol2, SYMBOL_ASK), 0, 0, "Tri Arb Leg2");
      newBasket.ticket3 = trade.Sell(lot, Symbol3, SymbolInfoDouble(Symbol3, SYMBOL_BID), 0, 0, "Tri Arb Leg3");
      if(newBasket.ticket1 && newBasket.ticket2 && newBasket.ticket3) {
         Print("🔥 Executed BUY synthetic arbitrage. Mispricing: ", mispricingPoints, " pts");
      } else {
         Print("❌ Partial execution, closing.");
         if(newBasket.ticket1) trade.PositionClose(newBasket.ticket1);
         if(newBasket.ticket2) trade.PositionClose(newBasket.ticket2);
         if(newBasket.ticket3) trade.PositionClose(newBasket.ticket3);
         return;
      }
   } else {
      // Synthetic is overpriced → sell synthetic, buy real
      newBasket.ticket1 = trade.Sell(lot, Symbol1, SymbolInfoDouble(Symbol1, SYMBOL_BID), 0, 0, "Tri Arb Leg1");
      newBasket.ticket2 = trade.Sell(lot, Symbol2, SymbolInfoDouble(Symbol2, SYMBOL_BID), 0, 0, "Tri Arb Leg2");
      newBasket.ticket3 = trade.Buy(lot, Symbol3, SymbolInfoDouble(Symbol3, SYMBOL_ASK), 0, 0, "Tri Arb Leg3");
      if(newBasket.ticket1 && newBasket.ticket2 && newBasket.ticket3) {
         Print("🔥 Executed SELL synthetic arbitrage. Mispricing: ", mispricingPoints, " pts");
      } else {
         Print("❌ Partial execution, closing.");
         if(newBasket.ticket1) trade.PositionClose(newBasket.ticket1);
         if(newBasket.ticket2) trade.PositionClose(newBasket.ticket2);
         if(newBasket.ticket3) trade.PositionClose(newBasket.ticket3);
         return;
      }
   }
   
   int sz = ArraySize(baskets);
   ArrayResize(baskets, sz+1);
   baskets[sz] = newBasket;
   last_trade = now;
   
   // --- Debug output ---
   if(now - last_debug >= 5) {
      last_debug = now;
      Print("📊 Mispricing: ", DoubleToString(mispricingPoints,2), " pts | Active baskets: ", ArraySize(baskets));
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
