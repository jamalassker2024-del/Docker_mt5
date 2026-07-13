
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
//|                                          BB_RSI_Scalp_EA.mq5    |
//|                                    Bollinger + RSI Scalper M1    |
//+------------------------------------------------------------------+
#property copyright "BB RSI Scalp"
#property version   "1.00"
#property description "Bollinger Band + RSI Scalp Strategy for XAUUSD M1"
#property description "Entry on next candle open after conditions met"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\SymbolInfo.mqh>

CTrade         m_trade;
CPositionInfo  m_position;
CAccountInfo   m_account;
CSymbolInfo    m_symbol;

input double   InpLotSize        = 0.01;           // Fixed Lot Size
input double   InpRiskPercent    = 0.0;            // Risk % (0 = fixed lot)
input int      InpSL_Pips        = 5;              // Stop Loss in pips
input int      InpBB_Period      = 20;             // Bollinger Bands Period
input double   InpBB_Deviation   = 2.0;            // Bollinger Bands Deviation
input int      InpRSI_Period     = 14;             // RSI Period
input int      InpRSI_Overbought = 70;             // RSI Overbought Level
input int      InpRSI_Oversold   = 30;             // RSI Oversold Level
input int      InpEMA_Period     = 200;            // EMA Period
input bool     InpUseADX         = false;          // Use ADX Filter
input int      InpADX_Period     = 14;             // ADX Period
input int      InpADX_Threshold  = 20;             // ADX Minimum Threshold
input int      InpMaxSpread      = 30;             // Max Spread (points)
input int      InpMagicNumber    = 20260713;       // Magic Number
input bool     InpTrailingStop   = false;          // Enable Trailing Stop

int            bb_handle, rsi_handle, ema_handle, adx_handle;
datetime       last_bar_time = 0;
bool           pending_buy = false, pending_sell = false;
double         pending_sl = 0, pending_tp = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(50);

   bb_handle = iBands(_Symbol, PERIOD_M1, InpBB_Period, 0, InpBB_Deviation, PRICE_CLOSE);
   if (bb_handle == INVALID_HANDLE) {
      Print("Failed to create BB indicator");
      return INIT_FAILED;
   }
   rsi_handle = iRSI(_Symbol, PERIOD_M1, InpRSI_Period, PRICE_CLOSE);
   if (rsi_handle == INVALID_HANDLE) {
      Print("Failed to create RSI indicator");
      return INIT_FAILED;
   }
   ema_handle = iMA(_Symbol, PERIOD_M1, InpEMA_Period, 0, MODE_EMA, PRICE_CLOSE);
   if (ema_handle == INVALID_HANDLE) {
      Print("Failed to create EMA indicator");
      return INIT_FAILED;
   }
   if (InpUseADX) {
      adx_handle = iADX(_Symbol, PERIOD_M1, InpADX_Period);
      if (adx_handle == INVALID_HANDLE) {
         Print("Failed to create ADX indicator");
         return INIT_FAILED;
      }
   }

   last_bar_time = iTime(_Symbol, PERIOD_M1, 0);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   IndicatorRelease(bb_handle);
   IndicatorRelease(rsi_handle);
   IndicatorRelease(ema_handle);
   if (InpUseADX) IndicatorRelease(adx_handle);
}

//+------------------------------------------------------------------+
//| Get the current pip value for the symbol                         |
//+------------------------------------------------------------------+
double GetPipValue() {
   if (_Point == 0) return 0;
   if (_Digits == 5 || _Digits == 3) return _Point * 10;
   return _Point;
}

//+------------------------------------------------------------------+
//| Check if there is already an open position                       |
//+------------------------------------------------------------------+
bool HasOpenPosition() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (m_position.SelectByIndex(i)) {
         if (m_position.Symbol() == _Symbol && m_position.Magic() == InpMagicNumber) {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk %                               |
//+------------------------------------------------------------------+
double GetLotSize() {
   if (InpRiskPercent <= 0) return InpLotSize;
   double sl_value = InpSL_Pips * GetPipValue();
   if (sl_value <= 0) return InpLotSize;
   double risk_amount = m_account.Balance() * InpRiskPercent / 100.0;
   double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if (tick_value <= 0 || tick_size <= 0) return InpLotSize;
   double lot = risk_amount / (sl_value / tick_size * tick_value);
   double min_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double max_lot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   lot = MathFloor(lot / lot_step) * lot_step;
   lot = MathMax(min_lot, MathMin(max_lot, lot));
   return lot;
}

//+------------------------------------------------------------------+
//| Check if spread is acceptable                                    |
//+------------------------------------------------------------------+
bool IsSpreadOk() {
   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (int)spread <= InpMaxSpread;
}

//+------------------------------------------------------------------+
//| Calculate Bollinger Bands                                         |
//+------------------------------------------------------------------+
bool GetBB(double &upper, double &middle, double &lower) {
   double upper_arr[], middle_arr[], lower_arr[];
   ArraySetAsSeries(upper_arr, true);
   ArraySetAsSeries(middle_arr, true);
   ArraySetAsSeries(lower_arr, true);

   if (CopyBuffer(bb_handle, 0, 0, 3, middle_arr) < 3) return false;
   if (CopyBuffer(bb_handle, 1, 0, 3, upper_arr) < 3) return false;
   if (CopyBuffer(bb_handle, 2, 0, 3, lower_arr) < 3) return false;

   upper = upper_arr[1];
   middle = middle_arr[1];
   lower = lower_arr[1];
   return true;
}

//+------------------------------------------------------------------+
//| Get current RSI value                                            |
//+------------------------------------------------------------------+
double GetRSI() {
   double rsi_arr[];
   ArraySetAsSeries(rsi_arr, true);
   if (CopyBuffer(rsi_handle, 0, 0, 3, rsi_arr) < 3) return -1;
   return rsi_arr[1];
}

//+------------------------------------------------------------------+
//| Get current EMA value                                            |
//+------------------------------------------------------------------+
double GetEMA() {
   double ema_arr[];
   ArraySetAsSeries(ema_arr, true);
   if (CopyBuffer(ema_handle, 0, 0, 3, ema_arr) < 3) return -1;
   return ema_arr[1];
}

//+------------------------------------------------------------------+
//| Get ADX value                                                    |
//+------------------------------------------------------------------+
double GetADX() {
   if (!InpUseADX) return 100;
   double adx_arr[];
   ArraySetAsSeries(adx_arr, true);
   if (CopyBuffer(adx_handle, 0, 0, 3, adx_arr) < 3) return 100;
   return adx_arr[1];
}

//+------------------------------------------------------------------+
//| Check for BUY signal on previous candle                          |
//+------------------------------------------------------------------+
bool CheckBuySignal() {
   double upper, middle, lower;
   if (!GetBB(upper, middle, lower)) return false;

   double rsi = GetRSI();
   if (rsi < 0) return false;

   double ema = GetEMA();
   if (ema < 0) return false;

   double adx = GetADX();
   if (InpUseADX && adx < InpADX_Threshold) return false;

   double low_arr[];
   ArraySetAsSeries(low_arr, true);
   if (CopyLow(_Symbol, PERIOD_M1, 0, 3, low_arr) < 3) return false;

   double close_arr[];
   ArraySetAsSeries(close_arr, true);
   if (CopyClose(_Symbol, PERIOD_M1, 0, 3, close_arr) < 3) return false;

   // Candle 1 (previous closed candle) touched/broke below lower BB
   bool touched_lower = (low_arr[1] <= lower);
   bool rsi_oversold = (rsi < InpRSI_Oversold);
   bool bullish_trend = (close_arr[1] > ema);

   return (touched_lower && rsi_oversold && bullish_trend);
}

//+------------------------------------------------------------------+
//| Check for SELL signal on previous candle                         |
//+------------------------------------------------------------------+
bool CheckSellSignal() {
   double upper, middle, lower;
   if (!GetBB(upper, middle, lower)) return false;

   double rsi = GetRSI();
   if (rsi < 0) return false;

   double ema = GetEMA();
   if (ema < 0) return false;

   double adx = GetADX();
   if (InpUseADX && adx < InpADX_Threshold) return false;

   double high_arr[];
   ArraySetAsSeries(high_arr, true);
   if (CopyHigh(_Symbol, PERIOD_M1, 0, 3, high_arr) < 3) return false;

   double close_arr[];
   ArraySetAsSeries(close_arr, true);
   if (CopyClose(_Symbol, PERIOD_M1, 0, 3, close_arr) < 3) return false;

   // Candle 1 (previous closed candle) touched/broke above upper BB
   bool touched_upper = (high_arr[1] >= upper);
   bool rsi_overbought = (rsi > InpRSI_Overbought);
   bool bearish_trend = (close_arr[1] < ema);

   return (touched_upper && rsi_overbought && bearish_trend);
}

//+------------------------------------------------------------------+
//| Execute a BUY trade                                              |
//+------------------------------------------------------------------+
void ExecuteBuy() {
   if (!IsSpreadOk()) { Print("Spread too wide. Skip BUY."); return; }
   double lot = GetLotSize();
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = NormalizeDouble(ask - InpSL_Pips * GetPipValue(), _Digits);
   double upper, middle, lower;
   if (!GetBB(upper, middle, lower)) {
      middle = ask + 10 * GetPipValue();
   }
   double tp = NormalizeDouble(middle, _Digits);
   if (m_trade.Buy(lot, _Symbol, ask, sl, tp, "BB RSI Scalp"))
      Print("BUY opened. Lot: ", lot, " SL: ", sl, " TP: ", tp);
   else
      Print("BUY failed. Error: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Execute a SELL trade                                             |
//+------------------------------------------------------------------+
void ExecuteSell() {
   if (!IsSpreadOk()) { Print("Spread too wide. Skip SELL."); return; }
   double lot = GetLotSize();
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = NormalizeDouble(bid + InpSL_Pips * GetPipValue(), _Digits);
   double upper, middle, lower;
   if (!GetBB(upper, middle, lower)) {
      middle = bid - 10 * GetPipValue();
   }
   double tp = NormalizeDouble(middle, _Digits);
   if (m_trade.Sell(lot, _Symbol, bid, sl, tp, "BB RSI Scalp"))
      Print("SELL opened. Lot: ", lot, " SL: ", sl, " TP: ", tp);
   else
      Print("SELL failed. Error: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Trailing Stop function                                           |
//+------------------------------------------------------------------+
void CheckTrailingStop() {
   if (!InpTrailingStop) return;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (m_position.SelectByIndex(i)) {
         if (m_position.Symbol() != _Symbol || m_position.Magic() != InpMagicNumber)
            continue;

         ulong ticket = m_position.Ticket();
         double sl = m_position.StopLoss();
         double tp = m_position.TakeProfit();
         double price = (m_position.PositionType() == POSITION_TYPE_BUY) ?
            SymbolInfoDouble(_Symbol, SYMBOL_BID) :
            SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double new_sl;

         if (m_position.PositionType() == POSITION_TYPE_BUY) {
            if (price - m_position.PriceOpen() > 3 * GetPipValue()) {
               new_sl = NormalizeDouble(price - InpSL_Pips * GetPipValue(), _Digits);
               if (new_sl > sl) m_trade.PositionModify(ticket, new_sl, tp);
            }
         } else {
            if (m_position.PriceOpen() - price > 3 * GetPipValue()) {
               new_sl = NormalizeDouble(price + InpSL_Pips * GetPipValue(), _Digits);
               if (new_sl < sl || sl == 0) m_trade.PositionModify(ticket, new_sl, tp);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   // Detect new bar on M1
   datetime current_bar_time = iTime(_Symbol, PERIOD_M1, 0);
   bool new_bar = (current_bar_time != last_bar_time);
   last_bar_time = current_bar_time;

   // If we have a pending signal from previous bar, execute at new bar open
   if (new_bar) {
      if (pending_buy) {
         if (!HasOpenPosition()) ExecuteBuy();
         pending_buy = false;
      }
      if (pending_sell) {
         if (!HasOpenPosition()) ExecuteSell();
         pending_sell = false;
      }

      // Check for new signals on the just-closed candle
      if (!HasOpenPosition()) {
         pending_buy = CheckBuySignal();
         pending_sell = CheckSellSignal();
      }

      if (pending_buy)
         Print("BUY signal detected. Will execute on next candle open.");
      if (pending_sell)
         Print("SELL signal detected. Will execute on next candle open.");
   }

   // Trailing stop
   CheckTrailingStop();
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
