FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. Install Wine and Desktop Environment
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. MT5 installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. AGGRESSIVE DOM SCALPER v7 EA
RUN cat > /root/AggressiveDOM_v7.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Aggressive DOM Scalper"
#property version   "7.00"
#property strict

//--- INPUTS
input double InpLotSize      = 0.1;
input double InpDOMThreshold = 1.1;      // Ratio set to 1.1 for extreme aggression (10% imbalance)
input int    InpTP           = 12;       
input int    InpSL           = 30;
input int    InpMaxOrders    = 15;       // Increased concurrent orders for HFT volume
input int    InpMagic        = 555002;

struct SymbolState {
    string name;
};

CTrade trade;
SymbolState monitored_symbols[];

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    int total = SymbolsTotal(true);
    int count = 0;
    
    for(int i=0; i<total; i++) {
        string sym = SymbolName(i, true);
        if(StringFind(sym, ".vx") >= 0) {
            MarketBookAdd(sym); 
            ArrayResize(monitored_symbols, count + 1);
            monitored_symbols[count].name = sym;
            count++;
        }
    }
    
    Print("HFT DOM Scalper Online. Watching ", count, " symbols.");
    EventSetMillisecondTimer(50); 
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    for(int i=0; i<ArraySize(monitored_symbols); i++) MarketBookRelease(monitored_symbols[i].name);
    EventKillTimer();
}

void OnTimer() {
    for(int i=0; i<ArraySize(monitored_symbols); i++) {
        ProcessDOM(monitored_symbols[i].name);
    }
}

void ProcessDOM(string sym) {
    MqlBookInfo book[];
    if(!MarketBookGet(sym, book)) return;

    double total_bid_vol = 0;
    double total_ask_vol = 0;

    for(int i=0; i<ArraySize(book); i++) {
        if(book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET)
            total_ask_vol += (double)book[i].volume;
        if(book[i].type == BOOK_TYPE_BUY || book[i].type == BOOK_TYPE_BUY_MARKET)
            total_bid_vol += (double)book[i].volume;
    }

    if(total_ask_vol == 0 || total_bid_vol == 0) return;

    double buy_pressure = total_bid_vol / total_ask_vol;
    double sell_pressure = total_ask_vol / total_bid_vol;

    int total_pos = 0;
    for(int j=PositionsTotal()-1; j>=0; j--)
        if(PositionSelectByTicket(PositionGetTicket(j)))
            if(PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

    if(total_pos < InpMaxOrders) {
        MqlTick last_tick;
        SymbolInfoTick(sym, last_tick);
        double point = SymbolInfoDouble(sym, SYMBOL_POINT);
        uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
        trade.SetTypeFilling(((filling & SYMBOL_FILLING_FOK) != 0) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC);

        if(buy_pressure >= InpDOMThreshold) {
            trade.Buy(InpLotSize, sym, last_tick.ask, last_tick.bid - InpSL * point, last_tick.ask + InpTP * point, "HFT DOM Buy");
        }
        else if(sell_pressure >= InpDOMThreshold) {
            trade.Sell(InpLotSize, sym, last_tick.bid, last_tick.ask + InpSL * point, last_tick.bid - InpTP * point, "HFT DOM Sell");
        }
    }
}
EOF

# 5. Install script (Hashed Data Folder Support)
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveDOM_v7.mq5 "$DATA_DIR/Experts/AggressiveDOM_v7.mq5"
EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$EDITOR" ]; then
    wine "$EDITOR" /compile:"$DATA_DIR/Experts/AggressiveDOM_v7.mq5" /log:"/root/compile.log" 2>&1
fi
EOF
RUN chmod +x /root/install_ea.sh

# 6. Entrypoint
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    wine /root/mt5setup.exe /auto
    sleep 90
fi
wine "$MT5_EXE" &
sleep 30 
bash /root/install_ea.sh
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
