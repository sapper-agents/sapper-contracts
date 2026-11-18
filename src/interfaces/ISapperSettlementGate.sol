// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISapperSettlementGate {
    function settleable(bytes32 findingId) external view returns (bool);
    function payees(bytes32 findingId)
        external
        view
        returns (address[] memory workers, uint16[] memory workerBps, address[] memory checkers);
    function onCheckerConsensus(bytes32 findingId, bool confirmed, bytes32 resultHash) external;
    function onSettled(bytes32 findingId) external;
    function onExpired(bytes32 findingId) external;
}
