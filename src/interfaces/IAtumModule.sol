// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title IAtumModule
/// @notice Minimal PaymentRails-bound Atum payment contract and ERC-1271 Permit2 owner.
/// @dev One module deployment is bound to one immutable PaymentRails. The PaymentRails funds the
///      contract through `execute`; the module emits the current available source
///      balance and destination details for an offchain keeper, and validates raw
///      Permit2 digests by keeper signature.
///
///      The module does not compute request ids, source assets, fulfillment amounts,
///      or fees. The keeper derives source details from the log context and prepares
///      Atum payment requests from the module's available token balance offchain.
///
///      Failed deposits, refunds, and unused source balances remain in the module. The
///      keeper should watch {AtumIntentCreated}, Atum Escrow refund events, and module
///      token balances to initiate new payment requests from the available balance.
interface IAtumModule is IActionModule, IERC1271 {
    /// @notice Emitted when the module approves Permit2 for a source token.
    event Permit2ApprovalSet(address indexed token, address indexed permit2, uint256 amount);

    /// @notice Emitted when the owner rotates the keeper.
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);

    /// @notice Emitted when the keeper permanently rejects a Permit2 digest.
    event PermitDigestInvalidated(bytes32 indexed digest);

    /// @notice Emitted when the owner returns a module-held token balance to the immutable PaymentRails.
    event TokenBalanceReturned(address indexed token, address indexed paymentRails, uint256 amount);

    /// @notice Emitted when source funds are available for an Atum payment request.
    /// @param token Source token available in the module.
    /// @param availableSourceAmount Current module token balance the keeper should use for the payment request.
    /// @param destinationChain CAIP-2 destination chain identifier.
    /// @param destinationAccount Destination account identifier for the Atum payment request.
    /// @param destinationAsset CAIP-19 destination asset identifier for the Atum payment request.
    event AtumIntentCreated(
        address indexed token,
        uint256 availableSourceAmount,
        string destinationChain,
        string destinationAccount,
        string destinationAsset
    );

    /// @notice Permit2 contract used by Atum Escrow on this source chain.
    function permit2() external view returns (address);

    /// @notice Permit2 domain separator captured at deployment.
    function permit2DomainSeparator() external view returns (bytes32);

    /// @notice Immutable PaymentRails allowed to call `execute` and receive fail-safe recovery returns.
    function paymentRails() external view returns (address);

    /// @notice Keeper that signs Permit2 digests and invalidates abandoned digests.
    function keeper() external view returns (address);

    /// @notice EIP-712 type hash for the keeper's approval of a Permit2 digest.
    /// @dev Certora M-01.
    function KEEPER_APPROVAL_TYPEHASH() external view returns (bytes32);

    /// @notice The digest the keeper must sign for `permit2Digest` to be accepted by THIS module.
    /// @dev Certora M-01. `isValidSignature` used to validate the raw hash against the keeper, and
    ///      Permit2's digest does not contain the owner, so any two modules sharing a keeper
    ///      accepted the same (hash, signature) pair -- and Permit2's nonces are per owner, so a
    ///      single authorisation could be replayed to drain each of them. Wrapping the digest in
    ///      this module's EIP-712 domain binds `address(this)` and `chainid` into what is signed.
    ///
    ///      OFF-CHAIN CONSEQUENCE: the keeper must sign THIS value, not the bare Permit2 digest.
    ///      A keeper that has not been updated produces signatures this module rejects, which
    ///      stops payments for it until the keeper is cut over. That is fail-closed, but it is a
    ///      coordinated deploy and not a drop-in.
    function keeperDigest(bytes32 permit2Digest) external view returns (bytes32);

    /// @notice Returns whether a Permit2 digest has been permanently invalidated.
    function isPermitDigestInvalidated(bytes32 digest) external view returns (bool);

    /// @notice Cumulative pending source amount per token, used to scope the Permit2 allowance.
    /// @dev Incremented by `execute`, reset to 0 by `returnTokenBalance` (which also revokes
    ///      Permit2 to 0). Monotonically increasing between recovery sweeps. The actual
    ///      pullable amount is bounded below by `IERC20.balanceOf(this)`.
    function pendingAmount(address token) external view returns (uint256);

    /// @notice Owner-only keeper rotation.
    function setKeeper(address newKeeper) external;

    /// @notice Owner-only pause.
    /// @dev While paused, `execute` is blocked, `validate` fails, ERC-1271 validation rejects
    ///      all signatures, and return-to-PaymentRails recovery is enabled.
    function pause() external;

    /// @notice Owner-only unpause after abandoned floating Permit2 digests have been invalidated or expired.
    function unpause() external;

    /// @notice Keeper- or owner-callable permanent invalidation of an abandoned Permit2 digest.
    function invalidateDigest(bytes32 digest) external;

    /// @notice Keeper- or owner-callable permanent invalidation of multiple abandoned Permit2 digests.
    function invalidateDigests(bytes32[] calldata digests) external;

    /// @notice Owner-only paused recovery that returns the full current token balance to the immutable PaymentRails.
    function returnTokenBalance(address token) external returns (uint256 amountReturned);

    /// @notice Owner-only paused recovery: returns full current balances for multiple tokens to the immutable
    /// PaymentRails.
    function returnTokenBalances(address[] calldata tokens) external;

    /// @notice ABI-encodes Atum payment params for `PaymentRails.configureToken`.
    function encodeParams(DataTypes.AtumPaymentParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes Atum payment params from `PaymentRails.configureToken`.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.AtumPaymentParams memory params);
}
