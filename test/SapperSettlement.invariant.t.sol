// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Fixture} from "./Fixture.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {SapperBurnBuffer} from "../src/SapperBurnBuffer.sol";
import {SapperCheckerNet} from "../src/SapperCheckerNet.sol";
import {SapperSettlementGate} from "../src/SapperSettlementGate.sol";
import {ISapperBountyPot, Severity, priceOf} from "../src/interfaces/ISapperBountyPot.sol";
import {MockUSDG, OwnedTarget} from "./mocks/Mocks.sol";

/// Drives the real scope, pot, checker net and gate through random claim lifecycles.
contract SettlementHandler is Test {
    struct Roles {
        address owner;
        address keeper;
        address resolver;
        address breaker;
        address fixer;
        uint256 agentId;
    }

    MockUSDG public usdg;
    SapperBountyPot public pot;
    SapperCheckerNet public net;
    SapperSettlementGate public gate;
    SapperBurnBuffer public burn;
    Roles public roles;

    address[] public clients;
    address[] public targets;
    address[] public payees;
    bytes32[] public ids;
    mapping(bytes32 => uint256) public clientOf;

    uint256 public funded;
    uint256 public withdrawn;
    uint256 public settled;
    uint256 public earningsWithdrawn;

    constructor(
        MockUSDG usdg_,
        SapperBountyPot pot_,
        SapperCheckerNet net_,
        SapperSettlementGate gate_,
        SapperBurnBuffer burn_,
        Roles memory roles_,
        address[] memory clients_,
        address[] memory targets_,
        address[] memory checkers_
    ) {
        usdg = usdg_;
        pot = pot_;
        net = net_;
        gate = gate_;
        burn = burn_;
        roles = roles_;
        clients = clients_;
        targets = targets_;
        payees.push(roles_.breaker);
        payees.push(roles_.fixer);
        for (uint256 i; i < checkers_.length; ++i) {
            payees.push(checkers_[i]);
        }
        payees.push(pot_.treasury());
        payees.push(address(burn_));
    }

    function fund(uint256 c, uint256 amount) external {
        address client = clients[c % clients.length];
        amount = bound(amount, 0, 50_000e6);
        usdg.mint(client, amount);
        vm.startPrank(client);
        usdg.approve(address(pot), amount);
        pot.fund(amount);
        vm.stopPrank();
        funded += amount;
    }

    function withdraw(uint256 c, uint256 amount) external {
        address client = clients[c % clients.length];
        amount = bound(amount, 0, pot.unlockedBalance(client));
        vm.prank(client);
        pot.withdraw(amount);
        withdrawn += amount;
    }

    function setTable(uint256 c, uint128 crit, uint128 high, uint128 med) external {
        vm.prank(clients[c % clients.length]);
        pot.setTable(
            ISapperBountyPot.Table(
                uint128(bound(crit, 0, 20_000e6)), uint128(bound(high, 0, 8_000e6)), uint128(bound(med, 0, 2_000e6)), 0
            )
        );
    }

    function claim(uint256 c) external {
        uint256 k = c % clients.length;
        bytes32 id = keccak256(abi.encode("finding", ids.length));
        vm.prank(roles.keeper);
        gate.claim(id, targets[k], uint64(block.chainid), uint64(block.number), id, roles.breaker, roles.agentId, 0);
        ids.push(id);
        clientOf[id] = k;
    }

    function consensus(uint256 i, bool passed) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        SapperCheckerNet.Round memory r = net.round(id);
        if (r.finalized || block.timestamp > r.commitEnd) return;
        bytes32 result = passed ? keccak256("replayed") : bytes32(0);
        for (uint256 j; j < r.assigned.length; ++j) {
            address a = r.assigned[j];
            bytes32 commitment = net.commitmentOf(id, a, passed, result, id);
            vm.prank(a);
            net.commit(id, commitment);
        }
        for (uint256 j; j < r.assigned.length; ++j) {
            vm.prank(r.assigned[j]);
            net.reveal(id, passed, result, id);
        }
        net.finalize(id);
    }

    function rate(uint256 i, uint8 severity, uint8 cause) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        if (gate.status(id) != SapperSettlementGate.Status.Confirmed) return;
        bytes32 rootCause = keccak256(abi.encode("cause", cause % 3));
        uint256 k = clientOf[id];
        bytes32 key = keccak256(abi.encode(clients[k], targets[k], uint64(block.chainid), rootCause));
        bool duplicate = gate.rootCauseFinding(key) != 0;
        if (!duplicate && block.timestamp > pot.lockOf(id).expiry) return;

        address[] memory workers = new address[](2);
        workers[0] = roles.breaker;
        workers[1] = roles.fixer;
        uint16[] memory bps = new uint16[](2);
        bps[0] = 7_000;
        bps[1] = 3_000;
        vm.prank(roles.keeper);
        gate.rate(id, Severity(severity % 4), rootCause, workers, bps);
    }

    function dispute(uint256 i, uint8 severity) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        SapperSettlementGate.Finding memory f = gate.finding(id);
        if (f.status != SapperSettlementGate.Status.Review || block.timestamp >= f.reviewEndsAt) return;
        vm.prank(f.client);
        gate.dispute(id, Severity(severity % 4), bytes32(0));
    }

    function resolve(uint256 i, uint8 severity, bool reject) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        SapperSettlementGate.Finding memory f = gate.finding(id);
        if (f.status != SapperSettlementGate.Status.Disputed) return;
        Severity s = Severity(bound(severity, 0, uint8(f.severity)));
        if (!reject && s < f.severity && block.timestamp >= pot.lockOf(id).expiry) return;
        vm.prank(roles.resolver);
        gate.resolve(id, s, reject);
    }

    function settle(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        ISapperBountyPot.Lock memory l = pot.lockOf(id);
        if (!gate.settleable(id) || l.status != ISapperBountyPot.LockStatus.Locked || block.timestamp > l.expiry) {
            return;
        }
        pot.settle(id);
        settled += l.amount;
    }

    function reclaim(uint256 i) external {
        if (ids.length == 0) return;
        bytes32 id = ids[i % ids.length];
        ISapperBountyPot.Lock memory l = pot.lockOf(id);
        if (l.status != ISapperBountyPot.LockStatus.Locked || block.timestamp <= l.expiry) return;
        vm.prank(makeAddr("anyone"));
        pot.reclaimExpired(id);
    }

    function withdrawEarnings(uint256 p, uint256 amount) external {
        address payee = payees[p % payees.length];
        if (payee == address(burn)) {
            vm.prank(roles.owner);
            earningsWithdrawn += burn.collect(pot);
            return;
        }
        amount = bound(amount, 0, pot.earningsOf(payee));
        vm.prank(payee);
        pot.withdrawEarnings(amount);
        earningsWithdrawn += amount;
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 3 days));
    }

    function idCount() external view returns (uint256) {
        return ids.length;
    }

    function clientCount() external view returns (uint256) {
        return clients.length;
    }

    function payeeCount() external view returns (uint256) {
        return payees.length;
    }
}

contract SapperSettlementInvariantTest is Fixture {
    SettlementHandler handler;

    function setUp() public override {
        super.setUp();
        vm.prank(owner);
        net.setWindows(1 days, 1 days);

        address[] memory clients = new address[](3);
        address[] memory targets = new address[](3);
        clients[0] = client;
        targets[0] = target;
        for (uint256 i = 1; i < 3; ++i) {
            clients[i] = makeAddr(string.concat("client", vm.toString(i)));
            targets[i] = address(new OwnedTarget(clients[i]));
            vm.prank(clients[i]);
            scope.optIn(targets[i], chain, ROOT, disclosure, "");
        }

        handler = new SettlementHandler(
            usdg,
            pot,
            net,
            gate,
            burn,
            SettlementHandler.Roles(owner, keeper, resolver, breaker, fixer, agentId),
            clients,
            targets,
            checkers
        );
        targetContract(address(handler));
    }

    function invariant_balanceEqualsPotsPlusEarnings() public view {
        assertEq(usdg.balanceOf(address(pot)), _clientTotal() + _earningsTotal());
    }

    function invariant_flowsConserve() public view {
        assertEq(handler.funded() - handler.withdrawn() - handler.earningsWithdrawn(), usdg.balanceOf(address(pot)));
        assertEq(_earningsTotal() + handler.earningsWithdrawn(), handler.settled());
    }

    function invariant_lockedEqualsOpenLocks() public view {
        uint256 open;
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            ISapperBountyPot.Lock memory l = pot.lockOf(handler.ids(i));
            if (l.status == ISapperBountyPot.LockStatus.Locked) open += l.amount;
        }
        uint256 locked;
        for (uint256 i; i < handler.clientCount(); ++i) {
            locked += pot.lockedBalance(handler.clients(i));
        }
        assertEq(locked, open);
    }

    function invariant_lockMatchesFindingStatus() public view {
        uint256 n = handler.idCount();
        for (uint256 i; i < n; ++i) {
            bytes32 id = handler.ids(i);
            SapperSettlementGate.Status s = gate.status(id);
            ISapperBountyPot.Lock memory l = pot.lockOf(id);
            assertLe(l.amount, priceOf(l.terms, l.severity));
            if (s == SapperSettlementGate.Status.Rejected) {
                assertTrue(
                    l.status == ISapperBountyPot.LockStatus.Released || l.status == ISapperBountyPot.LockStatus.Refunded
                );
            } else if (s == SapperSettlementGate.Status.Settled) {
                assertEq(uint8(l.status), uint8(ISapperBountyPot.LockStatus.Settled));
            } else if (s == SapperSettlementGate.Status.Expired) {
                assertEq(uint8(l.status), uint8(ISapperBountyPot.LockStatus.Refunded));
            } else {
                assertEq(uint8(l.status), uint8(ISapperBountyPot.LockStatus.Locked));
            }
            if (s == SapperSettlementGate.Status.Review || s == SapperSettlementGate.Status.Disputed) {
                assertEq(uint8(l.severity), uint8(gate.finding(id).severity));
            }
        }
    }

    function _clientTotal() private view returns (uint256 total) {
        for (uint256 i; i < handler.clientCount(); ++i) {
            address c = handler.clients(i);
            total += pot.unlockedBalance(c) + pot.lockedBalance(c);
        }
    }

    function _earningsTotal() private view returns (uint256 total) {
        for (uint256 i; i < handler.payeeCount(); ++i) {
            total += pot.earningsOf(handler.payees(i));
        }
    }
}
