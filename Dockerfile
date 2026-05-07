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
//|                                    Carry_Trade_EA_Fixed.mq5      |
//|                     Trades even with negative swap (choose best) |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Fixed Carry Trade"
#property version   "2.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   TradeSymbol      = "AUDJPY.vx";    // Your symbol
input double   RiskPercent      = 5.0;
input int      TakeProfitPips   = 200;
input int      StopLossPips     = 100;
input int      MaxOpenPositions = 1;
input int      MagicNumber      = 999555;
input bool     UseAutoDirection = true;           // true = pick direction with higher swap (even if negative)
input bool     ManualLong       = false;          // if UseAutoDirection=false, this decides
input double   MinSwapToTrade   = -999.0;         // Minimum swap allowed (e.g., -10 means swap must be >= -10)
input int      StartHour        = 0;
input int      EndHour          = 24;
input double   MaxDailyLossPercent = 10.0;
input bool     CloseOnProfit    = true;
input double   MinProfitUSD     = 5.00;

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime lastDebug = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
bool tradingEnabled = true;
ulong carryTicket = 0;

//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
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

//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(TradeSymbol, true);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("💰 CARRY TRADE EA (Fixed)");
   Print("   Symbol: ", TradeSymbol);
   Print("   Long swap: ", GetSwapLong(), " | Short swap: ", GetSwapShort());
   Print("   Auto direction: ", UseAutoDirection ? "YES (choose higher swap)" : "Manual");
   Print("   MinSwapToTrade: ", MinSwapToTrade);
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnTick() {
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
   
   // Close on profit if enabled
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
   
   if(!IsTradingTime()) return;
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // --- Determine direction ---
   bool doBuy = false, doSell = false;
   double swapLong = GetSwapLong();
   double swapShort = GetSwapShort();
   
   if(UseAutoDirection) {
      // Choose direction with higher swap (even if negative)
      if(swapLong >= swapShort) {
         if(swapLong >= MinSwapToTrade) doBuy = true;
         else Print("⚠️ Long swap ", swapLong, " below MinSwapToTrade ", MinSwapToTrade);
      } else {
         if(swapShort >= MinSwapToTrade) doSell = true;
         else Print("⚠️ Short swap ", swapShort, " below MinSwapToTrade ", MinSwapToTrade);
      }
   } else {
      doBuy = ManualLong;
      doSell = !ManualLong;
   }
   
   // Debug every 30 seconds
   if(now - lastDebug >= 30) {
      lastDebug = now;
      Print("📊 Swap Long=", swapLong, " Short=", swapShort);
      Print("   Selected: ", doBuy ? "BUY" : (doSell ? "SELL" : "NONE"));
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
         Print("🔥 Opened LONG (swap=", swapLong, ")");
      } else Print("❌ Buy failed. Error ", GetLastError());
   } else if(doSell) {
      if(StopLossPips>0) sl = bid + StopLossPips*point;
      if(TakeProfitPips>0) tp = bid - TakeProfitPips*point;
      if(trade.Sell(lot, TradeSymbol, bid, sl, tp, "Carry Short")) {
         carryTicket = trade.ResultOrder();
         Print("🔥 Opened SHORT (swap=", swapShort, ")");
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
