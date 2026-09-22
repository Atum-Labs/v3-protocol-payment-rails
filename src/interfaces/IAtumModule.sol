// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IActionModule } from "./IActionModule.sol";
import { DataTypes } from "../types/DataTypes.sol";
import { IERC1271 } from "@openzeppelin/contracts/interfaces/IERC1271.sol";

/// @title IAtumModule
/// @notice Minimal PaymentRails-bound Atum payment contract and ERC-1271 Permit2 owner.
/// @dev One module deployment is bound to one immutable PaymentRails. The PaymentRails funds the
///      contract through `execute`; the module emits the current available source
///      balance and destination details for an offchain keeper, and accepts raw Permit2
///      digests at its ERC-1271 surface. Those digests are validated as presented, against the
///      keeper alone, and only for callers in {isAuthorizedSignatureCaller} (Certora M-01).
///
///      The module does not compute request ids, source assets, fulfillment amounts,
///      or fees. The keeper derives source details from the log context and prepares
///      Atum payment requests from the module's available token balance offchain.
///
///      Failed deposits, refunds, and unused source balances remain in the module. The
///      keeper should watch {AtumIntentCreated}, Atum Escrow refund events, and module
///      token balances to initiate new payment requests from the available balance. For
///      funds that arrive outside `execute`, the keeper must call {syncAllowance} first:
///      the Permit2 allowance does not move with the balance, so an unsynced refund is
///      visible but not pullable.
interface IAtumModule is IActionModule, IERC1271 {
    /// @notice Emitted when the module approves Permit2 for a source token.
    event Permit2ApprovalSet(address indexed token, address indexed permit2, uint256 amount);

    /// @notice Emitted when the owner rotates the keeper.
    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);

    /// @notice Emitted when the keeper permanently rejects a Permit2 digest.
    event PermitDigestInvalidated(bytes32 indexed digest);

    /// @notice Emitted when a contract is authorized or de-authorized to call {isValidSignature}.
    /// @dev Also emitted from the constructor for Permit2, so the full set is recoverable from
    ///      logs alone rather than only its later edits (the shape Certora I-03 asked for).
    event SignatureCallerSet(address indexed caller, bool authorized);

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

    /// @notice Immutable PaymentRails allowed to call `execute` and receive fail-safe recovery returns.
    function paymentRails() external view returns (address);

    /// @notice Keeper that authorises Permit2 digests and invalidates abandoned ones.
    /// @dev Signs the Permit2 digest as Permit2 builds it. The module applies no wrap, so the
    ///      keeper's signing policy can still read the `PermitWitnessTransferFrom` struct it is
    ///      approving. Also the sole caller of {syncAllowance}.
    function keeper() external view returns (address);

    /// @notice Whether `caller` may receive an answer from `isValidSignature`.
    /// @dev Certora M-01. Permit2 is authorized at construction; anything else is an explicit
    ///      owner decision. An unauthorized caller gets the ERC-1271 failure value, including
    ///      an `eth_call` with no `from` -- keeper tooling that simulates must set `from` to an
    ///      authorized address or it will read a false negative.
    function isAuthorizedSignatureCaller(address caller) external view returns (bool);

    /// @notice Owner-only authorization of a contract that may call {isValidSignature}.
    /// @dev Certora M-01, and specifically the part of it that is NOT about Permit2. A keeper
    ///      signature is a bearer token at every ERC-1271 surface treating this module as a
    ///      signer, and the report is explicit that "the problem is not specific to Permit2".
    ///      Restricting the caller bounds a signature to applications that were deliberately
    ///      trusted.
    ///
    ///      IT DOES NOT FIX THE REPLAY THE FINDING DESCRIBES. Two modules sharing a keeper sit
    ///      behind the SAME Permit2, so both authorize it and both still validate the same
    ///      `(hash, signature)` pair. Only a keeper that is not shared, or a digest whose
    ///      contents name the module, prevents that -- and the contents are not visible here.
    ///
    ///      Authorizing a second application means trusting it the way Permit2 is trusted: the
    ///      keeper's signature over anything that application constructs will be honoured, and
    ///      this module cannot inspect what that is.
    function setSignatureCaller(address caller, bool authorized) external;

    /// @notice Destination route the currently-staged balance was pulled for, as
    ///         `keccak256(abi.encode(AtumPaymentParams))`. Zero when nothing is staged.
    /// @dev Certora L-04. `execute` refuses a different route while the token balance is
    ///      non-zero, because the module holds one fungible balance per token and the keeper
    ///      sweeps all of it -- so funds staged for one destination would otherwise be payable to
    ///      the next one configured. Cleared by `returnTokenBalance`.
    function stagedRoute(address token) external view returns (bytes32);

    /// @notice Re-points the Permit2 allowance at the module's current balance.
    /// @dev Keeper-only recovery path for funds that arrive outside `execute` -- Escrow refunds
    ///      and failed deposits. Without it those funds are unreachable whenever PaymentRails
    ///      has nothing left to pull, because the allowance was only ever refreshed by `execute`
    ///      (Certora L-02). Returns the new allowance, which equals the module's balance.
    ///
    ///      Callable only by the keeper and only while NOT paused, so it cannot contend with
    ///      `returnTokenBalance`, which is owner-only while paused and revokes the allowance to
    ///      zero. Does not change {stagedRoute}: it restores the allowance and does not stage a
    ///      new destination.
    function syncAllowance(address token) external returns (uint256 available);

    /// @notice Returns whether a Permit2 digest has been permanently invalidated.
    /// @dev Keyed on the digest exactly as Permit2 presents it to `isValidSignature`.
    function isPermitDigestInvalidated(bytes32 digest) external view returns (bool);

    /// @notice Source amount per token that Permit2 is currently approved to pull.
    /// @dev Set by `execute` and `syncAllowance` to the module's CURRENT balance, and reset to 0
    ///      by `returnTokenBalance` (which also revokes Permit2 to 0). It is NOT a cumulative
    ///      counter: it was one until Certora L-03/I-05, and a monotonic counter necessarily
    ///      disagrees with the balance in both directions -- too high after Permit2 pulls, too
    ///      low after a refund or a donation, the latter bricking the keeper's request against a
    ///      smaller allowance. The invariant now is
    ///      `pendingAmount(token) == IERC20(token).allowance(this, permit2) == balanceOf(this)`
    ///      as of the last `execute` or `syncAllowance`.
    function pendingAmount(address token) external view returns (uint256);

    /// @notice Owner-only keeper rotation.
    function setKeeper(address newKeeper) external;

    /// @notice Owner-only pause.
    /// @dev While paused, `execute` is blocked, `validate` fails, ERC-1271 validation rejects
    ///      all signatures, {syncAllowance} is blocked, and return-to-PaymentRails recovery is
    ///      enabled.
    function pause() external;

    /// @notice Owner-only unpause after abandoned floating Permit2 digests have been invalidated or expired.
    function unpause() external;

    /// @notice Keeper- or owner-callable permanent invalidation of an abandoned Permit2 digest.
    /// @dev Pass the Permit2 digest -- the same value Permit2 presents to `isValidSignature`.
    function invalidateDigest(bytes32 digest) external;

    /// @notice Keeper- or owner-callable permanent invalidation of multiple abandoned Permit2 digests.
    /// @dev Permit2 digests, as for {invalidateDigest}.
    function invalidateDigests(bytes32[] calldata digests) external;

    /// @notice Owner-only paused recovery that returns the full current token balance to the immutable PaymentRails.
    /// @dev Also resets {pendingAmount} and {stagedRoute} to zero and revokes the Permit2
    ///      allowance, so no recorded approval or destination outlives the funds it described.
    function returnTokenBalance(address token) external returns (uint256 amountReturned);

    /// @notice Owner-only paused recovery: returns full current balances for multiple tokens to the immutable
    /// PaymentRails.
    function returnTokenBalances(address[] calldata tokens) external;

    /// @notice ABI-encodes Atum payment params for `PaymentRails.configureToken`.
    function encodeParams(DataTypes.AtumPaymentParams calldata params) external pure returns (bytes memory encoded);

    /// @notice Decodes Atum payment params from `PaymentRails.configureToken`.
    function decodeParams(bytes calldata encoded) external pure returns (DataTypes.AtumPaymentParams memory params);
}
