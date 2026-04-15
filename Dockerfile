# Stage 1: Build the 'st' terminal
FROM debian:bullseye-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
COPY ./st /work
WORKDIR /work
RUN make

# Stage 2: Final Image
FROM python:3.11-slim-bullseye

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive

# Install Wine, X11, noVNC, and Fluxbox (lighter than Openbox for Railway)
RUN apt-get update && apt-get install -y \
    wine64 wine xvfb x11vnc \
    novnc websockify fluxbox \
    wget unzip procps \
    && rm -rf /var/lib/apt/lists/*

# Install Python bridge for MT5
RUN pip install mt5linux

# Setup noVNC
RUN ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# Copy your Terminal and MT5 files
COPY --from=st-builder /work/st /usr/bin/st
COPY Metatrader /root/.wine/drive_c/Program\ Files/MetaTrader\ 5
COPY bot.py /root/bot.py

# Setup Startup Script
RUN echo '#!/bin/bash\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
fluxbox &\n\
x11vnc -display :0 -forever -nopw -listen localhost -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" &\n\
python3 -m mt5linux &\n\
python3 /root/bot.py\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/entrypoint.sh"]
