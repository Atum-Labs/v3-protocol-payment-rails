// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test } from "forge-std/src/Test.sol";
import { DexSwapModule } from "../../../../../src/modules/swaps/DexSwapModule.sol";
import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { IChainlinkAggregatorV3 } from "../../../../../src/interfaces/IChainlinkAggregatorV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title DexSwapModuleL2SequencerFork_Test
/// @notice Fork tests for the L2 profile of DexSwapModule, against Base mainnet.
/// @dev The Ethereum and Avalanche DexSwapModule fork suites both deploy with
/// `sequencerUptimeFeed = address(0)`, which skips the sequencer branch of `_getOraclePrice`
/// entirely. This suite runs that branch against Base's real Chainlink L2 Sequencer Uptime Feed and
/// swaps through the real Uniswap V3 SwapRouter02, so the guard is proven against production
/// contracts rather than a mock.
///
///      Run with: forge test --match-contract DexSwapModuleL2SequencerFork -vvv
contract DexSwapModuleL2SequencerFork_Test is Test {
    /*//////////////////////////////////////////////////////////////////////////
                                BASE MAINNET CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Uniswap SwapRouter02 on Base; the legacy SwapRouter uses an incompatible
    /// `exactInputSingle` selector — see {ISwapRouter}.
    address internal constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;

    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;

    /// @dev At this block the sequencer feed reports up (answer 0) and last restarted ~80 days
    /// earlier, while its `updatedAt` is only hours old. The two timestamps being far apart is what
    /// makes this block able to tell the guard's two candidate readings apart.
    uint256 internal constant FORK_BLOCK = 51_340_000;

    uint256 internal constant GRACE_PERIOD = 3600;
    uint256 internal constant ORACLE_MAX_STALENESS = 86_400;
    uint256 internal constant DEFAULT_DEADLINE_SECONDS = 600;
    uint16 internal constant SLIPPAGE_BPS = 200;
    uint24 internal constant FEE_LOW = 500;

    uint256 internal constant WETH_SELL_AMOUNT = 1 ether;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    PaymentRails internal paymentRails;
    address internal owner;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }

        vm.createSelectFork("base", FORK_BLOCK);

        owner = makeAddr("owner");

        vm.startPrank(owner);
        module = new DexSwapModule(UNISWAP_V3_ROUTER, SEQUENCER_UPTIME_FEED, GRACE_PERIOD);
        paymentRails = new PaymentRails(owner);
        vm.stopPrank();

        deal(WETH, address(paymentRails), WETH_SELL_AMOUNT * 10);
        // validate() and estimateOutput() measure the caller's balance, so fund this contract
        // as the would-be PaymentRails for the direct-call tests.
        deal(WETH, address(this), WETH_SELL_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _wethToUsdcParams() internal view returns (bytes memory) {
        return module.encodeParams(
            DataTypes.DexSwapParams({
                targetToken: USDC,
                fee: FEE_LOW,
                maxSlippageBps: SLIPPAGE_BPS,
                sellTokenPriceFeed: ETH_USD_FEED,
                buyTokenPriceFeed: USDC_USD_FEED,
                maxStaleness: ORACLE_MAX_STALENESS,
                swapDeadlineSeconds: DEFAULT_DEADLINE_SECONDS,
                maxAmount: 0
            })
        );
    }

    function _liveFeed() internal view returns (uint256 startedAt, uint256 updatedAt) {
        int256 answer;
        (, answer, startedAt, updatedAt,) = IChainlinkAggregatorV3(SEQUENCER_UPTIME_FEED).latestRoundData();
        assertEq(answer, 0, "fork block must have the sequencer reporting up");
    }

    function _deployWithGrace(uint256 gracePeriod) internal returns (DexSwapModule) {
        return new DexSwapModule(UNISWAP_V3_ROUTER, SEQUENCER_UPTIME_FEED, gracePeriod);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    WIRING
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The constructor probes the router's `factory()`, so deploying against Base's real
    /// SwapRouter02 proves the probe accepts production wiring rather than only rejecting an EOA.
    function test_WhenDeployedAgainstRealBaseContracts_ShouldWireTheL2Profile() external view {
        assertEq(module.router(), UNISWAP_V3_ROUTER);
        assertEq(module.sequencerUptimeFeed(), SEQUENCER_UPTIME_FEED);
        assertEq(module.sequencerGracePeriod(), GRACE_PERIOD);
    }

    /*//////////////////////////////////////////////////////////////////////////
                            LIVE FEED — GRACE PERIOD GUARD
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The live feed's two timestamps must actually diverge at this block, otherwise every
    /// assertion below would hold for either reading and prove nothing.
    function test_WhenReadingTheLiveFeed_StartedAtAndUpdatedAtDiverge() external view {
        (uint256 startedAt, uint256 updatedAt) = _liveFeed();

        assertGt(updatedAt, startedAt, "positions 3 and 4 must be distinct on the live feed");
        assertGt(block.timestamp - startedAt, 30 days, "sequencer should be long recovered");
        assertLt(block.timestamp - updatedAt, 30 days, "feed should have been written recently");
    }

    /// @dev The whole point of this suite. The grace period is measured from `startedAt` (tuple
    /// position 3, the last sequencer status change), not `updatedAt` (position 4, the last routine
    /// feed write). The grace period here is chosen strictly between the two gaps, so the reading
    /// decides the outcome: measuring from `startedAt` allows the swap, measuring from `updatedAt`
    /// blocks it. It is deliberately larger than any production value — this test discriminates
    /// between two implementations, it does not model a real deployment.
    function test_WhenGraceSitsBetweenTheTwoTimestamps_ShouldMeasureFromStartedAt() external {
        (uint256 startedAt, uint256 updatedAt) = _liveFeed();

        uint256 sinceUpdated = block.timestamp - updatedAt;
        uint256 sinceStarted = block.timestamp - startedAt;
        uint256 grace = sinceUpdated + (sinceStarted - sinceUpdated) / 2;
        assertGt(grace, sinceUpdated, "grace must exceed the updatedAt gap to discriminate");
        assertLt(grace, sinceStarted, "grace must sit below the startedAt gap to discriminate");

        DexSwapModule strictModule = _deployWithGrace(grace);

        (bool isValid, string memory reason) = strictModule.validate(WETH, WETH_SELL_AMOUNT, _wethToUsdcParams());

        assertTrue(isValid, reason);
    }

    /// @dev The mirror image: with a grace period longer than the time since the sequencer actually
    /// recovered, the same live feed must block. Without this, a feed that is present but never
    /// consulted would pass the test above.
    function test_WhenGracePeriodHasNotElapsed_ShouldRejectTheSwap() external {
        (uint256 startedAt,) = _liveFeed();

        DexSwapModule strictModule = _deployWithGrace((block.timestamp - startedAt) + 1);

        (bool isValid, string memory reason) = strictModule.validate(WETH, WETH_SELL_AMOUNT, _wethToUsdcParams());

        assertFalse(isValid);
        assertEq(reason, "Oracle price unavailable");
    }

    /// @dev `estimateOutput` walks the same oracle path, so it must agree with `validate` rather
    /// than quoting a price the swap would refuse.
    function test_WhenGracePeriodHasNotElapsed_ShouldEstimateZero() external {
        (uint256 startedAt,) = _liveFeed();

        DexSwapModule strictModule = _deployWithGrace((block.timestamp - startedAt) + 1);

        (uint256 estimated,) = strictModule.estimateOutput(WETH, WETH_SELL_AMOUNT, _wethToUsdcParams());

        assertEq(estimated, 0, "a blocked oracle must not quote an output");
    }

    /*//////////////////////////////////////////////////////////////////////////
                    LIVE FEED — END TO END THROUGH REAL UNISWAP
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev The production path at the production grace period: the sequencer guard passes against
    /// the real feed, the oracle floor is computed from real Chainlink prices, and the swap settles
    /// through the real Uniswap V3 WETH/USDC pool.
    function test_WhenSequencerIsUpPastGrace_ShouldSwapThroughRealUniswap() external {
        bytes memory params = _wethToUsdcParams();

        (uint256 estimated,) = module.estimateOutput(WETH, WETH_SELL_AMOUNT, params);
        assertGt(estimated, 0, "oracle should quote an output while the sequencer is up");
        uint256 oracleFloor = estimated * (10_000 - SLIPPAGE_BPS) / 10_000;

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(module), WETH_SELL_AMOUNT, params, true);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);
        assertTrue(success, "swap should settle while the sequencer is up past grace");

        uint256 usdcReceived = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        assertGe(usdcReceived, oracleFloor, "output must clear the oracle floor");
        assertEq(wethBefore - IERC20(WETH).balanceOf(address(paymentRails)), WETH_SELL_AMOUNT, "sell amount debited");
        assertEq(IERC20(WETH).allowance(address(paymentRails), address(module)), 0, "approval revoked");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "module holds no residual buy token");
    }

    /// @dev The guard must gate the swap itself, not merely the view functions. With the grace
    /// period unelapsed, `executeAction` returns false and no tokens move.
    function test_WhenGracePeriodHasNotElapsed_ShouldNotMoveTokens() external {
        (uint256 startedAt,) = _liveFeed();

        DexSwapModule strictModule = _deployWithGrace((block.timestamp - startedAt) + 1);
        bytes memory params = _wethToUsdcParams();

        vm.prank(owner);
        paymentRails.configureToken(WETH, "SWAP", address(strictModule), WETH_SELL_AMOUNT, params, true);

        uint256 wethBefore = IERC20(WETH).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WETH, WETH_SELL_AMOUNT);

        assertFalse(success, "swap must not settle inside the grace period");
        assertEq(IERC20(WETH).balanceOf(address(paymentRails)), wethBefore, "sell token must not move");
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), usdcBefore, "no buy token should arrive");
        assertEq(IERC20(WETH).allowance(address(paymentRails), address(strictModule)), 0, "approval revoked");
    }
}
