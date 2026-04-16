FROM python:3.11-slim-bookworm

USER root
ENV WINEPREFIX=/root/.wine
ENV WINEARCH=win64
ENV DISPLAY=:0
ENV DEBIAN_FRONTEND=noninteractive
ENV WINEDEBUG=-all 

# Install dependencies + stable Wine branch
RUN dpkg --add-architecture i386 && apt-get update && apt-get install -y --no-install-recommends \
    wine64 wine32 winbind xvfb fluxbox x11vnc novnc websockify procps wget \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir mt5linux rpyc

# Fetch MT5 Installer
RUN wget -q https://download.mql5.com/cdn/web/metaquotes.software.corp/mt5/mt5setup.exe -O /root/mt5setup.exe

COPY bot.py /root/bot.py

# Entrypoint with automatic check for terminal
RUN echo '#!/bin/bash\n\
Xvfb :0 -screen 0 1024x768x16 &\n\
sleep 2\n\
fluxbox &\n\
x11vnc -display :0 -forever -shared -nopw -rfbport 5900 &\n\
websockify --web /usr/share/novnc/ 8080 localhost:5900 &\n\
\n\
wineboot --init > /dev/null 2>&1\n\
sleep 5\n\
\n\
# Silent install if not exists\n\
if [ ! -f "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]; then\n\
    echo "Installing MT5..."\n\
    wine /root/mt5setup.exe /silent\n\
    sleep 30\n\
fi\n\
\n\
echo "Starting MT5..."\n\
wine "/root/.wine/drive_c/Program Files/MetaTrader 5/terminal64.exe" &\n\
\n\
echo "Starting Bridge..."\n\
python3 -m mt5linux --port 8001 &\n\
\n\
sleep 20\n\
echo "Starting Bot..."\n\
python3 /root/bot.py\n\
\n\
wait' > /entrypoint.sh && chmod +x /entrypoint.sh

EXPOSE 8080
CMD ["/bin/bash", "/entrypoint.sh"]
