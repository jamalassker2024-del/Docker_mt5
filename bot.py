#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
💎 VALETUTAX MT5 BOT – LINUX/WINE COMPATIBLE (RAILWAY)
- Waits for mt5linux bridge to be ready
- Retry logic for connection
- Real broker data, no simulation
"""

import time
import os
import sys
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

# ============= MT5 BRIDGE WITH RETRY LOGIC =============
def get_mt5_connection():
    """Wait for mt5linux bridge to be ready and connect"""
    print("📦 Waiting for mt5linux bridge to start...")
    print("   (This may take 1-2 minutes on first run)")
    
    # Try to import mt5linux
    try:
        from mt5linux import MetaTrader5
        print("✅ mt5linux library loaded")
    except ImportError as e:
        print(f"❌ Failed to import mt5linux: {e}")
        return None
    
    # Try to connect up to 30 times (every 3 seconds = 90 seconds total)
    for attempt in range(1, 31):
        try:
            print(f"   [Attempt {attempt}/30] Connecting to bridge at localhost:8001...")
            conn = MetaTrader5(host='localhost', port=8001)
            
            if conn.initialize():
                print(f"✅ mt5linux bridge connected on attempt {attempt}")
                return conn
            else:
                print(f"   Initialize returned False")
        except ConnectionRefusedError:
            print(f"   Connection refused - bridge not ready yet")
        except Exception as e:
            print(f"   Error: {e}")
        
        # Wait before retry
        time.sleep(3)
    
    print("❌ Could not connect to bridge after 30 attempts.")
    return None

# Get MT5 connection
mt5 = get_mt5_connection()
if mt5 is None:
    print("❌ Failed to connect to MT5 bridge. Shutting down.")
    print("   Please ensure MT5 is running in noVNC")
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
        """Connect to MT5 via bridge (already connected, just verify)"""
        print("\n" + "="*60)
        print("🚀 VERIFYING MT5 CONNECTION")
        print("="*60)
        
        # Get account info
        try:
            account_info = mt5.account_info()
            if account_info:
                self.initial_balance = account_info.balance
                print(f"✅ Connected to MT5")
                print(f"   Account: {account_info.login}")
                print(f"   Balance: ${account_info.balance:.2f}")
                if account_info.balance < 100:
                    print(f"   (Cent account: {account_info.balance:.0f} cents)")
                print(f"   Leverage: 1:{account_info.leverage}")
                print(f"   Server: {account_info.server}")
            else:
                print("❌ Failed to get account info!")
                return False
        except Exception as e:
            print(f"❌ Error getting account info: {e}")
            return False
        
        # Enable symbols in Market Watch
        for symbol in CONFIG["SYMBOLS"]:
            try:
                info = mt5.symbol_info(symbol)
                if info:
                    if not info.visible:
                        mt5.symbol_select(symbol, True)
                    print(f"✅ {symbol} ready (spread: {info.spread/10:.1f} pips)")
                    self.tick_buffers[symbol] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                else:
                    print(f"⚠️ {symbol} not found - checking with .c suffix...")
                    symbol_c = f"{symbol}.c"
                    info_c = mt5.symbol_info(symbol_c)
                    if info_c:
                        print(f"   Found {symbol_c} instead!")
                        idx = CONFIG["SYMBOLS"].index(symbol)
                        CONFIG["SYMBOLS"][idx] = symbol_c
                        self.tick_buffers[symbol_c] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                    else:
                        print(f"⚠️ {symbol} not available")
            except Exception as e:
                print(f"⚠️ Error setting up {symbol}: {e}")
        
        self.connected = True
        return True
    
    def get_real_ticks(self, symbol):
        """Get REAL ticks from MT5 broker feed via bridge"""
        try:
            now = datetime.now()
            ticks = mt5.copy_ticks_from(symbol, now, CONFIG["LOOKBACK_TICKS"], 1)  # COPY_TICKS_ALL
            
            if ticks is None or len(ticks) == 0:
                return []
            
            result = []
            for tick in ticks:
                # Handle different tick data structures
                if isinstance(tick, (list, tuple)):
                    is_buy = bool(tick[2] & 4) if len(tick) > 2 else False
                    result.append({
                        "symbol": symbol,
                        "price": tick[1] if len(tick) > 1 else 0,
                        "is_buy": is_buy,
                        "volume": tick[5] if len(tick) > 5 else 1,
                        "timestamp": tick[0] if len(tick) > 0 else time.time()
                    })
                elif hasattr(tick, 'flags'):
                    is_buy = bool(tick.flags & 4)
                    result.append({
                        "symbol": symbol,
                        "price": tick.ask if is_buy else tick.bid,
                        "is_buy": is_buy,
                        "volume": tick.volume,
                        "timestamp": tick.time
                    })
            
            return result
        except Exception as e:
            # Silently fail to avoid log spam
            return []
    
    def update_tick_buffer(self, symbol):
        """Update tick buffer with real ticks"""
        ticks = self.get_real_ticks(symbol)
        for tick in ticks:
            self.tick_buffers[symbol].append(tick)
    
    def calculate_ofi(self, symbol):
        """Calculate Order Flow Imbalance from real ticks"""
        buffer = self.tick_buffers[symbol]
        if len(buffer) < 10:
            return None
        
        buy_ticks = sum(1 for tick in buffer if tick.get("is_buy", False))
        sell_ticks = len(buffer) - buy_ticks
        
        if sell_ticks == 0:
            ratio = 999 if buy_ticks > 0 else 1.0
        else:
            ratio = buy_ticks / sell_ticks
        
        return {
            "ratio": round(ratio, 2),
            "buy_ticks": buy_ticks,
            "sell_ticks": sell_ticks,
            "total_ticks": len(buffer)
        }
    
    def get_spread_pips(self, symbol):
        """Get current spread in pips"""
        try:
            info = mt5.symbol_info(symbol)
            if info:
                return info.spread / 10
        except:
            pass
        return 999
    
    def calculate_dynamic_lot(self):
        """Calculate position size based on risk"""
        try:
            account_info = mt5.account_info()
            if not account_info:
                return CONFIG["LOT_SIZE"]
            
            balance = account_info.balance
            risk_amount = balance * (CONFIG["MAX_RISK_PER_TRADE"] / 100)
            
            # For cent account, 0.01 lot = $0.01 per pip
            pip_value = 0.01
            stop_loss_value = CONFIG["STOP_LOSS_PIPS"] * pip_value
            
            lots = risk_amount / stop_loss_value / 10
            
            # Apply limits
            lots = max(CONFIG["LOT_SIZE"], min(lots, CONFIG["MAX_LOT_SIZE"]))
            
            return round(lots, 2)
        except:
            return CONFIG["LOT_SIZE"]
    
    def execute_trade(self, symbol, action, ofi_data):
        """Execute real trade on MT5"""
        if self.daily_trades >= CONFIG["MAX_DAILY_TRADES"]:
            return False
        
        if symbol in self.last_trade_time:
            if time.time() - self.last_trade_time[symbol] < CONFIG["COOLDOWN_SECONDS"]:
                return False
        
        spread = self.get_spread_pips(symbol)
        if spread > CONFIG["MAX_SPREAD_PIPS"]:
            return False
        
        try:
            tick = mt5.symbol_info_tick(symbol)
            if not tick:
                return False
            
            lot_size = self.calculate_dynamic_lot()
            point = mt5.symbol_info(symbol).point
            
            if action == "BUY":
                price = tick.ask
                tp = price + CONFIG["TAKE_PROFIT_PIPS"] * point * 10
                sl = price - CONFIG["STOP_LOSS_PIPS"] * point * 10
                order_type = 0
            else:
                price = tick.bid
                tp = price - CONFIG["TAKE_PROFIT_PIPS"] * point * 10
                sl = price + CONFIG["STOP_LOSS_PIPS"] * point * 10
                order_type = 1
            
            request = {
                "action": 1,
                "symbol": symbol,
                "volume": lot_size,
                "type": order_type,
                "price": price,
                "sl": sl,
                "tp": tp,
                "deviation": 10,
                "magic": 2026,
                "comment": f"OFI_{ofi_data['ratio']}x",
                "type_time": 0,
                "type_filling": 1,
            }
            
            result = mt5.order_send(request)
            
            if result and hasattr(result, 'retcode') and result.retcode == 10009:
                self.daily_trades += 1
                self.last_trade_time[symbol] = time.time()
                print(f"\n✅ {action} {symbol} | OFI: {ofi_data['ratio']}x | Entry: {price:.5f}")
                return True
            else:
                return False
        except Exception as e:
            return False
    
    def monitor_positions(self):
        """Monitor open positions"""
        try:
            positions = mt5.positions_get()
            if positions:
                total_profit = sum(pos.profit for pos in positions)
                if abs(total_profit) > 0.01:
                    print(f"📈 Positions: {len(positions)} | P&L: ${total_profit:.2f}")
        except:
            pass
    
    def print_status(self):
        """Print status update"""
        try:
            account_info = mt5.account_info()
            if account_info:
                roi = (account_info.equity - self.initial_balance) / self.initial_balance * 100 if self.initial_balance > 0 else 0
                print(f"\n📊 Balance: ${account_info.equity:.2f} | ROI: {roi:.2f}% | Trades: {self.daily_trades}")
        except:
            pass
    
    def run(self):
        """Main bot loop"""
        if not self.connect_mt5():
            print("\n❌ Failed to verify MT5 connection")
            return
        
        print("\n" + "="*60)
        print("💎 MT5 OFI BOT – RUNNING")
        print("="*60)
        print(f"   Symbols: {', '.join(CONFIG['SYMBOLS'])}")
        print(f"   OFI Threshold: {CONFIG['OFI_THRESHOLD']}x")
        print(f"   TP: {CONFIG['TAKE_PROFIT_PIPS']} pips | SL: {CONFIG['STOP_LOSS_PIPS']} pips")
        print("="*60 + "\n")
        
        last_status = time.time()
        
        try:
            while self.running:
                for symbol in CONFIG["SYMBOLS"]:
                    self.update_tick_buffer(symbol)
                    ofi = self.calculate_ofi(symbol)
                    
                    if ofi:
                        if ofi["ratio"] >= CONFIG["OFI_THRESHOLD"]:
                            print(f"🚀 {symbol} BUY! {ofi['ratio']}x")
                            self.execute_trade(symbol, "BUY", ofi)
                        elif ofi["ratio"] <= 1.0 / CONFIG["OFI_THRESHOLD"]:
                            print(f"📉 {symbol} SELL! {ofi['ratio']}x")
                            self.execute_trade(symbol, "SELL", ofi)
                
                self.monitor_positions()
                
                if time.time() - last_status > 30:
                    self.print_status()
                    last_status = time.time()
                
                time.sleep(CONFIG["SLEEP_INTERVAL"])
                
        except KeyboardInterrupt:
            print("\n🔴 Shutting down...")
        finally:
            mt5.shutdown()
            print("✅ MT5 disconnected")

if __name__ == "__main__":
    bot = RealMT5OFIBot()
    bot.run()
