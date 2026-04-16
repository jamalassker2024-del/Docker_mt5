# Stage 1: Build/Install phase
FROM debian:bookworm-slim AS builder
USER root
RUN apt-get update && apt-get install -y wget && \
    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /mt5setup.exe

# Stage 2: Final Slim Image
FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all 

# 1. Essential tools (Keeping it under the 4GB limit)
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine64 wine32 xvfb x11vnc fluxbox novnc websockify procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. ONLY install mt5linux (The bridge)
# We add rpyc because mt5linux uses it to communicate
RUN pip install --no-cache-dir mt5linux rpyc

COPY --from=builder /mt5setup.exe /root/mt5setup.exe
COPY bot.py /root/bot.py

# 3. Optimized Entrypoint
RUN echo '#!/bin/bash\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 2\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# Initialize Wine\n\
wineboot --init > /dev/null 2>&1\n\
sleep 5\n\
\n\
# Launch MT5\n\
if [ -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then\n\
    echo "Starting MT5..."\n\
    wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe" &\n\
else\n\
    echo "Running MT5 Installer..."\n\
    wine /root/mt5setup.exe &\n\
fi\n\
\n\
# Start Bridge\n\
# We use the full python path to ensure it finds the modules\n\
python3 -m mt5linux --port 8001 &\n\
\n\
sleep 25\n\
\n\
echo "Starting Bot..."\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
