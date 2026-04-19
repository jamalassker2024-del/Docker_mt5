#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time
import sys
import os
from datetime import datetime
from collections import deque

import MetaTrader5 as mt5


CONFIG = {
    "SYMBOLS": [
        "EURUSD.vx", "GBPUSD.vx", "BTCUSD.vx", "ETHUSD.vx"
    ],
    "LOT_SIZE": 0.01,
    "LOOKBACK_TICKS": 30,
    "OFI_THRESHOLD": 1.2,
    "TAKE_PROFIT_PIPS": 20,
    "STOP_LOSS_PIPS": 15,
    "MAX_SPREAD_PIPS": 60,
    "SLEEP_INTERVAL": 0.5,
}


# ================= MT5 INIT =================
print("\n==============================")
print("🔌 MT5 INITIALIZATION")
print("==============================")

if not mt5.initialize():
    print("❌ MT5 INIT FAILED")
    print("ERROR:", mt5.last_error())
    sys.exit(1)

print("✅ MT5 Connected")
print("ACCOUNT:", mt5.account_info())


class OFIBot:

    def __init__(self):
        self.buffers = {}

    # ================= SETUP =================
    def setup(self):
        print("\n🔍 Loading symbols...\n")

        symbols = mt5.symbols_get()
        available = [s.name for s in symbols] if symbols else []

        print(f"📊 Available symbols: {len(available)}")

        for sym in CONFIG["SYMBOLS"]:
            if sym in available:
                if mt5.symbol_select(sym, True):
                    self.buffers[sym] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                    print(f"✅ Activated: {sym}")
                else:
                    print(f"❌ Failed to select: {sym}")
            else:
                print(f"❌ Missing: {sym}")

        if not self.buffers:
            print("❌ No valid symbols → STOP")
            sys.exit(1)

    # ================= TICKS =================
    def get_ticks(self, symbol):
        try:
            ticks = mt5.copy_ticks_from(symbol, datetime.now(), 200, mt5.COPY_TICKS_ALL)

            if ticks is None:
                print(f"⚠️ {symbol} ticks = None | ERR:", mt5.last_error())
                return []

            if len(ticks) == 0:
                print(f"⚠️ No ticks: {symbol}")
                return []

            parsed = []
            for t in ticks:
                is_buy = t.ask > t.bid
                parsed.append({"is_buy": is_buy})

            return parsed[-CONFIG["LOOKBACK_TICKS"]:]

        except Exception as e:
            print(f"❌ Tick error {symbol}: {e}")
            return []

    # ================= OFI =================
    def ofi(self, symbol):
        buf = self.buffers[symbol]

        if len(buf) < 10:
            return None

        buys = sum(1 for x in buf if x["is_buy"])
        sells = len(buf) - buys or 1

        return buys / sells

    # ================= POSITION =================
    def has_position(self, symbol):
        pos = mt5.positions_get(symbol=symbol)
        return pos is not None and len(pos) > 0

    # ================= TRADE =================
    def trade(self, symbol, direction):

        if self.has_position(symbol):
            print(f"⚠️ Already open: {symbol}")
            return

        tick = mt5.symbol_info_tick(symbol)
        info = mt5.symbol_info(symbol)

        if not tick or not info:
            print(f"❌ No tick/info: {symbol} | ERR:", mt5.last_error())
            return

        spread = (tick.ask - tick.bid) / info.point
        print(f"📏 Spread {symbol}: {spread:.2f}")

        if spread > CONFIG["MAX_SPREAD_PIPS"]:
            print("⚠️ Spread too high")
            return

        price = tick.ask if direction == "BUY" else tick.bid

        order_type = mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL

        tp = price + CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10 if direction == "BUY" else price - CONFIG["TAKE_PROFIT_PIPS"] * info.point * 10
        sl = price - CONFIG["STOP_LOSS_PIPS"] * info.point * 10 if direction == "BUY" else price + CONFIG["STOP_LOSS_PIPS"] * info.point * 10

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": CONFIG["LOT_SIZE"],
            "type": order_type,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 20,
            "magic": 2026,
            "comment": "OFI-BOT",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }

        print("\n📤 SENDING ORDER:", request)

        res = mt5.order_send(request)

        if res is None:
            print("❌ ORDER FAILED (None)")
            print("MT5 ERROR:", mt5.last_error())
            return

        print("\n📩 ORDER RESPONSE:")
        print("retcode:", res.retcode)
        print("comment:", res.comment)
        print("deal:", res.deal)
        print("order:", res.order)

        if res.retcode == mt5.TRADE_RETCODE_DONE:
            print(f"🔥 TRADE OPENED: {direction} {symbol}")
        else:
            print("❌ TRADE REJECTED")
            print("REASON:", mt5.last_error())

    # ================= MAIN LOOP =================
    def run(self):

        self.setup()

        print("\n🚀 BOT STARTED (DEBUG MODE)\n")

        while True:

            for symbol in self.buffers:

                print("\n==============================")
                print("🔎 SYMBOL:", symbol)

                ticks = self.get_ticks(symbol)

                print("📊 ticks:", len(ticks))

                for t in ticks:
                    self.buffers[symbol].append(t)

                ratio = self.ofi(symbol)

                print("📈 OFI:", ratio)

                if ratio is None:
                    print("⚠️ waiting data...")
                    continue

                if ratio >= CONFIG["OFI_THRESHOLD"]:
                    print("🟢 BUY SIGNAL")
                    self.trade(symbol, "BUY")

                elif ratio <= 1 / CONFIG["OFI_THRESHOLD"]:
                    print("🔴 SELL SIGNAL")
                    self.trade(symbol, "SELL")

                else:
                    print("⏸ no signal")

            time.sleep(CONFIG["SLEEP_INTERVAL"])


if __name__ == "__main__":
    bot = OFIBot()
    bot.run()
