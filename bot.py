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
        "EURUSD.vx", "GBPUSD.vx", "USDJPY.vx",
        "AUDUSD.vx", "USDCAD.vx",
        "BTCUSD.vx", "ETHUSD.vx", "XRPUSD.vx",
        "LTCUSD.vx", "DOGEUSD.vx"
    ],

    "LOT_SIZE": 0.01,
    "LOOKBACK_TICKS": 30,

    # more realistic for crypto + forex mix
    "OFI_THRESHOLD": 1.2,

    "TAKE_PROFIT_PIPS": 20,
    "STOP_LOSS_PIPS": 15,

    "MAX_SPREAD_PIPS": 60,

    "COOLDOWN_SECONDS": 3,
    "SLEEP_INTERVAL": 0.5,
}

# ================= MT5 CONNECT =================
print("=" * 60)
print("🔌 CONNECTING TO MT5 BRIDGE")
print("=" * 60)

if os.name != 'nt':
    from mt5linux import MetaTrader5
    mt5 = MetaTrader5(host='127.0.0.1', port=8001)
else:
    import MetaTrader5 as mt5

for i in range(30):
    if mt5.initialize():
        print("✅ MT5 Connected")
        break
    print(f"⏳ Waiting MT5... {i}")
    time.sleep(2)
else:
    print("❌ MT5 connection failed")
    sys.exit(1)

# ================= BOT =================
class OFIBot:

    def __init__(self):
        self.buffers = {}

    # ---------- SYMBOL SETUP ----------
    def setup(self):
        print("\n🔍 Loading symbols...\n")

        available = [s.name for s in mt5.symbols_get()]

        for sym in CONFIG["SYMBOLS"]:
            if sym in available:
                mt5.symbol_select(sym, True)
                self.buffers[sym] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                print(f"✅ Active: {sym}")
            else:
                print(f"❌ Missing: {sym}")

        if not self.buffers:
            print("❌ No symbols available → STOP")
            sys.exit(1)

    # ---------- GET TICKS ----------
    def get_ticks(self, symbol):
        try:
            ticks = mt5.copy_ticks_from(symbol, datetime.now(), 50, 1)

            if ticks is None or len(ticks) == 0:
                print(f"⚠️ No ticks: {symbol}")
                return []

            parsed = []
            for t in ticks:
                if isinstance(t, (list, tuple)):
                    is_buy = bool(t[2] & 4)
                else:
                    is_buy = bool(t.flags & 4)

                parsed.append({"is_buy": is_buy})

            return parsed

        except Exception as e:
            print(f"❌ Tick error {symbol}: {e}")
            return []

    # ---------- OFI ----------
    def ofi(self, symbol):
        buf = self.buffers[symbol]

        if len(buf) < 10:
            return None

        buys = sum(1 for x in buf if x["is_buy"])
        sells = len(buf) - buys or 1

        return buys / sells

    # ---------- POSITION CHECK ----------
    def has_position(self, symbol):
        pos = mt5.positions_get(symbol=symbol)
        return pos is not None and len(pos) > 0

    # ---------- TRADE EXECUTION ----------
    def trade(self, symbol, direction):

        if self.has_position(symbol):
            print(f"⚠️ Already open: {symbol}")
            return

        tick = mt5.symbol_info_tick(symbol)
        info = mt5.symbol_info(symbol)

        if not tick or not info:
            print(f"❌ No tick/info: {symbol}")
            return

        spread = (tick.ask - tick.bid) / info.point
        print(f"📏 Spread {symbol}: {spread:.2f}")

        if spread > CONFIG["MAX_SPREAD_PIPS"]:
            print("⚠️ Spread too high → skip")
            return

        price = tick.ask if direction == "BUY" else tick.bid
        order_type = 0 if direction == "BUY" else 1

        tp = price + CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10 if direction == "BUY" else price - CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10
        sl = price - CONFIG["STOP_LOSS_PIPS"] * info.point * 10 if direction == "BUY" else price + CONFIG["STOP_LOSS_PIPS"] * info.point * 10

        request = {
            "action": 1,
            "symbol": symbol,
            "volume": CONFIG["LOT_SIZE"],
            "type": order_type,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 20,
            "magic": 2026,
            "comment": "OFI-BOT",
            "type_time": 0,
            "type_filling": 1,
        }

        res = mt5.order_send(request)

        # ---------- DEBUG RESULT ----------
        if res:
            print(f"📩 ORDER: retcode={res.retcode} comment={res.comment}")

            if res.retcode == 10009:
                print(f"🔥 TRADE OPENED: {direction} {symbol} @ {price}")
            else:
                print(f"❌ REJECTED: {symbol}")
        else:
            print("❌ No response from broker")

    # ---------- MAIN LOOP ----------
    def run(self):

        self.setup()

        print("\n🚀 BOT STARTED (FULL DEBUG MODE)\n")

        while True:

            for symbol in self.buffers:

                print(f"\n🔎 Checking: {symbol}")

                ticks = self.get_ticks(symbol)

                print(f"Ticks: {len(ticks)}")

                for t in ticks:
                    self.buffers[symbol].append(t)

                print(f"Buffer: {len(self.buffers[symbol])}")

                ratio = self.ofi(symbol)

                if ratio is None:
                    print("⚠️ Not enough data")
                    continue

                print(f"📊 OFI: {ratio:.2f}")

                if ratio >= CONFIG["OFI_THRESHOLD"]:
                    print("🟢 BUY SIGNAL")
                    self.trade(symbol, "BUY")

                elif ratio <= 1 / CONFIG["OFI_THRESHOLD"]:
                    print("🔴 SELL SIGNAL")
                    self.trade(symbol, "SELL")

                else:
                    print("⏸ No trade signal")

            time.sleep(CONFIG["SLEEP_INTERVAL"])


# ================= START =================
if __name__ == "__main__":
    bot = OFIBot()
    bot.run()
