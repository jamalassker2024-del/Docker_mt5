# VALETAX AGGRESSIVE SCALPER v3.0
FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. Install Wine + GUI
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps unzip dos2unix xdotool \
    libxt6 libxrender1 libxext6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python deps
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. AGGRESSIVE EA
# ============================================
RUN cat > /root/VALETAX_PROFIT_BOT.mq5 << 'EOF'
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
# 5. ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &

wineboot --init
sleep 5

wine /root/mt5setup.exe /auto
sleep 90

wine "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe" &
sleep 25

DATA_DIR=$(find /root/.wine -name "MQL5" | head -n 1)

mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_PROFIT_BOT.mq5 "$DATA_DIR/Experts/"

wine "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" \
/compile:"$DATA_DIR/Experts/VALETAX_PROFIT_BOT.mq5"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "READY - OPEN VNC"
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001
CMD ["/entrypoint.sh"]
