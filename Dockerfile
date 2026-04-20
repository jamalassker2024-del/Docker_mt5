FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. Install Wine, Dependencies & Clipboard Tools
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox autocutsel \
    novnc websockify wget curl procps cabextract \
    unzip dos2unix \
    libxt6 libxrender1 libxext6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Install Python deps
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5 Installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. Create MQL5 Bot Code (SUPER HFT AGGRESSOR)
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

struct TickData {
   double   price;
   bool     isBuy;
   long     volume;
};

TickData tickBuffer[];
int      tickCount = 0;
int      dailyTrades = 0;
int      lastTradeDay = 0;

int GetCurrentDay() {
   MqlDateTime tm;
   TimeToStruct(TimeTradeServer(), tm);
   return tm.day;
}

double GetPipValue() {
   return (_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point;
}

int OnInit() {
   ArrayResize(tickBuffer, LookbackTicks);
   lastTradeDay = GetCurrentDay();
   Print("🚀 SUPER HFT AGGRESSOR STARTING");
   return(INIT_SUCCEEDED);
}

void OnTick() {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   if(GetCurrentDay() != lastTradeDay) { dailyTrades = 0; lastTradeDay = GetCurrentDay(); }
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
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
   double spread = (currentTick.ask - currentTick.bid) / GetPipValue();
   
   if(spread > MaxSpreadPips) return;

   if(PositionsTotal() < MaxConcurrentTrades && dailyTrades < MaxDailyTrades) {
      if(ofiRatio >= OFIThreshold) ExecuteTrade(ORDER_TYPE_BUY, currentTick.ask);
      else if(ofiRatio <= 1.0 / OFIThreshold) ExecuteTrade(ORDER_TYPE_SELL, currentTick.bid);
   }
}

void ExecuteTrade(ENUM_ORDER_TYPE type, double price) {
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   double pip = GetPipValue();
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type   = type;
   request.price  = NormalizeDouble(price, digits);
   request.magic  = 2026;
   request.deviation = 30; 
   request.type_filling = ORDER_FILLING_IOC; 

   if(type == ORDER_TYPE_BUY) {
      request.sl = NormalizeDouble(price - (StopLossPips * pip), digits);
      request.tp = NormalizeDouble(price + (TakeProfitPips * pip), digits);
   } else {
      request.sl = NormalizeDouble(price + (StopLossPips * pip), digits);
      request.tp = NormalizeDouble(price - (TakeProfitPips * pip), digits);
   }

   OrderSend(request, result);
}
EOF

# ============================================
# 5. Create Entrypoint Script (UPGRADED CLIPBOARD)
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
rm -f /tmp/.X1-lock
Xvfb :1 -screen 0 1280x800x16 &
sleep 2

# Start clipboard sync
autocutsel -fork
autocutsel -selection PRIMARY -fork

fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

wineboot --init
sleep 5

MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"

if [ ! -f "$MT5_EXE" ]; then
    wine /root/mt5setup.exe /auto /silent &
    sleep 90
fi

export DISPLAY=:1
wine "$MT5_EXE" &
sleep 45
wineserver -k
sleep 5

DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"; fi

mkdir -p "$DATA_DIR/Experts"
cp /root/OFI_Tick_Bot.mq5 "$DATA_DIR/Experts/HFT_OFI_Bot.mq5"

# Compile
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/HFT_OFI_Bot.mq5" /log:"/root/compile.log"

wine "$MT5_EXE" &
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
