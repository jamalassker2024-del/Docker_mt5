FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. FAST + LIGHT WINE ENV
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. Python bridge
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. MT5 installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. MULTI-SYMBOL AGGRESSIVE OFI v6
# ============================================
RUN cat > /root/AggressiveOFI_Multi.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Multi-Symbol OFI Scalper"
#property version   "6.00"
#property strict

//--- INPUTS
input double InpLotSize      = 0.1;
input int    InpOFIThreshold = 1;
input int    InpTP           = 15;
input int    InpSL           = 40;
input int    InpMaxOrders    = 5;        // Max orders total
input int    InpMagic        = 555001;

// Structure to track tick history per symbol
struct SymbolState {
    string name;
    MqlTick prev_t;
    bool first;
};

CTrade      trade;
SymbolState monitored_symbols[];

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    
    // Scan Market Watch for .vx symbols
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
    
    Print("OFI Multi-Monitor active. Watching ", count, " symbols.");
    
    // Set a high-frequency timer (50ms) to catch micro-moves
    EventSetMillisecondTimer(50);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    EventKillTimer();
}

void OnTimer() {
    for(int i=0; i<ArraySize(monitored_symbols); i++) {
        ProcessOFI(monitored_symbols[i]);
    }
}

void ProcessOFI(SymbolState &state) {
    MqlTick curr_t;
    if(!SymbolInfoTick(state.name, curr_t)) return;
    if(curr_t.bid <= 0 || curr_t.ask <= 0) return;

    if(state.first) {
        state.prev_t = curr_t;
        state.first = false;
        return;
    }

    // Only process if it's a new tick
    if(curr_t.time_msc == state.prev_t.time_msc) return;

    // Calculate Volume Delta
    long v = (long)curr_t.volume_real;
    if(v <= 0) v = (long)curr_t.volume;

    long delta_bid = (curr_t.bid > state.prev_t.bid) ? v : (curr_t.bid < state.prev_t.bid ? -v : 0);
    long delta_ask = (curr_t.ask < state.prev_t.ask) ? v : (curr_t.ask > state.prev_t.ask ? -v : 0);
    long ofi = delta_bid - delta_ask;

    // Check Global Position Count
    int total_pos = 0;
    for(int j=PositionsTotal()-1; j>=0; j--)
        if(PositionSelectByTicket(PositionGetTicket(j)))
            if(PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

    if(total_pos < InpMaxOrders) {
        double point = SymbolInfoDouble(state.name, SYMBOL_POINT);
        int digits = (int)SymbolInfoInteger(state.name, SYMBOL_DIGITS);
        
        // Dynamic Filling Mode
        uint filling = (uint)SymbolInfoInteger(state.name, SYMBOL_FILLING_MODE);
        if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
        else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
        else trade.SetTypeFilling(ORDER_FILLING_RETURN);

        if(ofi >= InpOFIThreshold) {
            double sl = curr_t.bid - InpSL * point;
            double tp = curr_t.ask + InpTP * point;
            trade.Buy(InpLotSize, state.name, curr_t.ask, sl, tp, "OFI Multi-Buy");
        }
        else if(ofi <= -InpOFIThreshold) {
            double sl = curr_t.ask + InpSL * point;
            double tp = curr_t.bid - InpTP * point;
            trade.Sell(InpLotSize, state.name, curr_t.bid, sl, tp, "OFI Multi-Sell");
        }
    }
    state.prev_t = curr_t;
}
EOF

# ============================================
# 5. FIXED INSTALL SCRIPT
# ============================================
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveOFI_Multi.mq5 "$DATA_DIR/Experts/AggressiveOFI_Multi.mq5"
EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$EDITOR" ]; then
    wine "$EDITOR" /compile:"$DATA_DIR/Experts/AggressiveOFI_Multi.mq5" /log:"/root/compile.log" 2>&1
fi
EOF

RUN chmod +x /root/install_ea.sh

# ============================================
# 6. ENTRYPOINT
# ============================================
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
