FROM python:3.11-slim-bookworm

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:0
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV WINEDEBUG=-all

# 1. Install system + Wine properly
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine64 wine32 winbind xvfb x11vnc fluxbox \
    novnc websockify wget curl procps cabextract \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Python deps
RUN pip install --no-cache-dir mt5linux rpyc

# 3. Download MT5 installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

# 4. Copy bot
COPY bot.py /root/bot.py

# 5. Entrypoint
RUN echo '#!/bin/bash

set -e

echo "Starting virtual display..."
Xvfb :0 -screen 0 1280x800x16 &
sleep 2

fluxbox &
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &
websockify --web=/usr/share/novnc/ 8080 localhost:5900 &

echo "Initializing Wine (first run)..."
wineboot --init
sleep 5

MT5_PATH_1="/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe"
MT5_PATH_2="/root/.wine/drive_c/Program Files (x86)/MetaTrader 5/terminal64.exe"

start_mt5() {
    if [ -f "$MT5_PATH_1" ]; then
        echo "Launching MT5 (64-bit)..."
        wine "$MT5_PATH_1" &
        return 0
    elif [ -f "$MT5_PATH_2" ]; then
        echo "Launching MT5 (x86)..."
        wine "$MT5_PATH_2" &
        return 0
    else
        return 1
    fi
}

# Install if not found
if ! start_mt5; then
    echo "MT5 not found. Launching installer..."
    wine /root/mt5setup.exe &
    
    echo "Waiting for MT5 installation..."
    for i in {1..120}; do
        sleep 5
        if start_mt5; then
            echo "MT5 installed successfully!"
            break
        fi
        echo "Still waiting for install..."
    done
fi

echo "Waiting for MT5 to fully start..."
sleep 20

echo "Starting MT5 bridge..."
python3 -m mt5linux --host 0.0.0.0 --port 8001 &

echo "Waiting for bridge..."
sleep 10

echo "Starting bot..."
python3 /root/bot.py &

echo "System ready. Access via browser."
wait
' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080 8001

CMD ["/bin/bash", "/entrypoint.sh"]
