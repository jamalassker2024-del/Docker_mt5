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
    novnc websockify wget procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Install Bridge + RPyC
RUN pip install --no-cache-dir mt5linux rpyc

# 3. Download MT5
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

COPY --from=st-builder /work/st /usr/bin/st
COPY bot.py /root/bot.py

# 4. Correct Fluxbox Menu (Fixed Terminal paths)
RUN mkdir -p /root/.fluxbox && echo '[begin] (Fluxbox)\n\
[exec] (Terminal) {st}\n\
[exec] (Install MT5 Manually) {wine /root/mt5setup.exe}\n\
[exec] (Run MT5) {wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe"}\n\
[end]' > /root/.fluxbox/menu

# 5. The Runtime Script
RUN echo '#!/bin/bash\n\
# Initialize display\n\
Xvfb :0 -screen 0 1024x768x16 &\n\
sleep 2\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
echo "Initializing Wine..."\n\
wineboot --init\n\
sleep 10\n\
\n\
# CHECK: If MT5 is not there, pop up the installer immediately\n\
if [ ! -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then\n\
    echo "MT5 not found. Launching installer window..."\n\
    wine /root/mt5setup.exe &\n\
else\n\
    echo "MT5 found. Starting Terminal..."\n\
    wine "C:\\Program Files\\MetaTrader 5\\terminal64.exe" &\n\
fi\n\
\n\
# Start Bridge (Wait for Wine to be ready)\n\
(sleep 30 && python3 -m mt5linux --port 8001) &\n\
\n\
# Start Bot (Wait for Bridge)\n\
(sleep 45 && python3 /root/bot.py) &\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
