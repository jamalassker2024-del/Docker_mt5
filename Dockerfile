FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. Install Wine and dependencies
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. MT5 installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. CREATE THE OFI TICK SCALPER
RUN cat > /root/SimpleBot.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "OFI Aggressive Scalper"
#property version   "5.00"
#property strict

//--- INPUT PARAMETERS
input double InpLotSize      = 0.1;      // Trade Volume
input int    InpOFIThreshold = 50;       // Imbalance threshold to trigger trade
input int    InpTP           = 15;       // Take Profit (Points)
input int    InpSL           = 40;       // Stop Loss (Points)
input int    InpMaxOrders    = 3;        // Max concurrent positions
input int    InpMagic        = 555001;

//--- GLOBALS
CTrade      trade;
MqlTick     curr_t, prev_t;
long        accumulated_ofi = 0;
bool        first_tick = true;

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    // Auto-detect filling mode
    uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
    else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
    else trade.SetTypeFilling(ORDER_FILLING_RETURN);
    
    Print("OFI Scalper Initialized. Threshold: ", InpOFIThreshold);
    return(INIT_SUCCEEDED);
}

void OnTick() {
    if(!SymbolInfoTick(_Symbol, curr_t)) return;
    if(curr_t.bid <= 0 || curr_t.ask <= 0) return;

    if(first_tick) {
        prev_t = curr_t;
        first_tick = false;
        return;
    }

    //--- OFI LOGIC (Order Flow Imbalance)
    // Calculate Delta Bid
    long delta_bid = 0;
    if(curr_t.bid > prev_t.bid) delta_bid = (long)curr_t.bid_volume;
    else if(curr_t.bid < prev_t.bid) delta_bid = -(long)prev_t.bid_volume;
    else delta_bid = (long)curr_t.bid_volume - (long)prev_t.bid_volume;

    // Calculate Delta Ask
    long delta_ask = 0;
    if(curr_t.ask < prev_t.ask) delta_ask = (long)curr_t.ask_volume;
    else if(curr_t.ask > prev_t.ask) delta_ask = -(long)prev_t.ask_volume;
    else delta_ask = (long)curr_t.ask_volume - (long)prev_t.ask_volume;

    // Net Imbalance for this tick
    long current_ofi = delta_bid - delta_ask;
    
    // Check positions count
    int total = 0;
    for(int i=PositionsTotal()-1; i>=0; i--)
        if(PositionSelectByTicket(PositionGetTicket(i)))
            if(PositionGetInteger(POSITION_MAGIC)==InpMagic) total++;

    //--- ENTRY LOGIC
    if(total < InpMaxOrders) {
        // Aggressive Buy on Positive OFI spike
        if(current_ofi >= InpOFIThreshold) {
            double sl = curr_t.bid - InpSL * _Point;
            double tp = curr_t.ask + InpTP * _Point;
            trade.Buy(InpLotSize, _Symbol, curr_t.ask, sl, tp, "OFI Buy");
        }
        // Aggressive Sell on Negative OFI spike
        else if(current_ofi <= -InpOFIThreshold) {
            double sl = curr_t.ask + InpSL * _Point;
            double tp = curr_t.bid - InpTP * _Point;
            trade.Sell(InpLotSize, _Symbol, curr_t.bid, sl, tp, "OFI Sell");
        }
    }

    prev_t = curr_t;
}
EOF

# 5. INSTALLER SCRIPT
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
MQL5_DIR=$(find /root/.wine -type d -name "MQL5" | grep "Terminal" | head -n 1)
if [ -z "$MQL5_DIR" ]; then
    MQL5_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi
mkdir -p "$MQL5_DIR/Experts"
cp /root/SimpleBot.mq5 "$MQL5_DIR/Experts/SimpleBot.mq5"
EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$EDITOR" ]; then
    wine "$EDITOR" /compile:"$MQL5_DIR/Experts/SimpleBot.mq5" /log:"/root/compile.log"
fi
EOF

RUN chmod +x /root/install_ea.sh

# 6. ENTRYPOINT
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &
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
