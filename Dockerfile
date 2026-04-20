FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# SYSTEM + WINE (FAST)
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl unzip procps cabextract xdotool dos2unix \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# PYTHON BRIDGE
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# DOWNLOAD MT5
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 🔥 HIGH PROFIT HFT - TICK PRESSURE + SMART FILTERS
# ============================================
RUN cat << 'EOF' > /root/HFT_PROFIT_BOT.mq5
//+------------------------------------------------------------------+
//|                                         HFT_PROFIT_BOT.mq5      |
//|                    TICK PRESSURE + HIGH WIN RATE FILTERS        |
//+------------------------------------------------------------------+
#property strict
#property version "14.0"

// ============================================
// 🔥 HIGH PROFIT SETTINGS
// ============================================
input double   LotSize = 0.02;                // Base lot
input int      TakeProfit_Points = 150;       // Quick 1.5 pip scalp (crypto)
input int      StopLoss_Points = 120;         // Tight SL - positive R:R
input int      TrailingStop_Points = 80;      // 🔥 Lock in profits
input int      MaxSpread_Points = 3500;       // Wide enough for crypto
input int      MaxPositions = 8;              // Multiple positions
input int      Pressure_Threshold = 3;        // 🔥 Signal strength filter
input int      Cooldown_Ticks = 5;            // Micro-cooldown
input int      MagicNumber = 777000;
input bool     UseTrailingStop = true;

// Supported symbols
string Symbols[] = {
   "BTCUSD.vx",
   "ETHUSD.vx", 
   "DOGEUSD.vx",
   "LTCUSD.vx",
   "XRPUSD.vx"
};

// Tick pressure tracking
double lastBid[5];
double lastAsk[5];
int pressureScore[5];
int tickCounter[5];
int tradesOnSymbol[5];
datetime lastTradeTime[5];

// Performance tracking
int totalTrades = 0;
int winningTrades = 0;
int losingTrades = 0;
double totalProfit = 0;
double initialBalance = 0;
datetime sessionStart = 0;

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit() {
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   sessionStart = TimeCurrent();
   
   for(int i = 0; i < ArraySize(Symbols); i++) {
      lastBid[i] = 0;
      lastAsk[i] = 0;
      pressureScore[i] = 0;
      tickCounter[i] = 0;
      tradesOnSymbol[i] = 0;
      lastTradeTime[i] = 0;
   }
   
   EventSetTimer(1);
   
   Print("╔══════════════════════════════════════════════════╗");
   Print("║     🔥🔥🔥 HIGH PROFIT HFT v14.0 🔥🔥🔥           ║");
   Print("╠══════════════════════════════════════════════════╣");
   Print("║  Strategy: Tick Pressure + Smart Filters         ║");
   Print("║  TP: ", TakeProfit_Points, " | SL: ", StopLoss_Points, " | Trail: ", TrailingStop_Points);
   Print("║  Pressure Threshold: ", Pressure_Threshold);
   Print("║  Max Positions: ", MaxPositions);
   Print("║  Lot Size: ", LotSize);
   Print("╠══════════════════════════════════════════════════╣");
   Print("║  Symbols: BTC, ETH, DOGE, LTC, XRP              ║");
   Print("╚══════════════════════════════════════════════════╝");
   Print("🔥 Target: 30-80 trades/hour | 60-70% win rate");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Count all open positions                                        |
//+------------------------------------------------------------------+
int CountAllPositions() {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Count positions for specific symbol                             |
//+------------------------------------------------------------------+
int CountSymbolPositions(string sym) {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++) {
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
//| Find symbol index                                               |
//+------------------------------------------------------------------+
int GetSymbolIndex(string sym) {
   for(int i = 0; i < ArraySize(Symbols); i++) {
      if(Symbols[i] == sym) return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| 🔥 TICK PRESSURE - The real HFT signal                          |
//+------------------------------------------------------------------+
double GetTickPressure(int symIdx, string sym) {
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick)) return 0;
   
   double pressure = 0;
   
   // Bid pressure (buyers lifting offers)
   if(lastBid[symIdx] > 0) {
      if(tick.bid > lastBid[symIdx]) {
         pressure += 2.0;  // 🔥 Strong buy pressure
         pressureScore[symIdx] += 2;
      } else if(tick.bid < lastBid[symIdx]) {
         pressure -= 1.0;  // Weak sell pressure
         pressureScore[symIdx] -= 1;
      }
   }
   
   // Ask pressure (sellers hitting bids)
   if(lastAsk[symIdx] > 0) {
      if(tick.ask < lastAsk[symIdx]) {
         pressure -= 2.0;  // 🔥 Strong sell pressure
         pressureScore[symIdx] -= 2;
      } else if(tick.ask > lastAsk[symIdx]) {
         pressure += 1.0;  // Weak buy pressure
         pressureScore[symIdx] += 1;
      }
   }
   
   // Volume confirmation (optional boost)
   if(tick.tick_volume > 0) {
      double avgVolume = tick.tick_volume;
      if(avgVolume > 10) {
         pressure *= 1.2;  // 🔥 Boost on high volume
      }
   }
   
   lastBid[symIdx] = tick.bid;
   lastAsk[symIdx] = tick.ask;
   tickCounter[symIdx]++;
   
   // Reset pressure score periodically to avoid drift
   if(tickCounter[symIdx] > 100) {
      pressureScore[symIdx] = 0;
      tickCounter[symIdx] = 0;
   }
   
   return pressure;
}

//+------------------------------------------------------------------+
//| 🔥 SMART FILTER - Only trade quality setups                     |
//+------------------------------------------------------------------+
bool IsQualitySetup(int symIdx, double pressure, bool isBuy) {
   // Must have sufficient pressure
   if(MathAbs(pressure) < Pressure_Threshold) return false;
   
   // Direction must match accumulated pressure
   if(isBuy && pressureScore[symIdx] < Pressure_Threshold) return false;
   if(!isBuy && pressureScore[symIdx] > -Pressure_Threshold) return false;
   
   // Cooldown between trades on same symbol
   if(TimeCurrent() - lastTradeTime[symIdx] < Cooldown_Ticks) return false;
   
   return true;
}

//+------------------------------------------------------------------+
//| 🔥 ADAPTIVE LOT SIZE - Scale with confidence                    |
//+------------------------------------------------------------------+
double GetAdaptiveLot(double pressure) {
   double lot = LotSize;
   double absPressure = MathAbs(pressure);
   
   // Scale up on strong signals
   if(absPressure >= 6.0) lot = LotSize * 1.5;
   if(absPressure >= 10.0) lot = LotSize * 2.0;
   
   // Scale down if losing streak
   if(losingTrades > winningTrades && losingTrades > 2) {
      lot = LotSize * 0.7;
   }
   
   return lot;
}

//+------------------------------------------------------------------+
//| Execute trade with tight risk management                        |
//+------------------------------------------------------------------+
void ExecuteTrade(string sym, bool isBuy, double pressure) {
   int symIdx = GetSymbolIndex(sym);
   if(symIdx < 0) return;
   
   MqlTick tick;
   if(!SymbolInfoTick(sym, tick)) return;
   
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   
   double price = isBuy ? tick.ask : tick.bid;
   double sl = isBuy ? price - StopLoss_Points * point : price + StopLoss_Points * point;
   double tp = isBuy ? price + TakeProfit_Points * point : price - TakeProfit_Points * point;
   double lot = GetAdaptiveLot(pressure);
   
   MqlTradeRequest req = {};
   MqlTradeResult res = {};
   
   req.action = TRADE_ACTION_DEAL;
   req.symbol = sym;
   req.volume = lot;
   req.type = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price = price;
   req.sl = NormalizeDouble(sl, digits);
   req.tp = NormalizeDouble(tp, digits);
   req.deviation = 200;
   req.magic = MagicNumber;
   req.type_filling = ORDER_FILLING_IOC;
   req.type_time = ORDER_TIME_GTC;
   req.comment = "HFT" + DoubleToString(pressure, 1);
   
   if(OrderSend(req, res)) {
      if(res.retcode == TRADE_RETCODE_DONE) {
         totalTrades++;
         tradesOnSymbol[symIdx]++;
         lastTradeTime[symIdx] = TimeCurrent();
         
         string stars = "";
         if(MathAbs(pressure) >= 6.0) stars = "⭐⭐⭐";
         else if(MathAbs(pressure) >= 4.0) stars = "⭐⭐";
         else stars = "⭐";
         
         Print("╔══════════════════════════════════════════════╗");
         Print("║  🔥 ", isBuy ? "BUY" : "SELL", " | ", sym, " | ", stars);
         Print("║  Pressure: ", DoubleToString(pressure, 2), " | Lot: ", lot);
         Print("║  Price: ", price);
         Print("║  Trades: ", totalTrades, " | Win Rate: ", 
               DoubleToString(winningTrades * 100.0 / MathMax(1, winningTrades + losingTrades), 1), "%");
         Print("╚══════════════════════════════════════════════╝");
      }
   }
}

//+------------------------------------------------------------------+
//| 🔥 TRAILING STOP - Lock in profits                              |
//+------------------------------------------------------------------+
void ManageTrailingStop() {
   if(!UseTrailingStop) return;
   
   for(int i = 0; i < PositionsTotal(); i++) {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionSelectByTicket(ticket)) {
         string sym = PositionGetString(POSITION_SYMBOL);
         double point = SymbolInfoDouble(sym, SYMBOL_POINT);
         int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
         
         double currentSL = PositionGetDouble(POSITION_SL);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         int posType = (int)PositionGetInteger(POSITION_TYPE);
         
         MqlTick tick;
         if(!SymbolInfoTick(sym, tick)) continue;
         
         double currentPrice = (posType == POSITION_TYPE_BUY) ? tick.bid : tick.ask;
         double profitPoints = (posType == POSITION_TYPE_BUY) ? 
                              (currentPrice - openPrice) / point : 
                              (openPrice - currentPrice) / point;
         
         // Trail when in profit
         if(profitPoints > TrailingStop_Points) {
            double newSL = (posType == POSITION_TYPE_BUY) ? 
                          currentPrice - TrailingStop_Points * point :
                          currentPrice + TrailingStop_Points * point;
            
            // Only move SL in favorable direction
            bool shouldUpdate = (posType == POSITION_TYPE_BUY && newSL > currentSL) ||
                               (posType == POSITION_TYPE_SELL && newSL < currentSL);
            
            if(shouldUpdate) {
               MqlTradeRequest req = {};
               MqlTradeResult res = {};
               
               req.action = TRADE_ACTION_SLTP;
               req.position = ticket;
               req.symbol = sym;
               req.sl = NormalizeDouble(newSL, digits);
               req.tp = PositionGetDouble(POSITION_TP);
               
               if(OrderSend(req, res)) {
                  // Silent trail update
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Process single symbol                                           |
//+------------------------------------------------------------------+
void ProcessSymbol(int symIdx, string sym) {
   // Check spread
   long spread = SymbolInfoInteger(sym, SYMBOL_SPREAD);
   if(spread > MaxSpread_Points) return;
   
   // Position limits (allow scaling)
   if(CountAllPositions() >= MaxPositions) return;
   if(CountSymbolPositions(sym) >= 3) return;  // Max 3 per symbol
   
   // Get tick pressure
   double pressure = GetTickPressure(symIdx, sym);
   
   // 🔥 Execute on strong signals only
   if(pressure > 0 && IsQualitySetup(symIdx, pressure, true)) {
      ExecuteTrade(sym, true, pressure);
      pressureScore[symIdx] = 0;  // Reset after trade
   } else if(pressure < 0 && IsQualitySetup(symIdx, pressure, false)) {
      ExecuteTrade(sym, false, pressure);
      pressureScore[symIdx] = 0;  // Reset after trade
   }
}

//+------------------------------------------------------------------+
//| OnTick - Main HFT loop                                          |
//+------------------------------------------------------------------+
void OnTick() {
   for(int i = 0; i < ArraySize(Symbols); i++) {
      ProcessSymbol(i, Symbols[i]);
   }
   ManageTrailingStop();
}

//+------------------------------------------------------------------+
//| OnTimer - Backup loop                                           |
//+------------------------------------------------------------------+
void OnTimer() {
   for(int i = 0; i < ArraySize(Symbols); i++) {
      ProcessSymbol(i, Symbols[i]);
   }
   ManageTrailingStop();
   
   // Status report every 30 seconds
   static int counter = 0;
   counter++;
   if(counter >= 30) {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double profit = balance - initialBalance;
      double winRate = (winningTrades + losingTrades > 0) ? 
                       winningTrades * 100.0 / (winningTrades + losingTrades) : 0;
      
      Print("╔══════════════════════════════════════════════╗");
      Print("║        📊 HFT PROFIT STATUS                   ║");
      Print("║  Balance: $", DoubleToString(balance, 2));
      Print("║  P/L: $", DoubleToString(profit, 2));
      Print("║  Trades: ", totalTrades, " | Win: ", winningTrades, " | Loss: ", losingTrades);
      Print("║  Win Rate: ", DoubleToString(winRate, 1), "%");
      Print("║  Open: ", CountAllPositions(), "/", MaxPositions);
      Print("╚══════════════════════════════════════════════╝");
      counter = 0;
   }
}

//+------------------------------------------------------------------+
//| OnTrade - Track performance                                     |
//+------------------------------------------------------------------+
void OnTrade() {
   HistorySelect(TimeCurrent() - 300, TimeCurrent());
   
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket > 0) {
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT) {
            double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            
            if(profit > 0) {
               winningTrades++;
               Print("🟢 WIN: +$", DoubleToString(profit, 2));
            } else if(profit < 0) {
               losingTrades++;
               Print("🔴 LOSS: -$", DoubleToString(MathAbs(profit), 2));
            }
            
            totalProfit += profit;
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
   double netProfit = finalBalance - initialBalance;
   double winRate = (winningTrades + losingTrades > 0) ? 
                    winningTrades * 100.0 / (winningTrades + losingTrades) : 0;
   
   Print("╔══════════════════════════════════════════════╗");
   Print("║           🔴 HFT BOT SHUTDOWN                 ║");
   Print("╠══════════════════════════════════════════════╣");
   Print("║  Session: ", TimeToString(TimeCurrent() - sessionStart, TIME_MINUTES));
   Print("║  Initial: $", DoubleToString(initialBalance, 2));
   Print("║  Final:   $", DoubleToString(finalBalance, 2));
   Print("║  Profit:  $", DoubleToString(netProfit, 2));
   Print("║  Trades:  ", totalTrades);
   Print("║  Win Rate: ", DoubleToString(winRate, 1), "%");
   Print("╚══════════════════════════════════════════════╝");
}
EOF

# ============================================
# ENTRYPOINT - Optimized
# ============================================
RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash
set -e

rm -rf /tmp/.X*

Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2

fluxbox &
sleep 1

x11vnc -display :1 -forever -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &

wineboot --init
sleep 5

MT5="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5" ]; then
    echo "📦 Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 60
fi

wine "$MT5" &
sleep 25

DATA=$(find /root/.wine -name MQL5 -type d | head -n 1)
mkdir -p "$DATA/Experts"
cp /root/HFT_PROFIT_BOT.mq5 "$DATA/Experts/"

EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
echo "🔧 Compiling..."
wine "$EDITOR" /compile:"$DATA/Experts/HFT_PROFIT_BOT.mq5" /log:"/root/log.txt"

if grep -q "0 error(s)" /root/log.txt 2>/dev/null; then
    echo "✅ Compilation SUCCESS"
else
    echo "⚠️ Compilation output:"
    cat /root/log.txt || true
fi

echo "🌉 Starting bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "🔥 Stimulating ticks..."
while true; do
    xdotool key F5 2>/dev/null || true
    sleep 1
done &

echo "╔══════════════════════════════════════════════╗"
echo "║  🔥 HIGH PROFIT HFT v14.0 - READY 🔥          ║"
echo "║  VNC: http://localhost:8080                 ║"
echo "║  Target: 30-80 trades/hr | 60-70% win rate  ║"
echo "╚══════════════════════════════════════════════╝"

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash","/entrypoint.sh"]
