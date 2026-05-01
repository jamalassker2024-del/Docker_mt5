FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc

RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# V8 - THE "ULTRA-SENSITIVE" DOM TRIGGER
# ============================================
RUN cat > /root/AggressiveDOM_v8.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Ultra HFT DOM"
#property version   "8.00"
#property strict

input double InpLotSize      = 0.1;
input double InpDOMThreshold = 1.01;     // EXTREME: 1% imbalance triggers trade
input int    InpTP           = 10;       // Tighter for faster exits
input int    InpSL           = 30;
input int    InpMaxOrders    = 20;       
input int    InpMagic        = 555008;

CTrade trade;

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    int total = SymbolsTotal(true);
    for(int i=0; i<total; i++) {
        string sym = SymbolName(i, true);
        if(StringFind(sym, ".vx") >= 0) {
            if(!MarketBookAdd(sym)) Print("FAILED to subscribe to: ", sym);
            else Print("Subscribed to DOM: ", sym);
        }
    }
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    int total = SymbolsTotal(true);
    for(int i=0; i<total; i++) MarketBookRelease(SymbolName(i, true));
}

// OnBookEvent is 10x faster than OnTimer for DOM trading
void OnBookEvent(const string &symbol) {
    if(StringFind(symbol, ".vx") < 0) return;

    MqlBookInfo book[];
    if(!MarketBookGet(symbol, book) || ArraySize(book) == 0) {
        // Uncomment the line below only for debugging
        // Print("DEBUG: Book empty for ", symbol);
        return;
    }

    double bids = 0, asks = 0;
    for(int i=0; i<ArraySize(book); i++) {
        if(book[i].type == BOOK_TYPE_BUY || book[i].type == BOOK_TYPE_BUY_MARKET) bids += (double)book[i].volume;
        if(book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET) asks += (double)book[i].volume;
    }

    if(bids == 0 || asks == 0) return;

    double buy_ratio = bids / asks;
    double sell_ratio = asks / bids;

    if(buy_ratio >= InpDOMThreshold || sell_ratio >= InpDOMThreshold) {
        ExecuteHFT(symbol, buy_ratio > sell_ratio);
    }
}

void ExecuteHFT(string sym, bool is_buy) {
    int total_pos = 0;
    for(int i=PositionsTotal()-1; i>=0; i--)
        if(PositionSelectByTicket(PositionGetTicket(i)))
            if(PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

    if(total_pos >= InpMaxOrders) return;

    MqlTick t;
    if(!SymbolInfoTick(sym, t)) return;
    
    double p = SymbolInfoDouble(sym, SYMBOL_POINT);
    uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
    trade.SetTypeFilling(((filling & SYMBOL_FILLING_FOK) != 0) ? ORDER_FILLING_FOK : ORDER_FILLING_IOC);

    if(is_buy) trade.Buy(InpLotSize, sym, t.ask, t.bid - InpSL * p, t.ask + InpTP * p, "V8 Buy");
    else trade.Sell(InpLotSize, sym, t.bid, t.ask + InpSL * p, t.bid - InpTP * p, "V8 Sell");
}
EOF

RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveDOM_v8.mq5 "$DATA_DIR/Experts/AggressiveDOM_v8.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/AggressiveDOM_v8.mq5" /log:"/root/compile.log"
EOF
RUN chmod +x /root/install_ea.sh

RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
Xvfb :1 -screen 0 1280x800x16 -ac &
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
bash /root/install_ea.sh
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
