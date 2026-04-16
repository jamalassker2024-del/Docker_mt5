FROM debian:bookworm-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
RUN git clone https://git.suckless.org/st /work && cd /work && make

FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install System Tools + Winetricks dependencies
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine32 xvfb x11vnc fluxbox \
    novnc websockify wget procps cabextract winbind \
    && wget https://raw.githubusercontent.com/Winetricks/winetricks/master/src/winetricks -O /usr/local/bin/winetricks \
    && chmod +x /usr/local/bin/winetricks \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Download MT5
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

COPY --from=st-builder /work/st /usr/bin/st
COPY bot.py /root/bot.py

# 3. Clean Menu (No Explorer at start)
RUN mkdir -p /root/.fluxbox && echo '[begin] (Fluxbox)\n\
[exec] (Terminal) {st}\n\
[exec] (MetaTrader 5) {wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe"}\n\
[exec] (Force Installer) {wine /root/mt5setup.exe}\n\
[restart] (Restart)\n\
[end]' > /root/.fluxbox/menu

# 4. Entrypoint with focus on Installer
RUN echo '#!/bin/bash\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 2\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# Init Wine without opening explorer\n\
wineboot --init\n\
sleep 5\n\
\n\
# Force installer to start\n\
echo "Starting MT5..."\n\
wine /root/mt5setup.exe &\n\
\n\
# Open terminal so you can see if there are errors\n\
st -e /bin/bash &\n\
\n\
python3 /root/bot.py &\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
