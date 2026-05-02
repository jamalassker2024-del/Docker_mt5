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
//|                                        BidAskPressureFast.mq5   |
//|                     Fast in/out on profit using bid/ask tick rate|
//+------------------------------------------------------------------+
#property copyright "Omni-Apex"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS --------------------------------------------------------+
input double   RiskPercent       = 5.0;          // % of equity per trade
input int      WindowMs          = 2000;         // Rolling window (milliseconds)
input int      MinNetPressure    = 1;            // Minimum net pressure to trigger trade
input int      MaxOpenPositions  = 20;
input int      MagicNumber       = 777888;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
struct TickRecord {
   datetime time_ms;
   int      pressure;     // +1 for ask change, -1 for bid change
};
TickRecord buffer[];
int totalPressure = 0;
datetime lastDebug = 0;
double lastAsk = 0, lastBid = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   ArrayResize(buffer, 0);
   // Initialize last prices
   lastAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   lastBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   Print("==============================================");
   Print("🟢 BID/ASK PRESSURE EA (Tick Frequency)");
   Print("   Window: ", WindowMs, " ms | MinPressure: ", MinNetPressure);
   Print("   Risk: ", RiskPercent, "% | Fast close on profit");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Close any position with profit > 0
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0.0) {
            if(trade.PositionClose(ticket))
               Print("✅ [CLOSE] Ticket ", ticket, " profit: ", profit);
            else
               Print("❌ [CLOSE] Error: ", GetLastError());
         }
      }
   }
   
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // 2. Get current bid/ask
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(currentAsk <= 0 || currentBid <= 0) return;
   
   // 3. Detect changes and record pressure
   bool askChanged = (currentAsk != lastAsk);
   bool bidChanged = (currentBid != lastBid);
   int pressure = 0;
   if(askChanged && !bidChanged) pressure = 1;        // ask changed alone → buying pressure
   else if(!askChanged && bidChanged) pressure = -1;  // bid changed alone → selling pressure
   else if(askChanged && bidChanged) pressure = 0;    // both changed → ambiguous, ignore
   
   if(pressure != 0) {
      MqlTick tick;
      SymbolInfoTick(_Symbol, tick);  // get precise time in ms
      TickRecord rec;
      rec.time_ms = tick.time_msc;
      rec.pressure = pressure;
      ArrayResize(buffer, ArraySize(buffer)+1);
      buffer[ArraySize(buffer)-1] = rec;
      totalPressure += pressure;
      
      // Remove old records outside window
      datetime cutoff = tick.time_msc - WindowMs;
      int removeCount = 0;
      for(int j = 0; j < ArraySize(buffer); j++) {
         if(buffer[j].time_ms < cutoff) {
            totalPressure -= buffer[j].pressure;
            removeCount++;
         } else break;
      }
      if(removeCount > 0) {
         int newSize = ArraySize(buffer) - removeCount;
         for(int j = 0; j < newSize; j++)
            buffer[j] = buffer[j+removeCount];
         ArrayResize(buffer, newSize);
      }
   }
   
   // Update last prices
   lastAsk = currentAsk;
   lastBid = currentBid;
   
   // 4. Debug every 3 seconds
   if(TimeCurrent() - lastDebug >= 3) {
      lastDebug = TimeCurrent();
      Print("========================================");
      Print("📊 Net Pressure (", WindowMs, "ms): ", totalPressure);
      Print("   Threshold: ±", MinNetPressure, " | Positions: ", PositionsTotal());
      Print("   Buffer size: ", ArraySize(buffer));
      Print("   Ask: ", currentAsk, " Bid: ", currentBid);
      Print("========================================");
   }
   
   // 5. Trade signals
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   if(totalPressure >= MinNetPressure) {
      if(trade.Buy(lot, _Symbol, currentAsk, 0, 0, "Pressure Buy"))
         Print("🔥 [BUY] Pressure = ", totalPressure);
      else
         Print("❌ [BUY FAIL] Error: ", GetLastError());
   }
   else if(totalPressure <= -MinNetPressure) {
      if(trade.Sell(lot, _Symbol, currentBid, 0, 0, "Pressure Sell"))
         Print("🔥 [SELL] Pressure = ", totalPressure);
      else
         Print("❌ [SELL FAIL] Error: ", GetLastError());
   }
}
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
