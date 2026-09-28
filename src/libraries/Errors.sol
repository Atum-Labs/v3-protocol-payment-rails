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
}
