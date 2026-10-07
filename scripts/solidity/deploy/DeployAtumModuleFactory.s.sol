// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { AtumModuleFactory } from "../../../src/modules/contrib/bridges/AtumModuleFactory.sol";
import { IPaymentRailsFactory } from "../../../src/interfaces/IPaymentRailsFactory.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployAtumModuleFactory
/// @author Credit Cooperative
/// @notice Deploys the AtumModuleFactory contract. Run once per chain; use the factory to deploy
///         a dedicated AtumModule per PaymentRails instance (e.g. per borrower).
///
///      `owner` is the only address allowed to call create()/createDeterministic(); pass the multi-sig.
///
///      Usage:
///        PAYMENT_RAILS_FACTORY=<factory> source .env && \
///          forge script scripts/solidity/deploy/DeployAtumModuleFactory.s.sol \
///          --sig "run(address)" <FACTORY_OWNER> \
///          --rpc-url $AVALANCHE_RPC_URL --broadcast -vvvv
contract DeployAtumModuleFactory is BaseScript {
    /// @dev Canonical Permit2, deployed at the same address on every supported chain (incl. Avalanche).
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run(address _owner) public broadcast returns (AtumModuleFactory factory) {
        address railsFactory = vm.envAddress("PAYMENT_RAILS_FACTORY");
        factory = new AtumModuleFactory(_owner, PERMIT2, IPaymentRailsFactory(railsFactory));

        console2.log("=============================================================");
        console2.log("  DeployAtumModuleFactory - Complete");
        console2.log("=============================================================");
        console2.log("AtumModuleFactory:", address(factory));
        console2.log("Factory owner:    ", factory.owner());
        console2.log("Permit2:          ", PERMIT2);
        console2.log("PaymentRailsFactory:", railsFactory);
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  ATUM_MODULE_FACTORY_ADDRESS=%s", vm.toString(address(factory)));
        console2.log("");
        console2.log("Then deploy a module per PaymentRails, from the factory owner:");
        console2.log("  cast send $ATUM_MODULE_FACTORY_ADDRESS 'create(address,address,address)' \\");
        console2.log("    <MODULE_OWNER> <PAYMENT_RAILS> <KEEPER>");
        console2.log("  Verify module.paymentRails(), module.owner() and module.keeper()");
        console2.log("  before configureToken.");
        console2.log("=============================================================");
    }
}
