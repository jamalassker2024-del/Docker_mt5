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

RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# =========================================================
# V19 - APEX AGGRESSOR (HIGH-FREQUENCY ARBITRAGE)
# =========================================================
RUN cat > /root/APEX_AGGRESSOR_V19.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Omni-Apex V19"
#property version   "19.00"
#property strict

// --- AGGRESSIVE INPUTS
input string BinanceSymbol     = "BTCUSDT"; 
input double RiskPercent       = 3.0;        // Higher risk for faster growth[cite: 2]
input int    MinGap_BPS        = 4;          // Lowered to 4bps for high frequency[cite: 1]
input int    Fee_BPS           = 14;         // Conservative fee estimate[cite: 1]
input int    TradeCooldown_Sec = 5;          // Only 5 sec wait between trades
input int    MaxOpenPositions  = 3;          // Allow up to 3 concurrent trades for volume
input int    MagicNumber       = 999019;

// --- GLOBALS
CTrade trade;
string binance_url;
datetime last_trade_time = 0;

int OnInit() {
   binance_url = "https://api.binance.com/api/v3/ticker/bookTicker?symbol=" + BinanceSymbol;
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC); // Extreme speed execution[cite: 2]
   
   Print("🚀 V19 AGGRESSOR ONLINE | Target: 50+ trades/hr");
   return(INIT_SUCCEEDED);
}

double GetDynamicLot() {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = (equity / 1000.0) * (RiskPercent / 2.0) * 0.2; 
   return NormalizeDouble(MathMax(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), lot), 2);
}

void OnTick() {
   if(PositionsTotal() >= MaxOpenPositions) return;
   if(TimeCurrent() - last_trade_time < TradeCooldown_Sec) return;

   char post[], result[];
   string headers;
   // High-speed request (30ms timeout)[cite: 1]
   int res = WebRequest("GET", binance_url, NULL, NULL, 30, post, 0, result, headers);
   if(res == -1) return;

   string response = CharArrayToString(result);
   int ask_pos = StringFind(response, "\"askPrice\":\"");
   int bid_pos = StringFind(response, "\"bidPrice\":\"");
   if(ask_pos == -1 || bid_pos == -1) return;
   
   double b_ask = StringToDouble(StringSubstr(response, ask_pos + 12));
   double b_bid = StringToDouble(StringSubstr(response, bid_pos + 12));
   double m_ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double m_bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // --- ARBITRAGE GAP LOGIC[cite: 1]
   // Gap in Basis Points: ((Lead - Lag) / Lag) * 10,000
   double buy_gap_bps = (b_bid - m_ask) / m_ask * 10000;
   double sell_gap_bps = (m_bid - b_ask) / b_ask * 10000;

   double lot = GetDynamicLot();
   double tp_dist = (MinGap_BPS * 2) * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10;

   if(buy_gap_bps > (MinGap_BPS + Fee_BPS)) {
      if(trade.Buy(lot, _Symbol, m_ask, 0, m_ask + tp_dist, "Apex Aggressor")) {
         last_trade_time = TimeCurrent();
         PrintFormat("🔥 AGGRESSIVE BUY | Gap: %.2f bps", buy_gap_bps);
      }
   }
   else if(sell_gap_bps > (MinGap_BPS + Fee_BPS)) {
      if(trade.Sell(lot, _Symbol, m_bid, 0, m_bid - tp_dist, "Apex Aggressor")) {
         last_trade_time = TimeCurrent();
         PrintFormat("🔥 AGGRESSIVE SELL | Gap: %.2f bps", sell_gap_bps);
      }
   }
}
EOF

# ============================================
# ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90

MQL5_DIR=$(find /root/.wine -type d -name "MQL5" | grep "Terminal" | head -n 1)
mkdir -p "$MQL5_DIR/Experts"
cp /root/APEX_AGGRESSOR_V19.mq5 "$MQL5_DIR/Experts/"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$MQL5_DIR/Experts/APEX_AGGRESSOR_V19.mq5"

wine "$MT5_EXE" &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
