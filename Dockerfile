# Increment to bust cache
ARG CACHE_BUST=7

FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
# Per Railway docs: ensure root permissions for volume access
ENV RAILWAY_RUN_UID=0

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
# 2. Python Dependencies
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. Create entrypoint.sh (with FULL DEBUG)
# ============================================
RUN printf '%s\n' \
'#!/bin/bash' \
'echo "=========================================="' \
'echo "HFT OFI BOT - RAILWAY READY (DEBUG MODE)"' \
'echo "=========================================="' \
'' \
'# Setup X11' \
'rm -f /tmp/.X1-lock' \
'Xvfb :1 -screen 0 1280x800x16 &' \
'sleep 2' \
'fluxbox &' \
'x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &' \
'websockify --web=/usr/share/novnc/ 8080 localhost:5900 &' \
'' \
'# Initialize Wine in the persistent volume' \
'wineboot --init' \
'sleep 10' \
'' \
'MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"' \
'EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"' \
'' \
'if [ ! -f "$MT5_EXE" ]; then' \
'    echo "MT5 not found in volume. Downloading and installing..."' \
'    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /tmp/mt5setup.exe' \
'    wine /tmp/mt5setup.exe /auto /silent' \
'    echo "Waiting for installation to finish..."' \
'    sleep 120' \
'    rm /tmp/mt5setup.exe' \
'fi' \
'' \
'# Find the correct MQL5 folder' \
'DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "Include" -type d 2>/dev/null | sed "s/\/Include//" | head -n 1)' \
'if [ -z "$DATA_DIR" ]; then' \
'    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"' \
'fi' \
'echo "MQL5 Directory: $DATA_DIR"' \
'' \
'# Create MQL5 Bot Code with FULL DEBUG PRINTING' \
'mkdir -p "$DATA_DIR/Experts"' \
'cat > "$DATA_DIR/Experts/HFT_OFI_Bot.mq5" << '"'"'EOF'"'"'' \
'//+------------------------------------------------------------------+' \
'//|                                          HFT_OFI_Bot.mq5         |' \
'//|                                    High Frequency Order Flow     |' \
'//|                                           FULL DEBUG VERSION     |' \
'//+------------------------------------------------------------------+' \
'#property copyright "HFT Bot"' \
'#property version   "2.00"' \
'#property strict' \
'' \
'input double   LotSize = 0.01;' \
'input int      OFIThreshold = 2;' \
'input int      LookbackTicks = 20;' \
'input int      TakeProfitPips = 3;' \
'input int      StopLossPips = 2;' \
'input int      MaxSpreadPips = 3;' \
'input int      CooldownSeconds = 0;' \
'input int      MaxDailyTrades = 1000;' \
'input int      MaxConcurrentTrades = 10;' \
'' \
'struct TickData {' \
'   datetime time;' \
'   double   price;' \
'   bool     isBuy;' \
'   long     volume;' \
'};' \
'' \
'TickData tickBuffer[];' \
'int      tickCount = 0;' \
'datetime lastTradeTime = 0;' \
'int      dailyTrades = 0;' \
'int      lastTradeDay = 0;' \
'double   initialBalance = 0;' \
'bool     isConnected = false;' \
'int      totalTicks = 0;' \
'' \
'int GetCurrentDay() {' \
'   MqlDateTime tm;' \
'   TimeToStruct(TimeCurrent(), tm);' \
'   return tm.day;' \
'}' \
'' \
'double GetPipValue() {' \
'   return (_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point;' \
'}' \
'' \
'double GetSpreadPips() {' \
'   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);' \
'   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);' \
'   if(ask <= 0 || bid <= 0) return 999;' \
'   double pip = GetPipValue();' \
'   return (ask - bid) / pip;' \
'}' \
'' \
'int OnInit() {' \
'   Print("========== HFT OFI BOT INITIALIZED ==========");' \
'   Print("Symbol: ", _Symbol);' \
'   Print("Lot: ", LotSize);' \
'   Print("TP: ", TakeProfitPips, " pips | SL: ", StopLossPips, " pips");' \
'   Print("OFI Threshold: ", OFIThreshold);' \
'   Print("Max Spread: ", MaxSpreadPips, " pips");' \
'   Print("============================================");' \
'   ArrayResize(tickBuffer, LookbackTicks);' \
'   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);' \
'   lastTradeDay = GetCurrentDay();' \
'   if(initialBalance > 0) {' \
'      isConnected = true;' \
'      Print("✅ Account connected! Balance: $", initialBalance);' \
'   } else {' \
'      Print("⚠️ Waiting for broker connection...");' \
'   }' \
'   EventSetTimer(10);' \
'   return(INIT_SUCCEEDED);' \
'}' \
'' \
'void OnTick() {' \
'   totalTicks++;' \
'   if(!isConnected) {' \
'      double checkBalance = AccountInfoDouble(ACCOUNT_BALANCE);' \
'      if(checkBalance > 0) { isConnected = true; initialBalance = checkBalance; Print("✅ Connected! Balance: $", initialBalance); }' \
'      return;' \
'   }' \
'   ' \
'   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) {' \
'      static bool warned = false;' \
'      if(!warned) { Print("⚠️ Auto-trading NOT enabled! Please enable in MT5 toolbar."); warned = true; }' \
'      return;' \
'   }' \
'   ' \
'   int currentDay = GetCurrentDay();' \
'   if(currentDay != lastTradeDay) { dailyTrades = 0; lastTradeDay = currentDay; Print("📅 New day - Daily trades reset"); }' \
'   ' \
'   MqlTick currentTick;' \
'   if(!SymbolInfoTick(_Symbol, currentTick)) return;' \
'   if(currentTick.last <= 0) return;' \
'   ' \
'   bool isBuyTick = false;' \
'   if(currentTick.ask > 0 && currentTick.last >= currentTick.ask) isBuyTick = true;' \
'   else if(currentTick.bid > 0 && currentTick.last <= currentTick.bid) isBuyTick = false;' \
'   else { static double lastPrice = 0; if(lastPrice > 0) isBuyTick = (currentTick.last > lastPrice); lastPrice = currentTick.last; }' \
'   ' \
'   int idx = tickCount % LookbackTicks;' \
'   tickBuffer[idx].time = TimeCurrent();' \
'   tickBuffer[idx].price = currentTick.last;' \
'   tickBuffer[idx].isBuy = isBuyTick;' \
'   tickBuffer[idx].volume = currentTick.volume;' \
'   tickCount++;' \
'   ' \
'   if(tickCount < LookbackTicks) return;' \
'   ' \
'   static int ticksSinceCalc = 0;' \
'   ticksSinceCalc++;' \
'   if(ticksSinceCalc < 3) return;' \
'   ticksSinceCalc = 0;' \
'   ' \
'   // Calculate OFI' \
'   double buyVol = 0, sellVol = 0;' \
'   for(int i = 0; i < LookbackTicks; i++) {' \
'      if(tickBuffer[i].isBuy) buyVol += tickBuffer[i].volume;' \
'      else sellVol += tickBuffer[i].volume;' \
'   }' \
'   double ofiRatio = (sellVol == 0) ? 99.0 : buyVol / sellVol;' \
'   ' \
'   // Momentum' \
'   double lastPrice = tickBuffer[(tickCount-1) % LookbackTicks].price;' \
'   double prevPrice = tickBuffer[(tickCount-2) % LookbackTicks].price;' \
'   bool momentumUp = lastPrice > prevPrice;' \
'   bool momentumDown = lastPrice < prevPrice;' \
'   ' \
'   // Print OFI every 10 seconds' \
'   static datetime lastDebug = 0;' \
'   if(TimeCurrent() - lastDebug > 10) {' \
'      double spread = GetSpreadPips();' \
'      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);' \
'      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);' \
'      Print("🔍 DEBUG: OFI=", DoubleToString(ofiRatio, 2), "x | Spread=", DoubleToString(spread, 1), "pips | Bid=", DoubleToString(bid, _Digits), " Ask=", DoubleToString(ask, _Digits));' \
'      Print("   Momentum: ", momentumUp ? "UP" : (momentumDown ? "DOWN" : "FLAT"), " | Trades today: ", dailyTrades);' \
'      lastDebug = TimeCurrent();' \
'   }' \
'   ' \
'   if(PositionsTotal() >= MaxConcurrentTrades) return;' \
'   ' \
'   // BUY SIGNAL' \
'   if(ofiRatio >= OFIThreshold && momentumUp) {' \
'      if(dailyTrades >= MaxDailyTrades) { Print("Daily trade limit reached"); return; }' \
'      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;' \
'      ' \
'      double spread = GetSpreadPips();' \
'      if(spread > MaxSpreadPips) { Print("Spread too high: ", spread, " pips"); return; }' \
'      ' \
'      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);' \
'      if(ask <= 0) return;' \
'      ' \
'      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);' \
'      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);' \
'      double volume = MathMax(LotSize, minLot);' \
'      if(lotStep > 0) volume = MathFloor(volume / lotStep) * lotStep;' \
'      ' \
'      int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);' \
'      double pip = GetPipValue();' \
'      double minStop = stopLevel * _Point;' \
'      double price = ask;' \
'      double sl = price - MathMax(StopLossPips * pip, minStop + 2*_Point);' \
'      double tp = price + MathMax(TakeProfitPips * pip, minStop + 2*_Point);' \
'      ' \
'      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);' \
'      price = NormalizeDouble(price, digits);' \
'      sl = NormalizeDouble(sl, digits);' \
'      tp = NormalizeDouble(tp, digits);' \
'      ' \
'      Print("🚀 SIGNAL -> BUY | OFI=", DoubleToString(ofiRatio, 1), "x | Price=", price, " | SL=", sl, " | TP=", tp);' \
'      ' \
'      int fillings[3] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};' \
'      for(int i=0; i<3; i++) {' \
'         MqlTradeRequest request = {};' \
'         MqlTradeResult result = {};' \
'         request.action = TRADE_ACTION_DEAL;' \
'         request.symbol = _Symbol;' \
'         request.volume = volume;' \
'         request.type = ORDER_TYPE_BUY;' \
'         request.price = price;' \
'         request.sl = sl;' \
'         request.tp = tp;' \
'         request.deviation = 20;' \
'         request.magic = 2026;' \
'         request.comment = StringFormat("OFI_%.1fx", ofiRatio);' \
'         request.type_filling = fillings[i];' \
'         request.type_time = ORDER_TIME_GTC;' \
'         Print("   Trying filling mode: ", fillings[i]);' \
'         if(OrderSend(request, result)) {' \
'            Print("   OrderSend result: retcode=", result.retcode, " | comment=", result.comment);' \
'            if(result.retcode == TRADE_RETCODE_DONE) {' \
'               dailyTrades++;' \
'               lastTradeTime = TimeCurrent();' \
'               Print("✅ BUY EXECUTED! Ticket:", result.order);' \
'               break;' \
'            } else {' \
'               Print("   Failed with retcode: ", result.retcode);' \
'            }' \
'         } else {' \
'            Print("   OrderSend failed with error: ", GetLastError());' \
'         }' \
'      }' \
'   }' \
'   // SELL SIGNAL' \
'   else if(ofiRatio <= 1.0 / OFIThreshold && OFIThreshold > 1 && momentumDown) {' \
'      if(dailyTrades >= MaxDailyTrades) { Print("Daily trade limit reached"); return; }' \
'      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;' \
'      ' \
'      double spread = GetSpreadPips();' \
'      if(spread > MaxSpreadPips) { Print("Spread too high: ", spread, " pips"); return; }' \
'      ' \
'      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);' \
'      if(bid <= 0) return;' \
'      ' \
'      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);' \
'      double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);' \
'      double volume = MathMax(LotSize, minLot);' \
'      if(lotStep > 0) volume = MathFloor(volume / lotStep) * lotStep;' \
'      ' \
'      int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);' \
'      double pip = GetPipValue();' \
'      double minStop = stopLevel * _Point;' \
'      double price = bid;' \
'      double sl = price + MathMax(StopLossPips * pip, minStop + 2*_Point);' \
'      double tp = price - MathMax(TakeProfitPips * pip, minStop + 2*_Point);' \
'      ' \
'      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);' \
'      price = NormalizeDouble(price, digits);' \
'      sl = NormalizeDouble(sl, digits);' \
'      tp = NormalizeDouble(tp, digits);' \
'      ' \
'      Print("🚀 SIGNAL -> SELL | OFI=", DoubleToString(ofiRatio, 1), "x | Price=", price, " | SL=", sl, " | TP=", tp);' \
'      ' \
'      int fillings[3] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};' \
'      for(int i=0; i<3; i++) {' \
'         MqlTradeRequest request = {};' \
'         MqlTradeResult result = {};' \
'         request.action = TRADE_ACTION_DEAL;' \
'         request.symbol = _Symbol;' \
'         request.volume = volume;' \
'         request.type = ORDER_TYPE_SELL;' \
'         request.price = price;' \
'         request.sl = sl;' \
'         request.tp = tp;' \
'         request.deviation = 20;' \
'         request.magic = 2026;' \
'         request.comment = StringFormat("OFI_%.1fx", ofiRatio);' \
'         request.type_filling = fillings[i];' \
'         request.type_time = ORDER_TIME_GTC;' \
'         Print("   Trying filling mode: ", fillings[i]);' \
'         if(OrderSend(request, result)) {' \
'            Print("   OrderSend result: retcode=", result.retcode, " | comment=", result.comment);' \
'            if(result.retcode == TRADE_RETCODE_DONE) {' \
'               dailyTrades++;' \
'               lastTradeTime = TimeCurrent();' \
'               Print("✅ SELL EXECUTED! Ticket:", result.order);' \
'               break;' \
'            } else {' \
'               Print("   Failed with retcode: ", result.retcode);' \
'            }' \
'         } else {' \
'            Print("   OrderSend failed with error: ", GetLastError());' \
'         }' \
'      }' \
'   }' \
'}' \
'' \
'void OnTimer() {' \
'   double balance = AccountInfoDouble(ACCOUNT_BALANCE);' \
'   if(balance > 0) {' \
'      double profit = balance - initialBalance;' \
'      Print("📊 STATUS | Balance: $", DoubleToString(balance, 2), " | P&L: $", DoubleToString(profit, 2), " | Trades: ", dailyTrades);' \
'   } else {' \
'      Print("📊 STATUS | Waiting for connection...");' \
'   }' \
'}' \
'' \
'void OnDeinit(const int reason) { Print("Bot shutting down..."); EventKillTimer(); }' \
'EOF' \
'echo "✅ Bot code created"' \
'' \
'# Compile the bot' \
'if [ -f "$EDITOR_EXE" ]; then' \
'    echo "Compiling HFT bot..."' \
'    WIN_MQ5_PATH=$(wine winepath -w "$DATA_DIR/Experts/HFT_OFI_Bot.mq5" 2>/dev/null)' \
'    WIN_INC_PATH=$(wine winepath -w "$DATA_DIR" 2>/dev/null)' \
'    wine "$EDITOR_EXE" /compile:"$WIN_MQ5_PATH" /include:"$WIN_INC_PATH" /log:"/root/compile.log" 2>&1' \
'    sleep 5' \
'    if [ -f "$DATA_DIR/Experts/HFT_OFI_Bot.ex5" ]; then' \
'        echo "✅ Bot compiled successfully!"' \
'    else' \
'        echo "⚠️ Compilation may have failed. Check later."' \
'        cat /root/compile.log 2>/dev/null || echo "No log"' \
'    fi' \
'fi' \
'' \
'# Start the MT5 Linux Bridge' \
'echo "Starting mt5linux bridge..."' \
'python3 -m mt5linux --host 0.0.0.0 --port 8001 &' \
'' \
'# Start MT5' \
'echo "Starting MT5..."' \
'wine "$MT5_EXE" &' \
'' \
'echo "=========================================="' \
'echo "✅ HFT BOT READY! (DEBUG MODE)"' \
'echo "=========================================="' \
'echo "📊 DEBUG OUTPUT WILL SHOW:"' \
'echo "   - OFI ratio every 10 seconds"' \
'echo "   - Spread, Bid, Ask prices"' \
'echo "   - Signal triggers"' \
'echo "   - Order execution results"' \
'echo "=========================================="' \
'echo "STEPS:"' \
'echo "1. Open noVNC in browser"' \
'echo "2. Login to Valetutax"' \
'echo "3. Open Navigator (Ctrl+N)"' \
'echo "4. Drag HFT_OFI_Bot to chart"' \
'echo "5. Enable Auto-Trading"' \
'echo "=========================================="' \
'' \
'tail -f /dev/null' > /entrypoint.sh

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
