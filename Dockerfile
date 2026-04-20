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
# 2. Install Python deps (for bridge, optional)
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5 Installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. Create MQL5 Bot Code (FIXED - using tick_volume)
# ============================================
RUN cat << 'EOF' > /root/OFI_Tick_Bot.mq5
//+------------------------------------------------------------------+
//|                                                  OFI_Tick_Bot.mq5 |
//|                                    Order Flow Imbalance Scalper   |
//+------------------------------------------------------------------+
#property copyright "OFI Bot"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input double   LotSize = 0.01;              // Lot size (0.01 = 10 cents)
input int      OFIThreshold = 3;            // Buy/Sell ratio threshold (3x)
input int      LookbackTicks = 50;          // Number of ticks to analyze
input int      TakeProfitPips = 10;         // Take profit in pips
input int      StopLossPips = 8;            // Stop loss in pips
input int      MaxSpreadPips = 3;           // Max spread to trade
input int      CooldownSeconds = 3;         // Cooldown after trade
input int      MaxDailyTrades = 100;        // Max trades per day

//+------------------------------------------------------------------|
//| Structures                                                       |
//+------------------------------------------------------------------|
struct TickData {
   datetime time;
   double   price;
   bool     isBuy;
   long     volume;                         // Changed to long for tick_volume
};

//+------------------------------------------------------------------|
//| Global Variables                                                 |
//+------------------------------------------------------------------|
TickData tickBuffer[];
int      tickCount = 0;
datetime lastTradeTime = 0;
int      dailyTrades = 0;
int      lastTradeDay = 0;
double   initialBalance = 0;

//+------------------------------------------------------------------|
//| Expert initialization function                                   |
//+------------------------------------------------------------------|
int OnInit() {
   Print("========================================");
   Print("💎 OFI TICK BOT INITIALIZED");
   Print("   Lot: ", LotSize, " | TP: ", TakeProfitPips, " | SL: ", StopLossPips);
   Print("========================================");
   
   ArrayResize(tickBuffer, LookbackTicks);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastTradeDay = TimeDay(TimeCurrent());
   
   EventSetTimer(30);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------|
//| Expert tick function                                             |
//+------------------------------------------------------------------|
void OnTick() {
   // Daily reset
   if (TimeDay(TimeCurrent()) != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = TimeDay(TimeCurrent());
   }
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
   // Determine if tick is buyer or seller aggressive
   bool isBuyTick = false;
   double tickPrice = currentTick.last;
   
   if (currentTick.last >= currentTick.ask) {
      isBuyTick = true;
   }
   else if (currentTick.last <= currentTick.bid) {
      isBuyTick = false;
   }
   else {
      static double lastPrice = 0;
      isBuyTick = (currentTick.last > lastPrice);
      lastPrice = currentTick.last;
   }
   
   // Fill buffer
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = currentTick.time;
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].isBuy = isBuyTick;
   tickBuffer[idx].volume = currentTick.tick_volume;  // Use .tick_volume
   
   tickCount++;
   if (tickCount < LookbackTicks) return;
   
   // Calculate OFI every 5 ticks
   static int ticksSinceCalc = 0;
   ticksSinceCalc++;
   if (ticksSinceCalc < 5) return;
   ticksSinceCalc = 0;
   
   double ofiRatio = CalculateOFI();
   
   if (ofiRatio >= OFIThreshold) {
      CheckAndExecuteTrade("BUY", ofiRatio);
   }
   else if (ofiRatio <= 1.0 / (double)OFIThreshold) {
      CheckAndExecuteTrade("SELL", ofiRatio);
   }
}

//+------------------------------------------------------------------|
//| Calculate Order Flow Imbalance                                   |
//+------------------------------------------------------------------|
double CalculateOFI() {
   int buyTicks = 0;
   int sellTicks = 0;
   
   for (int i = 0; i < LookbackTicks; i++) {
      if (tickBuffer[i].isBuy) buyTicks++;
      else sellTicks++;
   }
   
   if (sellTicks == 0) return (buyTicks > 0) ? 99.0 : 1.0;
   return (double)buyTicks / (double)sellTicks;
}

//+------------------------------------------------------------------|
//| Get current spread in pips                                       |
//+------------------------------------------------------------------|
double GetSpreadPips() {
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0;
}

//+------------------------------------------------------------------|
//| Check and execute trade                                          |
//+------------------------------------------------------------------|
void CheckAndExecuteTrade(string action, double ofiRatio) {
   // Daily limit check
   if (dailyTrades >= MaxDailyTrades) return;
   
   // Cooldown check
   if (TimeCurrent() - lastTradeTime < CooldownSeconds) return;
   
   // Spread check
   if (GetSpreadPips() > MaxSpreadPips) return;
   
   // Position already open
   if (PositionSelect(_Symbol)) return;
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
   double price, tp, sl;
   int orderType;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipMultiplier = 10.0;
   
   if (action == "BUY") {
      price = currentTick.ask;
      tp = price + TakeProfitPips * point * pipMultiplier;
      sl = price - StopLossPips * point * pipMultiplier;
      orderType = ORDER_TYPE_BUY;
   } else {
      price = currentTick.bid;
      tp = price - TakeProfitPips * point * pipMultiplier;
      sl = price + StopLossPips * point * pipMultiplier;
      orderType = ORDER_TYPE_SELL;
   }
   
   // Dynamic lot sizing
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskPercent = 2.0;
   double riskAmount = balance * (riskPercent / 100.0);
   double pipValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double stopLossValue = StopLossPips * pipValue;
   double calculatedLot = riskAmount / stopLossValue;
   double finalLot = MathMax(LotSize, MathMin(calculatedLot, 0.10));
   finalLot = NormalizeDouble(finalLot, 2);
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = finalLot;
   request.type = orderType;
   request.price = price;
   request.sl = sl;
   request.tp = tp;
   request.deviation = 10;
   request.magic = 2026;
   request.comment = StringFormat("OFI_%.1fx", ofiRatio);
   request.type_filling = ORDER_FILLING_IOC;
   request.type_time = ORDER_TIME_GTC;
   
   if (OrderSend(request, result)) {
      if (result.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         Print("✅ ", action, " | OFI: ", ofiRatio, "x | Entry: ", price);
      }
   }
}

//+------------------------------------------------------------------|
//| Timer function for status updates                                |
//+------------------------------------------------------------------|
void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = balance - initialBalance;
   double roi = (profit / initialBalance) * 100;
   Print("📊 Balance: $", balance, " | Profit: $", profit, " | ROI: ", roi, "% | Trades: ", dailyTrades);
}

//+------------------------------------------------------------------|
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------|
void OnDeinit(const int reason) {
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("========================================");
   Print("🔴 OFI BOT SHUTDOWN");
   Print("   Final Balance: $", finalBalance);
   Print("   Total Profit: $", finalBalance - initialBalance);
   Print("========================================");
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 5. Create Entrypoint Script (FIXED)
# ============================================
RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash

echo "=========================================="
echo "💎 MT5 + MQL5 OFI BOT - RAILWAY READY"
echo "=========================================="

# Cleanup
rm -f /tmp/.X1-lock

# Start X server
echo "Starting virtual display..."
Xvfb :1 -screen 0 1280x800x16 &
sleep 2

# Start window manager and VNC
echo "Starting window manager..."
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

# Initialize Wine
echo "Initializing Wine..."
wineboot --init
sleep 5

# Find or install MT5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"

if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5 for first time..."
    wine /root/mt5setup.exe &
    echo "Waiting for installation (60 seconds)..."
    sleep 60
fi

# Start MT5 briefly to generate data folder
echo "Starting MT5 to generate profile..."
export DISPLAY=:1
wine "$MT5_EXE" &
echo "Waiting for MT5 to initialize (30 seconds)..."
sleep 30

# Kill MT5 to free resources for compilation
echo "Stopping MT5 for compilation..."
pkill -9 terminal64.exe 2>/dev/null || true
sleep 5

# Locate the REAL MQL5 Experts folder
echo "Locating MQL5 data directory..."
DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "MQL5" -type d 2>/dev/null | head -n 1)

if [ -z "$DATA_DIR" ]; then
    echo "AppData folder not found, using fallback location..."
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

EXPERT_PATH="$DATA_DIR/Experts/OFI_Tick_Bot.mq5"
mkdir -p "$DATA_DIR/Experts"

# Copy and compile the bot
echo "Installing bot to: $EXPERT_PATH"
cp /root/OFI_Tick_Bot.mq5 "$EXPERT_PATH"

echo "Compiling bot with MetaEditor..."
wine "$EDITOR_EXE" /compile:"$EXPERT_PATH" /log:"/root/compile.log" 2>&1

echo "Compilation log:"
cat /root/compile.log 2>/dev/null || echo "No compile log found (compilation may have succeeded silently)"

# Restart MT5
echo "Restarting MT5..."
wine "$MT5_EXE" &

# Start mt5linux bridge (optional)
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "=========================================="
echo "✅ SETUP COMPLETE"
echo "=========================================="
echo "📍 Bot installed at: $EXPERT_PATH"
echo "📍 Compiled to: ${EXPERT_PATH/.mq5/.ex5}"
echo ""
echo "📌 HOW TO USE:"
echo "   1. Open noVNC in your browser"
echo "   2. Login to Valetutax account"
echo "   3. Press Ctrl+N to open Navigator"
echo "   4. Right-click 'Expert Advisors' → Refresh"
echo "   5. Find 'OFI_Tick_Bot' and drag to chart"
echo "   6. Enable Auto-Trading (top toolbar)"
echo "=========================================="

# Keep container alive
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

# ============================================
# 6. Expose ports
# ============================================
EXPOSE 8080 8001

# ============================================
# 7. Entrypoint
# ============================================
CMD ["/bin/bash", "/entrypoint.sh"]
