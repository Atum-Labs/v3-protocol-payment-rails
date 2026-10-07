// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for DexSwapModule.validate()
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/validate/validate.tree
contract DexSwapModule_Validate_Test is DexSwapModuleBase {
    /*//////////////////////////////////////////////////////////////////////////
                            FAILURE TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenParamsTooShort_ReturnsFalse() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00");
        assertFalse(isValid, "isValid");
        assertEq(reason, "Invalid params encoding", "reason");
    }

    function test_WhenTargetTokenIsZero_ReturnsFalse() external {
        bytes memory params = _buildParamsCustom(
            address(0),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero target token", "reason");
    }

    function test_WhenTargetTokenEqualsSellToken_ReturnsFalse() external {
        bytes memory params = _buildParams(address(sellToken));
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Same input and output token", "reason");
    }

    function test_WhenAmountIsZero_ReturnsFalse() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), 0, _defaultParams());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero sell amount", "reason");
    }

    function test_WhenSlippageBpsIsZero_ReturnsFalse() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            0,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Invalid slippage bps", "reason");
    }

    function test_WhenSlippageBpsExceeds10000_ReturnsFalse() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            10_001,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Invalid slippage bps", "reason");
    }

    function test_WhenSellFeedIsZero_ReturnsFalse() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(0),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Missing sell token price feed", "reason");
    }

    function test_WhenBuyFeedIsZero_ReturnsFalse() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(0),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Missing buy token price feed", "reason");
    }

    function test_WhenMaxStalenessIsZero_ReturnsFalse() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            0,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero max staleness", "reason");
    }

    function test_WhenSwapDeadlineSecondsIsZero_ReturnsFalse() external {
        bytes memory params = _buildParamsCustom(
            address(buyToken),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            0
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Zero swap deadline", "reason");
    }

    function test_WhenOracleIsUnavailable_ReturnsFalse() external {
        sellFeed.setAnswer(-1);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Oracle price unavailable", "reason");
    }

    function test_WhenCallerHasInsufficientBalance_ReturnsFalse() external view {
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertFalse(isValid, "isValid");
        assertEq(reason, "Insufficient balance", "reason");
    }

    /*//////////////////////////////////////////////////////////////////////////
                            SUCCESS TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenAllValid_ReturnsTrue() external {
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _defaultParams());
        assertTrue(isValid, "isValid");
        assertEq(bytes(reason).length, 0, "reason should be empty");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    VALIDATE / EXECUTE AGREEMENT TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValidateExecuteAgree_ParamsTooShort() external {
        vm.prank(address(paymentRails));
        (, string memory valReason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00");
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, hex"00");
        assertEq(valReason, result.failureReason, "reasons must match");
    }

    function test_ValidateExecuteAgree_ZeroTargetToken() external {
        bytes memory params = _buildParamsCustom(
            address(0),
            DEFAULT_FEE,
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_SWAP_DEADLINE
        );
        vm.prank(address(paymentRails));
        (, string memory valReason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(valReason, result.failureReason, "reasons must match");
    }

    function test_ValidateExecuteAgree_ZeroSellAmount() external {
        vm.prank(address(paymentRails));
        (, string memory valReason) = module.validate(address(sellToken), 0, _defaultParams());
        DataTypes.ExecutionResult memory result = paymentRails.executeSwap(address(sellToken), 0, _defaultParams());
        assertEq(valReason, result.failureReason, "reasons must match");
    }

    function test_ValidateExecuteAgree_SameInputOutputToken() external {
        bytes memory params = _buildParams(address(sellToken));
        vm.prank(address(paymentRails));
        (, string memory valReason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(valReason, result.failureReason, "reasons must match");
    }

    /*//////////////////////////////////////////////////////////////////////////
            VALIDATE vs EXECUTE ORDERING — SHARED _validate() AGREEMENT
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev When both oracle AND balance are invalid, execute and validate report the same
    /// first error because both call the single _validate() internal.
    function test_Oracle_AndBalance_BothBad_AgreesOnReason() external {
        sellFeed.setAnswer(-1);
        uint256 tooMuch = DEFAULT_SELL_AMOUNT * 101;

        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) = module.validate(address(sellToken), tooMuch, _defaultParams());
        assertFalse(isValid);

        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), tooMuch, _defaultParams());
        assertFalse(result.success);
        assertEq(valReason, result.failureReason, "both paths report same first error");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    FUZZ: VALIDATE / EXECUTE AGREEMENT
    //////////////////////////////////////////////////////////////////////////*/

    function testFuzz_ValidateExecuteAgreeOnSharedChecks(uint256 amount) external {
        amount = bound(amount, 0, DEFAULT_SELL_AMOUNT * 200);

        vm.prank(address(paymentRails));
        (bool isValid, string memory valReason) = module.validate(address(sellToken), amount, _defaultParams());

        try paymentRails.executeSwap(address(sellToken), amount, _defaultParams()) returns (
            DataTypes.ExecutionResult memory result
        ) {
            if (!isValid && !result.success) {
                assertEq(valReason, result.failureReason, "shared validator reasons must match");
            }
        } catch { }
    }

    /*//////////////////////////////////////////////////////////////////////////
                    MAX AMOUNT VALIDATION TESTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenExceedsMaxAmount_ReturnsFalse() external {
        bytes memory params = _defaultParamsWithMaxAmount(500e18);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid, "isValid");
        assertEq(reason, "Exceeds max swap amount", "reason");
    }

    function test_WhenAmountEqualsMaxAmount_ReturnsTrue() external {
        bytes memory params = _defaultParamsWithMaxAmount(DEFAULT_SELL_AMOUNT);
        vm.prank(address(paymentRails));
        (bool isValid,) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(isValid, "exact maxAmount should validate");
    }

    function test_WhenMaxAmountZero_ReturnsTrue() external {
        bytes memory params = _defaultParamsWithMaxAmount(0);
        vm.prank(address(paymentRails));
        (bool isValid,) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(isValid, "zero maxAmount means no limit");
    }

    /*//////////////////////////////////////////////////////////////////////////
            VALIDATE / EXECUTE AGREEMENT: MAX AMOUNT
    //////////////////////////////////////////////////////////////////////////*/

    function test_ValidateExecuteAgree_ExceedsMaxAmount() external {
        bytes memory params = _defaultParamsWithMaxAmount(500e18);

        vm.prank(address(paymentRails));
        (, string memory valReason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        DataTypes.ExecutionResult memory result =
            paymentRails.executeSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(valReason, result.failureReason, "reasons must match");
    }
}
