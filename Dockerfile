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
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex V16.3 Profit-Max"
#property version   "16.30"
#property strict

// --- ENHANCED INPUTS FOR PROFITABILITY
input double LotSize          = 1.0;
input double OFI_Threshold    = 1.25;     // Higher threshold for higher quality signals
input int    LookbackTicks    = 15;       // Slightly longer to filter noise
input int    MinStopBuffer    = 50;       // Tighter SL for better RR
input double RewardRatio      = 1.5;      // Target 1.5x the spread for profitability
input int    MaxSpread_Pips   = 400;      // Tightened to avoid high-cost trades
input int    MagicNumber      = 999016;

struct TickRecord {
   int    direction; 
   long   volume;
   long   time_msc;
};

TickRecord tickBuffer[];
int        tickIdx = 0;
CTrade     trade;
double     lastPrice = 0;

int OnInit() {
   ArrayResize(tickBuffer, LookbackTicks);
   trade.SetExpertMagicNumber(MagicNumber);
   
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);

   Print("V16.3 Profit-Max Booted. RR: ", RewardRatio);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   MqlTick curr;
   if(!SymbolInfoTick(_Symbol, curr)) return;

   double bid = curr.bid;
   double ask = curr.ask;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spread_points = (ask - bid) / point;
   
   // --- VELOCITY & MOMENTUM ---
   int direction = (lastPrice > 0) ? (bid > lastPrice ? 1 : (bid < lastPrice ? -1 : 0)) : 0;
   lastPrice = bid;

   tickBuffer[tickIdx % LookbackTicks].direction = direction;
   tickBuffer[tickIdx % LookbackTicks].volume = (curr.volume_real > 0) ? (long)curr.volume_real : 1;
   tickBuffer[tickIdx % LookbackTicks].time_msc = curr.time_msc;
   tickIdx++;

   if(tickIdx < LookbackTicks) return;

   // Calculate OFI and Velocity (ms per tick)
   long buyVol = 0, sellVol = 0;
   int momentum = 0;
   for(int i=0; i<LookbackTicks; i++) {
      if(tickBuffer[i].direction > 0) { buyVol += tickBuffer[i].volume; momentum++; }
      if(tickBuffer[i].direction < 0) { sellVol += tickBuffer[i].volume; momentum--; }
   }
   
   long timeSpan = tickBuffer[(tickIdx-1)%LookbackTicks].time_msc - tickBuffer[tickIdx%LookbackTicks].time_msc;
   double velocity = (timeSpan > 0) ? (double)LookbackTicks / (double)timeSpan : 0;

   double ratio = (sellVol > 0) ? (double)buyVol / (double)sellVol : (double)buyVol;

   // --- PROFITABILITY FILTERS ---
   if(PositionsTotal() >= 1) return;
   if((spread_points / 10.0) > MaxSpread_Pips) return;
   if(timeSpan > 1000) return; // Only trade if LookbackTicks happened in < 1 second (High Velocity)

   // Dynamic Asymmetric Targets
   double sl_dist = (spread_points + MinStopBuffer) * point;
   double tp_dist = sl_dist * RewardRatio; 

   // --- BUY EXECUTION ---
   if(ratio >= OFI_Threshold && momentum > (LookbackTicks/2)) {
      double sl = ask - sl_dist; 
      double tp = ask + tp_dist;
      if(trade.Buy(LotSize, _Symbol, ask, sl, tp, "ProfitMax Buy"))
         PrintFormat("Profit Trade: Ratio %.2f | Velocity %.2f", ratio, velocity);
   }
   // --- SELL EXECUTION ---
   else if(ratio <= (1.0 / OFI_Threshold) && momentum < -(LookbackTicks/2)) {
      double sl = bid + sl_dist;
      double tp = bid - tp_dist;
      if(trade.Sell(LotSize, _Symbol, bid, sl, tp, "ProfitMax Sell"))
         PrintFormat("Profit Trade: Ratio %.2f | Velocity %.2f", ratio, velocity);
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
