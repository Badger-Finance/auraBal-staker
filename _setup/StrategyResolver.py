from brownie import interface

from helpers.StrategyCoreResolver import StrategyCoreResolver
from rich.console import Console
from _setup.config import WANT, WFTM

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
            "oxSolidRewards": strategy.OXSOLID_REWARDS(),
            "bvlOxd": strategy.bvlOxd(),
            "badgerTree": sett.badgerTree(),
        }

    def add_balances_snap(self, calls, entities):
        super().add_balances_snap(calls, entities)
        strategy = self.manager.strategy

        oxd = interface.IERC20(strategy.OXD())
        oxSolid = interface.IERC20(strategy.OXSOLID())  # want
        solid = interface.IERC20(strategy.SOLID())
        wftm = interface.IERC20(WFTM)

        bvlOxd = interface.IERC20(strategy.bvlOxd())

        calls = self.add_entity_balances_for_tokens(calls, "oxd", oxd, entities)
        calls = self.add_entity_balances_for_tokens(calls, "oxSolid", oxSolid, entities)
        calls = self.add_entity_balances_for_tokens(calls, "wftm", wftm, entities)
        calls = self.add_entity_balances_for_tokens(calls, "bvlOxd", bvlOxd, entities)

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

        tokens = [("bvlOxd", self.manager.strategy.bvlOxd()), ("wftm", WFTM)]

        for (name, token), event in zip(tokens, tx.events["TreeDistribution"]):
            assert after.balances(name, "badgerTree") > before.balances(
                name, "badgerTree"
            )

            if before.get("sett.performanceFeeGovernance") > 0:
                assert after.balances(name, "treasury") > before.balances(
                    name, "treasury"
                )

            if before.get("sett.performanceFeeStrategist") > 0:
                assert after.balances(name, "strategist") > before.balances(
                    name, "strategist"
                )

            assert event["token"] == token
            assert event["amount"] == after.balances(
                name, "badgerTree"
            ) - before.balances(name, "badgerTree")
