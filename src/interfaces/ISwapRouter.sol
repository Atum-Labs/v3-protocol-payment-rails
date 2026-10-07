// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title ISwapRouter
/// @notice Minimal Uniswap V3 SwapRouter02 interface used by DexSwapModule.
/// @dev SwapRouter02 only — the original SwapRouter keeps `deadline` in `ExactInputSingleParams`,
/// which changes the `exactInputSingle` selector.
/// @dev Only `exactInputSingle`, `multicall` and `factory` are needed. The module builds calldata
/// internally with a hardcoded `recipient = address(this)` to prevent output-redirection attacks.
/// All parameters are typed values; the caller never supplies raw bytes.
interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token.
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams`.
    /// @return amountOut The amount of the received token.
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    /// @notice Executes a batch of calls, reverting if `deadline` has passed.
    /// @dev SwapRouter02 has no `deadline` on the swap params; it is enforced here instead.
    /// @param deadline Unix timestamp after which the batch reverts.
    /// @param data ABI-encoded calls, delegatecalled against the router itself.
    /// @return results The raw return data of each call.
    function multicall(uint256 deadline, bytes[] calldata data) external payable returns (bytes[] memory results);

    /// @notice The Uniswap V3 factory this router routes through.
    /// @dev Used by DexSwapModule at construction to verify the configured router.
    function factory() external view returns (address);
}
