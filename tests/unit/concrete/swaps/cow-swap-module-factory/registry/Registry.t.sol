// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleFactoryBase } from "../CowSwapModuleFactoryBase.t.sol";

contract Registry_CowSwapModuleFactory_Test is CowSwapModuleFactoryBase {
    /*//////////////////////////////////////////////////////////////////////////
                            GIVEN NO MODULES DEPLOYED
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenNoModules_IsDeployedModule_ShouldReturnFalse() external view {
        assertFalse(factory.isDeployedModule(address(0x1)));
    }

    function test_GivenNoModules_GetDeployedModules_ShouldReturnEmptyArray() external view {
        address[] memory modules = factory.getDeployedModules();
        assertEq(modules.length, 0);
    }

    function test_GivenNoModules_GetModuleCount_ShouldReturnZero() external view {
        assertEq(factory.getModuleCount(), 0);
    }

    function test_GivenNoModules_GetModulesForPaymentRails_ShouldReturnEmptyArray() external view {
        address[] memory modules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(modules.length, 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            GIVEN MODULES DEPLOYED
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenModules_IsDeployedModule_ShouldReturnTrueForDeployed() external {
        address module = factory.create(owner, paymentRails);
        assertTrue(factory.isDeployedModule(module));
    }

    function test_GivenModules_IsDeployedModule_ShouldReturnFalseForNonDeployed() external {
        factory.create(owner, paymentRails);
        assertFalse(factory.isDeployedModule(address(0xdead)));
    }

    function test_GivenModules_GetDeployedModules_ShouldReturnCorrectArray() external {
        address module1 = factory.create(owner, paymentRails);
        address module2 = factory.create(owner, paymentRails);

        address[] memory modules = factory.getDeployedModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], module1);
        assertEq(modules[1], module2);
    }

    function test_GivenModules_GetModuleCount_ShouldReturnCorrectCount() external {
        factory.create(owner, paymentRails);
        factory.create(owner, paymentRails);
        factory.create(owner, paymentRails);
        assertEq(factory.getModuleCount(), 3);
    }

    function test_GivenModules_GetModulesForPaymentRails_ShouldSeparateLookups() external {
        address otherRailsOwner = makeAddr("otherRailsOwner");
        address otherPaymentRails = deployPaymentRails(otherRailsOwner);

        address module1 = factory.create(owner, paymentRails);
        address module2 = factory.create(owner, otherPaymentRails);

        address[] memory railsModules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(railsModules.length, 1);
        assertEq(railsModules[0], module1);

        address[] memory otherModules = factory.getModulesForPaymentRails(otherPaymentRails);
        assertEq(otherModules.length, 1);
        assertEq(otherModules[0], module2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    GIVEN MIX OF CREATE AND CREATE2 DEPLOYMENTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenMixedDeployments_ShouldTrackBothInSameRegistry() external {
        address createModule = factory.create(owner, paymentRails);
        address create2Module = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);

        assertTrue(factory.isDeployedModule(createModule));
        assertTrue(factory.isDeployedModule(create2Module));
        assertEq(factory.getModuleCount(), 2);

        address[] memory modules = factory.getDeployedModules();
        assertEq(modules[0], createModule);
        assertEq(modules[1], create2Module);

        address[] memory railsModules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(railsModules.length, 2);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    GIVEN A NON-OWNER ATTEMPTS TO REGISTER
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Owning a PaymentRails confers no right to register a module.
    function test_GivenNonOwnerAttempt_ShouldRegisterNothingEvenIfCallerOwnsARails() external {
        address attacker = makeAddr("attacker");
        address attackerRails = deployPaymentRails(attacker);

        vm.startPrank(attacker);
        try factory.create(attacker, attackerRails) returns (address) {
            fail();
        } catch { }
        try factory.create(attacker, paymentRails) returns (address) {
            fail();
        } catch { }
        vm.stopPrank();

        assertEq(factory.getModuleCount(), 0);
        assertEq(factory.getModulesForPaymentRails(attackerRails).length, 0);
        assertEq(factory.getModulesForPaymentRails(paymentRails).length, 0);
    }

    function test_GivenNonOwnerAttempt_ShouldOnlyListFactoryOwnerModules() external {
        address attacker = makeAddr("attacker");

        vm.prank(attacker);
        try factory.create(attacker, paymentRails) returns (address) {
            fail();
        } catch { }

        address legitimateModule = factory.create(owner, paymentRails);

        address[] memory modules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(modules.length, 1);
        assertEq(modules[0], legitimateModule);
    }
}
