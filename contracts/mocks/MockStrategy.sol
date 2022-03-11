// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import {BaseStrategy} from "@badger-finance/BaseStrategy.sol";

import {IVault} from "../../interfaces/badger/IVault.sol";

contract MockStrategy is BaseStrategy {
    function initialize(address _vault) public initializer {
        __BaseStrategy_init(_vault);
        want = IVault(vault).token();
    }

    function getName() external pure virtual override returns (string memory) {}

    function _deposit(uint256 _want) internal virtual override {}

    function _harvest()
        internal
        virtual
        override
        returns (TokenAmount[] memory harvested)
    {}

    function _isTendable() internal pure virtual override returns (bool) {}

    function _tend()
        internal
        virtual
        override
        returns (TokenAmount[] memory tended)
    {}

    function _withdrawAll() internal virtual override {}

    function _withdrawSome(uint256 _amount)
        internal
        virtual
        override
        returns (uint256)
    {}

    function balanceOfPool() public view virtual override returns (uint256) {}

    function balanceOfRewards()
        external
        view
        virtual
        override
        returns (TokenAmount[] memory rewards)
    {}

    function getProtectedTokens()
        public
        view
        virtual
        override
        returns (address[] memory)
    {}
}
