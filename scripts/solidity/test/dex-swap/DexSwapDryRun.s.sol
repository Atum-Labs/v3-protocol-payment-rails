// SPDX-License-Identifier: MIT
pragma solidity >=0.8.29 <0.9.0;

import { Script, console2 } from "forge-std/src/Script.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { PaymentRails } from "../../../../src/core/PaymentRails.sol";
import { DexSwapModule } from "../../../../src/modules/swaps/DexSwapModule.sol";
import { DataTypes } from "../../../../src/types/DataTypes.sol";
import { IChainlinkAggregatorV3 } from "../../../../src/interfaces/IChainlinkAggregatorV3.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title DexSwapDryRun
/// @author Credit Cooperative
/// @notice Full end-to-end simulation of the production keeper flow: deploy + configure + fund +
/// execute, using MEV-derived parameters and realistic min/max boundary scenarios.
/// @dev Simulation-only — no --broadcast needed. Override defaults via env vars for other chains/pairs.
///
///      Parameter derivation (per "DexSwapModule MEV Analysis & Validation Report"):
///      - Volatile pools: size `maxAmount` ≲ feeTier × poolDepth so no swap in
///        [minBalance, maxAmount] is profitably sandwichable. Worked example: WETH/USDC 0.3% pool
///        with ~$12.5M usable depth → threshold ≈ $37.5k → cap at $30k (20% safety margin).
///      - Low-fee stable pools: rely on a tight maxSlippageBps (10–25 bps) instead; the cap
///        threshold is low because the fee is tiny, but the slippage slack bounds the leak.
///      USD-denominated knobs are converted to token amounts on-fork via the live Chainlink feed,
///      so the same script stays realistic regardless of the current token price.
///
///      Scenarios simulated (what the keeper will actually do):
///        1. Typical inflow  — preview + swap the full balance in one call
///        2. Min boundary    — dust below minBalance is skipped (reverts); exactly minBalance swaps
///        3. Large inflow    — full-balance call blocked by maxAmount cap, then chunked drain via
///                             min(balance, maxAmount) until the balance is below minBalance
///
///      Usage (Ethereum mainnet fork, WETH -> USDC on the 0.3% pool):
///        source .env && forge script scripts/solidity/test/dex-swap/DexSwapDryRun.s.sol \
///          --rpc-url $ETHEREUM_RPC_URL -vvvv
///
///      Usage (custom pair / chain):
///        source .env && SELL_TOKEN=0x... BUY_TOKEN=0x... ROUTER=0x... POOL_FEE=500 \
///          MAX_AMOUNT_USD=10000 MAX_SLIPPAGE_BPS=25 \
///          forge script scripts/solidity/test/dex-swap/DexSwapDryRun.s.sol \
///            --rpc-url $RPC_URL -vvvv
contract DexSwapDryRun is Script, StdCheats {
    /*//////////////////////////////////////////////////////////////////////////
                                    CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    // Uniswap V3 SwapRouter on Ethereum mainnet
    /// @dev Uniswap SwapRouter02 on Ethereum mainnet; override with $ROUTER for other chains.
    address internal constant DEFAULT_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    address internal constant DEFAULT_SELL_TOKEN = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2; // WETH
    address internal constant DEFAULT_BUY_TOKEN = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC

    address internal constant DEFAULT_SELL_TOKEN_FEED = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419; // ETH/USD
    address internal constant DEFAULT_BUY_TOKEN_FEED = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6; // USDC/USD

    // MEV-derived production values (see derivation in the contract NatSpec above).
    uint24 internal constant DEFAULT_FEE = 3000; // 0.3% pool — the MEV report's worked example
    uint256 internal constant DEFAULT_MAX_AMOUNT_USD = 30_000; // < $37.5k sandwich threshold
    uint256 internal constant DEFAULT_MIN_BALANCE_USD = 500; // below this, gas dominates
    uint16 internal constant DEFAULT_SLIPPAGE_BPS = 100; // 1% — volatile pair; use 10–25 for stables

    // Inflow sizes for the keeper simulation.
    uint256 internal constant DEFAULT_TYPICAL_INFLOW_USD = 5000; // routine stream payout
    uint256 internal constant DEFAULT_LARGE_INFLOW_USD = 100_000; // forces chunked drain (4 chunks)

    // USDC/USD heartbeat is 24h (ETH/USD is 1h) — staleness must cover the slowest feed.
    uint256 internal constant DEFAULT_MAX_STALENESS = 90_000; // 25 hours
    uint256 internal constant DEFAULT_SWAP_DEADLINE = 300; // 5 minutes

    uint256 internal constant MAX_DRAIN_CHUNKS = 20; // safety bound for the drain loop

    struct Config {
        address routerAddr;
        address sellToken;
        address buyToken;
        address sellTokenFeed;
        address buyTokenFeed;
        uint16 maxSlippageBps;
        uint24 fee;
        uint256 maxStaleness;
        uint256 swapDeadlineSeconds;
        uint256 maxAmountUsd;
        uint256 minBalanceUsd;
        uint256 typicalInflowUsd;
        uint256 largeInflowUsd;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    STATE
    //////////////////////////////////////////////////////////////////////////*/

    Config internal cfg;
    PaymentRails internal paymentRails;
    DexSwapModule internal module;
    bytes internal moduleParams;
    address internal deployer;

    // USD knobs converted to sellToken units via the live Chainlink feed.
    uint256 internal maxAmountTokens;
    uint256 internal minBalanceTokens;

    /*//////////////////////////////////////////////////////////////////////////
                                    ENTRYPOINT
    //////////////////////////////////////////////////////////////////////////*/

    function run() public {
        cfg = _loadConfig();
        (deployer,) = _deriveDeployer();

        console2.log("=============================================================");
        console2.log("  DexSwap Dry Run - production keeper simulation");
        console2.log("=============================================================");
        console2.log("Deployer:       ", deployer);
        console2.log("Chain ID:       ", block.chainid);
        console2.log("Router:         ", cfg.routerAddr);
        console2.log("Sell token:     ", cfg.sellToken);
        console2.log("Buy token:      ", cfg.buyToken);
        console2.log("Pool fee:       ", uint256(cfg.fee));
        console2.log("Slippage bps:   ", uint256(cfg.maxSlippageBps));

        _deployAndConfigure();

        _scenarioTypicalInflow();
        _scenarioMinBoundary();
        _scenarioLargeInflowChunkedDrain();

        _finalVerification();
    }

    /*//////////////////////////////////////////////////////////////////////////
                                DEPLOY + CONFIGURE
    //////////////////////////////////////////////////////////////////////////*/

    function _deployAndConfigure() internal {
        vm.startPrank(deployer);

        // Production owner is a multi-sig; the deployer stands in for it in this simulation.
        paymentRails = new PaymentRails(deployer);
        console2.log("[DEPLOYED] PaymentRails:   ", address(paymentRails));

        // sequencerUptimeFeed = address(0) and gracePeriod = 0 for L1 dry run
        module = new DexSwapModule(cfg.routerAddr, address(0), 0);
        console2.log("[DEPLOYED] DexSwapModule:  ", address(module));

        vm.stopPrank();

        // Convert USD-denominated knobs to sellToken units at the live oracle price.
        uint256 price = _oraclePrice(cfg.sellTokenFeed);
        maxAmountTokens = _usdToSellToken(cfg.maxAmountUsd, price);
        minBalanceTokens = _usdToSellToken(cfg.minBalanceUsd, price);

        console2.log("");
        console2.log("MEV-derived configuration (live oracle price):");
        console2.log("  Sell token oracle price (feed decimals):", price);
        console2.log("  maxAmount  USD / tokens: ", cfg.maxAmountUsd, maxAmountTokens);
        console2.log("  minBalance USD / tokens: ", cfg.minBalanceUsd, minBalanceTokens);

        moduleParams = module.encodeParams(
            DataTypes.DexSwapParams({
                targetToken: cfg.buyToken,
                fee: cfg.fee,
                maxSlippageBps: cfg.maxSlippageBps,
                sellTokenPriceFeed: cfg.sellTokenFeed,
                buyTokenPriceFeed: cfg.buyTokenFeed,
                maxStaleness: cfg.maxStaleness,
                swapDeadlineSeconds: cfg.swapDeadlineSeconds,
                maxAmount: maxAmountTokens
            })
        );

        vm.prank(deployer);
        paymentRails.configureToken(cfg.sellToken, "SWAP", address(module), minBalanceTokens, moduleParams, true);
        console2.log("[CONFIGURED] Token route set (maxAmount cap + minBalance floor active)");
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    SCENARIOS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Scenario 1: routine inflow lands, keeper previews and swaps the full balance.
    function _scenarioTypicalInflow() internal {
        console2.log("");
        console2.log("=============================================================");
        console2.log("  SCENARIO 1: typical inflow, single swap");
        console2.log("=============================================================");

        uint256 amount = _usdToSellToken(cfg.typicalInflowUsd, _oraclePrice(cfg.sellTokenFeed));
        deal(cfg.sellToken, address(paymentRails), amount);
        console2.log("[FUNDED] inflow USD / tokens:", cfg.typicalInflowUsd, amount);

        // Keeper pre-flight: previewExecution gives the oracle-mid estimate for the full balance.
        (uint256 preview, address outputToken) = paymentRails.previewExecution(cfg.sellToken);
        console2.log("[PREVIEW] estimated output:", preview);
        require(outputToken == cfg.buyToken, "preview output token mismatch");
        require(preview > 0, "preview returned zero estimate");

        _swapAndReport("typical inflow", amount);
    }

    /// @dev Scenario 2: minBalance boundary — dust is skipped, exactly minBalance executes.
    function _scenarioMinBoundary() internal {
        console2.log("");
        console2.log("=============================================================");
        console2.log("  SCENARIO 2: minBalance boundary");
        console2.log("=============================================================");

        // Dust below minBalance: PaymentRails reverts, which is the keeper's signal to skip.
        uint256 dust = minBalanceTokens - 1;
        deal(cfg.sellToken, address(paymentRails), dust);
        try paymentRails.executeAction(cfg.sellToken, dust) returns (bool) {
            revert("dust below minBalance must revert");
        } catch {
            console2.log("[OK] dust below minBalance rejected - keeper skips, no gas wasted on swap");
        }

        // Exactly minBalance: the smallest swap the keeper will ever submit.
        deal(cfg.sellToken, address(paymentRails), minBalanceTokens);
        _swapAndReport("exactly minBalance", minBalanceTokens);
    }

    /// @dev Scenario 3: large inflow above the MEV cap. A naive full-balance call is blocked by
    /// the module; the keeper drains in min(balance, maxAmount) chunks instead. In production the
    /// chunks land in separate blocks; sequential calls here are equivalent for this simulation.
    function _scenarioLargeInflowChunkedDrain() internal {
        console2.log("");
        console2.log("=============================================================");
        console2.log("  SCENARIO 3: large inflow, maxAmount cap + chunked drain");
        console2.log("=============================================================");

        uint256 inflow = _usdToSellToken(cfg.largeInflowUsd, _oraclePrice(cfg.sellTokenFeed));
        deal(cfg.sellToken, address(paymentRails), inflow);
        console2.log("[FUNDED] inflow USD / tokens:", cfg.largeInflowUsd, inflow);

        // Naive full-balance attempt: module rejects above-cap amounts, nothing moves.
        uint256 balanceBefore = IERC20(cfg.sellToken).balanceOf(address(paymentRails));
        bool success = paymentRails.executeAction(cfg.sellToken, inflow);
        require(!success, "swap above maxAmount must return false");
        require(
            IERC20(cfg.sellToken).balanceOf(address(paymentRails)) == balanceBefore,
            "no sell tokens may move on a capped rejection"
        );
        console2.log("[OK] full-balance swap above maxAmount blocked; no tokens moved");

        // Real keeper behavior: chunk the balance through the cap until below minBalance.
        uint256 chunks;
        uint256 balance = balanceBefore;
        while (balance >= minBalanceTokens) {
            require(chunks < MAX_DRAIN_CHUNKS, "drain loop exceeded safety bound");
            uint256 amount = balance < maxAmountTokens ? balance : maxAmountTokens;
            chunks++;
            console2.log("");
            console2.log("--- drain chunk", chunks, "amount:", amount);
            _swapAndReport("drain chunk", amount);
            balance = IERC20(cfg.sellToken).balanceOf(address(paymentRails));
        }

        console2.log("");
        console2.log("[OK] balance drained in chunks:", chunks);
        console2.log("     residual sell token (below minBalance):", balance);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Executes one swap and reports execution quality: realized output vs. the oracle-mid
    /// estimate, in bps. A success implies the module's oracle floor held (it reverts otherwise),
    /// so realized slippage is structurally bounded by maxSlippageBps.
    function _swapAndReport(string memory label, uint256 amount) internal {
        (uint256 expected,) = module.estimateOutput(cfg.sellToken, amount, moduleParams);
        require(expected > 0, "oracle estimate unavailable");
        uint256 floor = (expected * (10_000 - uint256(cfg.maxSlippageBps))) / 10_000;

        uint256 buyBefore = IERC20(cfg.buyToken).balanceOf(address(paymentRails));
        bool success = paymentRails.executeAction(cfg.sellToken, amount);
        require(success, string.concat("executeAction failed: ", label));
        uint256 received = IERC20(cfg.buyToken).balanceOf(address(paymentRails)) - buyBefore;

        console2.log("[EXECUTED]", label);
        console2.log("  oracle-mid estimate:", expected);
        console2.log("  received:           ", received);
        if (received >= expected) {
            console2.log("  price improvement bps:", ((received - expected) * 10_000) / expected);
        } else {
            console2.log("  realized slippage bps:", ((expected - received) * 10_000) / expected);
        }

        require(received >= floor, "received below oracle floor");
        require(IERC20(cfg.sellToken).balanceOf(address(module)) == 0, "module retained sell tokens");
    }

    /// @dev Reads the latest price from a Chainlink feed, in feed decimals.
    function _oraclePrice(address feed) internal view returns (uint256) {
        (, int256 answer,,,) = IChainlinkAggregatorV3(feed).latestRoundData();
        require(answer > 0, "invalid oracle answer");
        return uint256(answer);
    }

    /// @dev Converts a whole-USD amount to sellToken units at the given feed price.
    function _usdToSellToken(uint256 usd, uint256 price) internal view returns (uint256) {
        uint8 feedDecimals = IChainlinkAggregatorV3(cfg.sellTokenFeed).decimals();
        uint8 tokenDecimals = IERC20Metadata(cfg.sellToken).decimals();
        return (usd * (10 ** feedDecimals) * (10 ** tokenDecimals)) / price;
    }

    function _finalVerification() internal view {
        uint256 moduleSellBalance = IERC20(cfg.sellToken).balanceOf(address(module));
        uint256 moduleBuyBalance = IERC20(cfg.buyToken).balanceOf(address(module));
        uint256 paymentRailsSellBalance = IERC20(cfg.sellToken).balanceOf(address(paymentRails));
        uint256 totalReceived = IERC20(cfg.buyToken).balanceOf(address(paymentRails));

        console2.log("");
        console2.log("=============================================================");
        console2.log("  FINAL VERIFICATION");
        console2.log("=============================================================");
        console2.log("Module sell token leftover:      ", moduleSellBalance, " (expected: 0)");
        console2.log("Module buy token leftover:       ", moduleBuyBalance, " (expected: 0)");
        console2.log("PaymentRails residual sell token:", paymentRailsSellBalance);
        console2.log("PaymentRails total buy token:    ", totalReceived);

        require(moduleSellBalance == 0, "Module still holds sell tokens");
        require(moduleBuyBalance == 0, "Module still holds buy tokens");
        require(paymentRailsSellBalance < minBalanceTokens, "Residual sell token above minBalance");
        require(totalReceived > 0, "No buy token received");

        console2.log("");
        console2.log("=============================================================");
        console2.log("  ALL CHECKS PASSED");
        console2.log("  Keeper flow validated with MEV-derived maxAmount/minBalance");
        console2.log("  Safe to deploy for real with --broadcast");
        console2.log("  Next: deploy/DeployPaymentRails.s.sol + deploy/DeployDexSwapModule.s.sol");
        console2.log("=============================================================");
    }

    function _loadConfig() internal view returns (Config memory config) {
        config.routerAddr = vm.envOr("ROUTER", DEFAULT_ROUTER);
        config.sellToken = vm.envOr("SELL_TOKEN", DEFAULT_SELL_TOKEN);
        config.buyToken = vm.envOr("BUY_TOKEN", DEFAULT_BUY_TOKEN);
        config.sellTokenFeed = vm.envOr("SELL_TOKEN_FEED", DEFAULT_SELL_TOKEN_FEED);
        config.buyTokenFeed = vm.envOr("BUY_TOKEN_FEED", DEFAULT_BUY_TOKEN_FEED);
        config.maxSlippageBps = uint16(vm.envOr("MAX_SLIPPAGE_BPS", uint256(DEFAULT_SLIPPAGE_BPS)));
        config.fee = uint24(vm.envOr("POOL_FEE", uint256(DEFAULT_FEE)));
        config.maxStaleness = vm.envOr("MAX_STALENESS", DEFAULT_MAX_STALENESS);
        config.swapDeadlineSeconds = vm.envOr("SWAP_DEADLINE", DEFAULT_SWAP_DEADLINE);
        config.maxAmountUsd = vm.envOr("MAX_AMOUNT_USD", DEFAULT_MAX_AMOUNT_USD);
        config.minBalanceUsd = vm.envOr("MIN_BALANCE_USD", DEFAULT_MIN_BALANCE_USD);
        config.typicalInflowUsd = vm.envOr("TYPICAL_INFLOW_USD", DEFAULT_TYPICAL_INFLOW_USD);
        config.largeInflowUsd = vm.envOr("LARGE_INFLOW_USD", DEFAULT_LARGE_INFLOW_USD);

        require(config.minBalanceUsd > 0, "MIN_BALANCE_USD must be non-zero");
        require(config.maxAmountUsd > config.minBalanceUsd, "MAX_AMOUNT_USD must exceed MIN_BALANCE_USD");
        require(config.largeInflowUsd > config.maxAmountUsd, "LARGE_INFLOW_USD must exceed MAX_AMOUNT_USD");
    }

    function _deriveDeployer() internal returns (address deployerAddr, uint256 deployerKey) {
        address ethFrom = vm.envOr("ETH_FROM", address(0));
        if (ethFrom != address(0)) {
            deployerAddr = ethFrom;
            deployerKey = vm.envUint("PRIVATE_KEY");
        } else {
            string memory defaultMnemonic = "test test test test test test test test test test test junk";
            string memory mnemonic = vm.envOr("MNEMONIC", defaultMnemonic);
            (deployerAddr, deployerKey) = deriveRememberKey(mnemonic, 0);
        }
    }
}
