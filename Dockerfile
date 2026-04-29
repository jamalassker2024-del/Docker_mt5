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
    gettext-base \
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
# 4. Create MQL5 Bot Code (WITH SAFE EXECUTION FIX)
# ============================================
RUN cat > /root/OFI_Tick_Bot.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                          HFT_OFI_Bot.mq5         |
//|                                    High Frequency Order Flow     |
//+------------------------------------------------------------------+
#property copyright "HFT Bot"
#property version   "2.00"
#property strict

// ========== HFT OPTIMIZED SETTINGS ==========
input double   LotSize = 0.01;
input int      OFIThreshold = 2;
input int      LookbackTicks = 20;
input int      TakeProfitPips = 3;
input int      StopLossPips = 2;
input int      MaxSpreadPips = 2;
input int      CooldownSeconds = 0;
input int      MaxDailyTrades = 1000;
input int      MaxConcurrentTrades = 10;

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
   Print("HFT OFI BOT INITIALIZED");
   Print("========================================");
   Print("Lot: ", LotSize);
   Print("TP: ", TakeProfitPips, " pips | SL: ", StopLossPips, " pips");
   Print("OFI Threshold: ", OFIThreshold, "x");
   Print("Max Concurrent: ", MaxConcurrentTrades);
   Print("========================================");
   
   ArrayResize(tickBuffer, LookbackTicks);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastTradeDay = GetCurrentDay();
   
   if(initialBalance > 0) {
      isConnected = true;
      Print("Account Balance: $", initialBalance);
   }
   
   EventSetTimer(10);
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
   if(ticksSinceCalc < 1) return;
   ticksSinceCalc = 0;
   
   // ========== VOLUME-WEIGHTED OFI ==========
   double buyVol = 0, sellVol = 0;
   for(int i = 0; i < LookbackTicks; i++) {
      if(tickBuffer[i].isBuy) {
         buyVol += tickBuffer[i].volume;
      } else {
         sellVol += tickBuffer[i].volume;
      }
   }
   
   double ofiRatio = (sellVol == 0) ? 99.0 : buyVol / sellVol;
   
   // ========== MOMENTUM FILTER ==========
   double lastPrice = tickBuffer[(tickCount-1) % LookbackTicks].price;
   double prevPrice = tickBuffer[(tickCount-2) % LookbackTicks].price;
   bool momentumUp = lastPrice > prevPrice;
   bool momentumDown = lastPrice < prevPrice;
   
   static datetime lastLog = 0;
   if(TimeCurrent() - lastLog > 5) {
      double spread = GetSpreadPips();
      Print("OFI: ", DoubleToString(ofiRatio, 2), "x | Spread: ", DoubleToString(spread, 1), " pips | Trades: ", dailyTrades);
      lastLog = TimeCurrent();
   }
   
   if(PositionsTotal() >= MaxConcurrentTrades) return;
   
   // ========== BUY SIGNAL ==========
   if(ofiRatio >= OFIThreshold && momentumUp) {
      if(dailyTrades >= MaxDailyTrades) return;
      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;
      
      double spread = GetSpreadPips();
      if(spread > MaxSpreadPips) return;
      
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(ask <= 0) return;
      
      // ========== SAFE UNIVERSAL EXECUTION FIX ==========
      // Fix 1: Volume validation with minLot and step
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double volume = MathMax(LotSize, minLot);
      if(lotStep > 0) {
         volume = MathFloor(volume / lotStep) * lotStep;
      }
      
      // Fix 2: Broker stop level check
      int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double pip = GetPipValue();
      double minStop = stopLevel * _Point;
      double price = ask;
      double sl = price - MathMax(StopLossPips * pip, minStop + 2*_Point);
      double tp = price + MathMax(TakeProfitPips * pip, minStop + 2*_Point);
      
      // Normalize
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      price = NormalizeDouble(price, digits);
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      Print("SIGNAL -> TRY BUY");
      Print("   Lot=", volume, " Entry=", price, " TP=", tp, " SL=", sl);
      
      // Fix 3: Try multiple filling modes (IOC, RETURN, FOK)
      int fillings[3] = {ORDER_FILLING_IOC, ORDER_FILLING_RETURN, ORDER_FILLING_FOK};
      bool orderSent = false;
      
      for(int i=0; i<3; i++) {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.symbol = _Symbol;
         request.volume = volume;
         request.type = ORDER_TYPE_BUY;
         request.price = price;
         request.sl = sl;
         request.tp = tp;
         request.deviation = 20;
         request.magic = 2026;
         request.comment = StringFormat("OFI_%.1fx", ofiRatio);
         request.type_filling = fillings[i];
         request.type_time = ORDER_TIME_GTC;
         
         Print("   Trying filling mode: ", fillings[i]);
         
         if(!OrderSend(request, result)) {
            Print("   ❌ OrderSend failed (mode ", fillings[i], ")");
            continue;
         }
         
         Print("   Retcode: ", result.retcode, " | Comment: ", result.comment);
         
         if(result.retcode == TRADE_RETCODE_DONE) {
            Print("✅ SUCCESS with filling mode: ", fillings[i]);
            dailyTrades++;
            lastTradeTime = TimeCurrent();
            orderSent = true;
            break;
         }
      }
      
      if(!orderSent) {
         Print("❌ All filling modes failed for BUY order");
      }
   }
   // ========== SELL SIGNAL ==========
   else if(ofiRatio <= 1.0 / OFIThreshold && OFIThreshold > 1 && momentumDown) {
      if(dailyTrades >= MaxDailyTrades) return;
      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;
      
      double spread = GetSpreadPips();
      if(spread > MaxSpreadPips) return;
      
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(bid <= 0) return;
      
      // ========== SAFE UNIVERSAL EXECUTION FIX ==========
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double volume = MathMax(LotSize, minLot);
      if(lotStep > 0) {
         volume = MathFloor(volume / lotStep) * lotStep;
      }
      
      int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double pip = GetPipValue();
      double minStop = stopLevel * _Point;
      double price = bid;
      double sl = price + MathMax(StopLossPips * pip, minStop + 2*_Point);
      double tp = price - MathMax(TakeProfitPips * pip, minStop + 2*_Point);
      
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      price = NormalizeDouble(price, digits);
      sl = NormalizeDouble(sl, digits);
      tp = NormalizeDouble(tp, digits);
      
      Print("SIGNAL -> TRY SELL");
      Print("   Lot=", volume, " Entry=", price, " TP=", tp, " SL=", sl);
      
      int fillings[3] = {ORDER_FILLING_IOC, ORDER_FILLING_RETURN, ORDER_FILLING_FOK};
      bool orderSent = false;
      
      for(int i=0; i<3; i++) {
         MqlTradeRequest request = {};
         MqlTradeResult result = {};
         
         request.action = TRADE_ACTION_DEAL;
         request.symbol = _Symbol;
         request.volume = volume;
         request.type = ORDER_TYPE_SELL;
         request.price = price;
         request.sl = sl;
         request.tp = tp;
         request.deviation = 20;
         request.magic = 2026;
         request.comment = StringFormat("OFI_%.1fx", ofiRatio);
         request.type_filling = fillings[i];
         request.type_time = ORDER_TIME_GTC;
         
         Print("   Trying filling mode: ", fillings[i]);
         
         if(!OrderSend(request, result)) {
            Print("   ❌ OrderSend failed (mode ", fillings[i], ")");
            continue;
         }
         
         Print("   Retcode: ", result.retcode, " | Comment: ", result.comment);
         
         if(result.retcode == TRADE_RETCODE_DONE) {
            Print("✅ SUCCESS with filling mode: ", fillings[i]);
            dailyTrades++;
            lastTradeTime = TimeCurrent();
            orderSent = true;
            break;
         }
      }
      
      if(!orderSent) {
         Print("❌ All filling modes failed for SELL order");
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
# 5. Create Entrypoint Script (FIXED COMPILATION)
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "HFT OFI BOT - RAILWAY READY"
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

# Start MT5 once to generate folders
wine "$MT5_EXE" &
sleep 45
wineserver -k
sleep 5

# Find the correct MQL5 folder (search for the Include directory)
DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "Include" -type d 2>/dev/null | sed 's/\/Include//' | head -n 1)

if [ -z "$DATA_DIR" ]; then
    echo "Using default Program Files path..."
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

echo "MQL5 Directory: $DATA_DIR"

# Create Experts folder and copy the bot
mkdir -p "$DATA_DIR/Experts"
cp /root/OFI_Tick_Bot.mq5 "$DATA_DIR/Experts/HFT_OFI_Bot.mq5"

# Convert paths to Windows format for MetaEditor
WIN_MQ5_PATH=$(wine winepath -w "$DATA_DIR/Experts/HFT_OFI_Bot.mq5" 2>/dev/null)
WIN_INC_PATH=$(wine winepath -w "$DATA_DIR" 2>/dev/null)

echo "Compiling HFT bot..."
echo "Source: $WIN_MQ5_PATH"
echo "Include: $WIN_INC_PATH"

# Compile using MetaEditor
wine "$EDITOR_EXE" /compile:"$WIN_MQ5_PATH" /include:"$WIN_INC_PATH" /log:"/root/compile.log" 2>&1

sleep 5

if [ -f "$DATA_DIR/Experts/HFT_OFI_Bot.ex5" ]; then
    echo "✅ Bot compiled successfully! .ex5 file created."
else
    echo "❌ Compilation failed. Showing log:"
    cat /root/compile.log 2>/dev/null || echo "No log file found"
fi

# Restart MT5
wine "$MT5_EXE" &

# Start bridge
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "=========================================="
echo "HFT BOT READY!"
echo "=========================================="
echo ""
echo "SETTINGS:"
echo "  TP: 3 pips | SL: 2 pips"
echo "  No cooldown | Max 10 concurrent trades"
echo "  Volume-weighted OFI | Momentum filter"
echo ""
echo "STEPS:"
echo "1. Open noVNC in browser"
echo "2. Login to Valetutax"
echo "3. Open Navigator (Ctrl+N)"
echo "4. Right-click 'Expert Advisors' -> Refresh"
echo "5. Drag 'HFT_OFI_Bot' to chart"
echo "6. Enable Auto-Trading"
echo ""

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
