FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. FAST + LIGHT WINE ENV
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python bridge
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. MT5 installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. FULLY FIXED EA - TICK-BASED HFT
# ============================================
RUN cat > /root/VALETAX_TICK_BOT.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                    VALETAX_TICK_BOT.mq5          |
//|                    TICK-BASED HFT - NO CANDLE BARS               |
//+------------------------------------------------------------------+
#property strict
#property version "2.00"

// ============================================
// INPUT PARAMETERS
// ============================================
input double   LotSize = 0.02;
input double   OFI_Threshold = 1.30;
input int      LookbackTicks = 30;
input int      TakeProfit_Price = 250;
input int      StopLoss_Price = 100;
input int      MaxSpread_Price = 50;
input int      Cooldown_Seconds = 1;
input int      MaxDaily_Trades = 500;
input int      MagicNumber = 999001;

// Supported symbols (Valetutax .vx format)
string Symbols[] = {
   "BTCUSD.vx",
   "ETHUSD.vx",
   "DOGEUSD.vx",
   "LTCUSD.vx",
   "XRPUSD.vx",
   "SOLUSD.vx"
};

// ========== TICK BUFFER STRUCTURE ==========
struct TickRecord {
   datetime time;
   double   price;
   int      direction;
   long     volume;
};

TickRecord tickBuffer[];
int      tickCount = 0;
int      totalTicks = 0;
datetime lastTradeTime = 0;
int      dailyTrades = 0;
int      lastTradeDay = 0;
double   initialBalance = 0;
bool     isInitialized = false;
double   lastPrice = 0;
int cachedFillingMode[6];
bool cacheInitialized[6];

//+------------------------------------------------------------------+
//| Get supported filling mode                                       |
//+------------------------------------------------------------------+
int GetSupportedFillingMode(string sym) {
   long fillingFlags = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fillingFlags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   else if((fillingFlags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Get spread in price terms                                        |
//+------------------------------------------------------------------+
int GetSpreadPrice() {
   return (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

//+------------------------------------------------------------------+
//| Get current bid/ask                                             |
//+------------------------------------------------------------------+
void GetCurrentPrices(double &bid, double &ask) {
   bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
}

//+------------------------------------------------------------------+
//| Day of year                                                     |
//+------------------------------------------------------------------+
int GetDayOfYear() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_year;
}

//+------------------------------------------------------------------+
//| Check if position exists                                        |
//+------------------------------------------------------------------+
bool HasPosition() {
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Initialization                                                  |
//+------------------------------------------------------------------+
int OnInit() {
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastTradeDay = GetDayOfYear();
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      cachedFillingMode[i] = GetSupportedFillingMode(Symbols[i]);
      cacheInitialized[i] = true;
   }
   
   ArrayResize(tickBuffer, LookbackTicks);
   isInitialized = true;
   EventSetTimer(30);
   
   Print("========================================");
   Print("  VALETAX TICK-BASED HFT BOT v2.0      ");
   Print("========================================");
   Print("  LOT: ", LotSize);
   Print("  OFI Threshold: ", OFI_Threshold, "x");
   Print("  TP: ", TakeProfit_Price, " pts | SL: ", StopLoss_Price, " pts");
   Print("  Lookback Ticks: ", LookbackTicks);
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| TICK HANDLER - PURE TICK-BASED                                   |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) return;
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   if(currentTick.last <= 0) return;
   
   totalTicks++;
   
   int direction = 0;
   if(lastPrice > 0) {
      if(currentTick.last > lastPrice) direction = 1;
      else if(currentTick.last < lastPrice) direction = -1;
   }
   lastPrice = currentTick.last;
   
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = TimeCurrent();
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].direction = direction;
   tickBuffer[idx].volume = currentTick.volume;
   tickCount++;
   
   if(tickCount < LookbackTicks) return;
   
   static int calcCounter = 0;
   calcCounter++;
   if(calcCounter < 2) return;
   calcCounter = 0;
   
   int buyTicks = 0, sellTicks = 0;
   long buyVolume = 0, sellVolume = 0;
   
   for(int i = 0; i < LookbackTicks; i++) {
      if(tickBuffer[i].direction > 0) {
         buyTicks++;
         buyVolume += tickBuffer[i].volume;
      } else if(tickBuffer[i].direction < 0) {
         sellTicks++;
         sellVolume += tickBuffer[i].volume;
      }
   }
   
   double tickRatio = (sellTicks > 0) ? (double)buyTicks / (double)sellTicks : 99.0;
   double volumeRatio = (sellVolume > 0) ? (double)buyVolume / (double)sellVolume : 99.0;
   double finalOFI = (volumeRatio + tickRatio) / 2.0;
   bool momentumUp = buyTicks > sellTicks;
   bool momentumDown = sellTicks > buyTicks;
   
   static datetime lastDebug = 0;
   if(TimeCurrent() - lastDebug > 15) {
      int spread = GetSpreadPrice();
      Print("TICK STATS: Ticks=", totalTicks, " | OFI=", DoubleToString(finalOFI, 2), "x | Spread=", spread);
      lastDebug = TimeCurrent();
   }
   
   if(HasPosition()) return;
   
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
   }
   
   if(dailyTrades >= MaxDaily_Trades) return;
   if(TimeCurrent() - lastTradeTime < Cooldown_Seconds) return;
   if(GetSpreadPrice() > MaxSpread_Price) return;
   
   if(finalOFI >= OFI_Threshold && momentumUp) {
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(ask <= 0) return;
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double price = ask;
      double sl = price - StopLoss_Price * point;
      double tp = price + TakeProfit_Price * point;
      
      int fillingMode = ORDER_FILLING_RETURN;
      for(int i = 0; i < ArraySize(Symbols); i++) {
         if(Symbols[i] == _Symbol && cacheInitialized[i]) {
            fillingMode = cachedFillingMode[i];
            break;
         }
      }
      
      MqlTradeRequest req = {};
      MqlTradeResult res = {};
      
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.volume = LotSize;
      req.type = ORDER_TYPE_BUY;
      req.price = NormalizeDouble(price, digits);
      req.sl = NormalizeDouble(sl, digits);
      req.tp = NormalizeDouble(tp, digits);
      req.deviation = 50;
      req.magic = MagicNumber;
      req.comment = "OFI_" + DoubleToString(finalOFI, 1);
      req.type_filling = fillingMode;
      req.type_time = ORDER_TIME_GTC;
      
      Print("BUY SIGNAL | OFI=", DoubleToString(finalOFI, 1), "x | Price=", price);
      
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         Print("BUY EXECUTED! Ticket:", res.order);
      }
   }
   else if(finalOFI <= 1.0 / OFI_Threshold && momentumDown) {
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(bid <= 0) return;
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double price = bid;
      double sl = price + StopLoss_Price * point;
      double tp = price - TakeProfit_Price * point;
      
      int fillingMode = ORDER_FILLING_RETURN;
      for(int i = 0; i < ArraySize(Symbols); i++) {
         if(Symbols[i] == _Symbol && cacheInitialized[i]) {
            fillingMode = cachedFillingMode[i];
            break;
         }
      }
      
      MqlTradeRequest req = {};
      MqlTradeResult res = {};
      
      req.action = TRADE_ACTION_DEAL;
      req.symbol = _Symbol;
      req.volume = LotSize;
      req.type = ORDER_TYPE_SELL;
      req.price = NormalizeDouble(price, digits);
      req.sl = NormalizeDouble(sl, digits);
      req.tp = NormalizeDouble(tp, digits);
      req.deviation = 50;
      req.magic = MagicNumber;
      req.comment = "OFI_" + DoubleToString(finalOFI, 1);
      req.type_filling = fillingMode;
      req.type_time = ORDER_TIME_GTC;
      
      Print("SELL SIGNAL | OFI=", DoubleToString(finalOFI, 1), "x | Price=", price);
      
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         Print("SELL EXECUTED! Ticket:", res.order);
      }
   }
}

//+------------------------------------------------------------------+
//| Timer - Status Report                                           |
//+------------------------------------------------------------------+
void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = balance - initialBalance;
   Print("STATUS | Balance: $", DoubleToString(balance, 2), " | Profit: $", DoubleToString(profit, 2), " | Trades: ", dailyTrades, " | Ticks: ", totalTicks);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
}
EOF

# ============================================
# 5. ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

rm -rf /tmp/.X*

Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2

fluxbox &
sleep 1

x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &

wineboot --init
sleep 5

MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 60
fi

echo "Starting MT5..."
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5"

echo "Compiling EA..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5" /log:"/root/compile.log" 2>&1

if [ -f "/root/compile.log" ]; then
    if grep -q "0 error(s)" /root/compile.log && grep -q "0 warning(s)" /root/compile.log; then
        echo "Compilation SUCCESS - 0 errors, 0 warnings"
    else
        echo "Compilation completed"
    fi
fi

echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 3
done &

echo "=========================================="
echo "TICK-BASED BOT READY!"
echo "VNC: http://localhost:8080"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
