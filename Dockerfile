# Increment to bust cache
ARG CACHE_BUST=8

FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV RAILWAY_RUN_UID=0

# ============================================
# 1. Install Wine + dependencies
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
# 2. Python dependencies
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. ENTRYPOINT (FIXED: EA AUTO-ATTACH + TRADING FIX)
# ============================================
RUN printf '%s\n' \
'#!/bin/bash' \
'echo "=========================================="' \
'echo "HFT OFI BOT - FIXED EXECUTION VERSION"' \
'echo "=========================================="' \
'' \
'# X11 setup' \
'rm -f /tmp/.X1-lock' \
'Xvfb :1 -screen 0 1280x800x16 &' \
'sleep 2' \
'fluxbox &' \
'x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &' \
'websockify --web=/usr/share/novnc/ 8080 localhost:5900 &' \
'' \
'# Wine init' \
'wineboot --init' \
'sleep 15' \
'' \
'MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"' \
'EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"' \
'' \
'if [ ! -f "$MT5_EXE" ]; then' \
'    echo "Installing MT5..."' \
'    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /tmp/mt5setup.exe' \
'    wine /tmp/mt5setup.exe /auto /silent' \
'    sleep 120' \
'fi' \
'' \
'# Locate MQL5 folder' \
'DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "Experts" -type d 2>/dev/null | head -n 1 | sed "s/\/Experts//")' \
'if [ -z "$DATA_DIR" ]; then' \
'    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"' \
'fi' \
'' \
'echo "MQL5 DIR: $DATA_DIR"' \
'' \
'mkdir -p "$DATA_DIR/Experts"' \
'' \
'# Write EA unchanged (your logic preserved)' \
'cat > "$DATA_DIR/Experts/HFT_OFI_Bot.mq5" << '"'"'EOF'"'"'' \
'#property strict' \
'#property version "2.01"' \
'' \
'input double LotSize = 0.01;' \
'input int OFIThreshold = 2;' \
'input int LookbackTicks = 20;' \
'input int TakeProfitPips = 3;' \
'input int StopLossPips = 2;' \
'input int MaxSpreadPips = 3;' \
'input int MaxDailyTrades = 1000;' \
'input int MaxConcurrentTrades = 10;' \
'' \
'struct TickData { datetime time; double price; bool isBuy; long volume; };' \
'TickData tickBuffer[];' \
'int tickCount=0;' \
'datetime lastTradeTime=0;' \
'int dailyTrades=0;' \
'int lastDay=0;' \
'double initialBalance=0;' \
'bool connected=false;' \
'' \
'int OnInit(){' \
'   ArrayResize(tickBuffer, LookbackTicks);' \
'   initialBalance=AccountInfoDouble(ACCOUNT_BALANCE);' \
'   connected=true;' \
'   SymbolSelect(_Symbol,true);' \
'   Print("BOT INIT OK");' \
'   return(INIT_SUCCEEDED);' \
'}' \
'' \
'double Pip(){ return (_Digits==3||_Digits==5)?_Point*10:_Point; }' \
'' \
'double Spread(){' \
'   return (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/Pip();' \
'}' \
'' \
'void OnTick(){' \
'   MqlTick t;' \
'   if(!SymbolInfoTick(_Symbol,t)) return;' \
'' \
'   bool buy = t.last > t.bid;' \
'' \
'   int i = tickCount % LookbackTicks;' \
'   tickBuffer[i].price=t.last;' \
'   tickBuffer[i].isBuy=buy;' \
'   tickBuffer[i].volume=t.volume;' \
'   tickCount++;' \
'' \
'   if(tickCount < LookbackTicks) return;' \
'' \
'   double buyV=0,sellV=0;' \
'   for(int j=0;j<LookbackTicks;j++){' \
'      if(tickBuffer[j].isBuy) buyV+=tickBuffer[j].volume;' \
'      else sellV+=tickBuffer[j].volume;' \
'   }' \
'' \
'   double ofi=(sellV==0)?99:buyV/sellV;' \
'   double spread=Spread();' \
'' \
'   Print("OFI=",ofi," Spread=",spread);' \
'' \
'   if(spread > MaxSpreadPips*2) return;' \
'   if(PositionsTotal()>=MaxConcurrentTrades) return;' \
'' \
'   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);' \
'   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);' \
'' \
'   double pip=Pip();' \
'   double sl,tp;' \
'' \
'   if(ofi>=OFIThreshold){' \
'      sl=ask-StopLossPips*pip;' \
'      tp=ask+TakeProfitPips*pip;' \
'' \
'      MqlTradeRequest r; MqlTradeResult res;' \
'      ZeroMemory(r); ZeroMemory(res);' \
'' \
'      r.action=TRADE_ACTION_DEAL;' \
'      r.symbol=_Symbol;' \
'      r.volume=LotSize;' \
'      r.type=ORDER_TYPE_BUY;' \
'      r.price=ask;' \
'      r.sl=sl;' \
'      r.tp=tp;' \
'      r.deviation=20;' \
'      r.magic=2026;' \
'      r.type_filling=ORDER_FILLING_IOC;' \
'' \
'      OrderSend(r,res);' \
'      Print("BUY RET=",res.retcode);' \
'   }' \
'' \
'   if(ofi<=1.0/OFIThreshold && OFIThreshold>1){' \
'      sl=bid+StopLossPips*pip;' \
'      tp=bid-TakeProfitPips*pip;' \
'' \
'      MqlTradeRequest r; MqlTradeResult res;' \
'      ZeroMemory(r); ZeroMemory(res);' \
'' \
'      r.action=TRADE_ACTION_DEAL;' \
'      r.symbol=_Symbol;' \
'      r.volume=LotSize;' \
'      r.type=ORDER_TYPE_SELL;' \
'      r.price=bid;' \
'      r.sl=sl;' \
'      r.tp=tp;' \
'      r.deviation=20;' \
'      r.magic=2026;' \
'      r.type_filling=ORDER_FILLING_IOC;' \
'' \
'      OrderSend(r,res);' \
'      Print("SELL RET=",res.retcode);' \
'   }' \
'}' \
'EOF' \
'' \
'echo "Compiling..."' \
'if [ -f "$EDITOR_EXE" ]; then' \
'   wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/HFT_OFI_Bot.mq5"' \
'fi' \
'' \
'# CRITICAL FIX: AUTO ATTACH EA TO CHART' \
'sleep 20' \
'' \
'CONFIG="/root/mt5.ini"' \
'cat > $CONFIG <<EOF' \
'[Common]' \
'Login=0' \
'Password=0' \
'Server=0' \
'' \
'[Charts]' \
'Symbol=EURUSD' \
'Period=M1' \
'Expert=HFT_OFI_Bot.ex5' \
'EOF' \
'' \
'wine "$MT5_EXE" /config:$CONFIG &' \
'' \
'python3 -m mt5linux --host 0.0.0.0 --port 8001 &' \
'' \
'echo "BOT RUNNING (FIXED)"' \
'tail -f /dev/null' \
> /entrypoint.sh

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
