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
# 4. AGGRESSIVE OFI v5 EA - YOUR STRATEGY
# ============================================
RUN cat > /root/AggressiveOFI_v5.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                           AggressiveOFI_v5.mq5   |
//|                         Order Flow Imbalance - High Frequency    |
//+------------------------------------------------------------------+
#include <Trade\Trade.mqh>

#property copyright "Expert Assistant"
#property version   "5.00"
#property strict

//--- INPUTS
input double InpLotSize      = 0.1;      // Trade Volume
input int    InpOFIThreshold = 50;       // Imbalance to trigger (lower = more trades)
input int    InpTP           = 15;       // Take Profit (Points)
input int    InpSL           = 40;       // Stop Loss (Points)
input int    InpMaxOrders    = 5;        // Concurrent positions for 50+/hr
input int    InpMagic        = 555001;

//--- GLOBALS
CTrade      trade;
MqlTick     curr_t, prev_t;
bool        first_tick = true;

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    
    // Auto-detect Filling Mode
    uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
    else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
    else trade.SetTypeFilling(ORDER_FILLING_RETURN);
    
    Print("OFI Scalper Online. Threshold: ", InpOFIThreshold);
    return(INIT_SUCCEEDED);
}

void OnTick() {
    // Validate Tick and Price
    if(!SymbolInfoTick(_Symbol, curr_t)) return;
    if(curr_t.bid <= 0 || curr_t.ask <= 0) return;

    if(first_tick) {
        prev_t = curr_t;
        first_tick = false;
        return;
    }

    //--- OFI CALCULATION
    long delta_bid = 0;
    if(curr_t.bid > prev_t.bid) delta_bid = (long)curr_t.bid_volume;
    else if(curr_t.bid < prev_t.bid) delta_bid = -(long)prev_t.bid_volume;
    else delta_bid = (long)curr_t.bid_volume - (long)prev_t.bid_volume;

    long delta_ask = 0;
    if(curr_t.ask < prev_t.ask) delta_ask = (long)curr_t.ask_volume;
    else if(curr_t.ask > prev_t.ask) delta_ask = -(long)prev_t.ask_volume;
    else delta_ask = (long)curr_t.ask_volume - (long)prev_t.ask_volume;

    long ofi = delta_bid - delta_ask;
    
    // Count current positions
    int total = 0;
    for(int i=PositionsTotal()-1; i>=0; i--)
        if(PositionSelectByTicket(PositionGetTicket(i)))
            if(PositionGetInteger(POSITION_MAGIC)==InpMagic) total++;

    //--- AGGRESSIVE EXECUTION
    if(total < InpMaxOrders) {
        if(ofi >= InpOFIThreshold) {
            double sl = curr_t.bid - InpSL * _Point;
            double tp = curr_t.ask + InpTP * _Point;
            trade.Buy(InpLotSize, _Symbol, curr_t.ask, sl, tp, "OFI Buy");
        }
        else if(ofi <= -InpOFIThreshold) {
            double sl = curr_t.ask + InpSL * _Point;
            double tp = curr_t.bid - InpTP * _Point;
            trade.Sell(InpLotSize, _Symbol, curr_t.bid, sl, tp, "OFI Sell");
        }
    }
    prev_t = curr_t;
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 5. CREATE INSTALL SCRIPT
# ============================================
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "Installing AggressiveOFI_v5 EA"
echo "=========================================="

# Find all MQL5 directories
MQL5_DIRS=$(find /root/.wine -type d -name "MQL5" 2>/dev/null)

if [ -z "$MQL5_DIRS" ]; then
    echo "No MQL5 directories found! Creating default..."
    mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    cp /root/AggressiveOFI_v5.mq5 "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/AggressiveOFI_v5.mq5"
else
    for dir in $MQL5_DIRS; do
        echo "Installing to: $dir/Experts/"
        mkdir -p "$dir/Experts"
        cp /root/AggressiveOFI_v5.mq5 "$dir/Experts/AggressiveOFI_v5.mq5"
        
        # Try to compile with metaeditor if found
        EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
        if [ -f "$EDITOR" ]; then
            echo "Compiling in: $dir"
            wine "$EDITOR" /compile:"$dir/Experts/AggressiveOFI_v5.mq5" /log:"/root/compile.log" 2>&1
        fi
    done
fi

echo "=========================================="
echo "EA installation complete!"
echo "Look for 'AggressiveOFI_v5' in MT5 Navigator"
echo "=========================================="
EOF

RUN chmod +x /root/install_ea.sh

# ============================================
# 6. ENTRYPOINT
# ============================================
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e

echo "=========================================="
echo "AGGRESSIVE OFI v5 - HIGH FREQUENCY"
echo "=========================================="

# Cleanup
rm -rf /tmp/.X*

# Start X11
Xvfb :1 -screen 0 1280x800x16 -ac &
sleep 2

fluxbox &
sleep 1

x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc 8080 localhost:5900 &

# Initialize Wine
wineboot --init
sleep 5

# Install MT5 if needed
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5_EXE" ]; then
    echo "Installing MT5 (first time setup)..."
    wine /root/mt5setup.exe /auto
    sleep 90
fi

echo "Starting MT5..."
wine "$MT5_EXE" &
sleep 45

# Install the EA
echo ""
echo "=========================================="
echo "INSTALLING EXPERT ADVISOR"
echo "=========================================="
bash /root/install_ea.sh
echo ""

# Start the bridge
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo ""
echo "=========================================="
echo "AGGRESSIVE OFI BOT READY!"
echo "=========================================="
echo ""
echo "STRATEGY SETTINGS:"
echo "  - Lot Size: 0.1"
echo "  - OFI Threshold: 50 (lower = more trades)"
echo "  - TP: 15 points | SL: 40 points"
echo "  - Max Orders: 5 concurrent"
echo ""
echo "TO USE THE BOT:"
echo "1. Open your browser to the VNC URL"
echo "2. Login to Valetutax in MT5"
echo "3. Press Ctrl+N to open Navigator"
echo "4. Right-click 'Expert Advisors' and select 'Refresh'"
echo "5. Look for 'AggressiveOFI_v5' in the list"
echo "6. Drag 'AggressiveOFI_v5' to any chart (BTCUSD.vx, EURUSD, etc.)"
echo "7. Click 'OK' on the settings dialog"
echo "8. Click the 'Auto-Trading' button (or press Alt+T)"
echo ""
echo "The bot will start trading immediately when OFI threshold is met"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
