# flake8: noqa
import logging
import time
from decimal import Decimal

from hummingbot.connector.utils import split_hb_trading_pair
from hummingbot.strategy.script_strategy_base import ScriptStrategyBase


class EKMicroPrice(ScriptStrategyBase):
    """
    INSTANCE VARIABLES
    """
    buy_usd_amount: Decimal = Decimal("100")

    """
    STRATEGY VARIABLES
    """
    connector_name: str = "kucoin_paper_trade"
    trading_pair: str = "AVAX-USDT"
    base_asset, quote_asset = split_hb_trading_pair(trading_pair)
    conversion_pair: str = f"{quote_asset}-USD"
    #: A cool off period before the next buy (in seconds)
    cool_off_interval: float = 10.
    #: The last buy timestamp
    last_ordered_ts: float = 0.

    markets = {connector_name: {trading_pair}}

    def on_tick(self):
        """
        Runs every tick_size seconds, this is the main operation of the strategy.
        - Create proposal (a list of order candidates)
        - Check the account balance and adjust the proposal accordingly (lower order amount if needed)
        - Lastly, execute the proposal on the exchange
        """
        # Check if it is time to buy
        if self.last_ordered_ts < (self.current_timestamp - self.buy_interval):
            # Lets set the order price to the best bid
            price = self.connectors["binance_paper_trade"].get_price("BTC-USDT", False)
            amount = self.buy_quote_amount / price
            self.buy("binance_paper_trade", "BTC-USDT", amount, OrderType.LIMIT, price)
            self.last_ordered_ts = self.current_timestamp
