// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

/// @dev Contracts that have code at a router address but are not Uniswap routers. On Base, the
/// Ethereum SwapRouter address 0xE592427A0AEce92De3Edee1F18E0157C05861564 holds exactly such a
/// contract, so a code-size check alone accepts it.

/// @dev Answers every call with empty return data instead of reverting.
contract PermissiveFallbackRouter {
    // solhint-disable-next-line no-empty-blocks
    fallback() external payable { }

    // solhint-disable-next-line no-empty-blocks
    receive() external payable { }
}

/// @dev Exposes `factory()` but points at an address with no code.
contract EoaFactoryRouter {
    address public immutable fakeFactory;

    constructor(address _fakeFactory) {
        fakeFactory = _fakeFactory;
    }

    function factory() external view returns (address) {
        return fakeFactory;
    }
}
