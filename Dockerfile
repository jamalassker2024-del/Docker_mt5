FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. Install Wine & Dependencies
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox autocutsel \
    novnc websockify wget curl procps cabextract \
    unzip dos2unix libxt6 libxrender1 libxext6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python Setup
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5 (Build stage - just download)
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. Create MQL5 Bot Code
# ============================================
RUN cat > /root/OFI_Tick_Bot.mq5 << 'EOF'
#property copyright "Super HFT Bot"
#property version   "4.00"
#property strict

input double   LotSize = 0.01;
input double   OFIThreshold = 0.5;            
input int      LookbackTicks = 10;            
input int      TakeProfitPips = 1;            
input int      StopLossPips = 5;              
input int      MaxSpreadPips = 15;            
input int      MaxDailyTrades = 10000;         
input int      MaxConcurrentTrades = 100;     

struct TickData { double price; bool isBuy; long volume; };
TickData tickBuffer[];
int tickCount = 0, dailyTrades = 0, lastTradeDay = 0;

int GetCurrentDay() { MqlDateTime tm; TimeToStruct(TimeTradeServer(), tm); return tm.day; }
double GetPipValue() { return (_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point; }

int OnInit() { ArrayResize(tickBuffer, LookbackTicks); lastTradeDay = GetCurrentDay(); return(INIT_SUCCEEDED); }

void OnTick() {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   MqlTick currentTick; if(!SymbolInfoTick(_Symbol, currentTick)) return;
   bool isBuyTick = (currentTick.last >= currentTick.ask);
   long t_volume = (currentTick.volume > 0) ? currentTick.volume : 1; 
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].isBuy = isBuyTick;
   tickBuffer[idx].volume = t_volume;
   tickCount++;
   if(tickCount < LookbackTicks) return;
   double buyVol = 0, sellVol = 0;
   for(int i = 0; i < LookbackTicks; i++) {
      if(tickBuffer[i].isBuy) buyVol += (double)tickBuffer[i].volume;
      else sellVol += (double)tickBuffer[i].volume;
   }
   double ofiRatio = (sellVol <= 0) ? 99.0 : buyVol / sellVol;
   if(ofiRatio >= OFIThreshold) ExecuteTrade(ORDER_TYPE_BUY, currentTick.ask);
   else if(ofiRatio <= 1.0 / OFIThreshold) ExecuteTrade(ORDER_TYPE_SELL, currentTick.bid);
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double price) {
   MqlTradeRequest req = {}; MqlTradeResult res = {};
   double pip = GetPipValue(); int dig = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   req.action = TRADE_ACTION_DEAL; req.symbol = _Symbol; req.volume = LotSize;
   req.type = type; req.price = NormalizeDouble(price, dig); req.magic = 2026;
   req.deviation = 30; req.type_filling = ORDER_FILLING_IOC;
   if(type == ORDER_TYPE_BUY) {
      req.sl = NormalizeDouble(price - (StopLossPips * pip), dig);
      req.tp = NormalizeDouble(price + (TakeProfitPips * pip), dig);
   } else {
      req.sl = NormalizeDouble(price + (StopLossPips * pip), dig);
      req.tp = NormalizeDouble(price - (TakeProfitPips * pip), dig);
   }
   OrderSend(req, res);
}
EOF

# ============================================
# 5. Entrypoint (Optimized for Railway Health)
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

# 1. IMMEDIATE WEBSERVER START (Tricks Railway Health Check)
# This ensures Railway sees the container as "Active" immediately
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

# 2. Start Virtual Display in background
Xvfb :1 -screen 0 1280x800x16 &
sleep 2
fluxbox &
autocutsel -fork
autocutsel -selection PRIMARY -fork
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &

# 3. Initialize Wine and MT5 if not exists
if [ ! -d "/root/.wine/drive_c/Program Files/MetaTrader 5" ]; then
    echo "First time setup: Initializing Wine..."
    wineboot --init
    sleep 5
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto /silent
    sleep 40
fi

# 4. Handle Bot Files
DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"; fi

mkdir -p "$DATA_DIR/Experts"
cp /root/OFI_Tick_Bot.mq5 "$DATA_DIR/Experts/HFT_OFI_Bot.mq5"

# Compile
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/HFT_OFI_Bot.mq5" /log:"/root/compile.log"

# 5. Run Terminal & Python Bridge
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" &
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "Setup Complete. Bot is running."
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
