// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AtumModuleFactoryBase } from "../AtumModuleFactoryBase.t.sol";

contract Registry_AtumModuleFactory_Test is AtumModuleFactoryBase {
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
        address module = factory.create(owner, paymentRails, keeper);
        assertTrue(factory.isDeployedModule(module));
    }

    function test_GivenModules_IsDeployedModule_ShouldReturnFalseForNonDeployed() external {
        factory.create(owner, paymentRails, keeper);
        assertFalse(factory.isDeployedModule(address(0xdead)));
    }

    function test_GivenModules_GetDeployedModules_ShouldReturnCorrectArray() external {
        address module1 = factory.create(owner, paymentRails, keeper);
        address module2 = factory.create(owner, paymentRails, keeper);

        address[] memory modules = factory.getDeployedModules();
        assertEq(modules.length, 2);
        assertEq(modules[0], module1);
        assertEq(modules[1], module2);
    }

    function test_GivenModules_GetModuleCount_ShouldReturnCorrectCount() external {
        factory.create(owner, paymentRails, keeper);
        factory.create(owner, paymentRails, keeper);
        factory.create(owner, paymentRails, keeper);
        assertEq(factory.getModuleCount(), 3);
    }

    function test_GivenModules_GetModulesForPaymentRails_ShouldSeparateLookups() external {

        address module1 = factory.create(owner, paymentRails, keeper);
        address module2 = factory.create(owner, otherPaymentRails, keeper);

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
        address createModule = factory.create(owner, paymentRails, keeper);
        address create2Module = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);

        assertTrue(factory.isDeployedModule(createModule));
        assertTrue(factory.isDeployedModule(create2Module));
        assertEq(factory.getModuleCount(), 2);

        address[] memory modules = factory.getDeployedModules();
        assertEq(modules[0], createModule);
        assertEq(modules[1], create2Module);

        address[] memory railsModules = factory.getModulesForPaymentRails(paymentRails);
        assertEq(railsModules.length, 2);
    }
}
