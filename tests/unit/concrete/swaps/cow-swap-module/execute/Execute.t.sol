// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { CowSwapModule } from "../../../../../../src/modules/swaps/CowSwapModule.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { MockChainlinkAggregator } from "../../../../../shared/mocks/MockChainlinkAggregator.sol";
import { MockPaymentRails } from "../../../../../shared/mocks/MockPaymentRails.sol";
import { FailingTransferERC20 } from "../../../../../shared/mocks/FailingTransferERC20.sol";
import { RevertingTransferERC20 } from "../../../../../shared/mocks/RevertingTransferERC20.sol";
import { ReentrantExecuteSellToken } from "../../../../../shared/mocks/ReentrantExecuteSellToken.sol";
import {
    ReentrantCancelDuringExecuteSellToken
} from "../../../../../shared/mocks/ReentrantCancelDuringExecuteSellToken.sol";

/// @notice Unit tests for CowSwapModule.execute()
/// @dev Tree: tests/unit/concrete/cow-swap-module/execute/execute.tree
contract CowSwapModule_Execute_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when caller is not authorized payment rails
    // -----------------------------------------------------------------------

    function test_WhenCallerIsNotAuthorizedPaymentRails_ReturnsFailedResult() external {
        sellToken.mint(attacker, DEFAULT_SELL_AMOUNT);

        vm.startPrank(attacker);
        sellToken.approve(address(module), DEFAULT_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result =
            module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        vm.stopPrank();

        assertFalse(result.success);
        assertEq(result.failureReason, "Caller is not authorized PaymentRails");
    }

    function test_WhenCallerIsNotAuthorizedPaymentRails_DoesNotTransferTokens() external {
        sellToken.mint(attacker, DEFAULT_SELL_AMOUNT);

        vm.startPrank(attacker);
        sellToken.approve(address(module), DEFAULT_SELL_AMOUNT);
        module.execute(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        vm.stopPrank();

        assertEq(sellToken.balanceOf(address(module)), 0);
        assertEq(sellToken.balanceOf(attacker), DEFAULT_SELL_AMOUNT);
    }

    // -----------------------------------------------------------------------
    // when amount is zero
    // -----------------------------------------------------------------------

    function test_WhenAmountIsZero_ReturnsFailedResult() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), 0, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero sell amount");
    }

    function test_WhenAmountIsZero_DoesNotCreateOrder() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), 0, _buildDefaultParams());
        assertEq(result.data.length, 0);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    // -----------------------------------------------------------------------
    // when params are malformed
    // -----------------------------------------------------------------------

    function test_WhenParamsAreMalformed_ReturnsFailedResult() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid params encoding");
    }

    function test_WhenParamsAreMalformed_DoesNotCreateOrder() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertEq(result.data.length, 0);
    }

    function test_WhenParamsAreMalformed_DoesNotTransferTokens() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        uint256 moduleBalanceBefore = sellToken.balanceOf(address(module));
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertEq(sellToken.balanceOf(address(module)), moduleBalanceBefore);
    }

    // -----------------------------------------------------------------------
    // when target token is zero address
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(0),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero target token");
    }

    function test_WhenTargetTokenIsZero_ReturnsZeroAmountOut() external {
        bytes memory params = _buildParams(
            address(0),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(result.amountOut, 0);
    }

    // -----------------------------------------------------------------------
    // when target token equals sell token
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenEqualsSellToken_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(sellToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Same sell and buy token");
    }

    // -----------------------------------------------------------------------
    // when slippage bps is invalid (zero)
    // -----------------------------------------------------------------------

    function test_WhenZeroSlippageBps_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(buyToken),
            0,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid slippage bps");
    }

    // -----------------------------------------------------------------------
    // when slippage bps is invalid (zero or > 10000)
    // -----------------------------------------------------------------------

    function test_WhenSlippageBpsExceeds10000_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(buyToken),
            10_001,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Invalid slippage bps");
    }

    // -----------------------------------------------------------------------
    // when sell token price feed is missing
    // -----------------------------------------------------------------------

    function test_WhenSellTokenPriceFeedIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(0),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Missing sell token price feed");
    }

    // -----------------------------------------------------------------------
    // when buy token price feed is missing
    // -----------------------------------------------------------------------

    function test_WhenBuyTokenPriceFeedIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(0),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Missing buy token price feed");
    }

    // -----------------------------------------------------------------------
    // when validity duration is zero
    // -----------------------------------------------------------------------

    function test_WhenMaxStalenessIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            0,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero max staleness");
    }

    function test_WhenValidityDurationIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            0,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Zero validity duration");
    }

    // -----------------------------------------------------------------------
    // when validity duration overflows uint32
    // -----------------------------------------------------------------------

    function test_WhenValidityDurationOverflows_ReturnsFailedResult() external {
        uint32 overflowDuration = type(uint32).max;
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            overflowDuration,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Validity duration overflow");
    }

    function test_WhenValidityDurationOverflows_DoesNotLockTokens() external {
        uint32 overflowDuration = type(uint32).max;
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            overflowDuration,
            DEFAULT_APP_DATA
        );
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(sellToken.balanceOf(address(module)), 0);
    }

    // -----------------------------------------------------------------------
    // when oracle price is unavailable
    // -----------------------------------------------------------------------

    function test_WhenSellOracleReverts_ReturnsFailedResult() external {
        sellFeed.setShouldRevert(true);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_WhenBuyOracleReverts_ReturnsFailedResult() external {
        buyFeed.setShouldRevert(true);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_WhenOraclePriceIsStale_ReturnsFailedResult() external {
        sellFeed.setUpdatedAt(block.timestamp - DEFAULT_MAX_STALENESS - 1);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_WhenOraclePriceIsNegative_ReturnsFailedResult() external {
        sellFeed.setAnswer(-1);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    function test_WhenOraclePriceIsZero_ReturnsFailedResult() external {
        sellFeed.setAnswer(0);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    // -----------------------------------------------------------------------
    // when oracle floor rounds to zero (amount too small for safe swap)
    // -----------------------------------------------------------------------

    function test_WhenOracleFloorRoundsToZero_ReturnsFailedResult() external {
        // Extreme price disparity: sellPrice=1e-8, buyPrice=1.0 → floor rounds to 0
        sellFeed.setAnswer(1);
        buyFeed.setAnswer(1e8);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), 1, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Amount too small for safe swap");
    }

    // -----------------------------------------------------------------------
    // when paymentRails has insufficient sell token balance
    // -----------------------------------------------------------------------

    function test_WhenPaymentRailsHasInsufficientBalance_ReturnsFailedResult() external {
        uint256 excessiveAmount = DEFAULT_SELL_AMOUNT * 11;
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), excessiveAmount, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Insufficient balance");
    }

    function test_WhenPaymentRailsHasInsufficientBalance_DoesNotTransferTokens() external {
        uint256 moduleBalanceBefore = sellToken.balanceOf(address(module));
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT * 11, _buildDefaultParams());
        assertEq(sellToken.balanceOf(address(module)), moduleBalanceBefore);
    }

    // -----------------------------------------------------------------------
    // when token transfer fails
    // -----------------------------------------------------------------------

    function test_WhenTokenTransferFails_ReturnsFailedResult() external {
        FailingTransferERC20 failToken = new FailingTransferERC20();
        failToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success);
        assertEq(result.failureReason, "Token transfer failed");
    }

    function test_WhenTokenTransferFails_DoesNotStoreMetadata() external {
        FailingTransferERC20 failToken = new FailingTransferERC20();
        failToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(result.data.length, 0);
    }

    /// @dev CEI rollback: delete _orders[orderId] when transfer fails, preventing stale collisions.
    function test_WhenTokenTransferFails_CleansUpOrderMetadata_CEIRollback() external {
        FailingTransferERC20 failToken = new FailingTransferERC20();
        failToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);

        // Same params must NOT collide — metadata was cleaned up
        DataTypes.ExecutionResult memory result2 =
            paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result2.success, "still fails (transfer always fails)");
        assertEq(result2.failureReason, "Token transfer failed", "failure reason is transfer, not collision");
    }

    // -----------------------------------------------------------------------
    // when all parameters are valid
    // -----------------------------------------------------------------------

    function test_WhenAllParamsValid_TransfersSellTokenFromPaymentRailsToModule() external {
        uint256 paymentRailsBalanceBefore = sellToken.balanceOf(address(paymentRails));
        _initiateDefaultOrder();
        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT);
        assertEq(sellToken.balanceOf(address(paymentRails)), paymentRailsBalanceBefore - DEFAULT_SELL_AMOUNT);
    }

    function test_WhenAllParamsValid_ApprovesVaultRelayerForMaxAmount() external {
        _initiateDefaultOrder();
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_WhenAllParamsValid_MaxApprovalSetOnlyOnce() external {
        _initiateDefaultOrder();
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        bytes memory params2 = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            keccak256("order-2")
        );
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_WhenAllParamsValid_StoresMetadataWithCancelledFalse() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertFalse(module.getOrder(orderId).cancelled);
    }

    function test_WhenAllParamsValid_StoresCorrectPaymentRailsAddress() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).paymentRails, address(paymentRails));
    }

    function test_WhenAllParamsValid_StoresCorrectSellToken() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).sellToken, address(sellToken));
    }

    function test_WhenAllParamsValid_StoresCorrectBuyToken() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).buyToken, address(buyToken));
    }

    function test_WhenAllParamsValid_StoresCorrectSellAmount() external {
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).sellAmount, DEFAULT_SELL_AMOUNT);
    }

    function test_WhenAllParamsValid_StoresCorrectValidTo() external {
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId = _initiateDefaultOrder();
        assertEq(module.getOrder(orderId).validTo, expectedValidTo);
    }

    function test_WhenAllParamsValid_EmitsOrderCreated() external {
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        vm.expectEmit(false, true, false, true, address(module));
        emit OrderCreated(
            bytes32(0),
            address(paymentRails),
            address(sellToken),
            address(buyToken),
            DEFAULT_SELL_AMOUNT,
            DEFAULT_MIN_BUY_AMOUNT,
            expectedValidTo,
            DEFAULT_APP_DATA
        );
        paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
    }

    function test_WhenAllParamsValid_ReturnsSuccessTrue() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertTrue(result.success);
    }

    function test_WhenAllParamsValid_ReturnsAmountOutZero() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertEq(result.amountOut, 0);
    }

    function test_WhenAllParamsValid_ReturnsOutputTokenAsBuyToken() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertEq(result.outputToken, address(buyToken));
    }

    function test_WhenAllParamsValid_ReturnsDataAsEncodedOrderId() external {
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        bytes32 orderId = abi.decode(result.data, (bytes32));
        assertNotEq(orderId, bytes32(0));
    }

    function test_WhenAllParamsValid_TwoOrdersProduceDifferentOrderIds() external {
        bytes32 id1 = _initiateDefaultOrder();
        vm.warp(block.timestamp + 1);
        bytes32 id2 = _initiateDefaultOrder();
        assertNotEq(id1, id2);
    }

    function testFuzz_WhenAllParamsValid_OrderIsStoredCorrectly(uint256 sellAmount, uint32 validity) external {
        sellAmount = bound(sellAmount, 1e6, DEFAULT_SELL_AMOUNT * 9);
        uint256 maxValidity = type(uint32).max - block.timestamp;
        validity = uint32(bound(uint256(validity), 1, maxValidity));

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            validity,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result = paymentRails.initiateSwap(address(sellToken), sellAmount, params);

        assertTrue(result.success);
        assertEq(result.amountOut, 0);

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.paymentRails, address(paymentRails));
        assertEq(meta.sellAmount, sellAmount);
        assertEq(meta.validTo, uint32(block.timestamp + uint256(validity)));
        assertFalse(meta.cancelled);
    }

    // -----------------------------------------------------------------------
    // order ID collision guard
    // -----------------------------------------------------------------------

    function test_Execute_TwiceSameBlock_SameParams_SecondCallRejectedWithCollision() external {
        bytes32 id1 = _initiateDefaultOrder();

        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success);
        assertEq(result.failureReason, "Order ID collision: use unique appData");

        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT);
        assertFalse(module.getOrder(id1).cancelled);
    }

    function test_Execute_TwiceSameBlock_DifferentAppData_ProducesDifferentOrderIds() external {
        bytes32 id1 = _initiateDefaultOrder();

        bytes memory params2 = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            keccak256("different-app-data")
        );
        DataTypes.ExecutionResult memory result2 =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2);

        assertTrue(result2.success);
        bytes32 id2 = abi.decode(result2.data, (bytes32));
        assertNotEq(id1, id2);
        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT * 2);
    }

    // -----------------------------------------------------------------------
    // Concurrent same-token orders: max approval coverage
    // -----------------------------------------------------------------------

    function test_ConcurrentSameToken_BothOrdersCoveredByMaxApproval() external {
        _initiateDefaultOrder();
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);

        bytes memory params2 = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            keccak256("order-2")
        );
        DataTypes.ExecutionResult memory r2 =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2);
        assertTrue(r2.success);
        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_ConcurrentSameToken_CancelOrder1_Order2ApprovalUnaffected() external {
        bytes32 id1 = _initiateDefaultOrder();
        bytes memory params2 = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            keccak256("order-2")
        );
        bytes32 id2 =
            abi.decode(paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params2).data, (bytes32));

        module.cancelOrder(id1);

        assertEq(sellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
        assertFalse(module.getOrder(id2).cancelled);
    }

    // -----------------------------------------------------------------------
    // no-return sellToken (e.g. USDT)
    // -----------------------------------------------------------------------

    /// @dev Non-standard ERC20 tokens returning no data from transferFrom must succeed.
    function test_Execute_NoReturnSellToken_SucceedsAndStoresOrder() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );

        uint256 paymentRailsBefore = noReturnSellToken.balanceOf(address(paymentRails));

        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(noReturnSellToken), DEFAULT_SELL_AMOUNT, params);

        assertTrue(result.success, "should succeed");
        assertEq(result.amountOut, 0, "async order: amountOut=0");

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.paymentRails, address(paymentRails), "paymentRails stored");
        assertEq(meta.sellToken, address(noReturnSellToken), "sellToken stored");
        assertEq(meta.sellAmount, DEFAULT_SELL_AMOUNT, "sellAmount stored");
        assertFalse(meta.cancelled, "not cancelled");

        assertEq(noReturnSellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT, "module received tokens");
        assertEq(
            noReturnSellToken.balanceOf(address(paymentRails)),
            paymentRailsBefore - DEFAULT_SELL_AMOUNT,
            "paymentRails debited"
        );
    }

    // -----------------------------------------------------------------------
    // L2 sequencer uptime feed (Certora L-02)
    // -----------------------------------------------------------------------

    /// @dev Certora L-02: oracle reads must fail when sequencer is down.
    function test_Execute_WhenSequencerDown_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setAnswer(1); // 1 = sequencer down
        MockPaymentRails l2Rails = new MockPaymentRails();
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(l2Rails), address(seqFeed), 3600);
        l2Rails.setModule(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success, "should fail when sequencer is down");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev Certora L-02: oracle reads must fail during grace period.
    function test_Execute_WhenSequencerInGracePeriod_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp - 1800); // up 30 min ago, grace = 1 hour
        MockPaymentRails l2Rails = new MockPaymentRails();
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(l2Rails), address(seqFeed), 3600);
        l2Rails.setModule(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success, "should fail during grace period");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev Certora L-02: oracle reads succeed after grace period expires.
    function test_Execute_WhenSequencerUpPastGracePeriod_Succeeds() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp - 7200); // up 2 hours ago, grace = 1 hour
        MockPaymentRails l2Rails = new MockPaymentRails();
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(l2Rails), address(seqFeed), 3600);
        l2Rails.setModule(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertTrue(result.success, "should succeed after grace period");
    }

    /// @dev Certora L-02: sequencer feed revert must fail gracefully.
    function test_Execute_WhenSequencerFeedReverts_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setShouldRevert(true);
        MockPaymentRails l2Rails = new MockPaymentRails();
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(l2Rails), address(seqFeed), 3600);
        l2Rails.setModule(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success, "should fail when sequencer feed reverts");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev The grace period must be measured from `startedAt` (tuple position 3, when the sequencer
    /// last changed status), not from `updatedAt` (position 4, the last routine feed write). On
    /// Base's live feed these run weeks apart: sampled across 31 days, `startedAt` stayed pinned at
    /// 1_782_491_507 while `updatedAt` advanced on every write. Reading position 4 would block every
    /// order for a full grace period after each write, with no outage.
    function test_Execute_WhenStartedAtAndUpdatedAtDiverge_MeasuresFromStartedAt() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp - 30 days); // sequencer up for 30 days
        seqFeed.setUpdatedAt(block.timestamp - 60); // feed written 60s ago, grace = 1 hour
        MockPaymentRails l2Rails = new MockPaymentRails();
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(l2Rails), address(seqFeed), 3600);
        l2Rails.setModule(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertTrue(result.success, "grace period must key off startedAt, not updatedAt");
    }

    /// @dev An uninitialized round reports startedAt == 0, making `block.timestamp - startedAt` span
    /// the whole unix epoch, which clears any grace period.
    function test_Execute_WhenSequencerRoundUninitialized_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(0);
        MockPaymentRails l2Rails = new MockPaymentRails();
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(l2Rails), address(seqFeed), 3600);
        l2Rails.setModule(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success, "uninitialized round must not clear the grace period");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev A feed ahead of block.timestamp would underflow. The subtraction sits in the try's
    /// success body, so the panic escapes the adjacent catch instead of failing closed.
    function test_Execute_WhenSequencerReportsFutureTimestamp_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp + 1 hours);
        MockPaymentRails l2Rails = new MockPaymentRails();
        CowSwapModule l2Module =
            new CowSwapModule(address(cowSettlement), address(this), address(l2Rails), address(seqFeed), 3600);
        l2Rails.setModule(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(result.success, "future timestamp must fail closed, not panic");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    // -----------------------------------------------------------------------
    // fee-on-transfer sellToken
    // -----------------------------------------------------------------------

    function test_Execute_FeeOnTransferSellToken_ModuleReceivesLessThanAmount() external {
        uint256 expectedReceived = DEFAULT_SELL_AMOUNT - (DEFAULT_SELL_AMOUNT * 100 / 10_000);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(fotSellToken), DEFAULT_SELL_AMOUNT, params);

        assertTrue(result.success);

        uint256 moduleBalance = fotSellToken.balanceOf(address(module));
        assertEq(moduleBalance, expectedReceived);

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.sellAmount, DEFAULT_SELL_AMOUNT, "Metadata records full amount (mismatch)");
        assertEq(fotSellToken.allowance(address(module), module.vaultRelayer()), type(uint256).max);
    }

    function test_Execute_FeeOnTransferSellToken_CowSwapCannotPullFullSellAmount() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(fotSellToken), DEFAULT_SELL_AMOUNT, params);

        bytes32 orderId = abi.decode(result.data, (bytes32));
        uint256 sellAmount = module.getOrder(orderId).sellAmount;
        uint256 moduleBalance = fotSellToken.balanceOf(address(module));

        assertLt(moduleBalance, sellAmount, "module balance < sellAmount");

        vm.prank(module.vaultRelayer());
        vm.expectRevert();
        fotSellToken.transferFrom(address(module), address(cowSettlement), sellAmount);
    }

    // -----------------------------------------------------------------------
    // reentrancy guard: ERC-777-style reentrant sell token
    // -----------------------------------------------------------------------

    /// @dev ERC-777-style hook re-enters execute() during transferFrom; ReentrancyGuard blocks it.
    function test_Execute_ReentrantSellToken_InnerCallBlockedByReentrancyGuard() external {
        ReentrantExecuteSellToken reentrantToken = new ReentrantExecuteSellToken(address(module));
        reentrantToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 5);
        // Token contract itself is msg.sender for the inner reentrant call
        reentrantToken.mint(address(reentrantToken), DEFAULT_SELL_AMOUNT * 5);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );

        reentrantToken.setReentryConfig(DEFAULT_SELL_AMOUNT, params);

        vm.prank(address(paymentRails));
        reentrantToken.approve(address(module), DEFAULT_SELL_AMOUNT);

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(reentrantToken), DEFAULT_SELL_AMOUNT, params);

        assertTrue(result.success, "outer execute must succeed");
        // Confirm the hook fired and was blocked (not silently skipped)
        assertTrue(reentrantToken.reentryAttempted(), "hook must have fired");
        assertTrue(reentrantToken.reentrancyBlocked(), "reentrant execute must be blocked");

        bytes32 orderId = abi.decode(result.data, (bytes32));
        assertEq(module.getOrder(orderId).sellAmount, DEFAULT_SELL_AMOUNT, "exactly 1x sell amount recorded");
        assertEq(reentrantToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT, "module holds exactly 1x");
    }

    /// @dev After blocked reentry: no phantom orders, no stuck tokens, cancel works normally.
    function test_Execute_ReentrantSellToken_ModuleStateCleanAfterBlockedReentry() external {
        ReentrantExecuteSellToken reentrantToken = new ReentrantExecuteSellToken(address(module));
        reentrantToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 5);
        reentrantToken.mint(address(reentrantToken), DEFAULT_SELL_AMOUNT * 5);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );

        reentrantToken.setReentryConfig(DEFAULT_SELL_AMOUNT, params);

        vm.prank(address(paymentRails));
        reentrantToken.approve(address(module), DEFAULT_SELL_AMOUNT);

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(reentrantToken), DEFAULT_SELL_AMOUNT, params);

        bytes32 orderId = abi.decode(result.data, (bytes32));
        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.paymentRails, address(paymentRails));
        assertFalse(meta.cancelled);

        module.cancelOrder(orderId);
        assertTrue(module.getOrder(orderId).cancelled);
        assertEq(reentrantToken.balanceOf(address(module)), 0, "all tokens returned after cancel");
        assertEq(reentrantToken.balanceOf(address(paymentRails)), DEFAULT_SELL_AMOUNT * 5, "paymentRails made whole");
    }

    // -----------------------------------------------------------------------
    // cross-function reentrancy: execute → cancelOrder
    // -----------------------------------------------------------------------

    /// @dev Hook-enabled token attempts cancelOrder() during execute()'s transferFrom; shared lock blocks it.
    function test_Execute_CrossFunctionReentrancy_CancelOrderBlockedDuringExecute() external {
        bytes32 existingOrderId = _initiateDefaultOrder();
        assertFalse(module.getOrder(existingOrderId).cancelled, "pre-existing order is pending");

        ReentrantCancelDuringExecuteSellToken crossToken = new ReentrantCancelDuringExecuteSellToken(address(module));
        crossToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT);
        // During transferFrom, token will try cancelOrder(existingOrderId)
        crossToken.setReentryConfig(existingOrderId);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            keccak256("cross-func-test")
        );

        vm.prank(address(paymentRails));
        crossToken.approve(address(module), DEFAULT_SELL_AMOUNT);

        vm.prank(address(paymentRails));
        DataTypes.ExecutionResult memory result = module.execute(address(crossToken), DEFAULT_SELL_AMOUNT, params);

        assertTrue(result.success, "outer execute must succeed");
        assertTrue(crossToken.reentryAttempted(), "hook must have fired");
        assertTrue(crossToken.cancelBlocked(), "cross-function cancelOrder must be blocked by shared nonReentrant");
        assertFalse(module.getOrder(existingOrderId).cancelled, "pre-existing order must remain pending");
        assertEq(sellToken.balanceOf(address(module)), DEFAULT_SELL_AMOUNT, "pre-existing order tokens intact");
    }

    // -----------------------------------------------------------------------
    // CEI cleanup: reverting transferFrom (not just false-return)
    // -----------------------------------------------------------------------

    /// @dev Reverts (not false-return) also trigger CEI cleanup via trySafeTransferFrom.
    function test_WhenTokenTransferReverts_CleansUpOrderMetadata() external {
        RevertingTransferERC20 revertToken = new RevertingTransferERC20();
        revertToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );

        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(revertToken), DEFAULT_SELL_AMOUNT, params);

        assertFalse(result.success, "must fail");
        assertEq(result.failureReason, "Token transfer failed");

        // Retry: must fail with "transfer failed", NOT "collision"
        DataTypes.ExecutionResult memory result2 =
            paymentRails.initiateSwap(address(revertToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result2.success);
        assertEq(result2.failureReason, "Token transfer failed", "no stale collision after revert cleanup");
    }

    // -----------------------------------------------------------------------
    // CEI cleanup: explicit struct zeroing and isValidSignature verification
    // -----------------------------------------------------------------------

    /// @dev Verifies `delete _orders[orderId]` zeros ALL struct fields after failed transfer.
    function test_WhenTokenTransferFails_AllStructFieldsZeroed() external {
        FailingTransferERC20 failToken = new FailingTransferERC20();
        failToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);

        // msg.sender inside module.execute() is address(paymentRails) via MockPaymentRails
        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId = _computeTestOrderDigest(
            address(failToken),
            address(buyToken),
            address(paymentRails),
            DEFAULT_SELL_AMOUNT,
            DEFAULT_MIN_BUY_AMOUNT,
            expectedValidTo,
            DEFAULT_APP_DATA
        );

        DataTypes.CowOrderMetadata memory meta = module.getOrder(orderId);
        assertEq(meta.paymentRails, address(0), "paymentRails must be zero after cleanup");
        assertEq(meta.sellToken, address(0), "sellToken must be zero after cleanup");
        assertEq(meta.buyToken, address(0), "buyToken must be zero after cleanup");
        assertEq(meta.sellAmount, 0, "sellAmount must be zero after cleanup");
        assertEq(meta.validTo, 0, "validTo must be zero after cleanup");
        assertFalse(meta.cancelled, "cancelled must be false after cleanup");
    }

    function test_WhenTokenTransferFails_IsValidSignatureReturnsFailureForCleanedUpOrderId() external {
        FailingTransferERC20 failToken = new FailingTransferERC20();
        failToken.mint(address(paymentRails), DEFAULT_SELL_AMOUNT * 10);

        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        paymentRails.initiateSwap(address(failToken), DEFAULT_SELL_AMOUNT, params);

        uint32 expectedValidTo = uint32(block.timestamp + DEFAULT_VALIDITY);
        bytes32 orderId = _computeTestOrderDigest(
            address(failToken),
            address(buyToken),
            address(paymentRails),
            DEFAULT_SELL_AMOUNT,
            DEFAULT_MIN_BUY_AMOUNT,
            expectedValidTo,
            DEFAULT_APP_DATA
        );

        assertEq(
            module.isValidSignature(orderId, abi.encode(orderId)),
            EIP1271_FAILURE,
            "isValidSignature must return FAILURE for cleaned-up orderId"
        );
    }
}
