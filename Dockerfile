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
# 4. CREATE EA - SIMPLE VERSION THAT WILL COMPILE
# ============================================
RUN cat > /root/SimpleBot.mq5 << 'EOF'
//+------------------------------------------------------------------+
//|                                                       SimpleBot.mq5 |
//|                                                      Test EA v1.0 |
//+------------------------------------------------------------------+
#property copyright "Valetax Bot"
#property version   "1.00"
#property strict

input double   LotSize = 0.01;
input int      TP = 50;
input int      SL = 25;

int ticket = 0;
bool tradeDone = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit() {
   Print("========================================");
   Print("  SIMPLE BOT LOADED SUCCESSFULLY!");
   Print("  Symbol: " + _Symbol);
   Print("  Lot Size: " + DoubleToString(LotSize, 2));
   Print("========================================");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick() {
   static int count = 0;
   count++;
   
   if(count % 100 == 0) {
      Print("Bot is running... Tick #" + IntegerToString(count));
   }
   
   // Place a test order on first tick (commented out for safety)
   // if(!tradeDone && count > 100) {
   //    MqlTick tick;
   //    if(SymbolInfoTick(_Symbol, tick)) {
   //       MqlTradeRequest req = {};
   //       MqlTradeResult res = {};
   //       req.action = TRADE_ACTION_DEAL;
   //       req.symbol = _Symbol;
   //       req.volume = LotSize;
   //       req.type = ORDER_TYPE_BUY;
   //       req.price = tick.ask;
   //       req.deviation = 10;
   //       req.magic = 12345;
   //       req.comment = "Test";
   //       req.type_filling = ORDER_FILLING_FOK;
   //       if(OrderSend(req, res)) {
   //          if(res.retcode == TRADE_RETCODE_DONE) {
   //             tradeDone = true;
   //             Print("ORDER EXECUTED! Ticket: " + IntegerToString(res.order));
   //          }
   //       }
   //    }
   // }
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   Print("Bot removed from chart. Reason: " + IntegerToString(reason));
}
//+------------------------------------------------------------------+
EOF

# ============================================
# 5. CREATE HELPER SCRIPT TO INSTALL EA
# ============================================
RUN cat > /root/install_ea.sh << 'EOF'
#!/bin/bash

echo "=========================================="
echo "Installing EA to all possible MQL5 folders"
echo "=========================================="

# Find all possible MQL5 directories
MQL5_DIRS=$(find /root/.wine -type d -name "MQL5" 2>/dev/null)

if [ -z "$MQL5_DIRS" ]; then
    echo "No MQL5 directories found! Creating default..."
    mkdir -p "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts"
    cp /root/SimpleBot.mq5 "/root/.wine/drive_c/Program Files/MetaTrader 5/MQL5/Experts/SimpleBot.mq5"
else
    for dir in $MQL5_DIRS; do
        echo "Installing to: $dir/Experts/"
        mkdir -p "$dir/Experts"
        cp /root/SimpleBot.mq5 "$dir/Experts/SimpleBot.mq5"
        
        # Try to compile with metaeditor if found
        EDITOR="/root/.wine/drive_c/Program Files/MetaTrader 5/metaeditor64.exe"
        if [ -f "$EDITOR" ]; then
            echo "Compiling in: $dir"
            wine "$EDITOR" /compile:"$dir/Experts/SimpleBot.mq5" /log:"/root/compile_$(basename $dir).log" 2>&1
        fi
    done
fi

echo "=========================================="
echo "EA installation complete!"
echo "Look for 'SimpleBot' in MT5 Navigator"
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
echo "VALETAX BOT - FINAL VERSION"
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
echo "SETUP COMPLETE!"
echo "=========================================="
echo ""
echo "TO USE THE BOT:"
echo "1. Open your browser to the VNC URL"
echo "2. Login to Valetutax in MT5"
echo "3. Press Ctrl+N to open Navigator"
echo "4. Right-click 'Expert Advisors' and select 'Refresh'"
echo "5. Look for 'SimpleBot' in the list"
echo "6. Drag 'SimpleBot' to any chart"
echo "7. Click 'OK' on the settings dialog"
echo "8. Click the 'Auto-Trading' button (or press Alt+T)"
echo ""
echo "If you don't see 'SimpleBot', check the Experts tab for compilation errors"
echo "=========================================="

tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
