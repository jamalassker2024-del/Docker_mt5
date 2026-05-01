FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. STABLE WINE ENV + PERFORMANCE TOOLS
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. MT5 installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. V12.0 - APEX AGGRESSIVE OFI (TIMER-BASED)
RUN cat > /root/AggressiveOFI_Apex.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Apex Multi-Symbol OFI"
#property version   "12.00"
#property strict

//--- APEX INPUTS
input double InpLotSize      = 0.3;      // Increased for Aggression
input int    InpOFIThreshold = 1;        
input int    InpTP           = 10;       // Scalp TP
input int    InpSL           = 30;       
input int    InpMaxOrders    = 20;       // Aggressive limit
input int    InpMagic        = 555012;
input double InpMaxSpread    = 2.0;      // 2-Pip Limit for Profitability
input bool   InpUseTrailing  = true;     // Ride the winners

struct SymbolState {
    string name;
    MqlTick prev_t;
    bool first;
};

CTrade      trade;
SymbolState monitored_symbols[];

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    int total = SymbolsTotal(true);
    int count = 0;
    for(int i=0; i<total; i++) {
        string sym = SymbolName(i, true);
        if(StringFind(sym, ".vx") >= 0) {
            ArrayResize(monitored_symbols, count + 1);
            monitored_symbols[count].name = sym;
            monitored_symbols[count].first = true;
            count++;
        }
    }
    Print("Apex V12 Active. Watching ", count, " symbols. Spread Limit: ", InpMaxSpread);
    EventSetMillisecondTimer(50);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
    for(int i=0; i<ArraySize(monitored_symbols); i++) {
        ProcessApex(monitored_symbols[i]);
    }
}

void ProcessApex(SymbolState &state) {
    MqlTick curr_t;
    if(!SymbolInfoTick(state.name, curr_t)) return;

    // --- SPREAD & LIQUIDITY FILTER ---
    double point = SymbolInfoDouble(state.name, SYMBOL_POINT);
    double spread_pips = (curr_t.ask - curr_t.bid) / (point * 10);
    if(spread_pips > InpMaxSpread) return; 

    if(state.first) { state.prev_t = curr_t; state.first = false; return; }
    if(curr_t.time_msc == state.prev_t.time_msc) return;

    // --- OFI CALCULATION ---
    long v = (curr_t.volume_real > 0) ? (long)curr_t.volume_real : (long)curr_t.volume;
    long delta_bid = (curr_t.bid > state.prev_t.bid) ? v : (curr_t.bid < state.prev_t.bid ? -v : 0);
    long delta_ask = (curr_t.ask < state.prev_t.ask) ? v : (curr_t.ask > state.prev_t.ask ? -v : 0);
    long ofi = delta_bid - delta_ask;

    int total_pos = 0;
    for(int j=PositionsTotal()-1; j>=0; j--)
        if(PositionSelectByTicket(PositionGetTicket(j)) && PositionGetInteger(POSITION_MAGIC) == InpMagic) {
            total_pos++;
            if(InpUseTrailing) ApplyTrailing(state.name, point);
        }

    if(total_pos < InpMaxOrders) {
        uint filling = (uint)SymbolInfoInteger(state.name, SYMBOL_FILLING_MODE);
        if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
        else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
        else trade.SetTypeFilling(ORDER_FILLING_RETURN);

        if(ofi >= InpOFIThreshold) trade.Buy(InpLotSize, state.name, curr_t.ask, curr_t.bid - InpSL*point, curr_t.ask + InpTP*point);
        else if(ofi <= -InpOFIThreshold) trade.Sell(InpLotSize, state.name, curr_t.bid, curr_t.ask + InpSL*point, curr_t.bid - InpTP*point);
    }
    state.prev_t = curr_t;
}

void ApplyTrailing(string sym, double p) {
    for(int i=PositionsTotal()-1; i>=0; i--) {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket) && PositionGetString(POSITION_SYMBOL) == sym) {
            double price = PositionGetDouble(POSITION_PRICE_CURRENT);
            double open  = PositionGetDouble(POSITION_PRICE_OPEN);
            double sl    = PositionGetDouble(POSITION_SL);
            if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) {
                if(price - open > 5*p && sl < price - 15*p) trade.PositionModify(ticket, price - 10*p, 0);
            } else {
                if(open - price > 5*p && (sl > price + 15*p || sl == 0)) trade.PositionModify(ticket, price + 10*p, 0);
            }
        }
    }
}
EOF

# 5. FIXED INSTALL SCRIPT
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveOFI_Apex.mq5 "$DATA_DIR/Experts/AggressiveOFI_Apex.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/AggressiveOFI_Apex.mq5" /log:"/root/compile.log"
EOF
RUN chmod +x /root/install_ea.sh

# 6. ENTRYPOINT (Stability Fixes for noVNC)
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
# Use a standard 24-bit depth for modal windows
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
# High performance VNC settings to prevent disconnect
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 -noxrecord -noxfixes -noxdamage &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
# Reserve memory for Wine to prevent terminal crash
WINEPRELOADRESERVE=0x10000000 wine "$MT5_EXE" &
sleep 30 
bash /root/install_ea.sh
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
