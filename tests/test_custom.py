import brownie
from brownie import *
from helpers.constants import MaxUint256
from helpers.SnapshotManager import SnapshotManager
from helpers.time import days

"""
  TODO: Put your tests here to prove the strat is good!
  See test_harvest_flow, for the basic tests
  See test_strategy_permissions, for tests at the permissions level
"""


def test_claimRewardsOnWithdrawAll(deployer, vault, strategy, want, governance, oxd):
    startingBalance = want.balanceOf(deployer)

    depositAmount = startingBalance // 2
    assert startingBalance >= depositAmount
    assert startingBalance >= 0
    # End Setup

    # Deposit
    assert want.balanceOf(vault) == 0

    want.approve(vault, MaxUint256, {"from": deployer})
    vault.deposit(depositAmount, {"from": deployer})

    vault.earn({"from": governance})

    chain.sleep(10000 * 13)  # Mine so we get some interest

    chain.snapshot()

    vault.withdrawToVault({"from": governance})
    assert oxd.balanceOf(strategy) > 0

    chain.revert()
    strategy.setClaimRewardsOnWithdrawAll(False)

    vault.withdrawToVault({"from": governance})
    assert oxd.balanceOf(strategy) == 0
