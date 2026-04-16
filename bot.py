#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
💎 VALETUTAX MT5 BOT – RAILWAY-READY
"""

import time
import sys
import os
from datetime import datetime
from collections import deque

# ============= CONFIGURATION =============
CONFIG = {
    "SYMBOLS": ["EURUSD.vx", "GBPUSD.vx", "USDJPY.vx", "AUDUSD.vx", "USDCAD.vx"],
    "LOT_SIZE": 0.01,
    "MAX_LOT_SIZE": 0.10,
    "LOOKBACK_TICKS": 50,
    "OFI_THRESHOLD": 2.5,
    "TAKE_PROFIT_PIPS": 10,
    "STOP_LOSS_PIPS": 8,
    "MAX_SPREAD_PIPS": 3,
    "COOLDOWN_SECONDS": 3,
    "MAX_DAILY_TRADES": 100,
    "MAX_RISK_PER_TRADE": 2.0,
    "SLEEP_INTERVAL": 0.2,
}

# ============= MT5 IMPORT =============
print("=" * 60)
print("🔍 DETECTING ENVIRONMENT...")
print("=" * 60)

if os.name != 'nt':
    try:
        from mt5linux import MetaTrader5
        # Set host to 127.0.0.1 explicitly to ensure bridge connection
        mt5 = MetaTrader5(host='127.0.0.1', port=8001)
        print("✅ Using mt5linux Bridge (Linux/Railway)")
        NATIVE_MODE = False
    except ImportError:
        print("❌ mt5linux not found!")
        sys.exit(1)
else:
    try:
        import MetaTrader5 as mt5
        print("✅ Using Native MetaTrader5 (Windows)")
        NATIVE_MODE = True
    except ImportError:
        print("❌ MetaTrader5 not found!")
        sys.exit(1)

def get_mt5_connection():
    print("\n" + "=" * 60)
    print("🔌 CONNECTING TO MT5...")
    print("=" * 60)
    
    attempt = 1
    while True:
        try:
            print(f"   [Attempt {attempt}] Connecting to MT5...")
            # Note: mt5linux bridge needs MT5 terminal to be OPEN first
            if mt5.initialize():
                print(f"✅ MT5 connected successfully!")
                return True
            else:
                err = mt5.last_error() if NATIVE_MODE else "Check Bridge/Wine"
                print(f"   ⚠️ Initialize failed: {err}")
        except Exception as e:
            print(f"   ⏳ Waiting for Bridge... ({e})")
        
        attempt += 1
        if attempt > 20: # Safety break to see logs
             print("❌ Failed to connect after many attempts. Check if MT5 is actually running in noVNC.")
        time.sleep(5)

if not get_mt5_connection():
    sys.exit(1)

class RealMT5OFIBot:
    def __init__(self):
        self.tick_buffers = {}
        self.daily_trades = 0
        self.initial_balance = 0
        self.running = True
        
    def connect_mt5(self):
        print("\n" + "=" * 60)
        print("💰 ACCOUNT & SYMBOL SETUP")
        print("=" * 60)
        
        try:
            account_info = mt5.account_info()
            if account_info:
                self.initial_balance = account_info.balance
                print(f"✅ Account: {account_info.login} | Balance: ${account_info.balance:.2f}")
            else:
                return False
        except Exception as e:
            print(f"❌ Account Error: {e}")
            return False
        
        for symbol in CONFIG["SYMBOLS"]:
            selected = mt5.symbol_select(symbol, True)
            if selected:
                print(f"✅ Symbol {symbol} is active")
                self.tick_buffers[symbol] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
            else:
                print(f"⚠️ Warning: Could not find/select {symbol}")
        
        return True
    
    def get_real_ticks(self, symbol):
        try:
            ticks = mt5.copy_ticks_from(symbol, datetime.now(), CONFIG["LOOKBACK_TICKS"], 1)
            if ticks is None or len(ticks) == 0: return []
            
            result = []
            for tick in ticks:
                # Handling list format often returned by mt5linux
                if isinstance(tick, (list, tuple)):
                    is_buy = bool(tick[2] & 4) 
                    result.append({"symbol": symbol, "price": tick[1], "is_buy": is_buy})
                else:
                    is_buy = bool(tick.flags & 4)
                    result.append({"symbol": symbol, "price": tick.ask if is_buy else tick.bid, "is_buy": is_buy})
            return result
        except:
            return []
    
    def calculate_ofi(self, symbol):
        buffer = self.tick_buffers.get(symbol, [])
        if len(buffer) < 10: return None
        buy_ticks = sum(1 for tick in buffer if tick.get("is_buy"))
        sell_ticks = len(buffer) - buy_ticks
        ratio = buy_ticks / (sell_ticks if sell_ticks > 0 else 0.1)
        return {"ratio": round(ratio, 2), "buy": buy_ticks, "sell": sell_ticks}

    def execute_trade(self, symbol, action, ofi_data):
        if self.daily_trades >= CONFIG["MAX_DAILY_TRADES"]: return
        
        tick = mt5.symbol_info_tick(symbol)
        if not tick: return
        
        order_type = 0 if action == "BUY" else 1 
        price = tick.ask if action == "BUY" else tick.bid
        
        symbol_info = mt5.symbol_info(symbol)
        point = symbol_info.point
        tp = price + (CONFIG["TAKE_PROFIT_PIPS"] * 10 * point) if action == "BUY" else price - (CONFIG["TAKE_PROFIT_PIPS"] * 10 * point)
        sl = price - (CONFIG["STOP_LOSS_PIPS"] * 10 * point) if action == "BUY" else price + (CONFIG["STOP_LOSS_PIPS"] * 10 * point)

        request = {
            "action": 1,
            "symbol": symbol,
            "volume": CONFIG["LOT_SIZE"],
            "type": order_type,
            "price": price,
            "sl": sl,
            "tp": tp,
            "magic": 2026,
            "comment": f"OFI {ofi_data['ratio']}x",
            "type_time": 0,
            "type_filling": 1,
        }
        
        res = mt5.order_send(request)
        if res and res.retcode == 10009:
            self.daily_trades += 1
            print(f"🔥 {action} EXECUTED: {symbol} @ {price} | OFI: {ofi_data['ratio']}x")
        else:
            comment = res.comment if res else 'Unknown Error'
            print(f"❌ Trade failed for {symbol}: {comment}")

    def run(self):
        if not self.connect_mt5(): return
        print("\n🚀 VALETUTAX BOT IS LIVE AND TRADING...")
        
        while self.running:
            for symbol in self.tick_buffers.keys():
                ticks = self.get_real_ticks(symbol)
                for t in ticks: self.tick_buffers[symbol].append(t)
                
                ofi = self.calculate_ofi(symbol)
                if ofi:
                    if ofi["ratio"] >= CONFIG["OFI_THRESHOLD"]:
                        self.execute_trade(symbol, "BUY", ofi)
                        time.sleep(CONFIG["COOLDOWN_SECONDS"])
                    elif ofi["ratio"] <= 1.0 / CONFIG["OFI_THRESHOLD"]:
                        self.execute_trade(symbol, "SELL", ofi)
                        time.sleep(CONFIG["COOLDOWN_SECONDS"])
            
            time.sleep(CONFIG["SLEEP_INTERVAL"])

if __name__ == "__main__":
    bot = RealMT5OFIBot()
    bot.run()
