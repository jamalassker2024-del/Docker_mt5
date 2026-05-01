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
# 4. EA WITH AUTO-ATTACH SUPPORT
# ============================================
RUN cat > /root/VALETAX_TICK_BOT.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                    VALETAX_TICK_BOT.mq5          |
//|                    AUTO-ATTACH - TICK-BASED HFT                  |
//+------------------------------------------------------------------+
#property strict
#property version "5.00"

// ============================================
// INPUT PARAMETERS
// ============================================
input double   LotSize = 0.02;
input double   OFI_Threshold = 1.10;
input int      LookbackTicks = 20;
input int      TakeProfit_Price = 200;
input int      StopLoss_Price = 80;
input int      MaxSpread_Price = 150;
input int      Cooldown_Seconds = 1;
input int      MaxDaily_Trades = 500;
input int      MagicNumber = 999001;

// ========== TICK BUFFER ==========
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
int      totalSignals = 0;
int      totalOrders = 0;

//+------------------------------------------------------------------+
//| Debug print                                                     |
//+------------------------------------------------------------------+
void DebugPrint(string msg) {
   Print("[DEBUG] ", msg);
}

//+------------------------------------------------------------------+
//| Get spread                                                      |
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
   ArrayResize(tickBuffer, LookbackTicks);
   
   DebugPrint("========================================");
   DebugPrint(" VALETAX TICK-BASED HFT BOT v5.0");
   DebugPrint("========================================");
   DebugPrint("Symbol: " + _Symbol);
   DebugPrint("Lot: " + DoubleToString(LotSize, 2));
   DebugPrint("OFI Threshold: " + DoubleToString(OFI_Threshold, 2));
   DebugPrint("Account Balance: $" + DoubleToString(initialBalance, 2));
   DebugPrint("========================================");
   
   // Force symbol selection
   SymbolSelect(_Symbol, true);
   
   isInitialized = true;
   EventSetTimer(5);
   
   DebugPrint("BOT READY - Attached to " + _Symbol);
   DebugPrint("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| TICK HANDLER                                                     |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) return;
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
   // Get price (use bid/ask for .vx symbols)
   double tickPrice = currentTick.last;
   if(tickPrice <= 0) tickPrice = currentTick.bid;
   if(tickPrice <= 0) tickPrice = currentTick.ask;
   if(tickPrice <= 0) return;
   
   totalTicks++;
   
   // First tick received
   if(totalTicks == 1) {
      DebugPrint(">>> TICKS RECEIVED! Price: " + DoubleToString(tickPrice, 6));
   }
   
   // Determine tick direction
   int direction = 0;
   if(lastPrice > 0) {
      if(tickPrice > lastPrice) direction = 1;
      else if(tickPrice < lastPrice) direction = -1;
   }
   lastPrice = tickPrice;
   
   // Store in buffer
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = TimeCurrent();
   tickBuffer[idx].price = tickPrice;
   tickBuffer[idx].direction = direction;
   tickBuffer[idx].volume = currentTick.volume;
   tickCount++;
   
   if(tickCount < LookbackTicks) return;
   
   // Process every 2 ticks
   static int calcCounter = 0;
   calcCounter++;
   if(calcCounter < 2) return;
   calcCounter = 0;
   
   // Calculate OFI
   int buyTicks = 0, sellTicks = 0;
   for(int i = 0; i < LookbackTicks; i++) {
      if(tickBuffer[i].direction > 0) buyTicks++;
      else if(tickBuffer[i].direction < 0) sellTicks++;
   }
   
   double tickRatio = (sellTicks > 0) ? (double)buyTicks / (double)sellTicks : 99.0;
   double finalOFI = tickRatio;
   bool momentumUp = buyTicks > sellTicks;
   bool momentumDown = sellTicks > buyTicks;
   
   // Debug every 50 ticks
   if(totalTicks % 50 == 1) {
      DebugPrint("Tick#" + IntegerToString(totalTicks) + " Price:" + DoubleToString(tickPrice,6) + " OFI:" + DoubleToString(finalOFI,2) + " B:" + IntegerToString(buyTicks) + " S:" + IntegerToString(sellTicks));
   }
   
   if(HasPosition()) return;
   
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
   }
   
   if(dailyTrades >= MaxDaily_Trades) return;
   if(TimeCurrent() - lastTradeTime < Cooldown_Seconds) return;
   
   int spread = GetSpreadPrice();
   if(spread > MaxSpread_Price) return;
   
   // ========== BUY SIGNAL ==========
   if(finalOFI >= OFI_Threshold && momentumUp) {
      totalSignals++;
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(ask <= 0) return;
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double price = ask;
      double sl = price - StopLoss_Price * point;
      double tp = price + TakeProfit_Price * point;
      
      DebugPrint("!!! BUY SIGNAL OFI=" + DoubleToString(finalOFI,2) + " Price=" + DoubleToString(price,digits));
      
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
      req.type_filling = ORDER_FILLING_FOK;
      req.type_time = ORDER_TIME_GTC;
      
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         totalOrders++;
         lastTradeTime = TimeCurrent();
         DebugPrint("SUCCESS: BUY EXECUTED! Ticket:" + IntegerToString(res.order));
      }
   }
   // ========== SELL SIGNAL ==========
   else if(finalOFI <= 1.0 / OFI_Threshold && momentumDown && OFI_Threshold > 1) {
      totalSignals++;
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(bid <= 0) return;
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double price = bid;
      double sl = price + StopLoss_Price * point;
      double tp = price - TakeProfit_Price * point;
      
      DebugPrint("!!! SELL SIGNAL OFI=" + DoubleToString(finalOFI,2) + " Price=" + DoubleToString(price,digits));
      
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
      req.type_filling = ORDER_FILLING_FOK;
      req.type_time = ORDER_TIME_GTC;
      
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         totalOrders++;
         lastTradeTime = TimeCurrent();
         DebugPrint("SUCCESS: SELL EXECUTED! Ticket:" + IntegerToString(res.order));
      }
   }
}

//+------------------------------------------------------------------+
//| Timer - Status Report                                           |
//+------------------------------------------------------------------+
void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = balance - initialBalance;
   Print("[STATUS] Symbol:" + _Symbol + " Ticks:" + IntegerToString(totalTicks) + " Trades:" + IntegerToString(dailyTrades) + " Balance:$" + DoubleToString(balance,2));
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("[DEBUG] Bot shutdown. Signals:" + IntegerToString(totalSignals) + " Orders:" + IntegerToString(totalOrders));
   EventKillTimer();
}
EOF

# ============================================
# 5. ENTRYPOINT WITH AUTO-ATTACH
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "VALETAX TICK-BASED HFT BOT v5.0"
echo "=========================================="

rm -rf /tmp/.X*

# Start X11
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2

fluxbox &
sleep 1

x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &

# Initialize Wine
wineboot --init
sleep 5

# Install MT5 if needed
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 90
fi

echo "Starting MT5..."
wine "$MT5_EXE" &
sleep 45

# Find correct MQL5 folder
DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR=$(find /root/.wine -name "MQL5" -type d 2>/dev/null | head -n 1)
fi
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

echo "MQL5 Directory: $DATA_DIR"

# Install and compile EA
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5"

EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5" /log:"/root/compile.log" 2>&1

if [ -f "$DATA_DIR/Experts/VALETAX_TICK_BOT.ex5" ]; then
    echo "✅ EA compiled successfully!"
fi

# Start bridge
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "=========================================="
echo "BOT READY!"
echo "VNC: http://localhost:8080"
echo ""
echo "TO START TRADING:"
echo "1. Open VNC in browser"
echo "2. Login to Valetutax"
echo "3. Right-click Market Watch -> Show All"
echo "4. Find BTCUSD.vx, ETHUSD.vx"
echo "5. Open chart for each symbol"
echo "6. Drag VALETAX_TICK_BOT to each chart"
echo "7. Enable Auto-Trading (Alt+T)"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
