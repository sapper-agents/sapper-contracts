// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SapperCheckerNet} from "../src/SapperCheckerNet.sol";
import {MockUSDG} from "./mocks/Mocks.sol";
import {MockGate} from "./mocks/MockGate.sol";

contract SapperCheckerNetTest is Test {
    MockUSDG usdg;
    MockGate gate;
    SapperCheckerNet net;

    address treasury = makeAddr("treasury");
    address breaker = makeAddr("breaker");
    uint256 constant MIN = 100e6;
    uint256 constant STAKE = 1_000e6;
    bytes32 constant H = keccak256("result");
    bytes32 constant F = keccak256("finding");

    function setUp() public {
        usdg = new MockUSDG();
        gate = new MockGate();
        net = new SapperCheckerNet(address(usdg), treasury, MIN, address(this));
        net.setGate(address(gate));
        gate.setCheckerNet(net);
    }

    function test_stakeJoinsPool() public {
        address c = _checker("c0", STAKE);
        assertTrue(net.isEligible(c));
        assertEq(net.checkerOf(c).stake, STAKE);
        assertEq(net.poolSize(), 1);

        address small = _checker("small", MIN - 1);
        assertFalse(net.isEligible(small));
    }

    function test_openRoundDrawsDistinctEligibleCheckers() public {
        address[] memory pool = _checkers(8);
        address[] memory drawn = _open(F, 5);
        assertEq(drawn.length, 5);
        for (uint256 i; i < 5; ++i) {
            assertTrue(_in(pool, drawn[i]));
            assertTrue(net.voteOf(F, drawn[i]).assigned);
            assertEq(net.checkerOf(drawn[i]).openRounds, 1);
            for (uint256 j; j < i; ++j) {
                assertTrue(drawn[i] != drawn[j]);
            }
        }
        SapperCheckerNet.Round memory r = net.round(F);
        assertEq(r.commitEnd, block.timestamp + 5 minutes);
        assertEq(r.revealEnd, block.timestamp + 35 minutes);
    }

    function testFuzz_breakerOperatorNeverDrawn(bytes32 findingId, uint64 blockNumber, bytes32 hash, uint8 size)
        public
    {
        blockNumber = uint64(bound(blockNumber, 2, type(uint64).max));
        vm.roll(blockNumber);
        vm.setBlockhash(blockNumber - 1, hash);
        uint8 n = uint8(bound(size, 3, 5));
        _checkers(n);
        _stakeAs(breaker, STAKE);

        address[] memory drawn = _openExcluding(findingId, n, breaker);
        for (uint256 i; i < n; ++i) {
            assertTrue(drawn[i] != breaker);
        }
        assertFalse(net.voteOf(findingId, breaker).assigned);
    }

    function test_notEnoughCheckersOnceBreakerExcluded() public {
        _checkers(2);
        _stakeAs(breaker, STAKE);
        address[] memory exclude = new address[](1);
        exclude[0] = breaker;
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.NotEnoughCheckers.selector, 2, 3));
        gate.open(F, 3, exclude);
    }

    function test_ineligibleCheckersAreSkipped() public {
        address[] memory pool = _checkers(4);
        vm.prank(pool[0]);
        net.requestUnstake(STAKE - MIN + 1);
        assertFalse(net.isEligible(pool[0]));

        address[] memory drawn = _open(F, 3);
        for (uint256 i; i < 3; ++i) {
            assertTrue(drawn[i] != pool[0]);
        }
    }

    function test_roundSizeAndAccess() public {
        _checkers(6);
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.BadRoundSize.selector, 2));
        _open(F, 2);
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.BadRoundSize.selector, 6));
        _open(F, 6);
        vm.expectRevert(SapperCheckerNet.NotGate.selector);
        net.openRound(F, 3, new address[](0));
        _open(F, 3);
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.RoundExists.selector, F));
        _open(F, 3);
    }

    function test_unanimousRoundFinalizesEarly() public {
        address[] memory pool = _checkers(3);
        _open(F, 3);
        for (uint256 i; i < 3; ++i) {
            _commit(F, pool[i], true, H);
        }
        for (uint256 i; i < 3; ++i) {
            _reveal(F, pool[i], true, H);
        }
        net.finalize(F);

        assertEq(gate.consensusCalls(F), 1);
        assertTrue(gate.confirmedOf(F));
        assertEq(gate.resultOf(F), H);
        assertEq(net.consensusCheckers(F).length, 3);
        assertEq(usdg.balanceOf(treasury), 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(net.checkerOf(pool[i]).openRounds, 0);
            assertEq(net.checkerOf(pool[i]).stake, STAKE);
        }
    }

    function test_revealOpensAfterAllCommitOrWindowEnds() public {
        address[] memory pool = _checkers(3);
        _open(F, 3);
        _commit(F, pool[0], true, H);
        _commit(F, pool[1], true, H);

        vm.prank(pool[0]);
        vm.expectRevert(SapperCheckerNet.RevealNotOpen.selector);
        net.reveal(F, true, H, _salt(pool[0]));

        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(pool[2]);
        vm.expectRevert(SapperCheckerNet.CommitClosed.selector);
        net.commit(F, keccak256("late"));

        _reveal(F, pool[0], true, H);

        vm.warp(block.timestamp + 30 minutes);
        vm.prank(pool[1]);
        vm.expectRevert(SapperCheckerNet.RevealClosed.selector);
        net.reveal(F, true, H, _salt(pool[1]));
    }

    function test_commitAndRevealGuards() public {
        address[] memory pool = _checkers(3);
        _open(F, 3);

        vm.prank(makeAddr("outsider"));
        vm.expectRevert(SapperCheckerNet.NotAssigned.selector);
        net.commit(F, keccak256("x"));

        bytes32 commitment = net.commitmentOf(F, pool[0], true, H, _salt(pool[0]));
        vm.startPrank(pool[0]);
        vm.expectRevert(SapperCheckerNet.EmptyCommitment.selector);
        net.commit(F, bytes32(0));
        net.commit(F, commitment);
        vm.expectRevert(SapperCheckerNet.AlreadyCommitted.selector);
        net.commit(F, keccak256("again"));
        vm.stopPrank();

        vm.prank(pool[1]);
        vm.expectRevert(SapperCheckerNet.NotCommitted.selector);
        net.reveal(F, true, H, _salt(pool[1]));

        vm.warp(block.timestamp + 5 minutes + 1);
        vm.startPrank(pool[0]);
        vm.expectRevert(SapperCheckerNet.CommitmentMismatch.selector);
        net.reveal(F, false, H, _salt(pool[0]));
        net.reveal(F, true, H, _salt(pool[0]));
        vm.expectRevert(SapperCheckerNet.AlreadyRevealed.selector);
        net.reveal(F, true, H, _salt(pool[0]));
        vm.stopPrank();
    }

    function test_dissenterAndNonRevealerSlashed() public {
        address[] memory pool = _checkers(5);
        _open(F, 5);
        for (uint256 i; i < 3; ++i) {
            _commit(F, pool[i], true, H);
        }
        _commit(F, pool[3], false, bytes32(0));
        _commit(F, pool[4], true, H);
        for (uint256 i; i < 4; ++i) {
            _reveal(F, pool[i], i < 3, i < 3 ? H : bytes32(0));
        }

        vm.expectRevert(SapperCheckerNet.RoundStillOpen.selector);
        net.finalize(F);
        vm.warp(block.timestamp + 36 minutes);
        net.finalize(F);

        assertTrue(gate.confirmedOf(F));
        address[] memory consensus = net.consensusCheckers(F);
        assertEq(consensus.length, 3);
        for (uint256 i; i < 3; ++i) {
            assertTrue(_in(consensus, pool[i]));
            assertEq(net.checkerOf(pool[i]).stake, STAKE);
        }
        assertEq(net.checkerOf(pool[3]).stake, STAKE * 9 / 10);
        assertEq(net.checkerOf(pool[4]).stake, STAKE * 9 / 10);
        assertEq(net.checkerOf(pool[3]).strikes, 1);
        assertEq(net.checkerOf(pool[4]).strikes, 1);
        assertEq(usdg.balanceOf(treasury), STAKE * 2 / 10);
    }

    function test_majorityFailIsNotConfirmedAndSlashesTheOutlier() public {
        address[] memory pool = _checkers(3);
        _open(F, 3);
        _commit(F, pool[0], false, bytes32(0));
        _commit(F, pool[1], false, bytes32(0));
        _commit(F, pool[2], true, H);
        _reveal(F, pool[0], false, bytes32(0));
        _reveal(F, pool[1], false, bytes32(0));
        _reveal(F, pool[2], true, H);
        net.finalize(F);

        assertEq(gate.consensusCalls(F), 1);
        assertFalse(gate.confirmedOf(F));
        assertEq(net.checkerOf(pool[2]).stake, STAKE * 9 / 10);
        assertEq(net.checkerOf(pool[0]).stake, STAKE);
    }

    function test_noStrictMajorityIsNotConfirmed() public {
        address[] memory pool = _checkers(4);
        _open(F, 4);
        _commit(F, pool[0], true, H);
        _commit(F, pool[1], true, H);
        _commit(F, pool[2], true, keccak256("other"));
        _commit(F, pool[3], true, keccak256("other"));
        _reveal(F, pool[0], true, H);
        _reveal(F, pool[1], true, H);
        _reveal(F, pool[2], true, keccak256("other"));
        _reveal(F, pool[3], true, keccak256("other"));
        net.finalize(F);

        assertFalse(gate.confirmedOf(F));
        assertEq(gate.resultOf(F), bytes32(0));
        assertEq(net.consensusCheckers(F).length, 0);
        assertEq(usdg.balanceOf(treasury), 0);
    }

    function test_noMajoritySlashesOnlyNonRevealers() public {
        address[] memory pool = _checkers(3);
        _open(F, 3);
        _commit(F, pool[0], true, H);
        _commit(F, pool[1], true, keccak256("other"));
        vm.warp(block.timestamp + 5 minutes + 1);
        _reveal(F, pool[0], true, H);
        _reveal(F, pool[1], true, keccak256("other"));
        vm.warp(block.timestamp + 31 minutes);
        net.finalize(F);

        assertFalse(gate.confirmedOf(F));
        assertEq(net.checkerOf(pool[0]).stake, STAKE);
        assertEq(net.checkerOf(pool[1]).stake, STAKE);
        assertEq(net.checkerOf(pool[2]).stake, STAKE * 9 / 10);
    }

    function test_threeStrikesRemove() public {
        address[] memory pool = _checkers(3);
        address lazy = pool[2];
        for (uint256 k; k < 3; ++k) {
            bytes32 id = keccak256(abi.encode("round", k));
            _open(id, 3);
            _commit(id, pool[0], true, H);
            _commit(id, pool[1], true, H);
            vm.warp(block.timestamp + 5 minutes + 1);
            _reveal(id, pool[0], true, H);
            _reveal(id, pool[1], true, H);
            vm.warp(block.timestamp + 31 minutes);
            net.finalize(id);
        }

        SapperCheckerNet.Checker memory c = net.checkerOf(lazy);
        assertEq(c.strikes, 3);
        assertTrue(c.removed);
        assertFalse(net.isEligible(lazy));
        assertEq(net.poolSize(), 2);
        assertEq(c.stake, STAKE * 729 / 1000);

        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.NotEnoughCheckers.selector, 2, 3));
        _open(keccak256("next"), 3);

        usdg.mint(lazy, STAKE);
        vm.startPrank(lazy);
        usdg.approve(address(net), STAKE);
        vm.expectRevert(SapperCheckerNet.Removed.selector);
        net.stake(STAKE);

        net.requestUnstake(c.stake);
        vm.warp(block.timestamp + 7 days);
        net.withdrawStake();
        vm.stopPrank();
        assertEq(usdg.balanceOf(lazy), STAKE + c.stake);
    }

    function test_cannotUnstakeWhileAssigned() public {
        address[] memory pool = _checkers(3);
        _open(F, 3);
        vm.prank(pool[0]);
        net.requestUnstake(STAKE);
        vm.warp(block.timestamp + 7 days);

        vm.prank(pool[0]);
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.AssignedToOpenRound.selector, 1));
        net.withdrawStake();

        net.finalize(F);
        vm.prank(pool[0]);
        net.withdrawStake();
        assertEq(usdg.balanceOf(pool[0]), STAKE * 9 / 10);
        assertEq(net.poolSize(), 2);
    }

    function test_unstakeCooldown() public {
        address c = _checker("c0", STAKE);
        vm.startPrank(c);
        vm.expectRevert(SapperCheckerNet.NothingPending.selector);
        net.withdrawStake();
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.ExceedsFreeStake.selector, STAKE, STAKE + 1));
        net.requestUnstake(STAKE + 1);

        net.requestUnstake(400e6);
        uint64 unlockAt = uint64(block.timestamp + 7 days);
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.CooldownActive.selector, unlockAt));
        net.withdrawStake();
        vm.warp(unlockAt);
        net.withdrawStake();
        vm.stopPrank();

        assertEq(usdg.balanceOf(c), 400e6);
        assertEq(net.checkerOf(c).stake, 600e6);
        assertTrue(net.isEligible(c));
    }

    function test_finalizeGuards() public {
        vm.expectRevert(abi.encodeWithSelector(SapperCheckerNet.NoRound.selector, F));
        net.finalize(F);
        _checkers(3);
        _open(F, 3);
        vm.expectRevert(SapperCheckerNet.RoundStillOpen.selector);
        net.finalize(F);
        vm.warp(block.timestamp + 36 minutes);
        net.finalize(F);
        vm.expectRevert(SapperCheckerNet.AlreadyFinalized.selector);
        net.finalize(F);
        assertFalse(gate.confirmedOf(F));
    }

    function test_configBoundsAndOwner() public {
        vm.expectRevert(SapperCheckerNet.BadConfig.selector);
        net.setMinStake(0);
        vm.expectRevert(SapperCheckerNet.BadConfig.selector);
        net.setCooldown(31 days);
        vm.expectRevert(SapperCheckerNet.BadConfig.selector);
        net.setWindows(0, 1);
        vm.expectRevert(SapperCheckerNet.GateAlreadySet.selector);
        net.setGate(address(1));

        net.setWindows(10 minutes, 1 hours);
        assertEq(net.commitWindow(), 10 minutes);
        assertEq(net.revealWindow(), 1 hours);

        vm.prank(breaker);
        vm.expectRevert();
        net.setMinStake(1);
    }

    function _checker(string memory label, uint256 amount) internal returns (address c) {
        c = makeAddr(label);
        _stakeAs(c, amount);
    }

    function _checkers(uint256 n) internal returns (address[] memory pool) {
        pool = new address[](n);
        for (uint256 i; i < n; ++i) {
            pool[i] = _checker(string.concat("checker", vm.toString(i)), STAKE);
        }
    }

    function _stakeAs(address c, uint256 amount) internal {
        usdg.mint(c, amount);
        vm.startPrank(c);
        usdg.approve(address(net), amount);
        net.stake(amount);
        vm.stopPrank();
    }

    function _open(bytes32 id, uint8 n) internal returns (address[] memory) {
        return gate.open(id, n, new address[](0));
    }

    function _openExcluding(bytes32 id, uint8 n, address who) internal returns (address[] memory) {
        address[] memory exclude = new address[](1);
        exclude[0] = who;
        return gate.open(id, n, exclude);
    }

    function _salt(address c) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", c));
    }

    function _commit(bytes32 id, address c, bool passed, bytes32 hash) internal {
        bytes32 commitment = net.commitmentOf(id, c, passed, hash, _salt(c));
        vm.prank(c);
        net.commit(id, commitment);
    }

    function _reveal(bytes32 id, address c, bool passed, bytes32 hash) internal {
        vm.prank(c);
        net.reveal(id, passed, hash, _salt(c));
    }

    function _in(address[] memory list, address a) internal pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}
