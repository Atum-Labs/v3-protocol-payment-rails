// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { Test, console2 } from "forge-std/src/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { PaymentRails } from "../../../../../src/core/PaymentRails.sol";
import { DexSwapModule } from "../../../../../src/modules/swaps/DexSwapModule.sol";
import { ISwapRouter } from "../../../../../src/interfaces/ISwapRouter.sol";
import { DataTypes } from "../../../../../src/types/DataTypes.sol";
import { Errors } from "../../../../../src/libraries/Errors.sol";

/// @notice Avalanche C-Chain fork tests for DexSwapModule.
/// @dev Tree: tests/fork/concrete/swaps/dex-swap-module/dexSwapModuleAvalancheFork.tree
///
/// Avalanche has no original Uniswap V3 SwapRouter, so these tests exercise the SwapRouter02
/// calldata path against a real router and real pools. Avalanche is an L1, so
/// `sequencerUptimeFeed` is address(0) throughout.
abstract contract DexSwapModuleAvalancheForkBase is Test {
    /*//////////////////////////////////////////////////////////////////////////
                            AVALANCHE C-CHAIN CONSTANTS
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Uniswap SwapRouter02 on Avalanche; router addresses are chain-specific.
    address internal constant SWAP_ROUTER_02 = 0xbb00FF08d01D300023C629E8fFfFcb65A5a578cE;

    /// @dev Uniswap V3 factory on Avalanche; the router must report this from `factory()`.
    address internal constant UNISWAP_V3_FACTORY = 0x740b1c1de25031C31FF4fC9A62f554A55cdC1baD;

    /// @dev The Ethereum SwapRouter address; has no code on Avalanche, asserted below.
    address internal constant ETHEREUM_SWAP_ROUTER_V1 = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    address internal constant USDC = 0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E;
    address internal constant WAVAX = 0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7;

    address internal constant AVAX_USD_FEED = 0x0A77230d17318075983913bC2145DB16C7366156;
    address internal constant USDC_USD_FEED = 0xF096872672F44d6EBA71458D74fe67F9a77a23B9;

    /// @dev USDC/USD on Avalanche has a 24h heartbeat and observed gaps of up to 86_422s, so a
    /// flat 86_400 window rejects swaps in the minutes before each daily update.
    uint256 internal constant ORACLE_MAX_STALENESS = 90_000; // 25 hours
    uint256 internal constant DEFAULT_DEADLINE_SECONDS = 600; // 10 minutes

    uint256 internal constant WAVAX_SELL_AMOUNT = 1 ether;
    uint256 internal constant USDC_SELL_AMOUNT = 100e6;

    uint24 internal constant FEE_LOW = 500;

    /*//////////////////////////////////////////////////////////////////////////
                                TEST CONTRACTS
    //////////////////////////////////////////////////////////////////////////*/

    DexSwapModule internal module;
    PaymentRails internal paymentRails;
    address internal owner;

    /*//////////////////////////////////////////////////////////////////////////
                                    SETUP
    //////////////////////////////////////////////////////////////////////////*/

    /// @dev Unpinned: the public Avalanche endpoint serves no archive state. Assertions are
    /// therefore written against live oracle prices rather than hardcoded amounts.
    function setUp() public virtual {
        string memory rpcUrl = vm.envOr("AVALANCHE_RPC_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            vm.skip(true);
        }

        vm.createSelectFork("avalanche");

        owner = makeAddr("owner");

        vm.startPrank(owner);
        module = new DexSwapModule(SWAP_ROUTER_02, address(0), 0);
        paymentRails = new PaymentRails(owner);
        vm.stopPrank();

        deal(WAVAX, address(paymentRails), WAVAX_SELL_AMOUNT * 100);
        deal(USDC, address(paymentRails), USDC_SELL_AMOUNT * 100);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                    HELPERS
    //////////////////////////////////////////////////////////////////////////*/

    function _buildSwapParams(
        address targetToken,
        uint16 maxSlippageBps,
        address sellTokenPriceFeed,
        address buyTokenPriceFeed
    )
        internal
        view
        returns (bytes memory)
    {
        return module.encodeParams(
            DataTypes.DexSwapParams({
                targetToken: targetToken,
                fee: FEE_LOW,
                maxSlippageBps: maxSlippageBps,
                sellTokenPriceFeed: sellTokenPriceFeed,
                buyTokenPriceFeed: buyTokenPriceFeed,
                maxStaleness: ORACLE_MAX_STALENESS,
                swapDeadlineSeconds: DEFAULT_DEADLINE_SECONDS,
                maxAmount: 0
            })
        );
    }

    function _wavaxToUsdcParams(uint16 maxSlippageBps) internal view returns (bytes memory) {
        return _buildSwapParams(USDC, maxSlippageBps, AVAX_USD_FEED, USDC_USD_FEED);
    }

    function _usdcToWavaxParams(uint16 maxSlippageBps) internal view returns (bytes memory) {
        return _buildSwapParams(WAVAX, maxSlippageBps, USDC_USD_FEED, AVAX_USD_FEED);
    }

    function _configure(address token, bytes memory params) internal {
        vm.prank(owner);
        paymentRails.configureToken(token, "SWAP", address(module), 0, params, true);
    }

    function _assertModuleIsClean() internal view {
        assertEq(IERC20(WAVAX).balanceOf(address(module)), 0, "module retained WAVAX");
        assertEq(IERC20(USDC).balanceOf(address(module)), 0, "module retained USDC");
        assertEq(IERC20(WAVAX).allowance(address(module), SWAP_ROUTER_02), 0, "WAVAX allowance not revoked");
        assertEq(IERC20(USDC).allowance(address(module), SWAP_ROUTER_02), 0, "USDC allowance not revoked");
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ROUTER WIRING TESTS
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleAvalancheForkRouterTest is DexSwapModuleAvalancheForkBase {
    function test_Router_IsRealUniswapRouterOnAvalanche() external view {
        assertEq(module.router(), SWAP_ROUTER_02, "router immutable");
        assertEq(ISwapRouter(SWAP_ROUTER_02).factory(), UNISWAP_V3_FACTORY, "router reports Avalanche UniV3 factory");
        assertGt(UNISWAP_V3_FACTORY.code.length, 0, "factory must be a contract");
    }

    function test_EthereumSwapRouterV1_DoesNotExistOnAvalanche() external {
        assertEq(ETHEREUM_SWAP_ROUTER_V1.code.length, 0, "v1 router unexpectedly present on Avalanche");

        vm.expectRevert(
            abi.encodeWithSelector(Errors.DexSwapModule_RouterNotContract.selector, ETHEREUM_SWAP_ROUTER_V1)
        );
        new DexSwapModule(ETHEREUM_SWAP_ROUTER_V1, address(0), 0);
    }

    /// @dev `swapDeadlineSeconds` is only meaningful if the real router's multicall enforces it.
    function test_RouterMulticall_EnforcesDeadline() external {
        bytes[] memory batch = new bytes[](1);
        batch[0] = abi.encodeCall(
            ISwapRouter.exactInputSingle,
            (ISwapRouter.ExactInputSingleParams({
                    tokenIn: WAVAX,
                    tokenOut: USDC,
                    fee: FEE_LOW,
                    recipient: address(this),
                    amountIn: WAVAX_SELL_AMOUNT,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                }))
        );

        vm.expectRevert(bytes("Transaction too old"));
        ISwapRouter(SWAP_ROUTER_02).multicall(block.timestamp - 1, batch);
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        WAVAX -> USDC SWAP TESTS
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleAvalancheForkWavaxToUsdcTest is DexSwapModuleAvalancheForkBase {
    function test_Swap_WavaxToUsdc_ViaPaymentRails() external {
        bytes memory params = _wavaxToUsdcParams(300);
        _configure(WAVAX, params);

        (uint256 estimate,) = module.estimateOutput(WAVAX, WAVAX_SELL_AMOUNT, params);
        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WAVAX, WAVAX_SELL_AMOUNT);

        uint256 received = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        console2.log("WAVAX -> USDC received:", received, "oracle estimate:", estimate);

        assertTrue(success, "swap should succeed against real SwapRouter02");
        assertEq(
            wavaxBefore - IERC20(WAVAX).balanceOf(address(paymentRails)), WAVAX_SELL_AMOUNT, "WAVAX not fully spent"
        );
        assertGe(received, estimate * 9700 / 10_000, "output below oracle floor");
        assertLe(received, estimate * 10_300 / 10_000, "output implausibly above oracle estimate");
        _assertModuleIsClean();
    }

    function test_Swap_WavaxToUsdc_DirectModuleCall() external {
        bytes memory params = _wavaxToUsdcParams(300);
        _configure(WAVAX, params);

        vm.startPrank(address(paymentRails));
        IERC20(WAVAX).approve(address(module), WAVAX_SELL_AMOUNT);
        DataTypes.ExecutionResult memory result = module.execute(WAVAX, WAVAX_SELL_AMOUNT, params);
        vm.stopPrank();

        assertTrue(result.success, result.failureReason);
        assertEq(result.outputToken, USDC, "outputToken");
        assertGt(result.amountOut, 0, "amountOut");
        _assertModuleIsClean();
    }

    /// @dev The oracle floor must hold at routed size, not just at 1 AVAX.
    function test_Swap_WavaxToUsdc_LargerSize() external {
        uint256 sellAmount = 50 ether;
        bytes memory params = _wavaxToUsdcParams(300);
        _configure(WAVAX, params);

        (uint256 estimate,) = module.estimateOutput(WAVAX, sellAmount, params);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WAVAX, sellAmount);

        uint256 received = IERC20(USDC).balanceOf(address(paymentRails)) - usdcBefore;
        console2.log("50 WAVAX -> USDC received:", received, "oracle estimate:", estimate);

        assertTrue(success, "50 WAVAX swap should succeed");
        assertGe(received, estimate * 9700 / 10_000, "output below oracle floor at size");
        _assertModuleIsClean();
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        USDC -> WAVAX SWAP TESTS
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleAvalancheForkUsdcToWavaxTest is DexSwapModuleAvalancheForkBase {
    function test_Swap_UsdcToWavax_ViaPaymentRails() external {
        bytes memory params = _usdcToWavaxParams(300);
        _configure(USDC, params);

        (uint256 estimate,) = module.estimateOutput(USDC, USDC_SELL_AMOUNT, params);
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));
        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(USDC, USDC_SELL_AMOUNT);

        uint256 received = IERC20(WAVAX).balanceOf(address(paymentRails)) - wavaxBefore;
        console2.log("USDC -> WAVAX received:", received, "oracle estimate:", estimate);

        assertTrue(success, "reverse-direction swap should succeed");
        assertEq(usdcBefore - IERC20(USDC).balanceOf(address(paymentRails)), USDC_SELL_AMOUNT, "USDC not fully spent");
        assertGe(received, estimate * 9700 / 10_000, "output below oracle floor");
        _assertModuleIsClean();
    }
}

/*//////////////////////////////////////////////////////////////////////////
                        ORACLE ENFORCEMENT TESTS
//////////////////////////////////////////////////////////////////////////*/

contract DexSwapModuleAvalancheForkOracleTest is DexSwapModuleAvalancheForkBase {
    /// @dev If the multicall wrapper swallowed an `amountOutMinimum` revert, the module would
    /// settle below the oracle floor. A zero-slippage floor is unreachable (the pool fee alone
    /// breaches it), so this asserts the revert propagates.
    function test_OracleFloor_EnforcedThroughMulticall() external {
        bytes memory params = _wavaxToUsdcParams(0);
        _configure(WAVAX, params);

        uint256 wavaxBefore = IERC20(WAVAX).balanceOf(address(paymentRails));
        uint256 usdcBefore = IERC20(USDC).balanceOf(address(paymentRails));

        bool success = paymentRails.executeAction(WAVAX, WAVAX_SELL_AMOUNT);

        assertFalse(success, "amountOutMinimum was not enforced through multicall");
        assertEq(IERC20(WAVAX).balanceOf(address(paymentRails)), wavaxBefore, "WAVAX must be returned on floor breach");
        assertEq(IERC20(USDC).balanceOf(address(paymentRails)), usdcBefore, "no USDC should be received");
        _assertModuleIsClean();
    }

    function test_Estimate_TracksLiveOraclePrices() external view {
        bytes memory params = _wavaxToUsdcParams(300);
        (uint256 estimate, address outputToken) = module.estimateOutput(WAVAX, WAVAX_SELL_AMOUNT, params);

        assertEq(outputToken, USDC, "outputToken");
        // AVAX has never traded outside this band; a break means a bad feed or bad decimal math.
        assertGt(estimate, 1e6, "estimate implausibly low (< $1 per AVAX)");
        assertLt(estimate, 1000e6, "estimate implausibly high (> $1000 per AVAX)");
    }

    /// @dev `validate` measures the caller's balance, so it must be asked as the PaymentRails.
    function test_Validate_PassesOnAvalanche() external {
        bytes memory params = _wavaxToUsdcParams(300);
        vm.prank(address(paymentRails));
        (bool isValid, string memory reason) = module.validate(WAVAX, WAVAX_SELL_AMOUNT, params);
        assertTrue(isValid, reason);
    }
}
