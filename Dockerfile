# Stage 1: Build phase
FROM debian:bookworm-slim AS builder
USER root
RUN apt-get update && apt-get install -y wget && \
    wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /mt5setup.exe

# Stage 2: Final Image
FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all 

# Install bare minimum (added xterm as it's lighter)
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine64 wine32 xvfb x11vnc fluxbox novnc websockify procps xterm \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc

COPY --from=builder /mt5setup.exe /root/mt5setup.exe
COPY bot.py /root/bot.py

# Create a manual menu in case the installer is hidden
RUN mkdir -p /root/.fluxbox && echo '[begin] (Menu)\n\
[exec] (Installer) {wine /root/mt5setup.exe}\n\
[exec] (Terminal) {xterm}\n\
[end]' > /root/.fluxbox/menu

RUN echo '#!/bin/bash\n\
# 1. Lower resolution and color depth (16-bit saves massive RAM)\n\
Xvfb :0 -screen 0 1024x768x16 &\n\
sleep 2\n\
fluxbox &\n\
sleep 1\n\
\n\
# 2. Optimized VNC for slow connections\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 -ultrafilexfer &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# 3. Quiet Wine Setup\n\
wineboot --init > /dev/null 2>&1\n\
sleep 5\n\
\n\
# 4. Start Installer\n\
echo "Starting MT5 Setup..."\n\
wine /root/mt5setup.exe &\n\
\n\
# 5. Start Bridge\n\
python3 -m mt5linux --port 8001 &\n\
\n\
# 6. Wait for user to finish clicking "Next" in browser\n\
sleep 45\n\
python3 /root/bot.py\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
