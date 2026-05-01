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

# 4. V9.6 - AGGRESSIVE APEX SCALPER (DOM + VELOCITY HYBRID)
RUN cat > /root/AggressiveApex_v9_6.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Aggressive Apex V9.6"
#property version   "9.60"
#property strict

//--- AGGRESSION SETTINGS
input double InpLotSize      = 0.2;      // Doubled for aggressiveness
input double InpMinVelocity  = 1.5;      // Points moved to trigger "Aggression"
input int    InpTP           = 8;        // Sniper TP for high win-rate
input int    InpSL           = 20;       // Tighter SL for profitability
input int    InpMaxOrders    = 20;       // Extreme aggressiveness
input int    InpMagic        = 555009;

CTrade trade;
double last_tick_price = 0;

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    int total = SymbolsTotal(true);
    for(int i=0; i<total; i++) {
        string sym = SymbolName(i, true);
        if(StringFind(sym, ".vx") >= 0) MarketBookAdd(sym);
    }
    return(INIT_SUCCEEDED);
}

void OnTick() {
    string sym = _Symbol;
    MqlTick t;
    if(!SymbolInfoTick(sym, t)) return;

    double p = SymbolInfoDouble(sym, SYMBOL_POINT);
    if(last_tick_price == 0) { last_tick_price = t.bid; return; }

    // 1. VELOCITY CHECK (How fast is it moving?)
    double velocity = (t.bid - last_tick_price) / p;
    last_tick_price = t.bid;

    // 2. VOLUME CHECK (OFI Fallback)
    MqlBookInfo book[];
    double ofi_ratio = 1.0;
    if(MarketBookGet(sym, book) && ArraySize(book) > 0) {
        double bids=0, asks=0;
        for(int i=0; i<ArraySize(book); i++) {
            if(book[i].type <= 2) bids += (double)book[i].volume; else asks += (double)book[i].volume;
        }
        if(asks > 0) ofi_ratio = bids/asks;
    }

    // AGGRESSIVE TRIGGER: If velocity > threshold AND flow is in the same direction
    if(velocity >= InpMinVelocity && ofi_ratio >= 0.8) ExecuteApex(sym, true, t, p);
    else if(velocity <= -InpMinVelocity && ofi_ratio <= 1.2) ExecuteApex(sym, false, t, p);
}

void ExecuteApex(string sym, bool is_buy, MqlTick &t, double p) {
    int total_pos = 0;
    for(int i=PositionsTotal()-1; i>=0; i--)
        if(PositionSelectByTicket(PositionGetTicket(i)) && PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

    if(total_pos >= InpMaxOrders) return;

    // Fast-Cycle Filling Logic
    trade.SetTypeFilling((ENUM_ORDER_TYPE_FILLING)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE));
    if(trade.GetTypeFilling() == 0) trade.SetTypeFilling(ORDER_FILLING_IOC);

    if(is_buy) trade.Buy(InpLotSize, sym, t.ask, t.bid - InpSL * p, t.ask + InpTP * p);
    else trade.Sell(InpLotSize, sym, t.bid, t.ask + InpSL * p, t.bid - InpTP * p);
}
EOF

# 5. Build/Install Logic
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveApex_v9_6.mq5 "$DATA_DIR/Experts/AggressiveApex_v9_6.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/AggressiveApex_v9_6.mq5" /log:"/root/compile.log"
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
