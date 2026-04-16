# Stage 1: Build the 'st' terminal
FROM debian:bullseye-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
# Fallback if st folder doesn't exist: clone it
RUN git clone https://git.suckless.org/st /work || mkdir /work
WORKDIR /work
RUN make

# Stage 2: Final Image
FROM python:3.11-slim-bullseye

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive

# Install dependencies
RUN apt-get update && apt-get install -y \
    wine64 wine xvfb x11vnc \
    novnc websockify fluxbox \
    wget unzip procps git \
    && rm -rf /var/lib/apt/lists/*

# Install Python bridge for MT5
RUN pip install mt5linux

# Setup noVNC
RUN ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# Copy your Terminal from the builder
COPY --from=st-builder /work/st /usr/bin/st

# Setup Startup Script (This handles everything)
RUN echo '#!/bin/bash\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
fluxbox &\n\
x11vnc -display :0 -forever -nopw -listen localhost -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
# If MT5 isnt installed, download it\n\
if [ ! -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then\n\
  wget https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe\n\
  wine /root/mt5setup.exe &\n\
fi\n\
python3 -m mt5linux &\n\
# Start your bot if it exists\n\
if [ -f "/root/bot.py" ]; then python3 /root/bot.py; fi\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
