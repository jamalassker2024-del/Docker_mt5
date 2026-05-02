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
//|                                        OrderFlowImbalance_V2.mq5 |
//|                              Fast in/out, any profit close       |
//+------------------------------------------------------------------+
#property copyright "Omni-Apex"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

// --- INPUTS --------------------------------------------------------+
input double   RiskPercent       = 2.0;       // % of equity per trade
input int      ImbalanceWindowMs = 3000;      // Time window for net delta (ms)
input int      MinNetDelta       = 1;         // Min net delta to trigger trade
input int      MaxOpenPositions  = 10;
input int      MagicNumber       = 999111;
input bool     UseTickVolume     = true;      // Weight delta by volume? (volume or 1)

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
struct TickRecord {
   datetime time_ms;
   int      delta;        // positive = buy, negative = sell (weighted by volume if enabled)
};
TickRecord tickBuffer[];
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
   Print("🟢 Order Flow Imbalance EA V2 (Price-based)");
   Print("   Window: ", ImbalanceWindowMs, " ms | MinDelta: ", MinNetDelta);
   Print("   Risk: ", RiskPercent, "% | Volume weighting: ", UseTickVolume);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Determine aggression from tick price relative to bid/ask        |
//+------------------------------------------------------------------+
int GetDeltaFromTick(MqlTick &tick) {
   // If no volume or invalid price, return 0 (ignore)
   if(tick.volume == 0 || tick.last <= 0) return 0;
   
   // Aggressive buy: last price is at or above ask
   if(tick.last >= tick.ask - (tick.ask - tick.bid) * 0.1) {  // allow tiny slippage
      return UseTickVolume ? (int)MathMax(1, tick.volume) : 1;
   }
   // Aggressive sell: last price is at or below bid
   else if(tick.last <= tick.bid + (tick.ask - tick.bid) * 0.1) {
      return UseTickVolume ? -(int)MathMax(1, tick.volume) : -1;
   }
   // Tick inside spread – could be a quote update or ambiguous trade
   return 0;
}

//+------------------------------------------------------------------+
//| Expert tick function                                            |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Close profitable positions
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
   
   // 2. Get current tick
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   
   // 3. Detect aggressor using price
   int delta = GetDeltaFromTick(tick);
   if(delta != 0) {
      // Add to buffer
      TickRecord newTick;
      newTick.time_ms = tick.time_msc;
      newTick.delta = delta;
      ArrayResize(tickBuffer, ArraySize(tickBuffer)+1);
      tickBuffer[ArraySize(tickBuffer)-1] = newTick;
      totalDelta += delta;
      
      // Remove old ticks
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
   
   // 4. Debug every 2 seconds
   if(TimeCurrent() - lastDebugTime >= 2) {
      lastDebugTime = TimeCurrent();
      Print("========================================");
      Print("📊 Net Delta (", ImbalanceWindowMs, "ms): ", totalDelta);
      Print("   Threshold: ±", MinNetDelta, " | Positions: ", PositionsTotal());
      Print("   Buffer size: ", ArraySize(tickBuffer), " | Last Price: ", tick.last);
      Print("   Bid: ", tick.bid, " Ask: ", tick.ask);
      Print("========================================");
   }
   
   // 5. Trade signal
   double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   
   if(totalDelta >= MinNetDelta) {
      if(trade.Buy(lot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_ASK), 0, 0, "Imbalance Buy"))
         Print("🔥 [BUY OPEN] NetDelta=", totalDelta);
      else
         Print("❌ [BUY FAIL] Error: ", GetLastError());
   }
   else if(totalDelta <= -MinNetDelta) {
      if(trade.Sell(lot, _Symbol, SymbolInfoDouble(_Symbol, SYMBOL_BID), 0, 0, "Imbalance Sell"))
         Print("🔥 [SELL OPEN] NetDelta=", totalDelta);
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
