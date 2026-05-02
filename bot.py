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

# ============================================
# V16 - ULTRA-AGGRESSIVE MOMENTUM TICK BOT
# ============================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex V16"
#property version   "16.00"
#property strict

// --- INPUTS
input double LotSize          = 1.0;
input double OFI_Threshold    = 1.05;     // Lower = more aggressive
input int    LookbackTicks    = 10;       // Fast reaction
input int    TakeProfit_Pips  = 3;        // 3 Pips (Aggressive Scalp)
input int    StopLoss_Pips    = 2;        // 2 Pips (Tight SL)
input int    MaxSpread_Pips   = 500;      // High to allow BTCUSD.vx
input int    MagicNumber      = 999016;

// --- GLOBALS
struct TickRecord {
   int direction; 
   long volume;
};

TickRecord tickBuffer[];
int        tickIdx = 0;
CTrade     trade;
double     lastPrice = 0;
double     initialBalance = 0;

int OnInit() {
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   ArrayResize(tickBuffer, LookbackTicks);
   trade.SetExpertMagicNumber(MagicNumber);
   
   // Auto-Detect Filling
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);

   Print("V16 START: Aggressive Scalper Ready on ", _Symbol);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   MqlTick curr;
   if(!SymbolInfoTick(_Symbol, curr)) return;

   double bid = curr.bid;
   double ask = curr.ask;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spread_pips = (ask - bid) / (point * 10);

   // Determine Tick Direction
   int direction = 0;
   if(lastPrice > 0) {
      if(bid > lastPrice) direction = 1;
      else if(bid < lastPrice) direction = -1;
   }
   lastPrice = bid;

   // Store in Buffer
   tickBuffer[tickIdx % LookbackTicks].direction = direction;
   tickBuffer[tickIdx % LookbackTicks].volume = (curr.volume_real > 0) ? (long)curr.volume_real : 1;
   tickIdx++;

   if(tickIdx < LookbackTicks) return;

   // --- OFI & MOMENTUM CALC ---
   long buyVol = 0, sellVol = 0;
   int  momentum = 0;

   for(int i=0; i<LookbackTicks; i++) {
      if(tickBuffer[i].direction > 0) { buyVol += tickBuffer[i].volume; momentum++; }
      if(tickBuffer[i].direction < 0) { sellVol += tickBuffer[i].volume; momentum--; }
   }

   double ratio = (sellVol > 0) ? (double)buyVol / (double)sellVol : (double)buyVol;

   // --- DEBUG LOGGING ---
   if(tickIdx % 10 == 0) {
      PrintFormat("[%s] Spread: %.1f | Ratio: %.2f | Momentum: %d", _Symbol, spread_pips, ratio, momentum);
   }

   // --- EXECUTION LOGIC ---
   if(PositionsTotal() >= 1) return; // One at a time for tight SL
   if(spread_pips > MaxSpread_Pips) return;

   // BUY: High Ratio + Positive Momentum
   if(ratio >= OFI_Threshold && momentum > 0) {
      double sl = ask - (StopLoss_Pips * 10 * point);
      double tp = ask + (TakeProfit_Pips * 10 * point);
      trade.Buy(LotSize, _Symbol, ask, sl, tp, "V16 Momentum Buy");
   }
   // SELL: Low Ratio + Negative Momentum
   else if(ratio <= (1.0 / OFI_Threshold) && momentum < 0) {
      double sl = bid + (StopLoss_Pips * 10 * point);
      double tp = bid - (TakeProfit_Pips * 10 * point);
      trade.Sell(LotSize, _Symbol, bid, sl, tp, "V16 Momentum Sell");
   }
}

void OnDeinit(const int reason) {
   Print("Bot shutdown. Final Balance: ", AccountInfoDouble(ACCOUNT_BALANCE));
}
EOF

# ============================================
# 5. ENTRYPOINT WITH AUTO-ATTACH & COMPILE
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

# Compile EA
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
