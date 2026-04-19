FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. Install Wine PROPERLY (FIXED)
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine wine64 wine32:i386 winbind \
    xvfb x11vnc fluxbox \
    novnc websockify wget curl procps cabextract \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python deps
RUN pip install --no-cache-dir mt5linux rpyc

# 3. Download MT5
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. Copy bot
COPY bot.py /root/bot.py

# 5. Entry script (FIXED X SERVER + WINE)
RUN cat << 'EOF' > /entrypoint.sh
#!/bin/bash

set -e

echo "Cleaning old X locks..."
rm -f /tmp/.X1-lock

echo "Starting virtual display..."
Xvfb :1 -screen 0 1280x800x16 &

sleep 2

fluxbox &
x11vnc -display :1 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

echo "Checking Wine..."
which wine || (echo "Wine not installed!" && exit 1)

echo "Initializing Wine..."
wineboot --init
sleep 5

MT5_1="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
MT5_2="/root/.wine/drive_c/Program Files (x86)/MetaTrader 5/terminal64.exe"

start_mt5() {
    if [ -f "$MT5_1" ]; then
        echo "Starting MT5 (64bit)"
        wine "$MT5_1" &
        return 0
    elif [ -f "$MT5_2" ]; then
        echo "Starting MT5 (x86)"
        wine "$MT5_2" &
        return 0
    else
        return 1
    fi
}

if ! start_mt5; then
    echo "Launching MT5 installer..."
    wine /root/mt5setup.exe &
fi

echo "Waiting for MT5..."
sleep 25

echo "Starting bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

sleep 10

echo "Starting bot..."
python3 /root/bot.py &

echo "READY: Open browser to see MT5"
wait
EOF

RUN chmod +x /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
