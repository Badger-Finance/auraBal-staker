import brownie
import pytest

from brownie import *

from helpers.constants import AddressZero
from helpers.time import days


VAULT_ADDRESS = "0x37d9D2C6035b744849C15F1BFEE8F268a20fCBd8"


@pytest.fixture
def vault_proxy():
    return TheVault.at(VAULT_ADDRESS)


@pytest.fixture
def strat_proxy(vault_proxy):
    return AuraBalStakerStrategy.at(vault_proxy.strategy())


@pytest.fixture
def new_strategy(vault_proxy, proxyAdmin, deployer):
    args = [vault_proxy]

    strat_logic = AuraBalStakerStrategy.deploy({"from": deployer})
    strat_proxy = AdminUpgradeabilityProxy.deploy(
        strat_logic,
        proxyAdmin,
        strat_logic.initialize.encode_input(*args),
        {"from": deployer},
    )

    ## We delete from deploy and then fetch again so we can interact
    AdminUpgradeabilityProxy.remove(strat_proxy)
    strat_proxy = AuraBalStakerStrategy.at(strat_proxy.address)

    return strat_proxy


def test_check_storage_integrity(strat_proxy, vault_proxy, new_strategy):
    with brownie.reverts():
        strat_proxy.minBbaUsdHarvest()

    ## Check Integrity
    assert new_strategy.want() == strat_proxy.want()
    assert new_strategy.vault() == strat_proxy.vault()
    assert (
        new_strategy.withdrawalMaxDeviationThreshold()
        == strat_proxy.withdrawalMaxDeviationThreshold()
    )
    assert new_strategy.autoCompoundRatio() == strat_proxy.autoCompoundRatio()
    assert (
        new_strategy.claimRewardsOnWithdrawAll()
        == strat_proxy.claimRewardsOnWithdrawAll()
    )
    assert (
        new_strategy.balEthBptToAuraBalMinOutBps()
        == strat_proxy.balEthBptToAuraBalMinOutBps()
    )

    # Check if var exists
    assert new_strategy.BB_A_USD() != AddressZero
    assert new_strategy.minBbaUsdHarvest() == int(1000e18)

    gov = accounts.at(vault_proxy.governance(), force=True)
    bb_a_usd = interface.IERC20(strat_proxy.BB_A_USD())

    # Harvest
    strat_proxy.harvest({"from": gov})

    # Checkpoint balance
    old_balance = vault_proxy.balance()

    # Migrate strategy
    vault_proxy.withdrawToVault({"from": gov})

    assert strat_proxy.balanceOf() == 0

    vault_proxy.setStrategy(new_strategy, {"from": gov})
    assert vault_proxy.strategy() == new_strategy

    vault_proxy.earn({"from": gov})

    assert new_strategy.balanceOf() > 0
    assert vault_proxy.balance() == old_balance

    # Sleep to accrue rewards
    chain.sleep(days(2))
    chain.mine()

    # Test harvest
    new_strategy.harvest({"from": gov})
    assert bb_a_usd.balanceOf(new_strategy) > 0
