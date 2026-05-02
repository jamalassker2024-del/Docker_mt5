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
//|                                            OrderFlowImbalance.mq5 |
//|                                      Fast in, fast out on profit |
//+------------------------------------------------------------------+
#property copyright "Omni-Apex"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS --------------------------------------------------------+
input double   RiskPercent       = 2.0;       // % of equity per trade
input int      ImbalanceWindowMs = 3000;      // Time window for net delta (milliseconds)
input int      MinNetDelta       = 1;         // Minimum net delta to trigger trade (>=1)
input int      MaxOpenPositions  = 10;        // Max concurrent trades
input int      MagicNumber       = 999111;    // EA identifier
input bool     UseTickVolume     = true;      // Weight delta by tick volume? (true=volume, false=counts)

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
struct TickRecord {
   datetime time_ms;
   int      delta;        // +1 for buy, -1 for sell, or weighted by volume
};
TickRecord tickBuffer[];   // dynamic array to store recent ticks
int totalDelta = 0;
datetime lastDebugTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   ArrayResize(tickBuffer, 0);
   Print("==============================================");
   Print("🟢 Order Flow Imbalance EA started");
   Print("   Window: ", ImbalanceWindowMs, " ms");
   Print("   MinNetDelta: ", MinNetDelta);
   Print("   RiskPercent: ", RiskPercent, "%");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick() {
   // --- 1. CLOSE ANY POSITION WITH POSITIVE PROFIT (FAST OUT) ---
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0.0) {
            if(trade.PositionClose(ticket))
               Print("✅ [CLOSE] Ticket ", ticket, " closed with profit: ", profit);
            else
               Print("❌ [CLOSE] Failed, error: ", GetLastError());
         }
      }
   }

   // --- 2. POSITION LIMIT ---
   if(PositionsTotal() >= MaxOpenPositions) return;

   // --- 3. GET CURRENT TICK AND DETECT AGGRESSOR ---
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   // Determine if this tick is an aggressive buy or sell
   int delta = 0;
   bool isNewTrade = false;
   if((tick.flags & TICK_FLAG_BUY) == TICK_FLAG_BUY) {
      delta = UseTickVolume ? (int)MathMax(1, tick.volume) : 1;
      isNewTrade = true;
   }
   else if((tick.flags & TICK_FLAG_SELL) == TICK_FLAG_SELL) {
      delta = UseTickVolume ? -(int)MathMax(1, tick.volume) : -1;
      isNewTrade = true;
   }

   // If it's a new trade tick, add to buffer and update total delta
   if(isNewTrade) {
      TickRecord newTick;
      newTick.time_ms = tick.time_msc;   // millisecond precision
      newTick.delta   = delta;
      ArrayResize(tickBuffer, ArraySize(tickBuffer)+1);
      tickBuffer[ArraySize(tickBuffer)-1] = newTick;
      totalDelta += delta;

      // Remove ticks older than ImbalanceWindowMs
      datetime cutoff = tick.time_msc - ImbalanceWindowMs;
      int removeCount = 0;
      for(int j = 0; j < ArraySize(tickBuffer); j++) {
         if(tickBuffer[j].time_ms < cutoff) {
            totalDelta -= tickBuffer[j].delta;
            removeCount++;
         } else break;
      }
      if(removeCount > 0) {
         int newSize = ArraySize(tickBuffer) - removeCount;
         for(int j = 0; j < newSize; j++)
            tickBuffer[j] = tickBuffer[j+removeCount];
         ArrayResize(tickBuffer, newSize);
      }
   }

   // --- 4. DEBUG OUTPUT (every 2 seconds) ---
   if(TimeCurrent() - lastDebugTime >= 2) {
      lastDebugTime = TimeCurrent();
      Print("========================================");
      Print("📊 Net Delta (", ImbalanceWindowMs, "ms): ", totalDelta);
      Print("   Min threshold: ", MinNetDelta);
      Print("   Active positions: ", PositionsTotal());
      Print("   Tick buffer size: ", ArraySize(tickBuffer));
      Print("========================================");
   }

   // --- 5. OPEN TRADE BASED ON IMBALANCE ---
   if(totalDelta >= MinNetDelta) {
      // Strong buying pressure → BUY
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
      lot = MathMax(0.01, lot);
      if(trade.Buy(lot, _Symbol, ask, 0, 0, "Imbalance Buy")) {
         Print("🔥 [BUY OPEN] NetDelta=", totalDelta, " Lot=", lot, " @ ", ask);
      } else {
         Print("❌ [BUY FAIL] Error: ", GetLastError());
      }
   }
   else if(totalDelta <= -MinNetDelta) {
      // Strong selling pressure → SELL
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
      lot = MathMax(0.01, lot);
      if(trade.Sell(lot, _Symbol, bid, 0, 0, "Imbalance Sell")) {
         Print("🔥 [SELL OPEN] NetDelta=", totalDelta, " Lot=", lot, " @ ", bid);
      } else {
         Print("❌ [SELL FAIL] Error: ", GetLastError());
      }
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
