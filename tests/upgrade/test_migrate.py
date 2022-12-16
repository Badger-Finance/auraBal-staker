import brownie
import pytest

from brownie import (
    AuraBalStakerStrategy,
    TheVault,
    AdminUpgradeabilityProxy,
    interface,
    accounts,
    chain
)

from helpers.constants import AddressZero
from helpers.time import days
from rich.console import Console

C = Console()


VAULT_ADDRESS = "0x37d9D2C6035b744849C15F1BFEE8F268a20fCBd8"


@pytest.fixture
def vault_proxy():
    return TheVault.at(VAULT_ADDRESS)

@pytest.fixture
def gov(vault_proxy):
    return accounts.at(vault_proxy.governance(), force=True)

@pytest.fixture
def strat_proxy(vault_proxy, gov):
    return AuraBalStakerStrategy.at(vault_proxy.strategy(), owner=gov)

@pytest.fixture
def current_bb_a_usd(strat_proxy):
    return interface.ERC20(strat_proxy.BB_A_USD())

@pytest.fixture
def want(strat_proxy):
    return interface.ERC20(strat_proxy.want())

@pytest.fixture
def new_strategy(vault_proxy, proxyAdmin, deployer, gov):
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
    return AuraBalStakerStrategy.at(strat_proxy.address, owner=gov)


@pytest.fixture
def new_bb_a_usd(new_strategy):
    return interface.ERC20(new_strategy.BB_A_USD())



def test_migrate(strat_proxy, vault_proxy, new_strategy, current_bb_a_usd, new_bb_a_usd, gov, want):
    ## 1. Reduce "minBbaUsdHarvest" threshold on old strategy and Harvest
    current_bbausd_bal = current_bb_a_usd.balanceOf(strat_proxy)
    strat_proxy.setMinBbaUsdHarvest(current_bbausd_bal - 1)
    strat_proxy.harvest()
    assert current_bb_a_usd.balanceOf(strat_proxy) == 0


    ##. 2. Sweep new bb_a_USD from old strat
    new_bbausd_bal_gov = new_bb_a_usd.balanceOf(gov)
    new_bbausd_bal = new_bb_a_usd.balanceOf(strat_proxy)
    vault_proxy.sweepExtraToken(new_bb_a_usd.address, {"from": gov})
    assert new_bb_a_usd.balanceOf(gov) == new_bbausd_bal_gov + new_bbausd_bal


    ## 3. Migrate strategies
    # Check Integrity
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
    assert new_strategy.BB_A_USD() != strat_proxy.BB_A_USD()
    assert new_strategy.minBbaUsdHarvest() == int(1000e18)
    # Check that threshold is lower than current bb_a_usd balance
    assert new_strategy.minBbaUsdHarvest() < new_bbausd_bal

    # Checkpoint balance
    balance = vault_proxy.balance()
    balance_of_pool = strat_proxy.balanceOfPool()
    vault_balance = want.balanceOf(vault_proxy)
    assert balance == balance_of_pool + vault_balance

    # Migrate strategy
    vault_proxy.withdrawToVault({"from": gov})

    assert strat_proxy.balanceOf() == 0
    vault_proxy.setStrategy(new_strategy, {"from": gov})
    assert vault_proxy.strategy() == new_strategy

    vault_proxy.earn({"from": gov})

    assert new_strategy.balanceOf() > 0
    assert vault_proxy.balance() == balance

    # Sleep to accrue rewards
    chain.sleep(days(3))
    chain.mine()


    # 4. Send new bb_a_usd o strat and harvest
    new_bb_a_usd.transfer(new_strategy, new_bbausd_bal, {"from": gov})
    assert new_bb_a_usd.balanceOf(new_strategy) == new_bbausd_bal
    new_strategy.harvest()
    assert new_bb_a_usd.balanceOf(new_strategy) == 0
