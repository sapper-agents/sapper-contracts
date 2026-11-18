// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ISapperSettlementGate} from "../../src/interfaces/ISapperSettlementGate.sol";
import {ISapperBountyPot, Severity} from "../../src/interfaces/ISapperBountyPot.sol";
import {ISapperCheckerNet} from "../../src/interfaces/ISapperCheckerNet.sol";

contract MockGate is ISapperSettlementGate {
    struct Payees {
        address[] workers;
        uint16[] bps;
        address[] checkers;
    }

    ISapperBountyPot public pot;
    ISapperCheckerNet public checkerNet;
    bool public revertOnExpired;

    mapping(bytes32 => bool) public isSettleable;
    mapping(bytes32 => uint256) public settledCalls;
    mapping(bytes32 => uint256) public expiredCalls;
    mapping(bytes32 => uint256) public consensusCalls;
    mapping(bytes32 => bool) public confirmedOf;
    mapping(bytes32 => bytes32) public resultOf;
    mapping(bytes32 => Payees) private _payees;

    function setPot(ISapperBountyPot pot_) external {
        pot = pot_;
    }

    function setCheckerNet(ISapperCheckerNet net) external {
        checkerNet = net;
    }

    function lock(bytes32 id, address client, uint64 expiry) external returns (uint256) {
        return pot.lockForFinding(id, client, expiry);
    }

    function adjust(bytes32 id, Severity s, uint64 expiry) external returns (uint256) {
        return pot.adjustLock(id, s, expiry);
    }

    function release(bytes32 id) external returns (uint256) {
        return pot.releaseLock(id);
    }

    function open(bytes32 id, uint8 n, address[] calldata exclude) external returns (address[] memory) {
        return checkerNet.openRound(id, n, exclude);
    }

    function setSettleable(bytes32 id, bool v) external {
        isSettleable[id] = v;
    }

    function setRevertOnExpired(bool v) external {
        revertOnExpired = v;
    }

    function setPayees(bytes32 id, address[] calldata workers, uint16[] calldata bps, address[] calldata checkers)
        external
    {
        _payees[id] = Payees(workers, bps, checkers);
    }

    function settleable(bytes32 id) external view returns (bool) {
        return isSettleable[id];
    }

    function payees(bytes32 id) external view returns (address[] memory, uint16[] memory, address[] memory) {
        Payees storage p = _payees[id];
        return (p.workers, p.bps, p.checkers);
    }

    function onCheckerConsensus(bytes32 id, bool confirmed, bytes32 resultHash) external {
        consensusCalls[id]++;
        confirmedOf[id] = confirmed;
        resultOf[id] = resultHash;
    }

    function onSettled(bytes32 id) external {
        settledCalls[id]++;
    }

    function onExpired(bytes32 id) external {
        if (revertOnExpired) revert("gate down");
        expiredCalls[id]++;
    }
}
