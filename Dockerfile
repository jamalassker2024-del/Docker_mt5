# Increment to bust cache
ARG CACHE_BUST=12

FROM python:3.11-slim-bookworm

USER root

# Setup Environment
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV RAILWAY_RUN_UID=0

# ============================================
# 1. Install Wine, X11, and Dependencies
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox \
    novnc websockify wget curl procps cabextract \
    unzip dos2unix \
    libxt6 libxrender1 libxext6 \
    gettext-base \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python Dependencies
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. All-in-One Entrypoint (Bot + Setup + Auto-Run)
# ============================================
RUN printf '%s\n' \
'#!/bin/bash' \
'echo "=========================================="' \
'echo "HFT OFI BOT - ULTIMATE AUTO-RECOVERY"' \
'echo "=========================================="' \
'' \
'# Setup X11 Display' \
'rm -f /tmp/.X1-lock' \
'Xvfb :1 -screen 0 1280x800x16 &' \
'sleep 2' \
'fluxbox &' \
'x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &' \
'websockify --web=/usr/share/novnc/ 8080 localhost:5900 &' \
'' \
'# Init Wine' \
'wineboot --init' \
'sleep 10' \
'' \
'MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"' \
'EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"' \
'' \
'if [ ! -f "$MT5_EXE" ]; then' \
'    echo "Installing MT5..."' \
'    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /tmp/mt5setup.exe' \
'    wine /tmp/mt5setup.exe /auto /silent' \
'    sleep 120' \
'    rm /tmp/mt5setup.exe' \
'fi' \
'' \
'# Locate Data Directory dynamically' \
'DATA_DIR=$(find "$WINEPREFIX" -name "Experts" -type d | grep "AppData" | head -n 1)' \
'if [ -z "$DATA_DIR" ]; then' \
'    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"' \
'    mkdir -p "$DATA_DIR"' \
'fi' \
'' \
'# 4. WRITE THE BOT CODE' \
'cat > "$DATA_DIR/HFT_OFI_Bot.mq5" << '"'"'EOF'"'"'' \
'#property copyright "HFT Bot"' \
'#property version   "2.10"' \
'#property strict' \
'' \
'input double LotSize = 0.01;' \
'input int OFIThreshold = 2;' \
'input int LookbackTicks = 20;' \
'input int TP_Pips = 3;' \
'input int SL_Pips = 2;' \
'' \
'double lastPrice = 0;' \
'int tickCount = 0;' \
'int buyTicks = 0, sellTicks = 0;' \
'' \
'int OnInit() { Print("OFI BOT ONLINE"); return(INIT_SUCCEEDED); }' \
'' \
'void OnTick() {' \
'   MqlTick tick;' \
'   if(!SymbolInfoTick(_Symbol, tick)) return;' \
'   if(lastPrice > 0) {' \
'      if(tick.last > lastPrice) buyTicks++;' \
'      else if(tick.last < lastPrice) sellTicks++;' \
'   }' \
'   lastPrice = tick.last;' \
'   tickCount++;' \
'' \
'   if(tickCount >= LookbackTicks) {' \
'      double ofi = (sellTicks == 0) ? 10.0 : (double)buyTicks/sellTicks;' \
'      if(ofi >= OFIThreshold) SendHFTOrder(ORDER_TYPE_BUY, tick.ask, ofi);' \
'      else if(ofi <= 1.0/OFIThreshold) SendHFTOrder(ORDER_TYPE_SELL, tick.bid, ofi);' \
'      tickCount = 0; buyTicks = 0; sellTicks = 0;' \
'   }' \
'}' \
'' \
'void SendHFTOrder(ENUM_ORDER_TYPE type, double price, double ofi) {' \
'   if(PositionsTotal() >= 5) return;' \
'   MqlTradeRequest req = {}; MqlTradeResult res = {};' \
'   double p = (_Digits==3||_Digits==5) ? _Point*10 : _Point;' \
'   req.action = TRADE_ACTION_DEAL;' \
'   req.symbol = _Symbol;' \
'   req.volume = LotSize;' \
'   req.type = type;' \
'   req.price = NormalizeDouble(price, _Digits);' \
'   req.sl = (type==ORDER_TYPE_BUY) ? price-(SL_Pips*p) : price+(SL_Pips*p);' \
'   req.tp = (type==ORDER_TYPE_BUY) ? price+(TP_Pips*p) : price-(TP_Pips*p);' \
'   req.magic = 2026;' \
'   req.comment = StringFormat("OFI_%.1f", ofi);' \
'   req.type_filling = ORDER_FILLING_IOC;' \
'   OrderSend(req, res);' \
'}' \
'EOF' \
'' \
'# 5. COMPILE' \
'WIN_MQ5_PATH=$(wine winepath -w "$DATA_DIR/HFT_OFI_Bot.mq5")' \
'wine "$EDITOR_EXE" /compile:"$WIN_MQ5_PATH" /log:"/root/compile.log"' \
'' \
'# 6. CREATE AUTO-START CONFIG' \
'cat > "$WINEPREFIX/drive_c/startup.ini" << INIEOF' \
'[Common]' \
'ProxyEnable=0' \
'[Charts]' \
'Count=1' \
'Chart0.Symbol=EURUSD' \
'Chart0.Period=M1' \
'Chart0.Expert=HFT_OFI_Bot' \
'Chart0.ExpertEnabled=1' \
'INIEOF' \
'' \
'# 7. LAUNCH' \
'python3 -m mt5linux --host 0.0.0.0 --port 8001 &' \
'wine "$MT5_EXE" /config:"C:\\startup.ini" &' \
'' \
'echo "=========================================="' \
'echo "✅ BOT DEPLOYED AND AUTO-ATTACHED!"' \
'echo "=========================================="' \
'tail -f /dev/null' > /entrypoint.sh

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
