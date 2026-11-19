// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

enum Severity {
    Low,
    Medium,
    High,
    Critical
}

interface ISapperBountyPot {
    enum LockStatus {
        None,
        Locked,
        Settled,
        Refunded,
        Released
    }

    struct Table {
        uint128 crit;
        uint128 high;
        uint128 med;
        uint128 low;
    }

    /// @dev `terms` is the client's table at claim time; every later price is read from it, never the live table.
    /// `severity` is Critical while the lock is provisional and the rated severity afterwards.
    struct Lock {
        address client;
        uint64 expiry;
        Severity severity;
        LockStatus status;
        uint128 amount;
        Table terms;
    }

    function lockForFinding(bytes32 findingId, address client, uint64 expiry) external returns (uint256 locked);
    function adjustLock(bytes32 findingId, Severity severity, uint64 expiry) external returns (uint256 locked);
    function releaseLock(bytes32 findingId) external returns (uint256 released);
    function withdrawEarnings(uint256 amount) external;
    function earningsOf(address payee) external view returns (uint256);
    function lockOf(bytes32 findingId) external view returns (Lock memory);
    function table(address client) external view returns (Table memory);
}

function priceOf(ISapperBountyPot.Table memory t, Severity s) pure returns (uint256) {
    if (s == Severity.Critical) return t.crit;
    if (s == Severity.High) return t.high;
    if (s == Severity.Medium) return t.med;
    return t.low;
}
