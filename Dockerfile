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
# 4. FIXED EA FOR VALETAX .vx SYMBOLS - GUARANTEED TRADES
# ============================================
RUN cat << 'EOF' > /root/FAST_OFI_BOT.mq5
//+------------------------------------------------------------------+
//|                                          FAST_OFI_VALETAX_FIX.mq5|
//|                                FIXED for .vx symbols - V6.0      |
//+------------------------------------------------------------------+
#property strict
#property version "6.0"

input double   LotSize = 0.01;
input double   Threshold = 1.3;
input int      TP = 1000;              // 🔥 FIXED: Points, not pips (1000 points = 10 pips for crypto)
input int      SL = 800;               // 🔥 FIXED: Points, not pips
input double   MaxSpreadPoints = 500;  // 🔥 FIXED: Raw points, not calculated pips
input int      Cooldown = 0;
input int      MaxTrades = 1000;

datetime lastTrade = 0;
int trades = 0;
int lastTradeDay = 0;
double initialBalance = 0;
bool debugSpreadReported = false;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   EventSetTimer(1);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   lastTradeDay = dt.day;
   
   Print("╔═══════════════════════════════════════════╗");
   Print("║   🚀 FAST OFI v6.0 - VALETAX .vx FIX      ║");
   Print("║   Symbol: ", _Symbol);
   Print("║   Point size: ", SymbolInfoDouble(_Symbol, SYMBOL_POINT));
   Print("║   Spread (raw): ", SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));
   Print("║   MaxSpreadPoints: ", MaxSpreadPoints);
   Print("║   TP/SL: ", TP, "/", SL, " POINTS");
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
         buyVol += (double)r[i].tick_volume * 0.5;
         sellVol += (double)r[i].tick_volume * 0.5;
      }
   }
   
   if(sellVol < 1.0) sellVol = 1.0;
   return buyVol / sellVol;
}

//+------------------------------------------------------------------+
//| Get raw spread (points, not calculated pips)                     |
//+------------------------------------------------------------------+
long GetRawSpread() {
   return SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
}

//+------------------------------------------------------------------+
//| Execute trade - FIXED for .vx symbols                            |
//+------------------------------------------------------------------+
void Trade(bool buy, double ofi) {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t)) {
      Print("❌ Failed to get tick data");
      return;
   }
   
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // 🔥 CRITICAL FIX: TP and SL are already in POINTS, not pips
   // Just multiply by point to get price difference
   double price = buy ? t.ask : t.bid;
   double sl = buy ? price - SL * point : price + SL * point;
   double tp = buy ? price + TP * point : price - TP * point;
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   
   req.action = TRADE_ACTION_DEAL;
   req.symbol = _Symbol;
   req.volume = LotSize;
   req.type = buy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = price;
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 100;  // 🔥 INCREASED: Allow more slippage for Valetax
   req.magic = 666000;
   req.type_filling = ORDER_FILLING_IOC;
   req.type_time = ORDER_TIME_GTC;
   req.comment = "OFI_" + DoubleToString(ofi, 2) + "x";
   
   if(OrderSend(req, res)) {
      if(res.retcode == TRADE_RETCODE_DONE) {
         trades++;
         lastTrade = TimeCurrent();
         Print("⚡ TRADE EXECUTED! ", buy ? "BUY" : "SELL", 
               " | OFI: ", DoubleToString(ofi, 2), 
               "x | Price: ", price,
               " | Trades: ", trades);
      } else {
         Print("⚠️ Order retcode: ", res.retcode, " - ", GetRetcodeText(res.retcode));
      }
   } else {
      int err = GetLastError();
      Print("❌ OrderSend failed. Error: ", err);
   }
}

//+------------------------------------------------------------------+
//| Get retcode text for debugging                                   |
//+------------------------------------------------------------------+
string GetRetcodeText(int code) {
   switch(code) {
      case 10004: return "Requote";
      case 10006: return "Order rejected";
      case 10007: return "Canceled by dealer";
      case 10008: return "Order placed";
      case 10009: return "Done";
      case 10010: return "Partial fill";
      case 10011: return "Rejected";
      case 10012: return "Canceled";
      case 10013: return "Invalid request";
      default: return "Unknown";
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
   
   // 🔥 FIXED: Compare raw spread (points) to MaxSpreadPoints
   long rawSpread = GetRawSpread();
   if(rawSpread > (long)MaxSpreadPoints) {
      // Only report once to avoid spam
      if(!debugSpreadReported) {
         Print("⏸️ Spread too high: ", rawSpread, " > ", MaxSpreadPoints, " (waiting...)");
         debugSpreadReported = true;
      }
      return;
   }
   debugSpreadReported = false;
   
   // Calculate OFI and execute
   double ofi = OFI();
   
   if(ofi >= Threshold) {
      Print("🔔 BUY SIGNAL | OFI: ", ofi, "x | Spread: ", rawSpread, " points");
      Trade(true, ofi);
   } else if(ofi <= 1.0 / Threshold) {
      Print("🔔 SELL SIGNAL | OFI: ", 1.0/ofi, "x | Spread: ", rawSpread, " points");
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
//| Timer handler - Backup trigger                                   |
//+------------------------------------------------------------------+
void OnTimer() {
   Process();
   
   // Status report
   static int counter = 0;
   counter++;
   if(counter >= 30) {  // Every 30 seconds
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      long spread = GetRawSpread();
      double ofi = OFI();
      
      Print("📊 BAL: $", DoubleToString(balance, 2),
            " | P/L: $", DoubleToString(profit, 2),
            " | Trades: ", trades,
            " | OFI: ", DoubleToString(ofi, 2), "x",
            " | Spread: ", spread, " pts",
            " | ", (spread <= MaxSpreadPoints ? "✅ READY" : "⏸️ WAITING"));
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
cp /root/FAST_OFI_BOT.mq5 "$DATA_DIR/Experts/FAST_OFI_BOT.mq5"

echo "🔧 Compiling..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/FAST_OFI_BOT.mq5" /log:"/root/compile.log" 2>&1

if [ -f "/root/compile.log" ]; then
    if grep -q "0 error(s)" /root/compile.log; then
        echo "✅ Compilation SUCCESS"
    else
        echo "⚠️ Compilation output:"
        cat /root/compile.log
    fi
fi

echo "🌉 Starting MT5-Linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "💓 Starting 5-second stimulation..."
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 5
done &

echo "╔═══════════════════════════════════════════╗"
echo "║   🚀 FIXED BOT FOR VALETAX .vx RUNNING    ║"
echo "╚═══════════════════════════════════════════╝"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
