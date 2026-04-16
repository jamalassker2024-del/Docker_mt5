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

# 1. Enable 32-bit architecture and install dependencies
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y \
    wine64 wine wine32 \
    xvfb x11vnc \
    novnc websockify fluxbox \
    wget unzip procps git \
    && rm -rf /var/lib/apt/lists/*

# 2. Install Python trading bridge
RUN pip install mt5linux

# 3. Setup noVNC web access
RUN ln -s /usr/share/novnc/vnc.html /usr/share/novnc/index.html

# 4. Copy the terminal we built in Stage 1
COPY --from=st-builder /work/st /usr/bin/st

# 5. Create a robust startup script
RUN echo '#!/bin/bash\n\
# Start Virtual Display\n\
Xvfb :0 -screen 0 1280x1024x24 &\n\
sleep 2\n\
\n\
# Start Window Manager and VNC\n\
fluxbox &\n\
x11vnc -display :0 -forever -nopw -listen localhost -rfbport 5900 &\n\
\n\
# Start the web bridge for your browser link\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
# Download MT5 if it does not exist\n\
if [ ! -f "/root/mt5setup.exe" ]; then\n\
  wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe\n\
fi\n\
\n\
# Automatically launch the installer on the screen\n\
wine /root/mt5setup.exe &\n\
\n\
# Start the Python bridge for your bot\n\
python3 -m mt5linux &\n\
\n\
# Keep the container running\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

# Railway settings
EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
