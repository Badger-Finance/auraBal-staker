from brownie import interface

from helpers.StrategyCoreResolver import StrategyCoreResolver
from rich.console import Console
from _setup.config import WANT

console = Console()


class StrategyResolver(StrategyCoreResolver):
    def get_strategy_destinations(self):
        """
        Track balances for all strategy implementations
        (Strategy Must Implement)
        """
        strategy = self.manager.strategy
        sett = self.manager.sett
        return {
            "auraBalRewards": strategy.AURABAL_REWARDS(),
            "graviAura": strategy.GRAVIAURA(),
            "badgerTree": sett.badgerTree(),
        }

    def add_balances_snap(self, calls, entities):
        super().add_balances_snap(calls, entities)
        strategy = self.manager.strategy

        aura = interface.IERC20(strategy.AURA())
        auraBal = interface.IERC20(strategy.AURABAL())  # want

        graviAura = interface.IERC20(strategy.GRAVIAURA())
        bbaUsd = interface.IERC20(strategy.BB_A_USD())
        bbaUsdc = interface.IERC20(strategy.BB_A_USDC())
        usdc = interface.IERC20(strategy.USDC())
        weth = interface.IERC20(strategy.WETH())

        calls = self.add_entity_balances_for_tokens(calls, "aura", aura, entities)
        calls = self.add_entity_balances_for_tokens(calls, "auraBal", auraBal, entities)
        calls = self.add_entity_balances_for_tokens(
            calls, "graviAura", graviAura, entities
        )
        calls = self.add_entity_balances_for_tokens(calls, "bbaUsd", bbaUsd, entities)
        calls = self.add_entity_balances_for_tokens(calls, "bbaUsdc", bbaUsdc, entities)
        calls = self.add_entity_balances_for_tokens(calls, "usdc", usdc, entities)
        calls = self.add_entity_balances_for_tokens(calls, "weth", weth, entities)

        return calls

    def confirm_harvest(self, before, after, tx):
        console.print("=== Compare Harvest ===")
        self.manager.printCompare(before, after)
        self.confirm_harvest_state(before, after, tx)

        super().confirm_harvest(before, after, tx)

        assert len(tx.events["Harvested"]) == 1
        event = tx.events["Harvested"][0]

        assert event["token"] == WANT
        assert event["amount"] == after.get("sett.balance") - before.get("sett.balance")

        assert len(tx.events["TreeDistribution"]) == 1

        emits = {
            "graviAura": self.manager.strategy.GRAVIAURA(),
        }

        # bbaUsd is autocompounded when strategy balance is greater than minBbaUsdHarvest
        # Find amount of bb-a-usd harvested
        amount = 0
        rewardsPool = "0xFD176Ba656b91F0cE8C59ad5C3245beBb99cd69a"
        for transfer in tx.events["Transfer"]:
            if transfer["from"] == rewardsPool and transfer["to"] == self.manager.strategy:
                amount = transfer["value"]
                break

        total_bb_a_usd = amount + before.balances("bbaUsd", "strategy")
        threshold = self.manager.strategy.minBbaUsdHarvest()

        if total_bb_a_usd < threshold:
            assert (
                after.balances("bbaUsd", "strategy") == total_bb_a_usd
            )
        else:
            assert after.balances("bbaUsd", "strategy") == 0

        # Check for swap dust
        assert after.balances("weth", "strategy") == 0
        assert after.balances("usdc", "strategy") == 0
        assert after.balances("bbaUsdc", "strategy") == 0

        for token_key, event in zip(emits, tx.events["TreeDistribution"]):
            token = emits[token_key]

            assert after.balances(token_key, "badgerTree") > before.balances(
                token_key, "badgerTree"
            )

            if before.get("sett.performanceFeeGovernance") > 0:
                assert after.balances(token_key, "treasury") > before.balances(
                    token_key, "treasury"
                )

            if before.get("sett.performanceFeeStrategist") > 0:
                assert after.balances(token_key, "strategist") > before.balances(
                    token_key, "strategist"
                )

            assert event["token"] == token
            assert event["amount"] == after.balances(
                token_key, "badgerTree"
            ) - before.balances(token_key, "badgerTree")
