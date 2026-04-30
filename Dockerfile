# VALETAX TICK-BASED HFT BOT - REDESIGNED FROM WORKING VERSION
ARG CACHE_BUST=14

FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV RAILWAY_RUN_UID=0

# ============================================
# 1. Install Wine and Dependencies
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc \
    novnc websockify wget curl procps cabextract \
    unzip dos2unix xdotool \
    libxt6 libxrender1 libxext6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python Dependencies
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5 Installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. Create TICK-BASED EA (REDESIGNED - NO BARS)
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
input int      TakeProfit_Price = 250;      // Price difference (not pips)
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
   int      direction;     // 1 = price up, -1 = price down
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

// Price tracking for direction
double   lastPrice = 0;

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
   ArrayResize(tickBuffer, LookbackTicks);
   for(int i = 0; i < LookbackTicks; i++) {
      tickBuffer[i].direction = 0;
      tickBuffer[i].price = 0;
      tickBuffer[i].volume = 0;
   }
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
   Print("  READY - WAITING FOR TICKS...");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| TICK HANDLER - PURE TICK-BASED (NO BARS!)                        |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) return;
   
   // Get current tick data
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   if(currentTick.last <= 0) return;
   
   totalTicks++;
   
   // Determine tick direction based on price movement
   int direction = 0;
   if(lastPrice > 0) {
      if(currentTick.last > lastPrice) direction = 1;
      else if(currentTick.last < lastPrice) direction = -1;
   }
   lastPrice = currentTick.last;
   
   // Store in circular buffer
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = TimeCurrent();
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].direction = direction;
   tickBuffer[idx].volume = currentTick.volume;
   tickCount++;
   
   // Need minimum ticks before analyzing
   if(tickCount < LookbackTicks) return;
   
   // Process every 3 ticks (for speed)
   static int calcCounter = 0;
   calcCounter++;
   if(calcCounter < 2) return;
   calcCounter = 0;
   
   // ========== TICK-BASED OFI CALCULATION ==========
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
   
   // Calculate ratios
   double tickRatio = (sellTicks > 0) ? (double)buyTicks / (double)sellTicks : 99.0;
   double volumeRatio = (sellVolume > 0) ? (double)buyVolume / (double)sellVolume : 99.0;
   double finalOFI = (volumeRatio + tickRatio) / 2.0;  // Weighted average
   
   // Momentum check (price direction)
   bool momentumUp = buyTicks > sellTicks;
   bool momentumDown = sellTicks > buyTicks;
   
   // Debug output every 30 seconds
   static datetime lastDebug = 0;
   if(TimeCurrent() - lastDebug > 15) {
      int spread = GetSpreadPrice();
      Print("🔍 TICK STATS: Ticks=", totalTicks, " | OFI=", DoubleToString(finalOFI, 2), "x | Spread=", spread, " | B=", buyTicks, " S=", sellTicks);
      lastDebug = TimeCurrent();
   }
   
   // Check for existing position
   if(HasPosition()) return;
   
   // Daily reset
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
   }
   
   if(dailyTrades >= MaxDaily_Trades) return;
   if(TimeCurrent() - lastTradeTime < Cooldown_Seconds) return;
   
   // Spread check
   if(GetSpreadPrice() > MaxSpread_Price) return;
   
   // ========== EXECUTE BUY SIGNAL ==========
   if(finalOFI >= OFI_Threshold && momentumUp) {
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(ask <= 0) return;
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      
      double price = ask;
      double sl = price - StopLoss_Price * point;
      double tp = price + TakeProfit_Price * point;
      
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
      
      Print("🚀 BUY SIGNAL | OFI=", DoubleToString(finalOFI, 1), "x | Price=", price);
      
      if(OrderSend(req, res)) {
         if(res.retcode == TRADE_RETCODE_DONE) {
            dailyTrades++;
            lastTradeTime = TimeCurrent();
            Print("✅ BUY EXECUTED! Ticket:", res.order);
         } else {
            Print("❌ Order failed. Retcode:", res.retcode);
         }
      }
   }
   // ========== EXECUTE SELL SIGNAL ==========
   else if(finalOFI <= 1.0 / OFI_Threshold && momentumDown) {
      double bid, ask;
      GetCurrentPrices(bid, ask);
      if(bid <= 0) return;
      
      double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      
      double price = bid;
      double sl = price + StopLoss_Price * point;
      double tp = price - TakeProfit_Price * point;
      
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
      
      Print("🔻 SELL SIGNAL | OFI=", DoubleToString(finalOFI, 1), "x | Price=", price);
      
      if(OrderSend(req, res)) {
         if(res.retcode == TRADE_RETCODE_DONE) {
            dailyTrades++;
            lastTradeTime = TimeCurrent();
            Print("✅ SELL EXECUTED! Ticket:", res.order);
         } else {
            Print("❌ Order failed. Retcode:", res.retcode);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Timer - Status Report                                           |
//+------------------------------------------------------------------+
void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = balance - initialBalance;
   double profitPct = (profit / initialBalance) * 100;
   Print("📊 STATUS | Balance: $", DoubleToString(balance, 2), " | Profit: $", DoubleToString(profit, 2), " (", DoubleToString(profitPct, 2), "%) | Trades: ", dailyTrades, " | Ticks: ", totalTicks);
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = finalBalance - initialBalance;
   Print("========== BOT SHUTDOWN ==========");
   Print(" Final Balance: $", DoubleToString(finalBalance, 2));
   Print(" Total Profit: $", DoubleToString(profit, 2));
   Print(" Total Ticks: ", totalTicks);
   Print("==================================");
}
EOF

# ============================================
# 5. Entrypoint Script (FIXED FOR TICK BOT)
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "VALETAX TICK-BASED HFT BOT v2.0"
echo "=========================================="

# Cleanup
rm -rf /tmp/.X*

# Start Xvfb
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &
sleep 3

# Start fluxbox
fluxbox -display :1 &
sleep 2

# Start x11vnc with stability fixes
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 -noxdamage -noxfixes -bg &
sleep 2

# Start websockify
websockify --web=/usr/share/novnc 0.0.0.0:8080 localhost:5900 &

# Initialize Wine
export WINEDEBUG=-all
export DISPLAY=:1
wineboot --init
sleep 5

# Install MT5 if not present
MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 120
fi

# Start MT5 and wait
echo "Starting MT5..."
wine "$MT5_EXE" &
echo "Waiting for MT5 to fully initialize (60 seconds)..."
sleep 60

# Find REAL terminal directory (exclude Community)
TERMINAL_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal -mindepth 1 -maxdepth 1 -type d ! -name "Community" 2>/dev/null | head -n 1)

if [ -z "$TERMINAL_DIR" ]; then
    echo "ERROR: Terminal directory not found!"
    exit 1
fi

DATA_DIR="$TERMINAL_DIR/MQL5"
echo "Using Terminal Dir: $TERMINAL_DIR"

# Create directories
mkdir -p "$DATA_DIR/Experts"
mkdir -p "$DATA_DIR/Logs"

# Install EA
cp /root/VALETAX_TICK_BOT.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5"

# Compile EA
EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
echo "Compiling Tick-based EA..."
wine "$EDITOR_EXE" /portable /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT.mq5" /log:"C:\\compile.log"
sleep 10

if [ -f "$DATA_DIR/Experts/VALETAX_TICK_BOT.ex5" ]; then
    echo "✅ EA compiled SUCCESSFULLY!"
else
    echo "❌ EA NOT FOUND after compile!"
    cat "$WINEPREFIX/drive_c/compile.log" 2>/dev/null || echo "No log"
fi

# Force Navigator refresh
sleep 2
xdotool search --name "MetaTrader" key Ctrl+n 2>/dev/null || true

# Start mt5linux bridge
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "=========================================="
echo "TICK-BASED BOT READY!"
echo "=========================================="
echo "📊 FEATURES:"
echo "  - Pure tick-based (NO candle bars)"
echo "  - Tick direction tracking"
echo "  - Volume-weighted OFI"
echo "  - 30-tick lookback window"
echo "=========================================="
echo "STEPS:"
echo "1. Open noVNC in browser"
echo "2. Login to Valetutax"
echo "3. Open Navigator (Ctrl+N)"
echo "4. Refresh Expert Advisors"
echo "5. Drag VALETAX_TICK_BOT to chart"
echo "6. Enable Auto-Trading"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
