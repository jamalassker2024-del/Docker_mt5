#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time
import sys
import os
from datetime import datetime
from collections import deque

# ================= CONFIG =================
CONFIG = {
    "SYMBOLS": ["EURUSD.vx", "GBPUSD.vx", "USDJPY.vx", "AUDUSD.vx", "USDCAD.vx"],
    "LOT_SIZE": 0.01,
    "LOOKBACK_TICKS": 50,
    "OFI_THRESHOLD": 1.3,
    "TAKE_PROFIT_PIPS": 10,
    "STOP_LOSS_PIPS": 8,
    "MAX_SPREAD_PIPS": 3,
    "COOLDOWN_SECONDS": 5,
    "SLEEP_INTERVAL": 0.5,
}

# ================= MT5 INIT =================
print("="*60)
print("🔌 CONNECTING TO MT5 (BRIDGE)...")
print("="*60)

if os.name != 'nt':
    from mt5linux import MetaTrader5
    mt5 = MetaTrader5(host='127.0.0.1', port=8001)
else:
    import MetaTrader5 as mt5

# Retry connection
for i in range(20):
    if mt5.initialize():
        print("✅ Connected to MT5")
        break
    print(f"⏳ Waiting for MT5... ({i})")
    time.sleep(3)
else:
    print("❌ Cannot connect to MT5")
    sys.exit(1)

# ================= BOT =================
class OFIBot:
    def __init__(self):
        self.tick_buffers = {}

    def setup_symbols(self):
        print("\n🔍 Checking .vx symbols...")
        all_symbols = mt5.symbols_get()
        available_names = [s.name for s in all_symbols]

        for symbol in CONFIG["SYMBOLS"]:
            if symbol in available_names:
                mt5.symbol_select(symbol, True)
                self.tick_buffers[symbol] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                print(f"✅ Enabled: {symbol}")
            else:
                print(f"❌ NOT FOUND: {symbol}")

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

    def calculate_ofi(self, symbol):
        buf = self.tick_buffers[symbol]
        if len(buf) < 10:
            return None

        buys = sum(1 for t in buf if t["is_buy"])
        sells = len(buf) - buys
        if sells == 0:
            sells = 1

        return buys / sells

    def has_position(self, symbol):
        pos = mt5.positions_get(symbol=symbol)
        return pos is not None and len(pos) > 0

    def execute_trade(self, symbol, action):
        if self.has_position(symbol):
            print(f"⚠️ Already in trade: {symbol}")
            return

        tick = mt5.symbol_info_tick(symbol)
        info = mt5.symbol_info(symbol)

        if not tick or not info:
            print(f"❌ No tick/info: {symbol}")
            return

        spread = (tick.ask - tick.bid) / info.point
        if spread > CONFIG["MAX_SPREAD_PIPS"]:
            print(f"⚠️ Spread too high {symbol}: {spread:.2f}")
            return

        price = tick.ask if action == "BUY" else tick.bid
        order_type = 0 if action == "BUY" else 1

        tp = price + (CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10) if action == "BUY" else price - (CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10)
        sl = price - (CONFIG["STOP_LOSS_PIPS"] * info.point * 10) if action == "BUY" else price + (CONFIG["STOP_LOSS_PIPS"] * info.point * 10)

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
            "comment": "OFI.vx",
            "type_time": 0,
            "type_filling": 1,
        }

        res = mt5.order_send(request)

        if res and res.retcode == 10009:
            print(f"🔥 {action} {symbol} @ {price}")
        else:
            print(f"❌ Trade failed: {symbol} | {res}")

    def test_trade(self):
        print("\n🧪 TEST TRADE...")
        for s in self.tick_buffers.keys():
            tick = mt5.symbol_info_tick(s)
            if tick:
                self.execute_trade(s, "BUY")
                break

    def run(self):
        self.setup_symbols()

        if not self.tick_buffers:
            print("❌ No valid .vx symbols → bot stopped")
            return

        self.test_trade()

        print("\n🚀 BOT RUNNING (.vx)...\n")

        while True:
            for symbol in self.tick_buffers.keys():
                ticks = self.get_ticks(symbol)

                for t in ticks:
                    self.tick_buffers[symbol].append(t)

                ratio = self.calculate_ofi(symbol)

                if ratio:
                    print(f"{symbol} OFI: {ratio:.2f}")

                    if ratio >= CONFIG["OFI_THRESHOLD"]:
                        self.execute_trade(symbol, "BUY")
                        time.sleep(CONFIG["COOLDOWN_SECONDS"])

                    elif ratio <= 1 / CONFIG["OFI_THRESHOLD"]:
                        self.execute_trade(symbol, "SELL")
                        time.sleep(CONFIG["COOLDOWN_SECONDS"])

            time.sleep(CONFIG["SLEEP_INTERVAL"])


# ================= RUN =================
if __name__ == "__main__":
    bot = OFIBot()
    bot.run()
