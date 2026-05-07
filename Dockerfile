FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# =========================================================
# V16.3 - PROFIT-MAX VELOCITY BOT (ULTRA PROFITABILITY)
# =========================================================
RUN cat > /root/VALETAX_TICK_BOT_V16.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                    Carry_Trade_EA_Debug.mq5      |
//|                           Prints swap values, signals, decisions |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Debug Carry Trade"
#property version   "1.1"
#property strict

input string   TradeSymbol      = "AUDJPY";       // Change to your broker's actual symbol (no .vx if not needed)
input double   RiskPercent      = 5.0;
input int      TakeProfitPips   = 200;
input int      StopLossPips     = 100;
input int      MaxOpenPositions = 1;
input int      MagicNumber      = 999555;
input bool     UseAutoDirection = true;
input bool     ManualLong       = false;
input int      StartHour        = 0;
input int      EndHour          = 24;
input double   MaxDailyLossPercent = 10.0;
input bool     CloseOnProfit    = true;
input double   MinProfitUSD     = 5.00;

CTrade trade;
datetime lastDebug = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
bool tradingEnabled = true;
ulong carryTicket = 0;

bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   bool inTime = (dt.hour >= StartHour && dt.hour < EndHour);
   if(!inTime && TimeCurrent()-lastDebug>30) Print("⏰ Outside trading hours. Hour=", dt.hour);
   return inTime;
}

double GetSwapLong() { return SymbolInfoDouble(TradeSymbol, SYMBOL_SWAP_LONG); }
double GetSwapShort() { return SymbolInfoDouble(TradeSymbol, SYMBOL_SWAP_SHORT); }

void CloseCarryTrade() {
   if(carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      trade.PositionClose(carryTicket);
      Print("Closed carry trade. Ticket: ", carryTicket);
      carryTicket = 0;
   }
}

int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(TradeSymbol, true);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("💰 CARRY TRADE EA (DEBUG)");
   Print("   Symbol: ", TradeSymbol);
   Print("   Long swap: ", GetSwapLong(), " | Short swap: ", GetSwapShort());
   Print("   Auto direction: ", UseAutoDirection ? "YES" : (ManualLong ? "Long" : "Short"));
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

void OnTick() {
   // Daily loss reset (simplified)
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      Print("✅ New trading day");
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity) / dailyEquityStart * 100.0;
   if(lossPercent >= MaxDailyLossPercent) {
      if(tradingEnabled) Print("🚨 Daily loss limit reached");
      tradingEnabled = false;
      return;
   }
   if(!tradingEnabled && lossPercent < MaxDailyLossPercent-2) tradingEnabled = true;
   if(!tradingEnabled) return;
   
   // Close if profit target reached
   if(CloseOnProfit && carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit >= MinProfitUSD) {
         CloseCarryTrade();
         Print("✅ Closed due to profit target: $", profit);
      }
   }
   
   // Manage existing position
   if(carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      double sl=0, tp=0, point=SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      if(StopLossPips>0) sl = (type==POSITION_TYPE_BUY) ? openPrice - StopLossPips*point : openPrice + StopLossPips*point;
      if(TakeProfitPips>0) tp = (type==POSITION_TYPE_BUY) ? openPrice + TakeProfitPips*point : openPrice - TakeProfitPips*point;
      if((sl>0||tp>0) && (MathAbs(PositionGetDouble(POSITION_SL)-sl)>point || MathAbs(PositionGetDouble(POSITION_TP)-tp)>point))
         trade.PositionModify(carryTicket, sl, tp);
      return;
   }
   
   // Check if we can open new trade
   if(!IsTradingTime()) return;
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // Determine direction
   bool doBuy = false, doSell = false;
   double swapLong = GetSwapLong();
   double swapShort = GetSwapShort();
   
   if(UseAutoDirection) {
      if(swapLong > 0 && swapLong > swapShort) doBuy = true;
      else if(swapShort > 0 && swapShort > swapLong) doSell = true;
      else {
         Print("⚠️ No positive swap: Long=", swapLong, " Short=", swapShort);
         return;
      }
   } else {
      doBuy = ManualLong;
      doSell = !ManualLong;
   }
   
   // Debug every 30 seconds
   if(now - lastDebug >= 30) {
      lastDebug = now;
      Print("📊 Swap Long=", swapLong, " Short=", swapShort, " doBuy=", doBuy, " doSell=", doSell);
      Print("   Bid=", SymbolInfoDouble(TradeSymbol, SYMBOL_BID), " Ask=", SymbolInfoDouble(TradeSymbol, SYMBOL_ASK));
   }
   
   if(!doBuy && !doSell) return;
   
   double lot = NormalizeDouble(equity/1000.0 * (RiskPercent/100.0), 2);
   lot = MathMax(0.01, MathMin(lot, SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX)));
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   double sl=0, tp=0;
   
   if(doBuy) {
      if(StopLossPips>0) sl = ask - StopLossPips*point;
      if(TakeProfitPips>0) tp = ask + TakeProfitPips*point;
      if(trade.Buy(lot, TradeSymbol, ask, sl, tp, "Carry Long")) {
         carryTicket = trade.ResultOrder();
         Print("🔥 Opened LONG carry trade. Swap=", swapLong);
      } else Print("❌ Buy failed. Error ", GetLastError());
   } else if(doSell) {
      if(StopLossPips>0) sl = bid + StopLossPips*point;
      if(TakeProfitPips>0) tp = bid - TakeProfitPips*point;
      if(trade.Sell(lot, TradeSymbol, bid, sl, tp, "Carry Short")) {
         carryTicket = trade.ResultOrder();
         Print("🔥 Opened SHORT carry trade. Swap=", swapShort);
      } else Print("❌ Sell failed. Error ", GetLastError());
   }
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 3. INSTALLATION & ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
wine "$MT5_EXE" &
sleep 30

DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/VALETAX_TICK_BOT_V16.mq5 "$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/VALETAX_TICK_BOT_V16.mq5" /log:"/root/compile.log"

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
