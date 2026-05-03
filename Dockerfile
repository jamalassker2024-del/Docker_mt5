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
//|                                       BinanceOrderFlowRouter.mq5 |
//|                                    Purpose: Smart Order Router  |
//|                                    Based on Binance Order Book  |
//+------------------------------------------------------------------+
#property copyright "Omni-Apex"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
input string   BinancePair          = "BTCUSDT";              // Symbol on Binance
input string   userApiKey           = "";                     // Your Binance API Key (optional)
input double   RiskPerTradePercent  = 2.0;                    // Risk per trade (% of equity)
input double   OrderBookImbalanceThreshold = 0.65;            // 0-1. >0.65 = buy, <0.35 = sell
input int      MaxOpenPositions     = 5;                      // Max concurrent trades
input int      MagicNumber          = 777888;                 // EA magic number
input int      OrderBookDepth       = 20;                     // Depth to analyze (top N levels)
input bool     DebugMode            = true;                   // Enable/Disable debug logs

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
CTrade trade;
string baseUrlSpot = "https://api.binance.com/api/v3/";
datetime lastDebugTime = 0;
datetime lastFetchTime = 0;
const int fetchIntervalMs = 5000;  // Fetch Binance data every 5 seconds

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   SymbolSelect(_Symbol, true);
   
   // Check if API key is empty, warn user
   if(StringLen(userApiKey) == 0) {
      Print("WARNING: No Binance API Key provided. Using public endpoints only.");
      Print("For better reliability, please add your Binance API key.");
   }
   
   Print("==============================================");
   Print("🚀 Binance Order Flow Router EA INITIALIZED");
   Print("   Binance Pair: ", BinancePair);
   Print("   MT5 Symbol: ", _Symbol);
   Print("   Imbalance Threshold: ", OrderBookImbalanceThreshold);
   Print("   Order Book Depth: ", OrderBookDepth, " levels");
   Print("   Risk Per Trade: ", RiskPerTradePercent, "% of equity");
   Print("==============================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Helper: WebRequest with better error handling                   |
//+------------------------------------------------------------------+
string WebRequestGet(string url) {
   char post[], result[];
   string headers;
   int res = WebRequest("GET", url, NULL, NULL, 5000, post, 0, result, headers);
   if(res <= 0) {
      Print("❌ WebRequest failed to: ", url, " Error: ", GetLastError());
      return "";
   }
   return CharArrayToString(result);
}

//+------------------------------------------------------------------+
//| Calculate Bid-Ask Ratio from Binance Order Book                 |
//+------------------------------------------------------------------+
double GetOrderBookImbalance() {
   string url = baseUrlSpot + "depth?symbol=" + BinancePair + "&limit=" + IntegerToString(OrderBookDepth);
   string response = WebRequestGet(url);
   if(response == "") return -1.0;  // Failed
    
   // Parse JSON manually (since MQL5 has no native JSON parser)
   double totalBidVol = 0.0, totalAskVol = 0.0;
   
   // Find bids array: "bids":[["price","vol"],...]
   int bidsPos = StringFind(response, "\"bids\":[");
   if(bidsPos >= 0) {
      int startPos = bidsPos + 8; // After "bids":[ 
      int endPos = StringFind(response, "],", startPos);
      if(endPos < 0) endPos = StringFind(response, "]]", startPos);
      if(endPos > startPos) {
         string bidsStr = StringSubstr(response, startPos, endPos - startPos);
         // Parse each bid entry ["price","vol"]
         int searchPos = 0;
         while(searchPos < StringLen(bidsStr)) {
            int volStart = StringFind(bidsStr, ",\"", searchPos);
            if(volStart < 0) break;
            volStart += 2;  // Skip past ',"'
            int volEnd = StringFind(bidsStr, "\"", volStart);
            if(volEnd > volStart) {
               double vol = StringToDouble(StringSubstr(bidsStr, volStart, volEnd - volStart));
               totalBidVol += vol;
            }
            searchPos = volEnd + 1;
         }
      }
   }
   
   // Find asks array: "asks":[["price","vol"],...]
   int asksPos = StringFind(response, "\"asks\":[");
   if(asksPos >= 0) {
      int startPos = asksPos + 8; // After "asks":[ 
      int endPos = StringFind(response, "]]", startPos);
      if(endPos > startPos) {
         string asksStr = StringSubstr(response, startPos, endPos - startPos);
         int searchPos = 0;
         while(searchPos < StringLen(asksStr)) {
            int volStart = StringFind(asksStr, ",\"", searchPos);
            if(volStart < 0) break;
            volStart += 2;
            int volEnd = StringFind(asksStr, "\"", volStart);
            if(volEnd > volStart) {
               double vol = StringToDouble(StringSubstr(asksStr, volStart, volEnd - volStart));
               totalAskVol += vol;
            }
            searchPos = volEnd + 1;
         }
      }
   }
   
   // Apply ratio formula: totalBidVol / (totalBidVol + totalAskVol)
   if(totalBidVol + totalAskVol == 0) return -1.0;
   double ratio = totalBidVol / (totalBidVol + totalAskVol);
   
   if(DebugMode && TimeCurrent() - lastDebugTime >= 5) {
      Print("📊 [Book] BidVol: ", DoubleToString(totalBidVol, 2), 
            " AskVol: ", DoubleToString(totalAskVol, 2),
            " Ratio: ", DoubleToString(ratio, 3));
   }
   return ratio;
}

//+------------------------------------------------------------------+
//| Get Trade Flow Imbalance (Aggressor from recent trades)         |
//| Returns positive for buying pressure, negative for selling      |
//+------------------------------------------------------------------+
double GetTradeFlowImbalance() {
   string url = baseUrlSpot + "trades?symbol=" + BinancePair + "&limit=50";
   string response = WebRequestGet(url);
   if(response == "") return 0.0;
   
   double buyVol = 0.0, sellVol = 0.0;
   
   // Parse trade array, look for "isBuyerMaker":true/false
   // If isBuyerMaker is false → aggressive buy (taker bought from maker)
   // If isBuyerMaker is true → aggressive sell (taker sold to maker)
   int searchPos = 0;
   while(true) {
      int makerPos = StringFind(response, "\"isBuyerMaker\":", searchPos);
      if(makerPos < 0) break;
      int valueStart = makerPos + 16;
      int valueEnd = (StringFind(response, ",\"", valueStart) < 0) ? 
                     StringFind(response, "}", valueStart) : 
                     StringFind(response, ",\"", valueStart);
      if(valueEnd < 0) break;
      string isMaker = StringSubstr(response, valueStart, valueEnd - valueStart);
      
      // Find volume for this trade
      int volPos = StringFind(response, "\"quoteQty\":", searchPos);
      if(volPos < 0) break;
      int volStart = volPos + 11;
      int volEnd = StringFind(response, ",\"", volStart);
      if(volEnd < 0) volEnd = StringFind(response, "}", volStart);
      if(volEnd < 0) break;
      double vol = StringToDouble(StringSubstr(response, volStart, volEnd - volStart));
      
      if(isMaker == "false") buyVol += vol;   // Aggressive buy
      else if(isMaker == "true") sellVol += vol;   // Aggressive sell
      
      searchPos = volEnd + 1;
   }
   
   double totalVol = buyVol + sellVol;
   if(totalVol == 0) return 0.0;
   double netImbalance = (buyVol - sellVol) / totalVol;  // Range -1 to +1
   
   if(DebugMode && TimeCurrent() - lastDebugTime >= 5) {
      Print("📊 [Trades] BuyVol: ", DoubleToString(buyVol, 2), 
            " SellVol: ", DoubleToString(sellVol, 2),
            " Net Imbalance: ", DoubleToString(netImbalance, 3));
   }
   return netImbalance;
}

//+------------------------------------------------------------------+
//| Main Expert Tick Function                                        |
//+------------------------------------------------------------------+
void OnTick() {
   // 1. Close any position with profit > 0 (Fast Out)
   for(int i = PositionsTotal()-1; i >= 0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket) && PositionGetInteger(POSITION_MAGIC) == MagicNumber) {
         double profit = PositionGetDouble(POSITION_PROFIT);
         if(profit > 0.0) {
            if(trade.PositionClose(ticket)) {
               Print("✅ [CLOSE] Ticket ", ticket, " closed with profit: ", profit);
            } else {
               Print("❌ [CLOSE] Failed to close ticket ", ticket);
            }
         }
      }
   }
   
   // 2. Position limit check
   if(PositionsTotal() >= MaxOpenPositions) {
      if(DebugMode && TimeCurrent() - lastDebugTime >= 30) {
         Print("⚠️ Max positions reached: ", PositionsTotal());
      }
      return;
   }
   
   // 3. Fetch Binance data at intervals (not every tick to avoid rate limits)
   if(TimeCurrent() * 1000 - lastFetchTime < fetchIntervalMs) return;
   lastFetchTime = TimeCurrent() * 1000;
   
   // 4. Get both signals
   double bookImbalance = GetOrderBookImbalance();      // Ratio 0-1
   double tradeFlow = GetTradeFlowImbalance();          // Net -1 to +1
   
   if(bookImbalance < 0) {
      Print("❌ Failed to fetch Binance order book data");
      return;
   }
   
   // 5. Determine signal direction
   bool buySignal = false;
   bool sellSignal = false;
   string signalStrength = "none";
   
   // Strong buy: Book ratio > threshold AND trade flow positive
   if(bookImbalance >= OrderBookImbalanceThreshold && tradeFlow > 0.2) {
      buySignal = true;
      signalStrength = "STRONG BUY";
   }
   // Strong sell: Book ratio < (1 - threshold) AND trade flow negative
   else if(bookImbalance <= (1.0 - OrderBookImbalanceThreshold) && tradeFlow < -0.2) {
      sellSignal = true;
      signalStrength = "STRONG SELL";
   }
   // Medium signal: Only one condition met
   else if(bookImbalance >= OrderBookImbalanceThreshold && tradeFlow <= 0.2) {
      buySignal = true;
      signalStrength = "WEAK BUY (book only)";
   }
   else if(bookImbalance <= (1.0 - OrderBookImbalanceThreshold) && tradeFlow >= -0.2) {
      sellSignal = true;
      signalStrength = "WEAK SELL (book only)";
   }
   
   // 6. Debug output
   if(DebugMode) {
      Print("========================================");
      Print("📊 SIGNAL ANALYSIS:");
      Print("   Book Ratio: ", DoubleToString(bookImbalance, 3));
      Print("   Trade Flow: ", DoubleToString(tradeFlow, 3));
      Print("   Signal: ", signalStrength);
      Print("========================================");
   }
   
   // 7. Execute trade based on signal
   if(buySignal || sellSignal) {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double lot = NormalizeDouble(AccountInfoDouble(ACCOUNT_EQUITY) / 1000.0 * (RiskPerTradePercent / 100.0), 2);
      lot = MathMax(0.01, lot);
      
      if(buySignal) {
         if(trade.Buy(lot, _Symbol, ask, 0, 0, "Binance Flow Buy")) {
            Print("🔥 [BUY OPEN] Signal: ", signalStrength, " | Lot: ", lot, " @ ", ask);
         } else {
            Print("❌ [BUY FAIL] Error: ", GetLastError());
         }
      }
      else if(sellSignal) {
         if(trade.Sell(lot, _Symbol, bid, 0, 0, "Binance Flow Sell")) {
            Print("🔥 [SELL OPEN] Signal: ", signalStrength, " | Lot: ", lot, " @ ", bid);
         } else {
            Print("❌ [SELL FAIL] Error: ", GetLastError());
         }
      }
   }
}
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
