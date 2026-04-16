# Stage 1: Build the 'st' terminal
FROM debian:bullseye-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
RUN git clone https://git.suckless.org/st /work
WORKDIR /work
RUN make

# Stage 2: Final Image
FROM python:3.11-slim-bullseye

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all

# 1. Install Windows support and GUI tools
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine wine32 \
    xvfb x11vnc \
    novnc websockify fluxbox \
    wget unzip procps git \
    && rm -rf /var/lib/apt/lists/*

# 2. Install trading bridge
RUN pip install mt5linux

# 3. Setup web access
RUN ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# 4. Copy your files from GitHub into the container
COPY --from=st-builder /work/st /usr/bin/st
COPY bot.py /root/bot.py

# 5. Startup Script
RUN echo '#!/bin/bash\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 2\n\
fluxbox &\n\
x11vnc -display :0 -forever -nopw -listen localhost -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# Auto-download MT5 installer\n\
if [ ! -f "/root/mt5setup.exe" ]; then\n\
  wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe\n\
fi\n\
\n\
wine /root/mt5setup.exe &\n\
\n\
# Start the Bridge and your Bot\n\
python3 -m mt5linux &\n\
sleep 5\n\
python3 /root/bot.py &\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
