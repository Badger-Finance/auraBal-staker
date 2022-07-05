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
            "bBbaUsd": strategy.B_BB_A_USD(),
            "badgerTree": sett.badgerTree(),
        }

    def add_balances_snap(self, calls, entities):
        super().add_balances_snap(calls, entities)
        strategy = self.manager.strategy

        aura = interface.IERC20(strategy.AURA())
        auraBal = interface.IERC20(strategy.AURABAL())  # want

        graviAura = interface.IERC20(strategy.GRAVIAURA())
        bBbaUsd = interface.IERC20(strategy.B_BB_A_USD())

        calls = self.add_entity_balances_for_tokens(calls, "aura", aura, entities)
        calls = self.add_entity_balances_for_tokens(calls, "auraBal", auraBal, entities)
        calls = self.add_entity_balances_for_tokens(
            calls, "graviAura", graviAura, entities
        )
        calls = self.add_entity_balances_for_tokens(calls, "bBbaUsd", bBbaUsd, entities)

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

        assert len(tx.events["TreeDistribution"]) == 2

        emits = {
            "bBbaUsd": self.manager.strategy.B_BB_A_USD(),
            "graviAura": self.manager.strategy.GRAVIAURA(),
        }

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
