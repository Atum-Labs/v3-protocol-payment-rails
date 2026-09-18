// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { PaymentRails } from "../../../../../../src/core/PaymentRails.sol";
import { AtumModule } from "../../../../../../src/modules/contrib/bridges/AtumModule.sol";
import { DataTypes } from "../../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { MockERC20 } from "../../../../../shared/mocks/MockERC20.sol";
import { FeeOnTransferERC20 } from "../../../../../shared/mocks/FeeOnTransferERC20.sol";
import { SenderFeeERC20 } from "../../../../../shared/mocks/SenderFeeERC20.sol";
import { MockPermit2 } from "../../../../../shared/mocks/atum/MockPermit2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";

contract AtumModuleIntegrationTest is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event ActionExecuted(
        address indexed token,
        string actionType,
        uint256 amountIn,
        uint256 amountOut,
        address outputToken,
        address indexed executor
    );

    event KeeperSet(address indexed oldKeeper, address indexed newKeeper);

    event PermitDigestInvalidated(bytes32 indexed digest);

    event TokenBalanceReturned(address indexed token, address indexed paymentRails, uint256 amount);

    event AtumIntentCreated(
        address indexed token,
        uint256 availableSourceAmount,
        string destinationChain,
        string destinationAccount,
        string destinationAsset
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    bytes4 internal constant EIP1271_MAGIC = 0x1626ba7e;
    bytes4 internal constant EIP1271_FAILURE = 0xffffffff;

    bytes32 internal constant PERMIT2_DOMAIN_SEPARATOR = keccak256("mock permit2 domain");

    uint256 internal constant MODULE_OWNER_PK = 0xA11CE;
    uint256 internal constant KEEPER_PK = 0xA71A;
    uint256 internal constant NEW_KEEPER_PK = 0xA71B;
    uint256 internal constant PAYMENT_AMOUNT = 1000e6;
    uint256 internal constant ESCROW_PULL_AMOUNT = 900e6;
    uint256 internal constant MIN_BALANCE = 100e6;

    string internal constant DESTINATION_CHAIN = "eip155:8453";
    string internal constant DESTINATION_ACCOUNT = "0x1111111111111111111111111111111111111111";
    string internal constant DESTINATION_ASSET = "eip155:8453/erc20:0x2222222222222222222222222222222222222222";

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    PaymentRails internal nodeContract;
    AtumModule internal module;
    MockPermit2 internal permit2;
    MockERC20 internal sourceToken;
    MockERC20 internal secondToken;
    FeeOnTransferERC20 internal feeToken;
    SenderFeeERC20 internal senderFeeToken;

    address internal nodeOwner;
    address internal moduleOwner;
    address internal keeper;
    address internal newKeeper;
    address internal executor;
    address internal escrow;

    /*//////////////////////////////////////////////////////////////////////////
                                    SET UP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public {
        nodeOwner = makeAddr("nodeOwner");
        moduleOwner = vm.addr(MODULE_OWNER_PK);
        keeper = vm.addr(KEEPER_PK);
        newKeeper = vm.addr(NEW_KEEPER_PK);
        executor = makeAddr("executor");
        escrow = makeAddr("escrow");

        permit2 = new MockPermit2(PERMIT2_DOMAIN_SEPARATOR);
        nodeContract = new PaymentRails(nodeOwner);
        module = new AtumModule(address(permit2), address(nodeContract), moduleOwner, keeper);

        sourceToken = new MockERC20("Source Token", "SRC");
        secondToken = new MockERC20("Second Token", "TWO");
        feeToken = new FeeOnTransferERC20();
        senderFeeToken = new SenderFeeERC20();

        bytes memory moduleParams = _defaultEncodedParams();
        vm.prank(nodeOwner);
        nodeContract.configureToken(
            address(sourceToken), "ATUM_PAYMENT", address(module), MIN_BALANCE, moduleParams, true
        );

        sourceToken.mint(address(nodeContract), PAYMENT_AMOUNT * 4);
        feeToken.mint(address(nodeContract), PAYMENT_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////////////////
                        CERTORA AUDIT REGRESSIONS (DRAFT, SEP 2026)
    //////////////////////////////////////////////////////////////////////////*/

    /// I-05. One wei, sent by anyone, used to brick a fresh module.
    ///
    /// The allowance followed `pendingAmount` (the sum of amounts pulled through `execute`) while
    /// the emitted intent followed `balanceOf`. A donation lands in the balance and not in the
    /// counter, so the keeper read the larger number off the event, asked Permit2 for it, and the
    /// pull reverted against the smaller allowance -- for every payment, until an owner swept.
    ///
    /// The assertion that matters is the last one: the amount advertised in the intent must be
    /// pullable. Under the old code it was not.
    function test_ExecuteAction_DonatedWeiDoesNotBrickTheIntent() external {
        sourceToken.mint(address(module), 1);

        uint256 expected = PAYMENT_AMOUNT + 1;

        vm.expectEmit(true, false, false, true);
        emit AtumIntentCreated(
            address(sourceToken), expected, DESTINATION_CHAIN, DESTINATION_ACCOUNT, DESTINATION_ASSET
        );

        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));

        assertEq(sourceToken.balanceOf(address(module)), expected, "balance");
        assertEq(sourceToken.allowance(address(module), address(permit2)), expected, "allowance");
        assertEq(module.pendingAmount(address(sourceToken)), expected, "pendingAmount");

        // The whole point: what the intent advertised is actually pullable.
        permit2.pull(address(sourceToken), address(module), escrow, expected);
        assertEq(sourceToken.balanceOf(escrow), expected);
    }

    /// L-03. `pendingAmount` was never decremented when Permit2 spent, so the allowance drifted
    /// above the funds the module still held. After a pull, a second execute must approve what
    /// the module has -- not the historical total.
    function test_ExecuteAction_AllowanceFollowsBalanceAfterEscrowPull() external {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));

        permit2.pull(address(sourceToken), address(module), escrow, ESCROW_PULL_AMOUNT);

        uint256 remaining = PAYMENT_AMOUNT - ESCROW_PULL_AMOUNT;
        assertEq(sourceToken.balanceOf(address(module)), remaining, "balance after pull");

        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));

        uint256 expected = remaining + PAYMENT_AMOUNT;
        assertEq(sourceToken.balanceOf(address(module)), expected, "balance");
        // Cumulative would be PAYMENT_AMOUNT * 2 here, which the module does not hold.
        assertEq(sourceToken.allowance(address(module), address(permit2)), expected, "allowance");
        assertEq(module.pendingAmount(address(sourceToken)), expected, "pendingAmount");
    }

    /// I-03. The first keeper -- the key that authorises moving every token the module holds --
    /// was assigned without ever being emitted, so logs alone could not answer who could sign.
    function test_Constructor_EmitsInitialKeeper() external {
        vm.expectEmit(true, true, false, false);
        emit KeeperSet(address(0), keeper);

        new AtumModule(address(permit2), address(nodeContract), moduleOwner, keeper);
    }

    /// I-02. Renouncing strands every recovery path: keeper rotation, pause/unpause and the
    /// `onlyOwner whenPaused` sweep all require an owner.
    function test_RenounceOwnership_Reverts() external {
        vm.expectRevert(Errors.AtumModule_RenounceOwnershipDisabled.selector);
        vm.prank(moduleOwner);
        module.renounceOwnership();

        assertEq(module.owner(), moduleOwner, "owner unchanged");
    }

    /// I-06. `_pullExactToken` verified what ARRIVED and not what was DEBITED, so a token that
    /// charges its fee to the sender passed the check: the module received exactly `amount`,
    /// reported success, and PaymentRails was quietly down `amount + fee`. The existing
    /// FeeOnTransferERC20 case does not cover this -- it shorts the recipient, which the received
    /// check already caught. This one credits the recipient in full.
    function test_ExecuteAction_RevertsWhenSenderPaysTheTransferFee() external {
        senderFeeToken.mint(address(nodeContract), PAYMENT_AMOUNT * 2);

        bytes memory encoded = _defaultEncodedParams();
        vm.prank(nodeOwner);
        nodeContract.configureToken(
            address(senderFeeToken), "ATUM_PAYMENT", address(module), MIN_BALANCE, encoded, true
        );

        uint256 railsBefore = senderFeeToken.balanceOf(address(nodeContract));

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(senderFeeToken), PAYMENT_AMOUNT);

        assertFalse(success, "a sender-paid fee must not read as an exact transfer");
        assertEq(senderFeeToken.balanceOf(address(module)), 0, "module holds nothing");
        assertEq(senderFeeToken.balanceOf(address(nodeContract)), railsBefore, "rails lost nothing");
    }

    /// L-04. A route change must not redirect funds already staged for the previous route.
    ///
    /// The module holds one fungible balance per token and the keeper sweeps all of it, so
    /// reconfiguring PaymentRails between an intent and its settlement used to make the whole
    /// balance -- including tokens staged for Route A -- payable to Route B. Nothing on chain
    /// recorded which route the staged funds belonged to.
    function test_ExecuteAction_RefusesNewRouteWhileFundsAreStaged() external {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));
        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT, "route A staged");

        _configureRouteB();

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT);

        assertFalse(success, "route B must not stage on top of route A funds");
        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT, "no extra funds pulled");
        assertEq(module.stagedRoute(address(sourceToken)), _routeHash(_defaultParams()), "route A still staged");
    }

    /// The guard is scoped to staged funds, not to route changes as such. Once the balance is
    /// drained the module is free to take the new route -- otherwise this would be a permanent
    /// lock rather than an ordering constraint.
    function test_ExecuteAction_AllowsNewRouteOnceBalanceIsDrained() external {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));
        permit2.pull(address(sourceToken), address(module), escrow, PAYMENT_AMOUNT);
        assertEq(sourceToken.balanceOf(address(module)), 0, "drained");

        DataTypes.AtumPaymentParams memory routeB = _configureRouteB();

        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT), "route B allowed once empty");
        assertEq(module.stagedRoute(address(sourceToken)), _routeHash(routeB), "route B staged");
    }

    /// Repeating the SAME route must keep working -- the guard compares routes, not call counts.
    function test_ExecuteAction_SameRouteStagesRepeatedly() external {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));

        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT * 2);
        assertEq(module.stagedRoute(address(sourceToken)), _routeHash(_defaultParams()));
    }

    /// The recovery sweep empties the module, so the recorded route must not outlive the funds.
    function test_ReturnTokenBalance_ClearsStagedRoute() external {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));
        assertTrue(module.stagedRoute(address(sourceToken)) != bytes32(0), "staged");

        vm.prank(moduleOwner);
        module.pause();
        vm.prank(moduleOwner);
        module.returnTokenBalance(address(sourceToken));

        assertEq(module.stagedRoute(address(sourceToken)), bytes32(0), "cleared with the funds");
    }

    /// L-02. A refund that arrives while PaymentRails is empty used to be unreachable: the
    /// allowance was only refreshed by `execute`, and `execute` needs a positive pull.
    function test_SyncAllowance_RecoversRefundWhenPaymentRailsIsEmpty() external {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));
        permit2.pull(address(sourceToken), address(module), escrow, PAYMENT_AMOUNT);

        // Escrow refunds straight back to the module, and PaymentRails has nothing left to pull.
        vm.prank(escrow);
        sourceToken.transfer(address(module), PAYMENT_AMOUNT);
        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT, "refund landed");
        assertEq(sourceToken.allowance(address(module), address(permit2)), 0, "allowance consumed");

        vm.prank(keeper);
        uint256 available = module.syncAllowance(address(sourceToken));

        assertEq(available, PAYMENT_AMOUNT);
        assertEq(sourceToken.allowance(address(module), address(permit2)), PAYMENT_AMOUNT, "resynced");
        assertEq(module.pendingAmount(address(sourceToken)), PAYMENT_AMOUNT);

        // Reachable again without the owner pausing and sweeping.
        permit2.pull(address(sourceToken), address(module), escrow, PAYMENT_AMOUNT);
        assertEq(sourceToken.balanceOf(address(module)), 0, "refund reclaimed without an owner sweep");
    }

    function test_SyncAllowance_RevertsWhenCallerIsNotKeeper() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.AtumModule_NotKeeper.selector, moduleOwner, keeper));
        vm.prank(moduleOwner);
        module.syncAllowance(address(sourceToken));
    }

    function test_SyncAllowance_RevertsWhenPaused() external {
        vm.prank(moduleOwner);
        module.pause();

        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(keeper);
        module.syncAllowance(address(sourceToken));
    }

    function test_SyncAllowance_RevertsWhenTokenIsZero() external {
        vm.expectRevert(Errors.AtumModule_ZeroToken.selector);
        vm.prank(keeper);
        module.syncAllowance(address(0));
    }

    /// M-01, the finding itself. An authorisation for one module must be worthless at another
    /// module sharing the same keeper.
    ///
    /// isValidSignature validated the caller's raw hash straight against the keeper, and the
    /// digest Permit2 builds does not contain the owner. Two modules with a common keeper
    /// therefore accepted the identical (hash, signature) pair -- and because Permit2 tracks
    /// nonces per owner, the same authorisation could be spent once at each. One signature, two
    /// drains.
    function test_IsValidSignature_SignatureForOneModuleIsRejectedByAnother() external {
        AtumModule otherModule = new AtumModule(address(permit2), address(nodeContract), moduleOwner, keeper);

        bytes32 permit2Digest = keccak256("shared permit2 digest");
        bytes memory signature = _signAsKeeper(KEEPER_PK, permit2Digest);

        assertEq(module.isValidSignature(permit2Digest, signature), EIP1271_MAGIC, "valid at its own module");
        assertEq(
            otherModule.isValidSignature(permit2Digest, signature),
            EIP1271_FAILURE,
            "same keeper, different module: replay must not validate"
        );

        // The exact shape that replayed: a signature over the RAW Permit2 digest. That digest is
        // byte-identical for both modules because it does not name the owner, so before the fix
        // BOTH of these returned the magic value off one keeper signature. Both must now refuse.
        bytes memory rawSignature = _sign(KEEPER_PK, permit2Digest);
        assertEq(module.isValidSignature(permit2Digest, rawSignature), EIP1271_FAILURE, "raw at module A");
        assertEq(otherModule.isValidSignature(permit2Digest, rawSignature), EIP1271_FAILURE, "raw at module B");
    }

    /// The other half of M-01: the wrap must actually be required. A keeper that still signs the
    /// bare Permit2 digest is rejected -- fail-closed, and the reason the keeper has to be cut
    /// over in lockstep with this deployment.
    function test_IsValidSignature_RejectsRawPermit2Digest() external view {
        bytes32 permit2Digest = keccak256("some permit2 digest");

        assertEq(module.isValidSignature(permit2Digest, _sign(KEEPER_PK, permit2Digest)), EIP1271_FAILURE);
        assertEq(module.isValidSignature(permit2Digest, _signAsKeeper(KEEPER_PK, permit2Digest)), EIP1271_MAGIC);
    }

    /// The trap inside the M-01 fix. `invalidateDigest` is called with the PERMIT2 digest, which
    /// is what arrives at isValidSignature as `hash`; the wrap changes what is VALIDATED but must
    /// not change what is looked up. Key the invalidation map on the wrapped digest instead and
    /// every previously revoked digest silently becomes live again, while still returning the
    /// magic value -- invisible until exploited.
    function test_InvalidateDigest_StillBlocksAfterTheEIP712Wrap() external {
        bytes32 permit2Digest = keccak256("digest to revoke");
        bytes memory signature = _signAsKeeper(KEEPER_PK, permit2Digest);
        assertEq(module.isValidSignature(permit2Digest, signature), EIP1271_MAGIC, "valid first");

        vm.prank(keeper);
        module.invalidateDigest(permit2Digest);

        assertEq(
            module.isValidSignature(permit2Digest, signature),
            EIP1271_FAILURE,
            "revocation must survive the wrap, keyed on the raw Permit2 digest"
        );
        assertTrue(module.isPermitDigestInvalidated(permit2Digest));
    }

    /// The domain must bind this module's address, which is what makes the replay above fail.
    function test_KeeperDigest_IsModuleSpecific() external {
        AtumModule otherModule = new AtumModule(address(permit2), address(nodeContract), moduleOwner, keeper);
        bytes32 permit2Digest = keccak256("digest");

        assertTrue(
            module.keeperDigest(permit2Digest) != otherModule.keeperDigest(permit2Digest),
            "two modules must not ask for the same signature"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////////////////*/

    function test_Constructor_StoresImmutableState() external view {
        assertEq(module.permit2(), address(permit2));
        assertEq(module.permit2DomainSeparator(), PERMIT2_DOMAIN_SEPARATOR);
        assertEq(module.paymentRails(), address(nodeContract));
        assertEq(module.owner(), moduleOwner);
        assertEq(module.keeper(), keeper);
        assertFalse(module.paused());
    }

    function test_Constructor_RevertsWhenPermit2IsZero() external {
        vm.expectRevert(Errors.AtumModule_ZeroPermit2.selector);
        new AtumModule(address(0), address(nodeContract), moduleOwner, keeper);
    }

    function test_Constructor_RevertsWhenNodeIsZero() external {
        vm.expectRevert(Errors.AtumModule_ZeroPaymentRails.selector);
        new AtumModule(address(permit2), address(0), moduleOwner, keeper);
    }

    function test_Constructor_RevertsWhenKeeperIsZero() external {
        vm.expectRevert(Errors.AtumModule_ZeroKeeper.selector);
        new AtumModule(address(permit2), address(nodeContract), moduleOwner, address(0));
    }

    function test_Constructor_RevertsWhenOwnerIsZero() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AtumModule(address(permit2), address(nodeContract), address(0), keeper);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            MODULE METADATA / PARAMS
    //////////////////////////////////////////////////////////////////////////*/

    function test_ModuleType_ReturnsAtumPayment() external view {
        assertEq(module.moduleType(), "ATUM_PAYMENT");
    }

    function test_EncodeDecodeParams_RoundTrip() external view {
        bytes memory encoded = module.encodeParams(_defaultParams());
        DataTypes.AtumPaymentParams memory decoded = module.decodeParams(encoded);

        assertEq(decoded.destinationChain, DESTINATION_CHAIN);
        assertEq(decoded.destinationAccount, DESTINATION_ACCOUNT);
        assertEq(decoded.destinationAsset, DESTINATION_ASSET);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                EXECUTE / INTENT
    //////////////////////////////////////////////////////////////////////////*/

    function test_ExecuteAction_FundsModuleAndEmitsIntent() external {
        vm.expectEmit(true, false, false, true);
        emit AtumIntentCreated(
            address(sourceToken), PAYMENT_AMOUNT, DESTINATION_CHAIN, DESTINATION_ACCOUNT, DESTINATION_ASSET
        );

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT);

        assertTrue(success);
        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT);
        // Permit2 allowance is scoped to the module's available balance, not type(uint256).max.
        assertEq(sourceToken.allowance(address(module), address(permit2)), PAYMENT_AMOUNT);
        assertEq(module.pendingAmount(address(sourceToken)), PAYMENT_AMOUNT);
    }

    function test_ExecuteAction_ScopesPermit2ApprovalToAvailableBalance() external {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));

        assertEq(sourceToken.allowance(address(module), address(permit2)), PAYMENT_AMOUNT);
        assertEq(module.pendingAmount(address(sourceToken)), PAYMENT_AMOUNT);

        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));

        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT * 2);
        // With nothing pulled in between, the balance IS the sum of both executes.
        assertEq(sourceToken.allowance(address(module), address(permit2)), PAYMENT_AMOUNT * 2);
        assertEq(module.pendingAmount(address(sourceToken)), PAYMENT_AMOUNT * 2);
    }

    function test_ExecuteAction_IntentUsesFullAvailableModuleBalance() external {
        uint256 existingBalance = 123e6;
        sourceToken.mint(address(module), existingBalance);

        vm.expectEmit(true, false, false, true);
        emit AtumIntentCreated(
            address(sourceToken),
            existingBalance + PAYMENT_AMOUNT,
            DESTINATION_CHAIN,
            DESTINATION_ACCOUNT,
            DESTINATION_ASSET
        );

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT);

        assertTrue(success);
        assertEq(sourceToken.balanceOf(address(module)), existingBalance + PAYMENT_AMOUNT);
    }

    function test_NodeEmitsActionExecutedWithAsyncPendingAmountOut() external {
        vm.expectEmit(true, false, false, true);
        emit ActionExecuted(address(sourceToken), "ATUM_PAYMENT", PAYMENT_AMOUNT, 0, address(sourceToken), executor);

        vm.prank(executor);
        nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT);
    }

    function test_PermissionlessNodeExecution_AnyCallerCanCreateIntent() external {
        address randomExecutor = makeAddr("randomExecutor");

        vm.prank(randomExecutor);
        bool success = nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT);

        assertTrue(success);
        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT);
    }

    function test_Execute_RevertsWhenCallerIsNotImmutableNode() external {
        bytes memory moduleParams = _defaultEncodedParams();

        vm.expectRevert(
            abi.encodeWithSelector(Errors.AtumModule_NotPaymentRails.selector, executor, address(nodeContract))
        );

        vm.prank(executor);
        module.execute(address(sourceToken), PAYMENT_AMOUNT, moduleParams);
    }

    function test_WhenSharedWithDifferentNode_ExecutionReturnsFalse() external {
        PaymentRails otherNode = new PaymentRails(nodeOwner);
        sourceToken.mint(address(otherNode), PAYMENT_AMOUNT);

        bytes memory moduleParams = _defaultEncodedParams();
        vm.prank(nodeOwner);
        otherNode.configureToken(address(sourceToken), "ATUM_PAYMENT", address(module), MIN_BALANCE, moduleParams, true);

        vm.prank(executor);
        bool success = otherNode.executeAction(address(sourceToken), PAYMENT_AMOUNT);

        assertFalse(success);
        assertEq(sourceToken.balanceOf(address(otherNode)), PAYMENT_AMOUNT);
        assertEq(sourceToken.balanceOf(address(module)), 0);
    }

    function test_WhenPaused_ExecuteActionReturnsFalseAndStoresNoFunds() external {
        vm.prank(moduleOwner);
        module.pause();

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT);

        assertFalse(success);
        assertEq(sourceToken.balanceOf(address(nodeContract)), PAYMENT_AMOUNT * 4);
        assertEq(sourceToken.balanceOf(address(module)), 0);
    }

    function test_Execute_ReturnsFailedResultWhenImmutableNodeHasInsufficientBalance() external {
        DataTypes.ExecutionResult memory result =
            _executeFromNode(address(sourceToken), PAYMENT_AMOUNT * 10, _defaultEncodedParams());

        _assertFailedResult(result, address(sourceToken), "Insufficient balance");
        assertEq(sourceToken.balanceOf(address(module)), 0);
    }

    function test_PreviewExecution_UsesSourceTokenAndAsyncPendingAmountOut() external view {
        (uint256 estimatedOutput, address outputToken) = nodeContract.previewExecution(address(sourceToken));

        assertEq(estimatedOutput, 0);
        assertEq(outputToken, address(sourceToken));
    }

    function test_EstimateOutput_WhenPaused_ReturnsZeroAndSourceToken() external {
        vm.prank(moduleOwner);
        module.pause();

        (uint256 estimatedOutput, address outputToken) =
            module.estimateOutput(address(sourceToken), PAYMENT_AMOUNT, _defaultEncodedParams());

        assertEq(estimatedOutput, 0);
        assertEq(outputToken, address(sourceToken));
    }

    function test_EstimateOutput_WhenParamsInvalid_ReturnsZeroAndSourceToken() external view {
        (uint256 estimatedOutput, address outputToken) =
            module.estimateOutput(address(sourceToken), PAYMENT_AMOUNT, _shortEncodedParams());

        assertEq(estimatedOutput, 0);
        assertEq(outputToken, address(sourceToken));
    }

    function test_OwnerCanRotateKeeper() external {
        vm.expectEmit(true, true, false, true);
        emit KeeperSet(keeper, newKeeper);

        vm.prank(moduleOwner);
        module.setKeeper(newKeeper);

        assertEq(module.keeper(), newKeeper);

        bytes32 digest = keccak256("permit2 digest");
        assertEq(module.isValidSignature(digest, _signAsKeeper(KEEPER_PK, digest)), EIP1271_FAILURE);
        assertEq(module.isValidSignature(digest, _signAsKeeper(NEW_KEEPER_PK, digest)), EIP1271_MAGIC);
    }

    function test_SetKeeper_RevertsWhenNewKeeperIsZero() external {
        vm.expectRevert(Errors.AtumModule_ZeroKeeper.selector);

        vm.prank(moduleOwner);
        module.setKeeper(address(0));
    }

    function test_WhenFeeOnTransferToken_ExecutionReturnsFalseAndStoresNoFunds() external {
        bytes memory moduleParams = _defaultEncodedParams();
        vm.prank(nodeOwner);
        nodeContract.configureToken(address(feeToken), "ATUM_PAYMENT", address(module), MIN_BALANCE, moduleParams, true);

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(feeToken), PAYMENT_AMOUNT);

        assertFalse(success);
        assertEq(feeToken.balanceOf(address(nodeContract)), PAYMENT_AMOUNT);
        assertEq(feeToken.balanceOf(address(module)), 0);
    }

    function test_WhenDestinationAssetChainMismatch_ExecutionReturnsFalseAndStoresNoFunds() external {
        DataTypes.AtumPaymentParams memory params = _defaultParams();
        params.destinationChain = "eip155:1";
        bytes memory moduleParams = module.encodeParams(params);

        vm.prank(nodeOwner);
        nodeContract.configureToken(
            address(sourceToken), "ATUM_PAYMENT", address(module), MIN_BALANCE, moduleParams, true
        );

        vm.prank(executor);
        bool success = nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT);

        assertFalse(success);
        assertEq(sourceToken.balanceOf(address(nodeContract)), PAYMENT_AMOUNT * 4);
        assertEq(sourceToken.balanceOf(address(module)), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    VALIDATE
    //////////////////////////////////////////////////////////////////////////*/

    function test_Validate_WhenPaused_ReturnsModulePaused() external {
        vm.prank(moduleOwner);
        module.pause();

        _assertValidate(address(sourceToken), PAYMENT_AMOUNT, _defaultEncodedParams(), false, "Module paused");
    }

    function test_Validate_WhenNodeHasInsufficientBalance_ReturnsInsufficientBalance() external {
        _assertValidate(
            address(sourceToken), PAYMENT_AMOUNT * 10, _defaultEncodedParams(), false, "Insufficient balance"
        );
    }

    function test_Validate_WhenTokenIsZero_ReturnsZeroToken() external {
        _assertValidate(address(0), PAYMENT_AMOUNT, _defaultEncodedParams(), false, "Zero token");
    }

    function test_Validate_WhenAmountIsZero_ReturnsZeroPaymentAmount() external {
        _assertValidate(address(sourceToken), 0, _defaultEncodedParams(), false, "Zero payment amount");
    }

    function test_Validate_WhenParamsEncodingIsShort_ReturnsInvalidParamsEncoding() external {
        _assertValidate(address(sourceToken), PAYMENT_AMOUNT, _shortEncodedParams(), false, "Invalid params encoding");
    }

    function test_Validate_WhenParamsEncodingIsMalformed_ReturnsInvalidParamsEncoding() external {
        _assertValidate(
            address(sourceToken), PAYMENT_AMOUNT, _malformedEncodedParams(), false, "Invalid params encoding"
        );
    }

    function test_Validate_WhenDestinationChainIsEmpty_ReturnsEmptyDestinationChain() external {
        DataTypes.AtumPaymentParams memory params = _defaultParams();
        params.destinationChain = "";

        _assertValidate(
            address(sourceToken), PAYMENT_AMOUNT, module.encodeParams(params), false, "Empty destination chain"
        );
    }

    function test_Validate_WhenDestinationAccountIsEmpty_ReturnsEmptyDestinationAccount() external {
        DataTypes.AtumPaymentParams memory params = _defaultParams();
        params.destinationAccount = "";

        _assertValidate(
            address(sourceToken), PAYMENT_AMOUNT, module.encodeParams(params), false, "Empty destination account"
        );
    }

    function test_Validate_WhenDestinationAssetIsEmpty_ReturnsEmptyDestinationAsset() external {
        DataTypes.AtumPaymentParams memory params = _defaultParams();
        params.destinationAsset = "";

        _assertValidate(
            address(sourceToken), PAYMENT_AMOUNT, module.encodeParams(params), false, "Empty destination asset"
        );
    }

    function test_Validate_WhenDestinationAssetHasNoChainSeparator_ReturnsDestinationAssetChainMismatch() external {
        DataTypes.AtumPaymentParams memory params = _defaultParams();
        params.destinationAsset = DESTINATION_CHAIN;

        _assertValidate(
            address(sourceToken), PAYMENT_AMOUNT, module.encodeParams(params), false, "Destination asset chain mismatch"
        );
    }

    function test_Validate_WhenDestinationAssetChainHasSameLengthButDifferentValue_ReturnsDestinationAssetChainMismatch()
        external
    {
        DataTypes.AtumPaymentParams memory params = _defaultParams();
        params.destinationChain = "eip155:9453";

        _assertValidate(
            address(sourceToken), PAYMENT_AMOUNT, module.encodeParams(params), false, "Destination asset chain mismatch"
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                ERC-1271
    //////////////////////////////////////////////////////////////////////////*/

    function test_IsValidSignature_WhenKeeperSignedDigest_ReturnsMagicValue() external view {
        bytes32 digest = keccak256("permit2 digest");
        bytes memory signature = _signAsKeeper(KEEPER_PK, digest);

        assertEq(module.isValidSignature(digest, signature), EIP1271_MAGIC);
    }

    function test_IsValidSignature_WhenOwnerSignedDigest_ReturnsFailureValue() external view {
        bytes32 digest = keccak256("permit2 digest");
        bytes memory signature = _sign(MODULE_OWNER_PK, digest);

        assertEq(module.isValidSignature(digest, signature), EIP1271_FAILURE);
    }

    function test_IsValidSignature_WhenPaused_ReturnsFailureValue() external {
        bytes32 digest = keccak256("permit2 digest");
        bytes memory signature = _signAsKeeper(KEEPER_PK, digest);

        vm.prank(moduleOwner);
        module.pause();

        assertEq(module.isValidSignature(digest, signature), EIP1271_FAILURE);
    }

    function test_OwnerCanUnpauseAndResumeSignatureValidationAndExecution() external {
        bytes32 digest = keccak256("permit2 digest");
        bytes memory signature = _signAsKeeper(KEEPER_PK, digest);

        vm.prank(moduleOwner);
        module.pause();

        assertTrue(module.paused());
        assertEq(module.isValidSignature(digest, signature), EIP1271_FAILURE);

        vm.prank(moduleOwner);
        module.unpause();

        assertFalse(module.paused());
        assertEq(module.isValidSignature(digest, signature), EIP1271_MAGIC);

        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));
    }

    function test_InvalidateDigest_MakesPreviouslyValidSignatureFail() external {
        bytes32 digest = keccak256("permit2 digest");
        bytes memory signature = _signAsKeeper(KEEPER_PK, digest);

        assertEq(module.isValidSignature(digest, signature), EIP1271_MAGIC);

        vm.expectEmit(true, false, false, true);
        emit PermitDigestInvalidated(digest);

        vm.prank(keeper);
        module.invalidateDigest(digest);

        assertTrue(module.isPermitDigestInvalidated(digest));
        assertEq(module.isValidSignature(digest, signature), EIP1271_FAILURE);
    }

    function test_InvalidateDigests_InvalidatesMultipleDigests() external {
        bytes32 firstDigest = keccak256("first digest");
        bytes32 secondDigest = keccak256("second digest");
        bytes32[] memory digests = new bytes32[](2);
        digests[0] = firstDigest;
        digests[1] = secondDigest;

        vm.prank(keeper);
        module.invalidateDigests(digests);

        assertTrue(module.isPermitDigestInvalidated(firstDigest));
        assertTrue(module.isPermitDigestInvalidated(secondDigest));
    }

    function test_InvalidateDigests_WhenBatchIsEmpty_DoesNothing() external {
        bytes32 digest = keccak256("unrelated digest");
        bytes32[] memory digests = new bytes32[](0);

        vm.prank(keeper);
        module.invalidateDigests(digests);

        assertFalse(module.isPermitDigestInvalidated(digest));
    }

    function test_InvalidateDigest_RevertsWhenDigestIsZero() external {
        vm.expectRevert(Errors.AtumModule_ZeroDigest.selector);

        vm.prank(keeper);
        module.invalidateDigest(bytes32(0));
    }

    function test_InvalidateDigest_RevertsWhenCallerIsNotKeeperOrOwner() external {
        bytes32 digest = keccak256("permit2 digest");
        address stranger = makeAddr("stranger");

        vm.expectRevert(abi.encodeWithSelector(Errors.AtumModule_NotKeeper.selector, stranger, keeper));

        vm.prank(stranger);
        module.invalidateDigest(digest);
    }

    function test_InvalidateDigest_OwnerCanInvalidate() external {
        bytes32 digest = keccak256("permit2 digest");

        vm.prank(moduleOwner);
        module.invalidateDigest(digest);

        assertTrue(module.isPermitDigestInvalidated(digest));
    }

    function testFuzz_IsValidSignature_NeverReverts(bytes32 digest, bytes calldata signature) external {
        try module.isValidSignature(digest, signature) returns (bytes4 result) {
            assertTrue(result == EIP1271_MAGIC || result == EIP1271_FAILURE);
        } catch {
            fail("isValidSignature must not revert");
        }
    }

    /*//////////////////////////////////////////////////////////////////////////
                              FAIL-SAFE RECOVERY
    //////////////////////////////////////////////////////////////////////////*/

    function test_ReturnTokenBalance_ReturnsFullBalanceToImmutableNodeOnly() external givenFundedModule {
        uint256 unusedBalance = 17e6;
        sourceToken.mint(address(module), unusedBalance);

        vm.prank(moduleOwner);
        module.pause();

        uint256 nodeBalanceBefore = sourceToken.balanceOf(address(nodeContract));
        uint256 ownerBalanceBefore = sourceToken.balanceOf(moduleOwner);

        vm.expectEmit(true, true, false, true);
        emit TokenBalanceReturned(address(sourceToken), address(nodeContract), PAYMENT_AMOUNT + unusedBalance);

        vm.prank(moduleOwner);
        uint256 amountReturned = module.returnTokenBalance(address(sourceToken));

        assertEq(amountReturned, PAYMENT_AMOUNT + unusedBalance);
        assertEq(sourceToken.balanceOf(address(module)), 0);
        assertEq(sourceToken.balanceOf(address(nodeContract)), nodeBalanceBefore + PAYMENT_AMOUNT + unusedBalance);
        assertEq(sourceToken.balanceOf(moduleOwner), ownerBalanceBefore);
    }

    function test_ReturnTokenBalance_CoversEscrowRefundAndUnusedSourceBalance() external givenFundedModule {
        uint256 unusedBalance = PAYMENT_AMOUNT - ESCROW_PULL_AMOUNT;

        permit2.pull(address(sourceToken), address(module), escrow, ESCROW_PULL_AMOUNT);
        assertEq(sourceToken.balanceOf(address(module)), unusedBalance);

        vm.prank(escrow);
        sourceToken.transfer(address(module), ESCROW_PULL_AMOUNT);

        vm.prank(moduleOwner);
        module.pause();

        vm.prank(moduleOwner);
        uint256 amountReturned = module.returnTokenBalance(address(sourceToken));

        assertEq(amountReturned, PAYMENT_AMOUNT);
        assertEq(sourceToken.balanceOf(address(module)), 0);
        assertEq(sourceToken.balanceOf(address(nodeContract)), PAYMENT_AMOUNT * 4);
        assertEq(sourceToken.balanceOf(escrow), 0);
    }

    function test_ReturnTokenBalances_ReturnsMultipleTokenBalances() external givenFundedModule {
        uint256 secondAmount = 77e6;
        secondToken.mint(address(module), secondAmount);

        address[] memory tokens = new address[](2);
        tokens[0] = address(sourceToken);
        tokens[1] = address(secondToken);

        vm.prank(moduleOwner);
        module.pause();

        vm.prank(moduleOwner);
        module.returnTokenBalances(tokens);

        assertEq(sourceToken.balanceOf(address(module)), 0);
        assertEq(secondToken.balanceOf(address(module)), 0);
        assertEq(sourceToken.balanceOf(address(nodeContract)), PAYMENT_AMOUNT * 4);
        assertEq(secondToken.balanceOf(address(nodeContract)), secondAmount);
    }

    function test_ReturnTokenBalances_WhenBatchIsEmpty_DoesNothing() external givenFundedModule {
        address[] memory tokens = new address[](0);

        vm.prank(moduleOwner);
        module.pause();

        vm.prank(moduleOwner);
        module.returnTokenBalances(tokens);

        assertEq(sourceToken.balanceOf(address(module)), PAYMENT_AMOUNT);
        assertEq(sourceToken.balanceOf(address(nodeContract)), PAYMENT_AMOUNT * 3);
    }

    function test_ReturnTokenBalance_RevertsWhenNotPaused() external givenFundedModule {
        vm.expectRevert(Pausable.ExpectedPause.selector);
        vm.prank(moduleOwner);
        module.returnTokenBalance(address(sourceToken));
    }

    function test_ReturnTokenBalance_ResetsPendingAndRevokesPermit2Allowance() external givenFundedModule {
        assertEq(module.pendingAmount(address(sourceToken)), PAYMENT_AMOUNT);
        assertEq(sourceToken.allowance(address(module), address(permit2)), PAYMENT_AMOUNT);

        vm.prank(moduleOwner);
        module.pause();

        vm.prank(moduleOwner);
        module.returnTokenBalance(address(sourceToken));

        assertEq(module.pendingAmount(address(sourceToken)), 0);
        assertEq(sourceToken.allowance(address(module), address(permit2)), 0);
    }

    function test_ReturnTokenBalance_RevertsWhenTokenIsZero() external {
        vm.prank(moduleOwner);
        module.pause();

        vm.expectRevert(Errors.AtumModule_ZeroToken.selector);

        vm.prank(moduleOwner);
        module.returnTokenBalance(address(0));
    }

    function test_NonOwnerCannotOperateModule() external {
        _expectUnauthorized(executor);
        vm.prank(executor);
        module.pause();

        vm.prank(moduleOwner);
        module.pause();

        _expectUnauthorized(executor);
        vm.prank(executor);
        module.unpause();

        _expectUnauthorized(executor);
        vm.prank(executor);
        module.setKeeper(newKeeper);

        _expectUnauthorized(executor);
        vm.prank(executor);
        module.returnTokenBalance(address(sourceToken));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    MODIFIERS
    //////////////////////////////////////////////////////////////////////////*/

    modifier givenFundedModule() {
        vm.prank(executor);
        assertTrue(nodeContract.executeAction(address(sourceToken), PAYMENT_AMOUNT));
        _;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _defaultParams() internal pure returns (DataTypes.AtumPaymentParams memory) {
        return DataTypes.AtumPaymentParams({
            destinationChain: DESTINATION_CHAIN,
            destinationAccount: DESTINATION_ACCOUNT,
            destinationAsset: DESTINATION_ASSET
        });
    }

    /// Points PaymentRails at a DIFFERENT destination, returning the new params.
    function _configureRouteB() internal returns (DataTypes.AtumPaymentParams memory routeB) {
        routeB = DataTypes.AtumPaymentParams({
            destinationChain: DESTINATION_CHAIN,
            destinationAccount: "0x2222222222222222222222222222222222222222",
            destinationAsset: DESTINATION_ASSET
        });
        // Encode BEFORE the prank: `encodeParams` is itself a call and would consume it,
        // leaving `configureToken` to run as the test contract and revert on Ownable.
        bytes memory encoded = module.encodeParams(routeB);
        vm.prank(nodeOwner);
        nodeContract.configureToken(address(sourceToken), "ATUM_PAYMENT", address(module), MIN_BALANCE, encoded, true);
    }

    function _routeHash(DataTypes.AtumPaymentParams memory params) internal pure returns (bytes32) {
        return keccak256(abi.encode(params));
    }

    function _defaultEncodedParams() internal view returns (bytes memory) {
        return module.encodeParams(_defaultParams());
    }

    function _shortEncodedParams() internal pure returns (bytes memory) {
        return hex"01";
    }

    function _malformedEncodedParams() internal pure returns (bytes memory) {
        return abi.encode(uint256(96), uint256(128), uint256(160));
    }

    function _executeFromNode(
        address token,
        uint256 amount,
        bytes memory params
    )
        internal
        returns (DataTypes.ExecutionResult memory result)
    {
        vm.prank(address(nodeContract));
        result = module.execute(token, amount, params);
    }

    function _assertFailedResult(
        DataTypes.ExecutionResult memory result,
        address outputToken,
        string memory reason
    )
        internal
        pure
    {
        assertFalse(result.success);
        assertEq(result.amountOut, 0);
        assertEq(result.outputToken, outputToken);
        assertEq(result.data.length, 0);
        assertEq(result.failureReason, reason);
    }

    function _assertValidate(
        address token,
        uint256 amount,
        bytes memory params,
        bool expectedValid,
        string memory expectedReason
    )
        internal
    {
        vm.prank(address(nodeContract));
        (bool isValid, string memory reason) = module.validate(token, amount, params);

        assertEq(isValid, expectedValid);
        assertEq(reason, expectedReason);
    }

    /// @dev What the keeper must now produce: a signature over the module-specific EIP-712
    ///      digest, not over the bare Permit2 digest (Certora M-01). Mirrors the off-chain change
    ///      the fix requires -- a keeper still signing the raw digest is rejected, which
    ///      test_IsValidSignature_RejectsRawPermit2Digest pins.
    function _signAsKeeper(uint256 privateKey, bytes32 permit2Digest) internal view returns (bytes memory) {
        return _sign(privateKey, module.keeperDigest(permit2Digest));
    }

    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory signature) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function _expectUnauthorized(address account) internal {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
    }
}
