// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { PaymentRailsFactoryBase } from "../PaymentRailsFactoryBase.t.sol";
import { PaymentRailsFactory } from "../../../../../src/core/PaymentRailsFactory.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";

/// @notice Unit tests for PaymentRailsFactory ownership.
/// @dev Tree: tests/unit/concrete/payment-rails-factory/ownership/ownership.tree
contract PaymentRailsFactory_Ownership_Test is PaymentRailsFactoryBase {
    function test_RevertWhen_InitialOwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new PaymentRailsFactory(address(0));
    }

    function test_WhenInitialOwnerIsValid_SetsOwner() external {
        PaymentRailsFactory f = new PaymentRailsFactory(owner);
        assertEq(f.owner(), owner, "owner");
    }

    /// @dev The owner is an argument, not msg.sender, so a deployer key never holds the role.
    function test_WhenDeployed_DeployerIsNotOwner() external {
        PaymentRailsFactory f = new PaymentRailsFactory(owner);
        assertNotEq(f.owner(), address(this), "deployer must not be owner");
    }

    function test_RevertWhen_RenounceOwnershipCalled() external {
        vm.expectRevert(Errors.PaymentRailsFactory_OwnershipCannotBeRenounced.selector);
        factory.renounceOwnership();
    }

    /// @dev Ownable2Step: the transfer only completes once the new owner accepts.
    function test_WhenOwnershipTransferred_RequiresAcceptance() external {
        factory.transferOwnership(owner);
        assertEq(factory.owner(), address(this), "owner must not change before acceptance");
        assertEq(factory.pendingOwner(), owner, "pendingOwner");

        vm.prank(owner);
        factory.acceptOwnership();
        assertEq(factory.owner(), owner, "owner after acceptance");
        assertEq(factory.pendingOwner(), address(0), "pendingOwner cleared");
    }

    function test_WhenOwnershipTransferred_NewOwnerCanCreate() external {
        factory.transferOwnership(owner);
        vm.prank(owner);
        factory.acceptOwnership();

        vm.prank(owner);
        address rails = factory.create(owner);
        assertTrue(factory.isDeployedInstance(rails), "new owner can create");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.create(owner);
    }
}
