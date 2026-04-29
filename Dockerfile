# Working VALETAX_PROFIT_MAXIMIZER - FULLY FIXED
ARG CACHE_BUST=13

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
# 4. Create VALETAX PROFIT MAXIMIZER EA
# ============================================
RUN cat > /root/VALETAX_PROFIT_BOT.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                    VALETAX_PROFIT_MAXIMIZER.mq5 |
//|                    FULLY FIXED - 0 ERRORS 0 WARNINGS - V10.0    |
//+------------------------------------------------------------------+
#property strict
#property version "10.0"

// ============================================
// AGGRESSIVE PROFIT SETTINGS
// ============================================
input double   LotSize = 0.02;
input double   OFI_Threshold = 1.15;
input int      Lookback_Bars = 10;
input int      TakeProfit_Points = 1500;
input int      StopLoss_Points = 600;
input double   MaxSpread_Points = 800;
input int      Cooldown_Seconds = 0;
input int      MaxDaily_Trades = 2000;
input bool     TradeOnWeekend = true;
input int      MagicNumber = 999000;

// Supported symbols
string Symbols[] = {
   "BTCUSD.vx",
   "ETHUSD.vx",
   "DOGEUSD.vx",
   "LTCUSD.vx",
   "XRPUSD.vx",
   "BCHUSD.vx",
   "BTCEUR.vx"
};

datetime lastTradeTime = 0;
int totalTrades = 0;
int dailyTrades = 0;
int lastTradeDay = 0;
double initialBalance = 0;
double maxDrawdown = 0;
double peakBalance = 0;
bool isInitialized = false;
int cachedFillingMode[7];
bool cacheInitialized[7];

int GetSupportedFillingMode(string sym) {
   long fillingFlags = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fillingFlags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   else if((fillingFlags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

int OnInit() {
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakBalance = initialBalance;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   lastTradeDay = dt.day_of_year;
   isInitialized = true;
   EventSetTimer(1);
   
   Print("========================================");
   Print("  VALETAX PROFIT MAXIMIZER v10.0        ");
   Print("========================================");
   Print("  OFI Threshold: ", OFI_Threshold, "x");
   Print("  TP: ", TakeProfit_Points, " pts | SL: ", StopLoss_Points, " pts");
   Print("  Lot Size: ", LotSize);
   Print("========================================");
   return(INIT_SUCCEEDED);
}

bool HasPosition(string sym) {
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == sym) return true;
      }
   }
   return false;
}

int CountOpenPositions() {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         string sym = PositionGetString(POSITION_SYMBOL);
         for(int j = 0; j < ArraySize(Symbols); j++) {
            if(sym == Symbols[j]) { count++; break; }
         }
      }
   }
   return count;
}

int GetDayOfYear() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_year;
}

bool IsWeekend() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
}

double CalculateOFI(string sym) {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(sym, PERIOD_M1, 0, Lookback_Bars, r) < Lookback_Bars) return 1.0;
   
   double buyVol = 0, sellVol = 0;
   for(int i = 0; i < Lookback_Bars; i++) {
      double volume = (double)r[i].tick_volume;
      if(r[i].close > r[i].open) buyVol += volume;
      else if(r[i].close < r[i].open) sellVol += volume;
      else {
         if(i > 0 && r[i].close >= r[i-1].close) { buyVol += volume * 0.7; sellVol += volume * 0.3; }
         else { buyVol += volume * 0.3; sellVol += volume * 0.7; }
      }
   }
   if(sellVol < 1.0) sellVol = 1.0;
   return buyVol / sellVol;
}

long GetSpread(string sym) { return SymbolInfoInteger(sym, SYMBOL_SPREAD); }

void ExecuteTrade(string sym, bool isBuy, double ofi) {
   MqlTick t;
   if(!SymbolInfoTick(sym, t)) return;
   
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   double price = isBuy ? t.ask : t.bid;
   double sl = isBuy ? price - StopLoss_Points * point : price + StopLoss_Points * point;
   double tp = isBuy ? price + TakeProfit_Points * point : price - TakeProfit_Points * point;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   req.action = TRADE_ACTION_DEAL;
   req.symbol = sym;
   req.volume = LotSize;
   req.type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = NormalizeDouble(price, digits);
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 150;
   req.magic = MagicNumber;
   req.type_filling = ORDER_FILLING_RETURN;
   req.type_time = ORDER_TIME_GTC;
   req.comment = "OFI" + DoubleToString(ofi, 2);
   
   if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) {
      totalTrades++; dailyTrades++; lastTradeTime = TimeCurrent();
      Print(" TRADE EXECUTED! ", isBuy ? "BUY" : "SELL", " ", sym, " OFI=", DoubleToString(ofi, 2), "x Price=", price);
   }
}

void ProcessSymbol(string sym) {
   if(HasPosition(sym)) return;
   if(GetSpread(sym) > (long)MaxSpread_Points) return;
   if(!TradeOnWeekend && IsWeekend()) return;
   double ofi = CalculateOFI(sym);
   if(ofi >= OFI_Threshold) ExecuteTrade(sym, true, ofi);
   else if(ofi <= 1.0 / OFI_Threshold) ExecuteTrade(sym, false, ofi);
}

void ProcessAllSymbols() {
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) { dailyTrades = 0; lastTradeDay = currentDay; }
   if(dailyTrades >= MaxDaily_Trades) return;
   if(Cooldown_Seconds > 0 && TimeCurrent() - lastTradeTime < Cooldown_Seconds) return;
   for(int i = 0; i < ArraySize(Symbols); i++) ProcessSymbol(Symbols[i]);
}

void UpdateBalanceMetrics() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > peakBalance) peakBalance = balance;
   double currentDD = (peakBalance - balance) / peakBalance * 100;
   if(currentDD > maxDrawdown) maxDrawdown = currentDD;
}

void OnTick() { if(isInitialized) ProcessAllSymbols(); }

void OnTimer() {
   if(!isInitialized) return;
   ProcessAllSymbols();
   UpdateBalanceMetrics();
   static int counter = 0;
   counter++;
   if(counter >= 30) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      Print("========== STATUS ==========");
      Print(" Balance: $", DoubleToString(balance, 2), " | Profit: $", DoubleToString(profit, 2));
      Print(" Daily: ", dailyTrades, " | Total: ", totalTrades);
      Print("============================");
      counter = 0;
   }
}

void OnDeinit(const int reason) { EventKillTimer(); }
EOF

# ============================================
# 5. Entrypoint Script - FULLY FIXED
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "VALETAX PROFIT MAXIMIZER v10.0"
echo "=========================================="

# Cleanup
rm -rf /tmp/.X*

# Start Xvfb
Xvfb :1 -screen 0 1280x800x24 -ac -nolisten tcp &
sleep 3

# Start fluxbox
fluxbox -display :1 &
sleep 2

# Start x11vnc with stability fixes (prevents crash)
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 -noxdamage -noxfixes -bg &
sleep 2

# Start websockify on all interfaces
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

# Start MT5 and wait for full initialization
echo "Starting MT5..."
wine "$MT5_EXE" &
echo "Waiting for MT5 to fully initialize (60 seconds)..."
sleep 60

# ========== FIXED: Find REAL terminal directory (exclude Community) ==========
TERMINAL_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal -mindepth 1 -maxdepth 1 -type d ! -name "Community" 2>/dev/null | head -n 1)

if [ -z "$TERMINAL_DIR" ]; then
    echo "ERROR: Terminal directory not found!"
    exit 1
fi

DATA_DIR="$TERMINAL_DIR/MQL5"
echo "Using Terminal Dir: $TERMINAL_DIR"
echo "Using MQL5 Dir: $DATA_DIR"

# Create necessary directories
mkdir -p "$DATA_DIR/Experts"
mkdir -p "$DATA_DIR/Logs"
mkdir -p "$DATA_DIR/Files"

# Install EA
cp /root/VALETAX_PROFIT_BOT.mq5 "$DATA_DIR/Experts/VALETAX_PROFIT_BOT.mq5"

# Compile EA (order matters in Wine)
EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
echo "Compiling EA..."
wine "$EDITOR_EXE" /portable /compile:"$DATA_DIR/Experts/VALETAX_PROFIT_BOT.mq5" /log:"C:\\compile.log"
sleep 10

# VERIFY EX5 EXISTS
if [ -f "$DATA_DIR/Experts/VALETAX_PROFIT_BOT.ex5" ]; then
    echo "✅ EA compiled SUCCESSFULLY and is in correct folder"
else
    echo "❌ EA NOT FOUND after compile!"
    echo "Check compile log:"
    cat "$WINEPREFIX/drive_c/compile.log" 2>/dev/null || echo "No log file"
fi

# Force refresh Navigator
sleep 2
xdotool search --name "MetaTrader" key Ctrl+n 2>/dev/null || true

# Start mt5linux bridge
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

# Auto-refresh charts
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 5
done &

echo "=========================================="
echo "BOT READY!"
echo "VNC: https://your-app.up.railway.app:8080/vnc.html"
echo ""
echo "STEPS:"
echo "1. Open noVNC in browser"
echo "2. Login to Valetutax"
echo "3. Open Navigator (Ctrl+N)"
echo "4. Refresh Expert Advisors (Right-click->Refresh)"
echo "5. Drag VALETAX_PROFIT_BOT to chart"
echo "6. Enable Auto-Trading (Alt+T)"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
