// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISapperCheckerNet {
    function openRound(bytes32 findingId, uint8 n, address[] calldata exclude) external returns (address[] memory drawn);
    function consensusCheckers(bytes32 findingId) external view returns (address[] memory);
}
