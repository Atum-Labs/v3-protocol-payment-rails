// SPDX-License-Identifier: MIT
pragma solidity 0.8.29;

/// @title Errors
/// @notice Centralized error definitions for the Receivables PaymentRails system
/// @dev All custom errors are defined here for gas efficiency and maintainability
library Errors {
    /*//////////////////////////////////////////////////////////////////////////
                                PAYMENT RAILS ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to configure a token with zero address
    error PaymentRails_ZeroTokenAddress();

    /// @notice Thrown when clearing a token configuration but providing a non-zero module address
    /// @dev When actionType is empty (clearing config), actionModule must be address(0)
    error PaymentRails_NoneActionRequiresZeroModule();

    /// @notice Thrown when configuring a token action with zero module address
    /// @dev When actionType is set, actionModule must be a valid contract address
    error PaymentRails_ZeroModuleAddress();

    /// @notice Thrown when the action module contract doesn't implement required interface
    error PaymentRails_InvalidModule();

    /// @notice Thrown when module validation call fails
    /// @dev This occurs when moduleType() call reverts or returns invalid data
    error PaymentRails_ModuleValidationFailed();

    /// @notice Thrown when attempting to execute action on a disabled token
    /// @dev Token must have enabled=true in its configuration
    error PaymentRails_TokenNotEnabled();

    /// @notice Thrown when attempting to execute but no action is configured
    /// @dev This occurs when actionType is empty string
    error PaymentRails_NoActionConfigured();

    /// @notice Thrown when execution amount is below the configured minimum balance threshold
    /// @param amount Attempted execution amount
    /// @param minBalance Required minimum balance
    error PaymentRails_BelowMinimumBalance(uint256 amount, uint256 minBalance);

    /// @notice Thrown when attempting to execute with zero amount
    error PaymentRails_ZeroAmount();

    /// @notice Thrown when paymentRails's token balance is insufficient for the requested amount
    /// @param balance PaymentRails's current token balance
    /// @param amount Requested execution amount
    error PaymentRails_InsufficientBalance(uint256 balance, uint256 amount);

    /*//////////////////////////////////////////////////////////////////////////
                            DEX SWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the router address is the zero address in the constructor.
    error DexSwapModule_ZeroRouter();

    /// @notice Thrown when the router address has no deployed code in the constructor.
    /// @param router The EOA address that was rejected.
    error DexSwapModule_RouterNotContract(address router);

    /// @notice Thrown when actual swap output is below the oracle-computed floor.
    /// @param amountOut Actual output from the swap.
    /// @param oracleFloor Oracle-computed minimum after applying `maxSlippageBps`.
    error DexSwapModule_InsufficientOutput(uint256 amountOut, uint256 oracleFloor);

    /*//////////////////////////////////////////////////////////////////////////
                            OWNERSHIP ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when renounceOwnership() is called on PaymentRails.
    /// @dev Ownership renunciation is permanently disabled to prevent locking the contract.
    error PaymentRails_OwnershipCannotBeRenounced();

    /*//////////////////////////////////////////////////////////////////////////
                            COWSWAP MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the CowSwap GPv2Settlement address is the zero address
    error CowSwapModule_ZeroCowSettlement();

    /// @notice Thrown when the PaymentRails address is the zero address in the constructor
    error CowSwapModule_ZeroPaymentRails();

    /// @notice Thrown when attempting to act on an orderId that was never created
    /// @param orderId The unknown order digest
    error CowSwapModule_UnknownOrder(bytes32 orderId);

    /// @notice Thrown when cancelOrder is called on an order that is already cancelled
    /// @param orderId The order digest
    error CowSwapModule_OrderAlreadyCancelled(bytes32 orderId);

    /// @notice Thrown when cancelOrder is called on an order already filled by a CowSwap solver
    /// @dev Verified via GPv2Settlement.filledAmount(orderUid) >= meta.sellAmount
    /// @param orderId The order digest
    error CowSwapModule_OrderAlreadyFilled(bytes32 orderId);

    /// @notice Thrown when renounceOwnership() is called on CowSwapModule.
    /// @dev Ownership renunciation is permanently disabled because it would lock
    /// all pending orders' sell tokens with no way to cancel them.
    error CowSwapModule_OwnershipCannotBeRenounced();

    /*//////////////////////////////////////////////////////////////////////////
                        CCTP BRIDGE MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the TokenMessengerV2 address is the zero address in the constructor.
    error CCTPBridgeModule_ZeroTokenMessenger();

    /// @notice Thrown when the USDC address is the zero address in the constructor.
    error CCTPBridgeModule_ZeroUSDC();

    /*//////////////////////////////////////////////////////////////////////////
                        ATUM PAYMENT MODULE ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the Permit2 address is the zero address in the constructor.
    error AtumModule_ZeroPermit2();

    /// @notice Thrown when the Permit2 address supplied to an AtumModule has no code.
    /// @dev The module used to reject an EOA only as a side effect of calling DOMAIN_SEPARATOR()
    ///      on it in the constructor. That call was dead state (it was stored and never read) and
    ///      has been removed, so the check it accidentally provided is now explicit. The factory
    ///      has an equivalent check of its own; this one covers modules constructed directly.
    error AtumModule_Permit2NotContract(address permit2);

    /// @notice Thrown when `renounceOwnership` is called on an AtumModule.
    /// @dev The module must always retain an owner: keeper rotation, pause/unpause and the
    ///      `onlyOwner whenPaused` recovery sweep all depend on one existing.
    error AtumModule_RenounceOwnershipDisabled();

    /// @notice Thrown when the immutable PaymentRails address is the zero address in the constructor.
    error AtumModule_ZeroPaymentRails();

    /// @notice Thrown when a caller is not the immutable PaymentRails.
    /// @param caller Unauthorized caller.
    /// @param paymentRails Immutable PaymentRails authorized to call.
    error AtumModule_NotPaymentRails(address caller, address paymentRails);

    /// @notice Thrown when the keeper address is the zero address.
    error AtumModule_ZeroKeeper();

    /// @notice Thrown when a caller is not the current keeper.
    /// @param caller Unauthorized caller.
    /// @param keeper Current keeper authorized to call.
    error AtumModule_NotKeeper(address caller, address keeper);

    /// @notice Thrown when a token address is zero.
    error AtumModule_ZeroToken();

    /// @notice Thrown when attempting to invalidate the zero digest.
    error AtumModule_ZeroDigest();

    /// @notice Thrown when the module receives less or more than the exact amount requested.
    /// @param expected Amount requested from the PaymentRails.
    /// @param actual Balance delta observed by the module.
    error AtumModule_UnsupportedTokenReceivedAmount(uint256 expected, uint256 actual);

    /*//////////////////////////////////////////////////////////////////////////
                        ATUM PAYMENT MODULE FACTORY ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the factory is constructed with a zero Permit2 address.
    error AtumModuleFactory_ZeroPermit2();

    /// @notice Thrown when the factory is constructed with a Permit2 address that has no code.
    /// @param permit2 The address supplied as Permit2.
    error AtumModuleFactory_Permit2NotContract(address permit2);

    /// @notice Thrown when a module is created with a zero owner address.
    error AtumModuleFactory_ZeroOwner();

    /// @notice Thrown when a module is created with a zero PaymentRails address.
    error AtumModuleFactory_ZeroPaymentRails();

    /// @notice Thrown when a module is created with a zero keeper address.
    error AtumModuleFactory_ZeroKeeper();

    /// @notice Thrown when a module is created for a PaymentRails the caller does not own.
    /// @dev Certora L-01. Creation used to be permissionless, so anyone could deploy a module
    ///      naming a victim's PaymentRails and have it recorded against them in the registry.
    error AtumModuleFactory_NotPaymentRailsOwner(address caller, address paymentRailsOwner);

    /// @notice Thrown when the supplied PaymentRails address has no code.
    /// @dev Reading `owner()` off an EOA would revert opaquely; fail with a named error instead.
    error AtumModuleFactory_PaymentRailsNotContract(address paymentRails);
}
