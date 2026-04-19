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
# 4. WORKING v10.0 + HFT AGGRESSION FEATURES
# ============================================
RUN cat << 'EOF' > /root/VALETAX_HFT_PRO_BOT.mq5
//+------------------------------------------------------------------+
//|                               VALETAX_HFT_PRO_BOT.mq5            |
//|                    v10.0 WORKING BASE + HFT UPGRADES - v12.0    |
//+------------------------------------------------------------------+
#property strict
#property version "12.0"

// ============================================
// 🔥 HFT AGGRESSIVE SETTINGS (Upgraded from v10.0)
// ============================================
input double   LotSize = 0.03;              // 🔥 Increased from 0.02
input double   OFI_Threshold = 1.08;        // 🔥 Lowered from 1.15 (more signals)
input int      Lookback_Bars = 5;           // 🔥 Reduced from 10 (faster)
input int      TakeProfit_Points = 800;     // 🔥 Reduced from 1500 (quicker scalps)
input int      StopLoss_Points = 400;       // 🔥 Reduced from 600 (tighter SL)
input double   MaxSpread_Points = 1200;     // 🔥 Increased from 800 (more trades)
input int      Cooldown_Seconds = 0;        // 🔥 Kept at 0
input int      MaxDaily_Trades = 2000;      // 🔥 Kept high
input int      MaxConcurrent_Positions = 5; // 🔥 NEW: Multiple positions (was 1)
input bool     TradeOnWeekend = true;
input int      MagicNumber = 999000;

// Supported symbols (unchanged)
string Symbols[] = {
   "BTCUSD.vx",
   "ETHUSD.vx", 
   "DOGEUSD.vx",
   "LTCUSD.vx",
   "XRPUSD.vx",
   "BCHUSD.vx",
   "BTCEUR.vx"
};

// State variables (from v10.0)
datetime lastTradeTime = 0;
int totalTrades = 0;
int dailyTrades = 0;
int lastTradeDay = 0;
double initialBalance = 0;
double maxDrawdown = 0;
double peakBalance = 0;
bool isInitialized = false;

// 🔥 NEW HFT variables
int consecutiveWins = 0;
int consecutiveLosses = 0;
double symbolMomentum[7];

// Cache filling mode per symbol (unchanged)
int cachedFillingMode[7];
bool cacheInitialized[7];

//+------------------------------------------------------------------+
//| Get supported filling mode - FIXED CONSTANTS (unchanged)         |
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
//| Get filling mode name for logging (unchanged)                    |
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
//| Get retcode description (unchanged)                              |
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
   
   // Initialize cache
   for(int i = 0; i < ArraySize(Symbols); i++) {
      cacheInitialized[i] = false;
      symbolMomentum[i] = 0;  // 🔥 NEW
   }
   
   isInitialized = true;
   EventSetTimer(1);
   
   Print("╔══════════════════════════════════════════════════╗");
   Print("║     🔥🔥🔥 VALETAX HFT PRO v12.0 🔥🔥🔥            ║");
   Print("║         v10.0 BASE + HFT UPGRADES                ║");
   Print("╠══════════════════════════════════════════════════╣");
   Print("║  OFI Threshold: ", OFI_Threshold, "x (🔥 LOWERED)            ║");
   Print("║  Lookback: ", Lookback_Bars, " bars (🔥 FASTER)                 ║");
   Print("║  TP: ", TakeProfit_Points, " | SL: ", StopLoss_Points, " (🔥 2:1 R:R)        ║");
   Print("║  Max Spread: ", MaxSpread_Points, " pts (🔥 LOOSENED)         ║");
   Print("║  Max Concurrent: ", MaxConcurrent_Positions, " (🔥 MULTI)          ║");
   Print("║  Lot Size: ", LotSize, " (🔥 INCREASED)                  ║");
   Print("╠══════════════════════════════════════════════════╣");
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      int mode = GetSupportedFillingMode(Symbols[i]);
      cachedFillingMode[i] = mode;
      cacheInitialized[i] = true;
      Print("║  ", Symbols[i], ": ", GetFillingModeName(mode));
   }
   
   Print("╚══════════════════════════════════════════════════╝");
   Print("🔥 HFT MODE: Targeting 50+ trades/hour");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| 🔥 NEW: Count positions per symbol                              |
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
//| Count open positions (MODIFIED for multi-position)               |
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
//| 🔥 NEW: Check if symbol has position (replaces old HasPosition) |
//+------------------------------------------------------------------+
bool HasPosition(string sym) {
   return CountSymbolPositions(sym) > 0;
}

//+------------------------------------------------------------------+
//| Get day of year (unchanged)                                     |
//+------------------------------------------------------------------+
int GetDayOfYear() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.day_of_year;
}

//+------------------------------------------------------------------+
//| Weekend check (unchanged)                                       |
//+------------------------------------------------------------------+
bool IsWeekend() {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
}

//+------------------------------------------------------------------+
//| 🔥 Calculate OFI - with momentum tracking                       |
//+------------------------------------------------------------------+
double CalculateOFI(string sym) {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   
   if(CopyRates(sym, PERIOD_M1, 0, Lookback_Bars, r) < Lookback_Bars) {
      return 1.0;
   }
   
   double buyVol = 0;
   double sellVol = 0;
   double momentum = 0;  // 🔥 NEW
   
   for(int i = 0; i < Lookback_Bars; i++) {
      double volume = (double)r[i].tick_volume;
      
      if(r[i].close > r[i].open) {
         buyVol += volume;
         momentum += (r[i].close - r[i].open) * volume;  // 🔥 NEW
      } else if(r[i].close < r[i].open) {
         sellVol += volume;
         momentum -= (r[i].open - r[i].close) * volume;  // 🔥 NEW
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
   
   // 🔥 NEW: Store momentum
   int symIndex = FindSymbolIndex(sym);
   if(symIndex >= 0) {
      symbolMomentum[symIndex] = momentum;
   }
   
   if(sellVol < 1.0) sellVol = 1.0;
   return buyVol / sellVol;
}

//+------------------------------------------------------------------+
//| Get spread (unchanged)                                          |
//+------------------------------------------------------------------+
long GetSpread(string sym) {
   return SymbolInfoInteger(sym, SYMBOL_SPREAD);
}

//+------------------------------------------------------------------+
//| Find symbol index (unchanged)                                   |
//+------------------------------------------------------------------+
int FindSymbolIndex(string sym) {
   for(int i = 0; i < ArraySize(Symbols); i++) {
      if(Symbols[i] == sym) return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| 🔥 NEW: Adaptive lot size based on win/loss streak              |
//+------------------------------------------------------------------+
double GetAdaptiveLotSize() {
   double baseLot = LotSize;
   
   if(consecutiveWins >= 3) {
      baseLot = LotSize * 1.5;
   }
   if(consecutiveWins >= 5) {
      baseLot = LotSize * 2.0;
   }
   if(consecutiveLosses >= 3) {
      baseLot = LotSize * 0.5;
   }
   
   return baseLot;
}

//+------------------------------------------------------------------+
//| Execute trade - MODIFIED with adaptive lot size                 |
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
   
   // 🔥 NEW: Adaptive lot size
   double lot = GetAdaptiveLotSize();
   
   // Get filling mode (unchanged)
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
   req.volume = lot;  // 🔥 Use adaptive lot
   req.type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = price;
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 200;  // 🔥 Increased from 150 for faster fills
   req.magic = MagicNumber;
   req.type_filling = fillingMode;
   req.type_time = ORDER_TIME_GTC;
   req.comment = "HFT" + DoubleToString(ofi, 2);
   
   if(OrderSend(req, res)) {
      if(res.retcode == TRADE_RETCODE_DONE) {
         totalTrades++;
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         
         Print("╔══════════════════════════════════════════════╗");
         Print("║  🔥🔥🔥 HFT TRADE ", isBuy ? "BUY" : "SELL", " 🔥🔥🔥              ║");
         Print("║  Symbol: ", sym);
         Print("║  OFI: ", DoubleToString(ofi, 2), "x | Lot: ", lot);
         Print("║  Price: ", price, " | Daily: ", dailyTrades);
         Print("║  Win Streak: ", consecutiveWins, " | Loss: ", consecutiveLosses);
         Print("╚══════════════════════════════════════════════╝");
      } else {
         Print("⚠️ Trade Error: ", GetRetcodeDescription(res.retcode));
      }
   }
}

//+------------------------------------------------------------------+
//| 🔥 Process symbol - MODIFIED for multi-position                 |
//+------------------------------------------------------------------+
void ProcessSymbol(string sym) {
   int symPositions = CountSymbolPositions(sym);      // 🔥 NEW
   int totalPositions = CountOpenPositions();         // 🔥 NEW
   
   // 🔥 NEW: Check max concurrent positions
   if(totalPositions >= MaxConcurrent_Positions) return;
   
   // 🔥 NEW: Allow up to 2 positions per symbol (was 1)
   if(symPositions >= 2) return;
   
   long spread = GetSpread(sym);
   if(spread > (long)MaxSpread_Points) return;
   
   if(!TradeOnWeekend && IsWeekend()) return;
   
   double ofi = CalculateOFI(sym);
   
   // 🔥 Execute on ANY signal (threshold already lowered to 1.08)
   if(ofi >= OFI_Threshold) {
      ExecuteTrade(sym, true, ofi);
   } else if(ofi <= 1.0 / OFI_Threshold) {
      ExecuteTrade(sym, false, ofi);
   }
}

//+------------------------------------------------------------------+
//| Process all symbols (unchanged)                                 |
//+------------------------------------------------------------------+
void ProcessAllSymbols() {
   int currentDay = GetDayOfYear();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
      consecutiveWins = 0;   // 🔥 NEW
      consecutiveLosses = 0; // 🔥 NEW
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
//| Update metrics (unchanged)                                      |
//+------------------------------------------------------------------+
void UpdateBalanceMetrics() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > peakBalance) peakBalance = balance;
   double currentDD = (peakBalance - balance) / peakBalance * 100;
   if(currentDD > maxDrawdown) maxDrawdown = currentDD;
}

//+------------------------------------------------------------------+
//| Tick handler (unchanged)                                        |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) return;
   ProcessAllSymbols();
}

//+------------------------------------------------------------------+
//| Timer handler - MODIFIED for faster updates                     |
//+------------------------------------------------------------------+
void OnTimer() {
   if(!isInitialized) return;
   
   ProcessAllSymbols();
   UpdateBalanceMetrics();
   
   static int counter = 0;
   counter++;
   if(counter >= 15) {  // 🔥 Changed from 30 to 15 seconds
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      double profitPercent = initialBalance > 0 ? (profit / initialBalance) * 100 : 0;
      int openPositions = CountOpenPositions();
      
      Print("╔══════════════════════════════════════════════╗");
      Print("║        📊 HFT STATUS (15s update)             ║");
      Print("║  Balance: $", DoubleToString(balance, 2));
      Print("║  Profit: $", DoubleToString(profit, 2), " (", DoubleToString(profitPercent, 2), "%)");
      Print("║  Open: ", openPositions, "/", MaxConcurrent_Positions);
      Print("║  Daily: ", dailyTrades, " | Total: ", totalTrades);
      Print("║  Win Streak: ", consecutiveWins, " | Loss: ", consecutiveLosses);
      Print("║  Max DD: ", DoubleToString(maxDrawdown, 2), "%");
      Print("║  🔥 Signals:");
      
      for(int i = 0; i < ArraySize(Symbols); i++) {
         double ofi = CalculateOFI(Symbols[i]);
         string signal = "⚪";
         if(ofi >= OFI_Threshold) signal = "🟢 BUY";
         else if(ofi <= 1.0/OFI_Threshold) signal = "🔴 SELL";
         Print("║  ", Symbols[i], ": OFI=", DoubleToString(ofi, 2), "x ", signal);
      }
      Print("╚══════════════════════════════════════════════╝");
      counter = 0;
   }
}

//+------------------------------------------------------------------+
//| 🔥 Position close monitor - MODIFIED for streak tracking        |
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
                  // 🔥 NEW: Track win/loss streaks
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
//| Deinitialization (unchanged)                                    |
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
   Print("║  Trades:  ", totalTrades);
   Print("║  Max DD:  ", DoubleToString(maxDrawdown, 2), "%");
   Print("╚══════════════════════════════════════════════╝");
}
EOF

# ============================================
# 5. ENTRYPOINT - Fast Stimulation
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
cp /root/VALETAX_HFT_PRO_BOT.mq5 "$DATA_DIR/Experts/VALETAX_HFT_PRO_BOT.mq5"

echo "🔧 Compiling HFT Pro Bot..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_HFT_PRO_BOT.mq5" /log:"/root/compile.log" 2>&1

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

echo "🔥 Starting 1-second stimulation..."
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 1
done &

echo "╔══════════════════════════════════════════════╗"
echo "║  🔥 HFT PRO v12.0 - 50+ TRADES/HOUR 🔥        ║"
echo "║  VNC: http://localhost:8080                 ║"
echo "╚══════════════════════════════════════════════╝"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
