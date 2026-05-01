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
# 4. AGGRESSIVE OFI v5 EA - FIXED IDENTIFIERS
# ============================================
RUN cat > /root/AggressiveOFI_v5.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Expert Assistant"
#property version   "5.01"
#property strict

input double InpLotSize      = 0.1;
input int    InpOFIThreshold = 50;
input int    InpTP           = 15;
input int    InpSL           = 40;
input int    InpMaxOrders    = 5;
input int    InpMagic        = 555001;

CTrade      trade;
MqlTick     curr_t, prev_t;
bool        first_tick = true;

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
    else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
    else trade.SetTypeFilling(ORDER_FILLING_RETURN);
    return(INIT_SUCCEEDED);
}

void OnTick() {
    if(!SymbolInfoTick(_Symbol, curr_t)) return;
    if(curr_t.bid <= 0 || curr_t.ask <= 0) return;
    if(first_tick) { prev_t = curr_t; first_tick = false; return; }

    // Use volume_real for OFI calculations (standard for MQL5 MqlTick)
    long v = (long)curr_t.volume_real;
    if(v <= 0) v = (long)curr_t.volume; // Fallback to standard volume

    long delta_bid = (curr_t.bid > prev_t.bid) ? v : (curr_t.bid < prev_t.bid ? -v : 0);
    long delta_ask = (curr_t.ask < prev_t.ask) ? v : (curr_t.ask > prev_t.ask ? -v : 0);
    long ofi = delta_bid - delta_ask;
    
    int total = 0;
    for(int i=PositionsTotal()-1; i>=0; i--)
        if(PositionSelectByTicket(PositionGetTicket(i)))
            if(PositionGetInteger(POSITION_MAGIC)==InpMagic) total++;

    if(total < InpMaxOrders) {
        if(ofi >= InpOFIThreshold) trade.Buy(InpLotSize, _Symbol, curr_t.ask, curr_t.bid - InpSL * _Point, curr_t.ask + InpTP * _Point, "OFI Buy");
        else if(ofi <= -InpOFIThreshold) trade.Sell(InpLotSize, _Symbol, curr_t.bid, curr_t.ask + InpSL * _Point, curr_t.bid - InpTP * _Point, "OFI Sell");
    }
    prev_t = curr_t;
}
EOF

# ============================================
# 5. FIXED INSTALL SCRIPT
# ============================================
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
echo "Locating MT5 Data Folder..."
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)

if [ -z "$DATA_DIR" ]; then
    echo "Hashed folder not found. Falling back to default Program Files..."
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

echo "Installing EA to: $DATA_DIR/Experts/"
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveOFI_v5.mq5 "$DATA_DIR/Experts/AggressiveOFI_v5.mq5"

EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$EDITOR" ]; then
    echo "Compiling EA..."
    wine "$EDITOR" /compile:"$DATA_DIR/Experts/AggressiveOFI_v5.mq5" /log:"/root/compile.log" 2>&1
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

echo "Starting MT5..."
wine "$MT5_EXE" &
sleep 30 

bash /root/install_ea.sh
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
