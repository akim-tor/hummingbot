import logging
from decimal import Decimal
from math import isnan
from typing import Dict, List

import numpy as np
import pandas as pd

from hummingbot.connector.exchange_base import ExchangeBase
from hummingbot.connector.exchange_base cimport ExchangeBase
from hummingbot.core.clock cimport Clock
from hummingbot.core.data_type.common import OrderType, PositionMode, PositionSide, TradeType
from hummingbot.core.data_type.limit_order cimport LimitOrder
from hummingbot.core.data_type.limit_order import LimitOrder
from hummingbot.core.network_iterator import NetworkStatus
from hummingbot.strategy.port_hedge.exchange_pair import ExchangePairTuple
from hummingbot.strategy.market_trading_pair_tuple import MarketTradingPairTuple
from hummingbot.strategy.strategy_base cimport StrategyBase
from hummingbot.strategy.strategy_base import StrategyBase
from hummingbot.strategy.utils import order_age
from hummingbot.core.rate_oracle.rate_oracle import RateOracle

# https://nadiah.org/2020/03/01/example-debug-mixed-python-c-in-visual-studio-code/

NaN = float("nan")
s_decimal_zero = Decimal(0)
s_decimal_nan = Decimal("nan")
s_logger = None

cdef class PortHedgeStrategy(StrategyBase):
    @classmethod
    def logger(cls):
        global s_logger
        if s_logger is None:
            s_logger = logging.getLogger(__name__)
        return s_logger

    def init_params(self,
                    exchanges: ExchangePairTuple,
                    market_infos: Dict[str, MarketTradingPairTuple],
                    holdings: List[str],
                    corr: List[Decimal],
                    hedge_ratio: Decimal,
                    status_report_interval: float = 900,
                    minimum_trade: Decimal = 11,
                    leverage: int = 5,
                    position_mode: str = "ONEWAY",
                    hedge_interval: float = 10,
                    slippage: Decimal = .01,
                    max_order_age: float = 100.0,
                    ):

        self._exchanges = exchanges
        self._market_infos = market_infos
        self._holdings = holdings
        self._corr = corr
        self._hedge_ratio = hedge_ratio
        self._minimum_trade = minimum_trade
        self._all_markets_ready = False
        self._last_timestamp = 0
        self._status_report_interval = status_report_interval
        self._position_mode = PositionMode.HEDGE if position_mode == "Hedge" else PositionMode.ONEWAY
        self._leverage = leverage
        self.c_add_markets([exchanges.maker, exchanges.taker])
        self._last_trade_time = {}
        self._shadow_taker_balance = {}
        self._update_shadow_balance_interval = 600
        self._hedge_interval = hedge_interval
        self._slippage = slippage
        self._max_order_age = max_order_age

        self._weights = {}
        self._port_corr = 0
        self._total = 0

    @property
    def market_info_to_active_orders(self) -> Dict[MarketTradingPairTuple, List[LimitOrder]]:
        return self._sb_order_tracker.market_pair_to_active_orders

    def get_shadow_position(self, trading_pair: str):
        return self._shadow_taker_balance[trading_pair]

    def set_shadow_position(self, trading_pair: str, value):
        self._shadow_taker_balance[trading_pair] = value

    def update_shadow_position(self, trading_pair: str, value):
        self._shadow_taker_balance[trading_pair] = self._shadow_taker_balance[trading_pair] + value

    @property
    def active_positions(self) -> List[LimitOrder]:
        return self._exchanges.taker.account_positions

    def get_position_amount(self, trading_pair: str):
        for idx in self.active_positions.values():
            if idx.trading_pair == trading_pair:
                # some exchanges, e.g dydx shows short amount as positive while some shows it as negative e.g binance_perpetual
                # May be due to positionMode.
                # hence, need to standardize position and return negative value
                if idx.position_side == PositionSide.SHORT and idx.amount>0:
                    return -idx.amount
                return idx.amount
        return self.get_shadow_position(trading_pair)

    def get_balance(self, maker_asset: str):
        return self._exchanges.maker.get_balance(maker_asset)

    cdef object check_and_cancel_active_orders(self,
                                               object market_pair,
                                               object hedge_amount):
        cdef:
            object active_orders=self.market_info_to_active_orders.get(market_pair, [])
            ExchangeBase market = market_pair.market
            object quantized_order_amount = market.c_quantize_order_amount(market_pair.trading_pair, Decimal(abs(hedge_amount)))
            object order_size_quantum = market.c_get_order_size_quantum(market_pair.trading_pair, quantized_order_amount)

        for o in active_orders:
            order_age = order_age(o, self._current_timestamp)
            if isnan(order_age):
                continue
            if self._max_order_age > 0 and order_age > self._max_order_age:
                self.log_with_clock(logging.INFO,
                                    f"{market_pair.trading_pair}: "
                                    f"order age of limit order ({order_age}) is more than {self._max_order_age}. "
                                    f"Canceling Order")
                self.c_cancel_order(market_pair, o.client_order_id)

            if isnan(o.quantity) or isnan(o.filled_quantity):
                continue
            if abs(o.quantity-o.filled_quantity-quantized_order_amount)>order_size_quantum:
                self.log_with_clock(logging.INFO,
                                    f"{market_pair.trading_pair}: "
                                    f"quantity: {o.quantity} filled_quantity: {o.filled_quantity}"
                                    f"{o.quantity - o.filled_quantity} is different than quantity required {quantized_order_amount}. "
                                    f"order quantum: {order_size_quantum} "
                                    f"Canceling Order")
                self.c_cancel_order(market_pair, o.client_order_id)

    cdef object check_and_hedge_asset(self,
                                      str maker_asset,
                                      object maker_balance,
                                      object market_pair,
                                      str trading_pair,
                                      object taker_balance,
                                      object hedge_amount,
                                      bint is_buy,
                                      object price
                                      ):

        if trading_pair in self._sb_order_tracker._tracked_limit_orders:
            return
        if self._last_trade_time[maker_asset] > self._current_timestamp - self._hedge_interval:
            return
        self._last_trade_time[maker_asset]=self._current_timestamp
        self.place_order(maker_asset, is_buy, abs(hedge_amount), price)

    cdef object place_order(self,
                            str maker_asset,
                            bint is_buy,
                            object amount,
                            object price):
        cdef:
            object market_pair = self._market_infos[maker_asset]
            str trading_pair = market_pair.trading_pair
            ExchangeBase market = market_pair.market
            object quantized_order_amount = market.c_quantize_order_amount(trading_pair, Decimal(amount))
        price = Decimal(price)
        price = price*(Decimal(1) + Decimal(self._slippage)) if is_buy else price*(Decimal(1) - Decimal(self._slippage))
        if quantized_order_amount*price>self._minimum_trade:
            if is_buy:
                order_id = self.c_buy_with_specific_market(market_pair, quantized_order_amount,
                                                           order_type=OrderType.LIMIT, price=price, expiration_seconds=NaN)
            else:
                order_id = self.c_sell_with_specific_market(market_pair, quantized_order_amount,
                                                            order_type=OrderType.LIMIT, price=price, expiration_seconds=NaN)
            self.log_with_clock(logging.INFO,
                                f"Place {'Buy' if is_buy else 'Sell'} {quantized_order_amount} {trading_pair}")

    def market_status_data_frame(self) -> pd.DataFrame:
        markets_data = []
        markets_columns = ["Exchange", "Market", "Best Bid", "Best Ask"]
        for maker_asset in self._market_infos:
            market_pair=self._market_infos[maker_asset]
            market=market_pair.market
            trading_pair=market_pair.trading_pair
            bid_price = market.get_price(trading_pair, False)
            ask_price = market.get_price(trading_pair, True)
            markets_data.append([
                market.display_name,
                trading_pair,
                float(bid_price),
                float(ask_price),
            ])
        return pd.DataFrame(data=markets_data, columns=markets_columns).replace(np.nan, '', regex=True)

    def update_wallet(self):
        position_updated=False
        # EK added
        rate_instance = RateOracle.get_instance()

        for maker_asset in self._market_infos:
            market_pair = self._market_infos[maker_asset]
            trading_pair=market_pair.trading_pair
            # After a recent trade execution, the position returned may be 0 for some time (binance perpetual),
            # Hence, introduce minimum time prior to last trade to ensure update is correct
            # Added to ensure shadow balance can remain in sync with actual balance
            if self._last_trade_time[maker_asset]==0 or max(self._last_trade_time.values())<self._current_timestamp-self._update_shadow_balance_interval:
                taker_balance = self.get_position_amount(trading_pair)
                self.set_shadow_position(trading_pair, taker_balance)
                position_updated=True
            maker_balance = self.get_balance(maker_asset)
            taker_balance = self.get_shadow_position(trading_pair)

            # calculate the correlation
            weights, total = self.calculate_weights()
            port_corr = {item[0]: item[1] * self._corr[idx] for idx, item in enumerate(weights.items())}
            port_corr = sum(port_corr.values())
            self._weights = weights
            self._port_corr = port_corr
            self._total = total

            # use the correlation as the hedge ratio set the proper hedge amount, in the maker asset units
            price = rate_instance.rate(maker_asset + "-USDT")
            hedge_amount = -((total/price) * port_corr * self._hedge_ratio + taker_balance)

            """
            print("Mkr asset:" + str(maker_asset) + "\n" + 
                  "Maker Bal:" + str(maker_balance) + "\n" + 
                  "Mkt Pair:" + str(market_pair) + "\n" + 
                  "Trd Pair:" + str(trading_pair) + "\n" +
                  "Tkr Bal:" + str(taker_balance) + "\n" + 
                  "hdg Amt:" + str(hedge_amount) + "\n" +
                  "Port Cor:" + str(port_corr) + "\n" +
                  "Hg Ratio:" + str(self._hedge_ratio) + "\n" +
                  "total:" + str(total))
            """


            #hedge_amount = -(maker_balance*self._hedge_ratio + taker_balance)
            is_buy = hedge_amount > 0
            price = market_pair.get_price(is_buy)

            self.check_and_cancel_active_orders(market_pair, hedge_amount)
            if market_pair not in self.market_info_to_active_orders:
                self.check_and_hedge_asset(maker_asset,
                                           maker_balance,
                                           market_pair,
                                           trading_pair,
                                           taker_balance,
                                           hedge_amount,
                                           is_buy,
                                           price)
        if position_updated:
            self._last_trade_time["last updated"]=self._current_timestamp

    # EK func
    def calculate_weights(self):
        holdings_list = []
        data = []
        balances = {}
        prices = {}
        weights = {}
        total = Decimal(0.0)
        
        # check if ticker data exists in our config map
        for tempAsset in self._holdings:
            base, quote = tempAsset.split("-")
            holdings_list.append(base)

        # get the balance and price of current holdings
        data = self._exchanges.maker.get_all_balances()
        rate_instance = RateOracle.get_instance()

        for maker_asset, balance in data.items():
            if maker_asset in holdings_list:
                #price = self._exchanges.maker.get_mid_price(maker_asset + "-USDT")
                price = rate_instance.rate(maker_asset + "-USDT")
                if price == None:
                    price = Decimal(0)
                #print(str(maker_asset) + "/" + str(price))
                prices[maker_asset] = price
                balances[maker_asset] = balance
                total = total + (balance * price)
                #print(str(maker_asset) + ":" + str(balance) + "/" + str(price) + " -- t:" + str(total))

        # calculate the weighting for each asset
        for tempAsset in holdings_list:
            weights[tempAsset] = (prices[tempAsset] * balances[tempAsset]) / total

        return weights, total


    def wallet_df(self) -> pd.DataFrame:
        data=[]
        columns = ["Asset", "Price", "Maker", "Taker", "Diff", "Hedge Ratio"]
        for maker_asset in self._market_infos:
            market_pair = self._market_infos[maker_asset]
            trading_pair=market_pair.trading_pair
            maker_balance = self.get_balance(maker_asset)
            taker_balance = self.get_shadow_position(trading_pair)
            mid_price = market_pair.get_mid_price()
            difference = - (maker_balance + taker_balance)
            hedge_ratio = Decimal(-round(taker_balance/maker_balance, 2)) if maker_balance != 0 else 1
            data.append([
                maker_asset,
                mid_price,
                Decimal(maker_balance).quantize(Decimal('0.0001')),
                Decimal(taker_balance).quantize(Decimal('0.0001')),
                Decimal(difference).quantize(Decimal('0.0001')),
                hedge_ratio,
            ])
        return pd.DataFrame(data=data, columns=columns)

    def active_orders_df(self) -> pd.DataFrame:

        active_orders = self.market_info_to_active_orders
        columns = ["Market", "Type", "Price", "Amount", "Age"]
        data = []
        for market_info in active_orders:
            orders = active_orders[market_info]
            for order in orders:
                market = order.trading_pair
                age = order_age(order, self._current_timestamp)
                data.append([
                    market,
                    "buy" if order.is_buy else "sell",
                    float(order.price),
                    float(order.quantity),
                    age
                ])
        return pd.DataFrame(data=data, columns=columns)

    def portfolio_df(self) -> pd.DataFrame:
        columns = ["Market", "Weight", "Corr"]
        data=[]

        for idx, (ticker, wgt) in enumerate(self._weights.items()):
            data.append([
                ticker,
                Decimal(wgt).quantize(Decimal('.01')),
                Decimal(self._corr[idx]).quantize(Decimal('.01'))
            ])

        return pd.DataFrame(data=data, columns=columns)

    def format_status(self) -> str:
        lines = []
        if not self._all_markets_ready:
            for exchange in self._exchanges:
                if not exchange.ready:
                    lines.extend(f"{exchange.name} connector is not ready...\n")
            return ''.join(lines)

        markets_df = self.market_status_data_frame()
        wallet_df = self.wallet_df()
        lines.extend(["", "  Markets:"] + ["    " + line for line in markets_df.to_string(index=False).split("\n")])

        lines.extend(["", f"  Wallet:\n"])
        lines.extend(["    " + line for line in wallet_df.to_string(index=False).split("\n")])

        # See if there're any active positions.
        if len(self.market_info_to_active_orders) > 0:
            df = self.active_orders_df()
            lines.extend(["", "  Active Orders:"] + ["    " + line for line in df.to_string(index=False).split("\n")])
        else:
            lines.extend(["", "  No active orders."])

        # EK: list out current portfolio
        weights_df = self.portfolio_df()
        lines.extend(["", "  Portfolio Weights:"] + ["    " + line for line in weights_df.to_string(index=False).split("\n")])

        lines.extend(["", "Portfolio Corr:" + str(Decimal(self._port_corr).quantize(Decimal('.0001')))])
        lines.extend(["", "Portfolio Total:" + str(Decimal(self._total).quantize(Decimal('.0001')))])

        return "\n".join(lines)

    cdef c_apply_initial_settings(self, object market_pair, object position, int64_t leverage):
        cdef:
            ExchangeBase market = market_pair.market
            str trading_pair = market_pair.trading_pair
        market.set_leverage(trading_pair, leverage)
        market.set_position_mode(position)

    cdef c_did_fill_order(self, object order_filled_event):
        cdef:
            str trading_pair = order_filled_event.trading_pair
            str trade_type = "Buy" if order_filled_event.trade_type == TradeType.BUY else "sell"
            object price = order_filled_event.price
            object amount = order_filled_event.amount
            object order_amount = amount if trade_type == "Buy" else -amount
        self.update_shadow_position(trading_pair, order_amount)

        self.log_with_clock(
            logging.INFO,
            f"{trading_pair} {trade_type} order of "
            f"{amount}  filled at {price}.")

    cdef c_start(self, Clock clock, double timestamp):
        clock._tick_size = self._hedge_interval
        StrategyBase.c_start(self, clock, timestamp)
        cdef:
            object market_pair
            str trading_pair
            object taker_balance

        self._last_timestamp = timestamp
        for maker_asset in self._market_infos:
            market_pair = self._market_infos[maker_asset]
            trading_pair = market_pair.trading_pair
            self._shadow_taker_balance[trading_pair]=0
            self._last_trade_time[maker_asset]=0
            self.c_apply_initial_settings(market_pair, self._position_mode, self._leverage)

    cdef c_tick(self, double timestamp):
        StrategyBase.c_tick(self, timestamp)
        cdef:
            int64_t current_tick = <int64_t>(timestamp // self._status_report_interval)
            int64_t last_tick = <int64_t>(self._last_timestamp // self._status_report_interval)
            bint should_report_warnings = (current_tick > last_tick)

        try:
            if not self._all_markets_ready:
                self._all_markets_ready = all([market.ready for market in self._sb_markets])
                if not self._all_markets_ready:
                    # Markets not ready yet. Don't do anything.
                    if should_report_warnings:
                        self.logger().warning(f"Markets are not ready. No market making trades are permitted.")
                    return
                else:
                    # Markets are ready, ok to proceed.
                    self.logger().info(f"Markets are ready. Trading started.")

            if should_report_warnings:
                # Check if all markets are still connected or not. If not, log a warning.
                if not all([market.network_status is NetworkStatus.CONNECTED for market in self._sb_markets]):
                    self.logger().warning(f"WARNING: Some markets are not connected or are down at the moment. Market "
                                          f"making may be dangerous when markets or networks are unstable.")

            self.update_wallet()

        finally:
            self._last_timestamp=timestamp

    cdef c_did_complete_buy_order(self, object order_completed_event):
        """
        Output log message when a bid order (on maker side or taker side) is completely taken.
        :param order_completed_event: event object
        """
        cdef:
            str order_id = order_completed_event.order_id
            object order_type = order_completed_event.order_type
            object base_asset_amount = order_completed_event.base_asset_amount
            object quote_asset_amount = order_completed_event.quote_asset_amount
            str base_asset = order_completed_event.base_asset
            str quote_asset = order_completed_event.quote_asset

        self.log_with_clock(
            logging.INFO,
            f"{order_type} order {order_id} "
            f"({base_asset_amount} {base_asset} @ "
            f"{quote_asset_amount} {quote_asset}) has been completely filled."
        )
        self.notify_hb_app_with_timestamp(
            f"{order_type} order {order_id} "
            f"({base_asset_amount} {base_asset} @ "
            f"{quote_asset_amount} {quote_asset}) has been completely filled."
        )

    cdef c_did_complete_sell_order(self, object order_completed_event):
        """
        Output log message when a ask order (on maker side or taker side) is completely taken.
        :param order_completed_event: event object
        """
        cdef:
            str order_id = order_completed_event.order_id
            object order_type = order_completed_event.order_type
            object base_asset_amount = order_completed_event.base_asset_amount
            object quote_asset_amount = order_completed_event.quote_asset_amount
            str base_asset = order_completed_event.base_asset
            str quote_asset = order_completed_event.quote_asset

        self.log_with_clock(
            logging.INFO,
            f"{order_type} order {order_id} "
            f"({base_asset_amount} {base_asset} @ "
            f"{quote_asset_amount} {quote_asset}) has been completely filled."
        )
        self.notify_hb_app_with_timestamp(
            f"{order_type} order {order_id} "
            f"({base_asset_amount} {base_asset} @ "
            f"{quote_asset_amount} {quote_asset}) has been completely filled."
        )
