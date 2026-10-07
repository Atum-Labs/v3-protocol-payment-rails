// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { DexSwapModuleBase } from "../DexSwapModuleBase.t.sol";
import { DexSwapModule } from "../../../../../../src/modules/swaps/DexSwapModule.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";
import { MockChainlinkAggregator } from "../../../../../shared/mocks/MockChainlinkAggregator.sol";
import { MockERC20 } from "../../../../../shared/mocks/MockERC20.sol";
import { PermissiveFallbackRouter, EoaFactoryRouter } from "../../../../../shared/mocks/NonUniswapRouter.sol";

/// @notice Unit tests for DexSwapModule constructor
/// @dev Tree: tests/unit/concrete/swaps/dex-swap-module/constructor/constructor.tree
contract DexSwapModule_Constructor_Test is DexSwapModuleBase {
    function test_RevertWhen_RouterIsZeroAddress() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_ZeroRouter.selector));
        new DexSwapModule(address(0), address(0), 0);
    }

    function test_RevertWhen_RouterHasNoCode() external {
        address noCode = makeAddr("noCode");
        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_RouterNotContract.selector, noCode));
        new DexSwapModule(noCode, address(0), 0);
    }

    function test_RevertWhen_RouterDoesNotExposeFactory() external {
        // Has code, but no `factory()`: the probe call reverts.
        MockERC20 notARouter = new MockERC20("Not A Router", "NAR");
        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_RouterNotUniswap.selector, address(notARouter)));
        new DexSwapModule(address(notARouter), address(0), 0);
    }

    function test_RevertWhen_RouterSwallowsCallsWithEmptyReturnData() external {
        // A permissive fallback answers `factory()` with no data instead of reverting, so
        // `code.length != 0` alone would accept it.
        PermissiveFallbackRouter trap = new PermissiveFallbackRouter();
        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_RouterNotUniswap.selector, address(trap)));
        new DexSwapModule(address(trap), address(0), 0);
    }

    function test_RevertWhen_RouterFactoryHasNoCode() external {
        EoaFactoryRouter fake = new EoaFactoryRouter(makeAddr("eoaFactory"));
        vm.expectRevert(abi.encodeWithSelector(Errors.DexSwapModule_RouterNotUniswap.selector, address(fake)));
        new DexSwapModule(address(fake), address(0), 0);
    }

    function test_WhenRouterIsValid_SetsImmutableRouter() external view {
        assertEq(module.router(), address(router));
    }

    function test_WhenRouterIsValid_StoresSequencerUptimeFeed() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        assertEq(l2Module.sequencerUptimeFeed(), address(seqFeed));
    }

    function test_WhenRouterIsValid_StoresSequencerGracePeriod() external {
        MockChainlinkAggregator seqFeed = new MockChainlinkAggregator(int256(0), 0);
        DexSwapModule l2Module = new DexSwapModule(address(router), address(seqFeed), 3600);
        assertEq(l2Module.sequencerGracePeriod(), 3600);
    }

    function test_WhenRouterIsValid_ModuleTypeIsSWAP() external view {
        assertEq(module.moduleType(), "SWAP");
    }
}
