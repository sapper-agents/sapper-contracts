// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {ISapperBountyPot, Severity} from "../src/interfaces/ISapperBountyPot.sol";
import {MockUSDG} from "./mocks/Mocks.sol";
import {MockGate} from "./mocks/MockGate.sol";

contract PotHandler is Test {
    SapperBountyPot public pot;
    MockGate public gate;
    MockUSDG public usdg;

    address[3] public clients = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2")];
    address[] public payees;
    bytes32[] public ids;
    uint256 public funded;
    uint256 public withdrawn;
    uint256 public settled;
    uint256 public earningsWithdrawn;

    constructor(SapperBountyPot pot_, MockGate gate_, MockUSDG usdg_) {
        pot = pot_;
        gate = gate_;
        usdg = usdg_;
        address[5] memory named = [makeAddr("w0"), makeAddr("w1"), makeAddr("k0"), makeAddr("k1"), makeAddr("k2")];
        for (uint256 i; i < named.length; ++i) {
            payees.push(named[i]);
        }
        payees.push(pot.treasury());
        payees.push(pot.burnBuffer());
    }

    function fund(uint256 c, uint256 amount) external {
        address client = clients[c % 3];
        amount = bound(amount, 0, 1e13);
        usdg.mint(client, amount);
        vm.startPrank(client);
        usdg.approve(address(pot), amount);
        pot.fund(amount);
        vm.stopPrank();
        funded += amount;
    }

    function withdraw(uint256 c, uint256 amount) external {
        address client = clients[c % 3];
        amount = bound(amount, 0, pot.unlockedBalance(client));
        vm.prank(client);
        pot.withdraw(amount);
        withdrawn += amount;
    }

    function setTable(uint256 c, uint128 crit, uint128 high, uint128 med, uint128 low) external {
        vm.prank(clients[c % 3]);
        pot.setTable(
            ISapperBountyPot.Table(
                uint128(bound(crit, 0, 1e13)),
                uint128(bound(high, 0, 1e13)),
                uint128(bound(med, 0, 1e13)),
                uint128(bound(low, 0, 1e13))
            )
        );
    }

    function lock(uint256 c, uint64 ttl) external {
        bytes32 id = keccak256(abi.encode("finding", ids.length));
        gate.lock(id, clients[c % 3], uint64(block.timestamp + bound(ttl, 1 hours, 20 days)));
        ids.push(id);

        address[] memory workers = new address[](2);
        workers[0] = payees[0];
        workers[1] = payees[1];
        uint16[] memory bps = new uint16[](2);
        bps[0] = 3_333;
        bps[1] = 6_667;
        address[] memory checkers = new address[](3);
        checkers[0] = payees[2];
        checkers[1] = payees[3];
        checkers[2] = payees[4];
        gate.setPayees(id, workers, bps, checkers);
        gate.setSettleable(id, true);
    }

    function adjust(uint256 i, uint8 severity, uint64 ttl) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        ISapperBountyPot.Lock memory l = pot.lockOf(id);
        if (l.status != ISapperBountyPot.LockStatus.Locked || block.timestamp > l.expiry) return;
        uint256 got = gate.adjust(id, Severity(severity % 4), uint64(block.timestamp + bound(ttl, 1 hours, 20 days)));
        assertLe(got, l.amount);
    }

    function release(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        ISapperBountyPot.LockStatus s = pot.lockOf(id).status;
        if (s != ISapperBountyPot.LockStatus.Locked && s != ISapperBountyPot.LockStatus.Refunded) return;
        gate.release(id);
    }

    function settle(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        ISapperBountyPot.Lock memory l = pot.lockOf(id);
        if (l.status != ISapperBountyPot.LockStatus.Locked || block.timestamp > l.expiry) return;
        pot.settle(id);
        settled += l.amount;
    }

    function reclaim(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        ISapperBountyPot.Lock memory l = pot.lockOf(id);
        if (l.status != ISapperBountyPot.LockStatus.Locked || block.timestamp <= l.expiry) return;
        pot.reclaimExpired(id);
    }

    function withdrawEarnings(uint256 p, uint256 amount) external {
        address payee = payees[p % payees.length];
        amount = bound(amount, 0, pot.earningsOf(payee));
        vm.prank(payee);
        pot.withdrawEarnings(amount);
        earningsWithdrawn += amount;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 10 days));
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function payeeCount() external view returns (uint256) {
        return payees.length;
    }
}

contract SapperBountyPotInvariantTest is Test {
    MockUSDG usdg;
    MockGate gate;
    SapperBountyPot pot;
    PotHandler handler;

    function setUp() public {
        usdg = new MockUSDG();
        gate = new MockGate();
        pot = new SapperBountyPot(address(usdg), makeAddr("treasury"), makeAddr("burn"), address(this));
        pot.setGate(address(gate));
        gate.setPot(pot);
        handler = new PotHandler(pot, gate, usdg);
        targetContract(address(handler));
    }

    function invariant_balanceEqualsPotsPlusEarnings() public view {
        uint256 total;
        for (uint256 i; i < 3; ++i) {
            address c = handler.clients(i);
            total += pot.unlockedBalance(c) + pot.lockedBalance(c);
        }
        uint256 n = handler.payeeCount();
        for (uint256 i; i < n; ++i) {
            total += pot.earningsOf(handler.payees(i));
        }
        assertEq(usdg.balanceOf(address(pot)), total);
    }

    function invariant_lockedEqualsOpenLocks() public view {
        uint256[3] memory open;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            ISapperBountyPot.Lock memory l = pot.lockOf(handler.ids(i));
            if (l.status != ISapperBountyPot.LockStatus.Locked) continue;
            for (uint256 j; j < 3; ++j) {
                if (handler.clients(j) == l.client) open[j] += l.amount;
            }
        }
        for (uint256 j; j < 3; ++j) {
            assertEq(pot.lockedBalance(handler.clients(j)), open[j]);
        }
    }

    function invariant_earningsEqualSettledLessWithdrawn() public view {
        uint256 earnings;
        uint256 n = handler.payeeCount();
        for (uint256 i; i < n; ++i) {
            earnings += pot.earningsOf(handler.payees(i));
        }
        assertEq(earnings, handler.settled() - handler.earningsWithdrawn());
    }

    function invariant_flowsConserve() public view {
        assertEq(handler.funded() - handler.withdrawn() - handler.earningsWithdrawn(), usdg.balanceOf(address(pot)));
    }
}
