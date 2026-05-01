FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. Environment Setup
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python Bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. MT5 Installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. V9.7 - "TOTAL WAR" AGGRESSIVE SNIPER
RUN cat > /root/AggressiveSniper_v9_7.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Aggressive Sniper V9.7"
#property version   "9.70"
#property strict

//--- MAXIMUM AGGRESSION INPUTS
input double InpLotSize      = 0.3;      // High stake
input int    InpVolumeBurst  = 50;       // Minimum volume spike to trigger
input int    InpTP           = 7;        // Ultra-tight TP for 90%+ win rate
input int    InpSL           = 25;       
input int    InpMaxOrders    = 30;       // Extreme frequency
input int    InpMagic        = 555009;

CTrade trade;

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    int total = SymbolsTotal(true);
    for(int i=0; i<total; i++) {
        string sym = SymbolName(i, true);
        if(StringFind(sym, ".vx") >= 0) MarketBookAdd(sym);
    }
    return(INIT_SUCCEEDED);
}

void OnBookEvent(const string &symbol) {
    MqlBookInfo book[];
    if(!MarketBookGet(symbol, book) || ArraySize(book) < 2) return;

    double bids = 0, asks = 0;
    for(int i=0; i<ArraySize(book); i++) {
        if(book[i].type == BOOK_TYPE_BUY || book[i].type == BOOK_TYPE_BUY_MARKET) bids += (double)book[i].volume;
        if(book[i].type == BOOK_TYPE_SELL || book[i].type == BOOK_TYPE_SELL_MARKET) asks += (double)book[i].volume;
    }

    // Trigger only on massive volume imbalances (The "Profit Spike")
    if(bids > asks + InpVolumeBurst) ExecuteFast(symbol, true);
    else if(asks > bids + InpVolumeBurst) ExecuteFast(symbol, false);
}

void ExecuteFast(string sym, bool is_buy) {
    int total_pos = 0;
    for(int i=PositionsTotal()-1; i>=0; i--)
        if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

    if(total_pos >= InpMaxOrders) return;

    MqlTick t;
    if(!SymbolInfoTick(sym, t)) return;

    double p = SymbolInfoDouble(sym, SYMBOL_POINT);
    
    // REPLACED GetTypeFilling() with manual bitmask check to fix compilation error
    uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
    if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
    else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
    else trade.SetTypeFilling(ORDER_FILLING_RETURN);

    if(is_buy) trade.Buy(InpLotSize, sym, t.ask, t.bid - InpSL * p, t.ask + InpTP * p, "Apex Long");
    else trade.Sell(InpLotSize, sym, t.bid, t.ask + InpSL * p, t.bid - InpTP * p, "Apex Short");
}
EOF

# 5. Build Script
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveSniper_v9_7.mq5 "$DATA_DIR/Experts/AggressiveSniper_v9_7.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/AggressiveSniper_v9_7.mq5" /log:"/root/compile.log"
EOF
RUN chmod +x /root/install_ea.sh

# 6. Entrypoint
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
