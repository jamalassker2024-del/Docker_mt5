#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time
import sys
import os
from datetime import datetime
from collections import deque

# ================= CONFIG =================
CONFIG = {
    "SYMBOLS": [
        # Forex
        "EURUSD.vx", "GBPUSD.vx", "USDJPY.vx", "AUDUSD.vx", "USDCAD.vx",
        
        # Crypto (from your screenshot)
        "BTCUSD.vx", "ETHUSD.vx", "XRPUSD.vx",
        "LTCUSD.vx", "DOGEUSD.vx", "BCHUSD.vx", "BTCEUR.vx"
    ],
    
    "LOT_SIZE": 0.01,
    "LOOKBACK_TICKS": 50,
    "OFI_THRESHOLD": 1.3,

    # 🔥 Adjusted for crypto
    "TAKE_PROFIT_PIPS": 20,
    "STOP_LOSS_PIPS": 15,
    "MAX_SPREAD_PIPS": 50,   # crypto spreads are bigger

    "COOLDOWN_SECONDS": 5,
    "SLEEP_INTERVAL": 0.5,
}

# ================= MT5 =================
print("🔌 Connecting to MT5...")

if os.name != 'nt':
    from mt5linux import MetaTrader5
    mt5 = MetaTrader5(host='127.0.0.1', port=8001)
else:
    import MetaTrader5 as mt5

for i in range(20):
    if mt5.initialize():
        print("✅ Connected")
        break
    print(f"⏳ Waiting MT5 {i}")
    time.sleep(3)
else:
    print("❌ Failed to connect")
    sys.exit(1)

# ================= BOT =================
class Bot:
    def __init__(self):
        self.buffers = {}

    def setup(self):
        print("\n🔍 Loading symbols...")
        all_symbols = [s.name for s in mt5.symbols_get()]

        for s in CONFIG["SYMBOLS"]:
            if s in all_symbols:
                mt5.symbol_select(s, True)
                self.buffers[s] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                print(f"✅ {s}")
            else:
                print(f"❌ Missing: {s}")

    def get_ticks(self, symbol):
        try:
            ticks = mt5.copy_ticks_from(symbol, datetime.now(), 50, 1)
            if not ticks:
                return []

            parsed = []
            for t in ticks:
                if isinstance(t, (list, tuple)):
                    is_buy = bool(t[2] & 4)
                else:
                    is_buy = bool(t.flags & 4)

                parsed.append({"is_buy": is_buy})

            return parsed
        except:
            return []

    def ofi(self, symbol):
        buf = self.buffers[symbol]
        if len(buf) < 10:
            return None

        buys = sum(1 for x in buf if x["is_buy"])
        sells = len(buf) - buys or 1

        return buys / sells

    def has_pos(self, symbol):
        p = mt5.positions_get(symbol=symbol)
        return p and len(p) > 0

    def trade(self, symbol, action):
        if self.has_pos(symbol):
            return

        tick = mt5.symbol_info_tick(symbol)
        info = mt5.symbol_info(symbol)
        if not tick or not info:
            return

        spread = (tick.ask - tick.bid) / info.point
        if spread > CONFIG["MAX_SPREAD_PIPS"]:
            print(f"⚠️ Spread high {symbol}: {spread:.1f}")
            return

        price = tick.ask if action == "BUY" else tick.bid
        order_type = 0 if action == "BUY" else 1

        tp = price + (CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10) if action == "BUY" else price - (CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10)
        sl = price - (CONFIG["STOP_LOSS_PIPS"] * info.point * 10) if action == "BUY" else price + (CONFIG["STOP_LOSS_PIPS"] * info.point * 10)

        req = {
            "action": 1,
            "symbol": symbol,
            "volume": CONFIG["LOT_SIZE"],
            "type": order_type,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 20,
            "magic": 2026,
            "comment": "OFI-CRYPTO",
            "type_time": 0,
            "type_filling": 1,
        }

        res = mt5.order_send(req)

        if res and res.retcode == 10009:
            print(f"🔥 {action} {symbol}")
        else:
            print(f"❌ Failed {symbol}: {res}")

    def run(self):
        self.setup()

        print("\n🚀 BOT LIVE (FOREX + CRYPTO)\n")

        while True:
            for s in self.buffers:
                ticks = self.get_ticks(s)
                for t in ticks:
                    self.buffers[s].append(t)

                ratio = self.ofi(s)
                if not ratio:
                    continue

                print(f"{s} → {ratio:.2f}")

                if ratio >= CONFIG["OFI_THRESHOLD"]:
                    self.trade(s, "BUY")
                    time.sleep(CONFIG["COOLDOWN_SECONDS"])

                elif ratio <= 1 / CONFIG["OFI_THRESHOLD"]:
                    self.trade(s, "SELL")
                    time.sleep(CONFIG["COOLDOWN_SECONDS"])

            time.sleep(CONFIG["SLEEP_INTERVAL"])


if __name__ == "__main__":
    Bot().run()
