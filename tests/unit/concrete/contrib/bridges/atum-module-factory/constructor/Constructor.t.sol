// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { AtumModuleFactoryBase } from "../AtumModuleFactoryBase.t.sol";
import { AtumModuleFactory } from "../../../../../../../src/modules/contrib/bridges/AtumModuleFactory.sol";
import { Errors } from "../../../../../../../src/libraries/Errors.sol";
import { IPaymentRailsFactory } from "../../../../../../../src/interfaces/IPaymentRailsFactory.sol";

contract Constructor_AtumModuleFactory_Test is AtumModuleFactoryBase {
    function test_RevertWhen_Permit2IsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroPermit2.selector);
        new AtumModuleFactory(address(0), railsFactory);
    }

    function test_RevertWhen_Permit2HasNoCode() external {
        address eoa = makeAddr("eoaPermit2");
        vm.expectRevert(abi.encodeWithSelector(Errors.AtumModuleFactory_Permit2NotContract.selector, eoa));
        new AtumModuleFactory(eoa, railsFactory);
    }

    function test_RevertWhen_PaymentRailsFactoryIsZeroAddress() external {
        vm.expectRevert(Errors.AtumModuleFactory_ZeroPaymentRailsFactory.selector);
        new AtumModuleFactory(address(permit2), IPaymentRailsFactory(address(0)));
    }

    function test_RevertWhen_PaymentRailsFactoryHasNoCode() external {
        address eoa = makeAddr("eoaRailsFactory");
        vm.expectRevert(abi.encodeWithSelector(Errors.AtumModuleFactory_PaymentRailsFactoryNotContract.selector, eoa));
        new AtumModuleFactory(address(permit2), IPaymentRailsFactory(eoa));
    }

    function test_WhenPermit2IsValidContract_ShouldSetPermit2() external {
        AtumModuleFactory newFactory = new AtumModuleFactory(address(permit2), railsFactory);
        assertEq(newFactory.permit2(), address(permit2));
        assertEq(address(newFactory.paymentRailsFactory()), address(railsFactory));
    }
}
