// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {MathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

import {IVault} from "../interfaces/badger/IVault.sol";
import {route, IBaseV1Router01} from "../interfaces/solidly/IBaseV1Router01.sol";
import {IMultiRewards} from "../interfaces/oxd/IMultiRewards.sol";

contract OxSolidStaker is BaseStrategy {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bool public claimRewardsOnWithdrawAll;
    IVault public bvlOxd;

    IMultiRewards public constant OXSOLID_REWARDS =
        IMultiRewards(0xDA0067ec0925eBD6D583553139587522310Bec60);

    IBaseV1Router01 public constant SOLIDLY_ROUTER =
        IBaseV1Router01(0xa38cd27185a464914D3046f0AB9d43356B34829D);

    IERC20Upgradeable public constant OXSOLID =
        IERC20Upgradeable(0xDA0053F0bEfCbcaC208A3f867BB243716734D809);
    IERC20Upgradeable public constant OXD =
        IERC20Upgradeable(0xc5A9848b9d145965d821AaeC8fA32aaEE026492d);
    IERC20Upgradeable public constant SOLID =
        IERC20Upgradeable(0x888EF71766ca594DED1F0FA3AE64eD2941740A20);

    /// @dev Initialize the Strategy with security settings as well as tokens
    /// @notice Proxies will set any non constant variable you declare as default value
    /// @dev add any extra changeable variable at end of initializer as shown
    function initialize(address _vault, address _bvlOxd) public initializer {
        assert(IVault(_vault).token() == address(OXSOLID));

        __BaseStrategy_init(_vault);

        want = address(OXSOLID);
        bvlOxd = IVault(_bvlOxd);

        claimRewardsOnWithdrawAll = true;

        OXSOLID.safeApprove(address(OXSOLID_REWARDS), type(uint256).max);
        OXD.safeApprove(_bvlOxd, type(uint256).max);
        SOLID.safeApprove(address(SOLIDLY_ROUTER), type(uint256).max);
    }

    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "OxSolidStaker";
    }

    /// @dev Return a list of protected tokens
    /// @notice It's very important all tokens that are meant to be in the strategy to be marked as protected
    /// @notice this provides security guarantees to the depositors they can't be sweeped away
    function getProtectedTokens()
        public
        view
        virtual
        override
        returns (address[] memory)
    {
        address[] memory protectedTokens = new address[](3);
        protectedTokens[0] = want; // OXSOLID
        protectedTokens[1] = address(OXD);
        protectedTokens[2] = address(SOLID);
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        // Add code here to invest `_amount` of want to earn yield
        OXSOLID_REWARDS.stake(_amount);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        uint256 poolBalance = balanceOfPool();
        if (poolBalance > 0) {
            if (claimRewardsOnWithdrawAll) {
                OXSOLID_REWARDS.exit();
            } else {
                OXSOLID_REWARDS.withdraw(balanceOfPool());
            }
        }
    }

    /// @dev Withdraw `_amount` of want, so that it can be sent to the vault / depositor
    /// @notice just unlock the funds and return the amount you could unlock
    function _withdrawSome(uint256 _amount)
        internal
        override
        returns (uint256)
    {
        uint256 wantBalance = balanceOfWant();
        if (wantBalance < _amount) {
            uint256 toWithdraw = _amount.sub(wantBalance);
            uint256 poolBalance = balanceOfPool();
            if (poolBalance < toWithdraw) {
                OXSOLID_REWARDS.withdraw(poolBalance);
            } else {
                OXSOLID_REWARDS.withdraw(toWithdraw);
            }
        }
        return MathUpgradeable.min(_amount, balanceOfWant());
    }

    /// @dev Does this function require `tend` to be called?
    function _isTendable() internal pure override returns (bool) {
        return false; // Change to true if the strategy should be tended
    }

    function _harvest()
        internal
        override
        returns (TokenAmount[] memory harvested)
    {
        uint256 oxSolidBefore = balanceOfWant();

        OXSOLID_REWARDS.getReward();

        uint256 numRewards = OXSOLID_REWARDS.rewardTokensLength();
        harvested = new TokenAmount[](numRewards - 1);

        // OXD --> bvlOXD
        uint256 oxdBalance = OXD.balanceOf(address(this));
        harvested[0].token = address(bvlOxd);
        if (oxdBalance > 0) {
            bvlOxd.deposit(oxdBalance);
            uint256 vaultBalance = bvlOxd.balanceOf(address(this));

            harvested[0].amount = vaultBalance;
            _processExtraToken(address(bvlOxd), vaultBalance);
        }

        // SOLID --> OXSOLID
        uint256 solidBalance = SOLID.balanceOf(address(this));
        if (solidBalance > 0) {
            (, bool stable) = SOLIDLY_ROUTER.getAmountOut(
                solidBalance,
                address(SOLID),
                address(OXSOLID)
            );

            route[] memory routeArray = new route[](1);
            routeArray[0] = route(address(SOLID), address(OXSOLID), stable);
            SOLIDLY_ROUTER.swapExactTokensForTokens(
                solidBalance,
                solidBalance, // at least 1:1
                routeArray,
                address(this),
                block.timestamp
            );
        }

        // OXSOLID (want)
        uint256 oxSolidGained = balanceOfWant().sub(oxSolidBefore);
        harvested[1] = TokenAmount(address(OXSOLID), oxSolidGained);
        _reportToVault(oxSolidGained);
        if (oxSolidGained > 0) {
            // Redeposit
            _deposit(oxSolidGained);
        }

        // 0 --> OXD
        // 1 --> OXSOLID
        // 2 --> SOLID
        // ------------
        // 3 --> WFTM |
        // ...        | --> Emitted through BADGER_TREE
        // ...        |
        for (uint256 i = 3; i < numRewards; ++i) {
            address rewardToken = OXSOLID_REWARDS.rewardTokens(i);
            uint256 rewardBalance = IERC20Upgradeable(rewardToken).balanceOf(
                address(this)
            );
            harvested[i - 1] = TokenAmount(rewardToken, rewardBalance);
            if (rewardBalance > 0) {
                _processExtraToken(rewardToken, rewardBalance);
            }
        }
    }

    // Example tend is a no-op which returns the values, could also just revert
    function _tend() internal override returns (TokenAmount[] memory tended) {
        revert("no op");
    }

    /// @dev Return the balance (in want) that the strategy has invested somewhere
    function balanceOfPool() public view override returns (uint256) {
        // Change this to return the amount of want invested in another protocol
        return OXSOLID_REWARDS.balanceOf(address(this));
    }

    /// @dev Return the balance of rewards that the strategy has accrued
    /// @notice Used for offChain APY and Harvest Health monitoring
    function balanceOfRewards()
        external
        view
        override
        returns (TokenAmount[] memory rewards)
    {
        uint256 numRewards = OXSOLID_REWARDS.rewardTokensLength();
        rewards = new TokenAmount[](numRewards);
        for (uint256 i; i < numRewards; ++i) {
            address rewardToken = OXSOLID_REWARDS.rewardTokens(i);
            rewards[i] = TokenAmount(
                rewardToken,
                OXSOLID_REWARDS.earned(address(this), rewardToken)
            );
        }
    }
}

/*
TODO:
- What should autoCompoundRatio be?
*/
