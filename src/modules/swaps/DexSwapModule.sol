// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { IDexSwapModule } from "../../interfaces/IDexSwapModule.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { ISwapRouter } from "../../interfaces/ISwapRouter.sol";
import { IChainlinkAggregatorV3 } from "../../interfaces/IChainlinkAggregatorV3.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DexSwapModule
/// @author Credit Cooperative
/// @notice Oracle-only synchronous swap module — the permissionless executor controls nothing.
/// @dev See {IDexSwapModule} for the full interface. Fee-on-transfer tokens are NOT supported.
/// @dev Requires Uniswap SwapRouter02 — see {ISwapRouter}.
contract DexSwapModule is IDexSwapModule, ActionModuleBase, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDexSwapModule
    address public immutable override router;

    /// @inheritdoc IDexSwapModule
    address public immutable override sequencerUptimeFeed;

    /// @inheritdoc IDexSwapModule
    uint256 public immutable override sequencerGracePeriod;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _router Uniswap V3 SwapRouter02 address; must expose `factory()`. Chain-specific.
    /// @param _sequencerUptimeFeed Chainlink L2 sequencer uptime feed; address(0) on L1.
    /// @param _sequencerGracePeriod Seconds after sequencer recovery before trusting oracles.
    constructor(address _router, address _sequencerUptimeFeed, uint256 _sequencerGracePeriod) {
        if (_router == address(0)) revert Errors.DexSwapModule_ZeroRouter();
        if (_router.code.length == 0) revert Errors.DexSwapModule_RouterNotContract(_router);

        // Code size alone does not prove a router: a foreign chain's router address may hold an
        // unrelated contract that answers calls without reverting.
        (bool probeOk, bytes memory probeData) = _router.staticcall(abi.encodeCall(ISwapRouter.factory, ()));
        if (!probeOk || probeData.length != 32) revert Errors.DexSwapModule_RouterNotUniswap(_router);
        address uniswapFactory = abi.decode(probeData, (address));
        if (uniswapFactory.code.length == 0) revert Errors.DexSwapModule_RouterNotUniswap(_router);

        router = _router;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            NON-CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function execute(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        override(ActionModuleBase, IActionModule)
        nonReentrant
        returns (DataTypes.ExecutionResult memory)
    {
        (bool valid, string memory reason, DataTypes.DexSwapParams memory cfg, uint256 oracleFloor) =
            _validate(token, amount, params);
        if (!valid) return _failedResult(token, reason);

        (bool ok, uint256 amountOut) = _executeSwap(token, amount, cfg, oracleFloor);

        _returnLeftover(token, msg.sender);

        if (!ok) return _failedResult(token, "Router call failed");
        if (amountOut < oracleFloor) {
            revert Errors.DexSwapModule_InsufficientOutput(amountOut, oracleFloor);
        }

        emit SwapExecuted(msg.sender, token, cfg.targetToken, amount, amountOut);

        return _successResult(amountOut, cfg.targetToken, "");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANT FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IActionModule
    function validate(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        override(ActionModuleBase, IActionModule)
        returns (bool isValid, string memory reason)
    {
        (isValid, reason,,) = _validate(token, amount, params);
    }

    /// @inheritdoc IActionModule
    function estimateOutput(
        address token,
        uint256 amount,
        bytes calldata params
    )
        external
        view
        override(ActionModuleBase, IActionModule)
        returns (uint256 estimatedOutput, address outputToken)
    {
        DataTypes.DexSwapParams memory cfg = decodeParams(params);
        (bool oracleOk, uint256 expected) = _computeExpectedOutput(token, amount, cfg);
        if (oracleOk) return (expected, cfg.targetToken);
        return (0, cfg.targetToken);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "SWAP";
    }

    /// @inheritdoc IDexSwapModule
    function encodeParams(DataTypes.DexSwapParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(params);
    }

    /// @inheritdoc IDexSwapModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.DexSwapParams memory params) {
        (params) = abi.decode(encoded, (DataTypes.DexSwapParams));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Single source of truth for all view-safe validation. Called by both validate() and execute().
    function _validate(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (bool valid, string memory reason, DataTypes.DexSwapParams memory cfg, uint256 oracleFloor)
    {
        (valid, reason, cfg) = _validateParams(token, amount, params);
        if (!valid) return (false, reason, cfg, 0);

        bool oracleOk;
        (oracleOk, oracleFloor) = _computeOracleFloor(token, amount, cfg);
        if (!oracleOk) return (false, "Oracle price unavailable", cfg, 0);
        if (oracleFloor == 0) return (false, "Amount too small for safe swap", cfg, 0);

        if (!_hasSufficientBalance(token, amount)) return (false, "Insufficient balance", cfg, 0);

        return (true, "", cfg, oracleFloor);
    }

    /// @dev Validates static params: encoding length, targetToken, amount, oracle config, deadline config.
    // solhint-disable-next-line code-complexity
    function _validateParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        pure
        returns (bool valid, string memory reason, DataTypes.DexSwapParams memory cfg)
    {
        if (params.length < 256) {
            return (false, "Invalid params encoding", cfg);
        }

        cfg = abi.decode(params, (DataTypes.DexSwapParams));

        if (cfg.targetToken == address(0)) return (false, "Zero target token", cfg);
        if (cfg.targetToken == token) return (false, "Same input and output token", cfg);
        if (amount == 0) return (false, "Zero sell amount", cfg);
        if (cfg.maxSlippageBps == 0 || cfg.maxSlippageBps > 10_000) return (false, "Invalid slippage bps", cfg);
        if (cfg.maxAmount != 0 && amount > cfg.maxAmount) return (false, "Exceeds max swap amount", cfg);
        if (cfg.sellTokenPriceFeed == address(0)) return (false, "Missing sell token price feed", cfg);
        if (cfg.buyTokenPriceFeed == address(0)) return (false, "Missing buy token price feed", cfg);
        if (cfg.maxStaleness == 0) return (false, "Zero max staleness", cfg);
        if (cfg.swapDeadlineSeconds == 0) return (false, "Zero swap deadline", cfg);

        return (true, "", cfg);
    }

    /// @dev Returns false when the L2 sequencer is down or still inside its recovery grace period.
    function _isSequencerHealthy() private view returns (bool) {
        if (sequencerUptimeFeed == address(0)) return true;

        try IChainlinkAggregatorV3(sequencerUptimeFeed).latestRoundData() returns (
            uint80, int256 answer, uint256 startedAt, uint256, uint80
        ) {
            // answer == 0 → sequencer is up; answer == 1 → sequencer is down
            if (answer != 0) return false;
            if (startedAt == 0 || startedAt > block.timestamp) return false;
            return block.timestamp - startedAt >= sequencerGracePeriod;
        } catch {
            return false;
        }
    }

    /// @dev Validates Chainlink price feed; checks L2 sequencer uptime when configured.
    function _getOraclePrice(
        address feed,
        uint256 maxStaleness
    )
        private
        view
        returns (bool ok, uint256 price, uint8 feedDecimals)
    {
        if (!_isSequencerHealthy()) return (false, 0, 0);

        try IChainlinkAggregatorV3(feed).latestRoundData() returns (
            uint80, int256 answer, uint256, uint256 updatedAt, uint80
        ) {
            if (answer <= 0) return (false, 0, 0);
            if (uint256(answer) > type(uint128).max) return (false, 0, 0);
            if (updatedAt > block.timestamp) return (false, 0, 0);
            if (block.timestamp - updatedAt > maxStaleness) return (false, 0, 0);
            try IChainlinkAggregatorV3(feed).decimals() returns (uint8 dec) {
                return (true, uint256(answer), dec);
            } catch {
                return (false, 0, 0);
            }
        } catch {
            return (false, 0, 0);
        }
    }

    /// @dev Computes oracle-expected output: amount * sellPrice / buyPrice, decimal-adjusted.
    function _computeExpectedOutput(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg
    )
        private
        view
        returns (bool ok, uint256 expectedOutput)
    {
        uint256 sellPrice;
        uint256 buyPrice;
        uint256 sellExp;
        uint256 buyExp;

        {
            uint8 sellFeedDec;
            uint8 buyFeedDec;
            bool oracleOk;
            (oracleOk, sellPrice, sellFeedDec) = _getOraclePrice(cfg.sellTokenPriceFeed, cfg.maxStaleness);
            if (!oracleOk) return (false, 0);
            (oracleOk, buyPrice, buyFeedDec) = _getOraclePrice(cfg.buyTokenPriceFeed, cfg.maxStaleness);
            if (!oracleOk) return (false, 0);

            (bool sellDecOk, uint8 sellTokenDec) = _getTokenDecimals(token);
            if (!sellDecOk) return (false, 0);
            (bool buyDecOk, uint8 buyTokenDec) = _getTokenDecimals(cfg.targetToken);
            if (!buyDecOk) return (false, 0);

            sellExp = uint256(sellTokenDec) + uint256(sellFeedDec);
            buyExp = uint256(buyTokenDec) + uint256(buyFeedDec);
        }

        if (buyExp >= sellExp) {
            uint256 scale = 10 ** (buyExp - sellExp);
            if (sellPrice > type(uint256).max / scale) return (false, 0);
            expectedOutput = Math.mulDiv(amount, sellPrice * scale, buyPrice);
        } else {
            uint256 scale = 10 ** (sellExp - buyExp);
            if (buyPrice > type(uint256).max / scale) return (false, 0);
            expectedOutput = Math.mulDiv(amount, sellPrice, buyPrice * scale);
        }

        return (true, expectedOutput);
    }

    /// @dev Applies maxSlippageBps to oracle-expected output to get the minimum floor.
    function _computeOracleFloor(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg
    )
        private
        view
        returns (bool ok, uint256 floor)
    {
        (bool oracleOk, uint256 expected) = _computeExpectedOutput(token, amount, cfg);
        if (!oracleOk) return (false, 0);

        floor = Math.mulDiv(expected, 10_000 - uint256(cfg.maxSlippageBps), 10_000);
        return (true, floor);
    }

    /// @dev Safe wrapper for IERC20Metadata.decimals().
    function _getTokenDecimals(address token) private view returns (bool ok, uint8 tokenDecimals) {
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return (true, dec);
        } catch {
            return (false, 0);
        }
    }

    /// @dev Pulls sellToken, calls the immutable router, measures output via balance diff, forwards to msg.sender.
    function _executeSwap(
        address token,
        uint256 amount,
        DataTypes.DexSwapParams memory cfg,
        uint256 oracleFloor
    )
        private
        returns (bool ok, uint256 amountOut)
    {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        IERC20(token).forceApprove(router, amount);

        uint256 buyTokenBefore = IERC20(cfg.targetToken).balanceOf(address(this));

        // SwapRouter02 has no `deadline` param; the multicall wrapper enforces it. Reverts inside
        // the batch (e.g. `amountOutMinimum` not met) propagate out of `multicall`.
        bytes[] memory swapBatch = new bytes[](1);
        swapBatch[0] = abi.encodeCall(
            ISwapRouter.exactInputSingle,
            (ISwapRouter.ExactInputSingleParams({
                    tokenIn: token,
                    tokenOut: cfg.targetToken,
                    fee: cfg.fee,
                    recipient: address(this),
                    amountIn: amount,
                    amountOutMinimum: oracleFloor,
                    sqrtPriceLimitX96: 0
                }))
        );
        bytes memory swapCalldata =
            abi.encodeCall(ISwapRouter.multicall, (block.timestamp + cfg.swapDeadlineSeconds, swapBatch));

        (ok,) = router.call(swapCalldata);

        IERC20(token).forceApprove(router, 0);

        if (!ok) return (false, 0);

        uint256 buyTokenAfter = IERC20(cfg.targetToken).balanceOf(address(this));
        if (buyTokenAfter < buyTokenBefore) return (false, 0);
        amountOut = buyTokenAfter - buyTokenBefore;

        if (amountOut > 0) {
            IERC20(cfg.targetToken).safeTransfer(msg.sender, amountOut);
        }
    }

    /// @dev Transfers any sellToken remaining in the module back to the PaymentRails.
    function _returnLeftover(address token, address paymentRails) private {
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(paymentRails, bal);
        }
    }
}
