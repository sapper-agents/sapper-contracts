// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SapperScope} from "../src/SapperScope.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {SapperBurnBuffer} from "../src/SapperBurnBuffer.sol";
import {SapperCheckerNet} from "../src/SapperCheckerNet.sol";
import {SapperSettlementGate} from "../src/SapperSettlementGate.sol";
import {SapperValidationRegistry} from "../src/SapperValidationRegistry.sol";
import {ISapperBountyPot, Severity} from "../src/interfaces/ISapperBountyPot.sol";
import {MockUSDG, MockIdentity, OwnedTarget} from "./mocks/Mocks.sol";

abstract contract Fixture is Test {
    MockUSDG usdg;
    MockIdentity identity;
    SapperScope scope;
    SapperBurnBuffer burn;
    SapperBountyPot pot;
    SapperCheckerNet net;
    SapperValidationRegistry validation;
    SapperSettlementGate gate;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address resolver = makeAddr("resolver");
    address treasury = makeAddr("treasury");
    address client = makeAddr("client");
    address disclosure = makeAddr("disclosure");
    address breaker = makeAddr("breakerOperator");
    address fixer = makeAddr("fixerOperator");

    address target;
    uint64 chain;
    uint256 agentId;
    address[] checkers;

    uint256 constant MIN_STAKE = 100e6;
    uint256 constant CHECKER_STAKE = 1_000e6;
    bytes32 constant ROOT = keccak256("invariants");
    bytes32 constant RESULT = keccak256("replay result");
    bytes32 constant ROOT_CAUSE = keccak256("unchecked price");

    function setUp() public virtual {
        chain = uint64(block.chainid);
        usdg = new MockUSDG();
        identity = new MockIdentity();

        vm.startPrank(owner);
        scope = new SapperScope(owner, address(0));
        burn = new SapperBurnBuffer(owner);
        pot = new SapperBountyPot(address(usdg), treasury, address(burn), owner);
        net = new SapperCheckerNet(address(usdg), treasury, MIN_STAKE, owner);
        validation = new SapperValidationRegistry(address(identity));
        gate = new SapperSettlementGate(
            address(scope), address(pot), address(net), address(validation), keeper, guardian, resolver, owner
        );
        pot.setGate(address(gate));
        net.setGate(address(gate));
        vm.stopPrank();

        target = address(new OwnedTarget(client));
        vm.prank(client);
        scope.optIn(target, chain, ROOT, disclosure, "");

        vm.startPrank(breaker);
        agentId = identity.register();
        identity.setApprovalForAll(address(gate), true);
        vm.stopPrank();

        for (uint256 i; i < 3; ++i) {
            checkers.push(_stake(string.concat("checker", vm.toString(i)), CHECKER_STAKE));
        }
    }

    function _stake(string memory label, uint256 amount) internal returns (address c) {
        c = makeAddr(label);
        _stakeAs(c, amount);
    }

    function _stakeAs(address c, uint256 amount) internal {
        usdg.mint(c, amount);
        vm.startPrank(c);
        usdg.approve(address(net), amount);
        net.stake(amount);
        vm.stopPrank();
    }

    function _fund(address who, uint256 amount) internal {
        usdg.mint(who, amount);
        vm.startPrank(who);
        usdg.approve(address(pot), amount);
        pot.fund(amount);
        vm.stopPrank();
    }

    function _claim(bytes32 id) internal returns (address[] memory) {
        return _claimTier(id, target, 0);
    }

    function _claimTier(bytes32 id, address on, uint8 tier) internal returns (address[] memory) {
        vm.prank(keeper);
        gate.claim(id, on, chain, uint64(block.number), keccak256(abi.encode("bundle", id)), breaker, agentId, tier);
        return net.round(id).assigned;
    }

    function _salt(bytes32 id, address c) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", id, c));
    }

    function _commit(bytes32 id, address c, bool passed, bytes32 result) internal {
        bytes32 commitment = net.commitmentOf(id, c, passed, result, _salt(id, c));
        vm.prank(c);
        net.commit(id, commitment);
    }

    function _reveal(bytes32 id, address c, bool passed, bytes32 result) internal {
        vm.prank(c);
        net.reveal(id, passed, result, _salt(id, c));
    }

    function _replay(bytes32 id, bool passed, bytes32 result) internal {
        address[] memory assigned = net.round(id).assigned;
        for (uint256 i; i < assigned.length; ++i) {
            _commit(id, assigned[i], passed, result);
        }
        for (uint256 i; i < assigned.length; ++i) {
            _reveal(id, assigned[i], passed, result);
        }
        net.finalize(id);
    }

    function _confirm(bytes32 id) internal {
        _claim(id);
        _replay(id, true, RESULT);
    }

    function _split() internal view returns (address[] memory workers, uint16[] memory bps) {
        workers = new address[](2);
        workers[0] = breaker;
        workers[1] = fixer;
        bps = new uint16[](2);
        bps[0] = 7_000;
        bps[1] = 3_000;
    }

    function _rate(bytes32 id, Severity severity, bytes32 rootCause) internal {
        (address[] memory workers, uint16[] memory bps) = _split();
        vm.prank(keeper);
        gate.rate(id, severity, rootCause, workers, bps);
    }

    function _status(bytes32 id) internal view returns (SapperSettlementGate.Status) {
        return gate.status(id);
    }

    function _table(uint128 crit, uint128 high, uint128 med, uint128 low) internal {
        vm.prank(client);
        pot.setTable(ISapperBountyPot.Table(crit, high, med, low));
    }
}
