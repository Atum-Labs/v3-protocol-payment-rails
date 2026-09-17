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

        _pullExactToken(token, amount);

        // Cap the Permit2 allowance to actual cumulative pending. Each `execute`
        // grows `pendingAmount[token]`; Permit2 pulls reduce the on-chain allowance
        // as Escrow drains. `forceApprove` sets the new ceiling absolutely, so an
        // un-drained prior allowance gets bumped to the new total (not double-added).
        pendingAmount[token] += amount;
        uint256 newAllowance = pendingAmount[token];
        IERC20(token).forceApprove(permit2, newAllowance);
        emit Permit2ApprovalSet(token, permit2, newAllowance);

        uint256 availableSourceAmount = IERC20(token).balanceOf(address(this));
        emit AtumIntentCreated(
            token,
            availableSourceAmount,
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
