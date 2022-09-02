# flake8: noqa
from decimal import Decimal
from typing import Iterator, List, Tuple

from hummingbot.connector.exchange_base import ExchangeBase
from hummingbot.connector.utils import split_hb_trading_pair
from hummingbot.core.data_type.order_book_row import ClientOrderBookRow
from hummingbot.core.data_type.order_candidate import OrderCandidate
from hummingbot.core.event.events import OrderFilledEvent, OrderType, TradeType
from hummingbot.strategy.market_trading_pair_tuple import MarketTradingPairTuple
from hummingbot.strategy.script_strategy_base import ScriptStrategyBase

# there are three formulas to try, TFI and OFI
# https://medium.com/@eliquinox/order-flow-analysis-of-cryptocurrency-markets-b479a0216ad8
# the third formula used in the paper "A continuous and efficient fundamental price"


class FundamentalPrice(ScriptStrategyBase):
    """
    Instance variables
    """
    time_interval: float = 10  # 10 seconds

    """
    Strategy variables
    """
    connector_name: str = "kucoin_paper_trade"
    trading_pair: str = "NIM-USDT"
    base_asset, quote_asset = split_hb_trading_pair(trading_pair)
    conversion_pair: str = f"{quote_asset}-USD"
    #:  A cool off period before the next buy (in seconds)
    cool_off_interval: float = 10.
    #:  The last buy timestamp
    last_ordered_ts: float = 0.

    markets = {connector_name: {trading_pair}}

    @property
    def connector(self) -> ExchangeBase:
        """
        The only connector in this strategy, define it here for easy access
        """
        return self.connectors[self.connector_name]

    def on_tick(self):
        """
        Runs every tick_size seconds, this is the main operation of the strategy.
        - Create proposal (a list of order candidates)
        - Check the account balance and adjust the proposal accordingly (lower order amount if needed)
        - Lastly, execute the proposal on the exchange
        """

        # Check if it is time to buy
        if self.last_ordered_ts < (self.current_timestamp - self.time_interval):
            currPrice = self.connector.get_mid_price(self.trading_pair)
            price, askVol, bidVol = self.calc_fprice()

            # output the orderbook
            #self.logger().info(f"FPrice: ${price} / AskVol: ${askVol} / BidVol: ${bidVol} / CurrPrice: ${currPrice}")
            #self.logger().info("----")

            # create a proposal
            # check the account balance and adjust proposal accordingly
            # execute proposal

            self.last_ordered_ts = self.current_timestamp

    def create_proposal(self) -> List[OrderCandidate]:
        """
        Creates and returns a proposal (a list of order candidate), in this strategy the list has 1 element at most.
        """
        proposal = []
        proposal.append(OrderCandidate(self.trading_pair, False, OrderType.LIMIT, TradeType.BUY, amount, price))
        return []

    def execute_proposal(self, proposal: List[OrderCandidate]):
        return None

    def calc_fprice(self, level: int = 5) -> Tuple[Decimal, Decimal, Decimal]:
        orderBook: List[MarketTradingPairTuple] = []
        askBook: List[ClientOrderBookRow] = []
        bidBook: List[ClientOrderBookRow] = []
        totalAskVolume: Decimal = Decimal(0)
        totalBidVolume: Decimal = Decimal(0)
        fundamentalPrice: Decimal = Decimal(0)

        # grab the order book for the first pair
        orderBook = self.get_market_trading_pair_tuples()
        askBook = list(orderBook[0].order_book_ask_entries())
        bidBook = list(orderBook[0].order_book_bid_entries())

        # get the orders for the first few levels, and get the total volume
        for i in range(level):
            totalAskVolume += askBook[i].amount
            totalBidVolume += bidBook[i].amount

        fundamentalPrice = ((totalAskVolume**2 * askBook[0].price) + (totalBidVolume**2 * bidBook[0].price)) / \
                            (totalAskVolume**2 + totalBidVolume**2)

        return fundamentalPrice, totalAskVolume, totalBidVolume