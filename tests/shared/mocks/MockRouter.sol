// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";

/// @dev Controllable router mock for DexSwapModule unit tests.
/// Mirrors the Uniswap SwapRouter02 surface DexSwapModule calls: `exactInputSingle`, the
/// deadline-checking `multicall`, and `factory()`.
/// Simulates a DEX router that can succeed, fail, partially fill, or produce zero output.
contract MockRouter {
    bool public shouldRevert;
    bool public shouldSendNothing;
    uint256 public outputAmount;
    uint256 public pullAmountOverride;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function setShouldRevert(bool _val) external {
        shouldRevert = _val;
    }

    function setShouldSendNothing(bool _val) external {
        shouldSendNothing = _val;
    }

    function setOutputAmount(uint256 _amount) external {
        outputAmount = _amount;
    }

    function setPullAmountOverride(uint256 _amount) external {
        pullAmountOverride = _amount;
    }

    /// @dev Any contract address satisfies the module's constructor probe.
    function factory() external view returns (address) {
        return address(this);
    }

    /// @dev SwapRouter02's deadline-checked batch entry point — the function the module calls.
    /// Delegatecall keeps `msg.sender` equal to the module, as the real router does.
    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory results) {
        require(block.timestamp <= deadline, "Transaction too old");
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; ++i) {
            results[i] = Address.functionDelegateCall(address(this), data[i]);
        }
    }

    /// @dev Uniswap V3 exactInputSingle — invoked through `multicall`.
    /// Pulls sellToken from caller (module), sends buyToken to recipient (module, then forwarded).
    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        if (shouldRevert) revert("MockRouter: forced revert");

        uint256 pullAmount = pullAmountOverride > 0 ? pullAmountOverride : params.amountIn;
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), pullAmount);

        if (shouldSendNothing) return 0;

        amountOut = outputAmount;
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }

    receive() external payable { }
}
