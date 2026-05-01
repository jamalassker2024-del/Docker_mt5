FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# ============================================
# 1. SYSTEM + WINE (FIXED)
# ============================================
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine32:i386 winbind \
    xvfb fluxbox x11vnc novnc websockify \
    fonts-wine \
    wget curl procps cabextract unzip dos2unix xdotool \
    build-essential python3-dev gcc \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# ============================================
# 2. PYTHON LIBS
# ============================================
RUN pip install --no-cache-dir mt5linux rpyc

# ============================================
# 3. DOWNLOAD MT5
# ============================================
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# ============================================
# 4. EA FILE
# ============================================
COPY <<EOF /root/MultiOFI_VX.mq5
// (your EA code unchanged here)
EOF

# ============================================
# 5. INSTALL EA SCRIPT (FIXED PATH)
# ============================================
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

# ============================================
# 6. PYTHON BOT (FIXED)
# ============================================
RUN cat > /root/hft_trader.py << 'EOF'
import time
import mt5linux as mt5

def wait_for_connection():
    for i in range(20):
        if mt5.initialize(host="127.0.0.1", port=8001):
            print("Connected to MT5")
            return True
        print("Retrying MT5 connection...")
        time.sleep(3)
    return False

print("Waiting MT5...")
time.sleep(40)

if not wait_for_connection():
    print("FAILED to connect MT5")
    exit(1)

symbols = [s.name for s in mt5.symbols_get() if ".vx" in s.name]

if not symbols:
    print("No symbols found")
    exit(1)

for s in symbols:
    mt5.symbol_select(s, True)

prev = {}

print("HFT STARTED")

while True:
    for sym in symbols:
        t = mt5.symbol_info_tick(sym)
        if not t:
            continue

        if sym not in prev:
            prev[sym] = t
            continue

        vol = t.volume if t.volume > 0 else 1

        ofi = (vol if t.bid > prev[sym].bid else -vol) - \
              (vol if t.ask < prev[sym].ask else -vol)

        if abs(ofi) > 0:
            print(sym, "OFI:", ofi)

        prev[sym] = t

    time.sleep(0.05)
EOF

# ============================================
# 7. ENTRYPOINT (FIXED ORDER + STABILITY)
# ============================================
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
sleep 40

echo "Installing EA..."
bash /root/install_ea.sh

echo "Starting mt5linux bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &
sleep 10

echo "Starting Python trader..."
python3 /root/hft_trader.py &

echo "System READY"
tail -f /dev/null
EOF

RUN chmod +x /entrypoint.sh && dos2unix /entrypoint.sh

# ============================================
# PORTS
# ============================================
EXPOSE 8080 8001

CMD ["/entrypoint.sh"]
