// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { AtumModuleFactory } from "../../../../../../src/modules/contrib/bridges/AtumModuleFactory.sol";

import { MockPermit2 } from "../../../../../shared/mocks/atum/MockPermit2.sol";
import { MockPaymentRailsFactory } from "../../../../../shared/mocks/MockPaymentRailsFactory.sol";
import { PaymentRails } from "../../../../../../src/core/PaymentRails.sol";

/// @dev Base test contract for AtumModuleFactory unit tests.
abstract contract AtumModuleFactoryBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event AtumModuleCreated(
        address indexed module, address indexed paymentRails, address indexed owner, address keeper
    );

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant PERMIT2_DOMAIN_SEPARATOR = keccak256("mock permit2 domain");
    bytes32 internal constant DEFAULT_SALT = bytes32(uint256(1));

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    AtumModuleFactory internal factory;
    MockPermit2 internal permit2;
    MockPaymentRailsFactory internal railsFactory;

    address internal owner;
    address internal paymentRails;
    address internal keeper;
    /// @dev A second PaymentRails, also owned by this contract, for per-rails registry tests.
    address internal otherPaymentRails;
    /// @dev A real PaymentRails owned by someone else, for the L-01 negative cases.
    address internal foreignPaymentRails;
    address internal foreignRailsOwner;

    /*//////////////////////////////////////////////////////////////////////////
                                    SET UP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        owner = makeAddr("owner");
        keeper = makeAddr("keeper");

        // A REAL PaymentRails, owned by this test contract. Certora L-01 restricts module
        // creation to the PaymentRails owner, so the factory now reads `owner()` off this
        // address -- it can no longer be a bare `makeAddr`. Owning it here keeps every existing
        // unpranked `factory.create(...)` call valid, which is what the old EOA stood in for.
        paymentRails = address(new PaymentRails(address(this)));

        otherPaymentRails = address(new PaymentRails(address(this)));

        foreignRailsOwner = makeAddr("foreignRailsOwner");
        foreignPaymentRails = address(new PaymentRails(foreignRailsOwner));

        // Creation now requires the rails to be on PaymentRailsFactory's deployment list. The
        // mock stands in for that list; the production factory is what makes membership unforgeable.
        railsFactory = new MockPaymentRailsFactory();
        railsFactory.register(paymentRails);
        railsFactory.register(otherPaymentRails);
        railsFactory.register(foreignPaymentRails);

        permit2 = new MockPermit2(PERMIT2_DOMAIN_SEPARATOR);
        factory = new AtumModuleFactory(address(permit2), railsFactory);
    }
}
