// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleBase } from "../CowSwapModuleBase.t.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";

/// @notice Unit tests for CowSwapModule.validate()
/// @dev Tree: tests/unit/concrete/cow-swap-module/validate/validate.tree
contract CowSwapModule_Validate_Test is CowSwapModuleBase {
    // -----------------------------------------------------------------------
    // when params are malformed
    // -----------------------------------------------------------------------

    function test_WhenParamsAreMalformed_ReturnsFalse() external view {
        bytes memory malformedParams = abi.encode(address(buyToken));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertFalse(isValid);
        assertEq(reason, "Invalid params encoding");
    }

    function test_WhenParamsAreMalformed_ReasonMatchesExecute() external {
        bytes memory malformedParams = abi.encode(address(buyToken));
        (, string memory validateReason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, malformedParams);
        assertEq(validateReason, result.failureReason, "validate/execute reason must match for malformed params");
    }

    // -----------------------------------------------------------------------
    // when amount is zero
    // -----------------------------------------------------------------------

    function test_WhenAmountIsZero_ReturnsFalse() external view {
        (bool isValid, string memory reason) = module.validate(address(sellToken), 0, _buildDefaultParams());
        assertFalse(isValid);
        assertEq(reason, "Zero sell amount");
    }

    function test_WhenAmountIsZero_ReasonMatchesExecute() external {
        (, string memory validateReason) = module.validate(address(sellToken), 0, _buildDefaultParams());
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), 0, _buildDefaultParams());
        assertEq(validateReason, result.failureReason, "validate/execute reason must match");
    }

    // -----------------------------------------------------------------------
    // when target token is zero address
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenIsZero_ReturnsFalse() external view {
        bytes memory params = _buildParams(
            address(0),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Zero target token");
    }

    // -----------------------------------------------------------------------
    // when target token equals sell token
    // -----------------------------------------------------------------------

    function test_WhenTargetTokenEqualsSellToken_ReturnsFalse() external view {
        bytes memory params = _buildParams(
            address(sellToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Same sell and buy token");
    }

    // -----------------------------------------------------------------------
    // when slippage bps is zero (invalid)
    // -----------------------------------------------------------------------

    function test_WhenSlippageBpsIsZero_ReturnsFalse() external view {
        bytes memory params = _buildParams(
            address(buyToken),
            0,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Invalid slippage bps");
    }

    // -----------------------------------------------------------------------
    // when sell token price feed is missing
    // -----------------------------------------------------------------------

    function test_WhenSellTokenPriceFeedIsZero_ReturnsFalse() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(0),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Missing sell token price feed");
    }

    // -----------------------------------------------------------------------
    // when buy token price feed is missing
    // -----------------------------------------------------------------------

    function test_WhenBuyTokenPriceFeedIsZero_ReturnsFalse() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(0),
            DEFAULT_MAX_STALENESS,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Missing buy token price feed");
    }

    // -----------------------------------------------------------------------
    // when validity duration is zero
    // -----------------------------------------------------------------------

    function test_WhenMaxStalenessIsZero_ReturnsFalse() external view {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            0,
            DEFAULT_VALIDITY,
            DEFAULT_APP_DATA
        );
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Zero max staleness");
    }

    function test_WhenValidityDurationIsZero_ReturnsFalse() external view {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            0,
            DEFAULT_APP_DATA
        );
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Zero validity duration");
    }

    // -----------------------------------------------------------------------
    // when validity duration overflows uint32
    // -----------------------------------------------------------------------

    function test_WhenValidityDurationOverflows_ReturnsFalse() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            type(uint32).max,
            DEFAULT_APP_DATA
        );
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Validity duration overflow");
    }

    function test_WhenValidityDurationOverflows_ReasonMatchesExecute() external {
        bytes memory params = _buildParams(
            address(buyToken),
            DEFAULT_SLIPPAGE_BPS,
            address(sellFeed),
            address(buyFeed),
            DEFAULT_MAX_STALENESS,
            type(uint32).max,
            DEFAULT_APP_DATA
        );
        vm.prank(address(paymentRails));
        (, string memory validateReason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        DataTypes.ExecutionResult memory result =
            paymentRails.initiateSwap(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(validateReason, result.failureReason, "validate/execute reason must match for overflow");
    }

    // -----------------------------------------------------------------------
    // when oracle price is unavailable
    // -----------------------------------------------------------------------

    function test_WhenSellOracleReverts_ReturnsFalse() external {
        sellFeed.setShouldRevert(true);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    function test_WhenBuyOracleReverts_ReturnsFalse() external {
        buyFeed.setShouldRevert(true);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    function test_WhenOraclePriceIsStale_ReturnsFalse() external {
        sellFeed.setUpdatedAt(block.timestamp - DEFAULT_MAX_STALENESS - 1);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    function test_WhenOraclePriceIsNegative_ReturnsFalse() external {
        sellFeed.setAnswer(-1);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) =
            module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, _buildDefaultParams());
        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    // -----------------------------------------------------------------------
    // when oracle floor rounds to zero
    // -----------------------------------------------------------------------

    function test_WhenOracleFloorRoundsToZero_ReturnsFalse() external {
        sellFeed.setAnswer(1);
        buyFeed.setAnswer(1e8);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), 1, _buildDefaultParams());
        assertFalse(isValid);
        assertEq(reason, "Amount too small for safe swap");
    }

    // -----------------------------------------------------------------------
    // when caller has insufficient balance
    // -----------------------------------------------------------------------

    function test_WhenCallerHasInsufficientBalance_ReturnsFalse() external view {
        bytes memory params = _buildDefaultParams();
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertFalse(isValid);
        assertEq(reason, "Insufficient balance");
    }

    // -----------------------------------------------------------------------
    // when all parameters are valid
    // -----------------------------------------------------------------------

    function test_WhenAllParametersAreValid_ReturnsTrue() external {
        bytes memory params = _buildDefaultParams();
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertTrue(isValid);
        assertEq(reason, "");
    }

    function test_WhenAllParametersAreValid_ReturnsEmptyReason() external {
        bytes memory params = _buildDefaultParams();
        vm.prank(address(paymentRails));
        (, string memory reason) = module.validate(address(sellToken), DEFAULT_SELL_AMOUNT, params);
        assertEq(bytes(reason).length, 0);
    }
}
