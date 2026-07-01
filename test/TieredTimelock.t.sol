// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {TieredTimelock} from "../src/TieredTimelock.sol";
import {TargetMock} from "./mocks/TargetMock.sol";

contract TieredTimelockTest is Test {
    // ─── actors ─────────────────────────────────────────────────────────────
    address internal admin    = makeAddr("admin");
    address internal proposer = makeAddr("proposer");
    address internal canceller = makeAddr("canceller");
    address internal stranger = makeAddr("stranger");

    // ─── contracts ──────────────────────────────────────────────────────────
    TieredTimelock internal tl;
    TargetMock     internal target;

    uint256 internal constant INITIAL_GRACE = 14 days;

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory cancellers = new address[](1);
        cancellers[0] = canceller;

        tl = new TieredTimelock(admin, proposers, cancellers, INITIAL_GRACE);

        target = new TargetMock(address(tl));
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  CONSTRUCTOR
    ════════════════════════════════════════════════════════════════════════ */

    function test_constructorSetsRolesAndGrace() public view {
        assertEq(tl.admin(), admin);
        assertTrue(tl.isProposer(proposer));
        assertTrue(tl.isCanceller(canceller));
        assertEq(tl.proposerCount(), 1);
        assertEq(tl.cancellerCount(), 1);
        assertEq(tl.gracePeriod(), INITIAL_GRACE);
    }

    function test_gettersReturnCurrentAddresses() public {
        address[] memory p = tl.getProposers();
        assertEq(p.length, 1);
        assertEq(p[0], proposer);

        address[] memory c = tl.getCancellers();
        assertEq(c.length, 1);
        assertEq(c[0], canceller);

        // Add a second proposer via self-call, verify the getter reflects it.
        address newProp = makeAddr("newProp");
        vm.prank(proposer);
        tl.execute(
            address(tl),
            abi.encodeCall(TieredTimelock.addProposer, (newProp)),
            bytes32(0),
            bytes32(0)
        );

        address[] memory p2 = tl.getProposers();
        assertEq(p2.length, 2);
        assertEq(tl.proposerCount(), 2);
    }

    function test_constructorRevertsZeroAdmin() public {
        address[] memory p = new address[](1);
        p[0] = proposer;
        address[] memory c = new address[](1);
        c[0] = canceller;
        vm.expectRevert(TieredTimelock.ZeroAddress.selector);
        new TieredTimelock(address(0), p, c, INITIAL_GRACE);
    }

    function test_constructorRevertsZeroProposers() public {
        address[] memory p = new address[](0);
        address[] memory c = new address[](1);
        c[0] = canceller;
        vm.expectRevert(TieredTimelock.CannotRemoveLastProposer.selector);
        new TieredTimelock(admin, p, c, INITIAL_GRACE);
    }

    function test_constructorRevertsZeroCancellers() public {
        address[] memory p = new address[](1);
        p[0] = proposer;
        address[] memory c = new address[](0);
        vm.expectRevert(TieredTimelock.CannotRemoveLastCanceller.selector);
        new TieredTimelock(admin, p, c, INITIAL_GRACE);
    }

    function test_constructorRevertsDuplicateProposer() public {
        address[] memory p = new address[](2);
        p[0] = proposer;
        p[1] = proposer;
        address[] memory c = new address[](1);
        c[0] = canceller;
        vm.expectRevert(TieredTimelock.AlreadyRoleMember.selector);
        new TieredTimelock(admin, p, c, INITIAL_GRACE);
    }

    function test_constructorRevertsGraceOutOfBounds() public {
        address[] memory p = new address[](1);
        p[0] = proposer;
        address[] memory c = new address[](1);
        c[0] = canceller;
        vm.expectRevert(TieredTimelock.GracePeriodOutOfBounds.selector);
        new TieredTimelock(admin, p, c, 1 hours); // below MIN

        vm.expectRevert(TieredTimelock.GracePeriodOutOfBounds.selector);
        new TieredTimelock(admin, p, c, 31 days); // above MAX
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  SEED + RENOUNCE
    ════════════════════════════════════════════════════════════════════════ */

    function test_seedDelaySetsValue() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 2 days);
        assertEq(
            tl.delayOf(tl.delayKey(address(target), TargetMock.setValue.selector)),
            2 days
        );
    }

    function test_seedDelayRevertsForNonAdmin() public {
        vm.prank(proposer);
        vm.expectRevert(TieredTimelock.NotAdmin.selector);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 2 days);
    }

    function test_seedDelayRevertsOnSecondCall() public {
        vm.startPrank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.AlreadySeeded.selector,
                address(target),
                TargetMock.setValue.selector
            )
        );
        tl.seedDelay(address(target), TargetMock.setValue.selector, 5 days);
        vm.stopPrank();
    }

    function test_seedDelayRevertsAboveMax() public {
        vm.prank(admin);
        vm.expectRevert(TieredTimelock.DelayTooLong.selector);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 31 days);
    }

    function test_renounceAdminRevertsWhenCriticalsNotSeeded() public {
        vm.prank(admin);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CriticalDelayNotSeeded.selector,
                TieredTimelock.addProposer.selector
            )
        );
        tl.renounceAdmin();
    }

    function test_renounceAdminSucceedsAfterFullSeeding() public {
        _seedAllCriticals();
        vm.prank(admin);
        tl.renounceAdmin();
        assertEq(tl.admin(), address(0));

        // After renounce, seedDelay can never be called again.
        vm.prank(admin);
        vm.expectRevert(TieredTimelock.NotAdmin.selector);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  SCHEDULE / EXECUTE — happy path
    ════════════════════════════════════════════════════════════════════════ */

    function test_executeShortcut_whenDelayZero_byProposer() public {
        // Default delay is 0 → proposer can execute without scheduling.
        bytes memory data = abi.encodeCall(TargetMock.setValue, (42));
        vm.prank(proposer);
        tl.execute(address(target), data, bytes32(0), bytes32(0));
        assertEq(target.value(), 42);
    }

    function test_executeShortcut_revertsForNonProposer() public {
        bytes memory data = abi.encodeCall(TargetMock.setValue, (42));
        vm.prank(stranger);
        vm.expectRevert(TieredTimelock.NotProposer.selector);
        tl.execute(address(target), data, bytes32(0), bytes32(0));
    }

    function test_scheduleAndExecute_afterDelay() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);

        bytes memory data = abi.encodeCall(TargetMock.setValue, (99));
        vm.prank(proposer);
        bytes32 id = tl.schedule(address(target), data, bytes32(0), bytes32(0));

        assertTrue(tl.isPending(id));
        assertFalse(tl.isReady(id));

        // Before eta — execute reverts.
        vm.expectRevert(TieredTimelock.TimelockNotExpired.selector);
        tl.execute(address(target), data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1 days);
        assertTrue(tl.isReady(id));

        // After eta, ANYONE can execute (permissionless).
        vm.prank(stranger);
        tl.execute(address(target), data, bytes32(0), bytes32(0));
        assertEq(target.value(), 99);
        assertTrue(tl.isDone(id));
    }

    function test_schedule_revertsWhenDuplicate() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);

        bytes memory data = abi.encodeCall(TargetMock.setValue, (1));
        vm.startPrank(proposer);
        tl.schedule(address(target), data, bytes32(0), bytes32(0));
        vm.expectRevert(TieredTimelock.AlreadyScheduled.selector);
        tl.schedule(address(target), data, bytes32(0), bytes32(0));
        vm.stopPrank();
    }

    function test_schedule_differentSaltsAreIndependent() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);

        bytes memory data = abi.encodeCall(TargetMock.setValue, (1));
        vm.startPrank(proposer);
        bytes32 id1 = tl.schedule(address(target), data, bytes32(0), bytes32(uint256(1)));
        bytes32 id2 = tl.schedule(address(target), data, bytes32(0), bytes32(uint256(2)));
        vm.stopPrank();

        assertTrue(id1 != id2);
        assertTrue(tl.isPending(id1));
        assertTrue(tl.isPending(id2));
    }

    function test_execute_revertsAfterGracePeriod() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);

        bytes memory data = abi.encodeCall(TargetMock.setValue, (7));
        vm.prank(proposer);
        tl.schedule(address(target), data, bytes32(0), bytes32(0));

        vm.warp(block.timestamp + 1 days + INITIAL_GRACE + 1);
        vm.expectRevert(TieredTimelock.ProposalExpired.selector);
        tl.execute(address(target), data, bytes32(0), bytes32(0));
    }

    function test_execute_bubblesUpRevertReason() public {
        bytes memory data = abi.encodeCall(TargetMock.revertingFunction, ());
        vm.prank(proposer);
        vm.expectRevert(); // CallFailed wraps the inner revert data
        tl.execute(address(target), data, bytes32(0), bytes32(0));
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  CANCEL
    ════════════════════════════════════════════════════════════════════════ */

    function test_cancel_byCanceller() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);

        bytes memory data = abi.encodeCall(TargetMock.setValue, (1));
        vm.prank(proposer);
        bytes32 id = tl.schedule(address(target), data, bytes32(0), bytes32(0));

        vm.prank(canceller);
        tl.cancel(id);
        assertFalse(tl.isPending(id));

        // Execute reverts because the op is no longer scheduled.
        vm.warp(block.timestamp + 1 days);
        vm.prank(proposer);
        vm.expectRevert(TieredTimelock.MustSchedule.selector);
        tl.execute(address(target), data, bytes32(0), bytes32(0));
    }

    function test_cancel_revertsForNonCanceller() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);

        bytes memory data = abi.encodeCall(TargetMock.setValue, (1));
        vm.prank(proposer);
        bytes32 id = tl.schedule(address(target), data, bytes32(0), bytes32(0));

        vm.prank(stranger);
        vm.expectRevert(TieredTimelock.NotCanceller.selector);
        tl.cancel(id);
    }

    function test_cancel_revertsForUnknownOrDoneOp() public {
        vm.prank(canceller);
        vm.expectRevert(TieredTimelock.NotScheduled.selector);
        tl.cancel(bytes32(uint256(0x1234)));
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  PREDECESSOR
    ════════════════════════════════════════════════════════════════════════ */

    function test_predecessor_blocksExecuteUntilDone() public {
        vm.startPrank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 1 days);
        tl.seedDelay(address(target), TargetMock.setSecondValue.selector, 1 days);
        vm.stopPrank();

        bytes memory dataA = abi.encodeCall(TargetMock.setValue, (10));
        bytes memory dataB = abi.encodeCall(TargetMock.setSecondValue, (20));

        vm.startPrank(proposer);
        bytes32 idA = tl.schedule(address(target), dataA, bytes32(0), bytes32(0));
        bytes32 idB = tl.schedule(address(target), dataB, idA, bytes32(0));
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);

        // B reverts because A isn't done.
        vm.expectRevert(TieredTimelock.PredecessorNotDone.selector);
        tl.execute(address(target), dataB, idA, bytes32(0));

        // Execute A, then B succeeds.
        tl.execute(address(target), dataA, bytes32(0), bytes32(0));
        tl.execute(address(target), dataB, idA, bytes32(0));

        assertEq(target.value(), 10);
        assertEq(target.secondValue(), 20);
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  INCREASE / DECREASE DELAY
    ════════════════════════════════════════════════════════════════════════ */

    function test_increaseDelay_viaSelfCall() public {
        // increaseDelay defaults to 0 → single-tx shortcut works.
        bytes memory data = abi.encodeCall(
            TieredTimelock.increaseDelay,
            (address(target), TargetMock.setValue.selector, 3 days)
        );
        vm.prank(proposer);
        tl.execute(address(tl), data, bytes32(0), bytes32(0));

        assertEq(
            tl.delayOf(tl.delayKey(address(target), TargetMock.setValue.selector)),
            3 days
        );
    }

    function test_increaseDelay_revertsWhenNotIncreasing() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 5 days);

        bytes memory data = abi.encodeCall(
            TieredTimelock.increaseDelay,
            (address(target), TargetMock.setValue.selector, 5 days)
        );
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CallFailed.selector,
                abi.encodeWithSelector(TieredTimelock.DelayNotIncreasing.selector)
            )
        );
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
    }

    function test_increaseDelay_revertsAboveMax() public {
        bytes memory data = abi.encodeCall(
            TieredTimelock.increaseDelay,
            (address(target), TargetMock.setValue.selector, 31 days)
        );
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CallFailed.selector,
                abi.encodeWithSelector(TieredTimelock.DelayTooLong.selector)
            )
        );
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
    }

    function test_decreaseDelay_usesTargetCurrentDelay() public {
        // Set target's delay to 5 days via seed.
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 5 days);

        // Attempt to lower it to 1 hour. Schedule must take 5 days, not the (0) delay of decreaseDelay.
        bytes memory data = abi.encodeCall(
            TieredTimelock.decreaseDelay,
            (address(target), TargetMock.setValue.selector, 1 hours)
        );
        vm.prank(proposer);
        bytes32 id = tl.schedule(address(tl), data, bytes32(0), bytes32(0));

        // Before 5 days passes, execute reverts.
        vm.warp(block.timestamp + 5 days - 1);
        vm.expectRevert(TieredTimelock.TimelockNotExpired.selector);
        tl.execute(address(tl), data, bytes32(0), bytes32(0));

        // After 5 days, execute succeeds.
        vm.warp(block.timestamp + 2);
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
        assertEq(
            tl.delayOf(tl.delayKey(address(target), TargetMock.setValue.selector)),
            1 hours
        );
        assertTrue(tl.isDone(id));
    }

    function test_decreaseDelay_revertsWhenNotDecreasing() public {
        vm.prank(admin);
        tl.seedDelay(address(target), TargetMock.setValue.selector, 5 days);
        bytes memory data = abi.encodeCall(
            TieredTimelock.decreaseDelay,
            (address(target), TargetMock.setValue.selector, 5 days)
        );
        vm.prank(proposer);
        bytes32 id = tl.schedule(address(tl), data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 5 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CallFailed.selector,
                abi.encodeWithSelector(TieredTimelock.DelayNotDecreasing.selector)
            )
        );
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
        id; // silence unused
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  ROLE MANAGEMENT
    ════════════════════════════════════════════════════════════════════════ */

    function test_addProposer_viaSelfCall() public {
        address newProp = makeAddr("newProp");
        bytes memory data = abi.encodeCall(TieredTimelock.addProposer, (newProp));
        vm.prank(proposer);
        tl.execute(address(tl), data, bytes32(0), bytes32(0));

        assertTrue(tl.isProposer(newProp));
        assertEq(tl.proposerCount(), 2);
    }

    function test_addProposer_revertsForAlreadyMember() public {
        bytes memory data = abi.encodeCall(TieredTimelock.addProposer, (proposer));
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CallFailed.selector,
                abi.encodeWithSelector(TieredTimelock.AlreadyRoleMember.selector)
            )
        );
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
    }

    function test_removeProposer_revertsWhenLast() public {
        bytes memory data = abi.encodeCall(TieredTimelock.removeProposer, (proposer));
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CallFailed.selector,
                abi.encodeWithSelector(TieredTimelock.CannotRemoveLastProposer.selector)
            )
        );
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
    }

    function test_removeProposer_succeedsWithMultiple() public {
        address newProp = makeAddr("newProp");
        // add
        vm.prank(proposer);
        tl.execute(
            address(tl),
            abi.encodeCall(TieredTimelock.addProposer, (newProp)),
            bytes32(0),
            bytes32(0)
        );
        // remove the original
        vm.prank(proposer);
        tl.execute(
            address(tl),
            abi.encodeCall(TieredTimelock.removeProposer, (proposer)),
            bytes32(0),
            bytes32(0)
        );

        assertFalse(tl.isProposer(proposer));
        assertTrue(tl.isProposer(newProp));
        assertEq(tl.proposerCount(), 1);
    }

    function test_removeCanceller_revertsWhenLast() public {
        bytes memory data = abi.encodeCall(TieredTimelock.removeCanceller, (canceller));
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CallFailed.selector,
                abi.encodeWithSelector(TieredTimelock.CannotRemoveLastCanceller.selector)
            )
        );
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  GRACE PERIOD UPDATE
    ════════════════════════════════════════════════════════════════════════ */

    function test_updateGracePeriod_viaSelfCall() public {
        bytes memory data = abi.encodeCall(TieredTimelock.updateGracePeriod, (7 days));
        vm.prank(proposer);
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
        assertEq(tl.gracePeriod(), 7 days);
    }

    function test_updateGracePeriod_revertsOutOfBounds() public {
        bytes memory data = abi.encodeCall(TieredTimelock.updateGracePeriod, (1 hours));
        vm.prank(proposer);
        vm.expectRevert(
            abi.encodeWithSelector(
                TieredTimelock.CallFailed.selector,
                abi.encodeWithSelector(TieredTimelock.GracePeriodOutOfBounds.selector)
            )
        );
        tl.execute(address(tl), data, bytes32(0), bytes32(0));
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  DIRECT-CALL PROTECTION
    ════════════════════════════════════════════════════════════════════════ */

    function test_selfFunctions_revertWhenCalledDirectly() public {
        vm.expectRevert(TieredTimelock.NotSelf.selector);
        tl.addProposer(stranger);

        vm.expectRevert(TieredTimelock.NotSelf.selector);
        tl.increaseDelay(address(target), TargetMock.setValue.selector, 1 days);

        vm.expectRevert(TieredTimelock.NotSelf.selector);
        tl.updateGracePeriod(2 days);
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  REENTRANCY
    ════════════════════════════════════════════════════════════════════════ */

    function test_executeReentrancyGuard() public {
        // First operation: schedule reenter(timelock, payload) so when execute() invokes the
        // target, the target turns around and calls back into the timelock. That nested call must
        // fail because the outer execute() is still in progress.
        bytes memory nestedPayload = abi.encodeCall(TargetMock.setValue, (1));
        bytes memory outerData = abi.encodeCall(
            TargetMock.reenter,
            (
                address(tl),
                abi.encodeWithSelector(
                    tl.execute.selector,
                    address(target),
                    nestedPayload,
                    bytes32(0),
                    bytes32(0)
                )
            )
        );

        // Default delay is 0; proposer single-tx executes. Expect the outer call to fail with
        // ReentrancyGuard's revert reason wrapped in CallFailed.
        vm.prank(proposer);
        vm.expectRevert(); // CallFailed(bytes) — the inner ReentrancyGuard revert string
        tl.execute(address(target), outerData, bytes32(0), bytes32(0));
    }

    /* ════════════════════════════════════════════════════════════════════════
                                  HELPERS
    ════════════════════════════════════════════════════════════════════════ */

    /// @dev Seed the six selectors `renounceAdmin` requires.
    function _seedAllCriticals() internal {
        vm.startPrank(admin);
        tl.seedDelay(address(tl), TieredTimelock.addProposer.selector,       3 days);
        tl.seedDelay(address(tl), TieredTimelock.removeProposer.selector,    3 days);
        tl.seedDelay(address(tl), TieredTimelock.addCanceller.selector,      3 days);
        tl.seedDelay(address(tl), TieredTimelock.removeCanceller.selector,   3 days);
        tl.seedDelay(address(tl), TieredTimelock.increaseDelay.selector,     1 days);
        tl.seedDelay(address(tl), TieredTimelock.updateGracePeriod.selector, 1 days);
        vm.stopPrank();
    }
}
