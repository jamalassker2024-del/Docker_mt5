FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. Install Wine + GUI + Tools
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox \
    novnc websockify wget curl procps cabextract \
    unzip dos2unix \
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
# 4. DEBUG BOT (VERY IMPORTANT)
# ============================================
RUN cat > /root/HFT_DEBUG_BOT.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                  HFT BOT - FULL DEBUG VERSION                    |
//+------------------------------------------------------------------+
#property strict

input double LotSize = 0.01;
input int TakeProfitPips = 3;
input int StopLossPips = 2;
input int MaxSpreadPips = 50;

datetime lastLog=0;

//------------------------------------------------
double GetPip()
{
   return (_Digits==3 || _Digits==5) ? _Point*10 : _Point;
}

double Spread()
{
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0 || bid<=0) return 999;
   return (ask-bid)/GetPip();
}

//------------------------------------------------
int OnInit()
{
   Print("====== DEBUG BOT STARTED ======");
   Print("Symbol:",_Symbol);

   Print("Terminal Trade Allowed:",TerminalInfoInteger(TERMINAL_TRADE_ALLOWED));
   Print("Account Trade Allowed:",AccountInfoInteger(ACCOUNT_TRADE_ALLOWED));
   Print("Symbol Trade Mode:",SymbolInfoInteger(_Symbol,SYMBOL_TRADE_MODE));
   Print("Filling Mode:",SymbolInfoInteger(_Symbol,SYMBOL_FILLING_MODE));

   return INIT_SUCCEEDED;
}

//------------------------------------------------
void OnTick()
{
   MqlTick tick;

   if(!SymbolInfoTick(_Symbol,tick))
   {
      Print("❌ NO TICK DATA");
      return;
   }

   if(tick.ask<=0 || tick.bid<=0)
   {
      Print("❌ INVALID PRICES");
      return;
   }

   double spread=Spread();

   if(TimeCurrent()-lastLog>2)
   {
      Print("Tick OK | Bid:",tick.bid," Ask:",tick.ask," Spread:",spread," Positions:",PositionsTotal());
      lastLog=TimeCurrent();
   }

   if(spread>MaxSpreadPips)
   {
      Print("🚫 SKIP SPREAD:",spread);
      return;
   }

   // 🔥 FORCE SIGNAL (for debugging execution)
   if(MathRand()%15!=1)
   {
      Print("No trade condition...");
      return;
   }

   Print("🔥 SIGNAL -> TRY BUY");

   //--------------------------------------------
   MqlTradeRequest req;
   MqlTradeResult res;

   ZeroMemory(req);
   ZeroMemory(res);

   double price=tick.ask;
   double pip=GetPip();

   req.action=TRADE_ACTION_DEAL;
   req.symbol=_Symbol;
   req.volume=LotSize;
   req.type=ORDER_TYPE_BUY;
   req.price=price;
   req.sl=price-StopLossPips*pip;
   req.tp=price+TakeProfitPips*pip;
   req.deviation=20;
   req.magic=777;

   // 🔥 IMPORTANT FIX
   req.type_filling=ORDER_FILLING_IOC;

   Print("Sending order...");
   Print("Price:",price," SL:",req.sl," TP:",req.tp);

   if(!OrderSend(req,res))
   {
      Print("❌ OrderSend FAILED (terminal level)");
      return;
   }

   Print("==== RESULT ====");
   Print("Retcode:",res.retcode);
   Print("Deal:",res.deal);
   Print("Order:",res.order);
   Print("Comment:",res.comment);

   if(res.retcode!=TRADE_RETCODE_DONE)
   {
      Print("❌ TRADE FAILED CODE:",res.retcode);
   }
   else
   {
      Print("✅ TRADE SUCCESS");
   }
}
EOF

# ============================================
# 5. ENTRYPOINT (IMPROVED DEBUG)
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash

echo "========= STARTING SYSTEM ========="

rm -f /tmp/.X1-lock

Xvfb :1 -screen 0 1280x800x16 &
sleep 2

fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

wineboot --init
sleep 5

MT5="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"

if [ ! -f "$MT5" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto /silent &
    sleep 90
fi

export DISPLAY=:1

echo "Launching MT5 first time..."
wine "$MT5" &
sleep 40
wineserver -k
sleep 5

DATA=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "Include" | head -n1 | sed 's/\/Include//')

if [ -z "$DATA" ]; then
   DATA="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

echo "MQL PATH: $DATA"

mkdir -p "$DATA/Experts"
cp /root/HFT_DEBUG_BOT.mq5 "$DATA/Experts/HFT_DEBUG_BOT.mq5"

WIN_PATH=$(wine winepath -w "$DATA/Experts/HFT_DEBUG_BOT.mq5")

echo "Compiling..."
wine "$EDITOR" /compile:"$WIN_PATH" /log:"/root/compile.log"

sleep 5

echo "===== COMPILE LOG ====="
cat /root/compile.log || true

echo "Starting MT5..."
wine "$MT5" &

python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "========= READY ========="
echo "Open noVNC -> attach bot manually"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash","/entrypoint.sh"]
