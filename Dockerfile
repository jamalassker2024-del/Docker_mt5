FROM debian:bookworm-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
RUN git clone https://git.suckless.org/st /work && cd /work && make

FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive
# This helps Wine run a bit faster in Docker
ENV WINEDEBUG=-all 

# 1. Install only essential tools
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine32 xvfb x11vnc fluxbox \
    novnc websockify wget procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install mt5linux

# 2. Pre-create Wine prefix during build to save time at launch
RUN xvfb-run wineboot --init && sleep 5

# 3. Download MT5
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

COPY --from=st-builder /work/st /usr/bin/st
COPY bot.py /root/bot.py

# 4. Clean Menu
RUN mkdir -p /root/.fluxbox && echo '[begin] (Fluxbox)\n\
[exec] (Terminal) {st}\n\
[exec] (MetaTrader 5) {wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe"}\n\
[exec] (Force Installer) {wine /root/mt5setup.exe}\n\
[restart] (Restart)\n\
[end]' > /root/.fluxbox/menu

# 5. Optimized Entrypoint
RUN echo '#!/bin/bash\n\
# Start Virtual Display\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 1\n\
\n\
# Start Window Manager & VNC\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
# Start noVNC on 8080\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
echo "Waiting for display..."\n\
sleep 3\n\
\n\
# Try to run MT5 if installed, otherwise run installer\n\
if [ -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then\n\
    echo "Launching MT5..."\n\
    wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe" &\n\
else\n\
    echo "Starting MT5 Installer..."\n\
    wine /root/mt5setup.exe &\n\
fi\n\
\n\
echo "Starting MT5Linux Bridge..."\n\
python3 -m mt5linux --port 8001 &\n\
\n\
# GIVE WINE TIME TO BREATHE\n\
sleep 30\n\
\n\
echo "Starting Bot..."\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
