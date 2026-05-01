# VALETAX TICK-BASED HFT BOT - REDESIGNED FROM WORKING VERSION
ARG CACHE_BUST=14

FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV RAILWAY_RUN_UID=0

# ============================================
# 1. Install Wine and Dependencies
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc \
    novnc websockify wget curl procps cabextract \
    unzip dos2unix xdotool \
    libxt6 libxrender1 libxext6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python Dependencies
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5 Installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. Create TICK-BASED EA (REDESIGNED - NO BARS)
# ============================================
RUN cat > /root/VALETAX_TICK_BOT.mq5 << 'EOF'
//+------------------------------------------------------------------+
//| VALETAX AGGRESSIVE SCALPER v3.0                                 |
//+------------------------------------------------------------------+
#property strict

input double LotSize = 0.02;
input double OFI_Threshold = 1.05;
input int LookbackTicks = 12;
input int TakeProfit_Price = 80;
input int StopLoss_Price = 120;
input int MaxSpread_Price = 500;
input int MaxPositions = 10;
input int MagicNumber = 999001;

// Tick buffer
struct TickRecord {
   double price;
   int direction;
   long volume;
};

TickRecord buffer[];
int tickCount = 0;
double lastPrice = 0;

//---------------------------------------------
int OnInit(){
   ArrayResize(buffer, LookbackTicks);
   Print("AGGRESSIVE MODE ENABLED");
   return(INIT_SUCCEEDED);
}

//---------------------------------------------
void OnTick(){
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   int dir = 0;
   if(lastPrice > 0){
      if(tick.last > lastPrice) dir = 1;
      else if(tick.last < lastPrice) dir = -1;
   }
   lastPrice = tick.last;

   int idx = tickCount % LookbackTicks;
   buffer[idx].price = tick.last;
   buffer[idx].direction = dir;
   buffer[idx].volume = tick.volume;
   tickCount++;

   if(tickCount < LookbackTicks) return;

   int buy=0,sell=0;
   long buyVol=0,sellVol=0;

   for(int i=0;i<LookbackTicks;i++){
      if(buffer[i].direction>0){ buy++; buyVol+=buffer[i].volume; }
      else if(buffer[i].direction<0){ sell++; sellVol+=buffer[i].volume; }
   }

   double ratio = (sellVol>0)?(double)buyVol/sellVol:2.0;

   if(SymbolInfoInteger(_Symbol,SYMBOL_SPREAD)>MaxSpread_Price) return;
   if(PositionsTotal()>=MaxPositions) return;

   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double point=SymbolInfoDouble(_Symbol,SYMBOL_POINT);
   int digits=(int)SymbolInfoInteger(_Symbol,SYMBOL_DIGITS);

   // BUY
   if(ratio >= OFI_Threshold){
      MqlTradeRequest r={};
      MqlTradeResult res={};

      r.action=TRADE_ACTION_DEAL;
      r.symbol=_Symbol;
      r.volume=LotSize;
      r.type=ORDER_TYPE_BUY;
      r.price=NormalizeDouble(ask,digits);
      r.sl=NormalizeDouble(ask-StopLoss_Price*point,digits);
      r.tp=NormalizeDouble(ask+TakeProfit_Price*point,digits);
      r.magic=MagicNumber;
      r.type_filling=ORDER_FILLING_IOC;

      if(!OrderSend(r,res))
         Print("BUY FAIL:",res.retcode);
      else
         Print("BUY OK");
   }

   // SELL
   if(ratio <= (1.0/OFI_Threshold)){
      MqlTradeRequest r={};
      MqlTradeResult res={};

      r.action=TRADE_ACTION_DEAL;
      r.symbol=_Symbol;
      r.volume=LotSize;
      r.type=ORDER_TYPE_SELL;
      r.price=NormalizeDouble(bid,digits);
      r.sl=NormalizeDouble(bid+StopLoss_Price*point,digits);
      r.tp=NormalizeDouble(bid-TakeProfit_Price*point,digits);
      r.magic=MagicNumber;
      r.type_filling=ORDER_FILLING_IOC;

      if(!OrderSend(r,res))
         Print("SELL FAIL:",res.retcode);
      else
         Print("SELL OK");
   }
}
EOF

# ============================================
# 5. Entrypoint Script (FIXED FOR TICK BOT)
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "VALETAX TICK-BASED HFT BOT v2.0"
echo "=========================================="

# Cleanup
rm -rf /tmp/.X*

# Start Xvfb
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &
sleep 3

# Start fluxbox
fluxbox -display :1 &
sleep 2

# Start x11vnc with stability fixes
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 -noxdamage -noxfixes -bg &
sleep 2

# Start websockify
websockify --web=/usr/share/novnc 0.0.0.0:8080 localhost:5900 &

# Initialize Wine
export WINEDEBUG=-all
export DISPLAY=:1
wineboot --init
sleep 5

# Install MT5 if not present
MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 120
fi

# Start MT5 and wait
echo "Starting MT5..."
wine "$MT5_EXE" &
echo "Waiting for MT5 to fully initialize (60 seconds)..."
sleep 60

# Find REAL terminal directory (exclude Community)
TERMINAL_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal -mindepth 1 -maxdepth 1 -type d ! -name "Community" 2>/dev/null | head -n 1)

if [ -z "$TERMINAL_DIR" ]; then
    echo "ERROR: Terminal directory not found!"
    exit 1
fi

DATA_DIR="$TERMINAL_DIR/MQL5"
echo "Using Terminal Dir: $TERMINAL_DIR"

# Create directories
mkdir -p "$DATA_DIR/Experts"
mkdir -p "$DATA_DIR/Logs"

# Install EA
cp /root/VALETAX_TICK_BOT.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5"

# Compile EA
EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
echo "Compiling Tick-based EA..."
wine "$EDITOR_EXE" /portable /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5" /log:"C:\\compile.log"
sleep 10

if [ -f "$DATA_DIR/Experts/VALETAX_TICK_BOT.ex5" ]; then
    echo "✅ EA compiled SUCCESSFULLY!"
else
    echo "❌ EA NOT FOUND after compile!"
    cat "$WINEPREFIX/drive_c/compile.log" 2>/dev/null || echo "No log"
fi

# Force Navigator refresh
sleep 2
xdotool search --name "MetaTrader" key Ctrl+n 2>/dev/null || true

# Start mt5linux bridge
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "=========================================="
echo "TICK-BASED BOT READY!"
echo "=========================================="
echo "📊 FEATURES:"
echo "  - Pure tick-based (NO candle bars)"
echo "  - Tick direction tracking"
echo "  - Volume-weighted OFI"
echo "  - 30-tick lookback window"
echo "=========================================="
echo "STEPS:"
echo "1. Open noVNC in browser"
echo "2. Login to Valetutax"
echo "3. Open Navigator (Ctrl+N)"
echo "4. Refresh Expert Advisors"
echo "5. Drag VALETAX_TICK_BOT to chart"
echo "6. Enable Auto-Trading"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
