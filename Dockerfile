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
# 4. HFT PROFIT MAXIMIZER - 50+ TRADES/HOUR
# ============================================
RUN cat << 'EOF' > /root/VALETAX_HFT_BOT.mq5
//+------------------------------------------------------------------+
//|                                          VALETAX_HFT_BOT.mq5     |
//|              ULTRA AGGRESSIVE HFT - 50+ TRADES/HOUR - v11.0     |
//+------------------------------------------------------------------+
#property strict
#property version "11.0"

// ============================================
// 🔥 HFT AGGRESSIVE SETTINGS - 50+ TRADES/HOUR
// ============================================
input double   LotSize = 0.03;              // 🔥 BIGGER SIZE = MORE PROFIT
input double   OFI_Threshold = 1.08;        // 🔥 ULTRA SENSITIVE (was 1.15)
input int      Lookback_Bars = 5;           // 🔥 5-BAR MICRO OFI (was 10)
input int      TakeProfit_Points = 800;     // 🔥 QUICK SCALPS (was 1500)
input int      StopLoss_Points = 400;       // 🔥 TIGHT SL - 2:1 R:R
input double   MaxSpread_Points = 1200;     // 🔥 LOOSENED - Trade volatile moves
input int      Cooldown_Seconds = 0;        // 🔥 ZERO COOLDOWN
input int      MaxDaily_Trades = 1000;      // 🔥 50+/hour capacity
input int      MaxConcurrent_Positions = 5; // 🔥 MULTI-POSITION (was 1)
input bool     TradeOnWeekend = true;
input bool     ReverseSignals = false;
input int      MagicNumber = 111000;

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

// 🔥 NEW: Momentum scores per symbol
double symbolMomentum[7];
int symbolSignalStrength[7]; // 0=neutral, 1=weak, 2=strong

// State variables
datetime lastTradeTime = 0;
int totalTrades = 0;
int dailyTrades = 0;
int lastTradeDay = 0;
double initialBalance = 0;
double maxDrawdown = 0;
double peakBalance = 0;
bool isInitialized = false;
int consecutiveWins = 0;
int consecutiveLosses = 0;

// Cache filling mode per symbol
int cachedFillingMode[7];
bool cacheInitialized[7];

//+------------------------------------------------------------------+
//| Get supported filling mode - FIXED                               |
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
//| Get filling mode name                                            |
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
      case 10009: return "Done";
      case 10022: return "Unsupported filling";
      default:    return "Code " + IntegerToString(code);
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
      symbolMomentum[i] = 0;
      symbolSignalStrength[i] = 0;
   }
   
   isInitialized = true;
   EventSetTimer(1);
   
   Print("╔══════════════════════════════════════════════════╗");
   Print("║   🔥🔥🔥 VALETAX HFT v11.0 - 50+/HOUR 🔥🔥🔥       ║");
   Print("╠══════════════════════════════════════════════════╣");
   Print("║  OFI Threshold: ", OFI_Threshold, "x (ULTRA SENSITIVE)      ║");
   Print("║  Lookback: ", Lookback_Bars, " bars (MICRO OFI)               ║");
   Print("║  TP: ", TakeProfit_Points, " | SL: ", StopLoss_Points, " (2:1 R:R)          ║");
   Print("║  Max Concurrent: ", MaxConcurrent_Positions, " positions          ║");
   Print("║  Lot Size: ", LotSize, " (AGGRESSIVE)                    ║");
   Print("╠══════════════════════════════════════════════════╣");
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      int mode = GetSupportedFillingMode(Symbols[i]);
      cachedFillingMode[i] = mode;
      cacheInitialized[i] = true;
      Print("║  ", Symbols[i], ": ", GetFillingModeName(mode));
   }
   
   Print("╚══════════════════════════════════════════════════╝");
   Print("🔥 HFT MODE ACTIVE - Targeting 50+ trades/hour");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Count open positions for a symbol                               |
//+------------------------------------------------------------------+
int CountSymbolPositions(string sym) {
   int count = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == sym) {
            count++;
         }
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count total open positions                                      |
//+------------------------------------------------------------------+
int CountAllOpenPositions() {
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
//| 🔥 MICRO OFI - 5-bar ultra-fast calculation                     |
//+------------------------------------------------------------------+
double CalculateOFI(string sym) {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   
   if(CopyRates(sym, PERIOD_M1, 0, Lookback_Bars, r) < Lookback_Bars) {
      return 1.0;
   }
   
   double buyVol = 0;
   double sellVol = 0;
   double momentum = 0;
   
   for(int i = 0; i < Lookback_Bars; i++) {
      double volume = (double)r[i].tick_volume;
      
      if(r[i].close > r[i].open) {
         buyVol += volume;
         momentum += (r[i].close - r[i].open) * volume;
      } else if(r[i].close < r[i].open) {
         sellVol += volume;
         momentum -= (r[i].open - r[i].close) * volume;
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
   
   // Store momentum for signal strength
   int symIndex = FindSymbolIndex(sym);
   if(symIndex >= 0) {
      symbolMomentum[symIndex] = momentum;
   }
   
   if(sellVol < 1.0) sellVol = 1.0;
   return buyVol / sellVol;
}

//+------------------------------------------------------------------+
//| 🔥 Calculate signal strength (0-3)                              |
//+------------------------------------------------------------------+
int GetSignalStrength(string sym, double ofi, double momentum) {
   int strength = 0;
   
   // OFI extremity
   if(ofi >= OFI_Threshold * 1.3 || ofi <= 1.0/(OFI_Threshold * 1.3)) strength++;
   if(ofi >= OFI_Threshold * 1.6 || ofi <= 1.0/(OFI_Threshold * 1.6)) strength++;
   
   // Momentum confirmation
   if(MathAbs(momentum) > 1000) strength++;
   
   return strength;
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
//| 🔥 ADAPTIVE LOT SIZE - Increase on win streak                   |
//+------------------------------------------------------------------+
double GetAdaptiveLotSize() {
   double baseLot = LotSize;
   
   if(consecutiveWins >= 3) {
      baseLot = LotSize * 1.5;  // 🔥 50% bigger after 3 wins
   }
   if(consecutiveWins >= 5) {
      baseLot = LotSize * 2.0;  // 🔥 DOUBLE after 5 wins
   }
   if(consecutiveLosses >= 3) {
      baseLot = LotSize * 0.5;  // 🔥 Half size after 3 losses (protection)
   }
   
   return baseLot;
}

//+------------------------------------------------------------------+
//| Execute trade - HFT OPTIMIZED                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(string sym, bool isBuy, double ofi, int strength) {
   // 🔥 Skip weak signals when we already have positions
   if(strength < 1 && CountAllOpenPositions() >= 3) {
      return;
   }
   
   MqlTick t;
   if(!SymbolInfoTick(sym, t)) return;
   
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   
   double price = isBuy ? t.ask : t.bid;
   double sl = isBuy ? price - StopLoss_Points * point : price + StopLoss_Points * point;
   double tp = isBuy ? price + TakeProfit_Points * point : price - TakeProfit_Points * point;
   
   // 🔥 ADAPTIVE LOT SIZE
   double lot = GetAdaptiveLotSize();
   
   int symIndex = FindSymbolIndex(sym);
   int fillingMode = ORDER_FILLING_RETURN;
   if(symIndex >= 0 && cacheInitialized[symIndex]) {
      fillingMode = cachedFillingMode[symIndex];
   }
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   
   req.action = TRADE_ACTION_DEAL;
   req.symbol = sym;
   req.volume = lot;
   req.type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = price;
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 200;  // 🔥 MAX SLIPPAGE ALLOWED
   req.magic = MagicNumber;
   req.type_filling = fillingMode;
   req.type_time = ORDER_TIME_GTC;
   req.comment = "HFT" + IntegerToString(strength) + "_" + DoubleToString(ofi, 2);
   
   if(OrderSend(req, res)) {
      if(res.retcode == TRADE_RETCODE_DONE) {
         totalTrades++;
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         
         string strengthStars = "";
         for(int s = 0; s < strength; s++) strengthStars += "⭐";
         
         Print("╔══════════════════════════════════════════════╗");
         Print("║  🔥🔥🔥 HFT TRADE ", isBuy ? "BUY" : "SELL", " 🔥🔥🔥              ║");
         Print("║  ", sym, " | ", strengthStars, " (", strength, "/3)");
         Print("║  OFI: ", DoubleToString(ofi, 2), "x | Lot: ", lot);
         Print("║  Price: ", price, " | Daily: ", dailyTrades);
         Print("║  Win Streak: ", consecutiveWins, " | Loss Streak: ", consecutiveLosses);
         Print("╚══════════════════════════════════════════════╝");
      }
   }
}

//+------------------------------------------------------------------+
//| 🔥 Process symbol - Ultra aggressive entry                      |
//+------------------------------------------------------------------+
void ProcessSymbol(string sym) {
   int symPositions = CountSymbolPositions(sym);
   int totalPositions = CountAllOpenPositions();
   
   // 🔥 Allow up to MaxConcurrent positions total
   if(totalPositions >= MaxConcurrent_Positions) return;
   
   // 🔥 Allow up to 2 positions per symbol
   if(symPositions >= 2) return;
   
   long spread = GetSpread(sym);
   if(spread > (long)MaxSpread_Points) return;
   
   if(!TradeOnWeekend && IsWeekend()) return;
   
   double ofi = CalculateOFI(sym);
   int symIndex = FindSymbolIndex(sym);
   double momentum = (symIndex >= 0) ? symbolMomentum[symIndex] : 0;
   int strength = GetSignalStrength(sym, ofi, momentum);
   
   // 🔥 ULTRA AGGRESSIVE - Execute on ANY signal, strength determines priority
   if(ofi >= OFI_Threshold) {
      ExecuteTrade(sym, true, ofi, strength);
   } else if(ofi <= 1.0 / OFI_Threshold) {
      ExecuteTrade(sym, false, ofi, strength);
   }
}

//+------------------------------------------------------------------+
//| Process all symbols - FAST SCAN                                 |
//+------------------------------------------------------------------+
void ProcessAllSymbols() {
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
      consecutiveWins = 0;
      consecutiveLosses = 0;
      Print("🔄 New day - Reset counters");
   }
   
   if(dailyTrades >= MaxDaily_Trades) return;
   
   // 🔥 NO COOLDOWN - Scan all symbols immediately
   for(int i = 0; i < ArraySize(Symbols); i++) {
      ProcessSymbol(Symbols[i]);
   }
}

//+------------------------------------------------------------------+
//| Update metrics                                                  |
//+------------------------------------------------------------------+
void UpdateBalanceMetrics() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > peakBalance) peakBalance = balance;
   double currentDD = (peakBalance - balance) / peakBalance * 100;
   if(currentDD > maxDrawdown) maxDrawdown = currentDD;
}

//+------------------------------------------------------------------+
//| 🔥 Tick handler - Every tick triggers scan                      |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) return;
   ProcessAllSymbols();
   
   // 🔥 Status every 100 ticks (more frequent)
   static int tickCount = 0;
   tickCount++;
   if(tickCount >= 100) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      int openPos = CountAllOpenPositions();
      
      // Calculate trades per hour
      static datetime hourStart = 0;
      static int hourTrades = 0;
      if(TimeCurrent() - hourStart >= 3600) {
         Print("📊 HOURLY: ", hourTrades, " trades | P/L: $", DoubleToString(profit, 2));
         hourStart = TimeCurrent();
         hourTrades = 0;
      }
      hourTrades = dailyTrades;
      
      tickCount = 0;
   }
}

//+------------------------------------------------------------------+
//| Timer handler - Backup scan                                     |
//+------------------------------------------------------------------+
void OnTimer() {
   if(!isInitialized) return;
   
   ProcessAllSymbols();
   UpdateBalanceMetrics();
   
   static int counter = 0;
   counter++;
   if(counter >= 15) {  // 🔥 Every 15 seconds (was 30)
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      double profitPercent = initialBalance > 0 ? (profit / initialBalance) * 100 : 0;
      int openPositions = CountAllOpenPositions();
      
      Print("╔══════════════════════════════════════════════╗");
      Print("║        📊 HFT STATUS (15s update)             ║");
      Print("║  Balance: $", DoubleToString(balance, 2));
      Print("║  P/L: $", DoubleToString(profit, 2), " (", DoubleToString(profitPercent, 2), "%)");
      Print("║  Open: ", openPositions, "/", MaxConcurrent_Positions);
      Print("║  Hourly Trades: ", dailyTrades, " | Total: ", totalTrades);
      Print("║  Win Streak: ", consecutiveWins, " | Loss: ", consecutiveLosses);
      Print("║  🔥 Signals:");
      
      for(int i = 0; i < ArraySize(Symbols); i++) {
         double ofi = CalculateOFI(Symbols[i]);
         int strength = GetSignalStrength(Symbols[i], ofi, symbolMomentum[i]);
         string signal = "⚪";
         if(ofi >= OFI_Threshold) signal = "🟢 BUY";
         else if(ofi <= 1.0/OFI_Threshold) signal = "🔴 SELL";
         
         string stars = "";
         for(int s = 0; s < strength; s++) stars += "⭐";
         
         Print("║  ", Symbols[i], ": ", signal, " ", stars, " OFI=", DoubleToString(ofi, 2), "x");
      }
      Print("╚══════════════════════════════════════════════╝");
      counter = 0;
   }
}

//+------------------------------------------------------------------+
//| Position close monitor - Track win/loss streaks                 |
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
                  if(profit > 0) {
                     consecutiveWins++;
                     consecutiveLosses = 0;
                     Print("🟢🟢🟢 WIN: ", sym, " | +$", DoubleToString(profit, 2), 
                           " | Streak: ", consecutiveWins);
                  } else {
                     consecutiveLosses++;
                     consecutiveWins = 0;
                     Print("🔴 LOSS: ", sym, " | -$", DoubleToString(MathAbs(profit), 2),
                           " | Streak: ", consecutiveLosses);
                  }
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
   
   Print("╔══════════════════════════════════════════════╗");
   Print("║           🔴 HFT BOT SHUTDOWN                 ║");
   Print("╠══════════════════════════════════════════════╣");
   Print("║  Initial: $", DoubleToString(initialBalance, 2));
   Print("║  Final:   $", DoubleToString(finalBalance, 2));
   Print("║  Profit:  $", DoubleToString(totalProfit, 2), " (", DoubleToString(profitPercent, 2), "%)");
   Print("║  Total Trades: ", totalTrades);
   Print("║  Trades/Hour: ~", totalTrades);
   Print("╚══════════════════════════════════════════════╝");
}
EOF

# ============================================
# 5. ENTRYPOINT - Ultra Fast Stimulation
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
cp /root/VALETAX_HFT_BOT.mq5 "$DATA_DIR/Experts/VALETAX_HFT_BOT.mq5"

echo "🔧 Compiling HFT Bot..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_HFT_BOT.mq5" /log:"/root/compile.log" 2>&1

if [ -f "/root/compile.log" ]; then
    if grep -q "0 error(s)" /root/compile.log; then
        echo "✅ Compilation SUCCESS - 0 errors, 0 warnings"
    else
        echo "⚠️ Compilation log:"
        cat /root/compile.log
    fi
fi

echo "🌉 Starting MT5-Linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "🔥🔥🔥 ULTRA FAST 1-SECOND STIMULATION 🔥🔥🔥"
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 1  # 🔥 1-SECOND REFRESH FOR MAX TRADES
done &

echo "╔══════════════════════════════════════════════╗"
echo "║  🔥🔥🔥 HFT v11.0 - 50+ TRADES/HOUR 🔥🔥🔥      ║"
echo "║  VNC: http://localhost:8080                 ║"
echo "║  Target: 50-200+ trades/hour                ║"
echo "╚══════════════════════════════════════════════╝"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
