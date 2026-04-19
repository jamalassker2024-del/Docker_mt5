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
# 4. Create MQL5 Bot Code
# ============================================
RUN cat << 'EOF' > /root/OFI_Tick_Bot.mq5
//+------------------------------------------------------------------+
//|                                                  OFI_Tick_Bot.mq5 |
//|                                    Order Flow Imbalance Scalper   |
//+------------------------------------------------------------------+
#property copyright "OFI Bot"
#property version   "1.00"
#property strict

input double   LotSize = 0.01;
input int      OFIThreshold = 3;
input int      LookbackTicks = 50;
input int      TakeProfitPips = 10;
input int      StopLossPips = 8;
input int      MaxSpreadPips = 3;
input int      CooldownSeconds = 3;
input int      MaxDailyTrades = 100;

struct TickData {
   datetime time;
   double   price;
   bool     isBuy;
   int      volume;
};

TickData tickBuffer[];
int      tickCount = 0;
datetime lastTradeTime = 0;
int      dailyTrades = 0;
int      lastTradeDay = 0;
double   initialBalance = 0;

int OnInit() {
   Print("========================================");
   Print("💎 OFI TICK BOT INITIALIZED");
   Print("   Lot: ", LotSize, " | TP: ", TakeProfitPips, " | SL: ", StopLossPips);
   Print("========================================");
   ArrayResize(tickBuffer, LookbackTicks);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastTradeDay = Day();
   EventSetTimer(30);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   if (Day() != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = Day();
   }
   
   MqlTick currentTick;
   SymbolInfoTick(_Symbol, currentTick);
   
   bool isBuyTick = false;
   double tickPrice = 0;
   
   if (currentTick.ask == currentTick.last) {
      isBuyTick = true;
      tickPrice = currentTick.ask;
   }
   else if (currentTick.bid == currentTick.last) {
      isBuyTick = false;
      tickPrice = currentTick.bid;
   }
   else {
      static double lastPrice = 0;
      tickPrice = currentTick.last;
      isBuyTick = (tickPrice > lastPrice);
      lastPrice = tickPrice;
   }
   
   tickBuffer[tickCount % LookbackTicks] = {
      TimeCurrent(), tickPrice, isBuyTick, (int)currentTick.volume
   };
   tickCount++;
   
   if (tickCount < LookbackTicks) return;
   
   static int ticksSinceCalc = 0;
   ticksSinceCalc++;
   if (ticksSinceCalc < 5) return;
   ticksSinceCalc = 0;
   
   double ofiRatio = CalculateOFI();
   
   if (ofiRatio >= OFIThreshold) {
      CheckAndExecuteTrade("BUY", ofiRatio);
   }
   else if (ofiRatio <= 1.0 / OFIThreshold) {
      CheckAndExecuteTrade("SELL", ofiRatio);
   }
}

double CalculateOFI() {
   int buyTicks = 0, sellTicks = 0;
   for (int i = 0; i < LookbackTicks; i++) {
      int idx = (tickCount - LookbackTicks + i) % LookbackTicks;
      if (tickBuffer[idx].isBuy) buyTicks++;
      else sellTicks++;
   }
   if (sellTicks == 0) return (buyTicks > 0) ? 999.0 : 1.0;
   return (double)buyTicks / (double)sellTicks;
}

double GetSpreadPips() {
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0;
}

void CheckAndExecuteTrade(string action, double ofiRatio) {
   if (dailyTrades >= MaxDailyTrades) return;
   if (TimeCurrent() - lastTradeTime < CooldownSeconds) return;
   if (GetSpreadPips() > MaxSpreadPips) return;
   if (PositionSelect(_Symbol)) return;
   
   MqlTick currentTick;
   SymbolInfoTick(_Symbol, currentTick);
   
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

void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = balance - initialBalance;
   Print("📊 Balance: $", balance, " | Profit: $", profit, " | Trades: ", dailyTrades);
}

void OnDeinit(const int reason) {
   Print("🔴 OFI BOT SHUTDOWN | Final Balance: $", AccountInfoDouble(ACCOUNT_BALANCE));
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 5. Create Complete Entrypoint Script (FIXED PATHS)
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

# Start MT5 to generate data folder
echo "Starting MT5 to generate profile..."
wine "$MT5_EXE" &
sleep 30

# Locate the REAL MQL5 Experts folder (AppData, not Program Files)
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
wine "$EDITOR_EXE" /compile:"$EXPERT_PATH" /log:"/root/compile.log"

echo "Compilation log:"
cat /root/compile.log 2>/dev/null || echo "No compile log found"

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
