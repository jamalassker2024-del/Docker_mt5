FROM python:3.11-slim-bookworm

USER root
ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. Environment Setup + STABILITY TOOLS
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python Bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. MT5 Installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. EA LOGIC WITH SPREAD FILTER
RUN cat > /root/PulseSniper_v11.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Pulse Sniper V11.0"
#property version   "11.00"
#property strict

//--- AGGRESSIVE INPUTS
input double InpLotSize      = 0.2;
input int    InpOFIThreshold = 1;
input int    InpTP           = 12;
input int    InpSL           = 30;
input int    InpMaxOrders    = 15;
input int    InpMagic        = 555011;
input double InpMaxSpread    = 2.0;      // NEW: 2-Pip spread filter for testing

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
    EventSetMillisecondTimer(50);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
    for(int i=0; i<ArraySize(monitored_symbols); i++) {
        ProcessPulse(monitored_symbols[i]);
    }
}

void ProcessPulse(SymbolState &state) {
    MqlTick curr_t;
    if(!SymbolInfoTick(state.name, curr_t)) return;

    // --- SPREAD FILTER ---
    double point = SymbolInfoDouble(state.name, SYMBOL_POINT);
    double current_spread = (curr_t.ask - curr_t.bid) / (point * 10); // Convert points to Pips
    if(current_spread > InpMaxSpread) return; // Skip if spread is too wide

    if(state.first) {
        state.prev_t = curr_t;
        state.first = false;
        return;
    }

    if(curr_t.time_msc == state.prev_t.time_msc) return;

    long v = (curr_t.volume_real > 0) ? (long)curr_t.volume_real : (long)curr_t.volume;
    long delta_bid = (curr_t.bid > state.prev_t.bid) ? v : (curr_t.bid < state.prev_t.bid ? -v : 0);
    long delta_ask = (curr_t.ask < state.prev_t.ask) ? v : (curr_t.ask > state.prev_t.ask ? -v : 0);
    long ofi = delta_bid - delta_ask;

    int total_pos = 0;
    for(int j=PositionsTotal()-1; j>=0; j--)
        if(PositionSelectByTicket(PositionGetTicket(j)))
            if(PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

    if(total_pos < InpMaxOrders) {
        uint filling = (uint)SymbolInfoInteger(state.name, SYMBOL_FILLING_MODE);
        if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
        else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
        else trade.SetTypeFilling(ORDER_FILLING_RETURN);

        if(ofi >= InpOFIThreshold) {
            trade.Buy(InpLotSize, state.name, curr_t.ask, curr_t.bid - InpSL*point, curr_t.ask + InpTP*point);
        }
        else if(ofi <= -InpOFIThreshold) {
            trade.Sell(InpLotSize, state.name, curr_t.bid, curr_t.ask + InpSL*point, curr_t.bid - InpTP*point);
        }
    }
    state.prev_t = curr_t;
}
EOF

# 5. Build Script
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/PulseSniper_v11.mq5 "$DATA_DIR/Experts/PulseSniper_v11.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/PulseSniper_v11.mq5" /log:"/root/compile.log"
EOF
RUN chmod +x /root/install_ea.sh

# 6. REINFORCED ENTRYPOINT
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
# Clear old locks to prevent noVNC crash
rm -rf /tmp/.X* /tmp/.vnc/*.log 
# Increase resolution slightly to handle modal windows better
Xvfb :1 -screen 0 1280x1024x24 +extension RANDR & 
sleep 3
fluxbox &
# Use high-performance VNC settings
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 -noxrecord -noxfixes -noxdamage &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
# Start MT5 with optimized Wine memory handling
WINEPRELOADRESERVE=0x10000000 wine "$MT5_EXE" &
sleep 30 
bash /root/install_ea.sh
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
