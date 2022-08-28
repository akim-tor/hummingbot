from decimal import Decimal

from hummingbot.strategy.market_trading_pair_tuple import MarketTradingPairTuple
from hummingbot.strategy.port_hedge.exchange_pair import ExchangePairTuple
from hummingbot.strategy.port_hedge.port_hedge import PortHedgeStrategy
from hummingbot.strategy.port_hedge.port_hedge_config_map import port_hedge_config_map as c_map


def start(self):
    maker_exchange = c_map.get("maker_exchange").value.lower()
    taker_exchange = c_map.get("taker_exchange").value.lower()
    maker_assets = list(c_map.get("maker_assets").value.split(","))
    taker_markets = list(c_map.get("taker_markets").value.split(","))
    maker_assets = [m.strip().upper() for m in maker_assets]
    taker_markets = [m.strip().upper() for m in taker_markets]
    corr = list(c_map.get("corr").value.split(","))
    corr = [Decimal(c.strip()) for c in corr]
    hedge_ratio = c_map.get("hedge_ratio").value
    leverage = c_map.get("leverage").value
    slippage = c_map.get("slippage").value
    max_order_age = c_map.get("max_order_age").value
    minimum_trade = c_map.get("minimum_trade").value
    hedge_interval = c_map.get("hedge_interval").value
    # cleared out the maker_assets below because we are using the oracle
    self._initialize_markets([(maker_exchange, []), (taker_exchange, taker_markets)])
    exchanges = ExchangePairTuple(maker=self.markets[maker_exchange], taker=self.markets[taker_exchange])

    market_infos = {}
    # problem here is that there isn't an equal number of maker and taker assets
    # we only have one taker market....one asset that is hedging
    # the maker_assets and taker_market are two different sizes
    # for i, maker_asset in enumerate(maker_assets):
    #    taker_market = taker_markets[i]
    #    t_base, t_quote = taker_market.split("-")
    #    taker = MarketTradingPairTuple(self.markets[taker_exchange], taker_market, t_base, t_quote)
    #    market_infos[maker_asset] = taker
    # === SHOULD WE USE RATE ORACLE?
    for tempAsset in taker_markets:
        t_base, t_quote = tempAsset.split("-")
        taker = MarketTradingPairTuple(self.markets[taker_exchange], tempAsset, t_base, t_quote)
        market_infos[t_base] = taker

    self.strategy = PortHedgeStrategy()
    self.strategy.init_params(
        exchanges = exchanges,
        market_infos = market_infos,
        holdings = maker_assets,
        corr = corr,
        hedge_ratio = hedge_ratio,
        leverage = leverage,
        minimum_trade = minimum_trade,
        slippage = slippage,
        max_order_age = max_order_age,
        hedge_interval = hedge_interval,
    )
