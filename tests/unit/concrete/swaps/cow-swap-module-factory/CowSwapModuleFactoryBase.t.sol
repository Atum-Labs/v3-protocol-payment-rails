// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModuleFactory } from "../../../../../src/modules/swaps/CowSwapModuleFactory.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";

import { MockChainlinkAggregator } from "../../../../shared/mocks/MockChainlinkAggregator.sol";
import { MockCowSettlement } from "../../../../shared/mocks/MockCowSettlement.sol";

/// @dev Base test contract for CowSwapModuleFactory unit tests.
abstract contract CowSwapModuleFactoryBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                    EVENTS
    //////////////////////////////////////////////////////////////////////////*/

    event CowSwapModuleCreated(address indexed module, address indexed paymentRails, address indexed owner);

    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    bytes32 internal constant DOMAIN_SEPARATOR = keccak256("cow.protocol.domain.separator.v1");
    bytes32 internal constant DEFAULT_SALT = bytes32(uint256(1));
    uint256 internal constant DEFAULT_GRACE_PERIOD = 3600;

    /// @dev Mirrors MAX_SEQUENCER_GRACE_PERIOD in CowSwapModuleFactory.
    uint256 internal constant MAX_GRACE_PERIOD = 1 days;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModuleFactory internal factory;
    MockCowSettlement internal cowSettlement;

    /// @dev Owner of `paymentRails`; has no right to call create().
    address internal railsOwner;

    /// @dev Initial owner passed to deployed modules; deliberately not the PaymentRails owner.
    address internal owner;

    /// @dev An address holding no role.
    address internal stranger;

    address internal paymentRails;

    address internal vaultRelayer;
    address internal sequencerFeed;

    /*//////////////////////////////////////////////////////////////////////////
                                    SET UP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        owner = makeAddr("owner");
        railsOwner = makeAddr("railsOwner");
        stranger = makeAddr("stranger");
        vaultRelayer = makeAddr("vaultRelayer");
        // A sequencer uptime feed must be a real contract; answer 0 means the sequencer is up.
        sequencerFeed = address(new MockChainlinkAggregator(0, 0));

        paymentRails = address(new PaymentRails(railsOwner));

        cowSettlement = new MockCowSettlement(DOMAIN_SEPARATOR, vaultRelayer);

        // Test contract is the factory owner; access control is exercised from `stranger` / `railsOwner`.
        // L1 profile: no sequencer uptime feed.
        factory = new CowSwapModuleFactory(address(this), address(cowSettlement), address(0), 0);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Deploys a fresh PaymentRails owned by `instanceOwner`.
    function deployPaymentRails(address instanceOwner) internal returns (address) {
        return address(new PaymentRails(instanceOwner));
    }
}
