// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { console2 } from "forge-std/src/Script.sol";
import { CowSwapModuleFactory } from "../../../src/modules/swaps/CowSwapModuleFactory.sol";

import { BaseScript } from "../Base.s.sol";

/// @title DeployCowSwapModuleFactory
/// @author Credit Cooperative
/// @notice Deploys the CowSwapModuleFactory contract. Run once per chain; use the factory to deploy
///         a dedicated CowSwapModule per PaymentRails instance.
///
///      `owner` is the only address allowed to call create()/createDeterministic(); pass the multi-sig.
///
///      Usage:
///        source .env && forge script scripts/solidity/deploy/DeployCowSwapModuleFactory.s.sol \
///          --sig "run(address,address,uint256)" <FACTORY_OWNER> <SEQUENCER_FEED_OR_0x0> <GRACE_PERIOD> \
///          --rpc-url $BASE_RPC_URL --broadcast -vvvv
///
///      <SEQUENCER_FEED_OR_0x0> and <GRACE_PERIOD> are two halves of one guard and the constructor
///      rejects a pair that cannot work, so they must be set together:
///        - L1 profile (Ethereum, Avalanche C-Chain, Sepolia): pass 0x0 and 0.
///        - L2 profile (Base, Arbitrum, Optimism): pass the chain's Chainlink L2 Sequencer Uptime
///          Feed and a grace period in (0, 1 days]. Chainlink's reference uses 3600.
///      Copying the L1 invocation to an L2 and changing only the feed is the mistake this rejects:
///      a zero grace period would reduce the module's check to `uint256 < 0`, which is never true.
contract DeployCowSwapModuleFactory is BaseScript {
    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;

    function run(
        address _owner,
        address _sequencerUptimeFeed,
        uint256 _sequencerGracePeriod
    )
        public
        broadcast
        returns (CowSwapModuleFactory factory)
    {
        factory = new CowSwapModuleFactory(_owner, GPV2_SETTLEMENT, _sequencerUptimeFeed, _sequencerGracePeriod);

        console2.log("=============================================================");
        console2.log("  DeployCowSwapModuleFactory - Complete");
        console2.log("=============================================================");
        console2.log("CowSwapModuleFactory:", address(factory));
        console2.log("Factory owner:       ", factory.owner());
        console2.log("GPv2Settlement:      ", GPV2_SETTLEMENT);
        console2.log("SequencerUptimeFeed: ", _sequencerUptimeFeed);
        console2.log("SequencerGracePeriod:", _sequencerGracePeriod);
        console2.log("");
        console2.log("Save to .env:");
        console2.log("  COW_SWAP_MODULE_FACTORY_ADDRESS=%s", vm.toString(address(factory)));
        console2.log("");
        console2.log("Then deploy a module per PaymentRails, from the factory owner:");
        console2.log(
            "  cast send $COW_SWAP_MODULE_FACTORY_ADDRESS 'create(address,address)' <MODULE_OWNER> <PAYMENT_RAILS>"
        );
        console2.log("  Verify module.paymentRails() and module.owner() before configureToken.");
        console2.log("=============================================================");
    }
}
