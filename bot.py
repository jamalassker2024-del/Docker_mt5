#!/usr/bin/env python3
# -*- coding: utf-8 -*-

"""
💎 VALETUTAX MT5 BOT – LINUX/WINE COMPATIBLE (RAILWAY)
- Uses mt5linux bridge to connect to MT5 running in Wine
- Real broker data, no simulation
- OFI calculation from real ticks
- Auto-trading on cent account
"""

import time
import os
from datetime import datetime
from collections import deque
import threading

# ============= MT5 BRIDGE FOR LINUX =============
try:
    import MetaTrader5 as mt5
    print("✅ Using native MetaTrader5 (Windows)")
except ImportError:
    print("📦 Loading mt5linux bridge for Linux/Wine...")
    from mt5linux import MetaTrader5
    # Connect to the MT5 bridge running in Wine
    mt5 = MetaTrader5(host='localhost', port=8001)
    print("✅ mt5linux bridge loaded")

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
    "MAX_RISK_PER_TRADE": 2.0,  # percent
    "SLEEP_INTERVAL": 0.2,  # Seconds between loops (reduced CPU)
}

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
        """Connect to MT5 via bridge (Linux/Wine compatible)"""
        print("\n" + "="*60)
        print("🚀 CONNECTING TO MT5 VIA BRIDGE (RAILWAY/LINUX)")
        print("="*60)
        
        # Initialize connection to MT5
        if not mt5.initialize():
            print(f"❌ MT5 initialization failed!")
            print("   Make sure MT5 is running in noVNC")
            print(f"   Error: {mt5.last_error() if hasattr(mt5, 'last_error') else 'Unknown'}")
            return False
        
        # Get account info
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
            print("   Please ensure you're logged into MT5 in noVNC")
            return False
        
        # Enable symbols in Market Watch
        for symbol in CONFIG["SYMBOLS"]:
            info = mt5.symbol_info(symbol)
            if info:
                if not info.visible:
                    mt5.symbol_select(symbol, True)
                print(f"✅ {symbol} ready (spread: {info.spread/10:.1f} pips)")
                self.tick_buffers[symbol] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
            else:
                print(f"⚠️ {symbol} not found - check symbol name")
                # Try with .c suffix for cent accounts
                symbol_c = f"{symbol}.c"
                info_c = mt5.symbol_info(symbol_c)
                if info_c:
                    print(f"   Found {symbol_c} instead!")
                    CONFIG["SYMBOLS"][CONFIG["SYMBOLS"].index(symbol)] = symbol_c
                    self.tick_buffers[symbol_c] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
        
        self.connected = True
        return True
    
    def get_real_ticks(self, symbol):
        """Get REAL ticks from MT5 broker feed via bridge"""
        try:
            # Get ticks from last LOOKBACK_TICKS
            now = datetime.now()
            ticks = mt5.copy_ticks_from(symbol, now, CONFIG["LOOKBACK_TICKS"], mt5.COPY_TICKS_ALL)
            
            if ticks is None or len(ticks) == 0:
                return []
            
            result = []
            for tick in ticks:
                # Parse tick data
                # flags: 2 = Bid (seller aggressive), 4 = Ask (buyer aggressive)
                is_buy = bool(tick[2] & 4) if len(tick) > 2 else False
                result.append({
                    "symbol": symbol,
                    "price": tick[1] if len(tick) > 1 else 0,
                    "is_buy": is_buy,
                    "volume": tick[5] if len(tick) > 5 else 1,
                    "timestamp": tick[0] if len(tick) > 0 else time.time()
                })
            
            return result
        except Exception as e:
            print(f"⚠️ Error getting ticks for {symbol}: {e}")
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
        
        buy_ticks = sum(1 for tick in buffer if tick["is_buy"])
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
        # Check daily limits
        if self.daily_trades >= CONFIG["MAX_DAILY_TRADES"]:
            print("⚠️ Daily trade limit reached")
            return False
        
        # Check cooldown
        if symbol in self.last_trade_time:
            if time.time() - self.last_trade_time[symbol] < CONFIG["COOLDOWN_SECONDS"]:
                return False
        
        # Check spread
        spread = self.get_spread_pips(symbol)
        if spread > CONFIG["MAX_SPREAD_PIPS"]:
            print(f"⚠️ Spread too high: {spread} pips")
            return False
        
        try:
            # Get price
            tick = mt5.symbol_info_tick(symbol)
            if not tick:
                return False
            
            lot_size = self.calculate_dynamic_lot()
            point = mt5.symbol_info(symbol).point
            
            if action == "BUY":
                price = tick.ask
                tp = price + CONFIG["TAKE_PROFIT_PIPS"] * point * 10
                sl = price - CONFIG["STOP_LOSS_PIPS"] * point * 10
                order_type = 0  # ORDER_TYPE_BUY
            else:
                price = tick.bid
                tp = price - CONFIG["TAKE_PROFIT_PIPS"] * point * 10
                sl = price + CONFIG["STOP_LOSS_PIPS"] * point * 10
                order_type = 1  # ORDER_TYPE_SELL
            
            # Prepare order request
            request = {
                "action": 1,  # TRADE_ACTION_DEAL
                "symbol": symbol,
                "volume": lot_size,
                "type": order_type,
                "price": price,
                "sl": sl,
                "tp": tp,
                "deviation": 10,
                "magic": 2026,
                "comment": f"OFI_{ofi_data['ratio']}x",
                "type_time": 0,  # ORDER_TIME_GTC
                "type_filling": 1,  # ORDER_FILLING_IOC
            }
            
            # Send order
            result = mt5.order_send(request)
            
            if result and result.retcode == 10009:  # TRADE_RETCODE_DONE
                self.daily_trades += 1
                self.last_trade_time[symbol] = time.time()
                
                print(f"\n{'='*60}")
                print(f"✅✅✅ {action} ORDER EXECUTED! ✅✅✅")
                print(f"   Symbol: {symbol}")
                print(f"   OFI Ratio: {ofi_data['ratio']}x (B:{ofi_data['buy_ticks']} S:{ofi_data['sell_ticks']})")
                print(f"   Lot: {lot_size:.2f} | Entry: {price:.5f}")
                print(f"   TP: {tp:.5f} | SL: {sl:.5f}")
                print(f"{'='*60}\n")
                return True
            else:
                print(f"❌ Order failed: {result.comment if result else 'Unknown'}")
                return False
        except Exception as e:
            print(f"❌ Trade execution error: {e}")
            return False
    
    def monitor_positions(self):
        """Monitor open positions"""
        try:
            positions = mt5.positions_get()
            if positions:
                total_profit = sum(pos.profit for pos in positions)
                if abs(total_profit) > 0.01:
                    print(f"📈 Open positions: {len(positions)} | P&L: ${total_profit:.2f}")
        except:
            pass
    
    def print_status(self):
        """Print status update"""
        try:
            account_info = mt5.account_info()
            if account_info:
                roi = (account_info.equity - self.initial_balance) / self.initial_balance * 100 if self.initial_balance > 0 else 0
                print(f"\n📊 STATUS | Balance: ${account_info.equity:.2f} | ROI: {roi:.2f}% | Trades: {self.daily_trades}")
        except:
            pass
    
    def run(self):
        """Main bot loop"""
        if not self.connect_mt5():
            print("\n❌ Failed to connect to MT5. Please ensure:")
            print("   1. MT5 is running in noVNC")
            print("   2. You're logged into your account")
            print("   3. The mt5linux bridge is running (port 8001)")
            return
        
        print("\n" + "="*60)
        print("💎 REAL MT5 OFI BOT – RUNNING ON RAILWAY/LINUX")
        print("="*60)
        print(f"   Symbols: {', '.join(CONFIG['SYMBOLS'])}")
        print(f"   OFI Threshold: {CONFIG['OFI_THRESHOLD']}x")
        print(f"   Lot size: {CONFIG['LOT_SIZE']} (dynamic up to {CONFIG['MAX_LOT_SIZE']})")
        print(f"   TP: {CONFIG['TAKE_PROFIT_PIPS']} pips | SL: {CONFIG['STOP_LOSS_PIPS']} pips")
        print(f"   Sleep interval: {CONFIG['SLEEP_INTERVAL']}s")
        print("="*60 + "\n")
        
        last_status = time.time()
        
        try:
            while self.running:
                for symbol in CONFIG["SYMBOLS"]:
                    # Update tick buffer with REAL data
                    self.update_tick_buffer(symbol)
                    
                    # Calculate OFI
                    ofi = self.calculate_ofi(symbol)
                    
                    if ofi:
                        # Check for BUY signal
                        if ofi["ratio"] >= CONFIG["OFI_THRESHOLD"]:
                            print(f"🚀 {symbol} BUY SIGNAL! Ratio: {ofi['ratio']}x (B:{ofi['buy_ticks']} S:{ofi['sell_ticks']})")
                            self.execute_trade(symbol, "BUY", ofi)
                        
                        # Check for SELL signal
                        elif ofi["ratio"] <= 1.0 / CONFIG["OFI_THRESHOLD"]:
                            print(f"📉 {symbol} SELL SIGNAL! Ratio: {ofi['ratio']}x (B:{ofi['buy_ticks']} S:{ofi['sell_ticks']})")
                            self.execute_trade(symbol, "SELL", ofi)
                
                # Monitor positions
                self.monitor_positions()
                
                # Status every 30 seconds
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
