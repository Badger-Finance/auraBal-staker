import brownie
import pytest

from brownie import *

from helpers.constants import AddressZero


VAULT_ADDRESS = "0x37d9D2C6035b744849C15F1BFEE8F268a20fCBd8"
STRAT_ADDRESS = "0xfB490b5beA343ABAe0E71B61bBdfd4301F5e4df9"


@pytest.fixture
def vault_proxy():
    return TheVault.at(VAULT_ADDRESS)


@pytest.fixture
def strat_proxy():
    return AuraBalStakerStrategy.at(STRAT_ADDRESS)


@pytest.fixture
def proxy_admin():
    ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103"
    admin = web3.eth.getStorageAt(STRAT_ADDRESS, ADMIN_SLOT).hex()
    return Contract.from_explorer(admin)


@pytest.fixture
def proxy_admin_gov(proxy_admin):
    return accounts.at(proxy_admin.owner(), force=True)


def test_check_storage_integrity(
    strat_proxy, vault_proxy, deployer, proxy_admin, proxy_admin_gov
):
    old_want = strat_proxy.want()
    old_vault = strat_proxy.vault()
    old_withdrawalMaxDeviationThreshold = strat_proxy.withdrawalMaxDeviationThreshold()
    old_autoCompoundRatio = strat_proxy.autoCompoundRatio()
    old_claimRewardsOnWithdrawAll = strat_proxy.claimRewardsOnWithdrawAll()
    old_balEthBptToAuraBalMinOutBps = strat_proxy.balEthBptToAuraBalMinOutBps()

    with brownie.reverts():
        strat_proxy.B_BB_A_USD()

    logics = [
        AuraBalStakerStrategy.deploy({"from": deployer}),
    ]

    chain.snapshot()
    for new_strat_logic in logics:
        ## Do the Upgrade
        proxy_admin.upgrade(strat_proxy, new_strat_logic, {"from": proxy_admin_gov})

        ## Check Integrity
        assert old_want == strat_proxy.want()
        assert old_vault == strat_proxy.vault()
        assert (
            old_withdrawalMaxDeviationThreshold
            == strat_proxy.withdrawalMaxDeviationThreshold()
        )
        assert old_autoCompoundRatio == strat_proxy.autoCompoundRatio()
        assert old_claimRewardsOnWithdrawAll == strat_proxy.claimRewardsOnWithdrawAll()
        assert (
            old_balEthBptToAuraBalMinOutBps == strat_proxy.balEthBptToAuraBalMinOutBps()
        )
        # Check if var exists
        assert strat_proxy.B_BB_A_USD() != AddressZero

        gov = accounts.at(vault_proxy.governance(), force=True)
        strategist = accounts.at(vault_proxy.strategist(), force=True)

        ## Let's do a quick earn and harvest as well
        vault_proxy.earn({"from": gov})

        with brownie.reverts():
            strat_proxy.harvest({"from": gov})

        # Do pending approvals and then harvest
        strat_proxy.doPendingApprovals({"from": strategist})

        strat_proxy.harvest({"from": gov})

        chain.revert()
