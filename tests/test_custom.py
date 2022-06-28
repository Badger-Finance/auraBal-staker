import brownie
from brownie import *
from helpers.constants import AddressZero, MaxUint256
from helpers.time import days
from helpers.utils import (
    approx,
)


def state_setup(deployer, vault, want, keeper):
    startingBalance = want.balanceOf(deployer)
    depositAmount = int(startingBalance * 0.8)
    assert depositAmount > 0

    want.approve(vault, MaxUint256, {"from": deployer})
    vault.deposit(depositAmount, {"from": deployer})

    chain.sleep(days(1))
    chain.mine()

    vault.earn({"from": keeper})

    chain.sleep(days(3))
    chain.mine()


def test_expected_aura_rewards_match_minted(deployer, vault, strategy, want, keeper):
    state_setup(deployer, vault, want, keeper)

    (bal, aura) = strategy.balanceOfRewards()
    # Check that rewards are accrued
    bal_amount = bal[1]
    aura_amount = aura[1]
    assert bal_amount > 0
    assert aura_amount > 0

    # Check that aura amount calculating function matches the result
    assert aura_amount == strategy.getMintableAuraRewards(bal_amount)

    # First Transfer event from harvest() function is emitted by aura._mint()
    tx = strategy.harvest({"from": keeper})

    for event in tx.events["Transfer"]:
        if event["from"] == AddressZero and event["to"] == strategy:
            assert approx(
                event["value"],
                aura_amount,
                1,
            )
            break


def test_claimRewardsOnWithdrawAll(deployer, vault, strategy, want, governance):
    startingBalance = want.balanceOf(deployer)

    aura = interface.IERC20Detailed(strategy.AURA())

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
    assert aura.balanceOf(strategy) > 0

    chain.revert()

    # Random can't call
    with brownie.reverts("onlyGovernanceOrStrategist"):
        strategy.setClaimRewardsOnWithdrawAll(False, {"from": accounts[5]})

    strategy.setClaimRewardsOnWithdrawAll(False)

    vault.withdrawToVault({"from": governance})
    assert aura.balanceOf(strategy) == 0
