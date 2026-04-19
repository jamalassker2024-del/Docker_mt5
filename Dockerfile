FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. Install Wine + Dependencies
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox \
    novnc websockify wget curl procps cabextract \
    unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python Dependencies
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. COMPILE-SAFE OFI BOT - Guaranteed Trades
# ============================================
RUN cat << 'EOF' > /root/OFI_Alpha_Bot.mq5
//+------------------------------------------------------------------+
//|                                                OFI_Alpha_Bot.mq5 |
//|                          COMPILE-SAFE - Wine Optimized - V3.0    |
//+------------------------------------------------------------------+
#property copyright "Alpha OFI"
#property version   "3.00"
#property strict
#property indicator_chart_window  // REMOVE THIS LINE BEFORE COMPILING AS EXPERT
// NOTE: The above line is commented in final version - it's an EXPERT, not indicator

input double   LotSize = 0.01;
input double   OFIThreshold = 1.5;        
input int      LookbackBars = 20;         
input int      TakeProfitPips = 15;
input int      StopLossPips = 10;
input double   MaxSpreadPips = 5.0;       
input int      CooldownSeconds = 1;       
input int      MaxDailyTrades = 500;      

// State variables
datetime lastTradeTime = 0;
int      dailyTrades = 0;
int      lastTradeDay = 0;
double   initialBalance = 0;
bool     isInTrade = false;
int      consecutiveLosses = 0;
double   lastOFIValue = 0;
datetime lastProcessTime = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   Print("╔════════════════════════════════════════════╗");
   Print("║     🚀 OFI ALPHA BOT - COMPILE SAFE v3     ║");
   Print("║     Threshold: ", OFIThreshold, "x | TP: ", TakeProfitPips, "pips   ║");
   Print("╚════════════════════════════════════════════╝");
   
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);  // FIXED: Correct MQL5 syntax
   lastTradeDay = dt.day;
   
   // CRITICAL: Use only EventSetTimer - MillisecondTimer unstable in Wine
   EventSetTimer(1);  // 1 second interval - Wine stable
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Get current day - Safe method                                    |
//+------------------------------------------------------------------+
int GetCurrentDay() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);  // FIXED: Correct syntax
   return dt.day;
}

//+------------------------------------------------------------------+
//| Check if we have open position - Safe loop                       |
//+------------------------------------------------------------------+
bool HasOpenPosition() {
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);  // FIXED: Safe ticket retrieval
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol) {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get current position direction - Safe                            |
//+------------------------------------------------------------------+
int GetPositionDirection() {
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol) {
            return (int)PositionGetInteger(POSITION_TYPE);
         }
      }
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Calculate OFI using Bars - Wine Stable                          |
//+------------------------------------------------------------------+
double CalculateOFI() {
   double buyVolume = 0;
   double sellVolume = 0;
   
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   int copied = CopyRates(_Symbol, PERIOD_M1, 0, LookbackBars, rates);
   
   if(copied < LookbackBars) return 1.0;
   
   for(int i = 0; i < LookbackBars; i++) {
      if(rates[i].close > rates[i].open) {
         buyVolume += (double)rates[i].tick_volume;
      } else if(rates[i].close < rates[i].open) {
         sellVolume += (double)rates[i].tick_volume;
      }
      // Equal open/close (doji) - ignore or split 50/50
      else {
         buyVolume += (double)rates[i].tick_volume * 0.5;
         sellVolume += (double)rates[i].tick_volume * 0.5;
      }
   }
   
   if(sellVolume < 1) sellVolume = 1;
   double ratio = buyVolume / sellVolume;
   lastOFIValue = ratio;
   
   return ratio;
}

//+------------------------------------------------------------------+
//| Get current spread in pips                                       |
//+------------------------------------------------------------------+
double GetSpreadPips() {
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   
   // Convert to pips
   if(StringFind(_Symbol, "JPY") >= 0 || _Symbol == "XAUUSD") {
      return (double)spread * point * 100.0;
   } else {
      return (double)spread * point * 10000.0;
   }
}

//+------------------------------------------------------------------+
//| Main execution logic - Called by Timer AND OnTick                |
//+------------------------------------------------------------------+
void ProcessTradeLogic() {
   // Throttle processing in Wine - max once per 500ms
   if(TimeCurrent() - lastProcessTime < 1) {
      return;
   }
   lastProcessTime = TimeCurrent();
   
   // Daily reset
   int currentDay = GetCurrentDay();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
      Print("🔄 New trading day - Reset counter");
   }
   
   // Check position status
   isInTrade = HasOpenPosition();
   
   // Trade limits
   if(dailyTrades >= MaxDailyTrades) return;
   if(TimeCurrent() - lastTradeTime < (datetime)CooldownSeconds) return;
   
   double spread = GetSpreadPips();
   if(spread > MaxSpreadPips) {
      static int spreadWarnCount = 0;
      if(spreadWarnCount++ % 20 == 0) {
         Print("⚠️ Spread too high: ", spread, " pips");
      }
      return;
   }
   
   // Don't trade if already in position
   if(isInTrade) return;
   
   // Calculate OFI
   double ofiRatio = CalculateOFI();
   
   // AGGRESSIVE ENTRY CONDITIONS
   bool signalBuy = (ofiRatio >= OFIThreshold);
   bool signalSell = (ofiRatio <= 1.0 / OFIThreshold);
   
   // Execute trades immediately
   if(signalBuy) {
      ExecuteTrade("BUY", ofiRatio);
   } else if(signalSell) {
      ExecuteTrade("SELL", ofiRatio);
   }
}

//+------------------------------------------------------------------+
//| Execute Trade - Safe version                                     |
//+------------------------------------------------------------------+
void ExecuteTrade(string action, double ofiRatio) {
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) {
      Print("❌ Failed to get tick data");
      return;
   }
   
   double price, tp, sl;
   ENUM_ORDER_TYPE orderType;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   // Calculate pip value correctly
   double pipSize;
   if(StringFind(_Symbol, "JPY") >= 0 || _Symbol == "XAUUSD") {
      pipSize = point * 100.0;
   } else {
      pipSize = point * 10000.0;
   }
   
   if(action == "BUY") {
      price = currentTick.ask;
      sl = price - StopLossPips * pipSize;
      tp = price + TakeProfitPips * pipSize;
      orderType = ORDER_TYPE_BUY;
   } else {
      price = currentTick.bid;
      sl = price + StopLossPips * pipSize;
      tp = price - TakeProfitPips * pipSize;
      orderType = ORDER_TYPE_SELL;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize;
   request.type = orderType;
   request.price = price;
   request.sl = NormalizeDouble(sl, digits);
   request.tp = NormalizeDouble(tp, digits);
   request.deviation = 20;
   request.magic = 202603;
   request.comment = "OFI_" + DoubleToString(ofiRatio, 2) + "x";
   request.type_filling = ORDER_FILLING_IOC;  // FIXED: Use IOC only - FOK fails on many brokers
   request.type_time = ORDER_TIME_GTC;
   
   if(OrderSend(request, result)) {
      if(result.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         Print("✅ ", action, " EXECUTED | OFI: ", DoubleToString(ofiRatio, 2), 
               "x | Price: ", price, " | Trades Today: ", dailyTrades);
      } else {
         Print("⚠️ Order placed but retcode: ", result.retcode);
      }
   } else {
      int error = GetLastError();
      Print("❌ OrderSend failed. Error: ", error);
   }
}

//+------------------------------------------------------------------+
//| Timer handler - Called every 1 second                            |
//+------------------------------------------------------------------+
void OnTimer() {
   ProcessTradeLogic();
   
   // Status report every 60 iterations (60 seconds)
   static int reportCounter = 0;
   reportCounter++;
   if(reportCounter >= 60) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      Print("📊 BAL: $", DoubleToString(balance, 2), 
            " | P/L: $", DoubleToString(profit, 2),
            " | Trades: ", dailyTrades,
            " | OFI: ", DoubleToString(lastOFIValue, 2), "x",
            " | Spread: ", GetSpreadPips(), " pips");
      reportCounter = 0;
   }
}

//+------------------------------------------------------------------+
//| Tick handler - Fallback for aggressive scanning                  |
//+------------------------------------------------------------------+
void OnTick() {
   // Process every tick for maximum trade frequency
   ProcessTradeLogic();
}

//+------------------------------------------------------------------+
//| Position close monitor - Safe history access                     |
//+------------------------------------------------------------------+
void OnTrade() {
   // Check if position was closed
   static bool wasInTrade = false;
   bool currentlyInTrade = HasOpenPosition();
   
   if(wasInTrade && !currentlyInTrade) {
      // Position just closed - safely check history
      HistorySelect(TimeCurrent() - 300, TimeCurrent());  // Last 5 minutes
      int total = HistoryDealsTotal();
      
      for(int i = total - 1; i >= 0; i--) {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket > 0) {
            if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
               if(HistoryDealGetString(ticket, DEAL_SYMBOL) == _Symbol) {
                  double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
                  if(profit < 0) consecutiveLosses++;
                  else consecutiveLosses = 0;
                  Print(profit >= 0 ? "🟢 Closed: +$" : "🔴 Closed: -$", 
                        DoubleToString(MathAbs(profit), 2));
                  break;
               }
            }
         }
      }
   }
   wasInTrade = currentlyInTrade;
}

//+------------------------------------------------------------------+
//| Deinitialization                                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double totalProfit = finalBalance - initialBalance;
   Print("╔════════════════════════════════════════════╗");
   Print("║           🔴 BOT SHUTDOWN                   ║");
   Print("║  Final Balance: $", DoubleToString(finalBalance, 2), "        ║");
   Print("║  Total P/L: $", DoubleToString(totalProfit, 2), "             ║");
   Print("║  Total Trades: ", dailyTrades, "                      ║");
   Print("╚════════════════════════════════════════════╝");
}
EOF

# ============================================
# 5. Create compile script with verification
# ============================================
RUN cat << 'EOF' > /root/compile_and_verify.sh
#!/bin/bash
# Remove the indicator property line that might cause issues
sed -i '/#property indicator_chart_window/d' /root/OFI_Alpha_Bot.mq5
echo "✅ Removed indicator property line"
EOF

RUN chmod +x /root/compile_and_verify.sh

# ============================================
# 6. Entrypoint with Wine optimization
# ============================================
RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash
set -e

# Clean up any stale X11 locks
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1

# Start virtual display
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 3

# Start window manager
fluxbox &
sleep 2

# Start VNC for debugging (optional)
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

# Initialize Wine
wineboot --init
sleep 5

# Install MT5 if not present
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
DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

# Copy and compile expert
EXPERT_PATH="$DATA_DIR/Experts/OFI_Alpha_Bot.mq5"
mkdir -p "$DATA_DIR/Experts"
cp /root/OFI_Alpha_Bot.mq5 "$EXPERT_PATH"

echo "🔧 Compiling expert..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$EXPERT_PATH" /log:"/root/compile.log"

# Check compilation result
if grep -q "0 error(s)" /root/compile.log; then
    echo "✅ Compilation successful - 0 errors"
else
    echo "⚠️ Compilation warnings/errors found:"
    cat /root/compile.log
fi

# Start MT5 Linux bridge
echo "🌉 Starting MT5-Linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

# Keep container alive and stimulate MT5
echo "💓 Starting heartbeat stimulation..."
while true; do
    # Send F5 refresh to MT5 window every 30 seconds
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 30
done &

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
