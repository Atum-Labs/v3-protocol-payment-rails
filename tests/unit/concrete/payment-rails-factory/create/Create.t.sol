// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { PaymentRailsFactoryBase } from "../PaymentRailsFactoryBase.t.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";

contract Create_Test is PaymentRailsFactoryBase {
    function test_RevertWhen_CallerIsNotFactoryOwner() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.create(owner);
    }

    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(Errors.PaymentRailsFactory_ZeroOwner.selector);
        factory.create(address(0));
    }

    function test_WhenOwnerIsValid_ShouldDeployContract() external {
        address instance = factory.create(owner);
        assertTrue(instance.code.length > 0);
    }

    function test_WhenOwnerIsValid_ShouldSetOwner() external {
        address instance = factory.create(owner);
        assertEq(PaymentRails(instance).owner(), owner);
    }

    function test_WhenOwnerIsValid_ShouldRegisterInstance() external {
        address instance = factory.create(owner);
        assertTrue(factory.isDeployedInstance(instance));
    }

    function test_WhenOwnerIsValid_ShouldIncrementInstanceCount() external {
        assertEq(factory.getInstanceCount(), 0);
        factory.create(owner);
        assertEq(factory.getInstanceCount(), 1);
    }

    function test_WhenOwnerIsValid_ShouldEmitEvent() external {
        // Check topic2 (owner) without asserting topic1 (unpredictable CREATE address).
        vm.expectEmit(false, true, false, true);
        emit PaymentRailsCreated(address(0), owner);

        factory.create(owner);
    }

    function test_WhenCalledMultipleTimes_ShouldDeployDistinctInstances() external {
        address instance1 = factory.create(owner);
        address instance2 = factory.create(owner);
        assertTrue(instance1 != instance2);
    }

    function test_WhenCalledMultipleTimes_ShouldRegisterAllInstances() external {
        address instance1 = factory.create(owner);
        address instance2 = factory.create(owner);

        assertTrue(factory.isDeployedInstance(instance1));
        assertTrue(factory.isDeployedInstance(instance2));
        assertEq(factory.getInstanceCount(), 2);

        address[] memory instances = factory.getDeployedInstances();
        assertEq(instances.length, 2);
        assertEq(instances[0], instance1);
        assertEq(instances[1], instance2);
    }
}
