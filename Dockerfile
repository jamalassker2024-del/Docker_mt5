FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. STABLE WINE ENV
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    wget curl procps cabextract unzip dos2unix xdotool \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. MT5 installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. V13.0 - DIAGNOSTIC APEX (LOOKBACK + RATIO)
RUN cat > /root/AggressiveOFI_Apex_v13.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Apex Diagnostic Multi-Symbol"
#property version   "13.00"
#property strict

//--- INPUTS
input double InpLotSize      = 0.3;      
input int    InpTP           = 10;       
input int    InpSL           = 30;       
input int    InpMaxOrders    = 20;       
input int    InpMagic        = 555013;
input double InpMaxSpread    = 2.0;      
input int    InpLookback     = 20;       // Number of ticks to analyze
input double InpPressureRatio = 1.05;    // Buy/Sell imbalance ratio

struct SymbolState {
    string name;
    MqlTick prev_t;
    long buy_volume_sum;
    long sell_volume_sum;
    int tick_count;
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
            monitored_symbols[count].buy_volume_sum = 0;
            monitored_symbols[count].sell_volume_sum = 0;
            monitored_symbols[count].tick_count = 0;
            monitored_symbols[count].first = true;
            count++;
        }
    }
    Print("Apex V13 ACTIVE. Lookback: ", InpLookback, " | Ratio: ", InpPressureRatio);
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

    double point = SymbolInfoDouble(state.name, SYMBOL_POINT);
    double spread_pips = (curr_t.ask - curr_t.bid) / (point * 10);
    if(spread_pips > InpMaxSpread) return; 

    if(state.first) { state.prev_t = curr_t; state.first = false; return; }
    if(curr_t.time_msc == state.prev_t.time_msc) return;

    // --- ACCUMULATE LOOKBACK DATA ---
    long v = (curr_t.volume_real > 0) ? (long)curr_t.volume_real : (long)curr_t.volume;
    if(v == 0) v = 1; // Fallback for low-liq ticks

    if(curr_t.bid > state.prev_t.bid) state.buy_volume_sum += v;
    if(curr_t.ask < state.prev_t.ask) state.sell_volume_sum += v;
    
    state.tick_count++;

    // --- EXECUTE ONLY AFTER LOOKBACK WINDOW ---
    if(state.tick_count >= InpLookback) {
        double buy_pressure = (double)state.buy_volume_sum;
        double sell_pressure = (double)state.sell_volume_sum;
        
        // DEBUG LOGGING
        PrintFormat("[%s] Ticks:%d | BuyP:%.0f | SellP:%.0f | Ratio:%.2f", 
                    state.name, InpLookback, buy_pressure, sell_pressure, 
                    (sell_pressure > 0 ? buy_pressure/sell_pressure : 0));

        int total_pos = 0;
        for(int j=PositionsTotal()-1; j>=0; j--)
            if(PositionSelectByTicket(PositionGetTicket(j)) && PositionGetInteger(POSITION_MAGIC) == InpMagic) total_pos++;

        if(total_pos < InpMaxOrders) {
            uint filling = (uint)SymbolInfoInteger(state.name, SYMBOL_FILLING_MODE);
            if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
            else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
            else trade.SetTypeFilling(ORDER_FILLING_RETURN);

            // Pressure Ratio Trigger
            if(buy_pressure > sell_pressure * InpPressureRatio) {
                trade.Buy(InpLotSize, state.name, curr_t.ask, curr_t.bid - InpSL*point, curr_t.ask + InpTP*point);
            }
            else if(sell_pressure > buy_pressure * InpPressureRatio) {
                trade.Sell(InpLotSize, state.name, curr_t.bid, curr_t.ask + InpSL*point, curr_t.bid - InpTP*point);
            }
        }
        
        // Reset window
        state.buy_volume_sum = 0;
        state.sell_volume_sum = 0;
        state.tick_count = 0;
    }
    state.prev_t = curr_t;
}
EOF

# 5. FIXED INSTALL SCRIPT
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
[ -z "$DATA_DIR" ] && DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
mkdir -p "$DATA_DIR/Experts"
cp /root/AggressiveOFI_Apex_v13.mq5 "$DATA_DIR/Experts/AggressiveOFI_Apex_v13.mq5"
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe" /compile:"$DATA_DIR/Experts/AggressiveOFI_Apex_v13.mq5" /log:"/root/compile.log"
EOF
RUN chmod +x /root/install_ea.sh

# 6. ENTRYPOINT (Stability + Memory)
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
