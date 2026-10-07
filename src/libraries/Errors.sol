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

    /// @notice Thrown when the router has code but does not expose a Uniswap V3 `factory()`.
    /// @param router The address that failed the Uniswap router probe.
    error DexSwapModule_RouterNotUniswap(address router);

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
                        PAYMENT RAILS FACTORY ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when attempting to deploy a PaymentRails with owner set to the zero address.
    error PaymentRailsFactory_ZeroOwner();

    /// @notice Thrown when renouncing ownership of the factory is attempted.
    error PaymentRailsFactory_OwnershipCannotBeRenounced();

    /*//////////////////////////////////////////////////////////////////////////
                        COWSWAP MODULE FACTORY ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Thrown when the GPv2Settlement address is the zero address in the factory constructor.
    error CowSwapModuleFactory_ZeroCowSettlement();

    /// @notice Thrown when the GPv2Settlement address has no deployed code in the factory constructor.
    /// @param settlement The EOA address that was rejected.
    error CowSwapModuleFactory_SettlementNotContract(address settlement);

    /// @notice Thrown when a non-zero sequencer uptime feed has no deployed code in the factory
    /// constructor. `address(0)` stays valid — it is the L1 profile.
    /// @param sequencerUptimeFeed The EOA address that was rejected.
    error CowSwapModuleFactory_SequencerFeedNotContract(address sequencerUptimeFeed);

    /// @notice Thrown when the sequencer grace period is zero or implausibly large on the L2
    /// profile. Zero would reduce every deployed module's grace check to `uint256 < 0`, which is
    /// never true, silently disabling the guard fleet-wide.
    /// @param sequencerGracePeriod The value that was rejected.
    error CowSwapModuleFactory_InvalidGracePeriod(uint256 sequencerGracePeriod);

    /// @notice Thrown when a non-zero sequencer grace period is paired with no uptime feed. The
    /// grace period is measured from the feed's `startedAt`, so without a feed it is dead config
    /// that still reads as protection through `sequencerGracePeriod()`.
    /// @param sequencerGracePeriod The value that was rejected.
    error CowSwapModuleFactory_GracePeriodWithoutFeed(uint256 sequencerGracePeriod);

    /// @notice Thrown when attempting to deploy a CowSwapModule with owner set to the zero address.
    error CowSwapModuleFactory_ZeroOwner();

    /// @notice Thrown when attempting to deploy a CowSwapModule with PaymentRails set to the zero address.
    error CowSwapModuleFactory_ZeroPaymentRails();

    /// @notice Thrown when the target PaymentRails address has no deployed code.
    /// @param paymentRails The address that was rejected.
    error CowSwapModuleFactory_PaymentRailsNotContract(address paymentRails);

    /// @notice Thrown when renouncing ownership of the factory is attempted.
    error CowSwapModuleFactory_OwnershipCannotBeRenounced();

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
    /// @dev The module must always retain an owner: keeper rotation, pause/unpause, the
    ///      `onlyOwner whenPaused` recovery sweep and `setSignatureCaller` all depend on one
    ///      existing. Renouncing would also freeze the ERC-1271 caller set permanently.
    error AtumModule_RenounceOwnershipDisabled();

    /// @notice Thrown when a transfer debited the sender by something other than `amount`.
    /// @dev Certora I-06. The received amount was already checked; this covers the other side,
    ///      where a sender-paid fee leaves PaymentRails down more than the module gained.
    error AtumModule_UnsupportedTokenDebitedAmount(uint256 expected, uint256 debited);

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

    /// @notice Thrown when authorizing the zero address as an ERC-1271 caller.
    /// @dev Certora M-01. `address(0)` is what an `eth_call` with no `from` presents as, so
    ///      authorizing it would hand the magic value to every off-chain probe.
    error AtumModule_ZeroSignatureCaller();

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

    /// @notice Thrown when the factory is constructed with a zero PaymentRailsFactory address.
    error AtumModuleFactory_ZeroPaymentRailsFactory();

    /// @notice Thrown when the factory is constructed with a PaymentRailsFactory address that has no code.
    /// @param paymentRailsFactory The address supplied as the PaymentRailsFactory.
    error AtumModuleFactory_PaymentRailsFactoryNotContract(address paymentRailsFactory);

    /// @notice Thrown when a module is created with a zero owner address.
    error AtumModuleFactory_ZeroOwner();

    /// @notice Thrown when a module is created with a zero PaymentRails address.
    error AtumModuleFactory_ZeroPaymentRails();

    /// @notice Thrown when a module is created with a zero keeper address.
    error AtumModuleFactory_ZeroKeeper();

    /// @notice Thrown when renouncing ownership of the factory is attempted.
    error AtumModuleFactory_OwnershipCannotBeRenounced();

    /// @notice Thrown when the supplied PaymentRails address has no code.
    /// @dev Querying the PaymentRailsFactory list for an EOA would only report it unknown; fail
    ///      with a named error instead.
    error AtumModuleFactory_PaymentRailsNotContract(address paymentRails);

    /// @notice Thrown when `paymentRails` was not deployed by the configured PaymentRailsFactory.
    /// @dev A lookalike contract, and a PaymentRails deployed outside the factory, fail here. An
    ///      address with no code fails earlier, at `PaymentRailsNotContract`. Membership is
    ///      owner-gated on that factory, so copying function names is not enough to get onto the list.
    error AtumModuleFactory_UnknownPaymentRails(address paymentRails);
}
