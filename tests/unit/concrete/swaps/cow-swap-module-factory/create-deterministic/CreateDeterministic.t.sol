// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

import { CowSwapModuleFactoryBase } from "../CowSwapModuleFactoryBase.t.sol";
import { CowSwapModule } from "../../../../../../src/modules/swaps/CowSwapModule.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";

contract CreateDeterministic_CowSwapModuleFactory_Test is CowSwapModuleFactoryBase {
    function test_RevertWhen_CallerIsNotFactoryOwner() external {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
    }

    /// @dev Predicted addresses cannot be front-run by an unauthorized caller.
    function test_WhenUnauthorized_PredictedAddressStaysUnoccupied() external {
        address predicted = factory.predictDeterministicAddress(owner, paymentRails, DEFAULT_SALT);

        vm.prank(stranger);
        try factory.createDeterministic(owner, paymentRails, DEFAULT_SALT) returns (address) {
            fail();
        } catch { }

        assertEq(predicted.code.length, 0);
        assertEq(factory.createDeterministic(owner, paymentRails, DEFAULT_SALT), predicted);
    }

    function test_RevertWhen_OwnerIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModuleFactory_ZeroOwner.selector);
        factory.createDeterministic(address(0), paymentRails, DEFAULT_SALT);
    }

    function test_RevertWhen_PaymentRailsIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModuleFactory_ZeroPaymentRails.selector);
        factory.createDeterministic(owner, address(0), DEFAULT_SALT);
    }

    function test_RevertWhen_PaymentRailsHasNoCode() external {
        address eoa = makeAddr("eoaRails");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_PaymentRailsNotContract.selector, eoa));
        factory.createDeterministic(owner, eoa, DEFAULT_SALT);
    }

    function test_WhenCallerIsFactoryOwner_ShouldDeployContract() external {
        address module = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
        assertTrue(module.code.length > 0);
    }

    function test_WhenCallerIsFactoryOwner_ShouldSetOwner() external {
        address module = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
        assertEq(CowSwapModule(module).owner(), owner);
    }

    function test_WhenCallerIsFactoryOwner_ShouldWirePaymentRails() external {
        address module = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
        assertEq(CowSwapModule(module).paymentRails(), paymentRails);
    }

    function test_WhenCallerIsFactoryOwner_ShouldDeployToPredictedAddress() external {
        address predicted = factory.predictDeterministicAddress(owner, paymentRails, DEFAULT_SALT);
        address module = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
        assertEq(module, predicted);
    }

    function test_WhenCallerIsFactoryOwner_ShouldRegisterModule() external {
        address module = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
        assertTrue(factory.isDeployedModule(module));
        assertEq(factory.getModuleCount(), 1);
    }

    function test_WhenCallerIsFactoryOwner_ShouldEmitEvent() external {
        address predicted = factory.predictDeterministicAddress(owner, paymentRails, DEFAULT_SALT);

        vm.expectEmit(true, true, true, true);
        emit CowSwapModuleCreated(predicted, paymentRails, owner);

        factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
    }

    function test_RevertWhen_SameSaltReusedWithSameParams() external {
        factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);

        vm.expectRevert();
        factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
    }

    function test_WhenDifferentSaltsUsed_ShouldDeployToDifferentAddresses() external {
        address module1 = factory.createDeterministic(owner, paymentRails, bytes32(uint256(1)));
        address module2 = factory.createDeterministic(owner, paymentRails, bytes32(uint256(2)));
        assertTrue(module1 != module2);
    }

    function test_WhenSameSaltWithDifferentOwners_ShouldDeployToDifferentAddresses() external {
        address otherOwner = makeAddr("otherOwner");

        address module1 = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
        address module2 = factory.createDeterministic(otherOwner, paymentRails, DEFAULT_SALT);

        assertTrue(module1 != module2);
    }

    function test_WhenSameSaltWithDifferentPaymentRails_ShouldDeployToDifferentAddresses() external {
        address otherPaymentRails = deployPaymentRails(railsOwner);

        address module1 = factory.createDeterministic(owner, paymentRails, DEFAULT_SALT);
        address module2 = factory.createDeterministic(owner, otherPaymentRails, DEFAULT_SALT);

        assertTrue(module1 != module2);
    }

    function testFuzz_PredictedAddressMatchesActual(address fuzzOwner, bytes32 fuzzSalt) external {
        vm.assume(fuzzOwner != address(0));

        address fuzzPaymentRails = deployPaymentRails(railsOwner);

        address predicted = factory.predictDeterministicAddress(fuzzOwner, fuzzPaymentRails, fuzzSalt);
        address actual = factory.createDeterministic(fuzzOwner, fuzzPaymentRails, fuzzSalt);

        assertEq(actual, predicted);
    }
}
