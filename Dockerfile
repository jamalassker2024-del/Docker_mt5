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
//|                                              For Valetutax Cent   |
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
//| Global Variables                                                 |
//+------------------------------------------------------------------|
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

//+------------------------------------------------------------------|
//| Expert initialization function                                   |
//+------------------------------------------------------------------|
int OnInit() {
   Print("========================================");
   Print("💎 OFI TICK BOT INITIALIZED");
   Print("========================================");
   Print("   Lot Size: ", LotSize);
   Print("   OFI Threshold: ", OFIThreshold, "x");
   Print("   TP: ", TakeProfitPips, " pips | SL: ", StopLossPips, " pips");
   Print("   Lookback Ticks: ", LookbackTicks);
   Print("========================================");
   
   ArrayResize(tickBuffer, LookbackTicks);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("💰 Initial Balance: $", initialBalance);
   lastTradeDay = Day();
   
   // Set timer for status updates every 30 seconds
   EventSetTimer(30);
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------|
//| Expert tick function                                             |
//+------------------------------------------------------------------|
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

//+------------------------------------------------------------------|
//| Calculate Order Flow Imbalance                                   |
//+------------------------------------------------------------------|
double CalculateOFI() {
   int buyTicks = 0;
   int sellTicks = 0;
   
   for (int i = 0; i < LookbackTicks; i++) {
      int idx = (tickCount - LookbackTicks + i) % LookbackTicks;
      if (tickBuffer[idx].isBuy) buyTicks++;
      else sellTicks++;
   }
   
   if (sellTicks == 0) return (buyTicks > 0) ? 999.0 : 1.0;
   return (double)buyTicks / (double)sellTicks;
}

//+------------------------------------------------------------------|
//| Get current spread in pips                                       |
//+------------------------------------------------------------------|
double GetSpreadPips() {
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0;
}

//+------------------------------------------------------------------|
//| Check and execute trade                                          |
//+------------------------------------------------------------------|
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

//+------------------------------------------------------------------|
//| Timer function                                                   |
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
//+------------------------------------------------------------------|
EOF

# ============================================
# 5. Create Complete Entrypoint Script
# ============================================
RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash

set -e

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

# Find and start MT5
MT5_1="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
MT5_2="/root/.wine/drive_c/Program Files (x86)/MetaTrader 5/terminal64.exe"

if [ -f "$MT5_1" ]; then
    echo "Starting MT5 (64bit)"
    wine "$MT5_1" &
    MT5_PATH="$MT5_1"
elif [ -f "$MT5_2" ]; then
    echo "Starting MT5 (x86)"
    wine "$MT5_2" &
    MT5_PATH="$MT5_2"
else
    echo "Installing MT5 for first time..."
    wine /root/mt5setup.exe &
    sleep 30
    if [ -f "$MT5_1" ]; then
        MT5_PATH="$MT5_1"
        wine "$MT5_1" &
    elif [ -f "$MT5_2" ]; then
        MT5_PATH="$MT5_2"
        wine "$MT5_2" &
    fi
fi

echo "Waiting for MT5 to load..."
sleep 30

# Install MQL5 bot
echo "Installing MQL5 bot..."
MT5_DIR=$(dirname "$MT5_PATH")
MQL5_DIR="$MT5_DIR/MQL5/Experts"
mkdir -p "$MQL5_DIR"
cp /root/OFI_Tick_Bot.mq5 "$MQL5_DIR/OFI_Tick_Bot.mq5"
echo "✅ Bot installed as 'OFI_Tick_Bot'"

# Start bridge (optional)
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "=========================================="
echo "✅ MT5 is running with OFI Bot"
echo "🌐 Open: https://your-app.up.railway.app:8080/vnc.html"
echo "=========================================="
echo ""
echo "📌 MANUAL STEPS:"
echo "   1. Login to Valetutax account"
echo "   2. Open Navigator (Ctrl+N)"
echo "   3. Find 'OFI_Tick_Bot' under Expert Advisors"
echo "   4. Drag it to any chart"
echo "   5. Enable Auto-Trading"
echo ""

# Keep alive
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
