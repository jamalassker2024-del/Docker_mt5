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
//|                                                Aggressive_Scalper |
//|                                                                  |
//|                     High Win Rate Scalping EA for MT5            |
//|                                    Weighted Signal Scoring System|
//+------------------------------------------------------------------+
#property copyright "Aggressive Scalper"
#property version   "1.00"
#property strict

// --- Input Parameters (Tweak these to adjust aggression) ---
input string   t1 = "====== Trade Settings ======";
input double   RiskPercent        = 1.0;        // Risk per trade (% of equity)
input int      StopLossPoints     = 120;        // Stop Loss (in points = pips*10)
input int      TakeProfitPoints   = 80;         // Take Profit (in points)
input int      MaxConcurrentTrades = 2;         // Max positions at once
input int      MagicNumber        = 20260505;   // Unique EA identifier

input string   t2 = "====== Entry Filters ======";
input int      SignalThreshold    = 75;         // Min signal score (0-100, 70+ = aggressive)
input int      FastMAPeriod       = 9;          // Fast EMA period
input int      SlowMAPeriod       = 21;         // Slow EMA period
input int      RsiPeriod          = 14;         // RSI period
input int      RsiBuyThreshold    = 35;         // RSI below this to consider buy
input int      RsiSellThreshold   = 65;         // RSI above this to consider sell
input int      AtrPeriod          = 14;         // ATR period for volatility filter
input double   MinATRMultiplier   = 0.8;        // Min ATR percentage to avoid choppy markets

input string   t3 = "====== Risk Management ======";
input double   MaxDailyLossPercent = 5.0;       // Max daily drawdown before halt
input bool     UseTrailingStop    = true;       // Enable trailing stop
input int      TrailingStartPoints = 30;        // Trailing activates at this profit (points)
input int      TrailingStepPoints = 10;         // Trailing stop step (points)

// --- Global Variables ---
double   RsiBuffer[];
double   AtrBuffer[];
double   FastEMABuffer[];
double   SlowEMABuffer[];
int      RsiHandle, AtrHandle, FastEMAHandle, SlowEMAHandle;
double   dailyLoss = 0.0;
datetime lastBarTime = 0;
bool     tradingHalted = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   // Initialize indicator handles
   RsiHandle = iRSI(_Symbol, PERIOD_CURRENT, RsiPeriod, PRICE_CLOSE);
   AtrHandle = iATR(_Symbol, PERIOD_CURRENT, AtrPeriod);
   FastEMAHandle = iMA(_Symbol, PERIOD_CURRENT, FastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   SlowEMAHandle = iMA(_Symbol, PERIOD_CURRENT, SlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   
   if(RsiHandle == INVALID_HANDLE || AtrHandle == INVALID_HANDLE ||
      FastEMAHandle == INVALID_HANDLE || SlowEMAHandle == INVALID_HANDLE)
   {
      Print("Error creating indicator handles");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(RsiBuffer, true);
   ArraySetAsSeries(AtrBuffer, true);
   ArraySetAsSeries(FastEMABuffer, true);
   ArraySetAsSeries(SlowEMABuffer, true);
   
   lastBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   tradingHalted = false;
   
   Print("✓ Aggressive Scalper EA initialized on ", _Symbol);
   Print("✓ Signal Threshold: ", SignalThreshold, " | Risk: ", RiskPercent, "% per trade");
   
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // Release indicator handles
   IndicatorRelease(RsiHandle);
   IndicatorRelease(AtrHandle);
   IndicatorRelease(FastEMAHandle);
   IndicatorRelease(SlowEMAHandle);
   
   Print("EA deinitialized. Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function (main trading logic)                        |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Check if trading is halted due to daily loss limit
   if(tradingHalted)
   {
      if(CalculateDailyLoss() < MaxDailyLossPercent)
         tradingHalted = false;
      else
         return;
   }
   
   // 2. Update daily loss tracking
   double dailyLossPercent = CalculateDailyLoss();
   if(dailyLossPercent >= MaxDailyLossPercent) 
   {
      tradingHalted = true;
      Print("Daily loss limit reached (", dailyLossPercent, "%). Trading halted.");
      return;
   }
   
   // 3. Check for new bar (only trade at bar close to reduce noise)
   datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(currentBarTime == lastBarTime) return;
   lastBarTime = currentBarTime;
   
   // 4. Refresh indicator values
   CopyBuffer(RsiHandle, 0, 0, 3, RsiBuffer);
   CopyBuffer(AtrHandle, 0, 0, 3, AtrBuffer);
   CopyBuffer(FastEMAHandle, 0, 0, 3, FastEMABuffer);
   CopyBuffer(SlowEMAHandle, 0, 0, 3, SlowEMABuffer);
   
   double currentRsi = RsiBuffer[0];
   double currentAtr = AtrBuffer[0];
   double fastEMA = FastEMABuffer[0];
   double slowEMA = SlowEMABuffer[0];
   double prevFastEMA = FastEMABuffer[1];
   double prevSlowEMA = SlowEMABuffer[1];
   
   // 5. Count open positions for this symbol
   int posCount = CountOpenPositions();
   if(posCount >= MaxConcurrentTrades) return;
   
   // 6. Calculate signal scores
   double buyScore = CalculateBuyScore(currentRsi, fastEMA, slowEMA, prevFastEMA, prevSlowEMA, currentAtr);
   double sellScore = CalculateSellScore(currentRsi, fastEMA, slowEMA, prevFastEMA, prevSlowEMA, currentAtr);
   
   // 7. Execute trades if threshold met
   if(buyScore >= SignalThreshold)
      ExecuteTrade(ORDER_TYPE_BUY);
   else if(sellScore >= SignalThreshold)
      ExecuteTrade(ORDER_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Calculate buy signal score (0-100)                               |
//+------------------------------------------------------------------+
double CalculateBuyScore(double rsi, double fastEMA, double slowEMA, 
                          double prevFast, double prevSlow, double atr)
{
   double score = 0.0;
   
   // Trend factor: EMA alignment (max 35 points)
   if(fastEMA > slowEMA)
      score += 25;
   // EMA just crossed up?
   if(prevFast <= prevSlow && fastEMA > slowEMA)
      score += 10;
      
   // Momentum factor: RSI condition (max 30 points)
   if(rsi < RsiBuyThreshold)
      score += 30;
   else if(rsi < RsiBuyThreshold + 10)
      score += 15;
   else if(rsi < RsiBuyThreshold + 20)
      score += 5;
   
   // Volatility factor: ATR validation (max 20 points)
   double normalizedATR = atr / _Point / 10;  // ATR in pips approx
   if(normalizedATR > MinATRMultiplier * 5)   // enough movement
      score += 20;
   else if(normalizedATR > MinATRMultiplier * 3)
      score += 10;
      
   // Price action / impulse detection (max 15 points)
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   double open = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double body = close - open;
   if(body > 0 && body > (iHigh(_Symbol, PERIOD_CURRENT, 0) - iLow(_Symbol, PERIOD_CURRENT, 0)) * 0.6)
      score += 15;
   else if(body > 0)
      score += 8;
   
   return score;
}

//+------------------------------------------------------------------+
//| Calculate sell signal score (0-100)                              |
//+------------------------------------------------------------------+
double CalculateSellScore(double rsi, double fastEMA, double slowEMA,
                           double prevFast, double prevSlow, double atr)
{
   double score = 0.0;
   
   // Trend factor: EMA alignment (max 35 points)
   if(fastEMA < slowEMA)
      score += 25;
   if(prevFast >= prevSlow && fastEMA < slowEMA)
      score += 10;
      
   // Momentum factor: RSI condition (max 30 points)
   if(rsi > RsiSellThreshold)
      score += 30;
   else if(rsi > RsiSellThreshold - 10)
      score += 15;
   else if(rsi > RsiSellThreshold - 20)
      score += 5;
   
   // Volatility factor: ATR validation (max 20 points)
   double normalizedATR = atr / _Point / 10;
   if(normalizedATR > MinATRMultiplier * 5)
      score += 20;
   else if(normalizedATR > MinATRMultiplier * 3)
      score += 10;
      
   // Price action: bearish impulse detection (max 15 points)
   double close = iClose(_Symbol, PERIOD_CURRENT, 0);
   double open = iOpen(_Symbol, PERIOD_CURRENT, 0);
   double body = close - open;
   if(body < 0 && -body > (iHigh(_Symbol, PERIOD_CURRENT, 0) - iLow(_Symbol, PERIOD_CURRENT, 0)) * 0.6)
      score += 15;
   else if(body < 0)
      score += 8;
   
   return score;
}

//+------------------------------------------------------------------+
//| Execute a market order                                           |
//+------------------------------------------------------------------+
void ExecuteTrade(int orderType)
{
   MqlTradeRequest request = {};
   MqlTradeResult  result = {};
   
   double price = (orderType == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK) 
                                                 : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = 0, tp = 0;
   
   // Calculate stop loss and take profit
   if(orderType == ORDER_TYPE_BUY)
   {
      sl = price - StopLossPoints * _Point;
      tp = price + TakeProfitPoints * _Point;
   }
   else // SELL
   {
      sl = price + StopLossPoints * _Point;
      tp = price - TakeProfitPoints * _Point;
   }
   
   // Normalize SL/TP to broker requirements
   sl = NormalizeDouble(sl, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   tp = NormalizeDouble(tp, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   
   // Calculate lot size based on risk percentage
   double lotSize = CalculateLotSize(orderType, sl, price);
   if(lotSize <= 0) return;
   
   // Prepare and send order
   request.action     = TRADE_ACTION_DEAL;
   request.symbol     = _Symbol;
   request.volume     = lotSize;
   request.type       = orderType;
   request.price      = price;
   request.sl         = sl;
   request.tp         = tp;
   request.deviation  = 10;
   request.magic      = MagicNumber;
   request.comment    = "Aggressive Scalper";
   request.type_filling = ORDER_FILLING_FOK;
   request.type_time  = ORDER_TIME_GTC;
   
   if(OrderSend(request, result))
   {
      if(result.retcode == TRADE_RETCODE_DONE)
      {
         Print("✓ ORDER EXECUTED | Type: ", (orderType == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               " | Lots: ", lotSize, " | Price: ", price,
               " | SL: ", sl, " | TP: ", tp,
               " | Ticket: ", result.order);
      }
      else
         Print("✗ Order failed | Error: ", result.retcode, " - ", GetLastError());
   }
   else
      Print("✗ Order send error: ", GetLastError());
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk percentage                      |
//+------------------------------------------------------------------+
double CalculateLotSize(int orderType, double slPrice, double entryPrice)
{
   double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double stopDistance = MathAbs(entryPrice - slPrice);
   double pointValue = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double stopInPoints = stopDistance / pointValue;
   
   double lotSize = riskAmount / (stopInPoints * tickValue);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   
   lotSize = MathMax(minLot, MathMin(maxLot, lotSize));
   lotSize = MathRound(lotSize / stepLot) * stepLot;
   
   return lotSize;
}

//+------------------------------------------------------------------+
//| Count open positions for this symbol and magic number            |
//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionSelectByTicket(PositionGetTicket(i)))
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            count++;
      }
   }
   return count;
}

//+------------------------------------------------------------------+
//| Calculate daily loss percentage from peak equity                |
//+------------------------------------------------------------------+
double CalculateDailyLoss()
{
   static double peakEquityToday = 0;
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   
   datetime currentTime = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime midnight = StructToTime(dt);
   
   static datetime lastMidnight = 0;
   if(lastMidnight != midnight)
   {
      peakEquityToday = currentEquity;
      lastMidnight = midnight;
   }
   
   if(currentEquity > peakEquityToday)
      peakEquityToday = currentEquity;
      
   if(peakEquityToday == 0)
      return 0;
      
   double drawdownPercent = (peakEquityToday - currentEquity) / peakEquityToday * 100.0;
   return drawdownPercent;
}

//+------------------------------------------------------------------+
//| Apply trailing stop to existing positions (called in OnTick)    |
//+------------------------------------------------------------------+
void ApplyTrailingStop()
{
   if(!UseTrailingStop) return;
   
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
            PositionGetInteger(POSITION_MAGIC) != MagicNumber)
            continue;
            
         double currentSL = PositionGetDouble(POSITION_SL);
         double currentTP = PositionGetDouble(POSITION_TP);
         double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         double currentPrice = PositionGetDouble(POSITION_TYPE) == POSITION_TYPE_BUY ? 
                               SymbolInfoDouble(_Symbol, SYMBOL_BID) : 
                               SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double profitPoints = (currentPrice - openPrice) / _Point;
         if(PositionGetDouble(POSITION_TYPE) == POSITION_TYPE_SELL)
            profitPoints = -profitPoints;
            
         if(profitPoints >= TrailingStartPoints)
         {
            double newSL = 0;
            if(PositionGetDouble(POSITION_TYPE) == POSITION_TYPE_BUY)
               newSL = currentPrice - TrailingStepPoints * _Point;
            else
               newSL = currentPrice + TrailingStepPoints * _Point;
               
            if(newSL > currentSL)
            {
               MqlTradeRequest req = {};
               MqlTradeResult res = {};
               req.action = TRADE_ACTION_SLTP;
               req.symbol = _Symbol;
               req.position = ticket;
               req.sl = newSL;
               req.tp = currentTP;
               req.magic = MagicNumber;
               OrderSend(req, res);
            }
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
