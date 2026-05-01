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
# 4. MULTI-PAIR AGGRESSIVE OFI EA
# ============================================
RUN cat > /root/MultiOFI_VX.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Multi-Pair OFI Scalper"
#property version   "6.00"
#property strict

//--- INPUTS
input double InpLotSize      = 0.1;
input int    InpOFIThreshold = 2;        // Lowered so it actually triggers on CFD volumes
input int    InpTP           = 15;
input int    InpSL           = 40;
input int    InpMaxOrders    = 2;        // Max orders PER SYMBOL
input int    InpMagic        = 555001;

CTrade trade;

// Structure to track data for each pair separately
struct SymbolData {
    string name;
    MqlTick prev_t;
    bool first_tick;
};

SymbolData symbols[];

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    
    // 1. Scan and load all .vx symbols into the array
    int total_symbols = SymbolsTotal(false);
    int count = 0;
    
    for(int i=0; i<total_symbols; i++) {
        string sym = SymbolName(i, false);
        if(StringFind(sym, ".vx") >= 0) {
            SymbolSelect(sym, true); // Force into Market Watch
            ArrayResize(symbols, count + 1);
            symbols[count].name = sym;
            symbols[count].first_tick = true;
            count++;
        }
    }
    
    Print("Loaded ", count, " .vx symbols. Starting 50ms High-Frequency Scanner.");
    
    // 2. Start high-frequency timer instead of waiting for OnTick
    EventSetMillisecondTimer(50); 
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
    EventKillTimer();
}

void OnTimer() {
    // Loop through every .vx symbol and check for OFI triggers
    for(int i=0; i<ArraySize(symbols); i++) {
        ProcessSymbol(i);
    }
}

void ProcessSymbol(int idx) {
    string sym = symbols[idx].name;
    MqlTick curr_t;

    if(!SymbolInfoTick(sym, curr_t)) return;
    if(curr_t.bid <= 0 || curr_t.ask <= 0) return;

    if(symbols[idx].first_tick) {
        symbols[idx].prev_t = curr_t;
        symbols[idx].first_tick = false;
        return;
    }

    // Skip if there's no new tick data
    if(curr_t.time_msc == symbols[idx].prev_t.time_msc) return;

    // OFI LOGIC INTACT
    long v = (long)curr_t.volume_real;
    if(v <= 0) v = (long)curr_t.volume;

    long delta_bid = (curr_t.bid > symbols[idx].prev_t.bid) ? v : (curr_t.bid < symbols[idx].prev_t.bid ? -v : 0);
    long delta_ask = (curr_t.ask < symbols[idx].prev_t.ask) ? v : (curr_t.ask > symbols[idx].prev_t.ask ? -v : 0);
    long ofi = delta_bid - delta_ask;
    
    // Count open positions specifically for THIS symbol
    int total = 0;
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC)==InpMagic && PositionGetString(POSITION_SYMBOL)==sym) {
                total++;
            }
        }
    }

    if(total < InpMaxOrders && ofi != 0) {
        // Dynamically set filling mode per symbol
        uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
        if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
        else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
        else trade.SetTypeFilling(ORDER_FILLING_RETURN);

        double point = SymbolInfoDouble(sym, SYMBOL_POINT);

        // EXECUTE
        if(ofi >= InpOFIThreshold) {
            trade.Buy(InpLotSize, sym, curr_t.ask, curr_t.bid - InpSL * point, curr_t.ask + InpTP * point, "OFI Buy");
        }
        else if(ofi <= -InpOFIThreshold) {
            trade.Sell(InpLotSize, sym, curr_t.bid, curr_t.ask + InpSL * point, curr_t.bid - InpTP * point, "OFI Sell");
        }
    }
    
    symbols[idx].prev_t = curr_t;
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
cp /root/MultiOFI_VX.mq5 "$DATA_DIR/Experts/MultiOFI_VX.mq5"

EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$EDITOR" ]; then
    echo "Compiling EA..."
    wine "$EDITOR" /compile:"$DATA_DIR/Experts/MultiOFI_VX.mq5" /log:"/root/compile.log" 2>&1
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
