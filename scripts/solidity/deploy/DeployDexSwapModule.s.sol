// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { DexSwapModule } from "../../../src/modules/swaps/DexSwapModule.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployDexSwapModule
/// @author Credit Cooperative
/// @notice Deploys the DexSwapModule. Stateless — a single instance can be shared across PaymentRails.
///
///      The router MUST be Uniswap SwapRouter02 for the target chain:
///        ethereum / arbitrum / optimism / polygon  0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45
///        base                                      0x2626664c2603336E57B271c5C0b26F421741e481
///        avalanche                                 0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE
///
///      `sequencerUptimeFeed` is address(0) on chains without a Chainlink sequencer uptime feed.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployDexSwapModule.s.sol \
///          --sig "run(address,address,uint256)" <ROUTER> <SEQUENCER_FEED_OR_0x0> <GRACE_PERIOD> \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
contract DeployDexSwapModule is BaseScript {
    function run(
        address _router,
        address _sequencerUptimeFeed,
        uint256 _sequencerGracePeriod
    )
        public
        broadcast
        returns (DexSwapModule module)
    {
        module = new DexSwapModule(_router, _sequencerUptimeFeed, _sequencerGracePeriod);

        console2.log("=============================================================");
        console2.log("  DeployDexSwapModule - Complete");
        console2.log("=============================================================");
        console2.log("Router:             ", _router);
        console2.log("SequencerFeed:      ", _sequencerUptimeFeed);
        console2.log("GracePeriod:         %s", vm.toString(_sequencerGracePeriod));
        console2.log("DexSwapModule:      ", address(module));
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  DEX_SWAP_MODULE=%s", vm.toString(address(module)));
        console2.log("");
        console2.log("Next steps:");
        console2.log("  1. Configure on PaymentRails: cast send $PAYMENT_RAILS_ADDRESS 'configureToken(...)' ...");
        console2.log("=============================================================");
    }
}
