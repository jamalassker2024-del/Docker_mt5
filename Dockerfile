FROM debian:bookworm-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
RUN git clone https://git.suckless.org/st /work && cd /work && make

FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all 

# 1. Install System Tools + Performance dependencies
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine64 wine32 xvfb x11vnc fluxbox \
    novnc websockify wget procps cabextract winbind \
    && wget https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -O /usr/local/bin/winetricks \
    && chmod +x /usr/local/bin/winetricks \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Install Bridge + RPyC (Required for stability)
RUN pip install --no-cache-dir mt5linux rpyc

# 3. Download MT5
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

COPY --from=st-builder /work/st /usr/bin/st
COPY bot.py /root/bot.py

# 4. Clean Menu
RUN mkdir -p /root/.fluxbox && echo '[begin] (Fluxbox)\n\
[exec] (Terminal) {st}\n\
[exec] (MetaTrader 5) {wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe"}\n\
[exec] (Force Installer) {wine /root/mt5setup.exe}\n\
[end]' > /root/.fluxbox/menu

# 5. The Corrected Entrypoint
RUN echo '#!/bin/bash\n\
# Initialize virtual display\n\
Xvfb :0 -screen 0 1024x768x16 &\n\
sleep 2\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# Prevent Wine corruption by waiting for init to finish\n\
echo "Initializing Wine..."\n\
wineboot --init\n\
while pgrep -f wineboot > /dev/null; do sleep 1; done\n\
\n\
# Check if MT5 is installed, if not, install it silently\n\
if [ ! -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then\n\
    echo "MT5 not found. Installing..."\n\
    wine /root/mt5setup.exe /silent\n\
    # Wait for installer to finish\n\
    while pgrep -f mt5setup.exe > /dev/null; do sleep 2; done\n\
    sleep 5\n\
fi\n\
\n\
echo "Starting MT5 Terminal..."\n\
wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe" &\n\
\n\
echo "Starting MT5Linux Bridge..."\n\
# We force the bridge to wait for Wine to settle\n\
sleep 10\n\
python3 -m mt5linux --port 8001 &\n\
\n\
echo "Waiting for Bridge to be ready..."\n\
sleep 15\n\
\n\
echo "Starting Bot..."\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
