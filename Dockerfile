FROM debian:bookworm-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
RUN git clone https://git.suckless.org/st /work && cd /work && make

FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install System Tools + cabextract for wine stability
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine32 xvfb x11vnc fluxbox \
    novnc websockify wget procps cabextract \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Linux-side Python bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. DOWNLOAD MT5
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

COPY --from=st-builder /work/st /usr/bin/st
# Ensure bot.py exists in your local directory before building
COPY bot.py /root/bot.py 

# 4. Fluxbox Menu (Right-click on desktop to see this)
RUN mkdir -p /root/.fluxbox && echo '[begin] (Fluxbox)\n\
[exec] (Terminal) {st}\n\
[exec] (MetaTrader 5) {wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe"}\n\
[exec] (Run Installer) {wine /root/mt5setup.exe}\n\
[restart] (Restart)\n\
[end]' > /root/.fluxbox/menu

# 5. Optimized Entrypoint
RUN echo '#!/bin/bash\n\
# Start X Server\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 2\n\
\n\
# Start Window Manager and VNC\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# Initialize Wine and wait\n\
wine boot --init\n\
sleep 8\n\
\n\
# AUTO-START MT5 INSTALLER (Focused)\n\
echo "Launching MT5 Installer..."\n\
wine /root/mt5setup.exe &\n\
\n\
# Launch Terminal for logs\n\
st -e tail -f /root/.wine/drive_c/users/root/Temp/*.log &\n\
\n\
# Run Bot bridge\n\
python3 /root/bot.py &\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
