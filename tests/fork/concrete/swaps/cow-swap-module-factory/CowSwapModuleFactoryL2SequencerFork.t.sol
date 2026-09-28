// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { CowSwapModule } from "../../../../../src/modules/swaps/CowSwapModule.sol";
import { CowSwapModuleFactory } from "../../../../../src/modules/swaps/CowSwapModuleFactory.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";
import { IChainlinkAggregatorV3 } from "../../../../../src/interfaces/IChainlinkAggregatorV3.sol";

/// @title CowSwapModuleFactoryL2SequencerFork_Test
/// @notice Fork tests for the L2 profile of CowSwapModuleFactory, against Base mainnet.
/// @dev The Ethereum fork suite deploys with `sequencerUptimeFeed = address(0)`, which skips the
/// constructor's sequencer-feed check entirely. These tests run that check against Base's real
/// Chainlink L2 Sequencer Uptime Feed, alongside the real GPv2Settlement deployment, so the guard is
/// proven to accept production configuration rather than only to reject an EOA in a unit test.
///
///      Run with: forge test --match-contract CowSwapModuleFactoryL2SequencerFork -vvv
contract CowSwapModuleFactoryL2SequencerFork_Test is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                BASE MAINNET CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    address internal constant GPV2_SETTLEMENT = 0x9008D19f58AAbD9eD0D60971565AA8510560ab41;
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;

    /// @dev At this block the sequencer feed reports up (answer 0) and last restarted ~80 days
    /// earlier, so a normal grace period is long past.
    uint256 internal constant FORK_BLOCK = 51_340_000;

    uint256 internal constant GRACE_PERIOD = 3600;
    uint256 internal constant ORACLE_MAX_STALENESS = 86_400;
    uint16 internal constant SLIPPAGE_BPS = 200;
    uint32 internal constant VALIDITY_DURATION = 3600;

    uint256 internal constant WETH_SELL_AMOUNT = 1 ether;

    bytes32 internal constant DEFAULT_SALT = bytes32(uint256(1));

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    CowSwapModuleFactory internal factory;
    PaymentRails internal paymentRails;

    address internal factoryOwner;
    address internal railsOwner;
    address internal moduleOwner;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }

        vm.createSelectFork("base", FORK_BLOCK);

        factoryOwner = makeAddr("factoryOwner");
        railsOwner = makeAddr("railsOwner");
        moduleOwner = makeAddr("moduleOwner");

        paymentRails = new PaymentRails(railsOwner);
        factory = new CowSwapModuleFactory(factoryOwner, GPV2_SETTLEMENT, SEQUENCER_UPTIME_FEED, GRACE_PERIOD);

        // validate() measures the caller's balance, so fund this contract as the would-be PaymentRails.
        deal(WETH, address(this), WETH_SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _swapParams() internal pure returns (bytes memory) {
        return abi.encode(
            USDC, SLIPPAGE_BPS, ETH_USD_FEED, USDC_USD_FEED, ORACLE_MAX_STALENESS, VALIDITY_DURATION, bytes32(0)
        );
    }

    function _createModule(CowSwapModuleFactory target) internal returns (CowSwapModule) {
        vm.prank(factoryOwner);
        return CowSwapModule(target.create(moduleOwner, address(paymentRails)));
    }

    /*//////////////////////////////////////////////////////////////////////////
                                CONSTRUCTOR GUARD
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenSequencerFeedIsTheRealChainlinkFeed_ShouldDeploy() external view {
        assertEq(factory.sequencerUptimeFeed(), SEQUENCER_UPTIME_FEED);
        assertEq(factory.sequencerGracePeriod(), GRACE_PERIOD);
        assertEq(factory.cowSettlement(), GPV2_SETTLEMENT);
    }

    function test_RevertWhen_SequencerFeedIsEOA() external {
        address eoa = makeAddr("eoaSequencerFeed");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_SequencerFeedNotContract.selector, eoa));
        new CowSwapModuleFactory(factoryOwner, GPV2_SETTLEMENT, eoa, GRACE_PERIOD);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                MODULE WIRING
    //////////////////////////////////////////////////////////////////////////*/

    function test_WhenCreate_ShouldWireTheRealSequencerFeed() external {
        CowSwapModule module = _createModule(factory);
        assertEq(module.sequencerUptimeFeed(), SEQUENCER_UPTIME_FEED);
        assertEq(module.sequencerGracePeriod(), GRACE_PERIOD);
        assertEq(module.cowSettlement(), GPV2_SETTLEMENT);
    }

    function test_WhenCreateDeterministic_ShouldWireTheRealSequencerFeed() external {
        address predicted = factory.predictDeterministicAddress(moduleOwner, address(paymentRails), DEFAULT_SALT);

        vm.prank(factoryOwner);
        CowSwapModule module =
            CowSwapModule(factory.createDeterministic(moduleOwner, address(paymentRails), DEFAULT_SALT));

        assertEq(address(module), predicted);
        assertEq(module.sequencerUptimeFeed(), SEQUENCER_UPTIME_FEED);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            LIVE SEQUENCER FEED READS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Proves the accepted feed is actually readable: validation walks the sequencer check
    /// against the live feed before it ever touches the price feeds.
    function test_WhenSequencerIsUp_ShouldValidateAgainstTheLiveFeed() external {
        CowSwapModule module = _createModule(factory);

        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, _swapParams());

        assertTrue(isValid, reason);
        assertEq(reason, "");
    }

    /// @dev The mirror image: inside the grace window the same live feed must block the order.
    /// Without this, a feed that is merely present but never consulted would pass the test above.
    /// @dev The window is reached by reading the live feed's own `startedAt` and moving the clock to
    /// one second after it, rather than by configuring an absurd grace period. The feed, its answer
    /// and its restart timestamp are all real Base state — only `block.timestamp` moves — so this
    /// exercises the production GRACE_PERIOD (3600) that every module is actually deployed with.
    function test_WhenGracePeriodHasNotElapsed_ShouldRejectTheOrder() external {
        CowSwapModule module = _createModule(factory);

        (, int256 answer, uint256 startedAt, uint256 updatedAt,) =
            IChainlinkAggregatorV3(SEQUENCER_UPTIME_FEED).latestRoundData();
        assertEq(answer, 0, "fork block must have the sequencer reporting up");

        // The two timestamps are weeks apart on this feed, so a test that measured from the wrong
        // one would still pass here. Assert they diverge, then measure from `startedAt` — the value
        // the guard is specified against.
        assertTrue(updatedAt > startedAt, "positions 3 and 4 must be distinct on the live feed");
        vm.warp(startedAt + 1);

        (bool isValid, string memory reason) = module.validate(WETH, WETH_SELL_AMOUNT, _swapParams());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /// @dev The grace period and the uptime feed are two halves of one guard, so the constructor
    /// rejects a pair that cannot work. A value this large would make every module the factory
    /// deploys permanently unable to price an order.
    function test_RevertWhen_GracePeriodExceedsTheBound() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_InvalidGracePeriod.selector, 365 days));
        new CowSwapModuleFactory(factoryOwner, GPV2_SETTLEMENT, SEQUENCER_UPTIME_FEED, 365 days);
    }

    /// @dev The opposite half: a zero grace period against a real feed would reduce the module's
    /// check to `block.timestamp - startedAt < 0`, which is never true for uint256.
    function test_RevertWhen_GracePeriodIsZeroWithARealFeed() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_InvalidGracePeriod.selector, 0));
        new CowSwapModuleFactory(factoryOwner, GPV2_SETTLEMENT, SEQUENCER_UPTIME_FEED, 0);
    }
}
