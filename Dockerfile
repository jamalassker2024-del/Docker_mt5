# Increment to bust cache
ARG CACHE_BUST=8

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
# 3. Create entrypoint.sh (with EA AUTO-ATTACHMENT)
# ============================================
RUN printf '%s\n' \
'#!/bin/bash' \
'echo "=========================================="' \
'echo "HFT OFI BOT - FIXED VERSION"' \
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
'# Initialize Wine' \
'wineboot --init' \
'sleep 10' \
'' \
'MT5_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/terminal64.exe"' \
'EDITOR_EXE="$WINEPREFIX/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"' \
'' \
'if [ ! -f "$MT5_EXE" ]; then' \
'    echo "Installing MT5..."' \
'    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /tmp/mt5setup.exe' \
'    wine /tmp/mt5setup.exe /auto /silent' \
'    sleep 120' \
'    rm /tmp/mt5setup.exe' \
'fi' \
'' \
'# Find MQL5 folder' \
'DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "Include" -type d 2>/dev/null | sed "s/\/Include//" | head -n 1)' \
'if [ -z "$DATA_DIR" ]; then' \
'    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"' \
'fi' \
'mkdir -p "$DATA_DIR/Experts"' \
'echo "MQL5 Directory: $DATA_DIR"' \
'' \
'# Create MQL5 Bot Code (FIXED VERSION)' \
'cat > "$DATA_DIR/Experts/HFT_OFI_Bot.mq5" << '"'"'EOF'"'"'' \
'//+------------------------------------------------------------------+' \
'//|                                          HFT_OFI_Bot.mq5         |' \
'//|                                    High Frequency Order Flow     |' \
'//|                                           FIXED VERSION          |' \
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
'input int      MaxSpreadPips = 5;' \
'input int      CooldownSeconds = 0;' \
'input int      MaxDailyTrades = 1000;' \
'input int      MaxConcurrentTrades = 5;' \
'' \
'struct TickData {' \
'   datetime time;' \
'   double   price;' \
'   int      direction;' \
'};' \
'' \
'TickData tickBuffer[];' \
'int      tickCount = 0;' \
'datetime lastTradeTime = 0;' \
'int      dailyTrades = 0;' \
'int      lastTradeDay = 0;' \
'double   initialBalance = 0;' \
'bool     isConnected = false;' \
'double   lastPrice = 0;' \
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
'   Print("Lot: ", LotSize, " | TP: ", TakeProfitPips, " | SL: ", StopLossPips);' \
'   Print("OFI Threshold: ", OFIThreshold);' \
'   Print("Max Spread: ", MaxSpreadPips, " pips");' \
'   SymbolSelect(_Symbol, true);' \
'   ArrayResize(tickBuffer, LookbackTicks);' \
'   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);' \
'   lastTradeDay = GetCurrentDay();' \
'   if(initialBalance > 0) { isConnected = true; Print("✅ Account: $", initialBalance); }' \
'   EventSetTimer(10);' \
'   return(INIT_SUCCEEDED);' \
'}' \
'' \
'void OnTick() {' \
'   if(!isConnected) {' \
'      double checkBalance = AccountInfoDouble(ACCOUNT_BALANCE);' \
'      if(checkBalance > 0) { isConnected = true; initialBalance = checkBalance; Print("✅ Connected! Balance: $", initialBalance); }' \
'      return;' \
'   }' \
'   ' \
'   MqlTick currentTick;' \
'   if(!SymbolInfoTick(_Symbol, currentTick)) return;' \
'   if(currentTick.last <= 0) return;' \
'   ' \
'   // FIXED: Simple price direction' \
'   int direction = 0;' \
'   if(lastPrice > 0) {' \
'      if(currentTick.last > lastPrice) direction = 1;' \
'      else if(currentTick.last < lastPrice) direction = -1;' \
'   }' \
'   lastPrice = currentTick.last;' \
'   ' \
'   int idx = tickCount % LookbackTicks;' \
'   tickBuffer[idx].time = TimeCurrent();' \
'   tickBuffer[idx].price = currentTick.last;' \
'   tickBuffer[idx].direction = direction;' \
'   tickCount++;' \
'   if(tickCount < LookbackTicks) return;' \
'   ' \
'   static int ticksSinceCalc = 0;' \
'   ticksSinceCalc++;' \
'   if(ticksSinceCalc < 2) return;' \
'   ticksSinceCalc = 0;' \
'   ' \
'   // Calculate OFI (simpler version)' \
'   int buyTicks = 0, sellTicks = 0;' \
'   for(int i = 0; i < LookbackTicks; i++) {' \
'      if(tickBuffer[i].direction > 0) buyTicks++;' \
'      else if(tickBuffer[i].direction < 0) sellTicks++;' \
'   }' \
'   double ofiRatio = (sellTicks == 0) ? 99.0 : (double)buyTicks / (double)sellTicks;' \
'   bool momentumUp = buyTicks > sellTicks;' \
'   bool momentumDown = sellTicks > buyTicks;' \
'   ' \
'   // Debug every 10 seconds' \
'   static datetime lastDebug = 0;' \
'   if(TimeCurrent() - lastDebug > 10) {' \
'      double spread = GetSpreadPips();' \
'      Print("🔍 OFI=", DoubleToString(ofiRatio, 2), "x | Spread=", DoubleToString(spread, 1), "pips | Buy=", buyTicks, " Sell=", sellTicks);' \
'      lastDebug = TimeCurrent();' \
'   }' \
'   ' \
'   if(PositionsTotal() >= MaxConcurrentTrades) return;' \
'   ' \
'   // Daily reset' \
'   int currentDay = GetCurrentDay();' \
'   if(currentDay != lastTradeDay) { dailyTrades = 0; lastTradeDay = currentDay; }' \
'   ' \
'   // BUY SIGNAL (RELAXED)' \
'   if(ofiRatio >= OFIThreshold && momentumUp) {' \
'      if(dailyTrades >= MaxDailyTrades) return;' \
'      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;' \
'      ' \
'      double spread = GetSpreadPips();' \
'      if(spread > MaxSpreadPips * 2) { Print("Spread too high: ", spread); return; }' \
'      ' \
'      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);' \
'      if(ask <= 0) return;' \
'      ' \
'      double volume = LotSize;' \
'      double pip = GetPipValue();' \
'      double price = ask;' \
'      double sl = price - MathMax(StopLossPips * pip, 10 * _Point);' \
'      double tp = price + MathMax(TakeProfitPips * pip, 10 * _Point);' \
'      ' \
'      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);' \
'      price = NormalizeDouble(price, digits);' \
'      sl = NormalizeDouble(sl, digits);' \
'      tp = NormalizeDouble(tp, digits);' \
'      ' \
'      Print("🚀 BUY | OFI=", DoubleToString(ofiRatio, 1), "x | Price=", price);' \
'      ' \
'      MqlTradeRequest request = {};' \
'      MqlTradeResult result = {};' \
'      request.action = TRADE_ACTION_DEAL;' \
'      request.symbol = _Symbol;' \
'      request.volume = volume;' \
'      request.type = ORDER_TYPE_BUY;' \
'      request.price = price;' \
'      request.sl = sl;' \
'      request.tp = tp;' \
'      request.deviation = 20;' \
'      request.magic = 2026;' \
'      request.comment = StringFormat("OFI_%.1fx", ofiRatio);' \
'      request.type_filling = ORDER_FILLING_FOK;' \
'      request.type_time = ORDER_TIME_GTC;' \
'      ' \
'      if(OrderSend(request, result)) {' \
'         if(result.retcode == TRADE_RETCODE_DONE) {' \
'            dailyTrades++; lastTradeTime = TimeCurrent();' \
'            Print("✅ BUY EXECUTED! Retcode:", result.retcode);' \
'         } else { Print("❌ Order failed. Retcode:", result.retcode); }' \
'      } else { Print("❌ OrderSend error:", GetLastError()); }' \
'   }' \
'   // SELL SIGNAL' \
'   else if(ofiRatio <= 1.0 / OFIThreshold && momentumDown) {' \
'      if(dailyTrades >= MaxDailyTrades) return;' \
'      if(TimeCurrent() - lastTradeTime < CooldownSeconds) return;' \
'      ' \
'      double spread = GetSpreadPips();' \
'      if(spread > MaxSpreadPips * 2) return;' \
'      ' \
'      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);' \
'      if(bid <= 0) return;' \
'      ' \
'      double volume = LotSize;' \
'      double pip = GetPipValue();' \
'      double price = bid;' \
'      double sl = price + MathMax(StopLossPips * pip, 10 * _Point);' \
'      double tp = price - MathMax(TakeProfitPips * pip, 10 * _Point);' \
'      ' \
'      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);' \
'      price = NormalizeDouble(price, digits);' \
'      sl = NormalizeDouble(sl, digits);' \
'      tp = NormalizeDouble(tp, digits);' \
'      ' \
'      Print("🚀 SELL | OFI=", DoubleToString(ofiRatio, 1), "x | Price=", price);' \
'      ' \
'      MqlTradeRequest request = {};' \
'      MqlTradeResult result = {};' \
'      request.action = TRADE_ACTION_DEAL;' \
'      request.symbol = _Symbol;' \
'      request.volume = volume;' \
'      request.type = ORDER_TYPE_SELL;' \
'      request.price = price;' \
'      request.sl = sl;' \
'      request.tp = tp;' \
'      request.deviation = 20;' \
'      request.magic = 2026;' \
'      request.comment = StringFormat("OFI_%.1fx", ofiRatio);' \
'      request.type_filling = ORDER_FILLING_FOK;' \
'      request.type_time = ORDER_TIME_GTC;' \
'      ' \
'      if(OrderSend(request, result)) {' \
'         if(result.retcode == TRADE_RETCODE_DONE) {' \
'            dailyTrades++; lastTradeTime = TimeCurrent();' \
'            Print("✅ SELL EXECUTED! Retcode:", result.retcode);' \
'         } else { Print("❌ Order failed. Retcode:", result.retcode); }' \
'      } else { Print("❌ OrderSend error:", GetLastError()); }' \
'   }' \
'}' \
'' \
'void OnTimer() {' \
'   double balance = AccountInfoDouble(ACCOUNT_BALANCE);' \
'   if(balance > 0) Print("📊 Balance: $", DoubleToString(balance, 2), " | Trades: ", dailyTrades);' \
'}' \
'' \
'void OnDeinit(const int reason) { Print("Bot shutdown"); EventKillTimer(); }' \
'EOF' \
'echo "✅ Bot code created"' \
'' \
'# Compile the bot' \
'if [ -f "$EDITOR_EXE" ]; then' \
'    echo "Compiling bot..."' \
'    WIN_MQ5_PATH=$(wine winepath -w "$DATA_DIR/Experts/HFT_OFI_Bot.mq5" 2>/dev/null)' \
'    WIN_INC_PATH=$(wine winepath -w "$DATA_DIR" 2>/dev/null)' \
'    wine "$EDITOR_EXE" /compile:"$WIN_MQ5_PATH" /include:"$WIN_INC_PATH" /log:"/root/compile.log" 2>&1' \
'    sleep 5' \
'    if [ -f "$DATA_DIR/Experts/HFT_OFI_Bot.ex5" ]; then' \
'        echo "✅ Bot compiled successfully!"' \
'    else' \
'        echo "⚠️ Compilation log:"' \
'        cat /root/compile.log 2>/dev/null || echo "No log"' \
'    fi' \
'fi' \
'' \
'# AUTO-ATTACH EA TO CHART (CRITICAL FIX!)' \
'echo "Creating auto-attach configuration..."' \
'cat > "$WINEPREFIX/drive_c/mt5_auto.ini" << INIEOF' \
'[Common]' \
'Port=0' \
'[Charts]' \
'Count=1' \
'Chart0.Symbol=EURUSD' \
'Chart0.Period=1' \
'Chart0.Width=800' \
'Chart0.Height=600' \
'Chart0.Expert=HFT_OFI_Bot.ex5' \
'Chart0.ExpertEnabled=1' \
'INIEOF' \
'' \
'echo "Starting mt5linux bridge..."' \
'python3 -m mt5linux --host 0.0.0.0 --port 8001 &' \
'' \
'echo "Starting MT5 with auto-attach config..."' \
'wine "$MT5_EXE" /config:"C:\\mt5_auto.ini" &' \
'' \
'echo "=========================================="' \
'echo "✅ HFT BOT READY! (FIXED VERSION)"' \
'echo "=========================================="' \
'echo "📊 FIXES APPLIED:"' \
'echo "   - EA auto-attached to EURUSD M1 chart"' \
'echo "   - OFI threshold relaxed (2x instead of 3x)"' \
'echo "   - Spread filter doubled (now 10 pips max)"' \
'echo "   - Stop loss minimum 10 points"' \
'echo "   - Auto-trading check removed (no blocking)"' \
'echo "=========================================="' \
'echo "📌 MANUAL STEPS IF AUTO-ATTACH FAILS:"' \
'echo "   1. Open noVNC"' \
'echo "   2. Login to Valetutax"' \
'echo "   3. Open Navigator (Ctrl+N)"' \
'echo "   4. Drag HFT_OFI_Bot to EURUSD chart"' \
'echo "   5. Enable Auto-Trading"' \
'echo "=========================================="' \
'' \
'tail -f /dev/null' > /entrypoint.sh

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
