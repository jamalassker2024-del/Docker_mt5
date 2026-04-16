# Stage 1: Build the terminal
FROM debian:bookworm-slim AS st-builder
RUN apt-get update && apt-get install -y make gcc git libx11-dev libxft-dev libxext-dev
RUN git clone https://git.suckless.org/st /work && cd /work && make

# Stage 2: Main Image
FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive

# 1. Install Latest Wine and VNC components
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine32 xvfb x11vnc fluxbox \
    novnc websockify wget procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Install Python Bridge
RUN pip install --no-cache-dir mt5linux rpyc

# 3. Download MT5 and Python Windows Installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe
RUN wget -q https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe -O /root/py_setup.exe

COPY --from=st-builder /work/st /usr/bin/st
COPY bot.py /root/bot.py

# 4. Entrypoint Script
RUN echo '#!/bin/bash\n\
# Initialize Xvfb\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 2\n\
\n\
# Start Fluxbox and VNC (Shared mode prevents the Disconnect popup)\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# First run of Wine to create the folder structure\n\
wine boot --init\n\
echo "Waiting for Wine to initialize..."\n\
sleep 30\n\
\n\
# Start MT5 and the Bridge\n\
wine /root/mt5setup.exe &\n\
sleep 15\n\
wine python -m mt5linux &\n\
\n\
# Start the Bot\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
