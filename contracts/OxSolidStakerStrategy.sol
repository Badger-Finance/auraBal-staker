// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {MathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

import {IVault} from "../interfaces/badger/IVault.sol";
import {ICurveRouter} from "../interfaces/curve/ICurveRouter.sol";
import {route, IBaseV1Router01} from "../interfaces/solidly/IBaseV1Router01.sol";
import {IUniswapRouterV2} from "../interfaces/uniswap/IUniswapRouterV2.sol";
import {IMultiRewards} from "../interfaces/oxd/IMultiRewards.sol";

contract OxSolidStakerStrategy is BaseStrategy {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bool public claimRewardsOnWithdrawAll;
    IVault public bvlOxd;
    mapping(address => bool) hasRouterApprovals;

    IMultiRewards public constant OXSOLID_REWARDS =
        IMultiRewards(0xDA0067ec0925eBD6D583553139587522310Bec60);

    ICurveRouter public constant CURVE_ROUTER =
        ICurveRouter(0x74E25054e98fd3FCd4bbB13A962B43E49098586f);
    IBaseV1Router01 public constant SOLIDLY_ROUTER =
        IBaseV1Router01(0xa38cd27185a464914D3046f0AB9d43356B34829D);
    IUniswapRouterV2 public constant SPOOKY_ROUTER =
        IUniswapRouterV2(0xF491e7B69E4244ad4002BC14e878a34207E38c29);

    IERC20Upgradeable public constant OXSOLID =
        IERC20Upgradeable(0xDA0053F0bEfCbcaC208A3f867BB243716734D809);
    IERC20Upgradeable public constant OXD =
        IERC20Upgradeable(0xc5A9848b9d145965d821AaeC8fA32aaEE026492d);
    IERC20Upgradeable public constant SOLID =
        IERC20Upgradeable(0x888EF71766ca594DED1F0FA3AE64eD2941740A20);
    IERC20Upgradeable public constant WFTM =
        IERC20Upgradeable(0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83);

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

        _doRouterApprovals(address(WFTM));
    }

    function setClaimRewardsOnWithdrawAll(bool _claimRewardsOnWithdrawAll)
        external
    {
        _onlyGovernanceOrStrategist();
        claimRewardsOnWithdrawAll = _claimRewardsOnWithdrawAll;
    }

    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "OxSolidStakerStrategy";
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

        // Rewards are handled like this:
        // ...            |
        // ...            | --> WFTM --> SOLID --> OXSOLID
        // ----------------
        // 3  --> WFTM    | --> SOLID --> OXSOLID
        // ----------------
        // 2  --> SOLID     --> OXSOLID
        // 1  --> OXSOLID       (Auto-compounded)
        // 0  --> OXD       --> bvlOXD (emitted)

        harvested = new TokenAmount[](2);
        harvested[0].token = address(OXSOLID);
        harvested[1].token = address(bvlOxd);

        // Reward[i] --> WFTM
        for (uint256 i = 4; i < numRewards; ++i) {
            address rewardToken = OXSOLID_REWARDS.rewardTokens(i);

            // Just in case there's duplication in the rewards array
            if (
                rewardToken == address(WFTM) ||
                rewardToken == address(SOLID) ||
                rewardToken == address(OXSOLID) ||
                rewardToken == address(OXD)
            ) {
                continue;
            }
            uint256 rewardBalance = IERC20Upgradeable(rewardToken).balanceOf(
                address(this)
            );
            if (rewardBalance > 0) {
                if (!hasRouterApprovals[rewardToken]) {
                    _doRouterApprovals(rewardToken);
                }
                _doOptimalSwap(rewardToken, address(WFTM), rewardBalance);
            }
        }

        // WFTM --> SOLID
        uint256 wftmBalance = WFTM.balanceOf(address(this));
        if (wftmBalance > 0) {
            route[] memory routeArray = new route[](1);
            routeArray[0] = route(address(WFTM), address(SOLID), false);

            SOLIDLY_ROUTER.swapExactTokensForTokens(
                wftmBalance,
                0,
                routeArray,
                address(this),
                block.timestamp
            );
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
        _reportToVault(oxSolidGained);
        if (oxSolidGained > 0) {
            _deposit(oxSolidGained);

            harvested[0].amount = oxSolidGained;
        }

        // OXD --> bvlOXD
        uint256 oxdBalance = OXD.balanceOf(address(this));
        if (oxdBalance > 0) {
            bvlOxd.deposit(oxdBalance);
            uint256 vaultBalance = bvlOxd.balanceOf(address(this));

            harvested[1].amount = vaultBalance;
            _processExtraToken(address(bvlOxd), vaultBalance);
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

    // ====================
    // ===== Swapping =====
    // ====================

    /// @dev View function for testing the routing of the strategy
    function findOptimalSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (string memory, uint256 amount) {
        // Check Solidly
        (uint256 solidlyQuote, bool stable) = IBaseV1Router01(SOLIDLY_ROUTER)
            .getAmountOut(amountIn, tokenIn, tokenOut);

        // Check Curve
        (, uint256 curveQuote) = ICurveRouter(CURVE_ROUTER).get_best_rate(
            tokenIn,
            tokenOut,
            amountIn
        );

        uint256 spookyQuote; // 0 by default

        // Check Spooky (Can Revert)
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);

        try
            IUniswapRouterV2(SPOOKY_ROUTER).getAmountsOut(amountIn, path)
        returns (uint256[] memory spookyAmounts) {
            spookyQuote = spookyAmounts[spookyAmounts.length - 1]; // Last one is the outToken
        } catch (bytes memory) {
            // We ignore as it means it's zero
        }

        // On average, we expect Solidly and Curve to offer better slippage
        // Spooky will be the default case
        if (solidlyQuote > spookyQuote) {
            // Either SOLID or curve
            if (curveQuote > solidlyQuote) {
                // Curve
                return ("curve", curveQuote);
            } else {
                // Solid
                return ("SOLID", solidlyQuote);
            }
        } else if (curveQuote > spookyQuote) {
            // Curve is greater than both
            return ("curve", curveQuote);
        } else {
            // Spooky is best
            return ("spooky", spookyQuote);
        }
    }

    function _doRouterApprovals(address tokenIn) internal {
        IERC20Upgradeable(tokenIn).safeApprove(
            address(SOLIDLY_ROUTER),
            type(uint256).max
        );
        IERC20Upgradeable(tokenIn).safeApprove(
            address(SPOOKY_ROUTER),
            type(uint256).max
        );
        IERC20Upgradeable(tokenIn).safeApprove(
            address(CURVE_ROUTER),
            type(uint256).max
        );

        hasRouterApprovals[tokenIn] = true;
    }

    function _doOptimalSwap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (uint256) {
        // Check Solidly
        (uint256 solidlyQuote, bool stable) = IBaseV1Router01(SOLIDLY_ROUTER)
            .getAmountOut(amountIn, tokenIn, tokenOut);

        // Check Curve
        (, uint256 curveQuote) = ICurveRouter(CURVE_ROUTER).get_best_rate(
            tokenIn,
            tokenOut,
            amountIn
        );

        uint256 spookyQuote; // 0 by default

        // Check Spooky (Can Revert)
        address[] memory path = new address[](2);
        path[0] = address(tokenIn);
        path[1] = address(tokenOut);

        // NOTE: Ganache sometimes will randomly revert over this line, no clue why, you may need to comment this out for testing on forknet
        try SPOOKY_ROUTER.getAmountsOut(amountIn, path) returns (
            uint256[] memory spookyAmounts
        ) {
            spookyQuote = spookyAmounts[spookyAmounts.length - 1]; // Last one is the outToken
        } catch (bytes memory) {
            // We ignore as it means it's zero
        }

        // On average, we expect Solidly and Curve to offer better slippage
        // Spooky will be the default case
        // Because we got quotes, we add them as min, but they are not guarantees we'll actually not get rekt
        if (solidlyQuote > spookyQuote) {
            // Either SOLID or curve
            if (curveQuote > solidlyQuote) {
                // Curve swap here
                return
                    CURVE_ROUTER.exchange_with_best_rate(
                        tokenIn,
                        tokenOut,
                        amountIn,
                        curveQuote
                    );
            } else {
                // Solid swap here
                route[] memory _route = new route[](1);
                _route[0] = route(tokenIn, tokenOut, stable);
                uint256[] memory amounts = SOLIDLY_ROUTER
                    .swapExactTokensForTokens(
                        amountIn,
                        solidlyQuote,
                        _route,
                        address(this),
                        now
                    );
                return amounts[amounts.length - 1];
            }
        } else if (curveQuote > spookyQuote) {
            // Curve Swap here
            return
                CURVE_ROUTER.exchange_with_best_rate(
                    tokenIn,
                    tokenOut,
                    amountIn,
                    curveQuote
                );
        } else {
            // Spooky swap here
            uint256[] memory amounts = SPOOKY_ROUTER.swapExactTokensForTokens(
                amountIn,
                spookyQuote, // This is not a guarantee of anything beside the quote we already got, if we got frontrun we're already rekt here
                path,
                address(this),
                now
            ); // Btw, if you're frontrunning us on this contract, email me at alex@badger.finance we have actual money for you to make

            return amounts[amounts.length - 1];
        }
    }
}
