FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all
ENV QT_X11_NO_MITSHM=1

RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    fonts-wine \
    wget curl procps cabextract unzip dos2unix xdotool \
    build-essential python3-dev gcc \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc

RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

RUN cat > /root/MultiOFI_VX.mq5 << 'EOF'
#include <Trade\Trade.mqh>
#property copyright "Multi-Pair OFI Scalper"
#property version   "6.00"
#property strict
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
    Print("Loaded ", count, " .vx symbols.");
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
    if(v <= 0) v = 1;
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

RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
echo "Searching MT5 data folder..."
DATA_DIR=$(find /root/.wine -type d -path "*MetaQuotes/Terminal/*/MQL5" | head -n 1)
if [ -z "$DATA_DIR" ]; then
    echo "Fallback path used"
    DATA_DIR="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi
mkdir -p "$DATA_DIR/Experts"
cp /root/MultiOFI_VX.mq5 "$DATA_DIR/Experts/"
echo "EA installed at $DATA_DIR/Experts"
EOF

RUN chmod +x /root/install_ea.sh

RUN cat > /root/hft_trader.py << 'EOF'
import time
import mt5linux as mt5

def wait_for_connection():
    for i in range(60):
        try:
            if mt5.initialize(host="127.0.0.1", port=8001):
                print("Connected via RPyC bridge")
                return True
            if mt5.initialize():
                print("Connected directly")
                return True
        except Exception as e:
            print(f"Attempt {i+1} failed: {e}")
        time.sleep(3)
    return False

print("Waiting MT5 and bridge...")
time.sleep(60)

if not wait_for_connection():
    print("FATAL: Could not connect to MT5")
    exit(1)

symbols = [s.name for s in mt5.symbols_get() if ".vx" in s.name]

if not symbols:
    print("No .vx symbols found – check broker login and symbol availability")
    exit(1)

for s in symbols:
    mt5.symbol_select(s, True)

prev_ticks = {}
lot = 0.1
tp = 15
sl = 40
magic = 555001

print(f"HFT STARTED – watching {len(symbols)} symbols")

while True:
    for sym in symbols:
        t = mt5.symbol_info_tick(sym)
        if not t or t.bid <= 0 or t.ask <= 0:
            continue
        if sym not in prev_ticks:
            prev_ticks[sym] = t
            continue
        vol = t.volume if t.volume > 0 else 1
        delta_bid = vol if t.bid > prev_ticks[sym].bid else (-vol if t.bid < prev_ticks[sym].bid else 0)
        delta_ask = vol if t.ask < prev_ticks[sym].ask else (-vol if t.ask > prev_ticks[sym].ask else 0)
        ofi = delta_bid - delta_ask
        if abs(ofi) >= 1:
            positions = mt5.positions_get(symbol=sym)
            open_positions = [p for p in (positions or []) if p.magic == magic]
            if len(open_positions) < 2:
                point = mt5.symbol_info(sym).point
                if ofi > 0:
                    req = {
                        "action": mt5.TRADE_ACTION_DEAL,
                        "symbol": sym,
                        "volume": lot,
                        "type": mt5.ORDER_TYPE_BUY,
                        "price": t.ask,
                        "sl": t.bid - sl * point,
                        "tp": t.ask + tp * point,
                        "deviation": 10,
                        "magic": magic,
                        "comment": "OFI Buy",
                        "type_filling": mt5.ORDER_FILLING_IOC,
                    }
                    res = mt5.order_send(req)
                    if res.retcode == mt5.TRADE_RETCODE_DONE:
                        print(f"Buy {sym} at {t.ask}")
                    else:
                        print(f"Buy failed {sym}: {res.comment} (code {res.retcode})")
                elif ofi < 0:
                    req = {
                        "action": mt5.TRADE_ACTION_DEAL,
                        "symbol": sym,
                        "volume": lot,
                        "type": mt5.ORDER_TYPE_SELL,
                        "price": t.bid,
                        "sl": t.ask + sl * point,
                        "tp": t.bid - tp * point,
                        "deviation": 10,
                        "magic": magic,
                        "comment": "OFI Sell",
                        "type_filling": mt5.ORDER_FILLING_IOC,
                    }
                    res = mt5.order_send(req)
                    if res.retcode == mt5.TRADE_RETCODE_DONE:
                        print(f"Sell {sym} at {t.bid}")
                    else:
                        print(f"Sell failed {sym}: {res.comment} (code {res.retcode})")
        prev_ticks[sym] = t
    time.sleep(0.05)
EOF

RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
echo "Starting X server..."
rm -rf /tmp/.X*
Xvfb :1 -screen 0 1280x800x16 &
sleep 3
fluxbox &
x11vnc -display :1 -forever -nopw -shared -rfbport 5900 &
websockify --web /usr/share/novnc/ 8080 localhost:5900 &
echo "Initializing Wine..."
wineboot --init
sleep 10
MT5="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [ ! -f "$MT5" ]; then
    echo "Installing MT5..."
    wine /root/mt5setup.exe /auto
    sleep 120
fi
echo "Launching MT5..."
wine "$MT5" &
echo "Waiting MT5 full startup (Wine needs ~90s)..."
sleep 90
echo "Installing EA..."
bash /root/install_ea.sh
echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
echo "Waiting bridge to become ready..."
sleep 20
echo "Starting Python trader..."
python3 /root/hft_trader.py &
echo "System READY – HFT active"
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
