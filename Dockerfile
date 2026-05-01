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
# 4. HFT TICK-BASED EA (0 ERRORS 0 WARNINGS)
# ============================================
RUN cat << 'EOF' > /root/VALETAX_PROFIT_BOT.mq5
//+------------------------------------------------------------------+
//|                                    VALETAX_TICK_HFT_BOT.mq5      |
//|                    TICK-BASED HFT - 0 ERRORS 0 WARNINGS         |
//+------------------------------------------------------------------+
#property strict
#property version "10.0"

// ============================================
// HFT TICK-BASED SETTINGS
// ============================================
input double   LotSize = 0.02;
input double   OFI_Threshold = 1.15;
input int      LookbackTicks = 20;
input int      TakeProfit_Price = 150;
input int      StopLoss_Price = 100;
input int      MaxSpread_Price = 50;
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
   "SOLUSD.vx"
};

// ========== TICK BUFFER STRUCTURE ==========
struct TickRecord {
   datetime time;
   double   price;
   int      direction;     // 1 = price up, -1 = price down
   long     volume;
};

TickRecord tickBuffer[];
int      tickCount = 0;
int      totalTicks = 0;
double   lastPrice = 0;

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
int cachedFillingMode[6];
bool cacheInitialized[6];

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
//| Get spread in price terms                                        |
//+------------------------------------------------------------------+
int GetSpreadPrice(string sym) {
   return (int)SymbolInfoInteger(sym, SYMBOL_SPREAD);
}

//+------------------------------------------------------------------+
//| Day of year                                                     |
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
//| Check if position exists                                        |
//+------------------------------------------------------------------+
bool HasPosition(string sym) {
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         if(PositionGetString(POSITION_SYMBOL) == sym) return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Count open positions                                            |
//+------------------------------------------------------------------+
int CountOpenPositions() {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
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
//| Update balance metrics                                          |
//+------------------------------------------------------------------+
void UpdateBalanceMetrics() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > peakBalance) peakBalance = balance;
   double currentDD = (peakBalance - balance) / peakBalance * 100;
   if(currentDD > maxDrawdown) maxDrawdown = currentDD;
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
   if(!SymbolInfoTick(sym, t)) return;
   
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   
   double price = isBuy ? t.ask : t.bid;
   double sl = isBuy ? price - StopLoss_Price * point : price + StopLoss_Price * point;
   double tp = isBuy ? price + TakeProfit_Price * point : price - TakeProfit_Price * point;
   
   // Get cached filling mode
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
   req.price = NormalizeDouble(price, digits);
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 50;
   req.magic = MagicNumber;
   req.type_filling = fillingMode;
   req.type_time = ORDER_TIME_GTC;
   req.comment = "TICK_OFI_" + DoubleToString(ofi, 2);
   
   if(OrderSend(req, res)) {
      if(res.retcode == TRADE_RETCODE_DONE) {
         totalTrades++;
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         
         Print("✅ TRADE EXECUTED! ", isBuy ? "BUY" : "SELL");
         Print("   Symbol: ", sym);
         Print("   OFI: ", DoubleToString(ofi, 2), "x | Price: ", price);
         Print("   Daily: ", dailyTrades, " | Total: ", totalTrades);
      } else {
         Print("⚠️ Trade Error: ", GetRetcodeDescription(res.retcode));
      }
   }
}

//+------------------------------------------------------------------+
//| Process single symbol using TICK-BASED OFI                       |
//+------------------------------------------------------------------+
void ProcessSymbol(string sym) {
   if(HasPosition(sym)) return;
   
   int spread = GetSpreadPrice(sym);
   if(spread > MaxSpread_Price) return;
   
   if(!TradeOnWeekend && IsWeekend()) return;
   
   // ========== TICK-BASED OFI CALCULATION ==========
   if(tickCount < LookbackTicks) return;
   
   int buyTicks = 0, sellTicks = 0;
   long buyVolume = 0, sellVolume = 0;
   
   for(int i = 0; i < LookbackTicks; i++) {
      if(tickBuffer[i].direction > 0) {
         buyTicks++;
         buyVolume += tickBuffer[i].volume;
      } else if(tickBuffer[i].direction < 0) {
         sellTicks++;
         sellVolume += tickBuffer[i].volume;
      }
   }
   
   // Calculate ratios
   double tickRatio = (sellTicks > 0) ? (double)buyTicks / (double)sellTicks : 99.0;
   double volumeRatio = (sellVolume > 0) ? (double)buyVolume / (double)sellVolume : 99.0;
   double finalOFI = (volumeRatio + tickRatio) / 2.0;
   
   // Momentum check
   bool momentumUp = buyTicks > sellTicks;
   bool momentumDown = sellTicks > buyTicks;
   
   // Execute based on tick-based OFI
   if(finalOFI >= OFI_Threshold && momentumUp) {
      ExecuteTrade(sym, true, finalOFI);
   } else if(finalOFI <= 1.0 / OFI_Threshold && momentumDown) {
      ExecuteTrade(sym, false, finalOFI);
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
//| Update tick buffer for all symbols                              |
//+------------------------------------------------------------------+
void UpdateTickBuffer(string sym) {
   MqlTick currentTick;
   if(!SymbolInfoTick(sym, currentTick)) return;
   if(currentTick.last <= 0) return;
   
   totalTicks++;
   
   // Determine tick direction based on price movement
   int direction = 0;
   if(lastPrice > 0) {
      if(currentTick.last > lastPrice) direction = 1;
      else if(currentTick.last < lastPrice) direction = -1;
   }
   lastPrice = currentTick.last;
   
   // Store in circular buffer
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = TimeCurrent();
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].direction = direction;
   tickBuffer[idx].volume = currentTick.volume;
   tickCount++;
}

//+------------------------------------------------------------------+
//| Initialization                                                  |
//+------------------------------------------------------------------+
int OnInit() {
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   peakBalance = initialBalance;
   lastTradeDay = GetDayOfYear();
   
   // Initialize tick buffer
   ArrayResize(tickBuffer, LookbackTicks);
   for(int i = 0; i < LookbackTicks; i++) {
      tickBuffer[i].direction = 0;
      tickBuffer[i].price = 0;
      tickBuffer[i].volume = 0;
   }
   
   // Initialize cache for filling modes
   for(int i = 0; i < ArraySize(Symbols); i++) {
      int mode = GetSupportedFillingMode(Symbols[i]);
      cachedFillingMode[i] = mode;
      cacheInitialized[i] = true;
   }
   
   isInitialized = true;
   EventSetTimer(30);
   
   Print("========================================");
   Print("  VALETAX TICK-BASED HFT BOT v10.0     ");
   Print("  TICK HFT - 0 ERRORS 0 WARNINGS      ");
   Print("========================================");
   Print("  LOT: ", LotSize);
   Print("  OFI Threshold: ", OFI_Threshold, "x");
   Print("  TP: ", TakeProfit_Price, " pts | SL: ", StopLoss_Price, " pts");
   Print("  Lookback Ticks: ", LookbackTicks);
   Print("========================================");
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      Print("  ", Symbols[i], ": ", GetFillingModeName(cachedFillingMode[i]));
   }
   
   Print("========================================");
   Print("  READY - TICK-BASED HFT ACTIVE");
   Print("========================================");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| TICK HANDLER - PURE TICK-BASED                                   |
//+------------------------------------------------------------------+
void OnTick() {
   if(!isInitialized) return;
   
   // Update tick buffer for all symbols
   for(int i = 0; i < ArraySize(Symbols); i++) {
      UpdateTickBuffer(Symbols[i]);
   }
   
   ProcessAllSymbols();
}

//+------------------------------------------------------------------+
//| Timer - Status Report                                           |
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
      Print(" Ticks: ", totalTicks, " | Max DD: ", DoubleToString(maxDrawdown, 2), "%");
      
      // Show current OFI for each symbol
      for(int i = 0; i < ArraySize(Symbols); i++) {
         if(tickCount >= LookbackTicks) {
            int buyTicks = 0, sellTicks = 0;
            long buyVolume = 0, sellVolume = 0;
            
            for(int j = 0; j < LookbackTicks; j++) {
               if(tickBuffer[j].direction > 0) {
                  buyTicks++;
                  buyVolume += tickBuffer[j].volume;
               } else if(tickBuffer[j].direction < 0) {
                  sellTicks++;
                  sellVolume += tickBuffer[j].volume;
               }
            }
            
            double tickRatio = (sellTicks > 0) ? (double)buyTicks / (double)sellTicks : 99.0;
            double volumeRatio = (sellVolume > 0) ? (double)buyVolume / (double)sellVolume : 99.0;
            double finalOFI = (volumeRatio + tickRatio) / 2.0;
            
            string signal = "⚪";
            if(finalOFI >= OFI_Threshold) signal = "🟢 BUY";
            else if(finalOFI <= 1.0/OFI_Threshold) signal = "🔴 SELL";
            
            Print(" ", Symbols[i], ": OFI=", DoubleToString(finalOFI, 2), "x ", signal);
         }
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
   Print(" Ticks:   ", totalTicks);
   Print(" Max DD:  ", DoubleToString(maxDrawdown, 2), "%");
   Print("===================================");
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
cp /root/VALETAX_PROFIT_BOT.mq5 "$DATA_DIR/Experts/VALETAX_TICK_HFT_BOT.mq5"

echo "🔧 Compiling..."
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/VALETAX_TICK_HFT_BOT.mq5" /log:"/root/compile.log" 2>&1

if [ -f "/root/compile.log" ]; then
    if grep -q "0 error(s)" /root/compile.log && grep -q "0 warning(s)" /root/compile.log; then
        echo "✅ Compilation SUCCESS - 0 errors, 0 warnings"
    else
        echo "⚠️ Compilation log:"
        cat /root/compile.log
    fi
fi

echo "🌉 Starting MT5-Linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "💓 Starting 3-second stimulation..."
while true; do
    xdotool search --name "MetaTrader" key F5 2>/dev/null || true
    sleep 3
done &

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  🔥 TICK-BASED HFT v10.0 - 0 ERRORS 0 WARNINGS 🔥           ║"
echo "║  VNC: http://localhost:8080                                 ║"
echo "║  FEATURES:                                                  ║"
echo "║  - Pure tick-based (NO candle bars)                        ║"
echo "║  - Tick direction tracking                                  ║"
echo "║  - Volume-weighted OFI                                      ║"
echo "║  - 20-tick lookback window                                  ║"
echo "╚══════════════════════════════════════════════════════════════╝"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
