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
//|                                    Carry_Trade_EA.mq5            |
//|                     Earn daily swap by trading high interest leg |
//|                             Version 1.0 - Valetax compatible    |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex Carry Trade"
#property version   "1.0"
#property strict

// --- INPUTS --------------------------------------------------------+
input string   TradeSymbol      = "AUDJPY.vx";    // Symbol to trade (use your broker's suffix)
input double   RiskPercent      = 5.0;            // % of equity for position sizing
input int      TakeProfitPips   = 200;            // Take profit in pips (0 = disabled)
input int      StopLossPips     = 100;            // Stop loss in pips (0 = disabled)
input int      MaxOpenPositions = 1;              // Max concurrent carry trades
input int      MagicNumber      = 999555;
input bool     UseAutoDirection = true;           // true = auto pick positive swap side, false = manual direction below
input bool     ManualLong       = false;          // if UseAutoDirection=false, true = open long, false = open short
input int      StartHour        = 0;              // Trading hours start (0-24, 0 = all day)
input int      EndHour          = 24;             // Trading hours end
input double   MaxDailyLossPercent = 10.0;        // Stop trading after this % loss in a day
input bool     CloseOnProfit    = true;           // If total profit > MinProfitUSD, close trade
input double   MinProfitUSD     = 5.00;           // Minimum profit to close (if CloseOnProfit=true)

// --- GLOBALS -------------------------------------------------------+
CTrade trade;
datetime lastDebug = 0;
datetime dayStart = 0;
double dailyEquityStart = 0;
bool tradingEnabled = true;
ulong carryTicket = 0;          // ticket of the open carry trade

//+------------------------------------------------------------------+
//| Check if we are inside trading hours                            |
//+------------------------------------------------------------------+
bool IsTradingTime() {
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.hour >= StartHour && dt.hour < EndHour);
}

//+------------------------------------------------------------------+
//| Get swap rate for long or short (in account currency per lot)   |
//+------------------------------------------------------------------+
double GetSwapLong() {
   return SymbolInfoDouble(TradeSymbol, SYMBOL_SWAP_LONG);
}
double GetSwapShort() {
   return SymbolInfoDouble(TradeSymbol, SYMBOL_SWAP_SHORT);
}

//+------------------------------------------------------------------+
//| Close existing carry trade                                      |
//+------------------------------------------------------------------+
void CloseCarryTrade() {
   if(carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      trade.PositionClose(carryTicket);
      Print("Closed carry trade. Ticket: ", carryTicket);
      carryTicket = 0;
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                           |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(TradeSymbol, true);
   dayStart = TimeCurrent();
   dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
   Print("==============================================");
   Print("💰 CARRY TRADE EA");
   Print("   Symbol: ", TradeSymbol);
   Print("   Long swap: ", GetSwapLong(), " | Short swap: ", GetSwapShort());
   Print("   Auto direction: ", UseAutoDirection ? "YES" : (ManualLong ? "Long" : "Short"));
   if(TakeProfitPips > 0) Print("   Take profit: ", TakeProfitPips, " pips");
   if(StopLossPips > 0) Print("   Stop loss: ", StopLossPips, " pips");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   // --- Daily loss reset ---
   datetime now = TimeCurrent();
   if(now - dayStart >= 86400) {
      dayStart = now;
      dailyEquityStart = AccountInfoDouble(ACCOUNT_EQUITY);
      tradingEnabled = true;
      Print("✅ New trading day, loss counter reset.");
   }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPercent = (dailyEquityStart - equity) / dailyEquityStart * 100.0;
   if(lossPercent >= MaxDailyLossPercent) {
      if(tradingEnabled) {
         Print("🚨 Daily loss limit reached (", lossPercent, "%). Trading disabled.");
         tradingEnabled = false;
      }
      return;
   }
   if(!tradingEnabled && lossPercent < MaxDailyLossPercent-2) tradingEnabled = true;
   if(!tradingEnabled) return;
   
   // --- Close if profit target reached ---
   if(CloseOnProfit && carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit >= MinProfitUSD) {
         CloseCarryTrade();
         Print("✅ Closed carry trade due to profit target: $", profit);
      }
   }
   
   // --- Manage open position (update SL/TP if not set) ---
   if(carryTicket != 0 && PositionSelectByTicket(carryTicket)) {
      double sl = 0, tp = 0;
      if(StopLossPips > 0) {
         double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(type == POSITION_TYPE_BUY)
            sl = openPrice - StopLossPips * point;
         else
            sl = openPrice + StopLossPips * point;
      }
      if(TakeProfitPips > 0) {
         double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         if(type == POSITION_TYPE_BUY)
            tp = openPrice + TakeProfitPips * point;
         else
            tp = openPrice - TakeProfitPips * point;
      }
      // Only modify if different
      if((sl > 0 || tp > 0) && (MathAbs(PositionGetDouble(POSITION_SL)-sl) > point || MathAbs(PositionGetDouble(POSITION_TP)-tp) > point))
         trade.PositionModify(carryTicket, sl, tp);
      return;  // already have a position
   }
   
   // --- Check if we can open a new carry trade (outside trading hours or max positions?) ---
   if(!IsTradingTime()) return;
   if(PositionsTotal() >= MaxOpenPositions) return;
   
   // --- Determine direction based on swap rates ---
   bool doBuy = false, doSell = false;
   if(UseAutoDirection) {
      double swapLong = GetSwapLong();
      double swapShort = GetSwapShort();
      if(swapLong > 0 && swapLong > swapShort) doBuy = true;
      else if(swapShort > 0 && swapShort > swapLong) doSell = true;
      else {
         if(swapLong <= 0 && swapShort <= 0) {
            if(DebugPrint())
               Print("⚠️ No positive swap available for ", TradeSymbol);
            return;
         }
         // If both positive? Normally only one is positive. But if both, pick higher.
         if(swapLong > 0 && swapShort > 0) {
            doBuy = (swapLong >= swapShort);
            doSell = !doBuy;
         }
         else if(swapLong > 0) doBuy = true;
         else if(swapShort > 0) doSell = true;
      }
   } else {
      doBuy = ManualLong;
      doSell = !ManualLong;
   }
   
   if(!doBuy && !doSell) return;
   
   // --- Calculate lot size based on risk % of equity ---
   double equitySize = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = NormalizeDouble(equitySize / 1000.0 * (RiskPercent / 100.0), 2);
   lot = MathMax(0.01, lot);
   lot = MathMin(lot, SymbolInfoDouble(TradeSymbol, SYMBOL_VOLUME_MAX));
   
   // --- Open position with optional SL/TP ---
   double ask = SymbolInfoDouble(TradeSymbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(TradeSymbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   double point = SymbolInfoDouble(TradeSymbol, SYMBOL_POINT);
   
   if(doBuy) {
      if(StopLossPips > 0) sl = ask - StopLossPips * point;
      if(TakeProfitPips > 0) tp = ask + TakeProfitPips * point;
      if(trade.Buy(lot, TradeSymbol, ask, sl, tp, "Carry Long")) {
         carryTicket = trade.ResultOrder();
         Print("🔥 Opened LONG carry trade. Swap long: ", GetSwapLong(), " | Lot: ", lot);
      } else {
         Print("❌ Failed to open long. Error: ", GetLastError());
      }
   }
   else if(doSell) {
      if(StopLossPips > 0) sl = bid + StopLossPips * point;
      if(TakeProfitPips > 0) tp = bid - TakeProfitPips * point;
      if(trade.Sell(lot, TradeSymbol, bid, sl, tp, "Carry Short")) {
         carryTicket = trade.ResultOrder();
         Print("🔥 Opened SHORT carry trade. Swap short: ", GetSwapShort(), " | Lot: ", lot);
      } else {
         Print("❌ Failed to open short. Error: ", GetLastError());
      }
   }
   
   // --- Debug every 60 seconds ---
   if(TimeCurrent() - lastDebug >= 60) {
      lastDebug = TimeCurrent();
      Print("📊 Carry status: Open trade = ", (carryTicket != 0 ? "YES" : "NO"));
      Print("   Long swap: ", GetSwapLong(), " | Short swap: ", GetSwapShort());
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
