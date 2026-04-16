# STAGE 1: The Builder (Downloads & Pre-installs)
FROM debian:bookworm-slim AS builder
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Install only what is needed to download and extract
RUN apt-get update && apt-get install -y wget cabextract && \
    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /mt5setup.exe

# STAGE 2: The Production Image
FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all
ENV PYTHONUNBUFFERED=1

# 1. Install bare minimum system tools
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine64 wine32 xvfb fluxbox x11vnc novnc websockify procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Install Python Bridge Dependencies
RUN pip install --no-cache-dir mt5linux rpyc

# 3. Bring the installer from the builder stage
COPY --from=builder /mt5setup.exe /root/mt5setup.exe
COPY bot.py /root/bot.py

# 4. The "Magic" Entrypoint Script
RUN echo '#!/bin/bash\n\
echo "Starting Virtual Display (1024x768x16)..."\n\
Xvfb :0 -screen 0 1024x768x16 &\n\
sleep 2\n\
fluxbox &\n\
\n\
echo "Starting VNC Interface..."\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
echo "Initializing Wine Environment..."\n\
wineboot --init > /dev/null 2>&1\n\
sleep 5\n\
\n\
# SILENT INSTALLER: This prevents the 4GB bloat and avoids manual clicks\n\
if [ ! -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then\n\
    echo "Installing MetaTrader 5 Silently..."\n\
    wine /root/mt5setup.exe /silent\n\
    # Wait for the background install process to finish\n\
    while pgrep -f mt5setup.exe > /dev/null; do sleep 5; done\n\
fi\n\
\n\
echo "Launching MT5 Terminal..."\n\
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" &\n\
\n\
echo "Launching MT5-Linux Bridge..."\n\
python3 -m mt5linux --port 8001 &\n\
\n\
echo "Waiting for Bridge to settle..."\n\
sleep 20\n\
\n\
echo "Executing Bot..."\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
