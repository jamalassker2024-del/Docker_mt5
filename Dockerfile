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
# 4. Create MQL5 Bot Code (FIXED 'tick_volume' ERROR)
# ============================================
RUN cat << 'EOF' > /root/OFI_Tick_Bot.mq5
//+------------------------------------------------------------------+
//|                                                  OFI_Tick_Bot.mq5 |
//|                                    Order Flow Imbalance Scalper   |
//+------------------------------------------------------------------+
#property copyright "OFI Bot"
#property version   "1.00"
#property strict

input double   LotSize = 0.01;
input int      OFIThreshold = 3;
input int      LookbackTicks = 50;
input int      TakeProfitPips = 10;
input int      StopLossPips = 8;
input int      MaxSpreadPips = 3;
input int      CooldownSeconds = 3;
input int      MaxDailyTrades = 100;

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

int GetCurrentDay() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return dt.day;
}

int OnInit() {
   Print("========================================");
   Print("💎 OFI TICK BOT INITIALIZED");
   Print("   Lot: ", LotSize, " | TP: ", TakeProfitPips, " | SL: ", StopLossPips);
   Print("========================================");
   ArrayResize(tickBuffer, LookbackTicks);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastTradeDay = GetCurrentDay();
   EventSetTimer(30);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   int currentDay = GetCurrentDay();
   if (currentDay != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = currentDay;
   }
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
   bool isBuyTick = false;
   double tickPrice = 0;
   
   if (currentTick.ask == currentTick.last) {
      isBuyTick = true;
      tickPrice = currentTick.ask;
   }
   else if (currentTick.bid == currentTick.last) {
      isBuyTick = false;
      tickPrice = currentTick.bid;
   }
   else {
      static double lastPrice = 0;
      tickPrice = currentTick.last;
      isBuyTick = (tickPrice > lastPrice);
      lastPrice = tickPrice;
   }
   
   // FIXED: Struct assignment using the correct MqlTick member
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = TimeCurrent();
   tickBuffer[idx].price = tickPrice;
   tickBuffer[idx].isBuy = isBuyTick;
   
   // FIXED: MT5 uses tick_volume for the volume of the current tick
   tickBuffer[idx].volume = currentTick.tick_volume;
   
   tickCount++;
   if (tickCount < LookbackTicks) return;
   
   static int ticksSinceCalc = 0;
   ticksSinceCalc++;
   if (ticksSinceCalc < 5) return;
   ticksSinceCalc = 0;
   
   double ofiRatio = CalculateOFI();
   
   if (ofiRatio >= OFIThreshold) {
      CheckAndExecuteTrade("BUY", ofiRatio);
   }
   else if (ofiRatio <= 1.0 / OFIThreshold) {
      CheckAndExecuteTrade("SELL", ofiRatio);
   }
}

double CalculateOFI() {
   int buyTicks = 0, sellTicks = 0;
   for (int i = 0; i < LookbackTicks; i++) {
      if (tickBuffer[i].isBuy) buyTicks++;
      else sellTicks++;
   }
   if (sellTicks == 0) return (buyTicks > 0) ? 999.0 : 1.0;
   return (double)buyTicks / (double)sellTicks;
}

double GetSpreadPips() {
   return (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) / 10.0;
}

void CheckAndExecuteTrade(string action, double ofiRatio) {
   if (dailyTrades >= MaxDailyTrades) return;
   if (TimeCurrent() - lastTradeTime < (datetime)CooldownSeconds) return;
   if (GetSpreadPips() > (double)MaxSpreadPips) return;
   if (PositionSelect(_Symbol)) return;
   
   MqlTick currentTick;
   SymbolInfoTick(_Symbol, currentTick);
   
   double price, tp, sl;
   ENUM_ORDER_TYPE orderType;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipMultiplier = 10.0;
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   if (action == "BUY") {
      price = currentTick.ask;
      sl = price - StopLossPips * point * pipMultiplier;
      tp = price + TakeProfitPips * point * pipMultiplier;
      orderType = ORDER_TYPE_BUY;
   } else {
      price = currentTick.bid;
      sl = price + StopLossPips * point * pipMultiplier;
      tp = price - TakeProfitPips * point * pipMultiplier;
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
   request.deviation = 10;
   request.magic = 2026;
   request.comment = "OFI_" + DoubleToString(ofiRatio, 1) + "x";
   request.type_filling = ORDER_FILLING_IOC;
   request.type_time = ORDER_TIME_GTC;
   
   if (OrderSend(request, result)) {
      if (result.retcode == TRADE_RETCODE_DONE) {
         dailyTrades++;
         lastTradeTime = TimeCurrent();
         Print("✅ ", action, " | OFI: ", ofiRatio, "x | Entry: ", price);
      }
   }
}

void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double profit = balance - initialBalance;
   Print("📊 Balance: $", balance, " | Profit: $", profit, " | Trades: ", dailyTrades);
}

void OnDeinit(const int reason) {
   Print("🔴 OFI BOT SHUTDOWN | Final Balance: $", AccountInfoDouble(ACCOUNT_BALANCE));
}
EOF

# ============================================
# 5. Entrypoint Script
# ============================================
RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash
set -e
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
    wine /root/mt5setup.exe &
    sleep 60
fi

wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine/drive_c/users/root/AppData/Roaming/MetaQuotes/Terminal/ -name "MQL5" -type d 2>/dev/null | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

EXPERT_PATH="$DATA_DIR/Experts/OFI_Tick_Bot.mq5"
mkdir -p "$DATA_DIR/Experts"
cp /root/OFI_Tick_Bot.mq5 "$EXPERT_PATH"

wine "$EDITOR_EXE" /compile:"$EXPERT_PATH" /log:"/root/compile.log"
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
