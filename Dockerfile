FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. Install Dependencies (FAST + CLEAN)
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox novnc websockify \
    wget curl unzip procps cabextract dos2unix \
    libxt6 libxrender1 libxext6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python libs
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. CREATE HFT BOT
# ============================================
RUN cat > /root/OFI_HFT_Bot.mq5 << 'EOF'
//+------------------------------------------------------------------+
#property strict

input double LotSize=0.01;
input int OFIThreshold=2;
input int LookbackTicks=20;
input int TP=3;
input int SL=2;
input int MaxSpread=2;
input int MaxPositions=10;

struct T{
 double p; bool b; long v;
};

T buf[];
int c=0;

double pip(){ return (_Digits==3||_Digits==5)?_Point*10:_Point; }

double spread(){
 return (SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID))/pip();
}

int OnInit(){
 ArrayResize(buf,LookbackTicks);
 return(INIT_SUCCEEDED);
}

void OnTick(){

 if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
 if(PositionsTotal()>MaxPositions) return;
 if(spread()>MaxSpread) return;

 MqlTick t;
 if(!SymbolInfoTick(_Symbol,t)) return;

 bool buy = (t.last>=t.ask);

 int i=c%LookbackTicks;
 buf[i].p=t.last;
 buf[i].b=buy;
 buf[i].v=t.volume;
 c++;

 if(c<LookbackTicks) return;

 double bv=0,sv=0;
 for(int k=0;k<LookbackTicks;k++){
  if(buf[k].b) bv+=buf[k].v;
  else sv+=buf[k].v;
 }

 double ofi = (sv==0)?99:bv/sv;

 double last=buf[(c-1)%LookbackTicks].p;
 double prev=buf[(c-2)%LookbackTicks].p;

 bool up = last>prev;
 bool down = last<prev;

 double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
 double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
 double p=pip();

 // BUY
 if(ofi>=OFIThreshold && up){
  MqlTradeRequest r={};
  MqlTradeResult res={};

  r.action=TRADE_ACTION_DEAL;
  r.symbol=_Symbol;
  r.volume=LotSize;
  r.type=ORDER_TYPE_BUY;
  r.price=ask;
  r.sl=ask-(SL*p);
  r.tp=ask+(TP*p);
  r.deviation=5;
  r.magic=2026;
  r.type_filling=ORDER_FILLING_IOC;

  OrderSend(r,res);
 }

 // SELL
 if(ofi<=1.0/OFIThreshold && down){
  MqlTradeRequest r={};
  MqlTradeResult res={};

  r.action=TRADE_ACTION_DEAL;
  r.symbol=_Symbol;
  r.volume=LotSize;
  r.type=ORDER_TYPE_SELL;
  r.price=bid;
  r.sl=bid+(SL*p);
  r.tp=bid-(TP*p);
  r.deviation=5;
  r.magic=2026;
  r.type_filling=ORDER_FILLING_IOC;

  OrderSend(r,res);
 }
}
EOF

# ============================================
# 5. ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash

echo "STARTING MT5 HFT BOT..."

rm -f /tmp/.X1-lock

Xvfb :1 -screen 0 1280x800x16 &
sleep 2

fluxbox &
x11vnc -display :1 -forever -nopw -shared -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

wineboot --init
sleep 5

# Install MT5 if not exists
if [ ! -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto /silent &
    sleep 120
fi

export DISPLAY=:1

# First launch
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" &
sleep 40

wineserver -k
sleep 5

DATA=$(find /root/.wine -name MQL5 -type d | head -n 1)

mkdir -p "$DATA/Experts"
cp /root/OFI_HFT_Bot.mq5 "$DATA/Experts/"

echo "Compiling..."
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" \
/compile:"$DATA/Experts/OFI_HFT_Bot.mq5"

sleep 10

echo "Starting MT5..."
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" &

python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "READY → Open noVNC (port 8080)"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
