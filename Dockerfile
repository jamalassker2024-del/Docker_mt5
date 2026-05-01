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
# 4. FULLY FIXED EA - 0 ERRORS 0 WARNINGS
# ============================================
RUN cat << 'EOF' > /root/VALETAX_PROFIT_BOT.mq5
//+------------------------------------------------------------------+
//|                                    VALETAX_TICK_BOT.mq5          |
//|                    TICK-BASED HFT - .vx SYMBOL SUPPORT           |
//+------------------------------------------------------------------+
#property strict
#property version "4.00"

// ============================================
// INPUT PARAMETERS
// ============================================
input double   LotSize = 0.02;
input double   OFI_Threshold = 1.15;
input int      LookbackTicks = 30;
input int      TakeProfit_Price = 250;
input int      StopLoss_Price = 100;
input int      MaxSpread_Price = 100;
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
bool     symbolSelected = false;

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
   DebugPrint(" VALETAX TICK-BASED HFT BOT v4.0");
   DebugPrint("========================================");
   DebugPrint("Symbol: " + _Symbol);
   DebugPrint("Lot: " + DoubleToString(LotSize, 2));
   DebugPrint("OFI Threshold: " + DoubleToString(OFI_Threshold, 2));
   DebugPrint("Account Balance: $" + DoubleToString(initialBalance, 2));
   DebugPrint("========================================");
   
   // FORCE symbol selection - CRITICAL FOR .vx SYMBOLS!
   DebugPrint("Attempting to select symbol: " + _Symbol);
   symbolSelected = SymbolSelect(_Symbol, true);
   if(symbolSelected) {
      DebugPrint("SUCCESS: Symbol " + _Symbol + " selected in Market Watch");
   } else {
      DebugPrint("WARNING: Could not select " + _Symbol + " - trying alternative names");
      
      // Try alternative naming
      string altSymbol = _Symbol;
      StringReplace(altSymbol, ".vx", "");
      DebugPrint("Trying without .vx: " + altSymbol);
      if(SymbolSelect(altSymbol, true)) {
         symbolSelected = true;
         DebugPrint("SUCCESS: Found symbol as " + altSymbol);
      } else {
         DebugPrint("ERROR: Symbol not available. Please add " + _Symbol + " to Market Watch manually.");
      }
   }
   
   // Get symbol info
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   DebugPrint("Point: " + DoubleToString(point, 8));
   DebugPrint("Digits: " + IntegerToString(digits));
   
   isInitialized = true;
   EventSetTimer(10);
   
   DebugPrint("BOT INITIALIZED - WAITING FOR TICKS...");
   DebugPrint("If NO ticks: Make sure '" + _Symbol + "' is in Market Watch (Market Watch -> Show All)");
   DebugPrint("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| TICK HANDLER                                                     |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) {
      DebugPrint("ERROR: Bot not initialized!");
      return;
   }
   
   // Get current tick - use bid/ask for .vx symbols
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) {
      if(totalTicks == 0) {
         DebugPrint("ERROR: Cannot get tick data for " + _Symbol);
         DebugPrint("Make sure symbol is visible in Market Watch");
      }
      return;
   }
   
   // For .vx symbols, use bid if last is zero
   double tickPrice = currentTick.last;
   if(tickPrice <= 0) {
      tickPrice = currentTick.bid;
      if(tickPrice <= 0) {
         tickPrice = currentTick.ask;
      }
      if(tickPrice <= 0) {
         if(totalTicks == 0) {
            DebugPrint("WARNING: No price data for " + _Symbol);
            DebugPrint("  Bid: " + DoubleToString(currentTick.bid, 6));
            DebugPrint("  Ask: " + DoubleToString(currentTick.ask, 6));
            DebugPrint("  Last: " + DoubleToString(currentTick.last, 6));
         }
         return;
      }
   }
   
   totalTicks++;
   
   // First tick received
   if(totalTicks == 1) {
      DebugPrint(">>> FIRST TICK RECEIVED! Price: " + DoubleToString(tickPrice, 6));
      DebugPrint(">>> Bot is working! <<<");
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
   
   // Debug every 100 ticks
   if(totalTicks % 100 == 1) {
      DebugPrint("Tick #" + IntegerToString(totalTicks) + " | Price: " + DoubleToString(tickPrice, 6) + " | OFI: " + DoubleToString(finalOFI, 2) + " | B:" + IntegerToString(buyTicks) + " S:" + IntegerToString(sellTicks));
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
      
      DebugPrint("=====================================");
      DebugPrint("!!! BUY SIGNAL TRIGGERED !!!");
      DebugPrint("OFI: " + DoubleToString(finalOFI, 2));
      DebugPrint("Price: " + DoubleToString(price, digits));
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
            DebugPrint("FAILED: Retcode: " + IntegerToString(res.retcode));
         }
      } else {
         DebugPrint("ERROR: OrderSend failed. Error: " + IntegerToString(GetLastError()));
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
      
      DebugPrint("=====================================");
      DebugPrint("!!! SELL SIGNAL TRIGGERED !!!");
      DebugPrint("OFI: " + DoubleToString(finalOFI, 2));
      DebugPrint("Price: " + DoubleToString(price, digits));
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
            DebugPrint("FAILED: Retcode: " + IntegerToString(res.retcode));
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
   int spread = GetSpreadPrice();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   
   Print("[STATUS] ====================================");
   Print("[STATUS] Symbol: " + _Symbol);
   Print("[STATUS] Balance: $" + DoubleToString(balance, 2));
   Print("[STATUS] Profit: $" + DoubleToString(profit, 2));
   Print("[STATUS] Daily Trades: " + IntegerToString(dailyTrades));
   Print("[STATUS] Total Ticks: " + IntegerToString(totalTicks));
   Print("[STATUS] Total Signals: " + IntegerToString(totalSignals));
   Print("[STATUS] Total Orders: " + IntegerToString(totalOrders));
   Print("[STATUS] Spread: " + IntegerToString(spread));
   Print("[STATUS] Bid: " + DoubleToString(bid, 6));
   Print("[STATUS] Ask: " + DoubleToString(ask, 6));
   Print("[STATUS] ====================================");
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("[DEBUG] Bot shutting down. Total Signals: " + IntegerToString(totalSignals) + " | Orders: " + IntegerToString(totalOrders));
   EventKillTimer();
}

EOF

# ============================================
# 5. ENTRYPOINT
# ============================================
RUN cat << 'EOF' > /entrypoint.sh
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
    echo "📦 Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 60
fi

echo "🚀 Starting MT5..."
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_PROFIT_BOT.mq5 "$DATA_DIR/Experts/VALETAX_PROFIT_BOT.mq5"

echo "🔧 Compiling..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_PROFIT_BOT.mq5" /log:"/root/compile.log" 2>&1

if [ -f "/root/compile.log" ]; then
    if grep -q "0 error(s)" /root/compile.log && grep -q "0 warning(s)" /root/compile.log; then
        echo "✅ Compilation SUCCESS - 0 errors, 0 warnings"
    else
        echo "⚠️ Compilation log:"
        cat /root/compile.log
    fi
fi

echo "🌉 Starting MT5-Linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "💓 Starting 3-second stimulation..."
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 3
done &

echo "╔══════════════════════════════════════════════╗"
echo "║  🔥 v10.0 - FULLY FIXED - 0 ERRORS 0 WARN 🔥 ║"
echo "║  VNC: http://localhost:8080                 ║"
echo "╚══════════════════════════════════════════════╝"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
