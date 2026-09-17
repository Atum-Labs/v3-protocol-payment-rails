// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { AtumModule } from "../../../src/modules/contrib/bridges/AtumModule.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployAtumModule
/// @author Atum Labs
/// @notice Deploys one PaymentRails-bound AtumModule instance.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployAtumModule.s.sol \
///          --sig "run(address,address,address,address)" <PERMIT2> <NODE> <OWNER> <KEEPER> \
///          --rpc-url $SOURCE_RPC_URL --broadcast -vvvv
contract DeployAtumModule is BaseScript {
    function run(
        address permit2,
        address paymentRails,
        address owner,
        address keeper
    )
        public
        broadcast
        returns (AtumModule module)
    {
        module = new AtumModule(permit2, paymentRails, owner, keeper);

        console2.log("=============================================================");
        console2.log("  DeployAtumModule - Complete");
        console2.log("=============================================================");
        console2.log("Owner:                    ", owner);
        console2.log("Keeper:                   ", keeper);
        console2.log("PaymentRails:                     ", paymentRails);
        console2.log("Permit2:                  ", permit2);
        console2.log("AtumModule:               ", address(module));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  ATUM_MODULE=%s", vm.toString(address(module)));
        console2.log("=============================================================");
    }
}
