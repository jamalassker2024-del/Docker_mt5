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

# 4. CREATE AGGRESSIVE EA
RUN cat > /root/SimpleBot.mq5 << 'EOF'
#property copyright "Valetax Bot"
#property version   "2.00"
#property strict

input double LotSize = 0.1; // Increased lot size
input int    Magic   = 12345;

// Aggressive Trading Logic: Open Buy if none exists, Open Sell if none exists
void OnTick() {
    MqlTick last_tick;
    
    // Fix for "Tick Price: 0.0000" - Only proceed if price is valid
    if(!SymbolInfoTick(_Symbol, last_tick)) {
        Print("Waiting for valid tick data...");
        return;
    }

    if(last_tick.ask <= 0 || last_tick.bid <= 0) return;

    // Check if we already have a position
    if(PositionSelect(_Symbol) == false) {
        TradeAction(last_tick);
    }
}

void TradeAction(MqlTick &tick) {
    MqlTradeRequest request = {};
    MqlTradeResult  result  = {};

    request.action       = TRADE_ACTION_DEAL;
    request.symbol       = _Symbol;
    request.volume       = LotSize;
    request.type_filling = ORDER_FILLING_FOK;
    request.deviation    = 20;
    request.magic        = Magic;

    // Aggressive logic: Alternate Buy/Sell or follow trend
    if(tick.ask > 0) {
        request.type = ORDER_TYPE_BUY;
        request.price = tick.ask;
        if(!OrderSend(request, result)) {
            Print("OrderSend error: ", GetLastError());
        } else {
            Print("Aggressive Buy Opened at: ", tick.ask);
        }
    }
}
EOF

# 5. FIXED INSTALLER (Finds the hashed Data Folder)
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash
echo "Locating MT5 Data Folder..."
# MT5 creates a hashed folder in AppData. We must find THAT folder.
DATA_FOLDER=$(find /root/.wine -type d -name "MQL5" | grep "Terminal" | head -n 1)

if [ -z "$DATA_FOLDER" ]; then
    echo "MT5 hasn't created the Data Folder yet. Using fallback..."
    DATA_FOLDER="/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5"
fi

echo "Installing EA to: $DATA_FOLDER/Experts/SimpleBot.mq5"
mkdir -p "$DATA_FOLDER/Experts"
cp /root/SimpleBot.mq5 "$DATA_FOLDER/Experts/SimpleBot.mq5"

EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
if [ -f "$EDITOR" ]; then
    echo "Compiling EA..."
    wine "$EDITOR" /compile:"$DATA_FOLDER/Experts/SimpleBot.mq5" /log:"/root/compile.log"
    cat /root/compile.log
fi
EOF

RUN chmod +x /root/install_ea.sh

# 6. ENTRYPOINT
RUN cat > /entrypoint.sh << 'EOF'
#!/bin/bash
set -e
rm -rf /tmp/.X*
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
    echo "Waiting for installation..."
    sleep 60
fi

# Start MT5 to let it create the folder structure
wine "$MT5_EXE" &
sleep 30

# Run the installer now that folders exist
bash /root/install_ea.sh

python3 -m mt5linux --host 0.0.0.0 --port 8001 &
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh
EXPOSE 8080 8001
CMD ["/bin/bash", "/entrypoint.sh"]
