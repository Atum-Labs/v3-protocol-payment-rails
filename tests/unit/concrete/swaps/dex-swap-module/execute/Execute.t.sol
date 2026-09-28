// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DexSwapModule } from "../../../../../../src/modules/swaps/DexSwapModule.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { ReentrantRouter } from "../../../../../shared/mocks/ReentrantRouter.sol";
import { MockDexSwapPaymentRails } from "../../../../../shared/mocks/MockDexSwapPaymentRails.sol";
import { MockChainlinkAggregator } from "../../../../../shared/mocks/MockChainlinkAggregator.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Unit tests for DexSwapModule.execute()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/execute/execute.tree
contract DexSwapModule_Execute_Test is DexSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                        VALIDATION FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsTooShort_ReturnsFailedResult() external {
        bytes memory shortParams = hex"00";
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, shortParams);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Invalid params encoding", "failureReason");
    }

    function test_WhenParamsTooShort_DoesNotTransferTokens() external {
        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00");
        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "no tokens moved");
    }

    function test_WhenParamsEmpty_ReturnsFailedResult() external {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, "");
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Invalid params encoding", "failureReason");
    }

    function test_WhenAmountIsZero_ReturnsFailedResult() external {
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(address(sellToken), 0, _defaultParams());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero sell amount", "failureReason");
    }

    function test_WhenTargetTokenIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParamsCustom(
            address(0),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero target token", "failureReason");
    }

    function test_WhenTargetTokenEqualsSellToken_ReturnsFailedResult() external {
        bytes memory params = _buildParams(address(sellToken));
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Same input and output token", "failureReason");
    }

    function test_WhenSlippageBpsIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            0,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Invalid slippage bps", "failureReason");
    }

    function test_WhenSlippageBpsExceeds10000_ReturnsFailedResult() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            10_001,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Invalid slippage bps", "failureReason");
    }

    function test_WhenSellTokenPriceFeedIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(0),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Missing sell token price feed", "failureReason");
    }

    function test_WhenBuyTokenPriceFeedIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(0),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Missing buy token price feed", "failureReason");
    }

    function test_WhenMaxStalenessIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            0,
            DEFAULT_SWAP_DEADLINE
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero max staleness", "failureReason");
    }

    function test_WhenSwapDeadlineSecondsIsZero_ReturnsFailedResult() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            0
        );
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Zero swap deadline", "failureReason");
    }

    function test_WhenCallerHasInsufficientBalance_ReturnsFailedResult() external {
        uint256 tooMuch = DEFAULT_SELL_AMOUNT * 101;
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), tooMuch, _defaultParams());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Insufficient balance", "failureReason");
    }

    function test_WhenOracleReturnsNegativePrice_ReturnsFailedResult() external {
        sellFeed.setAnswer(-1);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Oracle price unavailable", "failureReason");
    }

    function test_WhenOracleIsStale_ReturnsFailedResult() external {
        sellFeed.setUpdatedAt(block.timestamp - DEFAULT_MAX_STALENESS - 1);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Oracle price unavailable", "failureReason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ROUTER CALL FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenRouterReverts_ReturnsFailedResult() external {
        router.setShouldRevert(true);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Router call failed", "failureReason");
    }

    function test_WhenRouterReverts_ReturnsSellTokensToCaller() external {
        router.setShouldRevert(true);
        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "all tokens returned");
    }

    function test_WhenRouterReverts_ModuleHasZeroBalance() external {
        router.setShouldRevert(true);
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(sellToken.balanceOf(address(module)), 0, "module retains nothing");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SLIPPAGE ENFORCEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenOutputBelowOracleFloor_RevertsWithInsufficientOutput() external {
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);
        uint256 tinyBuyAmount = oracleFloor - 1;
        router.setOutputAmount(tinyBuyAmount);

        vm.expectRevert(
            abi.encodeWithSelector(Errors.DexSwapModule_InsufficientOutput.selector, tinyBuyAmount, oracleFloor)
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
    }

    function test_WhenOutputBelowOracleFloor_SellTokensNotTransferred() external {
        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);
        router.setOutputAmount(oracleFloor - 1);
        buyToken.mint(address(router), oracleFloor);

        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        try paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams()) { } catch { }
        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "atomic rollback");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        ADVERSARIAL ROUTER TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenRouterSendsNothing_RevertsAtomically() external {
        router.setShouldSendNothing(true);

        uint256 paymentRailsBefore = sellToken.balanceOf(address(paymentRails));

        vm.expectRevert();
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertEq(sellToken.balanceOf(address(paymentRails)), paymentRailsBefore, "tokens safe after revert");
    }

    function test_WhenRouterProducesZeroOutput_RevertsWithInsufficientOutput() external {
        router.setOutputAmount(0);
        router.setShouldSendNothing(true);

        uint256 oracleFloor = _computeOracleFloor(DEFAULT_SELL_AMOUNT);

        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_InsufficientOutput.selector, 0, oracleFloor));
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
    }

    /*//////////////////////////////////////////////////////////////////////////
                    PARTIAL FILL TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_PartialFill_ReturnsUnconsumedSellTokens() external {
        uint256 halfSell = DEFAULT_SELL_AMOUNT / 2;
        router.setPullAmountOverride(halfSell);

        uint256 paymentRailsBefore = sellToken.balanceOf(address(paymentRails));
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertTrue(result.success, "partial fill should succeed");
        uint256 paymentRailsAfter = sellToken.balanceOf(address(paymentRails));
        assertEq(paymentRailsBefore - paymentRailsAfter, halfSell, "only half consumed");
        assertEq(sellToken.balanceOf(address(module)), 0, "module retains nothing");
    }

    /*//////////////////////////////////////////////////////////////////////////
                        SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValid_TransfersTokensCorrectly() external whenAllValidationsPass {
        uint256 paymentRailsSellBefore = sellToken.balanceOf(address(paymentRails));
        uint256 paymentRailsBuyBefore = buyToken.balanceOf(address(paymentRails));

        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertEq(
            sellToken.balanceOf(address(paymentRails)),
            paymentRailsSellBefore - DEFAULT_SELL_AMOUNT,
            "sell tokens debited"
        );
        assertEq(
            buyToken.balanceOf(address(paymentRails)), paymentRailsBuyBefore + DEFAULT_BUY_AMOUNT, "buy tokens credited"
        );
    }

    function test_WhenAllValid_ReturnsSuccessTrue() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertTrue(result.success, "success");
    }

    function test_WhenAllValid_ReturnsCorrectAmountOut() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(result.amountOut, DEFAULT_BUY_AMOUNT, "amountOut");
    }

    function test_WhenAllValid_ReturnsOutputTokenAsTargetToken() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(result.outputToken, address(buyToken), "outputToken");
    }

    function test_WhenAllValid_ReturnsEmptyData() external whenAllValidationsPass {
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(result.data.length, 0, "data should be empty");
    }

    function test_WhenAllValid_EmitsSwapExecuted() external whenAllValidationsPass {
        vm.expectEmit(true, true, false, true, address(module));
        emit SwapExecuted(
            address(paymentRails), address(sellToken), address(buyToken), DEFAULT_SELL_AMOUNT, DEFAULT_BUY_AMOUNT
        );
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
    }

    function test_WhenAllValid_ModuleRetainsZeroSellToken() external whenAllValidationsPass {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(sellToken.balanceOf(address(module)), 0, "no residual sell token");
    }

    function test_WhenAllValid_ModuleRetainsZeroBuyToken() external whenAllValidationsPass {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(buyToken.balanceOf(address(module)), 0, "no residual buy token");
    }

    function test_WhenAllValid_RouterApprovalRevokedAfterSwap() external whenAllValidationsPass {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertEq(sellToken.allowance(address(module), address(router)), 0, "approval revoked");
    }

    function test_ConsecutiveSwaps_NoResidualState() external {
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertEq(sellToken.balanceOf(address(module)), 0, "zero after swap 1");
        assertEq(buyToken.balanceOf(address(module)), 0, "zero after swap 1");

        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT);
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertEq(sellToken.balanceOf(address(module)), 0, "zero after swap 2");
        assertEq(buyToken.balanceOf(address(module)), 0, "zero after swap 2");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    REENTRANCY GUARD TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenRouterReenters_RevertsWithReentrancyGuardReentrantCall() external {
        (ReentrantRouter reentrantRouter,, MockDexSwapPaymentRails victim,) = _setupReentrancyScenario();

        reentrantRouter.setReentrantCall(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertTrue(reentrantRouter.reentrancyAttempted(), "router attempted reentrancy");
        assertFalse(reentrantRouter.reentrancySucceeded(), "reentrant call was blocked");

        bytes memory expectedRevert = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(reentrantRouter.revertReasonBytes(), expectedRevert, "reverted with ReentrancyGuardReentrantCall");
    }

    function test_WhenRouterReenters_OriginalSwapCompletesSuccessfully() external {
        (ReentrantRouter reentrantRouter, DexSwapModule reentrantModule, MockDexSwapPaymentRails victim,) =
            _setupReentrancyScenario();

        reentrantRouter.setReentrantCall(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        uint256 victimSellBefore = sellToken.balanceOf(address(victim));
        uint256 victimBuyBefore = buyToken.balanceOf(address(victim));

        DataTypes.ExecutionResult memory result =
            victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertTrue(result.success, "original swap succeeds");
        assertEq(result.amountOut, DEFAULT_BUY_AMOUNT, "correct output amount");
        assertEq(sellToken.balanceOf(address(victim)), victimSellBefore - DEFAULT_SELL_AMOUNT, "sell tokens debited");
        assertEq(buyToken.balanceOf(address(victim)), victimBuyBefore + DEFAULT_BUY_AMOUNT, "buy tokens credited");
        assertEq(sellToken.balanceOf(address(reentrantModule)), 0, "module retains nothing");
    }

    function test_WhenRouterReenters_AttackerBalancesUnchanged() external {
        (ReentrantRouter reentrantRouter, DexSwapModule reentrantModule,, MockDexSwapPaymentRails attackerRails) =
            _setupReentrancyScenario();

        sellToken.mint(address(attackerRails), DEFAULT_SELL_AMOUNT);

        reentrantRouter.setReentrantCall(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        uint256 attackerSellBefore = sellToken.balanceOf(address(attackerRails));
        uint256 attackerBuyBefore = buyToken.balanceOf(address(attackerRails));

        MockDexSwapPaymentRails victim = new MockDexSwapPaymentRails(address(reentrantModule));
        sellToken.mint(address(victim), DEFAULT_SELL_AMOUNT);
        buyToken.mint(address(reentrantRouter), DEFAULT_BUY_AMOUNT);

        victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertEq(sellToken.balanceOf(address(attackerRails)), attackerSellBefore, "attacker sell tokens unchanged");
        assertEq(buyToken.balanceOf(address(attackerRails)), attackerBuyBefore, "attacker buy tokens unchanged");
    }

    function test_WhenRouterReenters_ModuleRemainsUsableAfterBlockedReentrancy() external {
        (ReentrantRouter reentrantRouter,, MockDexSwapPaymentRails victim,) = _setupReentrancyScenario();

        reentrantRouter.setReentrantCall(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        victim.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());

        assertTrue(result.success, "module functional after blocked reentrancy");
        assertEq(result.amountOut, DEFAULT_BUY_AMOUNT, "subsequent swap correct output");
        assertEq(sellToken.balanceOf(address(module)), 0, "no residual after subsequent swap");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    REENTRANCY HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Creates a DexSwapModule whose immutable router IS the ReentrantRouter.
    /// Uses vm.computeCreateAddress to resolve the chicken-and-egg dependency:
    /// ReentrantRouter needs the module address, module needs the router address.
    function _setupReentrancyScenario()
        private
        returns (
            ReentrantRouter reentrantRouter,
            DexSwapModule reentrantModule,
            MockDexSwapPaymentRails victim,
            MockDexSwapPaymentRails attackerRails
        )
    {
        uint256 nonce = vm.getNonce(address(this));
        address predictedModule = vm.computeCreateAddress(address(this), nonce + 1);

        reentrantRouter = new ReentrantRouter(predictedModule);
        reentrantModule = new DexSwapModule(address(reentrantRouter), address(0), 0);

        reentrantRouter.setOutputAmount(DEFAULT_BUY_AMOUNT);

        victim = new MockDexSwapPaymentRails(address(reentrantModule));
        sellToken.mint(address(victim), DEFAULT_SELL_AMOUNT);
        buyToken.mint(address(reentrantRouter), DEFAULT_BUY_AMOUNT);

        attackerRails = new MockDexSwapPaymentRails(address(reentrantModule));
    }

    /*//////////////////////////////////////////////////////////////////////////
                    L2 SEQUENCER UPTIME FEED TESTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Certora L-02: oracle reads must fail when sequencer is down.
    function test_WhenSequencerDown_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setAnswer(1); // 1 = sequencer down
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        MockDexSwapPaymentRails l2Rails = new MockDexSwapPaymentRails(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "should fail when sequencer is down");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev Certora L-02: oracle reads must fail during grace period.
    function test_WhenSequencerInGracePeriod_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp - 1800); // up 30 min ago, grace = 1 hour
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        MockDexSwapPaymentRails l2Rails = new MockDexSwapPaymentRails(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "should fail during grace period");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev Certora L-02: oracle reads succeed after grace period expires.
    function test_WhenSequencerUpPastGracePeriod_Succeeds() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp - 7200); // up 2 hours ago, grace = 1 hour
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        MockDexSwapPaymentRails l2Rails = new MockDexSwapPaymentRails(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);
        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT);
        router.setOutputAmount(DEFAULT_BUY_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertTrue(result.success, "should succeed after grace period");
    }

    /// @dev Certora L-02: sequencer feed revert must fail gracefully.
    function test_WhenSequencerFeedReverts_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setShouldRevert(true);
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        MockDexSwapPaymentRails l2Rails = new MockDexSwapPaymentRails(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "should fail when sequencer feed reverts");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev The grace period must be measured from `startedAt` (tuple position 3, when the sequencer
    /// last changed status), not from `updatedAt` (position 4, the last routine feed write). On
    /// Base's live feed these run weeks apart: sampled across 31 days, `startedAt` stayed pinned at
    /// 1_782_491_507 while `updatedAt` advanced on every write. Reading position 4 would block every
    /// order for a full grace period after each write, with no outage.
    function test_WhenStartedAtAndUpdatedAtDiverge_MeasuresFromStartedAt() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp - 30 days); // sequencer up for 30 days
        seqFeed.setUpdatedAt(block.timestamp - 60); // feed written 60s ago, grace = 1 hour
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        MockDexSwapPaymentRails l2Rails = new MockDexSwapPaymentRails(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);
        buyToken.mint(address(router), DEFAULT_BUY_AMOUNT);
        router.setOutputAmount(DEFAULT_BUY_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertTrue(result.success, "grace period must key off startedAt, not updatedAt");
    }

    /// @dev An uninitialized round reports startedAt == 0, making `block.timestamp - startedAt` span
    /// the whole unix epoch, which clears any grace period.
    function test_WhenSequencerRoundUninitialized_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(0);
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        MockDexSwapPaymentRails l2Rails = new MockDexSwapPaymentRails(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "uninitialized round must not clear the grace period");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /// @dev A feed ahead of block.timestamp would underflow. The subtraction sits in the try's
    /// success body, so the panic escapes the adjacent catch instead of failing closed.
    function test_WhenSequencerReportsFutureTimestamp_ReturnsOracleUnavailable() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        seqFeed.setStartedAt(block.timestamp + 1 hours);
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        MockDexSwapPaymentRails l2Rails = new MockDexSwapPaymentRails(address(l2Module));
        sellToken.mint(address(l2Rails), DEFAULT_SELL_AMOUNT);

        DataTypes.ExecutionResult memory result =
            l2Rails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(result.success, "future timestamp must fail closed, not panic");
        assertEq(result.failureReason, "Oracle price unavailable");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_WhenAllValid_HandlesAnyValidAmounts(uint256 sellAmount, uint256 _buyAmount) external {
        sellAmount = bound(sellAmount, 1, DEFAULT_SELL_AMOUNT * 50);
        uint256 oracleFloor = _computeOracleFloor(sellAmount);
        // Skip dust amounts where oracle floor rounds to zero — the module now rejects these.
        vm.assume(oracleFloor > 0);
        _buyAmount = bound(_buyAmount, oracleFloor, type(uint128).max);

        sellToken.mint(address(paymentRails), sellAmount);
        buyToken.mint(address(router), _buyAmount);
        router.setOutputAmount(_buyAmount);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), sellAmount, _defaultParams());

        assertTrue(result.success, "success");
        assertEq(result.amountOut, _buyAmount, "amountOut");
        assertEq(sellToken.balanceOf(address(module)), 0, "no residual");
    }

    function test_WhenOracleFloorRoundsToZero_RejectsSwap() external {
        // 1 wei with equal prices and 1% slippage → oracleFloor = mulDiv(1, 9900, 10000) = 0
        uint256 dustAmount = 1;
        sellToken.mint(address(paymentRails), dustAmount);
        buyToken.mint(address(router), 1);
        router.setOutputAmount(1);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), dustAmount, _defaultParams());

        assertFalse(result.success, "should reject dust swap");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    MAX AMOUNT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenExceedsMaxAmount_ReturnsFailedResult() external {
        bytes memory params = _defaultParamsWithMaxAmount(500e18);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "success");
        assertEq(result.failureReason, "Exceeds max swap amount", "failureReason");
    }

    function test_WhenExceedsMaxAmount_DoesNotTransferTokens() external {
        bytes memory params = _defaultParamsWithMaxAmount(500e18);
        uint256 balBefore = sellToken.balanceOf(address(paymentRails));
        paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(sellToken.balanceOf(address(paymentRails)), balBefore, "no tokens moved");
    }

    function test_WhenAmountEqualsMaxAmount_Succeeds() external {
        bytes memory params = _defaultParamsWithMaxAmount(DEFAULT_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(result.success, "exact maxAmount should succeed");
    }

    function test_WhenAmountBelowMaxAmount_Succeeds() external {
        bytes memory params = _defaultParamsWithMaxAmount(DEFAULT_SELL_AMOUNT * 2);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(result.success, "below maxAmount should succeed");
    }

    function test_WhenMaxAmountIsZero_NoLimit() external {
        bytes memory params = _defaultParamsWithMaxAmount(0);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(result.success, "zero maxAmount means no limit");
    }

    function testFuzz_MaxAmountBoundary(uint256 maxAmt) external {
        maxAmt = bound(maxAmt, 1, DEFAULT_SELL_AMOUNT - 1);
        bytes memory params = _defaultParamsWithMaxAmount(maxAmt);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(result.success, "amount > maxAmount must fail");
        assertEq(result.failureReason, "Exceeds max swap amount");
    }
}
