// SPDX-License-Identifier: MIT
pragma solidity ^0.8.29;

import { CowSwapModuleFactoryBase } from "../CowSwapModuleFactoryBase.t.sol";
import { CowSwapModuleFactory } from "../../../../../../src/modules/swaps/CowSwapModuleFactory.sol";
import { Errors } from "../../../../../../src/libraries/Errors.sol";

contract Constructor_CowSwapModuleFactory_Test is CowSwapModuleFactoryBase {
    function test_RevertWhen_CowSettlementIsZeroAddress() external {
        vm.expectRevert(Errors.CowSwapModuleFactory_ZeroCowSettlement.selector);
        new CowSwapModuleFactory(owner, address(0), sequencerFeed, DEFAULT_GRACE_PERIOD);
    }

    function test_RevertWhen_CowSettlementHasNoCode() external {
        address eoa = makeAddr("eoaSettlement");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_SettlementNotContract.selector, eoa));
        new CowSwapModuleFactory(owner, eoa, sequencerFeed, DEFAULT_GRACE_PERIOD);
    }

    function test_RevertWhen_SequencerFeedIsNotContract() external {
        address eoa = makeAddr("eoaSequencerFeed");
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_SequencerFeedNotContract.selector, eoa));
        new CowSwapModuleFactory(owner, address(cowSettlement), eoa, DEFAULT_GRACE_PERIOD);
    }

    /// @dev L1 has no sequencer uptime feed, so address(0) must stay a valid configuration.
    function test_WhenSequencerFeedIsZero_ShouldDeployForL1Profile() external {
        CowSwapModuleFactory newFactory = new CowSwapModuleFactory(owner, address(cowSettlement), address(0), 0);
        assertEq(newFactory.sequencerUptimeFeed(), address(0));
        assertEq(newFactory.sequencerGracePeriod(), 0);
    }

    /// @dev The grace period is measured from the uptime feed's round data, so without a feed it is
    /// dead config that still reads as protection through `sequencerGracePeriod()`.
    function test_RevertWhen_GracePeriodIsNonZeroWithoutAFeed() external {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.CowSwapModuleFactory_GracePeriodWithoutFeed.selector, DEFAULT_GRACE_PERIOD)
        );
        new CowSwapModuleFactory(owner, address(cowSettlement), address(0), DEFAULT_GRACE_PERIOD);
    }

    /// @dev Zero against a real feed reduces the module's check to `block.timestamp - startedAt < 0`,
    /// which is never true for uint256 — the guard is deleted rather than shortened.
    function test_RevertWhen_GracePeriodIsZeroWithAFeed() external {
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_InvalidGracePeriod.selector, 0));
        new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, 0);
    }

    /// @dev An oversized value makes the module's check always true, so every module the factory
    /// deploys is permanently unable to price an order. Both values are immutable, so this must
    /// fail at factory deployment rather than silently at every execution.
    function test_RevertWhen_GracePeriodExceedsTheMaximum() external {
        vm.expectRevert(
            abi.encodeWithSelector(Errors.CowSwapModuleFactory_InvalidGracePeriod.selector, MAX_GRACE_PERIOD + 1)
        );
        new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, MAX_GRACE_PERIOD + 1);
    }

    /// @dev The bound is inclusive.
    function test_WhenGracePeriodEqualsTheMaximum_ShouldDeploy() external {
        CowSwapModuleFactory newFactory =
            new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, MAX_GRACE_PERIOD);
        assertEq(newFactory.sequencerGracePeriod(), MAX_GRACE_PERIOD);
    }

    /// @dev Pins the bound to its literal value on both sides of the edge. MAX_GRACE_PERIOD here
    /// mirrors a private constant in the factory, so this is the test that catches the two drifting
    /// apart: change the contract without changing the mirror and this fails.
    function test_TheGracePeriodBoundIsExactlyOneDay() external {
        assertEq(MAX_GRACE_PERIOD, 1 days, "test mirror drifted from the factory constant");

        CowSwapModuleFactory atBound = new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, 1 days);
        assertEq(atBound.sequencerGracePeriod(), 1 days);

        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_InvalidGracePeriod.selector, 1 days + 1));
        new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, 1 days + 1);
    }

    /// @dev The point tests above cover four values. These three pin the whole accepted domain:
    /// with a feed it is exactly (0, MAX_GRACE_PERIOD], and without a feed it is exactly {0}.
    function testFuzz_WithFeed_AcceptsEveryValueInRange(uint256 grace) external {
        grace = bound(grace, 1, MAX_GRACE_PERIOD);
        CowSwapModuleFactory newFactory = new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, grace);
        assertEq(newFactory.sequencerGracePeriod(), grace);
    }

    function testFuzz_WithFeed_RejectsEveryValueAboveTheBound(uint256 grace) external {
        grace = bound(grace, MAX_GRACE_PERIOD + 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_InvalidGracePeriod.selector, grace));
        new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, grace);
    }

    function testFuzz_WithoutFeed_RejectsEveryNonZeroValue(uint256 grace) external {
        grace = bound(grace, 1, type(uint256).max);
        vm.expectRevert(abi.encodeWithSelector(Errors.CowSwapModuleFactory_GracePeriodWithoutFeed.selector, grace));
        new CowSwapModuleFactory(owner, address(cowSettlement), address(0), grace);
    }

    function test_WhenCowSettlementIsValidContract_ShouldSetCowSettlement() external {
        CowSwapModuleFactory newFactory =
            new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, DEFAULT_GRACE_PERIOD);
        assertEq(newFactory.cowSettlement(), address(cowSettlement));
    }

    function test_WhenCowSettlementIsValidContract_ShouldSetSequencerUptimeFeed() external {
        CowSwapModuleFactory newFactory =
            new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, DEFAULT_GRACE_PERIOD);
        assertEq(newFactory.sequencerUptimeFeed(), sequencerFeed);
    }

    function test_WhenCowSettlementIsValidContract_ShouldSetSequencerGracePeriod() external {
        CowSwapModuleFactory newFactory =
            new CowSwapModuleFactory(owner, address(cowSettlement), sequencerFeed, DEFAULT_GRACE_PERIOD);
        assertEq(newFactory.sequencerGracePeriod(), DEFAULT_GRACE_PERIOD);
    }
}
