// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { IAtumModule } from "../../../interfaces/IAtumModule.sol";
import { IPermit2 } from "../../../interfaces/IPermit2.sol";
import { IActionModule } from "../../../interfaces/IActionModule.sol";
import { ActionModuleBase } from "../../../abstracts/ActionModuleBase.sol";
import { DataTypes } from "../../../types/DataTypes.sol";
import { Errors } from "../../../libraries/Errors.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SignatureChecker } from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import { Ownable2Step, Ownable } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

/// @title AtumModule
/// @custom:tier contrib
/// @custom:maintainer @atum-labs (security@atumlabs.xyz)
/// @custom:audit-status unaudited
/// @notice Minimal PaymentRails-bound Atum payment contract and ERC-1271 Permit2 owner.
/// @dev Each module deployment is permanently bound to one immutable PaymentRails. The module
///      is funded by that PaymentRails through `execute`, emits the current available source
///      balance and destination details for an offchain Atum keeper, and validates
///      generic Permit2 digests by keeper signature.
///
///      The module does not call Atum Escrow, compute request ids, compute fulfillment
///      amounts, decode Atum witness data, inspect Escrow state, classify payment
///      outcomes, reserve per-payment balances, or store per-payment recovery metadata.
///      The keeper derives source chain/source asset/request id and selects fulfillment
///      terms offchain.
///
///      `execute` is a PaymentRails funding action and payment availability signal, not a
///      complete Atum payment order. It moves additional source tokens into the module
///      and emits the module's full current balance for that token. The keeper should
///      create Atum payment requests from the available source balance, not merely from
///      the amount pulled by one PaymentRails action. Failed deposits, Escrow refunds, and
///      unused source balances remain in the module and can be picked up by a later
///      keeper request.
///
///      Keeper operating flow:
///      - Watch {AtumIntentCreated}; when emitted, read/use `availableSourceAmount` and
///        prepare a payment request for the available source balance.
///      - Watch Atum Escrow refund events and module token balances; when refunded
///        funds return, initiate a new payment request for the current module balance.
///      - Invalidate abandoned floating Permit2 digests before signing replacement
///        requests when those stale digests must not remain usable.
///
///      Pause is a rare fail-safe control for return-to-PaymentRails recovery. It blocks
///      new `execute` calls and ERC-1271 validation, makes `validate` fail, and enables
///      return-to-PaymentRails recovery. It does not revoke Permit2 approvals, invalidate
///      digests permanently, block inbound refunds or direct transfers, prove refund
///      attribution, or undo already consumed Permit2 nonces.
contract AtumModule is IAtumModule, ActionModuleBase, Ownable2Step, Pausable, EIP712 {
    using SafeERC20 for IERC20;
    using SignatureChecker for address;

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev EIP-1271 magic value returned for valid signatures.
    bytes4 internal constant EIP1271_MAGIC_VALUE = 0x1626ba7e;

    /// @dev EIP-1271 failure value returned for invalid signatures.
    bytes4 internal constant EIP1271_FAILURE_VALUE = 0xffffffff;

    /*//////////////////////////////////////////////////////////////////////////
                                IMMUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModule
    address public immutable override permit2;

    /// @inheritdoc IAtumModule
    bytes32 public immutable override permit2DomainSeparator;

    /// @inheritdoc IAtumModule
    address public immutable override paymentRails;

    /*//////////////////////////////////////////////////////////////////////////
                                MUTABLE STATE
    //////////////////////////////////////////////////////////////////////////*/

    /// @inheritdoc IAtumModule
    address public override keeper;

    /// @dev Permit2 digests that must no longer satisfy ERC-1271 checks.
    /// @inheritdoc IAtumModule
    bytes32 public constant override KEEPER_APPROVAL_TYPEHASH = keccak256("AtumKeeperApproval(bytes32 permit2Digest)");

    mapping(bytes32 digest => bool invalidated) private _invalidatedPermitDigests;

    /// @inheritdoc IAtumModule
    /// @dev Cumulative source tokens routed in via `execute` minus what's been returned
    ///      to PaymentRails via `returnTokenBalance`. Used to cap the Permit2 ERC-20
    ///      allowance to actual pending instead of `type(uint256).max`. Permit2 itself
    ///      reduces the on-chain allowance as Atum Escrow pulls funds, so the *effective*
    ///      pullable amount is `min(allowance(this, permit2), balanceOf(this))`. This
    ///      value is monotonically increasing between recovery sweeps; reset only by
    ///      `returnTokenBalance` (which also revokes the Permit2 allowance to 0).
    mapping(address token => uint256 amount) public override pendingAmount;

    /// @inheritdoc IAtumModule
    mapping(address token => bytes32 route) public override stagedRoute;

    /*//////////////////////////////////////////////////////////////////////////
                                  CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    /// @param _permit2 Permit2 contract used by Atum Escrow on this source chain.
    /// @param _paymentRails Immutable PaymentRails allowed to call `execute`.
    /// @param _owner Module owner authorized to manage operations and keeper rotation.
    /// @param _keeper Keeper whose signatures validate Atum Permit2 digests.
    constructor(
        address _permit2,
        address _paymentRails,
        address _owner,
        address _keeper
    )
        Ownable(_owner)
        EIP712("AtumModule", "1")
    {
        if (_permit2 == address(0)) revert Errors.AtumModule_ZeroPermit2();
        if (_paymentRails == address(0)) revert Errors.AtumModule_ZeroPaymentRails();
        if (_keeper == address(0)) revert Errors.AtumModule_ZeroKeeper();

        permit2 = _permit2;
        paymentRails = _paymentRails;
        keeper = _keeper;
        permit2DomainSeparator = IPermit2(_permit2).DOMAIN_SEPARATOR();

        // The initial keeper is the hot key that authorises moving every token this module holds,
        // and it was previously assigned without ever being emitted (Certora I-03): `KeeperSet`
        // only fired on rotation, so an indexer reconstructing "who could sign for this module"
        // had no record of the first one. Emitting from zero makes the whole keeper history
        // recoverable from logs alone.
        emit KeeperSet(address(0), _keeper);
    }

    /// @notice Disabled: this module must always retain an owner.
    /// @dev Certora I-02. `Ownable.renounceOwnership` would set the owner to `address(0)` and
    ///      permanently disable keeper rotation, pause/unpause and `returnTokenBalance`. The
    ///      recovery path is `onlyOwner whenPaused`, so renouncing while paused and holding
    ///      tokens strands them with no way out. There is no situation in which this module
    ///      wants no owner, so the function reverts rather than being left as a footgun.
    function renounceOwnership() public view override onlyOwner {
        revert Errors.AtumModule_RenounceOwnershipDisabled();
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
        whenNotPaused
        returns (DataTypes.ExecutionResult memory result)
    {
        if (msg.sender != paymentRails) {
            revert Errors.AtumModule_NotPaymentRails(msg.sender, paymentRails);
        }

        (bool valid, string memory reason, DataTypes.AtumPaymentParams memory paymentParams) =
            _validatePaymentParams(token, amount, params);
        if (!valid) {
            return _failedResult(token, reason);
        }
        if (!_hasSufficientBalance(token, amount)) {
            return _failedResult(token, "Insufficient balance");
        }

        // Certora L-04: a route change must not silently redirect funds already staged for the
        // previous one.
        //
        // The module holds one fungible balance per token and the keeper is documented to sweep
        // ALL of it (see the note on refunds below), so tokens pulled while Route A was configured
        // are indistinguishable from tokens pulled under Route B. Change the PaymentRails config
        // between an intent and its settlement and the next intent advertises the whole balance
        // against the new destination -- including the funds staged for the old one.
        //
        // Certora's own recommendation was to emit only the newly-pulled amount, but that
        // contradicts the documented sweep the report quotes under L-02: refunds and failed
        // deposits are meant to be picked up by a later request. Both cannot hold. This keeps the
        // sweep and makes the collision impossible instead, by refusing to stage a second route
        // on top of a non-empty balance. Drain or sweep first, then reconfigure.
        //
        // Keyed on the decoded destination triple rather than the raw `params` bytes, so the guard
        // tracks the ROUTE and not its encoding.
        bytes32 routeHash = keccak256(abi.encode(paymentParams));
        bytes32 staged = stagedRoute[token];
        if (staged != bytes32(0) && staged != routeHash && IERC20(token).balanceOf(address(this)) > 0) {
            return _failedResult(token, "Route changed while funds are staged");
        }

        _pullExactToken(token, amount);
        stagedRoute[token] = routeHash;

        // ONE quantity drives the allowance, the emitted intent and `pendingAmount`: the balance
        // the module actually holds right now (Certora L-03 + I-05).
        //
        // Before this, the allowance followed a monotonic counter (`pendingAmount += amount`,
        // never decremented) while the intent followed `balanceOf`. Those are different numbers
        // and they drifted apart in BOTH directions:
        //
        //   * after Permit2 pulled, the balance dropped and the counter did not, so the module
        //     advertised an allowance over funds it no longer held;
        //   * after an Escrow refund or a 1-wei donation, the balance rose above the counter, so
        //     the keeper read the larger number off the event, requested it, and Permit2's
        //     `transferFrom` reverted against the smaller allowance -- which bricked a fresh
        //     module for the price of one wei.
        //
        // Deriving all three from the balance makes the post-condition trivially true:
        // `pendingAmount[token] == allowance(permit2) == balanceOf(this)`. A donation is then
        // harmless rather than fatal -- it is simply money the module really has, which is what
        // the sweep behaviour documented on `execute` already assumes.
        uint256 available = IERC20(token).balanceOf(address(this));
        pendingAmount[token] = available;
        IERC20(token).forceApprove(permit2, available);
        emit Permit2ApprovalSet(token, permit2, available);

        emit AtumIntentCreated(
            token,
            available,
            paymentParams.destinationChain,
            paymentParams.destinationAccount,
            paymentParams.destinationAsset
        );

        return _successResult(0, token, "");
    }

    /// @inheritdoc IAtumModule
    function setKeeper(address newKeeper) external onlyOwner {
        if (newKeeper == address(0)) revert Errors.AtumModule_ZeroKeeper();

        address oldKeeper = keeper;
        keeper = newKeeper;

        emit KeeperSet(oldKeeper, newKeeper);
    }

    /// @inheritdoc IAtumModule
    function pause() external onlyOwner {
        _pause();
    }

    /// @inheritdoc IAtumModule
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @inheritdoc IAtumModule
    /// @dev Exists because the allowance used to be reachable ONLY through `execute`, and
    ///      `execute` requires a positive pull from PaymentRails (Certora L-02). When Escrow
    ///      refunds into the module while PaymentRails is empty, there is then no way to point
    ///      Permit2 at the returned funds: the keeper can see them and cannot request them, and
    ///      the only exit is the owner pausing and sweeping everything back. That converts a
    ///      routine refund into an owner-gated incident.
    ///
    ///      `onlyKeeper`, not permissionless: raising the allowance grants nothing on its own,
    ///      since Permit2 still needs a keeper signature to move anything, but the keeper is the
    ///      party that is actually blocked and restricting it is the cheaper argument to make.
    ///      This is also the modifier's first real use -- it was dead code (Certora I-01), and
    ///      giving it a caller is a better resolution than deleting it.
    ///
    ///      `whenNotPaused` so it cannot fight `returnTokenBalance`, which is `whenPaused` and
    ///      deliberately revokes the allowance to zero.
    function syncAllowance(address token) external onlyKeeper whenNotPaused returns (uint256 available) {
        if (token == address(0)) revert Errors.AtumModule_ZeroToken();

        available = IERC20(token).balanceOf(address(this));
        pendingAmount[token] = available;
        IERC20(token).forceApprove(permit2, available);
        emit Permit2ApprovalSet(token, permit2, available);
    }

    /// @inheritdoc IAtumModule
    function invalidateDigest(bytes32 digest) external onlyKeeperOrOwner {
        _invalidateDigest(digest);
    }

    /// @inheritdoc IAtumModule
    function invalidateDigests(bytes32[] calldata digests) external onlyKeeperOrOwner {
        uint256 length = digests.length;
        for (uint256 i; i < length; ++i) {
            _invalidateDigest(digests[i]);
        }
    }

    /// @inheritdoc IAtumModule
    function returnTokenBalance(address token) external onlyOwner whenPaused returns (uint256 amountReturned) {
        amountReturned = _returnTokenBalance(token);
    }

    /// @inheritdoc IAtumModule
    function returnTokenBalances(address[] calldata tokens) external onlyOwner whenPaused {
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            _returnTokenBalance(tokens[i]);
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                            EIP-1271 SURFACE
    //////////////////////////////////////////////////////////////////////////*/

    /// @notice Validates that `signature` was signed by the module keeper for `hash`.
    function isValidSignature(bytes32 hash, bytes memory signature) external view override returns (bytes4) {
        // INVALIDATION IS KEYED ON THE RAW `hash`, NOT THE WRAPPED ONE. This is the part of the
        // M-01 fix that can silently break the kill-switch: `invalidateDigest` is called by the
        // keeper with the Permit2 digest it produced, which is exactly the value arriving here as
        // `hash`. Re-keying this lookup to the wrapped digest would leave every previously
        // invalidated digest looking un-invalidated, and this function would keep returning the
        // magic value for a digest an operator believes they revoked -- a failure that is invisible
        // until it is exploited. The pairing is pinned by test_InvalidateDigest_StillBlocks...
        if (paused() || _invalidatedPermitDigests[hash]) {
            return EIP1271_FAILURE_VALUE;
        }

        // Certora M-01: validate a MODULE-SPECIFIC digest, not the caller's raw one.
        //
        // The raw hash was checked straight against the keeper, and the hash Permit2 builds does
        // not contain the owner. Two modules sharing a keeper therefore accepted the very same
        // (hash, signature) pair, and Permit2 tracks nonces per owner, so one authorisation drained
        // both. Wrapping in this module's EIP-712 domain binds `address(this)` and `chainid` into
        // what the keeper actually signs, so a signature for module A is meaningless at module B.
        if (keeper.isValidSignatureNow(keeperDigest(hash), signature)) {
            return EIP1271_MAGIC_VALUE;
        }

        return EIP1271_FAILURE_VALUE;
    }

    /// @inheritdoc IAtumModule
    function keeperDigest(bytes32 permit2Digest) public view override returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(KEEPER_APPROVAL_TYPEHASH, permit2Digest)));
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
        if (paused()) {
            return (false, "Module paused");
        }

        (isValid, reason,) = _validatePaymentParams(token, amount, params);
        if (!isValid) {
            return (false, reason);
        }
        if (!_hasSufficientBalance(token, amount)) {
            return (false, "Insufficient balance");
        }
        return (true, "");
    }

    /// @inheritdoc IAtumModule
    function isPermitDigestInvalidated(bytes32 digest) external view returns (bool) {
        return _invalidatedPermitDigests[digest];
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
        if (paused()) {
            return (0, token);
        }

        (bool valid,,) = _validatePaymentParams(token, amount, params);
        if (!valid) {
            return (0, token);
        }

        return (0, token);
    }

    /// @inheritdoc IActionModule
    function moduleType() external pure override(ActionModuleBase, IActionModule) returns (string memory) {
        return "ATUM_PAYMENT";
    }

    /// @inheritdoc IAtumModule
    function encodeParams(DataTypes.AtumPaymentParams calldata params) external pure returns (bytes memory encoded) {
        return abi.encode(params.destinationChain, params.destinationAccount, params.destinationAsset);
    }

    /// @inheritdoc IAtumModule
    function decodeParams(bytes calldata encoded) public pure returns (DataTypes.AtumPaymentParams memory params) {
        (params.destinationChain, params.destinationAccount, params.destinationAsset) =
            abi.decode(encoded, (string, string, string));
    }

    /*//////////////////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////////////////*/

    function _validatePaymentParams(
        address token,
        uint256 amount,
        bytes calldata params
    )
        private
        view
        returns (bool valid, string memory reason, DataTypes.AtumPaymentParams memory paymentParams)
    {
        if (token == address(0)) {
            return (false, "Zero token", paymentParams);
        }
        if (amount == 0) {
            return (false, "Zero payment amount", paymentParams);
        }

        (valid, reason, paymentParams) = _decodeAndValidatePaymentParams(params);
        if (!valid) {
            return (false, reason, paymentParams);
        }

        return (true, "", paymentParams);
    }

    function _decodeAndValidatePaymentParams(bytes calldata params)
        private
        view
        returns (bool valid, string memory reason, DataTypes.AtumPaymentParams memory paymentParams)
    {
        if (params.length < 96) {
            return (false, "Invalid params encoding", paymentParams);
        }

        try this.decodeParams(params) returns (DataTypes.AtumPaymentParams memory decoded) {
            paymentParams = decoded;
        } catch {
            return (false, "Invalid params encoding", paymentParams);
        }

        if (bytes(paymentParams.destinationChain).length == 0) {
            return (false, "Empty destination chain", paymentParams);
        }
        if (bytes(paymentParams.destinationAccount).length == 0) {
            return (false, "Empty destination account", paymentParams);
        }
        if (bytes(paymentParams.destinationAsset).length == 0) {
            return (false, "Empty destination asset", paymentParams);
        }
        if (!_hasChainPrefix(paymentParams.destinationAsset, paymentParams.destinationChain)) {
            return (false, "Destination asset chain mismatch", paymentParams);
        }
        return (true, "", paymentParams);
    }

    function _pullExactToken(address token, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        // Certora I-06: the received side was checked, the SENDER side was not. A token that
        // debits the sender more than it credits the recipient -- a sender-paid fee -- leaves
        // PaymentRails down `amount + fee` while this function sees exactly `amount` arrive and
        // reports success. The loss is real and silent, and PaymentRails' own accounting then
        // understates it. Measuring both sides makes the module's "exact transfer" claim true in
        // the direction it was not.
        uint256 senderBalanceBefore = IERC20(token).balanceOf(msg.sender);
        // Route through the base class helper so error paths fall through into the
        // module's `_failedResult` / revert surface consistently (#11). The
        // exact-balance check below still defends against fee-on-transfer tokens.
        bool transferred = _safeTransferFrom(token, msg.sender, address(this), amount);
        if (!transferred) {
            revert Errors.AtumModule_UnsupportedTokenReceivedAmount(amount, 0);
        }
        uint256 received = IERC20(token).balanceOf(address(this)) - balanceBefore;
        if (received != amount) {
            revert Errors.AtumModule_UnsupportedTokenReceivedAmount(amount, received);
        }

        // Guarded: a token that mints to the sender inside `transferFrom`, or a self-transfer,
        // could leave the sender's balance level or higher. Underflow would revert opaquely.
        uint256 senderBalanceAfter = IERC20(token).balanceOf(msg.sender);
        uint256 debited = senderBalanceBefore > senderBalanceAfter ? senderBalanceBefore - senderBalanceAfter : 0;
        if (debited != amount) {
            revert Errors.AtumModule_UnsupportedTokenDebitedAmount(amount, debited);
        }
    }

    function _invalidateDigest(bytes32 digest) private {
        if (digest == bytes32(0)) revert Errors.AtumModule_ZeroDigest();

        _invalidatedPermitDigests[digest] = true;

        emit PermitDigestInvalidated(digest);
    }

    function _returnTokenBalance(address token) private returns (uint256 amountReturned) {
        if (token == address(0)) revert Errors.AtumModule_ZeroToken();

        amountReturned = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(paymentRails, amountReturned);

        // Recovery sweep clears the cumulative pending tracker and revokes the
        // Permit2 allowance so an already-signed-but-uninvalidated digest can't
        // re-pull anything that arrives later (refund, mistaken transfer).
        pendingAmount[token] = 0;
        // The balance is now zero, so the L-04 guard would pass regardless; clearing keeps the
        // recorded route from outliving the funds it described.
        stagedRoute[token] = bytes32(0);
        IERC20(token).forceApprove(permit2, 0);
        emit Permit2ApprovalSet(token, permit2, 0);

        emit TokenBalanceReturned(token, paymentRails, amountReturned);
    }

    function _hasChainPrefix(string memory asset, string memory chain) private pure returns (bool) {
        bytes memory assetBytes = bytes(asset);
        bytes memory chainBytes = bytes(chain);

        if (chainBytes.length == 0 || assetBytes.length <= chainBytes.length || assetBytes[chainBytes.length] != "/") {
            return false;
        }

        for (uint256 i; i < chainBytes.length; ++i) {
            if (assetBytes[i] != chainBytes[i]) {
                return false;
            }
        }

        return true;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert Errors.AtumModule_NotKeeper(msg.sender, keeper);
        _;
    }

    /// @dev Owner already has stronger powers (`pause`, `setKeeper`, `returnTokenBalance`);
    ///      digest invalidation belongs in the same trust tier so the owner doesn't have
    ///      to rotate the keeper just to cancel a stale digest.
    modifier onlyKeeperOrOwner() {
        if (msg.sender != keeper && msg.sender != owner()) {
            revert Errors.AtumModule_NotKeeper(msg.sender, keeper);
        }
        _;
    }
}
