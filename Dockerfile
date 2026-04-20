
#property copyright "OFI Bot"
#property version   "1.00"
#property strict

//+------------------------------------------------------------------+
//| Input Parameters                                                 |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Global Variables                                                 |
//+------------------------------------------------------------------+
TickData tickBuffer[];
int      tickCount = 0;
datetime lastTradeTime = 0;
int      dailyTrades = 0;
int      lastTradeDay = -1;
double   initialBalance = 0;

//+------------------------------------------------------------------+
//| Helper: Get Day of Month                                         |
//+------------------------------------------------------------------+
int GetDay(datetime date) {
   MqlDateTime tm;
   TimeToStruct(date, tm);
   return tm.day;
}

int OnInit() {
   ArrayResize(tickBuffer, LookbackTicks);
   initialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   lastTradeDay = GetDay(TimeTradeServer());
   
   EventSetTimer(30);
   return(INIT_SUCCEEDED);
}

void OnTick() {
   datetime now = TimeTradeServer();
   
   // Daily reset
   if (GetDay(now) != lastTradeDay) {
      dailyTrades = 0;
      lastTradeDay = GetDay(now);
   }
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
   bool isBuyTick = false;
   // logic to determine aggressor
   if (currentTick.last >= currentTick.ask) isBuyTick = true;
   else if (currentTick.last <= currentTick.bid) isBuyTick = false;
   else {
      static double lastPrice = 0;
      isBuyTick = (currentTick.last > lastPrice);
      lastPrice = currentTick.last;
   }
   
   int idx = tickCount % LookbackTicks;
   tickBuffer[idx].time = currentTick.time;
   tickBuffer[idx].price = currentTick.last;
   tickBuffer[idx].isBuy = isBuyTick;
   tickBuffer[idx].volume = currentTick.tick_volume;  
   
   tickCount++;
   if (tickCount < LookbackTicks) return;
   
   // Calculate OFI every 5 ticks
   static int ticksSinceCalc = 0;
   ticksSinceCalc++;
   if (ticksSinceCalc < 5) return;
   ticksSinceCalc = 0;
   
   double ofiRatio = CalculateOFI();
   
   if (ofiRatio >= (double)OFIThreshold) {
      CheckAndExecuteTrade("BUY", ofiRatio);
   }
   else if (ofiRatio <= 1.0 / (double)OFIThreshold) {
      CheckAndExecuteTrade("SELL", ofiRatio);
   }
}

double CalculateOFI() {
   int buyTicks = 0, sellTicks = 0;
   for (int i = 0; i < LookbackTicks; i++) {
      if (tickBuffer[i].isBuy) buyTicks++;
      else sellTicks++;
   }
   if (sellTicks == 0) return (buyTicks > 0) ? 99.0 : 1.0;
   return (double)buyTicks / (double)sellTicks;
}

void CheckAndExecuteTrade(string action, double ofiRatio) {
   if (dailyTrades >= MaxDailyTrades) return;
   if (TimeTradeServer() - lastTradeTime < CooldownSeconds) return;
   
   // Spread logic
   int spread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if (spread > MaxSpreadPips * 10) return; 
   
   if (PositionSelect(_Symbol)) return;
   
   MqlTick currentTick;
   if(!SymbolInfoTick(_Symbol, currentTick)) return;
   
   double price, tp, sl;
   ENUM_ORDER_TYPE orderType;
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   
   if (action == "BUY") {
      price = currentTick.ask;
      tp = price + (TakeProfitPips * 10 * point);
      sl = price - (StopLossPips * 10 * point);
      orderType = ORDER_TYPE_BUY;
   } else {
      price = currentTick.bid;
      tp = price - (TakeProfitPips * 10 * point);
      sl = price + (StopLossPips * 10 * point);
      orderType = ORDER_TYPE_SELL;
   }
   
   MqlTradeRequest request = {};
   MqlTradeResult result = {};
   
   request.action = TRADE_ACTION_DEAL;
   request.symbol = _Symbol;
   request.volume = LotSize; // Simplified for stability
   request.type = orderType;
   request.price = NormalizeDouble(price, digits);
   request.sl = NormalizeDouble(sl, digits);
   request.tp = NormalizeDouble(tp, digits);
   request.deviation = 10;
   request.magic = 2026;
   request.type_filling = ORDER_FILLING_IOC; 
   request.type_time = ORDER_TIME_GTC;
   
   if (OrderSend(request, result)) {
      if (result.retcode == TRADE_RETCODE_DONE || result.retcode == TRADE_RETCODE_PLACED) {
         dailyTrades++;
         lastTradeTime = TimeTradeServer();
         Print("✅ ", action, " Sent | OFI: ", ofiRatio);
      }
   }
}

void OnTimer() {
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   Print("📊 Balance: $", balance, " | Daily Trades: ", dailyTrades);
}

void OnDeinit(const int reason) {
   EventKillTimer();
}
