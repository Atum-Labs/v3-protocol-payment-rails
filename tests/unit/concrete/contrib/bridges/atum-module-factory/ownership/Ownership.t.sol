// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { AtumModuleFactoryBase } from "../AtumModuleFactoryBase.t.sol";
import { AtumModuleFactory } from "../../../../../../../src/modules/contrib/bridges/AtumModuleFactory.sol";
import { Errors } from "../../../../../../../src/libraries/Errors.sol";

/// @notice Unit tests for AtumModuleFactory ownership.
/// @dev Tree: tests/unit/concrete/contrib/bridges/atum-module-factory/ownership/ownership.tree
contract Ownership_AtumModuleFactory_Test is AtumModuleFactoryBase {
    function test_RevertWhen_InitialOwnerIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new AtumModuleFactory(address(0), address(permit2), railsFactory);
    }

    function test_WhenInitialOwnerIsValid_SetsOwner() external {
        AtumModuleFactory f = new AtumModuleFactory(owner, address(permit2), railsFactory);
        assertEq(f.owner(), owner, "owner");
    }

    /// @dev The owner is an argument, not msg.sender, so a deployer key never holds the role.
    function test_WhenDeployed_DeployerIsNotOwner() external {
        AtumModuleFactory f = new AtumModuleFactory(owner, address(permit2), railsFactory);
        assertNotEq(f.owner(), address(this), "deployer must not be owner");
    }

    function test_RevertWhen_RenounceOwnershipCalled() external {
        vm.expectRevert(Errors.AtumModuleFactory_OwnershipCannotBeRenounced.selector);
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
        address module = factory.create(owner, paymentRails, keeper);
        assertTrue(factory.isDeployedModule(module), "new owner can create");

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.create(owner, paymentRails, keeper);
    }

    /// @dev The previous owner loses the role on acceptance, not on transfer.
    function test_WhenOwnershipTransferred_PreviousOwnerCannotCreate() external {
        factory.transferOwnership(owner);
        vm.prank(owner);
        factory.acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.create(owner, paymentRails, keeper);
    }
}
