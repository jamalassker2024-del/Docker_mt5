import time
import sys
import logging
from datetime import datetime
from collections import deque
from mt5linux import MetaTrader5

# ==============================================================================
# 1. INDUSTRIAL LOGGING (Forces logs to show in Railway Console)
# ==============================================================================
logging.basicConfig(
    level=logging.DEBUG,
    format='%(asctime)s | %(levelname)-8s | %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout), # Essential for Railway logs
        logging.FileHandler('/root/trading_debug.log')
    ]
)
logger = logging.getLogger("OFIBot")

# ==============================================================================
# 2. CONFIGURATION (Symbols from your Screenshot)
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
    "OFI_THRESHOLD": 1.2,
    "TAKE_PROFIT_PIPS": 20,
    "STOP_LOSS_PIPS": 15,
    "SLEEP_INTERVAL": 1.0, 
}

# Initialize mt5linux bridge (connecting to the port opened in entrypoint.sh)
mt5 = MetaTrader5(host='localhost', port=8001)

class OFIBot:
    def __init__(self):
        self.buffers = {}

    def get_error_desc(self, code):
        errors = {10013: "Invalid Request", 10014: "Invalid Volume", 10016: "Invalid Stops", 10018: "Market Closed"}
        return errors.get(code, f"Code {code}")

    def initialize_connection(self):
        logger.info("📡 Attempting to connect to mt5linux bridge...")
        if not mt5.initialize():
            logger.error(f"❌ Failed to connect to MT5 bridge: {mt5.last_error()}")
            return False
        
        acc = mt5.account_info()
        if acc:
            logger.info(f"✅ Connected! Account: {acc.login} | Server: {acc.server}")
            logger.info(f"💰 Balance: {acc.balance} | Equity: {acc.equity}")
        return True

    def setup_symbols(self):
        logger.info("🔍 Selecting symbols from Market Watch...")
        for sym in CONFIG["SYMBOLS"]:
            if mt5.symbol_select(sym, True):
                self.buffers[sym] = deque(maxlen=CONFIG["LOOKBACK_TICKS"])
                logger.debug(f"✅ Active: {sym}")
            else:
                logger.warning(f"⚠️ Symbol {sym} not found on this broker.")

        if not self.buffers:
            logger.critical("❌ No active symbols. Check Market Watch in noVNC!")
            sys.exit(1)

    def trade(self, symbol, direction):
        tick = mt5.symbol_info_tick(symbol)
        info = mt5.symbol_info(symbol)
        
        if not tick or not info:
            logger.error(f"❌ No data for {symbol}")
            return

        price = tick.ask if direction == "BUY" else tick.bid
        multiplier = info.point * 10
        sl = price - (CONFIG["STOP_LOSS_PIPS"] * multiplier) if direction == "BUY" else price + (CONFIG["STOP_LOSS_PIPS"] * multiplier)
        tp = price + (CONFIG["TAKE_PROFIT_PIPS"] * multiplier) if direction == "BUY" else price - (CONFIG["TAKE_PROFIT_PIPS"] * multiplier)

        request = {
            "action": mt5.TRADE_ACTION_DEAL,
            "symbol": symbol,
            "volume": float(CONFIG["LOT_SIZE"]),
            "type": mt5.ORDER_TYPE_BUY if direction == "BUY" else mt5.ORDER_TYPE_SELL,
            "price": price,
            "sl": sl,
            "tp": tp,
            "deviation": 20,
            "magic": 2026,
            "comment": "OFI Linux Bot",
            "type_time": mt5.ORDER_TIME_GTC,
            "type_filling": mt5.ORDER_FILLING_IOC,
        }

        logger.info(f"📤 SENDING {direction} {symbol} @ {price}")
        result = mt5.order_send(request)
        
        if result is None:
            logger.error(f"❌ MT5 Bridge Error: {mt5.last_error()}")
        elif result.retcode != mt5.TRADE_RETCODE_DONE:
            logger.error(f"❌ REJECTED: {result.retcode} ({self.get_error_desc(result.retcode)})")
            logger.debug(f"Full Result: {result._asdict()}")
        else:
            logger.info(f"🔥 SUCCESS: {symbol} {direction} Opened! Ticket: {result.order}")

    def run(self):
        if not self.initialize_connection(): return
        self.setup_symbols()
        
        logger.info("🚀 Monitoring for Order Flow Imbalance...")
        while True:
            try:
                for symbol in list(self.buffers.keys()):
                    # Get tick data from bridge
                    ticks = mt5.copy_ticks_from(symbol, datetime.now(), CONFIG["LOOKBACK_TICKS"], mt5.COPY_TICKS_ALL)
                    
                    if ticks is None or len(ticks) < 10:
                        continue

                    # OFI: Comparing Ask/Bid pressure
                    buys = sum(1 for t in ticks if t[1] > t[2]) # t[1]=bid, t[2]=ask (order varies by broker)
                    sells = len(ticks) - buys
                    ratio = buys / (sells if sells > 0 else 1)

                    if ratio >= CONFIG["OFI_THRESHOLD"]:
                        if not mt5.positions_get(symbol=symbol):
                            self.trade(symbol, "BUY")
                    elif ratio <= (1 / CONFIG["OFI_THRESHOLD"]):
                        if not mt5.positions_get(symbol=symbol):
                            self.trade(symbol, "SELL")
                
                time.sleep(CONFIG["SLEEP_INTERVAL"])
            except Exception as e:
                logger.exception(f"Loop Error: {e}")
                time.sleep(5)

if __name__ == "__main__":
    bot = OFIBot()
    bot.run()
