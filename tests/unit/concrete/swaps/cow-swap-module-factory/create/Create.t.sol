// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { CowSwapModuleFactoryBase } from "../CowSwapModuleFactoryBase.t.sol";
import { CowSwapModule } from "../../../../../../src/modules/swaps/CowSwapModule.sol";
import { PaymentRails } from "../../../../../../src/core/PaymentRails.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";

contract Create_CowSwapModuleFactory_Test is CowSwapModuleFactoryBase {
    /*//////////////////////////////////////////////////////////////////////////
                            CALLER IS NOT THE FACTORY OWNER
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_CallerIsNotFactoryOwner() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.create(owner, paymentRails);
    }

    /// @dev Owning the PaymentRails confers no right to mint a module for it.
    function test_RevertWhen_CallerIsPaymentRailsOwnerButNotFactoryOwner() external {
        assertEq(PaymentRails(paymentRails).owner(), railsOwner);

        vm.prank(railsOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, railsOwner));
        factory.create(railsOwner, paymentRails);
    }

    function test_WhenUnauthorized_RegistryStaysEmpty() external {
        vm.prank(stranger);
        try factory.create(stranger, paymentRails) returns (address) {
            fail();
        } catch { }

        assertEq(factory.getModulesForPaymentRails(paymentRails).length, 0);
        assertEq(factory.getModuleCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                PARAMETER VALIDATION
    //////////////////////////////////////////////////////////////////////////*/

    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModuleFactory_ZeroOwner.selector);
        factory.create(address(0), paymentRails);
    }

    function test_RevertWhen_PaymentRailsIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModuleFactory_ZeroPaymentRails.selector);
        factory.create(owner, address(0));
    }

    /// @dev Typo guard, not authentication: an EOA can never call execute().
    function test_RevertWhen_PaymentRailsHasNoCode() external {
        address eoa = makeAddr("eoaRails");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_PaymentRailsNotContract.selector, eoa));
        factory.create(owner, eoa);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            CALLER IS THE FACTORY OWNER
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenCallerIsFactoryOwner_ShouldDeployContract() external {
        address module = factory.create(owner, paymentRails);
        assertTrue(module.code.length > 0);
    }

    function test_WhenCallerIsFactoryOwner_ShouldSetOwner() external {
        address module = factory.create(owner, paymentRails);
        assertEq(CowSwapModule(module).owner(), owner);
    }

    function test_WhenCallerIsFactoryOwner_ShouldAllowDistinctModuleOwner() external {
        assertTrue(owner != railsOwner);

        address module = factory.create(owner, paymentRails);

        assertEq(CowSwapModule(module).owner(), owner);
        assertEq(PaymentRails(paymentRails).owner(), railsOwner);
    }

    /// @dev The production flow: cancel rights go straight to the PaymentRails owner.
    function test_WhenCallerIsFactoryOwner_ShouldAllowRailsOwnerAsModuleOwner() external {
        address module = factory.create(railsOwner, paymentRails);

        assertEq(CowSwapModule(module).owner(), railsOwner);
        assertEq(CowSwapModule(module).paymentRails(), paymentRails);
    }

    function test_WhenCallerIsFactoryOwner_ShouldNotRequireOwningThePaymentRails() external {
        assertTrue(PaymentRails(paymentRails).owner() != address(this));
        assertEq(factory.owner(), address(this));

        address module = factory.create(owner, paymentRails);
        assertTrue(factory.isDeployedModule(module));
    }

    function test_WhenCallerIsFactoryOwner_ShouldWirePaymentRails() external {
        address module = factory.create(owner, paymentRails);
        assertEq(CowSwapModule(module).paymentRails(), paymentRails);
    }

    function test_WhenCallerIsFactoryOwner_ShouldWireChainConfig() external {
        address module = factory.create(owner, paymentRails);

        assertEq(CowSwapModule(module).cowSettlement(), address(cowSettlement));
        assertEq(CowSwapModule(module).cowDomainSeparator(), DOMAIN_SEPARATOR);
        assertEq(CowSwapModule(module).vaultRelayer(), vaultRelayer);
        assertEq(CowSwapModule(module).sequencerUptimeFeed(), factory.sequencerUptimeFeed());
        assertEq(CowSwapModule(module).sequencerGracePeriod(), factory.sequencerGracePeriod());
    }

    function test_WhenCallerIsFactoryOwner_ShouldRegisterModule() external {
        address module = factory.create(owner, paymentRails);
        assertTrue(factory.isDeployedModule(module));
    }

    function test_WhenCallerIsFactoryOwner_ShouldIncrementModuleCount() external {
        assertEq(factory.getModuleCount(), 0);
        factory.create(owner, paymentRails);
        assertEq(factory.getModuleCount(), 1);
    }

    function test_WhenCallerIsFactoryOwner_ShouldRegisterUnderPaymentRailsLookup() external {
        address module = factory.create(owner, paymentRails);

        address[] memory modules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(modules.length, 1);
        assertEq(modules[0], module);
    }

    function test_WhenCallerIsFactoryOwner_ShouldEmitEvent() external {
        // Check topic2 (paymentRails) and topic3 (owner) without asserting topic1 (unpredictable CREATE address).
        vm.expectEmit(false, true, true, true);
        emit CowSwapModuleCreated(address(0), paymentRails, owner);

        factory.create(owner, paymentRails);
    }

    function test_WhenCalledMultipleTimes_ShouldDeployDistinctInstances() external {
        address module1 = factory.create(owner, paymentRails);
        address module2 = factory.create(owner, paymentRails);
        assertTrue(module1 != module2);
    }

    function test_WhenCalledMultipleTimes_ShouldRegisterAllInstances() external {
        address module1 = factory.create(owner, paymentRails);
        address module2 = factory.create(owner, paymentRails);

        assertTrue(factory.isDeployedModule(module1));
        assertTrue(factory.isDeployedModule(module2));
        assertEq(factory.getModuleCount(), 2);

        address[] memory modules = factory.getDeployedModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], module1);
        assertEq(modules[1], module2);
    }

    function test_WhenCalledMultipleTimes_ShouldAccumulateInPaymentRailsLookup() external {
        address module1 = factory.create(owner, paymentRails);
        address module2 = factory.create(owner, paymentRails);

        address[] memory modules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(modules.length, 2);
        assertEq(modules[0], module1);
        assertEq(modules[1], module2);
    }
}
