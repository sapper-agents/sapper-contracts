// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISapperScope {
    struct Entry {
        address target;
        uint64 chainId;
        bytes32 invariantsRoot;
        address disclosureAddr;
        address client;
        bool active;
        uint64 optedInAt;
    }

    function isInScope(address target, uint64 chainId) external view returns (bool);
    function entry(address target, uint64 chainId) external view returns (Entry memory);
}
