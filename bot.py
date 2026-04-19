#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import time
import sys
import logging
from datetime import datetime
from collections import deque
import MetaTrader5 as mt5

# ==============================================================================
# 1. ADVANCED LOGGING SETUP (Console + File)
# ==============================================================================
logger = logging.getLogger("OFIBot")
logger.setLevel(logging.DEBUG)

# Create formatters
log_format = logging.Formatter('%(asctime)s | %(levelname)-8s | %(message)s', datefmt='%Y-%m-%d %H:%M:%S')

# Console Handler (for noVNC terminal)
console_handler = logging.StreamHandler()
console_handler.setFormatter(log_format)
logger.addHandler(console_handler)

# File Handler (to check history later)
file_handler = logging.FileHandler('trading_debug.log')
file_handler.setFormatter(log_format)
logger.addHandler(file_handler)

# ==============================================================================
# 2. CONFIGURATION (Screenshot Symbols + Top 20)
# ==============================================================================
CONFIG = {
    "SYMBOLS": [
        "BTCUSD.vx", "ETHUSD.vx", "LTCUSD.vx", "XRPUSD.vx", 
        "BCHUSD.vx", "DOGEUSD.vx", "BTCEUR.vx", "SOLUSD.vx", 
        "BNBUSD.vx", "ADAUSD.vx", "DOTUSD.vx", "TRXUSD.vx", 
        "LINKUSD.vx", "AVAXUSD.vx", "MATICUSD.vx", "SHIBUSD.vx", 
        "UNIUSD.vx", "NEARUSD.vx", "ATOMUSD.vx", "APTUSD.vx"
    ],
    "LOT_SIZE": 0.01,
    "LOOKBACK_TICKS": 30,
    "OFI_THRESHOLD": 1.3, # Slightly stricter for production
    "TAKE_PROFIT_PIPS": 30,
    "STOP_LOSS_PIPS": 20,
    "SLEEP_INTERVAL": 1.0, 
}

class OFIBot:
    def __init__(self):
        self.buffers = {}

    def get_error_desc(self, code):
        """Translates MT5 codes into human language."""
        errors = {
            10013: "Invalid Request",
            10014: "Invalid Volume/Lot Size",
            10015: "Invalid Price (Check Connectivity)",
            10016: "Invalid Stops (SL/TP too close to price)",
            10018: "Market Closed",
            10019: "Not Enough Money",
            10027: "Too Frequent Requests"
        }
        return errors.get(code, f"Unknown Error ({code})")

    def initialize_mt5(self):
        logger.info("--- STARTING INITIALIZATION ---")
        if not mt5.initialize():
            logger.critical(f"MT5 Init Failed! Error: {mt5.last_error()}")
            return False
        
        acc = mt5.account_info()
        if acc:
            logger.info(f"✅ Connected to Account: {acc.login} on {acc.server}")
            logger.info(f"💰 Balance: {acc.balance} {acc.currency} | Equity: {acc.equity}")
        return True

    def setup_symbols(self):
        logger.info("🔍 Validating symbols from Market Watch...")
        for sym in CONFIG["SYMBOLS"]:
            if mt5.symbol_select(sym, True):
                self.buffers[sym] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                logger.debug(f"Symbol {sym} is ready.")
            else:
                logger.warning(f"Symbol {sym} not found or not supported by broker.")

        if not self.buffers:
            logger.error("No valid symbols found. Check your broker's naming convention.")
            sys.exit(1)

    def trade(self, symbol, direction):
        # 1. Pre-trade checks
        tick = mt5.symbol_info_tick(symbol)
        info = mt5.symbol_info(symbol)
        
        if not tick or not info:
            logger.error(f"Failed to get price/info for {symbol}")
            return

        price = tick.ask if direction == "BUY" else tick.bid
        multiplier = info.point * 10
        sl = price - (CONFIG["STOP_LOSS_PIPS"] * multiplier) if direction == "BUY" else price + (CONFIG["STOP_LOSS_PIPS"] * multiplier)
        tp = price + (CONFIG["TAKE_PROFIT_PIPS"] * multiplier) if direction == "BUY" else price - (CONFIG["TAKE_PROFIT_PIPS"] * multiplier)

        # 2. Build Request
        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": float(CONFIG["LOT_SIZE"]),
            "type": mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 20,
            "magic": 20260419,
            "comment": "DeepDebugBot",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC, # Most common for crypto
        }

        # 3. Execution & Full Response Logging
        logger.info(f"🚀 SENDING {direction}: {symbol} at {price} (SL: {sl}, TP: {tp})")
        
        start_time = time.time()
        result = mt5.order_send(request)
        end_time = time.time()

        if result is None:
            logger.error(f"❌ SYSTEM ERROR: No response from MT5. Code: {mt5.last_error()}")
            return

        # LOG THE FULL DICTIONARY RESPONSE
        res_dict = result._asdict()
        logger.debug(f"RAW MT5 RESPONSE: {res_dict}")

        if result.retcode == mt5.TRADE_RETCODE_DONE:
            logger.info(f"🔥 SUCCESS! {symbol} {direction} Opened. Ticket: {result.order}")
        else:
            reason = self.get_error_desc(result.retcode)
            logger.error(f"❌ TRADE REJECTED | Code: {result.retcode} | Reason: {reason}")
            logger.warning(f"MT5 Comment: {result.comment}")

    def run(self):
        if not self.initialize_mt5(): return
        self.setup_symbols()
        
        logger.info("--- BOT RUNNING IN PRODUCTION MODE ---")
        while True:
            for symbol in list(self.buffers.keys()):
                ticks = mt5.copy_ticks_from(symbol, datetime.now(), CONFIG["LOOKBACK_TICKS"], mt5.COPY_TICKS_ALL)
                
                if ticks is None or len(ticks) < 10:
                    continue

                # OFI Calculation
                buys = sum(1 for t in ticks if t[1] > t[2]) # Ask > Bid
                sells = len(ticks) - buys
                ratio = buys / (sells if sells > 0 else 1)

                if ratio >= CONFIG["OFI_THRESHOLD"]:
                    if not mt5.positions_get(symbol=symbol):
                        self.trade(symbol, "BUY")
                elif ratio <= (1 / CONFIG["OFI_THRESHOLD"]):
                    if not mt5.positions_get(symbol=symbol):
                        self.trade(symbol, "SELL")
                
            time.sleep(CONFIG["SLEEP_INTERVAL"])

if __name__ == "__main__":
    try:
        bot = OFIBot()
        bot.run()
    except Exception as e:
        logger.exception(f"CRASH DETECTED: {e}")
    finally:
        mt5.shutdown()
        logger.info("--- MT5 SHUTDOWN ---")
