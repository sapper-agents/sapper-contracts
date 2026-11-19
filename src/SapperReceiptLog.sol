// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice One Merkle root of hash-chained step receipts per job, written once.
contract SapperReceiptLog is Ownable2Step {
    struct Anchor {
        bytes32 root;
        uint32 steps;
        uint64 anchoredAt;
    }

    address public keeper;

    mapping(bytes32 => Anchor) private _anchors;

    event ReceiptRootAnchored(bytes32 indexed jobId, bytes32 merkleRoot, uint32 steps);
    event KeeperSet(address keeper);

    error NotKeeper();
    error ZeroAddress();
    error ZeroRoot();
    error AlreadyAnchored(bytes32 jobId);

    constructor(address owner_, address keeper_) Ownable(owner_) {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function anchor(bytes32 jobId, bytes32 merkleRoot, uint32 steps) external {
        if (msg.sender != keeper) revert NotKeeper();
        if (merkleRoot == 0) revert ZeroRoot();
        Anchor storage a = _anchors[jobId];
        if (a.root != 0) revert AlreadyAnchored(jobId);
        a.root = merkleRoot;
        a.steps = steps;
        a.anchoredAt = uint64(block.timestamp);
        emit ReceiptRootAnchored(jobId, merkleRoot, steps);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function anchorOf(bytes32 jobId) external view returns (Anchor memory) {
        return _anchors[jobId];
    }
}
