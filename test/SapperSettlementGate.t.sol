// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {SapperSettlementGate} from "../src/SapperSettlementGate.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {ISapperBountyPot, Severity} from "../src/interfaces/ISapperBountyPot.sol";
import {MockUSDG, OwnedTarget} from "./mocks/Mocks.sol";

contract SapperSettlementGateTest is Fixture {
    bytes32 constant F = keccak256("finding-1");
    bytes32 constant G = keccak256("finding-2");

    function test_claimGuards() public {
        vm.expectRevert(SapperSettlementGate.NotKeeper.selector);
        gate.claim(F, target, chain, 1, 0, breaker, agentId, 0);

        address stray = address(new OwnedTarget(client));
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SapperSettlementGate.NotInScope.selector, stray, chain));
        gate.claim(F, stray, chain, 1, 0, breaker, agentId, 0);
        vm.expectRevert(abi.encodeWithSelector(SapperSettlementGate.BadTier.selector, 3));
        gate.claim(F, target, chain, 1, 0, breaker, agentId, 3);
        vm.expectRevert(SapperSettlementGate.ZeroFinding.selector);
        gate.claim(bytes32(0), target, chain, 1, 0, breaker, agentId, 0);
        vm.expectRevert(SapperSettlementGate.ZeroAddress.selector);
        gate.claim(F, target, chain, 1, 0, address(0), agentId, 0);
        vm.stopPrank();

        _claim(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Claimed));
        SapperSettlementGate.Finding memory f = gate.finding(F);
        assertEq(f.client, client);
        assertEq(f.target, target);
        assertEq(f.breakerOperator, breaker);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SapperSettlementGate.FindingExists.selector, F));
        gate.claim(F, target, chain, 1, 0, breaker, agentId, 0);
    }

    function test_guardianPausesNewClaimsOnly() public {
        _fund(client, 10_000e6);
        _confirm(F);

        vm.prank(client);
        vm.expectRevert(SapperSettlementGate.NotGuardian.selector);
        gate.setClaimsPaused(true);
        vm.prank(guardian);
        gate.setClaimsPaused(true);

        vm.prank(keeper);
        vm.expectRevert(SapperSettlementGate.ClaimsArePaused.selector);
        gate.claim(G, target, chain, 1, 0, breaker, agentId, 0);

        _rate(F, Severity.High, ROOT_CAUSE);
        vm.warp(block.timestamp + 72 hours);
        pot.settle(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Settled));

        vm.prank(guardian);
        gate.setClaimsPaused(false);
        _claim(G);
    }

    function test_breakerOperatorIsExcludedFromItsRound() public {
        _stakeAs(breaker, CHECKER_STAKE);
        address[] memory drawn = _claim(F);
        assertEq(drawn.length, 3);
        for (uint256 i; i < drawn.length; ++i) {
            assertTrue(drawn[i] != breaker);
        }
    }

    function test_sizeTierDrawsFiveCheckers() public {
        _stake("checker3", CHECKER_STAKE);
        _stake("checker4", CHECKER_STAKE);
        assertEq(_claimTier(F, target, 2).length, 5);
    }

    function test_claimLocksCriticalProvisionally() public {
        _fund(client, 15_000e6);
        _claim(F);

        ISapperBountyPot.Lock memory l = pot.lockOf(F);
        assertEq(uint8(l.status), uint8(ISapperBountyPot.LockStatus.Locked));
        assertEq(uint8(l.severity), uint8(Severity.Critical));
        assertEq(l.amount, 10_000e6);
        assertEq(l.expiry, block.timestamp + 7 days);
        assertEq(pot.lockedBalance(client), 10_000e6);
        assertEq(pot.unlockedBalance(client), 5_000e6);

        vm.startPrank(client);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientUnlocked.selector, 5_000e6, 5_000e6 + 1));
        pot.withdraw(5_000e6 + 1);
        pot.withdraw(5_000e6);
        vm.stopPrank();
        assertEq(usdg.balanceOf(client), 5_000e6);
        assertEq(pot.lockedBalance(client), 10_000e6);

        _replay(F, true, RESULT);
        assertEq(pot.lockedBalance(client), 10_000e6);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientUnlocked.selector, 0, 1));
        pot.withdraw(1);
    }

    function test_claimCapsProvisionalLockAtUnlocked() public {
        _fund(client, 4_000e6);
        _claim(F);
        assertEq(pot.lockOf(F).amount, 4_000e6);
        assertEq(pot.unlockedBalance(client), 0);

        _claim(G);
        assertEq(pot.lockOf(G).amount, 0);
    }

    function testFuzz_failedReplayLeavesClientWhole(uint96 funded, uint96 spent, uint128 crit, uint8 mode) public {
        funded = uint96(bound(funded, 0, 1e15));
        crit = uint128(bound(crit, 0, 2e15));
        _fund(client, funded);
        _table(crit, 0, 0, 0);
        spent = uint96(bound(spent, 0, funded));
        vm.prank(client);
        pot.withdraw(spent);

        uint256 unlockedBefore = pot.unlockedBalance(client);
        address[] memory assigned = _claim(F);
        assertEq(pot.lockOf(F).amount, crit < unlockedBefore ? crit : unlockedBefore);

        mode %= 3;
        if (mode == 0) {
            _replay(F, false, bytes32(0));
        } else if (mode == 1) {
            for (uint256 i; i < 3; ++i) {
                _commit(F, assigned[i], true, keccak256(abi.encode(i)));
            }
            for (uint256 i; i < 3; ++i) {
                _reveal(F, assigned[i], true, keccak256(abi.encode(i)));
            }
            net.finalize(F);
        } else {
            vm.warp(block.timestamp + 36 minutes);
            net.finalize(F);
        }

        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Rejected));
        assertEq(uint8(pot.lockOf(F).status), uint8(ISapperBountyPot.LockStatus.Released));
        assertEq(pot.unlockedBalance(client), unlockedBefore);
        assertEq(pot.lockedBalance(client), 0);
        vm.prank(client);
        pot.withdraw(unlockedBefore);
        assertEq(usdg.balanceOf(client), funded);
        assertEq(usdg.balanceOf(address(pot)), 0);
    }

    function test_failedReplayNeverLocksOrPays() public {
        _fund(client, 10_000e6);
        _claim(F);
        _replay(F, false, bytes32(0));
        _assertNeverPaid(F);
    }

    function test_noMajorityReplayNeverLocksOrPays() public {
        _fund(client, 10_000e6);
        address[] memory assigned = _claim(F);
        for (uint256 i; i < 3; ++i) {
            _commit(F, assigned[i], true, keccak256(abi.encode(i)));
        }
        for (uint256 i; i < 3; ++i) {
            _reveal(F, assigned[i], true, keccak256(abi.encode(i)));
        }
        net.finalize(F);
        _assertNeverPaid(F);
    }

    function test_silentRoundNeverLocksOrPays() public {
        _fund(client, 10_000e6);
        _claim(F);
        vm.warp(block.timestamp + 36 minutes);
        net.finalize(F);
        _assertNeverPaid(F);
        for (uint256 i; i < 3; ++i) {
            assertEq(net.checkerOf(checkers[i]).stake, CHECKER_STAKE * 9 / 10);
        }
    }

    function test_duplicateRootCauseIsRejected() public {
        _fund(client, 25_000e6);
        _confirm(F);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        uint256 locked = pot.lockedBalance(client);
        assertEq(locked, 10_000e6);

        _confirm(G);
        assertEq(pot.lockOf(G).amount, 10_000e6);
        assertEq(pot.unlockedBalance(client), 5_000e6);

        vm.expectEmit(address(pot));
        emit SapperBountyPot.LockReleased(G, client, 10_000e6);
        vm.expectEmit(address(gate));
        emit SapperSettlementGate.DuplicateRejected(G, F, ROOT_CAUSE);
        _rate(G, Severity.Critical, ROOT_CAUSE);

        assertEq(uint8(_status(G)), uint8(SapperSettlementGate.Status.Rejected));
        assertEq(uint8(pot.lockOf(G).status), uint8(ISapperBountyPot.LockStatus.Released));
        assertEq(pot.lockedBalance(client), locked);
        assertEq(pot.unlockedBalance(client), 15_000e6);
        assertEq(gate.rootCauseFinding(keccak256(abi.encode(client, target, chain, ROOT_CAUSE))), F);
    }

    function test_rateLowersLockToSeverityPrice() public {
        _fund(client, 12_000e6);
        _confirm(F);
        assertEq(pot.lockOf(F).amount, 10_000e6);
        assertEq(pot.unlockedBalance(client), 2_000e6);

        uint64 reviewEndsAt = uint64(block.timestamp) + 72 hours;
        vm.expectEmit(address(pot));
        emit SapperBountyPot.LockAdjusted(F, Severity.High, 10_000e6, 2_500e6, reviewEndsAt + 14 days);
        vm.expectEmit(address(gate));
        emit SapperSettlementGate.FindingRated(F, Severity.High, ROOT_CAUSE, 2_500e6, reviewEndsAt);
        _rate(F, Severity.High, ROOT_CAUSE);

        ISapperBountyPot.Lock memory l = pot.lockOf(F);
        assertEq(l.amount, 2_500e6);
        assertEq(uint8(l.severity), uint8(Severity.High));
        assertEq(l.expiry, reviewEndsAt + 14 days);
        assertEq(pot.lockedBalance(client), 2_500e6);
        assertEq(pot.unlockedBalance(client), 9_500e6);
    }

    function test_rateNeverRaisesProvisionalLock() public {
        _fund(client, 3_000e6);
        _confirm(F);
        assertEq(pot.lockOf(F).amount, 3_000e6);

        _fund(client, 50_000e6);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        assertEq(pot.lockOf(F).amount, 3_000e6);
        assertEq(pot.lockedBalance(client), 3_000e6);
        assertEq(pot.unlockedBalance(client), 50_000e6);
    }

    function test_tableChangeAfterClaimDoesNotReprice() public {
        _fund(client, 20_000e6);
        _claim(F);
        _table(1e6, 1e6, 1e6, 0);
        _replay(F, true, RESULT);
        _rate(F, Severity.High, ROOT_CAUSE);
        assertEq(pot.lockOf(F).amount, 2_500e6);
        assertEq(pot.lockOf(F).terms.high, 2_500e6);
    }

    function test_unratedClaimRefundsAfterRatingWindow() public {
        _fund(client, 10_000e6);
        _confirm(F);
        uint64 expiry = pot.lockOf(F).expiry;
        assertEq(expiry, block.timestamp + gate.ratingWindow());

        vm.warp(expiry);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotExpired.selector, F));
        pot.reclaimExpired(F);

        vm.warp(expiry + 1);
        (address[] memory workers, uint16[] memory bps) = _split();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.LockExpired.selector, F));
        gate.rate(F, Severity.Critical, ROOT_CAUSE, workers, bps);

        vm.prank(makeAddr("anyone"));
        pot.reclaimExpired(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Expired));
        assertEq(pot.unlockedBalance(client), 10_000e6);
        assertEq(pot.lockedBalance(client), 0);

        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SapperSettlementGate.BadStatus.selector, F, SapperSettlementGate.Status.Expired)
        );
        gate.rate(F, Severity.Critical, ROOT_CAUSE, workers, bps);
    }

    function test_roundStillFinalizesAfterClaimRefunded() public {
        _fund(client, 20_000e6);
        address[] memory assigned = _claim(F);
        vm.prank(owner);
        gate.setRatingWindow(1 minutes);
        _claim(G);
        assertEq(pot.unlockedBalance(client), 0);

        vm.warp(block.timestamp + 2 minutes);
        pot.reclaimExpired(G);
        assertEq(uint8(_status(G)), uint8(SapperSettlementGate.Status.Expired));
        assertEq(pot.unlockedBalance(client), 10_000e6);

        _replay(G, false, bytes32(0));
        assertEq(uint8(_status(G)), uint8(SapperSettlementGate.Status.Expired));
        assertEq(uint8(pot.lockOf(G).status), uint8(ISapperBountyPot.LockStatus.Refunded));
        assertTrue(net.round(G).finalized);
        for (uint256 i; i < assigned.length; ++i) {
            assertEq(net.checkerOf(assigned[i]).openRounds, 1);
        }
        assertEq(pot.unlockedBalance(client), 10_000e6);
        assertEq(pot.lockOf(F).amount, 10_000e6);
    }

    function test_sameRootCauseOnAnotherTargetIsNotDuplicate() public {
        _fund(client, 20_000e6);
        address second = address(new OwnedTarget(client));
        vm.prank(client);
        scope.optIn(second, chain, ROOT, disclosure, "");

        _confirm(F);
        _rate(F, Severity.High, ROOT_CAUSE);
        _claimTier(G, second, 0);
        _replay(G, true, RESULT);
        _rate(G, Severity.High, ROOT_CAUSE);
        assertEq(uint8(_status(G)), uint8(SapperSettlementGate.Status.Review));
    }

    function test_rateGuards() public {
        _confirm(F);
        (address[] memory workers, uint16[] memory bps) = _split();
        vm.startPrank(keeper);

        vm.expectRevert(SapperSettlementGate.ZeroRootCause.selector);
        gate.rate(F, Severity.High, bytes32(0), workers, bps);

        bps[1] = 2_999;
        vm.expectRevert(SapperSettlementGate.BadSplit.selector);
        gate.rate(F, Severity.High, ROOT_CAUSE, workers, bps);
        bps[1] = 3_000;

        workers[1] = address(0);
        vm.expectRevert(SapperSettlementGate.BadSplit.selector);
        gate.rate(F, Severity.High, ROOT_CAUSE, workers, bps);
        workers[1] = fixer;

        vm.expectRevert(SapperSettlementGate.BadSplit.selector);
        gate.rate(F, Severity.High, ROOT_CAUSE, workers, new uint16[](1));

        vm.expectRevert(SapperSettlementGate.BadSplit.selector);
        gate.rate(F, Severity.High, ROOT_CAUSE, new address[](17), new uint16[](17));

        vm.expectRevert(
            abi.encodeWithSelector(SapperSettlementGate.BadStatus.selector, G, SapperSettlementGate.Status.None)
        );
        gate.rate(G, Severity.High, ROOT_CAUSE, workers, bps);
        vm.stopPrank();

        vm.expectRevert(SapperSettlementGate.NotKeeper.selector);
        gate.rate(F, Severity.High, ROOT_CAUSE, workers, bps);
    }

    function test_settleTimingAndOnce() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.High, ROOT_CAUSE);
        uint64 ends = gate.finding(F).reviewEndsAt;
        assertEq(ends, block.timestamp + 72 hours);
        assertEq(pot.lockOf(F).expiry, ends + 14 days);

        vm.warp(ends - 1);
        assertFalse(gate.settleable(F));
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotSettleable.selector, F));
        pot.settle(F);

        vm.warp(ends);
        pot.settle(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Settled));
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F));
        pot.settle(F);
    }

    function test_cannotSettleWhileDisputed() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.High, ROOT_CAUSE);

        vm.prank(client);
        gate.dispute(F, Severity.Medium, bytes32(0));
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Disputed));
        assertEq(uint8(gate.disputeOf(F).proposedSeverity), uint8(Severity.Medium));

        vm.warp(block.timestamp + 10 days);
        assertFalse(gate.settleable(F));
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotSettleable.selector, F));
        pot.settle(F);

        vm.prank(resolver);
        gate.resolve(F, Severity.High, false);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Review));
        assertEq(gate.finding(F).reviewEndsAt, block.timestamp);
        pot.settle(F);
        assertEq(pot.earningsOf(breaker), 2_500e6 * 8 / 10 * 7 / 10);
    }

    function test_disputeReRatesDownAgainstFrozenTable() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        assertEq(pot.lockOf(F).amount, 10_000e6);

        _table(10_000e6, 0, 0, 0);
        vm.prank(client);
        gate.dispute(F, Severity.High, bytes32(0));

        vm.expectEmit(address(gate));
        emit SapperSettlementGate.DisputeResolved(F, Severity.High, false, 2_500e6);
        vm.prank(resolver);
        gate.resolve(F, Severity.High, false);

        assertEq(pot.lockOf(F).amount, 2_500e6);
        assertEq(pot.lockedBalance(client), 2_500e6);
        assertEq(pot.unlockedBalance(client), 7_500e6);
        assertEq(uint8(gate.finding(F).severity), uint8(Severity.High));

        pot.settle(F);
        uint256 checkersCut = 125e6;
        uint256 dust = checkersCut - 3 * (checkersCut / 3);
        assertEq(pot.earningsOf(treasury), 250e6 + dust);
    }

    function test_disputeRejectReturnsLockAndFreesRootCause() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.High, ROOT_CAUSE);
        vm.prank(client);
        gate.dispute(F, Severity.Low, keccak256("prior report"));
        vm.prank(resolver);
        gate.resolve(F, Severity.Low, true);

        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Rejected));
        assertEq(pot.unlockedBalance(client), 10_000e6);
        assertEq(pot.lockedBalance(client), 0);
        assertEq(uint8(pot.lockOf(F).status), uint8(ISapperBountyPot.LockStatus.Released));
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F));
        pot.settle(F);

        _confirm(G);
        _rate(G, Severity.High, ROOT_CAUSE);
        assertEq(uint8(_status(G)), uint8(SapperSettlementGate.Status.Review));
    }

    function test_disputeGuards() public {
        _fund(client, 10_000e6);
        _confirm(F);

        vm.prank(client);
        vm.expectRevert(
            abi.encodeWithSelector(SapperSettlementGate.BadStatus.selector, F, SapperSettlementGate.Status.Confirmed)
        );
        gate.dispute(F, Severity.Low, 0);

        _rate(F, Severity.High, ROOT_CAUSE);
        vm.expectRevert(SapperSettlementGate.NotClient.selector);
        gate.dispute(F, Severity.Low, 0);

        vm.prank(client);
        gate.dispute(F, Severity.Low, 0);

        vm.expectRevert(SapperSettlementGate.NotResolver.selector);
        gate.resolve(F, Severity.Low, false);
        vm.prank(resolver);
        vm.expectRevert(SapperSettlementGate.CannotRaiseSeverity.selector);
        gate.resolve(F, Severity.Critical, false);

        vm.prank(resolver);
        gate.resolve(F, Severity.High, false);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SapperSettlementGate.ReviewClosed.selector, uint64(block.timestamp)));
        gate.dispute(F, Severity.Low, 0);
    }

    function test_expiredLockRefundsAndCannotSettle() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        uint64 expiry = pot.lockOf(F).expiry;

        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.LockExpired.selector, F));
        pot.settle(F);

        vm.prank(makeAddr("anyone"));
        pot.reclaimExpired(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Expired));
        assertEq(pot.unlockedBalance(client), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F));
        pot.settle(F);
    }

    function test_unresolvedDisputeExpiresToClient() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        vm.prank(client);
        gate.dispute(F, Severity.Low, 0);

        vm.warp(pot.lockOf(F).expiry + 1);
        pot.reclaimExpired(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Expired));
        assertEq(pot.unlockedBalance(client), 10_000e6);

        vm.prank(resolver);
        vm.expectRevert(
            abi.encodeWithSelector(SapperSettlementGate.BadStatus.selector, F, SapperSettlementGate.Status.Expired)
        );
        gate.resolve(F, Severity.Low, false);
    }

    function testFuzz_unlockedWithdrawAlwaysSucceeds(uint96 funded, uint96 request, uint8 open) public {
        funded = uint96(bound(funded, 1, 1e14));
        open = uint8(bound(open, 0, 3));
        _fund(client, funded);
        _table(uint128(funded) / 4, uint128(funded) / 8, 1, 0);

        for (uint256 i; i < open; ++i) {
            bytes32 id = keccak256(abi.encode("locked", i));
            _confirm(id);
            _rate(id, Severity(3 - i), keccak256(abi.encode("cause", i)));
        }
        vm.prank(guardian);
        gate.setClaimsPaused(true);

        uint256 unlocked = pot.unlockedBalance(client);
        uint256 locked = pot.lockedBalance(client);
        assertEq(unlocked + locked, funded);
        request = uint96(bound(request, 0, unlocked));
        vm.prank(client);
        pot.withdraw(request);
        assertEq(usdg.balanceOf(client), request);
        assertEq(pot.lockedBalance(client), locked);

        vm.prank(client);
        pot.withdraw(unlocked - request);
        assertEq(usdg.balanceOf(client), unlocked);
        assertEq(usdg.balanceOf(address(pot)), locked);
    }

    function test_emptyPotIsConfirmedButUnpaid() public {
        _confirm(F);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        assertEq(pot.lockOf(F).amount, 0);
        vm.warp(block.timestamp + 72 hours);
        pot.settle(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Settled));
        assertEq(pot.earningsOf(breaker), 0);
    }

    function test_settleCreditsFrozenPayeesWhoWithdrawLater() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        usdg.setBlocked(fixer, true);
        usdg.setBlocked(treasury, true);
        usdg.setBlocked(address(burn), true);
        vm.warp(block.timestamp + 72 hours);

        pot.settle(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Settled));
        assertEq(pot.earningsOf(breaker), 5_600e6);
        assertEq(pot.earningsOf(fixer), 2_400e6);
        assertEq(pot.earningsOf(treasury), 1_000e6 + 2);
        assertEq(pot.earningsOf(address(burn)), 500e6);
        assertEq(usdg.balanceOf(address(pot)), 10_000e6);

        vm.prank(breaker);
        pot.withdrawEarnings(5_600e6);
        assertEq(usdg.balanceOf(breaker), 5_600e6);

        vm.prank(fixer);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.Blocked.selector, fixer));
        pot.withdrawEarnings(2_400e6);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.Blocked.selector, address(burn)));
        burn.collect(pot);

        usdg.setBlocked(fixer, false);
        usdg.setBlocked(treasury, false);
        usdg.setBlocked(address(burn), false);
        vm.prank(fixer);
        pot.withdrawEarnings(2_400e6);
        vm.prank(treasury);
        pot.withdrawEarnings(1_000e6 + 2);
        vm.prank(owner);
        burn.collect(pot);
        for (uint256 i; i < 3; ++i) {
            uint256 earned = pot.earningsOf(checkers[i]);
            vm.prank(checkers[i]);
            pot.withdrawEarnings(earned);
        }
        assertEq(usdg.balanceOf(fixer), 2_400e6);
        assertEq(usdg.balanceOf(address(burn)), 500e6);
        assertEq(usdg.balanceOf(address(pot)), 0);
    }

    function test_settlePostsValidation() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.Critical, ROOT_CAUSE);
        vm.prank(owner);
        gate.setValidationBaseURI("https://sapper.example/f/");
        vm.warp(block.timestamp + 72 hours);

        bytes32 requestHash = keccak256(abi.encode(block.chainid, address(gate), F, RESULT, block.number));
        vm.expectEmit(address(gate));
        emit SapperSettlementGate.ValidationPosted(F, agentId, requestHash);
        pot.settle(F);
        assertEq(gate.validationRequestOf(F), requestHash);

        (address validator, uint256 id, uint8 response, bytes32 responseHash, string memory tag,) =
            validation.getValidationStatus(requestHash);
        assertEq(validator, address(gate));
        assertEq(id, agentId);
        assertEq(response, 100);
        assertEq(responseHash, RESULT);
        assertEq(tag, "critical");
        assertEq(validation.getAgentValidations(agentId)[0], requestHash);
    }

    function test_validationRefusalNeverBlocksSettle() public {
        _fund(client, 10_000e6);
        _confirm(F);
        _rate(F, Severity.High, ROOT_CAUSE);
        vm.prank(breaker);
        identity.setApprovalForAll(address(gate), false);
        vm.warp(block.timestamp + 72 hours);

        vm.expectEmit(address(gate));
        emit SapperSettlementGate.ValidationSkipped(F, agentId);
        pot.settle(F);
        assertEq(uint8(_status(F)), uint8(SapperSettlementGate.Status.Settled));
        assertEq(validation.getAgentValidations(agentId).length, 0);
        assertEq(gate.validationRequestOf(F), bytes32(0));
    }

    function test_callbacksAreRestricted() public {
        vm.expectRevert(SapperSettlementGate.NotCheckerNet.selector);
        gate.onCheckerConsensus(F, true, RESULT);
        vm.expectRevert(SapperSettlementGate.NotPot.selector);
        gate.onSettled(F);
        vm.expectRevert(SapperSettlementGate.NotPot.selector);
        gate.onExpired(F);
    }

    function test_config() public {
        vm.startPrank(owner);
        vm.expectRevert(SapperSettlementGate.BadConfig.selector);
        gate.setReviewWindow(0);
        vm.expectRevert(SapperSettlementGate.BadConfig.selector);
        gate.setReviewWindow(31 days);
        vm.expectRevert(SapperSettlementGate.BadConfig.selector);
        gate.setSettleGrace(61 days);
        vm.expectRevert(SapperSettlementGate.BadConfig.selector);
        gate.setRatingWindow(0);
        vm.expectRevert(SapperSettlementGate.BadConfig.selector);
        gate.setRatingWindow(31 days);
        vm.expectRevert(SapperSettlementGate.ZeroAddress.selector);
        gate.setKeeper(address(0));

        assertEq(gate.ratingWindow(), 7 days);
        vm.expectEmit(address(gate));
        emit SapperSettlementGate.RatingWindowSet(2 days);
        gate.setRatingWindow(2 days);
        gate.setReviewWindow(1 days);
        gate.setSettleGrace(7 days);
        address next = makeAddr("next");
        gate.setKeeper(next);
        gate.setGuardian(next);
        gate.setDisputeResolver(next);
        vm.stopPrank();

        assertEq(gate.ratingWindow(), 2 days);
        assertEq(gate.reviewWindow(), 1 days);
        assertEq(gate.settleGrace(), 7 days);
        assertEq(gate.keeper(), next);
        assertEq(gate.guardian(), next);
        assertEq(gate.disputeResolver(), next);

        vm.prank(keeper);
        vm.expectRevert();
        gate.setKeeper(keeper);
        vm.prank(keeper);
        vm.expectRevert();
        gate.setRatingWindow(1 days);
    }

    function _assertNeverPaid(bytes32 id) internal {
        assertEq(uint8(_status(id)), uint8(SapperSettlementGate.Status.Rejected));
        (address[] memory workers, uint16[] memory bps) = _split();
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SapperSettlementGate.BadStatus.selector, id, SapperSettlementGate.Status.Rejected)
        );
        gate.rate(id, Severity.Critical, ROOT_CAUSE, workers, bps);

        assertEq(uint8(pot.lockOf(id).status), uint8(ISapperBountyPot.LockStatus.Released));
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, id));
        pot.settle(id);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, id));
        pot.reclaimExpired(id);
        assertEq(pot.lockedBalance(client), 0);
        assertEq(pot.unlockedBalance(client), 10_000e6);
        assertEq(pot.earningsOf(breaker), 0);
        assertEq(pot.earningsOf(fixer), 0);
    }
}
