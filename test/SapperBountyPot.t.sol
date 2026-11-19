// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {SapperBurnBuffer} from "../src/SapperBurnBuffer.sol";
import {ISapperBountyPot, Severity} from "../src/interfaces/ISapperBountyPot.sol";
import {MockUSDG, RejectingPayee} from "./mocks/Mocks.sol";
import {MockGate} from "./mocks/MockGate.sol";

contract SapperBountyPotTest is Test {
    MockUSDG usdg;
    MockGate gate;
    SapperBountyPot pot;
    SapperBurnBuffer burn;

    address treasury = makeAddr("treasury");
    uint256 constant CLIENT_KEY = 0xC11E;
    address client = vm.addr(CLIENT_KEY);
    address other = makeAddr("other");

    bytes32 constant F1 = keccak256("f1");
    bytes32 constant F2 = keccak256("f2");

    function setUp() public {
        usdg = new MockUSDG();
        gate = new MockGate();
        burn = new SapperBurnBuffer(address(this));
        pot = new SapperBountyPot(address(usdg), treasury, address(burn), address(this));
        pot.setGate(address(gate));
        gate.setPot(pot);
    }

    function test_defaultTable() public view {
        ISapperBountyPot.Table memory t = pot.table(client);
        assertEq(t.crit, 10_000e6);
        assertEq(t.high, 2_500e6);
        assertEq(t.med, 500e6);
        assertEq(t.low, 0);
    }

    function test_fundAndWithdraw() public {
        _fund(client, 1_000e6);
        assertEq(pot.unlockedBalance(client), 1_000e6);
        assertEq(usdg.balanceOf(address(pot)), 1_000e6);

        vm.expectEmit(address(pot));
        emit SapperBountyPot.Withdrawn(client, 400e6);
        vm.prank(client);
        pot.withdraw(400e6);
        assertEq(pot.unlockedBalance(client), 600e6);
        assertEq(usdg.balanceOf(client), 400e6);

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientUnlocked.selector, 600e6, 601e6));
        pot.withdraw(601e6);
    }

    function test_fundWithPermit() public {
        usdg.mint(client, 500e6);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(500e6, deadline);
        vm.prank(client);
        pot.fundWithPermit(500e6, deadline, v, r, s);
        assertEq(pot.unlockedBalance(client), 500e6);
    }

    function test_fundWithPermitSurvivesFrontRun() public {
        usdg.mint(client, 500e6);
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _permit(500e6, deadline);
        usdg.permit(client, address(pot), 500e6, deadline, v, r, s);
        vm.prank(client);
        pot.fundWithPermit(500e6, deadline, v, r, s);
        assertEq(pot.unlockedBalance(client), 500e6);
    }

    function testFuzz_withdrawWhileOtherFindingsLocked(uint96 funded, uint8 locks, uint96 request) public {
        funded = uint96(bound(funded, 1, 1e15));
        locks = uint8(bound(locks, 0, 6));
        _fund(client, funded);
        _fund(other, funded);
        _setTable(client, ISapperBountyPot.Table(uint128(funded) / 3 + 1, uint128(funded) / 5, 7, 1));

        for (uint256 i; i < locks; ++i) {
            gate.lock(keccak256(abi.encode("c", i)), client, _expiry());
            gate.lock(keccak256(abi.encode("o", i)), other, _expiry());
        }

        uint256 unlocked = pot.unlockedBalance(client);
        uint256 lockedBefore = pot.lockedBalance(client);
        request = uint96(bound(request, 0, unlocked));
        vm.prank(client);
        pot.withdraw(request);

        assertEq(usdg.balanceOf(client), request);
        assertEq(pot.unlockedBalance(client), unlocked - request);
        assertEq(pot.lockedBalance(client), lockedBefore);
        assertEq(usdg.balanceOf(address(pot)), uint256(funded) * 2 - request);
    }

    function testFuzz_lockNeverExceedsUnlockedOrTouchesOtherLocks(
        uint96 funded,
        uint128 crit,
        uint128 high,
        uint8 count,
        uint256 seed
    ) public {
        funded = uint96(bound(funded, 0, 1e15));
        crit = uint128(bound(crit, 0, 2e15));
        high = uint128(bound(high, 0, 2e15));
        count = uint8(bound(count, 1, 12));
        _fund(client, funded);
        _setTable(client, ISapperBountyPot.Table(crit, high, high / 2, 0));

        bytes32[] memory ids = new bytes32[](count);
        uint256[] memory amounts = new uint256[](count);
        uint256 sum;
        for (uint256 i; i < count; ++i) {
            ids[i] = keccak256(abi.encode(seed, i));
            uint256 unlockedBefore = pot.unlockedBalance(client);
            amounts[i] = gate.lock(ids[i], client, _expiry());

            assertEq(amounts[i], crit < unlockedBefore ? crit : unlockedBefore);
            assertEq(uint8(pot.lockOf(ids[i]).severity), uint8(Severity.Critical));
            sum += amounts[i];
            for (uint256 j; j <= i; ++j) {
                assertEq(pot.lockOf(ids[j]).amount, amounts[j]);
            }
        }
        assertEq(pot.lockedBalance(client), sum);
        assertEq(pot.unlockedBalance(client), uint256(funded) - sum);
    }

    function test_lockIsGateOnlyAndUnique() public {
        vm.expectRevert(SapperBountyPot.NotGate.selector);
        pot.lockForFinding(F1, client, _expiry());

        gate.lock(F1, client, _expiry());
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.LockExists.selector, F1));
        gate.lock(F1, client, _expiry());

        vm.expectRevert(SapperBountyPot.BadExpiry.selector);
        gate.lock(F2, client, uint64(block.timestamp));
    }

    function test_emptyPotLocksZero() public {
        uint256 locked = gate.lock(F1, client, _expiry());
        assertEq(locked, 0);
        assertEq(uint8(pot.lockOf(F1).status), uint8(ISapperBountyPot.LockStatus.Locked));
    }

    function testFuzz_tableChangeDoesNotAlterLock(uint128 before, uint128 later) public {
        before = uint128(bound(before, 1, 1e15));
        _fund(client, 2e15);
        _setTable(client, ISapperBountyPot.Table(before, before / 2, 0, 0));
        gate.lock(F1, client, _expiry());

        _setTable(client, ISapperBountyPot.Table(later, later, later, later));
        ISapperBountyPot.Lock memory l = pot.lockOf(F1);
        assertEq(l.amount, before);
        assertEq(l.terms.crit, before);
        assertEq(pot.lockedBalance(client), before);

        assertEq(gate.adjust(F1, Severity.High, _expiry()), before / 2);
        assertEq(pot.lockedBalance(client), before / 2);
    }

    function testFuzz_settleSplitsExactly(uint96 amount, uint8 nWorkers, uint8 nCheckers, uint256 seed) public {
        amount = uint96(bound(amount, 0, 1e15));
        nWorkers = uint8(bound(nWorkers, 1, 16));
        nCheckers = uint8(bound(nCheckers, 0, 5));
        _fund(client, amount);
        _setTable(client, ISapperBountyPot.Table(amount, 0, 0, 0));
        gate.lock(F1, client, _expiry());

        (address[] memory workers, uint16[] memory bps) = _workers(nWorkers, seed);
        address[] memory checkers = _addrs("checker", nCheckers);
        gate.setPayees(F1, workers, bps, checkers);
        gate.setSettleable(F1, true);

        pot.settle(F1);

        uint256 credited;
        for (uint256 i; i < nWorkers; ++i) {
            assertEq(pot.earningsOf(workers[i]), uint256(amount) * 8_000 * bps[i] / 1e8);
            credited += pot.earningsOf(workers[i]);
        }
        uint256 each = nCheckers == 0 ? 0 : uint256(amount) * 500 / (10_000 * uint256(nCheckers));
        for (uint256 i; i < nCheckers; ++i) {
            assertEq(pot.earningsOf(checkers[i]), each);
            credited += each;
        }
        assertEq(pot.earningsOf(address(burn)), uint256(amount) * 500 / 10_000);
        credited += pot.earningsOf(address(burn));

        uint256 toTreasury = pot.earningsOf(treasury);
        assertGe(toTreasury, uint256(amount) * 1_000 / 10_000);
        if (nCheckers != 0) assertLe(toTreasury - uint256(amount) * 1_000 / 10_000, uint256(nWorkers) + nCheckers + 4);
        credited += toTreasury;

        assertEq(credited, amount);
        assertEq(usdg.balanceOf(address(pot)), amount);
        assertEq(pot.lockedBalance(client), 0);
        assertEq(pot.unlockedBalance(client), 0);
        assertEq(gate.settledCalls(F1), 1);

        for (uint256 i; i < nWorkers; ++i) {
            _withdrawAll(workers[i]);
        }
        for (uint256 i; i < nCheckers; ++i) {
            _withdrawAll(checkers[i]);
        }
        _withdrawAll(treasury);
        burn.collect(pot);
        assertEq(usdg.balanceOf(address(pot)), 0);
        assertEq(usdg.balanceOf(address(burn)), uint256(amount) * 500 / 10_000);
    }

    function test_settleExactBpsOnRoundAmount() public {
        _fund(client, 10_000e6);
        gate.lock(F1, client, _expiry());
        (address[] memory workers, uint16[] memory bps) = _workers(1, 0);
        address[] memory checkers = _addrs("checker", 2);
        gate.setPayees(F1, workers, bps, checkers);
        gate.setSettleable(F1, true);

        vm.expectEmit(address(pot));
        emit SapperBountyPot.EarningsCredited(workers[0], F1, 8_000e6);
        vm.expectEmit(address(pot));
        emit SapperBountyPot.EarningsCredited(checkers[0], F1, 250e6);
        vm.expectEmit(address(pot));
        emit SapperBountyPot.EarningsCredited(checkers[1], F1, 250e6);
        vm.expectEmit(address(pot));
        emit SapperBountyPot.EarningsCredited(address(burn), F1, 500e6);
        vm.expectEmit(address(pot));
        emit SapperBountyPot.EarningsCredited(treasury, F1, 1_000e6);
        vm.expectEmit(address(pot));
        emit SapperBountyPot.FindingSettled(F1, 10_000e6, 8_000e6, 1_000e6, 500e6, 500e6);
        pot.settle(F1);
        assertEq(pot.earningsOf(workers[0]), 8_000e6);
        assertEq(pot.earningsOf(treasury), 1_000e6);
        assertEq(pot.earningsOf(checkers[0]), 250e6);
        assertEq(pot.earningsOf(checkers[1]), 250e6);
        assertEq(pot.earningsOf(address(burn)), 500e6);
        assertEq(usdg.balanceOf(workers[0]), 0);

        vm.expectEmit(address(pot));
        emit SapperBountyPot.EarningsWithdrawn(workers[0], workers[0], 8_000e6);
        vm.prank(workers[0]);
        pot.withdrawEarnings(8_000e6);
        assertEq(usdg.balanceOf(workers[0]), 8_000e6);
        assertEq(pot.earningsOf(workers[0]), 0);
    }

    function test_settleGuards() public {
        _fund(client, 10_000e6);
        gate.lock(F1, client, _expiry());
        (address[] memory workers, uint16[] memory bps) = _workers(2, 1);
        gate.setPayees(F1, workers, bps, _addrs("checker", 3));

        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotSettleable.selector, F1));
        pot.settle(F1);

        gate.setSettleable(F1, true);
        pot.settle(F1);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F1));
        pot.settle(F1);

        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F2));
        pot.settle(F2);
    }

    function test_expiredLockRefundsByAnyoneAndCannotSettle() public {
        _fund(client, 3_000e6);
        _setTable(client, ISapperBountyPot.Table(2_500e6, 1_000e6, 0, 0));
        uint64 expiry = _expiry();
        gate.lock(F1, client, expiry);
        gate.setPayees(F1, _addrs("w", 1), _bps1(), _addrs("checker", 3));
        gate.setSettleable(F1, true);
        assertEq(pot.unlockedBalance(client), 500e6);

        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotExpired.selector, F1));
        pot.reclaimExpired(F1);

        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.LockExpired.selector, F1));
        pot.settle(F1);

        vm.expectEmit(address(pot));
        emit SapperBountyPot.FindingExpiredRefunded(F1, client, 2_500e6);
        vm.prank(makeAddr("anyone"));
        pot.reclaimExpired(F1);

        assertEq(pot.unlockedBalance(client), 3_000e6);
        assertEq(pot.lockedBalance(client), 0);
        assertEq(gate.expiredCalls(F1), 1);

        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F1));
        pot.settle(F1);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F1));
        pot.reclaimExpired(F1);

        vm.prank(client);
        pot.withdraw(3_000e6);
        assertEq(usdg.balanceOf(client), 3_000e6);
    }

    function test_reclaimSurvivesFailingGate() public {
        _fund(client, 1_000e6);
        uint64 expiry = _expiry();
        gate.lock(F1, client, expiry);
        gate.setRevertOnExpired(true);
        vm.warp(expiry + 1);
        pot.reclaimExpired(F1);
        assertEq(pot.unlockedBalance(client), 1_000e6);
        assertEq(uint8(pot.lockOf(F1).status), uint8(ISapperBountyPot.LockStatus.Refunded));
    }

    function test_adjustLockReturnsDifference() public {
        _fund(client, 10_000e6);
        gate.lock(F1, client, _expiry());
        assertEq(pot.unlockedBalance(client), 0);

        uint64 later = _expiry() + 1 days;
        vm.expectEmit(address(pot));
        emit SapperBountyPot.LockAdjusted(F1, Severity.High, 10_000e6, 2_500e6, later);
        assertEq(gate.adjust(F1, Severity.High, later), 2_500e6);
        ISapperBountyPot.Lock memory l = pot.lockOf(F1);
        assertEq(l.amount, 2_500e6);
        assertEq(l.expiry, later);
        assertEq(uint8(l.severity), uint8(Severity.High));
        assertEq(pot.lockedBalance(client), 2_500e6);
        assertEq(pot.unlockedBalance(client), 7_500e6);

        assertEq(gate.adjust(F1, Severity.Critical, later), 2_500e6);
        assertEq(pot.unlockedBalance(client), 7_500e6);

        assertEq(gate.adjust(F1, Severity.Low, later), 0);
        assertEq(pot.unlockedBalance(client), 10_000e6);

        vm.expectRevert(SapperBountyPot.BadExpiry.selector);
        gate.adjust(F1, Severity.Low, uint64(block.timestamp));
        vm.expectRevert(SapperBountyPot.NotGate.selector);
        pot.adjustLock(F1, Severity.Low, later);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F2));
        gate.adjust(F2, Severity.Low, later);
    }

    function test_expiredLockCannotBeAdjusted() public {
        _fund(client, 10_000e6);
        uint64 expiry = _expiry();
        gate.lock(F1, client, expiry);
        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.LockExpired.selector, F1));
        gate.adjust(F1, Severity.High, expiry + 30 days);
        pot.reclaimExpired(F1);
        assertEq(pot.unlockedBalance(client), 10_000e6);
    }

    function test_releaseLockReturnsEverything() public {
        _fund(client, 12_000e6);
        gate.lock(F1, client, _expiry());
        assertEq(pot.unlockedBalance(client), 2_000e6);

        vm.expectEmit(address(pot));
        emit SapperBountyPot.LockReleased(F1, client, 10_000e6);
        assertEq(gate.release(F1), 10_000e6);
        assertEq(uint8(pot.lockOf(F1).status), uint8(ISapperBountyPot.LockStatus.Released));
        assertEq(pot.unlockedBalance(client), 12_000e6);
        assertEq(pot.lockedBalance(client), 0);

        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F1));
        gate.release(F1);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F1));
        pot.reclaimExpired(F1);
        gate.setSettleable(F1, true);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.NotLocked.selector, F1));
        pot.settle(F1);
        vm.expectRevert(SapperBountyPot.NotGate.selector);
        pot.releaseLock(F1);
    }

    function test_releaseAfterRefundIsANoOp() public {
        _fund(client, 1_000e6);
        uint64 expiry = _expiry();
        gate.lock(F1, client, expiry);
        vm.warp(expiry + 1);
        pot.reclaimExpired(F1);
        assertEq(gate.release(F1), 0);
        assertEq(uint8(pot.lockOf(F1).status), uint8(ISapperBountyPot.LockStatus.Refunded));
        assertEq(pot.unlockedBalance(client), 1_000e6);
    }

    function test_zeroLockSettlesWithNoCredits() public {
        gate.lock(F1, client, _expiry());
        gate.setPayees(F1, _addrs("w", 1), _bps1(), _addrs("checker", 3));
        gate.setSettleable(F1, true);
        vm.recordLogs();
        pot.settle(F1);
        assertEq(vm.getRecordedLogs().length, 1);
        assertEq(uint8(pot.lockOf(F1).status), uint8(ISapperBountyPot.LockStatus.Settled));
        assertEq(pot.earningsOf(treasury), 0);
    }

    function test_settleNeverBlockedByFrozenOrRejectingPayee() public {
        _fund(client, 10_000e6);
        gate.lock(F1, client, _expiry());
        RejectingPayee rejecting = new RejectingPayee();
        usdg.setHooked(address(rejecting), true);
        address frozen = makeAddr("frozen");
        usdg.setBlocked(frozen, true);
        usdg.setBlocked(treasury, true);

        address[] memory workers = new address[](2);
        workers[0] = address(rejecting);
        workers[1] = frozen;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 5_000;
        bps[1] = 5_000;
        gate.setPayees(F1, workers, bps, _addrs("checker", 2));
        gate.setSettleable(F1, true);

        pot.settle(F1);
        assertEq(uint8(pot.lockOf(F1).status), uint8(ISapperBountyPot.LockStatus.Settled));
        assertEq(pot.earningsOf(address(rejecting)), 4_000e6);
        assertEq(pot.earningsOf(frozen), 4_000e6);
        assertEq(pot.earningsOf(treasury), 1_000e6);

        vm.prank(frozen);
        vm.expectRevert(abi.encodeWithSelector(MockUSDG.Blocked.selector, frozen));
        pot.withdrawEarnings(4_000e6);
        vm.expectRevert("rejected");
        rejecting.withdraw(pot, 4_000e6);
        assertEq(pot.earningsOf(frozen), 4_000e6);
        assertEq(pot.earningsOf(address(rejecting)), 4_000e6);

        usdg.setBlocked(frozen, false);
        vm.prank(frozen);
        pot.withdrawEarnings(4_000e6);
        assertEq(usdg.balanceOf(frozen), 4_000e6);

        rejecting.setAccepts(true);
        rejecting.withdraw(pot, 4_000e6);
        assertEq(usdg.balanceOf(address(rejecting)), 4_000e6);

        usdg.setBlocked(treasury, false);
        _withdrawAll(treasury);
        assertEq(usdg.balanceOf(treasury), 1_000e6);
    }

    function testFuzz_withdrawEarningsNeverExceedsCredit(uint96 amount, uint96 first, uint96 second) public {
        amount = uint96(bound(amount, 1, 1e15));
        _fund(client, amount);
        _setTable(client, ISapperBountyPot.Table(amount, 0, 0, 0));
        gate.lock(F1, client, _expiry());
        address worker = makeAddr("worker");
        address[] memory workers = new address[](1);
        workers[0] = worker;
        gate.setPayees(F1, workers, _bps1(), new address[](0));
        gate.setSettleable(F1, true);
        pot.settle(F1);
        uint256 credit = pot.earningsOf(worker);
        assertEq(credit, uint256(amount) * 8_000 / 10_000);

        vm.startPrank(worker);
        if (first > credit) {
            vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientEarnings.selector, credit, first));
            pot.withdrawEarnings(first);
            first = 0;
        } else {
            pot.withdrawEarnings(first);
        }
        uint256 left = credit - first;
        assertEq(pot.earningsOf(worker), left);
        if (second > left) {
            vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientEarnings.selector, left, second));
            pot.withdrawEarnings(second);
            second = 0;
        } else {
            pot.withdrawEarnings(second);
        }
        uint256 rest = left - second;
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientEarnings.selector, rest, rest + 1));
        pot.withdrawEarnings(rest + 1);
        vm.stopPrank();

        assertEq(usdg.balanceOf(worker), uint256(first) + second);
        assertEq(usdg.balanceOf(other), 0);
        assertLe(uint256(first) + second, credit);
        assertEq(pot.earningsOf(worker), rest);

        vm.prank(other);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientEarnings.selector, 0, 1));
        pot.withdrawEarnings(1);
    }


    function test_adminConfig() public {
        vm.expectRevert(SapperBountyPot.GateAlreadySet.selector);
        pot.setGate(other);

        pot.setTreasury(other);
        assertEq(pot.treasury(), other);
        pot.setBurnBuffer(other);
        assertEq(pot.burnBuffer(), other);
        vm.expectRevert(SapperBountyPot.ZeroAddress.selector);
        pot.setTreasury(address(0));

        vm.startPrank(client);
        vm.expectRevert();
        pot.setTreasury(client);
        vm.expectRevert();
        pot.setBurnBuffer(client);
        vm.stopPrank();
    }

    function test_burnBufferCollectsItsEarnings() public {
        _fund(client, 10_000e6);
        gate.lock(F1, client, _expiry());
        gate.setPayees(F1, _addrs("w", 1), _bps1(), new address[](0));
        gate.setSettleable(F1, true);
        pot.settle(F1);
        assertEq(pot.earningsOf(address(burn)), 500e6);

        vm.prank(client);
        vm.expectRevert();
        burn.collect(pot);

        vm.expectEmit(address(burn));
        emit SapperBurnBuffer.Collected(address(pot), 500e6);
        assertEq(burn.collect(pot), 500e6);
        assertEq(usdg.balanceOf(address(burn)), 500e6);
        assertEq(pot.earningsOf(address(burn)), 0);
    }

    function test_burnBufferReleaseOwnerOnly() public {
        usdg.mint(address(burn), 10e6);
        vm.prank(client);
        vm.expectRevert();
        burn.release(usdg, client, 10e6);
        burn.release(usdg, other, 10e6);
        assertEq(usdg.balanceOf(other), 10e6);
    }

    function _fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(pot), amount);
        pot.fund(amount);
        vm.stopPrank();
    }

    function _withdrawAll(address payee) internal {
        uint256 amount = pot.earningsOf(payee);
        vm.prank(payee);
        pot.withdrawEarnings(amount);
        assertEq(pot.earningsOf(payee), 0);
    }

    function _setTable(address who, ISapperBountyPot.Table memory t) internal {
        vm.prank(who);
        pot.setTable(t);
    }

    function _expiry() internal view returns (uint64) {
        return uint64(block.timestamp + 30 days);
    }

    function _permit(uint256 value, uint256 deadline) internal view returns (uint8, bytes32, bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                client,
                address(pot),
                value,
                usdg.nonces(client),
                deadline
            )
        );
        return vm.sign(CLIENT_KEY, keccak256(abi.encodePacked("\x19\x01", usdg.DOMAIN_SEPARATOR(), structHash)));
    }

    function _workers(uint256 n, uint256 seed) internal returns (address[] memory workers, uint16[] memory bps) {
        workers = _addrs("worker", n);
        bps = new uint16[](n);
        uint256[] memory raw = new uint256[](n);
        uint256 total;
        for (uint256 i; i < n; ++i) {
            raw[i] = uint256(keccak256(abi.encode(seed, i))) % 1_000 + 1;
            total += raw[i];
        }
        uint256 assigned;
        for (uint256 i; i < n; ++i) {
            bps[i] = uint16(raw[i] * 10_000 / total);
            assigned += bps[i];
        }
        bps[0] += uint16(10_000 - assigned);
    }

    function _bps1() internal pure returns (uint16[] memory bps) {
        bps = new uint16[](1);
        bps[0] = 10_000;
    }

    function _addrs(string memory label, uint256 n) internal returns (address[] memory out) {
        out = new address[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = makeAddr(string.concat(label, vm.toString(i)));
        }
    }
}
