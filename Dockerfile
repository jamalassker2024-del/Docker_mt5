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
    libxt6 libxrender1 libxext6 \
    gettext-base \
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
# 4. BOT (ONLY EXECUTION FIX APPLIED)
# ============================================
RUN cat > /root/OFI_Tick_Bot.mq5 << 'EOF'
#property strict

input double   LotSize = 0.01;
input int      OFIThreshold = 2;
input int      LookbackTicks = 20;
input int      TakeProfitPips = 3;
input int      StopLossPips = 2;
input int      MaxSpreadPips = 2;
input int      CooldownSeconds = 0;
input int      MaxDailyTrades = 1000;
input int      MaxConcurrentTrades = 10;

struct TickData {
   datetime time;
   double   price;
   bool     isBuy;
   long     volume;
};

TickData tickBuffer[];
int tickCount=0;
datetime lastTradeTime=0;
int dailyTrades=0;
int lastTradeDay=0;

double GetPipValue(){ return (_Digits==3||_Digits==5)?_Point*10:_Point; }

double GetSpreadPips(){
   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   if(ask<=0||bid<=0) return 999;
   return (ask-bid)/GetPipValue();
}

int GetDay(){
   MqlDateTime t; TimeToStruct(TimeCurrent(),t); return t.day;
}

int OnInit(){
   ArrayResize(tickBuffer,LookbackTicks);
   lastTradeDay=GetDay();
   return(INIT_SUCCEEDED);
}

void OnTick(){
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return;

   if(GetDay()!=lastTradeDay){ dailyTrades=0; lastTradeDay=GetDay(); }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol,tick)) return;

   bool isBuyTick = tick.last >= tick.ask;

   int i=tickCount%LookbackTicks;
   tickBuffer[i].price=tick.last;
   tickBuffer[i].isBuy=isBuyTick;
   tickBuffer[i].volume=tick.volume;
   tickCount++;

   if(tickCount<LookbackTicks) return;

   double buyVol=0,sellVol=0;
   for(int j=0;j<LookbackTicks;j++){
      if(tickBuffer[j].isBuy) buyVol+=tickBuffer[j].volume;
      else sellVol+=tickBuffer[j].volume;
   }

   double ofi = (sellVol==0)?99:buyVol/sellVol;

   double last=tickBuffer[(tickCount-1)%LookbackTicks].price;
   double prev=tickBuffer[(tickCount-2)%LookbackTicks].price;

   bool up = last>prev;
   bool down = last<prev;

   if(PositionsTotal()>=MaxConcurrentTrades) return;

   double spread=GetSpreadPips();
   if(spread>MaxSpreadPips) return;

   //================ SAFE EXECUTION =================
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volume = MathMax(LotSize, minLot);
   volume = MathFloor(volume / lotStep) * lotStep;

   int stopLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pip = GetPipValue();
   double minStop = stopLevel * _Point;

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   int fillings[3]={ORDER_FILLING_IOC,ORDER_FILLING_RETURN,ORDER_FILLING_FOK};

   // ================= BUY =================
   if(ofi>=OFIThreshold && up){

      double price=tick.ask;
      double sl = price - MathMax(StopLossPips*pip, minStop + 2*_Point);
      double tp = price + MathMax(TakeProfitPips*pip, minStop + 2*_Point);

      price=NormalizeDouble(price,digits);
      sl=NormalizeDouble(sl,digits);
      tp=NormalizeDouble(tp,digits);

      for(int f=0;f<3;f++){
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);

         req.action=TRADE_ACTION_DEAL;
         req.symbol=_Symbol;
         req.volume=volume;
         req.type=ORDER_TYPE_BUY;
         req.price=price;
         req.sl=sl;
         req.tp=tp;
         req.deviation=20;
         req.magic=777;
         req.type_filling=fillings[f];
         req.type_time=ORDER_TIME_GTC;

         Print("Trying BUY filling:",fillings[f]);

         if(!OrderSend(req,res)){
            Print("Send failed:",GetLastError());
            continue;
         }

         Print("Retcode:",res.retcode," ",res.comment);

         if(res.retcode==TRADE_RETCODE_DONE){
            Print("BUY SUCCESS");
            break;
         }
      }
   }

   // ================= SELL =================
   if(ofi<=1.0/OFIThreshold && down){

      double price=tick.bid;
      double sl = price + MathMax(StopLossPips*pip, minStop + 2*_Point);
      double tp = price - MathMax(TakeProfitPips*pip, minStop + 2*_Point);

      price=NormalizeDouble(price,digits);
      sl=NormalizeDouble(sl,digits);
      tp=NormalizeDouble(tp,digits);

      for(int f=0;f<3;f++){
         MqlTradeRequest req; MqlTradeResult res;
         ZeroMemory(req); ZeroMemory(res);

         req.action=TRADE_ACTION_DEAL;
         req.symbol=_Symbol;
         req.volume=volume;
         req.type=ORDER_TYPE_SELL;
         req.price=price;
         req.sl=sl;
         req.tp=tp;
         req.deviation=20;
         req.magic=777;
         req.type_filling=fillings[f];
         req.type_time=ORDER_TIME_GTC;

         Print("Trying SELL filling:",fillings[f]);

         if(!OrderSend(req,res)){
            Print("Send failed:",GetLastError());
            continue;
         }

         Print("Retcode:",res.retcode," ",res.comment);

         if(res.retcode==TRADE_RETCODE_DONE){
            Print("SELL SUCCESS");
            break;
         }
      }
   }
}
EOF

# ============================================
# ENTRYPOINT (UNCHANGED)
# ============================================
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
