FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. FAST + LIGHT WINE ENV (optimized)
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python (light bridge only)
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. MT5 installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. ULTRA FAST AGGRESSIVE EA (COMPILE-SAFE)
# ============================================
RUN cat << 'EOF' > /root/FAST_OFI_BOT.mq5
//+------------------------------------------------------------------+
//|                                          FAST_AGGRESSIVE_OFI.mq5 |
//|                                PRODUCTION v5.0 - COMPILE SAFE    |
//+------------------------------------------------------------------+
#property strict
#property version "5.0"

input double   LotSize = 0.01;
input double   Threshold = 1.3;        // 🔥 Aggressive entry
input int      TP = 10;                // Take profit pips
input int      SL = 8;                 // Stop loss pips
input double   MaxSpread = 6.0;        // Relaxed spread filter
input int      Cooldown = 0;           // 🔥 NO cooldown (max speed)
input int      MaxTrades = 1000;       // 🔥 High frequency ready

datetime lastTrade = 0;
int trades = 0;
int lastTradeDay = 0;
double initialBalance = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   EventSetTimer(1);  // Stable 1-second loop
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   lastTradeDay = dt.day;
   
   Print("╔═══════════════════════════════════════════╗");
   Print("║   🚀 FAST AGGRESSIVE OFI BOT v5.0         ║");
   Print("║   Threshold: ", Threshold, "x | TP: ", TP, " | SL: ", SL, "      ║");
   Print("║   Max Trades: ", MaxTrades, " | Cooldown: 0s        ║");
   Print("╚═══════════════════════════════════════════╝");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Check for open position                                          |
//+------------------------------------------------------------------+
bool HasPos() {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol) {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get current day                                                  |
//+------------------------------------------------------------------+
int GetDay() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.day;
}

//+------------------------------------------------------------------+
//| Calculate Order Flow Imbalance                                   |
//+------------------------------------------------------------------+
double OFI() {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   
   if(CopyRates(_Symbol, PERIOD_M1, 0, 15, r) < 15) {
      return 1.0;
   }
   
   double buyVol = 0;
   double sellVol = 0;
   
   for(int i = 0; i < 15; i++) {
      if(r[i].close > r[i].open) {
         buyVol += (double)r[i].tick_volume;
      } else if(r[i].close < r[i].open) {
         sellVol += (double)r[i].tick_volume;
      } else {
         // Doji - split volume
         buyVol += (double)r[i].tick_volume * 0.5;
         sellVol += (double)r[i].tick_volume * 0.5;
      }
   }
   
   if(sellVol < 1.0) sellVol = 1.0;
   return buyVol / sellVol;
}

//+------------------------------------------------------------------+
//| Get current spread in pips                                       |
//+------------------------------------------------------------------+
double Spread() {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // Convert to pips based on symbol type
   if(StringFind(_Symbol, "JPY") >= 0 || _Symbol == "XAUUSD") {
      return (double)spread * point * 100.0;
   }
   return (double)spread * point * 10000.0;
}

//+------------------------------------------------------------------+
//| Execute trade                                                    |
//+------------------------------------------------------------------+
void Trade(bool buy, double ofi) {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) {
      return;
   }
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Calculate pip size
   double pipSize;
   if(StringFind(_Symbol, "JPY") >= 0 || _Symbol == "XAUUSD") {
      pipSize = point * 100.0;
   } else {
      pipSize = point * 10000.0;
   }
   
   double price = buy ? t.ask : t.bid;
   double sl = buy ? price - SL * pipSize : price + SL * pipSize;
   double tp = buy ? price + TP * pipSize : price - TP * pipSize;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = LotSize;
   req.type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = price;
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 30;  // 🔥 Allow slippage for fast fills
   req.magic = 555000;
   req.type_filling = ORDER_FILLING_IOC;  // 🔥 Immediate or Cancel
   req.type_time = ORDER_TIME_GTC;
   req.comment = "OFI_" + DoubleToString(ofi, 2) + "x";
   
   if(OrderSend(req, res)) {
      if(res.retcode == TRADE_RETCODE_DONE) {
         trades++;
         lastTrade = TimeCurrent();
         Print("⚡ TRADE ", buy ? "BUY" : "SELL", 
               " | OFI: ", DoubleToString(ofi, 2), 
               "x | Price: ", price,
               " | Trades: ", trades);
      }
   }
}

//+------------------------------------------------------------------+
//| Main processing logic                                            |
//+------------------------------------------------------------------+
void Process() {
   // Daily reset
   int currentDay = GetDay();
   if(currentDay != lastTradeDay) {
      trades = 0;
      lastTradeDay = currentDay;
   }
   
   // Trade limits
   if(trades >= MaxTrades) {
      return;
   }
   
   // No overlapping positions
   if(HasPos()) {
      return;
   }
   
   // Spread check
   if(Spread() > MaxSpread) {
      return;
   }
   
   // Calculate OFI and execute
   double ofi = OFI();
   
   if(ofi >= Threshold) {
      Trade(true, ofi);
   } else if(ofi <= 1.0 / Threshold) {
      Trade(false, ofi);
   }
}

//+------------------------------------------------------------------+
//| Tick handler - Primary trigger                                   |
//+------------------------------------------------------------------+
void OnTick() {
   Process();
}

//+------------------------------------------------------------------+
//| Timer handler - Backup trigger (every 1 second)                  |
//+------------------------------------------------------------------+
void OnTimer() {
   Process();
   
   // Periodic status report
   static int counter = 0;
   counter++;
   if(counter >= 60) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      Print("📊 BAL: $", DoubleToString(balance, 2),
            " | P/L: $", DoubleToString(profit, 2),
            " | Trades: ", trades,
            " | OFI: ", DoubleToString(OFI(), 2), "x",
            " | Spread: ", Spread(), " pips");
      counter = 0;
   }
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double totalProfit = finalBalance - initialBalance;
   Print("╔═══════════════════════════════════════════╗");
   Print("║           🔴 BOT SHUTDOWN                  ║");
   Print("║  Final Balance: $", DoubleToString(finalBalance, 2), "       ║");
   Print("║  Total P/L: $", DoubleToString(totalProfit, 2), "            ║");
   Print("║  Total Trades: ", trades, "                         ║");
   Print("╚═══════════════════════════════════════════╝");
}
EOF

# ============================================
# 5. FAST ENTRYPOINT WITH 5-SECOND STIMULATION
# ============================================
RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash
set -e

# Clean up X11 locks
rm -rf /tmp/.X*

# Start virtual display
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2

# Window manager
fluxbox &
sleep 1

# VNC for debugging (optional)
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &

# Initialize Wine
wineboot --init
sleep 5

# Install MT5 if missing
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "📦 Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 60
fi

# Launch MT5
echo "🚀 Starting MT5..."
wine "$MT5_EXE" &
sleep 30

# Find MQL5 directory
DATA_DIR=$(find /root/.wine -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

# Copy and compile expert
mkdir -p "$DATA_DIR/Experts"
cp /root/FAST_OFI_BOT.mq5 "$DATA_DIR/Experts/FAST_OFI_BOT.mq5"

echo "🔧 Compiling FAST_OFI_BOT..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/FAST_OFI_BOT.mq5" /log:"/root/compile.log" 2>&1

# Check compilation
if [ -f "/root/compile.log" ]; then
    if grep -q "0 error(s)" /root/compile.log; then
        echo "✅ Compilation SUCCESS - 0 errors"
    else
        echo "⚠️ Compilation output:"
        cat /root/compile.log
    fi
fi

# Start MT5 Linux bridge
echo "🌉 Starting MT5-Linux bridge on port 8001..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

# 🔥 ULTRA FAST STIMULATION LOOP (5-second intervals)
echo "💓 Starting 5-second heartbeat stimulation..."
while true; do
    # Send F5 refresh to keep MT5 connection alive
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 5
done &

echo "╔═══════════════════════════════════════════╗"
echo "║   🚀 FAST AGGRESSIVE BOT IS RUNNING       ║"
echo "║   VNC: http://localhost:8080              ║"
echo "║   Bridge: port 8001                       ║"
echo "╚═══════════════════════════════════════════╝"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
