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
    libxt6 libxrender1 libxext6 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Install Python deps
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Download MT5 Installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. Create MQL5 Bot Code (FULLY FIXED - no tick_volume error)
# ============================================
RUN cat > /root/OFI_Tick_Bot.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                                  OFI_Tick_Bot.mq5 |
//|                                    Order Flow Imbalance Scalper   |
//|                                          FIXED: tick_volume error |
//+------------------------------------------------------------------+
#property copyright "OFI Bot"
#property version   "1.20"
#property strict

input double   LotSize = 0.01;
input int      OFIThreshold = 3;
input int      LookbackTicks = 30;
input int      TakeProfitPips = 8;
input int      StopLossPips = 6;
input int      MaxSpreadPips = 5;
input int      CooldownSeconds = 2;
input int      MaxDailyTrades = 50;

struct TickData {
   datetime time;
   double   price;
   bool     isBuy;
   long     volume;
};

TickData tickBuffer[];
int      tickCount = 0;
datetime lastTradeTime = 0;
int      dailyTrades = 0;
int      lastTradeDay = 0;
double   initialBalance = 0;
bool     isConnected = false;

int GetCurrentDay() {
   MqlDateTime tm;
   TimeToStruct(TimeCurrent(), tm);
   return tm.day;
}

double GetPipValue() {
   return (_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point;
}

double GetSpreadPips() {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 999;
   double pip = GetPipValue();
   return (ask - bid) / pip;
}

int OnInit() {
   Print("========================================");
   Print("OFI TICK BOT INITIALIZED");
   Print("========================================");
   Print("Lot: ", LotSize);
   Print("TP: ", TakeProfitPips, " pips | SL: ", StopLossPips, " pips");
   Print("OFI Threshold: ", OFIThreshold, "x");
   Print("========================================");
   
   ArrayResize(tickBuffer, LookbackTicks);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastTradeDay = GetCurrentDay();
   
   if(initialBalance > 0) {
      isConnected = true;
      Print("Account Balance: $", initialBalance);
   }
   
   EventSetTimer(30);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   if(!isConnected) {
      double checkBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(checkBalance > 0) {
         isConnected = true;
         initialBalance = checkBalance;
         Print("Broker connected! Balance: $", initialBalance);
      }
      return;
   }
   
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;
   
   int currentDay = GetCurrentDay();
   if(currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
   }
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   if(currentTick.last <= 0) return;
   
   bool isBuyTick = false;
   if(currentTick.ask > 0 && currentTick.last >= currentTick.ask) {
      isBuyTick = true;
   }
   else if(currentTick.bid > 0 && currentTick.last <= currentTick.bid) {
      isBuyTick = false;
   }
   else {
      static double lastPrice = 0;
      if(lastPrice > 0) isBuyTick = (currentTick.last > lastPrice);
      lastPrice = currentTick.last;
   }
   
   // FIXED: استخدام currentTick.volume بدلاً من tick_volume
   long tickVolume = currentTick.volume;
   
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = TimeCurrent();
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].isBuy = isBuyTick;
   tickBuffer[idx].volume = tickVolume;
   tickCount++;
   
   if(tickCount < LookbackTicks) return;
   
   static int ticksSinceCalc = 0;
   ticksSinceCalc++;
   if(ticksSinceCalc < 3) return;
   ticksSinceCalc = 0;
   
   int buyTicks = 0, sellTicks = 0;
   for(int i = 0; i < LookbackTicks; i++) {
      if(tickBuffer[i].isBuy) buyTicks++;
      else sellTicks++;
   }
   
   double ofiRatio = (sellTicks == 0) ? 99.0 : (double)buyTicks / (double)sellTicks;
   
   static datetime lastLog = 0;
   if(TimeCurrent() - lastLog > 10) {
      double spread = GetSpreadPips();
      Print("OFI: ", DoubleToString(ofiRatio, 2), "x | Spread: ", DoubleToString(spread, 1), " pips | Trades: ", dailyTrades);
      lastLog = TimeCurrent();
   }
   
   if(ofiRatio >= OFIThreshold) {
      if(dailyTrades >= MaxDailyTrades) return;
      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;
      
      double spread = GetSpreadPips();
      if(spread > MaxSpreadPips) return;
      if(PositionSelect(_Symbol)) return;
      
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask <= 0) return;
      
      double pipValue = GetPipValue();
      double price = ask;
      double tp = price + (TakeProfitPips * pipValue);
      double sl = price - (StopLossPips * pipValue);
      
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      price = NormalizeDouble(price, digits);
      tp = NormalizeDouble(tp, digits);
      sl = NormalizeDouble(sl, digits);
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.symbol = _Symbol;
      request.volume = LotSize;
      request.type = ORDER_TYPE_BUY;
      request.price = price;
      request.sl = sl;
      request.tp = tp;
      request.deviation = 20;
      request.magic = 2026;
      request.comment = StringFormat("OFI_%.1fx", ofiRatio);
      request.type_filling = ORDER_FILLING_IOC;
      request.type_time = ORDER_TIME_GTC;
      
      if(OrderSend(request, result)) {
         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED) {
            dailyTrades++;
            lastTradeTime = TimeCurrent();
            Print("BUY EXECUTED! OFI: ", DoubleToString(ofiRatio, 1), "x | Entry: ", price);
         }
      }
   }
   else if(ofiRatio <= 1.0 / OFIThreshold && OFIThreshold > 1) {
      if(dailyTrades >= MaxDailyTrades) return;
      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;
      
      double spread = GetSpreadPips();
      if(spread > MaxSpreadPips) return;
      if(PositionSelect(_Symbol)) return;
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= 0) return;
      
      double pipValue = GetPipValue();
      double price = bid;
      double tp = price - (TakeProfitPips * pipValue);
      double sl = price + (StopLossPips * pipValue);
      
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      price = NormalizeDouble(price, digits);
      tp = NormalizeDouble(tp, digits);
      sl = NormalizeDouble(sl, digits);
      
      MqlTradeRequest request = {};
      MqlTradeResult result = {};
      
      request.action = TRADE_ACTION_DEAL;
      request.symbol = _Symbol;
      request.volume = LotSize;
      request.type = ORDER_TYPE_SELL;
      request.price = price;
      request.sl = sl;
      request.tp = tp;
      request.deviation = 20;
      request.magic = 2026;
      request.comment = StringFormat("OFI_%.1fx", ofiRatio);
      request.type_filling = ORDER_FILLING_IOC;
      request.type_time = ORDER_TIME_GTC;
      
      if(OrderSend(request, result)) {
         if(result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED) {
            dailyTrades++;
            lastTradeTime = TimeCurrent();
            Print("SELL EXECUTED! OFI: ", DoubleToString(ofiRatio, 1), "x | Entry: ", price);
         }
      }
   }
}

void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance > 0) {
      double profit = balance - initialBalance;
      Print("Balance: $", DoubleToString(balance, 2), " | Profit: $", DoubleToString(profit, 2), " | Trades: ", dailyTrades);
   }
}

void OnDeinit(const int reason) {
   EventKillTimer();
}
EOF

# ============================================
# 5. Create Entrypoint Script
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "OFI TICK BOT - RAILWAY READY"
echo "=========================================="

rm -f /tmp/.X1-lock

Xvfb :1 -screen 0 1280x800x16 &
sleep 2

fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

wineboot --init
sleep 5

MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
EDITOR_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"

if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto /silent &
    sleep 90
fi

export DISPLAY=:1

# Start MT5 to create necessary folders
wine "$MT5_EXE" &
sleep 45

# Kill MT5 to free resources for compilation
wineserver -k
sleep 5

# Find the correct MQL5 folder
DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

# Create Experts folder and copy bot
mkdir -p "$DATA_DIR/Experts"
cp /root/OFI_Tick_Bot.mq5 "$DATA_DIR/Experts/"

# Compile the bot using command line
echo "Compiling bot..."
wine "$EDITOR_EXE" /compile:"$DATA_DIR/Experts/OFI_Tick_Bot.mq5" /log:"/root/compile.log"

# Check compilation result
if [ -f "$DATA_DIR/Experts/OFI_Tick_Bot.ex5" ]; then
    echo "✅ Bot compiled successfully!"
else
    echo "⚠️ Compilation may have failed. Check log."
fi

# Restart MT5
wine "$MT5_EXE" &

# Start bridge
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "=========================================="
echo "BOT READY!"
echo "=========================================="
echo ""
echo "STEPS:"
echo "1. Open noVNC in browser"
echo "2. Login to Valetutax"
echo "3. Open Navigator (Ctrl+N)"
echo "4. Right-click 'Expert Advisors' -> Refresh"
echo "5. Drag 'OFI_Tick_Bot' to chart"
echo "6. Enable Auto-Trading"
echo ""

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
