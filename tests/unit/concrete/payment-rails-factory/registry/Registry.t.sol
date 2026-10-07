// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { PaymentRailsFactoryBase } from "../PaymentRailsFactoryBase.t.sol";

contract Registry_Test is PaymentRailsFactoryBase {
    /*//////////////////////////////////////////////////////////////////////////
                            GIVEN NO INSTANCES DEPLOYED
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenNoInstances_IsDeployedInstance_ShouldReturnFalse() external view {
        assertFalse(factory.isDeployedInstance(address(0x1)));
    }

    function test_GivenNoInstances_GetDeployedInstances_ShouldReturnEmptyArray() external view {
        address[] memory instances = factory.getDeployedInstances();
        assertEq(instances.length, 0);
    }

    function test_GivenNoInstances_GetInstanceCount_ShouldReturnZero() external view {
        assertEq(factory.getInstanceCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            GIVEN INSTANCES DEPLOYED
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenInstances_IsDeployedInstance_ShouldReturnTrueForDeployed() external {
        address instance = factory.create(owner);
        assertTrue(factory.isDeployedInstance(instance));
    }

    function test_GivenInstances_IsDeployedInstance_ShouldReturnFalseForNonDeployed() external {
        factory.create(owner);
        assertFalse(factory.isDeployedInstance(address(0xdead)));
    }

    function test_GivenInstances_GetDeployedInstances_ShouldReturnCorrectArray() external {
        address instance1 = factory.create(owner);
        address instance2 = factory.create(owner);

        address[] memory instances = factory.getDeployedInstances();
        assertEq(instances.length, 2);
        assertEq(instances[0], instance1);
        assertEq(instances[1], instance2);
    }

    function test_GivenInstances_GetInstanceCount_ShouldReturnCorrectCount() external {
        factory.create(owner);
        factory.create(owner);
        factory.create(owner);
        assertEq(factory.getInstanceCount(), 3);
    }

    /*//////////////////////////////////////////////////////////////////////////
                    GIVEN MIX OF CREATE AND CREATE2 DEPLOYMENTS
    //////////////////////////////////////////////////////////////////////////*/

    function test_GivenMixedDeployments_ShouldTrackBothInSameRegistry() external {
        address createInstance = factory.create(owner);
        address create2Instance = factory.createDeterministic(owner, DEFAULT_SALT);

        assertTrue(factory.isDeployedInstance(createInstance));
        assertTrue(factory.isDeployedInstance(create2Instance));
        assertEq(factory.getInstanceCount(), 2);

        address[] memory instances = factory.getDeployedInstances();
        assertEq(instances[0], createInstance);
        assertEq(instances[1], create2Instance);
    }
}
