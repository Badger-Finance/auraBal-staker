// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {IERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {MathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/MathUpgradeable.sol";
import {SafeMathUpgradeable} from "@openzeppelin-contracts-upgradeable/math/SafeMathUpgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin-contracts-upgradeable/token/ERC20/SafeERC20Upgradeable.sol";
import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

import {IVault} from "../interfaces/badger/IVault.sol";
import {IAsset} from "../interfaces/balancer/IAsset.sol";
import {IBalancerVault, JoinKind} from "../interfaces/balancer/IBalancerVault.sol";
import {IAuraToken} from "../interfaces/aura/IAuraToken.sol";
import {IBaseRewardPool} from "../interfaces/aura/IBaseRewardPool.sol";
import {IVirtualBalanceRewardPool} from "interfaces/aura/IVirtualBalanceRewardPool.sol";

contract AuraBalStakerStrategy is BaseStrategy {
    using SafeMathUpgradeable for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    bool public claimRewardsOnWithdrawAll;
    uint256 public balEthBptToAuraBalMinOutBps;

    IBaseRewardPool public constant AURABAL_REWARDS =
        IBaseRewardPool(0x5e5ea2048475854a5702F5B8468A51Ba1296EFcC);

    IVault public constant B_BB_A_USD =
        IVault(0x06D756861De0724FAd5B5636124e0f252d3C1404);
    IVault public constant GRAVIAURA =
        IVault(0xBA485b556399123261a5F9c95d413B4f93107407);

    IBalancerVault public constant BALANCER_VAULT =
        IBalancerVault(0xBA12222222228d8Ba445958a75a0704d566BF2C8);

    IAuraToken public constant AURA =
        IAuraToken(0xC0c293ce456fF0ED870ADd98a0828Dd4d2903DBF);

    IERC20Upgradeable public constant AURABAL =
        IERC20Upgradeable(0x616e8BfA43F920657B3497DBf40D6b1A02D4608d);
    IERC20Upgradeable public constant WETH =
        IERC20Upgradeable(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);
    IERC20Upgradeable public constant BAL =
        IERC20Upgradeable(0xba100000625a3754423978a60c9317c58a424e3D);
    IERC20Upgradeable public constant BALETH_BPT =
        IERC20Upgradeable(0x5c6Ee304399DBdB9C8Ef030aB642B10820DB8F56);
    IERC20Upgradeable public constant BB_A_USD =
        IERC20Upgradeable(0x7B50775383d3D6f0215A8F290f2C9e2eEBBEceb2);

    bytes32 public constant BAL_ETH_POOL_ID =
        0x5c6ee304399dbdb9c8ef030ab642b10820db8f56000200000000000000000014;
    bytes32 public constant AURABAL_BALETH_BPT_POOL_ID =
        0x3dd0843a028c86e0b760b1a76929d1c5ef93a2dd000200000000000000000249;

    /// @dev Initialize the Strategy with security settings as well as tokens
    /// @notice Proxies will set any non constant variable you declare as default value
    /// @dev add any extra changeable variable at end of initializer as shown
    function initialize(address _vault) public initializer {
        require(IVault(_vault).token() == address(AURABAL));

        __BaseStrategy_init(_vault);

        want = address(AURABAL);

        claimRewardsOnWithdrawAll = true;
        balEthBptToAuraBalMinOutBps = 9500; // max 5% slippage

        AURABAL.safeApprove(address(AURABAL_REWARDS), type(uint256).max);

        BAL.safeApprove(address(BALANCER_VAULT), type(uint256).max);
        BALETH_BPT.safeApprove(address(BALANCER_VAULT), type(uint256).max);

        BB_A_USD.approve(address(B_BB_A_USD), type(uint256).max);
        AURA.approve(address(GRAVIAURA), type(uint256).max);
    }

    function setClaimRewardsOnWithdrawAll(bool _claimRewardsOnWithdrawAll)
        external
    {
        _onlyGovernanceOrStrategist();
        claimRewardsOnWithdrawAll = _claimRewardsOnWithdrawAll;
    }

    function setBalEthBptToAuraBalMinOutBps(uint256 _minOutBps) external {
        _onlyGovernanceOrStrategist();
        require(_minOutBps <= MAX_BPS, "Invalid minOutBps");

        balEthBptToAuraBalMinOutBps = _minOutBps;
    }

    function doPendingApprovals() external {
        _onlyGovernanceOrStrategist();

        BB_A_USD.approve(address(B_BB_A_USD), type(uint256).max);
    }

    /// @dev Return the name of the strategy
    function getName() external pure override returns (string memory) {
        return "AuraBalStakerStrategy";
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
        address[] memory protectedTokens = new address[](4);
        protectedTokens[0] = want; // AURABAL
        protectedTokens[1] = address(AURA);
        protectedTokens[2] = address(BAL);
        protectedTokens[3] = address(BB_A_USD);
        return protectedTokens;
    }

    /// @dev Deposit `_amount` of want, investing it to earn yield
    function _deposit(uint256 _amount) internal override {
        // Add code here to invest `_amount` of want to earn yield
        AURABAL_REWARDS.stake(_amount);
    }

    /// @dev Withdraw all funds, this is used for migrations, most of the time for emergency reasons
    function _withdrawAll() internal override {
        uint256 poolBalance = balanceOfPool();
        if (poolBalance > 0) {
            AURABAL_REWARDS.withdrawAll(claimRewardsOnWithdrawAll);
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
            AURABAL_REWARDS.withdraw(toWithdraw, false);
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
        AURABAL_REWARDS.getReward();

        // Rewards are handled like this:
        // BB_A_USD  --> B-BB_A_USD (emitted)
        // BAL       --> BAL/ETH BPT --> AURABAL (autocompounded)
        // AURA      --> GRAVIAURA (emitted)
        harvested = new TokenAmount[](3);
        harvested[0].token = address(B_BB_A_USD);
        harvested[1].token = address(AURABAL);
        harvested[2].token = address(GRAVIAURA);

        // BB_A_USD --> B_BB_A_USD
        uint256 bbaUsdBalance = BB_A_USD.balanceOf(address(this));
        if (bbaUsdBalance > 0) {
            B_BB_A_USD.deposit(bbaUsdBalance);
            uint256 b_bbaUsdBalance = B_BB_A_USD.balanceOf(address(this));

            harvested[0].amount = b_bbaUsdBalance;
            _processExtraToken(address(B_BB_A_USD), b_bbaUsdBalance);
        }

        // BAL --> BAL/ETH BPT --> AURABAL
        uint256 balBalance = BAL.balanceOf(address(this));
        uint256 auraBalEarned;
        if (balBalance > 0) {
            // Deposit BAL --> BAL/ETH BPT
            IAsset[] memory assets = new IAsset[](2);
            assets[0] = IAsset(address(BAL));
            assets[1] = IAsset(address(WETH));
            uint256[] memory maxAmountsIn = new uint256[](2);
            maxAmountsIn[0] = balBalance;
            maxAmountsIn[1] = 0;

            BALANCER_VAULT.joinPool(
                BAL_ETH_POOL_ID,
                address(this),
                address(this),
                IBalancerVault.JoinPoolRequest({
                    assets: assets,
                    maxAmountsIn: maxAmountsIn,
                    userData: abi.encode(
                        JoinKind.EXACT_TOKENS_IN_FOR_BPT_OUT,
                        maxAmountsIn,
                        0 // minOut
                    ),
                    fromInternalBalance: false
                })
            );

            // Swap BAL/ETH BPT --> AURABAL
            uint256 balEthBptBalance = IERC20Upgradeable(BALETH_BPT).balanceOf(
                address(this)
            );

            // Swap BAL/ETH BPT --> auraBal
            IBalancerVault.FundManagement memory fundManagement = IBalancerVault
                .FundManagement({
                    sender: address(this),
                    fromInternalBalance: false,
                    recipient: payable(address(this)),
                    toInternalBalance: false
                });
            IBalancerVault.SingleSwap memory singleSwap = IBalancerVault
                .SingleSwap({
                    poolId: AURABAL_BALETH_BPT_POOL_ID,
                    kind: IBalancerVault.SwapKind.GIVEN_IN,
                    assetIn: IAsset(address(BALETH_BPT)),
                    assetOut: IAsset(address(AURABAL)),
                    amount: balEthBptBalance,
                    userData: new bytes(0)
                });
            uint256 minOut = (balEthBptBalance * balEthBptToAuraBalMinOutBps) /
                MAX_BPS;
            auraBalEarned = BALANCER_VAULT.swap(
                singleSwap,
                fundManagement,
                minOut,
                type(uint256).max
            );

            harvested[1].amount = auraBalEarned;
        }

        // AURA --> graviAURA
        uint256 auraBalance = AURA.balanceOf(address(this));
        if (auraBalance > 0) {
            GRAVIAURA.deposit(auraBalance);
            uint256 graviAuraBalance = GRAVIAURA.balanceOf(address(this));

            harvested[2].amount = graviAuraBalance;
            _processExtraToken(address(GRAVIAURA), graviAuraBalance);
        }

        // Report harvest
        _reportToVault(auraBalEarned);

        // Stake whatever is earned
        if (auraBalEarned > 0) {
            _deposit(auraBalEarned);
        }
    }

    // Example tend is a no-op which returns the values, could also just revert
    function _tend() internal override returns (TokenAmount[] memory tended) {
        revert("no op");
    }

    /// @dev Return the balance (in want) that the strategy has invested somewhere
    function balanceOfPool() public view override returns (uint256) {
        // Change this to return the amount of want invested in another protocol
        return AURABAL_REWARDS.balanceOf(address(this));
    }

    /// @dev Return the balance of rewards that the strategy has accrued
    /// @notice Used for offChain APY and Harvest Health monitoring
    function balanceOfRewards()
        external
        view
        override
        returns (TokenAmount[] memory rewards)
    {
        uint256 numExtraRewards = AURABAL_REWARDS.extraRewardsLength();
        rewards = new TokenAmount[](numExtraRewards + 2);

        uint256 balEarned = AURABAL_REWARDS.earned(address(this));

        rewards[0] = TokenAmount(address(BAL), balEarned);
        rewards[1] = TokenAmount(
            address(AURA),
            getMintableAuraRewards(balEarned)
        );

        for (uint256 i; i < numExtraRewards; ++i) {
            IVirtualBalanceRewardPool extraRewardPool = IVirtualBalanceRewardPool(
                    address(AURABAL_REWARDS.extraRewards(i))
                );
            rewards[i + 2] = TokenAmount(
                extraRewardPool.rewardToken(),
                extraRewardPool.earned(address(this))
            );
        }
    }

    /// @notice Returns the expected amount of AURA to be minted given an amount of BAL rewards
    /// @dev ref: https://etherscan.io/address/0xc0c293ce456ff0ed870add98a0828dd4d2903dbf#code#F1#L86
    function getMintableAuraRewards(uint256 _balAmount)
        public
        view
        returns (uint256 amount)
    {
        // NOTE: Only correct if AURA.minterMinted() == 0
        //       minterMinted is a private var in the contract, so we can't access it directly
        uint256 emissionsMinted = AURA.totalSupply() - AURA.INIT_MINT_AMOUNT();

        uint256 cliff = emissionsMinted.div(AURA.reductionPerCliff());
        uint256 totalCliffs = AURA.totalCliffs();

        if (cliff < totalCliffs) {
            uint256 reduction = totalCliffs.sub(cliff).mul(5).div(2).add(700);
            amount = _balAmount.mul(reduction).div(totalCliffs);

            uint256 amtTillMax = AURA.EMISSIONS_MAX_SUPPLY().sub(
                emissionsMinted
            );
            if (amount > amtTillMax) {
                amount = amtTillMax;
            }
        }
    }
}
