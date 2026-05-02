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

# 4. V14.0 - CRYPTO AUTO-SCALING APEX
RUN cat > /root/CryptoApex_v14.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Crypto Apex V14.0"
#property version   "14.00"
#property strict

//--- INPUTS (Points-based for auto-scaling)
input double InpLotSize       = 0.5;      
input int    InpTP_Points     = 150;      // Auto-scales: BTC (1.50) vs DOGE (0.0015)
input int    InpSL_Points     = 400;      
input int    InpMaxOrders     = 20;       
input int    InpMagic         = 555014;
input double InpMaxSpreadPips = 3.0;      
input int    InpLookback      = 15;       // Faster lookback for Crypto Volatility
input double InpPressureRatio = 1.05;    

struct SymbolState {
    string name;
    MqlTick prev_t;
    long buy_v;
    long sell_v;
    int ticks;
    bool first;
};

CTrade      trade;
SymbolState monitored[];

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    int total = SymbolsTotal(true);
    int count = 0;
    for(int i=0; i<total; i++) {
        string sym = SymbolName(i, true);
        if(StringFind(sym, ".vx") >= 0) {
            ArrayResize(monitored, count + 1);
            monitored[count].name = sym;
            monitored[count].buy_v = 0;
            monitored[count].sell_v = 0;
            monitored[count].ticks = 0;
            monitored[count].first = true;
            count++;
        }
    }
    Print("Crypto Apex V14 Active. Scaling for ", count, " symbols.");
    EventSetMillisecondTimer(50);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
    for(int i=0; i<ArraySize(monitored); i++) {
        ProcessCrypto(monitored[i]);
    }
}

void ProcessCrypto(SymbolState &state) {
    MqlTick curr_t;
    if(!SymbolInfoTick(state.name, curr_t)) return;

    double point = SymbolInfoDouble(state.name, SYMBOL_POINT);
    int digits = (int)SymbolInfoInteger(state.name, SYMBOL_DIGITS);
    
    // Spread Check (Scaled for Digits)
    double spread_pips = (curr_t.ask - curr_t.bid) / (point * 10);
    if(spread_pips > InpMaxSpreadPips) return; 

    if(state.first) { state.prev_t = curr_t; state.first = false; return; }
    if(curr_t.time_msc == state.prev_t.time_msc) return;

    // Accumulate Pressure
    long v = (curr_t.volume_real > 0) ? (long)curr_t.volume_real : (long)curr_t.volume;
    if(v == 0) v = 1;

    if(curr_t.bid > state.prev_t.bid) state.buy_v += v;
    if(curr_t.ask < state.prev_t.ask) state.sell_v += v;
    state.ticks++;

    if(state.ticks >= InpLookback) {
        double bP = (double)state.buy_v;
        double sP = (double)state.sell_v;
        
        // Debug Log
        if(bP > 0 || sP > 0)
            PrintFormat("[%s] OFI: Buy %.0f | Sell %.0f | Ratio: %.2f", state.name, bP, sP, (sP>0?bP/sP:bP));

        int total_pos = 0;
        for(int j=PositionsTotal()-1; j>=0; j--)
            if(PositionSelectByTicket(PositionGetTicket(j)) && PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

        if(total_pos < InpMaxOrders) {
            uint filling = (uint)SymbolInfoInteger(state.name, SYMBOL_FILLING_MODE);
            if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
            else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
            else trade.SetTypeFilling(ORDER_FILLING_RETURN);

            if(bP > sP * InpPressureRatio) {
                trade.Buy(InpLotSize, state.name, curr_t.ask, curr_t.bid - InpSL_Points*point, curr_t.ask + InpTP_Points*point);
            }
            else if(sP > bP * InpPressureRatio) {
                trade.Sell(InpLotSize, state.name, curr_t.bid, curr_t.ask + InpSL_Points*point, curr_t.bid - InpTP_Points*point);
            }
        }
        state.buy_v = 0; state.sell_v = 0; state.ticks = 0;
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
cp /root/CryptoApex_v14.mq5 "$DATA_DIR/Experts/CryptoApex_v14.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/CryptoApex_v14.mq5" /log:"/root/compile.log"
EOF
RUN chmod +x /root/install_ea.sh

# 6. Entrypoint (Stability Fixes)
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x1024x24 -ac &
sleep 2
fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 -noxrecord -noxfixes -noxdamage &
websockify --web=/usr/share/novnc 8080 0.0.0.0:5900 &
wineboot --init
sleep 5
MT5_EXE="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
[ ! -f "$MT5_EXE" ] && wine /root/mt5setup.exe /auto && sleep 90
WINEPRELOADRESERVE=0x10000000 wine "$MT5_EXE" &
sleep 30 
bash /root/install_ea.sh
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
