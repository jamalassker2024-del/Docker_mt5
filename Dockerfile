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
# 2. Python bridge + trading libs
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. MT5 installer
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. MULTI-PAIR AGGRESSIVE OFI EA (preserved)
# ============================================
RUN cat > /root/MultiOFI_VX.mq5 << 'EOF'
#include <Trade\Trade.mqh>

#property copyright "Multi-Pair OFI Scalper"
#property version   "6.00"
#property strict

//--- INPUTS
input double InpLotSize      = 0.1;
input int    InpOFIThreshold = 2;
input int    InpTP           = 15;
input int    InpSL           = 40;
input int    InpMaxOrders    = 2;
input int    InpMagic        = 555001;

CTrade trade;

struct SymbolData {
    string name;
    MqlTick prev_t;
    bool first_tick;
};

SymbolData symbols[];

int OnInit() {
    trade.SetExpertMagicNumber(InpMagic);
    
    int total_symbols = SymbolsTotal(false);
    int count = 0;
    for(int i=0; i<total_symbols; i++) {
        string sym = SymbolName(i, false);
        if(StringFind(sym, ".vx") >= 0) {
            SymbolSelect(sym, true);
            ArrayResize(symbols, count+1);
            symbols[count].name = sym;
            symbols[count].first_tick = true;
            count++;
        }
    }
    Print("Loaded ", count, " .vx symbols. Starting 50ms HFT scanner.");
    EventSetMillisecondTimer(50);
    return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { EventKillTimer(); }

void OnTimer() {
    for(int i=0; i<ArraySize(symbols); i++) ProcessSymbol(i);
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
    if(curr_t.time_msc == symbols[idx].prev_t.time_msc) return;

    long v = (long)curr_t.volume_real;
    if(v <= 0) v = (long)curr_t.volume;
    if(v <= 0) v = 1;   // fallback for CFD symbols

    long delta_bid = (curr_t.bid > symbols[idx].prev_t.bid) ? v : (curr_t.bid < symbols[idx].prev_t.bid ? -v : 0);
    long delta_ask = (curr_t.ask < symbols[idx].prev_t.ask) ? v : (curr_t.ask > symbols[idx].prev_t.ask ? -v : 0);
    long ofi = delta_bid - delta_ask;
    
    int total = 0;
    for(int i=PositionsTotal()-1; i>=0; i--) {
        if(PositionSelectByTicket(PositionGetTicket(i))) {
            if(PositionGetInteger(POSITION_MAGIC)==InpMagic && PositionGetString(POSITION_SYMBOL)==sym) {
                total++;
            }
        }
    }
    if(total < InpMaxOrders && ofi != 0) {
        uint filling = (uint)SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
        if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
        else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
        else trade.SetTypeFilling(ORDER_FILLING_RETURN);

        double point = SymbolInfoDouble(sym, SYMBOL_POINT);
        if(ofi >= InpOFIThreshold) {
            trade.Buy(InpLotSize, sym, curr_t.ask, curr_t.bid - InpSL*point, curr_t.ask + InpTP*point, "OFI Buy");
        }
        else if(ofi <= -InpOFIThreshold) {
            trade.Sell(InpLotSize, sym, curr_t.bid, curr_t.ask + InpSL*point, curr_t.bid - InpTP*point, "OFI Sell");
        }
    }
    symbols[idx].prev_t = curr_t;
}
EOF

# ============================================
# 5. INSTALL SCRIPT (unchanged)
# ============================================
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
echo "Locating MT5 Data Folder..."
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
if [ -z "$DATA_DIR" ]; then
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
# 6. FIXED PYTHON HFT TRADER (corrected connection)
# ============================================
RUN cat > /root/hft_trader.py << 'EOF'
import sys
import time
from collections import defaultdict
import mt5linux as mt5

def connect_mt5(retries=10, delay=5):
    """Connect to the mt5linux RPyC service."""
    for i in range(retries):
        try:
            # Initialize with the correct host/port of the RPyC server
            if mt5.initialize(host='127.0.0.1', port=8001):
                print("Connected to MT5 via mt5linux")
                return True
        except Exception as e:
            print(f"Connection attempt {i+1} failed: {e}")
        time.sleep(delay)
    return False

def get_all_vx_symbols(mt5_client):
    symbols = mt5_client.symbols_get()
    if symbols is None:
        return []
    return [s.name for s in symbols if '.vx' in s.name]

def main():
    print("Waiting for MT5 terminal and RPyC server...")
    time.sleep(30)  # give MT5 time to fully start

    if not connect_mt5():
        print("FATAL: Could not connect to mt5linux RPyC server")
        sys.exit(1)

    symbols = get_all_vx_symbols(mt5)
    if not symbols:
        print("No .vx symbols found – ensure your broker provides them and you are logged in.")
        sys.exit(1)

    print(f"Watching {len(symbols)} symbols: {symbols}")
    for sym in symbols:
        mt5.symbol_select(sym, True)

    prev_ticks = {}
    lot_size = 0.1
    threshold = 1      # aggressive: trigger on smallest OFI
    tp_points = 15
    sl_points = 40
    max_orders_per_sym = 2

    print("Starting aggressive HFT loop (50ms)...")
    while True:
        for sym in symbols:
            tick = mt5.symbol_info_tick(sym)
            if not tick or tick.bid <= 0 or tick.ask <= 0:
                continue

            # First tick for this symbol – just store
            if sym not in prev_ticks:
                prev_ticks[sym] = tick
                continue

            prev = prev_ticks[sym]
            # Use 1 as volume if real volume is missing (CFD fix)
            vol = getattr(tick, 'volume', 0)
            if vol <= 0:
                vol = 1

            delta_bid = vol if tick.bid > prev.bid else (-vol if tick.bid < prev.bid else 0)
            delta_ask = vol if tick.ask < prev.ask else (-vol if tick.ask > prev.ask else 0)
            ofi = delta_bid - delta_ask

            # Count open positions for this symbol with our magic number
            positions = mt5.positions_get(symbol=sym)
            if positions is None:
                positions = []
            open_positions = [p for p in positions if p.magic == 555001]
            if len(open_positions) >= max_orders_per_sym:
                prev_ticks[sym] = tick
                continue

            point = mt5.symbol_info(sym).point
            if ofi >= threshold:
                request = {
                    "action": mt5.TRADE_ACTION_DEAL,
                    "symbol": sym,
                    "volume": lot_size,
                    "type": mt5.ORDER_TYPE_BUY,
                    "price": tick.ask,
                    "sl": tick.bid - sl_points * point,
                    "tp": tick.ask + tp_points * point,
                    "deviation": 10,
                    "magic": 555001,
                    "comment": "Python OFI Buy",
                    "type_time": mt5.ORDER_TIME_GTC,
                    "type_filling": mt5.ORDER_FILLING_IOC,
                }
                result = mt5.order_send(request)
                if result.retcode == mt5.TRADE_RETCODE_DONE:
                    print(f"Buy order placed on {sym} at {tick.ask}")
                else:
                    print(f"Buy failed on {sym}: {result.comment} (retcode={result.retcode})")
            elif ofi <= -threshold:
                request = {
                    "action": mt5.TRADE_ACTION_DEAL,
                    "symbol": sym,
                    "volume": lot_size,
                    "type": mt5.ORDER_TYPE_SELL,
                    "price": tick.bid,
                    "sl": tick.ask + sl_points * point,
                    "tp": tick.bid - tp_points * point,
                    "deviation": 10,
                    "magic": 555001,
                    "comment": "Python OFI Sell",
                    "type_time": mt5.ORDER_TIME_GTC,
                    "type_filling": mt5.ORDER_FILLING_IOC,
                }
                result = mt5.order_send(request)
                if result.retcode == mt5.TRADE_RETCODE_DONE:
                    print(f"Sell order placed on {sym} at {tick.bid}")
                else:
                    print(f"Sell failed on {sym}: {result.comment} (retcode={result.retcode})")

            prev_ticks[sym] = tick

        time.sleep(0.05)  # 50ms loop

if __name__ == "__main__":
    main()
EOF

# ============================================
# 7. ENTRYPOINT (starts ALL services)
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
sleep 5    # give the RPyC server time to start
python3 /root/hft_trader.py &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
