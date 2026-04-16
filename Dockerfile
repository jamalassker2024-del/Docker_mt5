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

# 1. Enable 32-bit support and install system dependencies
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine wine32 \
    xvfb x11vnc \
    novnc websockify fluxbox \
    wget unzip procps git \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Python trading bridge (Linux side)
RUN pip install mt5linux rpyc

# 3. Setup web access
RUN ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# 4. Copy your project files
COPY --from=st-builder /work/st /usr/bin/st
COPY bot.py /root/bot.py

# 5. INSTALL PYTHON FOR WINDOWS (Inside Wine)
# We need this so mt5linux has a Windows python to talk to
RUN wget -q https://www.python.org/ftp/python/3.10.11/python-3.10.11-amd64.exe -O /root/py_setup.exe \
    && wine /root/py_setup.exe /quiet PrependPath=1 \
    && sleep 10 \
    && wine python -m pip install MetaTrader5 mt5linux rpyc

# 6. Create the Startup Script
RUN echo '#!/bin/bash\n\
# Start Virtual Display\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 3\n\
\n\
# Start Window Manager and VNC\n\
fluxbox &\n\
x11vnc -display :0 -forever -nopw -listen localhost -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# Ensure MT5 installer is ready\n\
if [ ! -f "/root/mt5setup.exe" ]; then\n\
  wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe\n\
fi\n\
\n\
# Start MT5 Terminal automatically\n\
wine /root/mt5setup.exe &\n\
\n\
# Wait for Wine to initialize properly before starting the bridge\n\
echo "Waiting for Wine environment..."\n\
sleep 30\n\
\n\
# Start the Windows-side bridge server\n\
wine python -m mt5linux &\n\
\n\
# Give the bridge 15 seconds to open the port 8001\n\
sleep 15\n\
\n\
# Start your bot\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

# Railway Settings
EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
