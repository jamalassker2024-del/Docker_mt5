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
//|                                        MomentumTickFast.mq5     |
//|                     Mid-price momentum using every bid/ask tick |
//+------------------------------------------------------------------+
#property copyright "Omni-Apex"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS --------------------------------------------------------+
input double   RiskPercent       = 5.0;          // % of equity per trade
input int      WindowMs          = 2000;         // Rolling window (milliseconds)
input int      MinNetMomentum    = 1;            // Minimum net momentum to trigger trade
input int      MaxOpenPositions  = 20;
input int      MagicNumber       = 999555;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
struct TickRecord {
   datetime time_ms;
   int      momentum;     // +1 for mid increase, -1 for mid decrease
};
TickRecord buffer[];
int totalMomentum = 0;
datetime lastDebug = 0;
double lastMid = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   ArrayResize(buffer, 0);
   // Initialize with current mid
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   lastMid = (ask + bid) / 2.0;
   Print("==============================================");
   Print("🟢 MID-PRICE MOMENTUM EA (Every tick gives signal)");
   Print("   Window: ", WindowMs, " ms | MinMomentum: ", MinNetMomentum);
   Print("   Risk: ", RiskPercent, "% | Fast close on profit");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Close any profitable position immediately
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
   
   // 2. Get current prices and compute mid
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;
   double currentMid = (ask + bid) / 2.0;
   
   // 3. Determine momentum direction
   int momentum = 0;
   if(currentMid > lastMid) momentum = 1;
   else if(currentMid < lastMid) momentum = -1;
   else momentum = 0;   // no change, ignore
   
   if(momentum != 0) {
      MqlTick tick;
      SymbolInfoTick(_Symbol, tick);
      TickRecord rec;
      rec.time_ms = tick.time_msc;
      rec.momentum = momentum;
      ArrayResize(buffer, ArraySize(buffer)+1);
      buffer[ArraySize(buffer)-1] = rec;
      totalMomentum += momentum;
      
      // Remove old records
      datetime cutoff = tick.time_msc - WindowMs;
      int removeCount = 0;
      for(int j = 0; j < ArraySize(buffer); j++) {
         if(buffer[j].time_ms < cutoff) {
            totalMomentum -= buffer[j].momentum;
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
   lastMid = currentMid;
   
   // 4. Debug every 3 seconds
   if(TimeCurrent() - lastDebug >= 3) {
      lastDebug = TimeCurrent();
      Print("========================================");
      Print("📊 Net Momentum (", WindowMs, "ms): ", totalMomentum);
      Print("   Threshold: ±", MinNetMomentum, " | Positions: ", PositionsTotal());
      Print("   Buffer size: ", ArraySize(buffer));
      Print("   Mid: ", DoubleToString(currentMid, _Digits));
      Print("========================================");
   }
   
   // 5. Trade signals
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   if(totalMomentum >= MinNetMomentum) {
      if(trade.Buy(lot, _Symbol, ask, 0, 0, "Momentum Buy"))
         Print("🔥 [BUY] NetMomentum = ", totalMomentum);
      else
         Print("❌ [BUY FAIL] Error: ", GetLastError());
   }
   else if(totalMomentum <= -MinNetMomentum) {
      if(trade.Sell(lot, _Symbol, bid, 0, 0, "Momentum Sell"))
         Print("🔥 [SELL] NetMomentum = ", totalMomentum);
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
