// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

import { ICowSwapModule } from "../../interfaces/ICowSwapModule.sol";
import { IGPv2Settlement } from "../../interfaces/IGPv2Settlement.sol";
import { IActionModule } from "../../interfaces/IActionModule.sol";
import { IChainlinkAggregatorV3 } from "../../interfaces/IChainlinkAggregatorV3.sol";
import { ActionModuleBase } from "../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../types/DataTypes.sol";
import { Errors } from "../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title CowSwapModule
/// @author Credit Cooperative
/// @notice Async action module that submits sell orders to the CowSwap order-book protocol.
/// @dev See {ICowSwapModule} for lifecycle and security model. Fee-on-transfer tokens are NOT supported.
contract CowSwapModule is ICowSwapModule, ActionModuleBase, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev EIP-1271 magic value returned for valid orders.
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev EIP-1271 failure value returned for invalid orders.
    bytes4 internal constant EIP1271_FAILURE_VALUE = 0xffffffff;

    /// @dev EIP-712 type hash for GPv2Order.Data.
    /// See: https://github.com/cowprotocol/contracts/blob/main/src/contracts/libraries/GPv2Order.sol
    bytes32 internal constant ORDER_TYPE_HASH = keccak256(
        "Order(" "address sellToken," "address buyToken," "address receiver," "uint256 sellAmount," "uint256 buyAmount,"
        "uint32 validTo," "bytes32 appData," "uint256 feeAmount," "string kind," "bool partiallyFillable,"
        "string sellTokenBalance," "string buyTokenBalance" ")"
    );

    /// @dev CowSwap order kind: sell an exact amount of sellToken.
    bytes32 internal constant KIND_SELL = keccak256("sell");

    /// @dev CowSwap balance type: standard ERC-20 balances.
    bytes32 internal constant BALANCE_ERC20 = keccak256("erc20");

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc ICowSwapModule
    address public immutable override cowSettlement;

    /// @notice Address of the GPv2VaultRelayer that pulls sellToken during settlement.
    address public immutable vaultRelayer;

    /// @inheritdoc ICowSwapModule
    bytes32 public immutable override cowDomainSeparator;

    /// @inheritdoc ICowSwapModule
    address public immutable override paymentRails;

    /// @inheritdoc ICowSwapModule
    address public immutable override sequencerUptimeFeed;

    /// @inheritdoc ICowSwapModule
    uint256 public immutable override sequencerGracePeriod;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Order metadata keyed by GPv2Order digest.
    mapping(bytes32 orderId => DataTypes.CowOrderMetadata metadata) private _orders;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _cowSettlement GPv2Settlement contract address.
    /// @param _owner Owner for Ownable2Step (can cancel orders).
    /// @param _paymentRails Authorized PaymentRails caller for execute().
    /// @param _sequencerUptimeFeed Chainlink L2 sequencer uptime feed; address(0) on L1.
    /// @param _sequencerGracePeriod Seconds after sequencer recovery before trusting oracles.
    constructor(
        address _cowSettlement,
        address _owner,
        address _paymentRails,
        address _sequencerUptimeFeed,
        uint256 _sequencerGracePeriod
    )
        Ownable(_owner)
    {
        if (_cowSettlement == address(0)) revert Errors.CowSwapModule_ZeroCowSettlement();
        if (_paymentRails == address(0)) revert Errors.CowSwapModule_ZeroPaymentRails();

        cowSettlement = _cowSettlement;
        cowDomainSeparator = IGPv2Settlement(_cowSettlement).domainSeparator();
        vaultRelayer = IGPv2Settlement(_cowSettlement).vaultRelayer();
        paymentRails = _paymentRails;
        sequencerUptimeFeed = _sequencerUptimeFeed;
        sequencerGracePeriod = _sequencerGracePeriod;
    }

    /*//////////////////////////////////////////////////////////////////////////
                            OWNERSHIP OVERRIDES
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Disables renounceOwnership() to prevent permanently locking pending orders' sell tokens.
    function renounceOwnership() public pure override {
        revert Errors.CowSwapModule_OwnershipCannotBeRenounced();
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
        returns (DataTypes.ExecutionResult memory result)
    {
        if (msg.sender != paymentRails) {
            return _failedResult(token, "Caller is not authorized PaymentRails");
        }

        DataTypes.CowSwapParams memory swapParams;
        uint32 validTo;
        uint256 oracleFloor;

        // --- Checks ---

        {
            bool valid;
            string memory reason;
            (valid, reason, swapParams, validTo, oracleFloor) = _validate(token, amount, params);
            if (!valid) {
                return _failedResult(token, reason);
            }
        }

        bytes32 orderId = _computeOrderDigest(
            token, swapParams.targetToken, msg.sender, amount, oracleFloor, validTo, swapParams.appData
        );

        if (_orders[orderId].paymentRails != address(0)) {
            return _failedResult(token, "Order ID collision: use unique appData");
        }

        // --- Effects ---

        _orders[orderId] = DataTypes.CowOrderMetadata({
            paymentRails: msg.sender,
            sellToken: token,
            buyToken: swapParams.targetToken,
            sellAmount: amount,
            validTo: validTo,
            cancelled: false
        });

        // --- Interactions ---

        bool transferred = _safeTransferFrom(token, msg.sender, address(this), amount);
        if (!transferred) {
            delete _orders[orderId];
            return _failedResult(token, "Token transfer failed");
        }

        if (IERC20(token).allowance(address(this), vaultRelayer) < type(uint256).max) {
            IERC20(token).forceApprove(vaultRelayer, type(uint256).max);
        }

        emit OrderCreated(
            orderId, msg.sender, token, swapParams.targetToken, amount, oracleFloor, validTo, swapParams.appData
        );

        return _successResult(0, swapParams.targetToken, abi.encode(orderId));
    }

    /// @inheritdoc ICowSwapModule
    function cancelOrder(bytes32 orderId) external onlyOwner nonReentrant {
        DataTypes.CowOrderMetadata storage meta = _orders[orderId];

        if (meta.paymentRails == address(0)) {
            revert Errors.CowSwapModule_UnknownOrder(orderId);
        }
        if (meta.cancelled) {
            revert Errors.CowSwapModule_OrderAlreadyCancelled(orderId);
        }
        if (IGPv2Settlement(cowSettlement).filledAmount(_orderUid(orderId, meta.validTo)) >= meta.sellAmount) {
            revert Errors.CowSwapModule_OrderAlreadyFilled(orderId);
        }

        address sellToken = meta.sellToken;
        uint256 sellAmount = meta.sellAmount;

        meta.cancelled = true;

        IGPv2Settlement(cowSettlement).invalidateOrder(_orderUid(orderId, meta.validTo));

        uint256 sellBalance = IERC20(sellToken).balanceOf(address(this));
        uint256 returnAmount = sellBalance < sellAmount ? sellBalance : sellAmount;
        if (returnAmount > 0) {
            IERC20(sellToken).safeTransfer(paymentRails, returnAmount);
        }

        emit OrderCancelled(orderId, paymentRails, sellToken, returnAmount);
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
        (isValid, reason,,,) = _validate(token, amount, params);
    }

    /// @inheritdoc ICowSwapModule
    function getOrder(bytes32 orderId) external view returns (DataTypes.CowOrderMetadata memory metadata) {
        return _orders[orderId];
    }

    /// @inheritdoc ICowSwapModule
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4 magicValue) {
        if (signature.length != 32) {
            return EIP1271_FAILURE_VALUE;
        }

        bytes32 orderId = abi.decode(signature, (bytes32));

        if (orderId != hash) {
            return EIP1271_FAILURE_VALUE;
        }

        DataTypes.CowOrderMetadata storage meta = _orders[orderId];

        if (meta.paymentRails == address(0)) {
            return EIP1271_FAILURE_VALUE;
        }
        if (meta.cancelled) {
            return EIP1271_FAILURE_VALUE;
        }

        // Check expiry before filledAmount to save the external call for expired orders.
        if (block.timestamp > meta.validTo) {
            return EIP1271_FAILURE_VALUE;
        }
        if (IGPv2Settlement(cowSettlement).filledAmount(_orderUid(orderId, meta.validTo)) >= meta.sellAmount) {
            return EIP1271_FAILURE_VALUE;
        }

        return EIP1271_MAGIC_VALUE;
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
        DataTypes.CowSwapParams memory swapParams = decodeParams(params);
        (bool oracleOk, uint256 expected) = _computeExpectedOutput(token, amount, swapParams);
        if (oracleOk) return (expected, swapParams.targetToken);
        return (0, swapParams.targetToken);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "COWSWAP";
    }

    /// @inheritdoc ICowSwapModule
    function encodeParams(DataTypes.CowSwapParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(
            params.targetToken,
            params.maxSlippageBps,
            params.sellTokenPriceFeed,
            params.buyTokenPriceFeed,
            params.maxStaleness,
            params.validityDuration,
            params.appData
        );
    }

    /// @inheritdoc ICowSwapModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.CowSwapParams memory params) {
        (
            params.targetToken,
            params.maxSlippageBps,
            params.sellTokenPriceFeed,
            params.buyTokenPriceFeed,
            params.maxStaleness,
            params.validityDuration,
            params.appData
        ) = abi.decode(encoded, (address, uint16, address, address, uint256, uint32, bytes32));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Shared validation for validate() and execute(). Collision check remains in execute().
    function _validate(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (
            bool valid,
            string memory reason,
            DataTypes.CowSwapParams memory swapParams,
            uint32 validTo,
            uint256 oracleFloor
        )
    {
        (valid, reason, swapParams, validTo) = _validateSwapParams(token, amount, params);
        if (!valid) return (false, reason, swapParams, 0, 0);

        bool oracleOk;
        (oracleOk, oracleFloor) = _computeOracleFloor(token, amount, swapParams);
        if (!oracleOk) return (false, "Oracle price unavailable", swapParams, 0, 0);
        if (oracleFloor == 0) return (false, "Amount too small for safe swap", swapParams, 0, 0);

        if (!_hasSufficientBalance(token, amount)) return (false, "Insufficient balance", swapParams, 0, 0);

        return (true, "", swapParams, validTo, oracleFloor);
    }

    /// @dev Decodes and checks all swap parameters without touching storage.
    // solhint-disable-next-line code-complexity
    function _validateSwapParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (bool valid, string memory reason, DataTypes.CowSwapParams memory swapParams, uint32 validTo)
    {
        if (params.length < 224) {
            return (false, "Invalid params encoding", swapParams, 0);
        }

        swapParams = decodeParams(params);

        if (amount == 0) {
            return (false, "Zero sell amount", swapParams, 0);
        }
        if (swapParams.targetToken == address(0)) {
            return (false, "Zero target token", swapParams, 0);
        }
        if (swapParams.targetToken == token) {
            return (false, "Same sell and buy token", swapParams, 0);
        }
        if (swapParams.maxSlippageBps == 0 || swapParams.maxSlippageBps > 10_000) {
            return (false, "Invalid slippage bps", swapParams, 0);
        }
        if (swapParams.sellTokenPriceFeed == address(0)) {
            return (false, "Missing sell token price feed", swapParams, 0);
        }
        if (swapParams.buyTokenPriceFeed == address(0)) {
            return (false, "Missing buy token price feed", swapParams, 0);
        }
        if (swapParams.maxStaleness == 0) {
            return (false, "Zero max staleness", swapParams, 0);
        }
        if (swapParams.validityDuration == 0) {
            return (false, "Zero validity duration", swapParams, 0);
        }

        uint256 rawValidTo = block.timestamp + uint256(swapParams.validityDuration);
        if (rawValidTo > type(uint32).max) {
            return (false, "Validity duration overflow", swapParams, 0);
        }

        return (true, "", swapParams, uint32(rawValidTo));
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
        DataTypes.CowSwapParams memory cfg
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
        DataTypes.CowSwapParams memory cfg
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

    /// @dev Computes the EIP-712 GPv2Order digest used as orderId.
    function _computeOrderDigest(
        address sellToken,
        address buyToken,
        address receiver,
        uint256 sellAmount,
        uint256 buyAmount,
        uint32 validTo,
        bytes32 appData
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPE_HASH,
                sellToken,
                buyToken,
                receiver,
                sellAmount,
                buyAmount,
                validTo,
                appData,
                uint256(0),
                KIND_SELL,
                false,
                BALANCE_ERC20,
                BALANCE_ERC20
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", cowDomainSeparator, structHash));
    }

    /// @dev Constructs the 56-byte GPv2 order UID: digest (32) ++ owner (20) ++ validTo (4).
    /// The "owner" is this module (the EIP-1271 signer), NOT the PaymentRails.
    function _orderUid(bytes32 orderId, uint32 validTo) internal view returns (bytes memory uid) {
        return abi.encodePacked(orderId, address(this), validTo);
    }
}
