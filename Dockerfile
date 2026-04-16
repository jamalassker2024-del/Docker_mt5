# Base image
FROM python:3.11-slim-bookworm

ENV DEBIAN_FRONTEND=noninteractive
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV WINEDEBUG=-all

USER root

# Install dependencies
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine64 wine32 winbind xvfb fluxbox x11vnc novnc websockify procps wget cabextract unzip \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Python libs
RUN pip install --no-cache-dir mt5linux rpyc

# Download MT5 during build (NOT runtime)
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /mt5setup.exe

# Setup Wine + install MT5 silently
RUN Xvfb :0 -screen 0 1024x768x16 & \
    sleep 2 && \
    wineboot --init && sleep 5 && \
    wine /mt5setup.exe /silent && sleep 20

# Copy bot
COPY bot.py /root/bot.py

# Entrypoint
RUN echo '#!/bin/bash\n\
echo "Starting virtual display..."\n\
Xvfb :0 -screen 0 1024x768x16 &\n\
sleep 2\n\
fluxbox &\n\
\n\
echo "Starting VNC..."\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
echo "Starting MT5..."\n\
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" &\n\
\n\
echo "Waiting for MT5..."\n\
while ! pgrep -f terminal64.exe > /dev/null; do\n\
    sleep 2\n\
done\n\
\n\
echo "Starting bridge..."\n\
python3 -m mt5linux --port 8001 &\n\
\n\
echo "Starting bot..."\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080

CMD ["/bin/bash", "/entrypoint.sh"]
