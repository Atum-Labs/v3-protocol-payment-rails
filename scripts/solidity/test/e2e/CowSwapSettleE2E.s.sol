// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { ICowSwapModule } from "../../../../src/interfaces/ICowSwapModule.sol";
import { ISwapRouter } from "../../../../src/interfaces/ISwapRouter.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice GPv2 trade struct, as consumed by `GPv2Settlement.settle`.
struct GPv2TradeData {
    uint256 sellTokenIndex;
    uint256 buyTokenIndex;
    address receiver;
    uint256 sellAmount;
    uint256 buyAmount;
    uint32 validTo;
    bytes32 appData;
    uint256 feeAmount;
    uint256 flags;
    uint256 executedAmount;
    bytes signature;
}

/// @notice GPv2 solver interaction struct, as consumed by `GPv2Settlement.settle`.
struct GPv2InteractionData {
    address target;
    uint256 value;
    bytes callData;
}

interface IGPv2SettlementSettle {
    function settle(
        address[] calldata tokens,
        uint256[] calldata clearingPrices,
        GPv2TradeData[] calldata trades,
        GPv2InteractionData[][3] calldata interactions
    )
        external;

    function filledAmount(bytes calldata orderUid) external view returns (uint256);
}

/// @title CowSwapSettleE2E
/// @author Credit Cooperative
/// @notice Fills a live CowSwapModule order by acting as a real CoW Protocol solver.
/// @dev Used by `scripts/bash/e2e-anvil.sh` to close the CowSwap lifecycle end-to-end: the module
///      places an EIP-1271 order, and this script settles it through the real GPv2Settlement
///      contract, sourcing the buyToken from a real Uniswap V3 pool inside a solver interaction.
///      The caller must already be an allow-listed solver (the harness adds it via the
///      authenticator's manager).
///
///      Required env:
///        E2E_COW_MODULE      CowSwapModule holding the order
///        E2E_ORDER_ID        GPv2 order digest emitted by {OrderCreated}
///        E2E_BUY_AMOUNT      buyAmount from {OrderCreated} (the oracle floor)
///        E2E_APP_DATA        appData from {OrderCreated}
///        E2E_SOLVER_PK       private key of the allow-listed solver
///        E2E_SETTLEMENT      GPv2Settlement address
///        E2E_ROUTER          Uniswap V3 SwapRouter used to source the buyToken
///        E2E_POOL_FEE        Uniswap V3 fee tier for the sell/buy pair
contract CowSwapSettleE2E is Script {
    /// @dev Signing scheme EIP-1271 (0b10) in bits 5-6 of the GPv2 trade flags; sell kind,
    ///      fill-or-kill, erc20 balances everywhere else.
    uint256 internal constant FLAGS_SELL_FILL_OR_KILL_EIP1271 = 2 << 5;

    /// @dev Bundles the env-provided settlement inputs so `run` stays under the stack limit.
    struct Config {
        address module;
        bytes32 orderId;
        uint256 buyAmount;
        bytes32 appData;
        uint256 solverPk;
        address settlement;
        address router;
        uint24 poolFee;
    }

    function run() external {
        Config memory cfg = _readConfig();

        DataTypes.CowOrderMetadata memory meta = ICowSwapModule(cfg.module).getOrder(cfg.orderId);
        require(meta.paymentRails != address(0), "E2E: unknown order");

        (address[] memory tokens, uint256 sellIndex, uint256 buyIndex) = _sortedTokens(meta.sellToken, meta.buyToken);

        vm.startBroadcast(cfg.solverPk);
        IGPv2SettlementSettle(cfg.settlement)
            .settle(
                tokens,
                _clearingPrices(cfg, meta, sellIndex, buyIndex),
                _trades(cfg, meta, sellIndex, buyIndex),
                _interactions(cfg, meta)
            );
        vm.stopBroadcast();

        uint256 filled =
            IGPv2SettlementSettle(cfg.settlement).filledAmount(abi.encodePacked(cfg.orderId, cfg.module, meta.validTo));

        console2.log("=============================================================");
        console2.log("  CowSwapSettleE2E - Complete");
        console2.log("=============================================================");
        console2.log("orderId filled amount:", filled);
        console2.log("order sellAmount:     ", meta.sellAmount);
        console2.log("=============================================================");
    }

    function _readConfig() private view returns (Config memory cfg) {
        cfg.module = vm.envAddress("E2E_COW_MODULE");
        cfg.orderId = vm.envBytes32("E2E_ORDER_ID");
        cfg.buyAmount = vm.envUint("E2E_BUY_AMOUNT");
        cfg.appData = vm.envBytes32("E2E_APP_DATA");
        cfg.solverPk = vm.envUint("E2E_SOLVER_PK");
        cfg.settlement = vm.envAddress("E2E_SETTLEMENT");
        cfg.router = vm.envAddress("E2E_ROUTER");
        cfg.poolFee = uint24(vm.envUint("E2E_POOL_FEE"));
    }

    /// @dev Uniform clearing prices are quoted per token, so a sell order executes at
    ///      `sellAmount * price[sell] / price[buy]`. Pricing the pair at (buyAmount * 1001,
    ///      sellAmount * 1000) fills the order 0.1% above its limit price — enough to clear GPv2's
    ///      limit check with room for rounding, leaving the rest as solver surplus.
    function _clearingPrices(
        Config memory cfg,
        DataTypes.CowOrderMetadata memory meta,
        uint256 sellIndex,
        uint256 buyIndex
    )
        private
        pure
        returns (uint256[] memory clearingPrices)
    {
        clearingPrices = new uint256[](2);
        clearingPrices[sellIndex] = cfg.buyAmount * 1001;
        clearingPrices[buyIndex] = meta.sellAmount * 1000;
    }

    function _trades(
        Config memory cfg,
        DataTypes.CowOrderMetadata memory meta,
        uint256 sellIndex,
        uint256 buyIndex
    )
        private
        pure
        returns (GPv2TradeData[] memory trades)
    {
        trades = new GPv2TradeData[](1);
        trades[0] = GPv2TradeData({
            sellTokenIndex: sellIndex,
            buyTokenIndex: buyIndex,
            receiver: meta.paymentRails,
            sellAmount: meta.sellAmount,
            buyAmount: cfg.buyAmount,
            validTo: meta.validTo,
            appData: cfg.appData,
            feeAmount: 0,
            flags: FLAGS_SELL_FILL_OR_KILL_EIP1271,
            executedAmount: meta.sellAmount,
            // EIP-1271 signature: 20-byte verifier address ++ signature payload. The module's
            // isValidSignature expects the 32-byte order digest as its payload.
            signature: abi.encodePacked(cfg.module, cfg.orderId)
        });
    }

    /// @dev Solver route: the settlement contract receives the sellToken from the module via the
    ///      vault relayer, then swaps it for the buyToken on a real Uniswap V3 pool so it can pay
    ///      the trade out. Surplus above buyAmount stays with the settlement, as it does on mainnet.
    function _interactions(
        Config memory cfg,
        DataTypes.CowOrderMetadata memory meta
    )
        private
        view
        returns (GPv2InteractionData[][3] memory interactions)
    {
        interactions[0] = new GPv2InteractionData[](0);
        interactions[2] = new GPv2InteractionData[](0);
        interactions[1] = new GPv2InteractionData[](2);
        interactions[1][0] = GPv2InteractionData({
            target: meta.sellToken, value: 0, callData: abi.encodeCall(IERC20.approve, (cfg.router, meta.sellAmount))
        });
        // SwapRouter02 has no `deadline` param; it is enforced by the multicall wrapper.
        bytes[] memory swapBatch = new bytes[](1);
        swapBatch[0] = abi.encodeCall(ISwapRouter.exactInputSingle, (_swapParams(cfg, meta)));
        interactions[1][1] = GPv2InteractionData({
            target: cfg.router,
            value: 0,
            callData: abi.encodeCall(ISwapRouter.multicall, (block.timestamp + 600, swapBatch))
        });
    }

    function _swapParams(
        Config memory cfg,
        DataTypes.CowOrderMetadata memory meta
    )
        private
        pure
        returns (ISwapRouter.ExactInputSingleParams memory)
    {
        return ISwapRouter.ExactInputSingleParams({
            tokenIn: meta.sellToken,
            tokenOut: meta.buyToken,
            fee: cfg.poolFee,
            recipient: cfg.settlement,
            amountIn: meta.sellAmount,
            amountOutMinimum: cfg.buyAmount,
            sqrtPriceLimitX96: 0
        });
    }

    /// @dev GPv2 indexes tokens positionally; the order within `tokens` is free, so sort by address
    ///      to keep the array canonical and the indices unambiguous.
    function _sortedTokens(
        address sellToken,
        address buyToken
    )
        private
        pure
        returns (address[] memory tokens, uint256 sellIndex, uint256 buyIndex)
    {
        tokens = new address[](2);
        if (sellToken < buyToken) {
            tokens[0] = sellToken;
            tokens[1] = buyToken;
            (sellIndex, buyIndex) = (0, 1);
        } else {
            tokens[0] = buyToken;
            tokens[1] = sellToken;
            (sellIndex, buyIndex) = (1, 0);
        }
    }
}
