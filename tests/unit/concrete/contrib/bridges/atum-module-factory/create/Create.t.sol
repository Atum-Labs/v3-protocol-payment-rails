// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AtumModuleFactoryBase } from "../AtumModuleFactoryBase.t.sol";
import { AtumModule } from "../../../../../../../src/modules/contrib/bridges/AtumModule.sol";
import { Errors } from "../../../../../../../src/libraries/Errors.sol";
import { PaymentRails } from "../../../../../../../src/core/PaymentRails.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Vm } from "forge-std/src/Vm.sol";

/// @dev Copies `owner()` and nothing else. Not on the PaymentRailsFactory list.
contract OwnerReturningLookalike is Ownable {
    constructor(address initialOwner) Ownable(initialOwner) { }
}

contract Create_AtumModuleFactory_Test is AtumModuleFactoryBase {
    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroOwner.selector);
        factory.create(address(0), paymentRails, keeper);
    }

    function test_RevertWhen_PaymentRailsIsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroPaymentRails.selector);
        factory.create(owner, address(0), keeper);
    }

    function test_RevertWhen_KeeperIsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroKeeper.selector);
        factory.create(owner, paymentRails, address(0));
    }

    function test_WhenParamsAreValid_ShouldDeployContract() external {
        address module = factory.create(owner, paymentRails, keeper);
        assertTrue(module.code.length > 0);
    }

    function test_WhenParamsAreValid_ShouldSetOwner() external {
        address module = factory.create(owner, paymentRails, keeper);
        assertEq(AtumModule(module).owner(), owner);
    }

    function test_WhenParamsAreValid_ShouldWirePaymentRails() external {
        address module = factory.create(owner, paymentRails, keeper);
        assertEq(AtumModule(module).paymentRails(), paymentRails);
    }

    function test_WhenParamsAreValid_ShouldSetKeeper() external {
        address module = factory.create(owner, paymentRails, keeper);
        assertEq(AtumModule(module).keeper(), keeper);
    }

    function test_WhenParamsAreValid_ShouldWirePermit2() external {
        address module = factory.create(owner, paymentRails, keeper);
        assertEq(AtumModule(module).permit2(), address(permit2));
    }

    function test_WhenParamsAreValid_ShouldRegisterModule() external {
        address module = factory.create(owner, paymentRails, keeper);
        assertTrue(factory.isDeployedModule(module));
    }

    function test_WhenParamsAreValid_ShouldIncrementModuleCount() external {
        assertEq(factory.getModuleCount(), 0);
        factory.create(owner, paymentRails, keeper);
        assertEq(factory.getModuleCount(), 1);
    }

    function test_WhenParamsAreValid_ShouldRegisterUnderPaymentRailsLookup() external {
        address module = factory.create(owner, paymentRails, keeper);

        address[] memory modules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(modules.length, 1);
        assertEq(modules[0], module);
    }

    function test_WhenParamsAreValid_ShouldEmitEvent() external {
        // Check topic2 (paymentRails) and topic3 (owner) without asserting topic1 (unpredictable CREATE address).
        // The final `true` checks the data field, which is now the initial keeper (Certora I-03).
        vm.expectEmit(false, true, true, true);
        emit AtumModuleCreated(address(0), paymentRails, owner, keeper);

        factory.create(owner, paymentRails, keeper);
    }

    function test_WhenCalledMultipleTimes_ShouldDeployDistinctInstances() external {
        address module1 = factory.create(owner, paymentRails, keeper);
        address module2 = factory.create(owner, paymentRails, keeper);
        assertTrue(module1 != module2);
    }

    function test_WhenCalledMultipleTimes_ShouldRegisterAllInstances() external {
        address module1 = factory.create(owner, paymentRails, keeper);
        address module2 = factory.create(owner, paymentRails, keeper);

        assertTrue(factory.isDeployedModule(module1));
        assertTrue(factory.isDeployedModule(module2));
        assertEq(factory.getModuleCount(), 2);

        address[] memory modules = factory.getDeployedModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], module1);
        assertEq(modules[1], module2);
    }

    function test_WhenCalledMultipleTimes_ShouldAccumulateInPaymentRailsLookup() external {
        address module1 = factory.create(owner, paymentRails, keeper);
        address module2 = factory.create(owner, paymentRails, keeper);

        address[] memory modules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(modules.length, 2);
        assertEq(modules[0], module1);
        assertEq(modules[1], module2);
    }

    /// I-03, the factory half. The initial keeper authorises moving every token the module will
    /// hold and was absent from this event, so an indexer following factory deployments could not
    /// record which key could sign for a module without also watching the module's own logs.
    function test_Create_EmitsTheInitialKeeper() external {
        address distinctKeeper = makeAddr("distinctKeeper");

        vm.recordLogs();
        factory.create(owner, paymentRails, distinctKeeper);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("AtumModuleCreated(address,address,address,address)");

        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic) {
                assertEq(abi.decode(logs[i].data, (address)), distinctKeeper, "keeper must be in the event data");
                found = true;
            }
        }
        assertTrue(found, "AtumModuleCreated not emitted");
    }

    /// L-01. Creation was permissionless, so anyone could deploy a genuine factory module naming
    /// a victim's PaymentRails -- making themselves owner and keeper -- and have it recorded
    /// against the victim in the registry, passing `isDeployedModule` and appearing in
    /// `getModulesForPaymentRails(victim)`.
    function test_Create_RevertsWhenCallerIsNotPaymentRailsOwner() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AtumModuleFactory_NotPaymentRailsOwner.selector, address(this), foreignRailsOwner
            )
        );
        factory.create(owner, foreignPaymentRails, keeper);
    }

    /// The rails owner themselves is still free to create, which is the flow the check preserves.
    function test_Create_SucceedsForThePaymentRailsOwner() external {
        vm.prank(foreignRailsOwner);
        address module = factory.create(owner, foreignPaymentRails, keeper);

        assertTrue(factory.isDeployedModule(module));
        assertEq(factory.getModulesForPaymentRails(foreignPaymentRails).length, 1);
    }

    /// An address with no code fails the code-length check, before the factory list is consulted.
    function test_Create_RevertsWhenPaymentRailsHasNoCode() external {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(abi.encodeWithSelector(Errors.AtumModuleFactory_PaymentRailsNotContract.selector, eoa));
        factory.create(owner, eoa, keeper);
    }

    /// A contract that returns the caller from `owner()` still fails unless PaymentRailsFactory
    /// deployed it. Copying the function is not enough to get onto that list.
    function test_Create_RevertsWhenPaymentRailsIsALookalike() external {
        address lookalike = address(new OwnerReturningLookalike(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Errors.AtumModuleFactory_UnknownPaymentRails.selector, lookalike));
        factory.create(owner, lookalike, keeper);
    }

    /// A real PaymentRails deployed outside the factory is rejected. That is the cost of trusting
    /// the list.
    function test_Create_RevertsWhenPaymentRailsWasNotDeployedByTheFactory() external {
        address direct = address(new PaymentRails(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Errors.AtumModuleFactory_UnknownPaymentRails.selector, direct));
        factory.create(owner, direct, keeper);
    }
}
