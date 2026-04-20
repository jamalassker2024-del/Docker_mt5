FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. Install Wine and Dependencies
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox \
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
#property version   "3.00"
#property strict

// ========== AGGRESSOR SETTINGS ==========
input double   LotSize = 0.01;
input double   OFIThreshold = 1.5;            // Lowered for high frequency
input int      LookbackTicks = 10;            // Ultra-fast window
input int      TakeProfitPips = 2;            // Scalp targets
input int      StopLossPips = 5;              // Wider SL to stay in trades
input int      MaxSpreadPips = 10;            // Loosened to allow more entries
input int      MaxDailyTrades = 5000;         
input int      MaxConcurrentTrades = 50;      // Massively increased

struct TickData {
   double   price;
   bool     isBuy;
   long     volume;
};

TickData tickBuffer[];
int      tickCount = 0;
datetime lastTradeTime = 0;
int      dailyTrades = 0;
int      lastTradeDay = 0;

int GetCurrentDay() {
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   return tm.day;
}

double GetPipValue() {
   return (_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point;
}

int OnInit() {
   ArrayResize(tickBuffer, LookbackTicks);
   lastTradeDay = GetCurrentDay();
   Print("🚀 SUPER HFT MODE ACTIVATED");
   return(INIT_SUCCEEDED);
}

void OnTick() {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   
   if(GetCurrentDay() != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = GetCurrentDay();
   }
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
   // Determine Aggressor
   bool isBuyTick = (currentTick.last >= currentTick.ask);
   
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].isBuy = isBuyTick;
   tickBuffer[idx].volume = (currentTick.tick_volume > 0) ? currentTick.tick_volume : 1;
   tickCount++;
   
   if(tickCount < LookbackTicks) return;
   
   // ========== CALC OFI RATIO ==========
   double buyVol = 0, sellVol = 0;
   for(int i = 0; i < LookbackTicks; i++) {
      if(tickBuffer[i].isBuy) buyVol += tickBuffer[i].volume;
      else sellVol += tickBuffer[i].volume;
   }
   
   double ofiRatio = (sellVol <= 0) ? 99.0 : buyVol / sellVol;
   
   // Check limits
   if(PositionsTotal() >= MaxConcurrentTrades || dailyTrades >= MaxDailyTrades) return;

   // Spread Check
   double spread = (SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID)) / GetPipValue();
   if(spread > MaxSpreadPips) return;

   // ========== EXECUTION ==========
   string action = "";
   if(ofiRatio >= OFIThreshold) action = "BUY";
   else if(ofiRatio <= 1.0 / OFIThreshold) action = "SELL";

   if(action != "") {
      ExecuteTrade(action, ofiRatio);
   }
}

void ExecuteTrade(string action, double ofi) {
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   double pip = GetPipValue();
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.magic  = 2026;
   request.deviation = 20; // High slippage tolerance for HFT
   
   // ORDER_FILLING_IOC (Immediate Or Cancel) is better than FOK for high volume
   request.type_filling = ORDER_FILLING_IOC; 
   
   if(action == "BUY") {
      request.type = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      request.tp = NormalizeDouble(request.price + (TakeProfitPips * pip), digits);
      request.sl = NormalizeDouble(request.price - (StopLossPips * pip), digits);
   } else {
      request.type = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      request.tp = NormalizeDouble(request.price - (TakeProfitPips * pip), digits);
      request.sl = NormalizeDouble(request.price + (StopLossPips * pip), digits);
   }

   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED) {
         dailyTrades++;
         Print("🎯 ", action, " | OFI: ", ofi);
      }
   }
}
EOF

# ============================================
# 5. Create Entrypoint Script
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
rm -f /tmp/.X1-lock
Xvfb :1 -screen 0 1280x800x16 &
sleep 2
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
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/HFT_OFI_Bot.mq5" /log:"/root/compile.log"
wine "$MT5_EXE" &
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
