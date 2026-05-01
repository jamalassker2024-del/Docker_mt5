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
# 4. FULL DEBUG EA - TICK-BASED HFT WITH DEBUG OUTPUT
# ============================================
RUN cat > /root/VALETAX_TICK_BOT.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                    VALETAX_TICK_BOT.mq5          |
//|                    TICK-BASED HFT - FULL DEBUG VERSION           |
//+------------------------------------------------------------------+
#property strict
#property version "3.00"

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

// Supported symbols
string Symbols[] = {
   "BTCUSD.vx",
   "ETHUSD.vx",
   "DOGEUSD.vx",
   "LTCUSD.vx",
   "XRPUSD.vx"
};

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
//| Debug print                                                    |
//+------------------------------------------------------------------+
void DebugPrint(string msg) {
   Print("[DEBUG] ", msg);
}

//+------------------------------------------------------------------+
//| Get spread                                                      |
//+------------------------------------------------------------------+
int GetSpreadPrice() {
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return spread;
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
   isInitialized = true;
   EventSetTimer(10);
   
   DebugPrint("========== BOT INITIALIZED ==========");
   DebugPrint("Symbol: " + _Symbol);
   DebugPrint("Lot: " + DoubleToString(LotSize, 2));
   DebugPrint("OFI Threshold: " + DoubleToString(OFI_Threshold, 2));
   DebugPrint("Lookback Ticks: " + IntegerToString(LookbackTicks));
   DebugPrint("TP: " + IntegerToString(TakeProfit_Price) + " pts");
   DebugPrint("SL: " + IntegerToString(StopLoss_Price) + " pts");
   DebugPrint("Account Balance: $" + DoubleToString(initialBalance, 2));
   DebugPrint("=====================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| TICK HANDLER - WITH FULL DEBUG                                  |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) {
      DebugPrint("WARNING: Bot not initialized!");
      return;
   }
   
   // Get current tick
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) {
      DebugPrint("ERROR: Cannot get tick data for " + _Symbol);
      return;
   }
   
   if(currentTick.last <= 0) {
      DebugPrint("WARNING: Invalid tick price: " + DoubleToString(currentTick.last, 6));
      return;
   }
   
   totalTicks++;
   
   // Determine tick direction
   int direction = 0;
   if(lastPrice > 0) {
      if(currentTick.last > lastPrice) direction = 1;
      else if(currentTick.last < lastPrice) direction = -1;
   }
   lastPrice = currentTick.last;
   
   // Store in buffer
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = TimeCurrent();
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].direction = direction;
   tickBuffer[idx].volume = currentTick.volume;
   tickCount++;
   
   // Debug every 100 ticks
   if(totalTicks % 100 == 1) {
      DebugPrint("Tick #" + IntegerToString(totalTicks) + " - Price: " + DoubleToString(currentTick.last, 6) + " | Dir: " + IntegerToString(direction));
   }
   
   // Need minimum ticks before analyzing
   if(tickCount < LookbackTicks) {
      if(totalTicks == LookbackTicks) {
         DebugPrint("Buffer filled. Ready to analyze after " + IntegerToString(LookbackTicks) + " ticks.");
      }
      return;
   }
   
   // Process every 2 ticks
   static int calcCounter = 0;
   calcCounter++;
   if(calcCounter < 2) return;
   calcCounter = 0;
   
   // Calculate OFI
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
   
   // Always print OFI every 100 ticks for debugging
   if(totalTicks % 100 == 1) {
      DebugPrint("OFI Calculation: Buy=" + IntegerToString(buyTicks) + " Sell=" + IntegerToString(sellTicks) + " Ratio=" + DoubleToString(finalOFI, 2));
   }
   
   // Check for position
   if(HasPosition()) return;
   
   // Daily reset
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
      DebugPrint("New day - Daily trades reset");
   }
   
   // Trade limits
   if(dailyTrades >= MaxDaily_Trades) {
      if(dailyTrades == MaxDaily_Trades) DebugPrint("Daily trade limit reached: " + IntegerToString(MaxDaily_Trades));
      return;
   }
   
   if(TimeCurrent() - lastTradeTime < Cooldown_Seconds) return;
   
   // Spread check
   int spread = GetSpreadPrice();
   if(spread > MaxSpread_Price) {
      if(totalTicks % 500 == 1) DebugPrint("Spread too high: " + IntegerToString(spread) + " (max: " + IntegerToString(MaxSpread_Price) + ")");
      return;
   }
   
   // ========== CHECK BUY SIGNAL ==========
   if(finalOFI >= OFI_Threshold && momentumUp) {
      totalSignals++;
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(ask <= 0) {
         DebugPrint("ERROR: Invalid ask price: " + DoubleToString(ask, 6));
         return;
      }
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double price = ask;
      double sl = price - StopLoss_Price * point;
      double tp = price + TakeProfit_Price * point;
      
      DebugPrint("=====================================");
      DebugPrint("!!! BUY SIGNAL TRIGGERED !!!");
      DebugPrint("OFI Ratio: " + DoubleToString(finalOFI, 2));
      DebugPrint("Buy Ticks: " + IntegerToString(buyTicks) + " | Sell Ticks: " + IntegerToString(sellTicks));
      DebugPrint("Price: " + DoubleToString(price, digits));
      DebugPrint("SL: " + DoubleToString(sl, digits));
      DebugPrint("TP: " + DoubleToString(tp, digits));
      DebugPrint("Spread: " + IntegerToString(spread));
      DebugPrint("=====================================");
      
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
      
      if(OrderSend(req, res)) {
         if(res.retcode == TRADE_RETCODE_DONE) {
            dailyTrades++;
            totalOrders++;
            lastTradeTime = TimeCurrent();
            DebugPrint("SUCCESS: BUY ORDER EXECUTED! Ticket: " + IntegerToString(res.order));
         } else {
            DebugPrint("FAILED: Order rejected. Retcode: " + IntegerToString(res.retcode));
         }
      } else {
         DebugPrint("ERROR: OrderSend failed. Error: " + IntegerToString(GetLastError()));
      }
   }
   // ========== CHECK SELL SIGNAL ==========
   else if(finalOFI <= 1.0 / OFI_Threshold && momentumDown && OFI_Threshold > 1) {
      totalSignals++;
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(bid <= 0) {
         DebugPrint("ERROR: Invalid bid price: " + DoubleToString(bid, 6));
         return;
      }
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      double price = bid;
      double sl = price + StopLoss_Price * point;
      double tp = price - TakeProfit_Price * point;
      
      DebugPrint("=====================================");
      DebugPrint("!!! SELL SIGNAL TRIGGERED !!!");
      DebugPrint("OFI Ratio: " + DoubleToString(finalOFI, 2));
      DebugPrint("Buy Ticks: " + IntegerToString(buyTicks) + " | Sell Ticks: " + IntegerToString(sellTicks));
      DebugPrint("Price: " + DoubleToString(price, digits));
      DebugPrint("SL: " + DoubleToString(sl, digits));
      DebugPrint("TP: " + DoubleToString(tp, digits));
      DebugPrint("Spread: " + IntegerToString(spread));
      DebugPrint("=====================================");
      
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
      
      if(OrderSend(req, res)) {
         if(res.retcode == TRADE_RETCODE_DONE) {
            dailyTrades++;
            totalOrders++;
            lastTradeTime = TimeCurrent();
            DebugPrint("SUCCESS: SELL ORDER EXECUTED! Ticket: " + IntegerToString(res.order));
         } else {
            DebugPrint("FAILED: Order rejected. Retcode: " + IntegerToString(res.retcode));
         }
      } else {
         DebugPrint("ERROR: OrderSend failed. Error: " + IntegerToString(GetLastError()));
      }
   }
}

//+------------------------------------------------------------------+
//| Timer - Status Report                                           |
//+------------------------------------------------------------------+
void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = balance - initialBalance;
   double spread = GetSpreadPrice();
   
   Print("[STATUS] ====================================");
   Print("[STATUS] Symbol: " + _Symbol);
   Print("[STATUS] Balance: $" + DoubleToString(balance, 2));
   Print("[STATUS] Profit: $" + DoubleToString(profit, 2));
   Print("[STATUS] Daily Trades: " + IntegerToString(dailyTrades));
   Print("[STATUS] Total Ticks: " + IntegerToString(totalTicks));
   Print("[STATUS] Total Signals: " + IntegerToString(totalSignals));
   Print("[STATUS] Total Orders: " + IntegerToString(totalOrders));
   Print("[STATUS] Spread: " + DoubleToString(spread, 1) + " pts");
   Print("[STATUS] Current Price: " + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), 6));
   Print("[STATUS] Buffer Ticks: " + IntegerToString(tickCount));
   Print("[STATUS] Last Trade: " + TimeToString(lastTradeTime));
   Print("[STATUS] ====================================");
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("[DEBUG] Bot shutting down. Reason: " + IntegerToString(reason));
   Print("[DEBUG] Total Signals: " + IntegerToString(totalSignals));
   Print("[DEBUG] Total Orders Executed: " + IntegerToString(totalOrders));
   EventKillTimer();
}
EOF

# ============================================
# 5. ENTRYPOINT WITH DEBUG
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "DEBUG: Starting TICK-BASED BOT v3.0"
echo "=========================================="

rm -rf /tmp/.X*

echo "DEBUG: Starting Xvfb..."
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2

echo "DEBUG: Starting fluxbox..."
fluxbox &
sleep 1

echo "DEBUG: Starting x11vnc..."
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
sleep 1

echo "DEBUG: Starting websockify..."
websockify --web=/usr/share/novnc 8080 localhost:5900 &

echo "DEBUG: Initializing Wine..."
wineboot --init
sleep 5

MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "DEBUG: Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 60
fi

echo "DEBUG: Starting MT5..."
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

echo "DEBUG: MQL5 Directory: $DATA_DIR"

mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5"

echo "DEBUG: Compiling EA..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5" /log:"/root/compile.log" 2>&1

if [ -f "/root/compile.log" ]; then
    echo "DEBUG: Compilation log:"
    cat /root/compile.log
    if grep -q "0 error(s)" /root/compile.log && grep -q "0 warning(s)" /root/compile.log; then
        echo "DEBUG: Compilation SUCCESS - 0 errors, 0 warnings"
    else
        echo "DEBUG: Compilation completed with warnings"
    fi
fi

echo "DEBUG: Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "DEBUG: Starting auto-refresh..."
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 3
done &

echo "=========================================="
echo "DEBUG: TICK-BASED BOT READY!"
echo "DEBUG: VNC: http://localhost:8080"
echo "=========================================="
echo ""
echo "IMPORTANT - Check MT5 Experts tab for:"
echo "  - 'VALETAX_TICK_BOT' attached to chart"
echo "  - 'Auto-Trading' enabled (Alt+T)"
echo "  - 'DEBUG:' messages in Experts log"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
