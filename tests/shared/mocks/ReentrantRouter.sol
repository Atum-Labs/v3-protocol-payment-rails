// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Address } from "@openzeppelin/contracts/utils/Address.sol";
import { DexSwapModule } from "../../../src/modules/swaps/DexSwapModule.sol";

/// @dev Router that re-enters DexSwapModule.execute() during a swap.
/// Used to verify that the nonReentrant guard on execute() blocks reentrancy
/// through a malicious router callback.
contract ReentrantRouter {
    DexSwapModule public immutable module;

    bytes public reentrantCallParams;
    bool public reentrancyAttempted;
    bool public reentrancySucceeded;
    bytes public revertReasonBytes;

    uint256 public outputAmount;

    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    constructor(address _module) {
        module = DexSwapModule(_module);
    }

    function setOutputAmount(uint256 _amount) external {
        outputAmount = _amount;
    }

    /// @dev Satisfies the constructor's router probe.
    function factory() external view returns (address) {
        return address(this);
    }

    /// @dev SwapRouter02's deadline-checked batch entry point; the reentrancy attempt is made
    /// from inside the delegatecalled swap.
    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory results) {
        require(block.timestamp <= deadline, "Transaction too old");
        results = new bytes[](data.length);
        for (uint256 i = 0; i < data.length; ++i) {
            results[i] = Address.functionDelegateCall(address(this), data[i]);
        }
    }

    function setReentrantCall(address token, uint256 amount, bytes calldata params) external {
        reentrantCallParams = abi.encode(token, amount, params);
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external returns (uint256 amountOut) {
        IERC20(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn);

        if (reentrantCallParams.length > 0) {
            (address token, uint256 amount, bytes memory moduleParams) =
                abi.decode(reentrantCallParams, (address, uint256, bytes));

            reentrancyAttempted = true;
            (bool success, bytes memory returnData) =
                address(module).call(abi.encodeCall(module.execute, (token, amount, moduleParams)));
            reentrancySucceeded = success;
            if (!success) {
                revertReasonBytes = returnData;
            }
        }

        amountOut = outputAmount;
        IERC20(params.tokenOut).transfer(params.recipient, amountOut);
    }
}
