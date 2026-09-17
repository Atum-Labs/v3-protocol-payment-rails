// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AtumModuleFactoryBase } from "../AtumModuleFactoryBase.t.sol";
import { AtumModule } from "../../../../../../../src/modules/contrib/bridges/AtumModule.sol";
import { Errors } from "../../../../../../../src/libraries/Errors.sol";

contract CreateDeterministic_AtumModuleFactory_Test is AtumModuleFactoryBase {
    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroOwner.selector);
        factory.createDeterministic(address(0), paymentRails, keeper, DEFAULT_SALT);
    }

    function test_RevertWhen_PaymentRailsIsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroPaymentRails.selector);
        factory.createDeterministic(owner, address(0), keeper, DEFAULT_SALT);
    }

    function test_RevertWhen_KeeperIsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroKeeper.selector);
        factory.createDeterministic(owner, paymentRails, address(0), DEFAULT_SALT);
    }

    function test_WhenParamsAreValid_ShouldDeployContract() external {
        address module = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        assertTrue(module.code.length > 0);
    }

    function test_WhenParamsAreValid_ShouldSetOwner() external {
        address module = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        assertEq(AtumModule(module).owner(), owner);
    }

    function test_WhenParamsAreValid_ShouldWirePaymentRails() external {
        address module = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        assertEq(AtumModule(module).paymentRails(), paymentRails);
    }

    function test_WhenParamsAreValid_ShouldSetKeeper() external {
        address module = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        assertEq(AtumModule(module).keeper(), keeper);
    }

    function test_WhenParamsAreValid_ShouldDeployToPredictedAddress() external {
        address predicted =
            factory.predictDeterministicAddress(address(this), owner, paymentRails, keeper, DEFAULT_SALT);
        address module = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        assertEq(module, predicted);
    }

    function test_WhenParamsAreValid_ShouldRegisterModule() external {
        address module = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        assertTrue(factory.isDeployedModule(module));
        assertEq(factory.getModuleCount(), 1);
    }

    function test_WhenParamsAreValid_ShouldEmitEvent() external {
        address predicted =
            factory.predictDeterministicAddress(address(this), owner, paymentRails, keeper, DEFAULT_SALT);

        vm.expectEmit(true, true, true, true);
        emit AtumModuleCreated(predicted, paymentRails, owner);

        factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
    }

    function test_RevertWhen_SameSaltReusedWithSameParams() external {
        factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        vm.expectRevert();
        factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
    }

    function test_WhenDifferentSaltsUsed_ShouldDeployToDifferentAddresses() external {
        address module1 = factory.createDeterministic(owner, paymentRails, keeper, bytes32(uint256(1)));
        address module2 = factory.createDeterministic(owner, paymentRails, keeper, bytes32(uint256(2)));
        assertTrue(module1 != module2);
    }

    function test_WhenSameSaltWithDifferentOwners_ShouldDeployToDifferentAddresses() external {
        address otherOwner = makeAddr("otherOwner");
        address module1 = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        address module2 = factory.createDeterministic(otherOwner, paymentRails, keeper, DEFAULT_SALT);
        assertTrue(module1 != module2);
    }

    function test_WhenSameSaltWithDifferentPaymentRails_ShouldDeployToDifferentAddresses() external {
        address module1 = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);
        address module2 = factory.createDeterministic(owner, otherPaymentRails, keeper, DEFAULT_SALT);
        assertTrue(module1 != module2);
    }

    /// @dev The PaymentRails address is no longer fuzzed: Certora L-01 requires it to be a real
    ///      contract whose `owner()` is the caller, so an arbitrary address cannot be used. Owner,
    ///      keeper and salt stay fuzzed, which is what this test is actually about -- that
    ///      prediction tracks deployment across inputs.
    function testFuzz_PredictedAddressMatchesActual(address fuzzOwner, address fuzzKeeper, bytes32 fuzzSalt) external {
        vm.assume(fuzzOwner != address(0));
        vm.assume(fuzzKeeper != address(0));

        address predicted =
            factory.predictDeterministicAddress(address(this), fuzzOwner, paymentRails, fuzzKeeper, fuzzSalt);
        address actual = factory.createDeterministic(fuzzOwner, paymentRails, fuzzKeeper, fuzzSalt);
        assertEq(actual, predicted);
    }

    /// I-04. Two deployers using the SAME salt must not collide -- that collision is the
    /// front-running vector: watch a createDeterministic in the mempool, deploy to its address
    /// first, and the legitimate call reverts.
    function test_CreateDeterministic_SameSaltDifferentDeployersDoNotCollide() external {
        address moduleA = factory.createDeterministic(owner, paymentRails, keeper, DEFAULT_SALT);

        vm.prank(foreignRailsOwner);
        address moduleB = factory.createDeterministic(owner, foreignPaymentRails, keeper, DEFAULT_SALT);

        assertTrue(moduleA != moduleB, "same salt must not mean the same address for two deployers");
    }

    /// The salt is bound to the caller, so prediction for a different deployer differs.
    function test_PredictDeterministicAddress_IsPerDeployer() external view {
        address forThis = factory.predictDeterministicAddress(address(this), owner, paymentRails, keeper, DEFAULT_SALT);
        address forOther =
            factory.predictDeterministicAddress(foreignRailsOwner, owner, paymentRails, keeper, DEFAULT_SALT);
        assertTrue(forThis != forOther, "prediction must be deployer-scoped");
    }

    /// L-01. A stranger cannot deploy a module naming someone else's PaymentRails.
    function test_CreateDeterministic_RevertsWhenCallerIsNotPaymentRailsOwner() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                Errors.AtumModuleFactory_NotPaymentRailsOwner.selector, address(this), foreignRailsOwner
            )
        );
        factory.createDeterministic(owner, foreignPaymentRails, keeper, DEFAULT_SALT);
    }
}
