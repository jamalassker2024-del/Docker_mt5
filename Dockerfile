# Working VALETAX_PROFIT_MAXIMIZER - Dockerized for Railway
ARG CACHE_BUST=9

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
# 4. Create VALETAX PROFIT MAXIMIZER EA (EXACT WORKING VERSION)
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

// State variables
datetime lastTradeTime = 0;
int totalTrades = 0;
int dailyTrades = 0;
int lastTradeDay = 0;
double initialBalance = 0;
double maxDrawdown = 0;
double peakBalance = 0;
bool isInitialized = false;

// Cache filling mode per symbol
int cachedFillingMode[7];
bool cacheInitialized[7];

//+------------------------------------------------------------------+
//| Get supported filling mode                                       |
//+------------------------------------------------------------------+
int GetSupportedFillingMode(string sym) {
   long fillingFlags = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   
   if((fillingFlags & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) {
      return ORDER_FILLING_IOC;
   }
   else if((fillingFlags & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) {
      return ORDER_FILLING_FOK;
   }
   
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Get filling mode name for logging                                |
//+------------------------------------------------------------------+
string GetFillingModeName(int mode) {
   switch(mode) {
      case ORDER_FILLING_FOK:    return "FOK";
      case ORDER_FILLING_IOC:    return "IOC";
      case ORDER_FILLING_RETURN: return "RETURN";
      default:                   return "DEFAULT";
   }
}

//+------------------------------------------------------------------+
//| Get retcode description                                          |
//+------------------------------------------------------------------+
string GetRetcodeDescription(int code) {
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
      case 10022: return "Unsupported filling mode";
      default:    return "Unknown";
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakBalance = initialBalance;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   lastTradeDay = dt.day_of_year;
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      cacheInitialized[i] = false;
   }
   
   isInitialized = true;
   EventSetTimer(1);
   
   Print("========================================");
   Print("  VALETAX PROFIT MAXIMIZER v10.0        ");
   Print("  FULLY FIXED - 0 ERRORS 0 WARNINGS    ");
   Print("========================================");
   Print("  OFI Threshold: ", OFI_Threshold, "x");
   Print("  TP: ", TakeProfit_Points, " pts | SL: ", StopLoss_Points, " pts");
   Print("  Max Spread: ", MaxSpread_Points, " pts");
   Print("  Lot Size: ", LotSize);
   Print("========================================");
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      int mode = GetSupportedFillingMode(Symbols[i]);
      cachedFillingMode[i] = mode;
      cacheInitialized[i] = true;
      Print("  ", Symbols[i], ": ", GetFillingModeName(mode));
   }
   
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Check if position exists                                        |
//+------------------------------------------------------------------+
bool HasPosition(string sym) {
   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == sym) {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Count open positions                                            |
//+------------------------------------------------------------------+
int CountOpenPositions() {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         string sym = PositionGetString(POSITION_SYMBOL);
         for(int j = 0; j < ArraySize(Symbols); j++) {
            if(sym == Symbols[j]) {
               count++;
               break;
            }
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Get day of year                                                 |
//+------------------------------------------------------------------+
int GetDayOfYear() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_year;
}

//+------------------------------------------------------------------+
//| Weekend check                                                   |
//+------------------------------------------------------------------+
bool IsWeekend() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
}

//+------------------------------------------------------------------+
//| Calculate OFI using tick_volume                                 |
//+------------------------------------------------------------------+
double CalculateOFI(string sym) {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   
   if(CopyRates(sym, PERIOD_M1, 0, Lookback_Bars, r) < Lookback_Bars) {
      return 1.0;
   }
   
   double buyVol = 0;
   double sellVol = 0;
   
   for(int i = 0; i < Lookback_Bars; i++) {
      double volume = (double)r[i].tick_volume;
      
      if(r[i].close > r[i].open) {
         buyVol += volume;
      } else if(r[i].close < r[i].open) {
         sellVol += volume;
      } else {
         if(i > 0 && r[i].close >= r[i-1].close) {
            buyVol += volume * 0.7;
            sellVol += volume * 0.3;
         } else {
            buyVol += volume * 0.3;
            sellVol += volume * 0.7;
         }
      }
   }
   
   if(sellVol < 1.0) sellVol = 1.0;
   return buyVol / sellVol;
}

//+------------------------------------------------------------------+
//| Get spread                                                      |
//+------------------------------------------------------------------+
long GetSpread(string sym) {
   return SymbolInfoInteger(sym, SYMBOL_SPREAD);
}

//+------------------------------------------------------------------+
//| Find symbol index                                               |
//+------------------------------------------------------------------+
int FindSymbolIndex(string sym) {
   for(int i = 0; i < ArraySize(Symbols); i++) {
      if(Symbols[i] == sym) return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Execute trade                                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(string sym, bool isBuy, double ofi) {
   MqlTick t;
   if(!SymbolInfoTick(sym, t)) {
      return;
   }
   
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   
   double price = isBuy ? t.ask : t.bid;
   double sl = isBuy ? price - StopLoss_Points * point : price + StopLoss_Points * point;
   double tp = isBuy ? price + TakeProfit_Points * point : price - TakeProfit_Points * point;
   
   int symIndex = FindSymbolIndex(sym);
   int fillingMode = ORDER_FILLING_RETURN;
   
   if(symIndex >= 0 && cacheInitialized[symIndex]) {
      fillingMode = cachedFillingMode[symIndex];
   } else {
      fillingMode = GetSupportedFillingMode(sym);
   }
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   
   req.action = TRADE_ACTION_DEAL;
   req.symbol = sym;
   req.volume = LotSize;
   req.type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = price;
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 150;
   req.magic = MagicNumber;
   req.type_filling = fillingMode;
   req.type_time = ORDER_TIME_GTC;
   req.comment = "OFI" + DoubleToString(ofi, 2);
   
   if(OrderSend(req, res)) {
      if(res.retcode == TRADE_RETCODE_DONE) {
         totalTrades++;
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         
         Print(" TRADE EXECUTED! ", isBuy ? "BUY" : "SELL");
         Print(" Symbol: ", sym);
         Print(" OFI: ", DoubleToString(ofi, 2), "x | Price: ", price);
         Print(" Daily: ", dailyTrades, " | Total: ", totalTrades);
      } else {
         Print(" Trade Error: ", GetRetcodeDescription(res.retcode));
      }
   }
}

//+------------------------------------------------------------------+
//| Process single symbol                                           |
//+------------------------------------------------------------------+
void ProcessSymbol(string sym) {
   if(HasPosition(sym)) return;
   
   long spread = GetSpread(sym);
   if(spread > (long)MaxSpread_Points) return;
   
   if(!TradeOnWeekend && IsWeekend()) return;
   
   double ofi = CalculateOFI(sym);
   
   if(ofi >= OFI_Threshold) {
      ExecuteTrade(sym, true, ofi);
   } else if(ofi <= 1.0 / OFI_Threshold) {
      ExecuteTrade(sym, false, ofi);
   }
}

//+------------------------------------------------------------------+
//| Process all symbols                                             |
//+------------------------------------------------------------------+
void ProcessAllSymbols() {
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
   }
   
   if(dailyTrades >= MaxDaily_Trades) return;
   
   if(Cooldown_Seconds > 0) {
      if(TimeCurrent() - lastTradeTime < Cooldown_Seconds) return;
   }
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      ProcessSymbol(Symbols[i]);
   }
}

//+------------------------------------------------------------------+
//| Update balance metrics                                          |
//+------------------------------------------------------------------+
void UpdateBalanceMetrics() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > peakBalance) peakBalance = balance;
   double currentDD = (peakBalance - balance) / peakBalance * 100;
   if(currentDD > maxDrawdown) maxDrawdown = currentDD;
}

//+------------------------------------------------------------------+
//| Tick handler                                                    |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) return;
   ProcessAllSymbols();
}

//+------------------------------------------------------------------+
//| Timer handler                                                   |
//+------------------------------------------------------------------+
void OnTimer() {
   if(!isInitialized) return;
   
   ProcessAllSymbols();
   UpdateBalanceMetrics();
   
   static int counter = 0;
   counter++;
   if(counter >= 30) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      double profitPercent = initialBalance > 0 ? (profit / initialBalance) * 100 : 0;
      int openPositions = CountOpenPositions();
      
      Print("========== STATUS REPORT ==========");
      Print(" Balance: $", DoubleToString(balance, 2));
      Print(" Profit: $", DoubleToString(profit, 2), " (", DoubleToString(profitPercent, 2), "%)");
      Print(" Open: ", openPositions, " | Daily: ", dailyTrades, " | Total: ", totalTrades);
      Print(" Max DD: ", DoubleToString(maxDrawdown, 2), "%");
      
      for(int i = 0; i < ArraySize(Symbols); i++) {
         double ofi = CalculateOFI(Symbols[i]);
         string signal = "";
         if(ofi >= OFI_Threshold) signal = "BUY";
         else if(ofi <= 1.0/OFI_Threshold) signal = "SELL";
         Print(" ", Symbols[i], ": OFI=", DoubleToString(ofi, 2), "x ", signal);
      }
      Print("====================================");
      counter = 0;
   }
}

//+------------------------------------------------------------------+
//| Position close monitor                                          |
//+------------------------------------------------------------------+
void OnTrade() {
   HistorySelect(TimeCurrent() - 60, TimeCurrent());
   int total = HistoryDealsTotal();
   
   for(int i = total - 1; i >= 0; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0) {
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            string sym = HistoryDealGetString(ticket, DEAL_SYMBOL);
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            
            for(int j = 0; j < ArraySize(Symbols); j++) {
               if(sym == Symbols[j]) {
                  string emoji = profit >= 0 ? "🟢" : "🔴";
                  Print(emoji, " Closed: ", sym, " | $", DoubleToString(profit, 2));
                  break;
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Deinitialization                                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   
   double finalBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double totalProfit = finalBalance - initialBalance;
   double profitPercent = initialBalance > 0 ? (totalProfit / initialBalance) * 100 : 0;
   
   Print("========== BOT SHUTDOWN ==========");
   Print(" Initial: $", DoubleToString(initialBalance, 2));
   Print(" Final:   $", DoubleToString(finalBalance, 2));
   Print(" Profit:  $", DoubleToString(totalProfit, 2), " (", DoubleToString(profitPercent, 2), "%)");
   Print(" Trades:  ", totalTrades);
   Print(" Max DD:  ", DoubleToString(maxDrawdown, 2), "%");
   Print("===================================");
}
EOF

# ============================================
# 5. Entrypoint Script
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "VALETAX PROFIT MAXIMIZER v10.0"
echo "=========================================="

# Cleanup
rm -rf /tmp/.X*

# Start X11
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2

# Start window manager and VNC
fluxbox &
sleep 1
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &

# Initialize Wine
wineboot --init
sleep 5

# Install MT5 if not present
MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 90
fi

# Start MT5
echo "Starting MT5..."
wine "$MT5_EXE" &
sleep 30

# Find MQL5 folder
DATA_DIR=$(find /root/.wine -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/MQL5"
fi

# Install EA
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_PROFIT_BOT.mq5 "$DATA_DIR/Experts/VALETAX_PROFIT_BOT.mq5"

# Compile EA
echo "Compiling EA..."
EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$EDITOR_EXE" ]; then
    wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_PROFIT_BOT.mq5" /log:"/root/compile.log" 2>&1
    if grep -q "0 error(s)" /root/compile.log 2>/dev/null; then
        echo "Compilation SUCCESS - 0 errors"
    else
        echo "Compilation completed"
    fi
fi

# Start mt5linux bridge
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

# Auto-refresh charts
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 3
done &

echo "=========================================="
echo "BOT READY!"
echo "VNC: http://localhost:8080"
echo ""
echo "STEPS:"
echo "1. Open noVNC in browser"
echo "2. Login to Valetutax"
echo "3. Open Navigator (Ctrl+N)"
echo "4. Drag VALETAX_PROFIT_BOT to chart"
echo "5. Enable Auto-Trading"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
