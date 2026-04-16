#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
💎 VALETUTAX MT5 BOT – RAILWAY-READY
- Auto-detects environment (Windows vs Linux)
- Uses mt5linux bridge on Railway
- Infinite retry logic for connection
- Real broker data, no simulation
"""

import time
import sys
import os
from datetime import datetime
from collections import deque

# ============= CONFIGURATION =============
CONFIG = {
    "SYMBOLS": ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD"],
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

# ============= MT5 IMPORT (AUTO-DETECT ENVIRONMENT) =============
print("=" * 60)
print("🔍 DETECTING ENVIRONMENT...")
print("=" * 60)

# Check if we are running on Linux (Railway)
if os.name != 'nt':
    try:
        from mt5linux import MetaTrader5
        mt5 = MetaTrader5(host='localhost', port=8001)
        print("✅ Using mt5linux Bridge (Linux/Railway)")
        NATIVE_MODE = False
    except ImportError:
        print("❌ mt5linux not found! Install it with: pip install mt5linux")
        sys.exit(1)
else:
    try:
        import MetaTrader5 as mt5
        print("✅ Using Native MetaTrader5 (Windows)")
        NATIVE_MODE = True
    except ImportError:
        print("❌ MetaTrader5 not found! Install it with: pip install MetaTrader5")
        sys.exit(1)

# ============= MT5 BRIDGE WITH RETRY LOGIC =============
def get_mt5_connection():
    """Connect to MT5 with retry logic (critical for Railway)"""
    print("\n" + "=" * 60)
    print("🔌 CONNECTING TO MT5...")
    print("=" * 60)
    
    attempt = 1
    # On Railway, Wine takes a long time to start. We loop until it works.
    while True:
        try:
            print(f"   [Attempt {attempt}] Connecting to MT5...")
            if mt5.initialize():
                print(f"✅ MT5 connected successfully!")
                return True
            else:
                print(f"   ⚠️ Initialize failed: {mt5.last_error() if NATIVE_MODE else 'Bridge not ready'}")
        except Exception as e:
            print(f"   ⏳ Waiting for Bridge/Wine... ({e})")
        
        attempt += 1
        time.sleep(5) # Wait 5 seconds between retries

# Get MT5 connection
if not get_mt5_connection():
    sys.exit(1)

class RealMT5OFIBot:
    def __init__(self):
        self.connected = False
        self.tick_buffers = {}
        self.last_trade_time = {}
        self.daily_trades = 0
        self.daily_pnl = 0
        self.daily_start = datetime.now()
        self.initial_balance = 0
        self.running = True
        
    def connect_mt5(self):
        """Verify MT5 connection and get account info"""
        print("\n" + "=" * 60)
        print("💰 ACCOUNT INFORMATION")
        print("=" * 60)
        
        try:
            account_info = mt5.account_info()
            if account_info:
                self.initial_balance = account_info.balance
                print(f"✅ Account: {account_info.login}")
                print(f"   Balance: ${account_info.balance:.2f}")
                print(f"   Server: {account_info.server}")
            else:
                return False
        except Exception as e:
            print(f"❌ Error: {e}")
            return False
        
        # Enable symbols
        for symbol in CONFIG["SYMBOLS"]:
            mt5.symbol_select(symbol, True)
            self.tick_buffers[symbol] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
        
        self.connected = True
        return True
    
    def get_real_ticks(self, symbol):
        """Get REAL ticks from MT5 broker feed"""
        try:
            # COPY_TICKS_ALL is 1
            ticks = mt5.copy_ticks_from(symbol, datetime.now(), CONFIG["LOOKBACK_TICKS"], 1)
            if ticks is None or len(ticks) == 0: return []
            
            result = []
            for tick in ticks:
                # Handle bridge list format
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
        buffer = self.tick_buffers[symbol]
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
        
        request = {
            "action": 1,
            "symbol": symbol,
            "volume": CONFIG["LOT_SIZE"],
            "type": order_type,
            "price": price,
            "magic": 2026,
            "comment": f"OFI {ofi_data['ratio']}x",
            "type_time": 0,
            "type_filling": 1,
        }
        
        res = mt5.order_send(request)
        if res and res.retcode == 10009:
            self.daily_trades += 1
            print(f"✅ {action} {symbol} at {price}")

    def run(self):
        if not self.connect_mt5(): return
        print("\n🚀 BOT RUNNING...")
        while self.running:
            for symbol in CONFIG["SYMBOLS"]:
                ticks = self.get_real_ticks(symbol)
                for t in ticks: self.tick_buffers[symbol].append(t)
                
                ofi = self.calculate_ofi(symbol)
                if ofi:
                    if ofi["ratio"] >= CONFIG["OFI_THRESHOLD"]:
                        self.execute_trade(symbol, "BUY", ofi)
                    elif ofi["ratio"] <= 1.0 / CONFIG["OFI_THRESHOLD"]:
                        self.execute_trade(symbol, "SELL", ofi)
            
            time.sleep(CONFIG["SLEEP_INTERVAL"])

if __name__ == "__main__":
    bot = RealMT5OFIBot()
    bot.run()
