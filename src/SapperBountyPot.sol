// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISapperBountyPot, Severity, priceOf} from "./interfaces/ISapperBountyPot.sol";
import {ISapperSettlementGate} from "./interfaces/ISapperSettlementGate.sol";

/// @notice Every client's bounty pot and every payee's earnings in one contract.
/// @dev Invariant: token balance == sum over clients of (unlocked + locked) + sum over payees of
/// earnings. Settlement only moves locked balance into earnings, and tokens leave only through
/// withdraw and withdrawEarnings. Those two and reclaimExpired depend on nothing outside this
/// contract and cannot be paused.
contract SapperBountyPot is ISapperBountyPot, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant WORKERS_BPS = 8_000;
    uint256 public constant TREASURY_BPS = 1_000;
    uint256 public constant CHECKERS_BPS = 500;
    uint256 public constant BURN_BPS = 500;

    uint128 public constant DEFAULT_CRIT = 10_000e6;
    uint128 public constant DEFAULT_HIGH = 2_500e6;
    uint128 public constant DEFAULT_MED = 500e6;
    uint128 public constant DEFAULT_LOW = 0;

    struct Pot {
        uint256 unlocked;
        uint256 locked;
        Table table;
        bool customTable;
    }

    IERC20 public immutable token;
    ISapperSettlementGate public gate;
    address public treasury;
    address public burnBuffer;

    mapping(address => Pot) private _pots;
    mapping(bytes32 => Lock) private _locks;
    mapping(address => uint256) private _earnings;

    event Funded(address indexed client, uint256 amount);
    event Withdrawn(address indexed client, uint256 amount);
    event TableSet(address indexed client, uint128 crit, uint128 high, uint128 med, uint128 low);
    event FindingLocked(bytes32 indexed findingId, address indexed client, uint256 amount, uint64 expiry);
    event LockAdjusted(
        bytes32 indexed findingId, Severity severity, uint256 oldAmount, uint256 newAmount, uint64 expiry
    );
    event LockReleased(bytes32 indexed findingId, address indexed client, uint256 amount);
    event FindingSettled(
        bytes32 indexed findingId, uint256 paid, uint256 workers, uint256 treasury, uint256 checkers, uint256 burn
    );
    event FindingExpiredRefunded(bytes32 indexed findingId, address indexed client, uint256 amount);
    event EarningsCredited(address indexed payee, bytes32 indexed findingId, uint256 amount);
    event EarningsWithdrawn(address indexed payee, address indexed to, uint256 amount);
    event GateSet(address gate);
    event TreasurySet(address treasury);
    event BurnBufferSet(address burnBuffer);

    error ZeroAddress();
    error NotGate();
    error GateAlreadySet();
    error InsufficientUnlocked(uint256 unlocked, uint256 requested);
    error LockExists(bytes32 findingId);
    error NotLocked(bytes32 findingId);
    error BadExpiry();
    error InsufficientEarnings(uint256 earned, uint256 requested);
    error NotSettleable(bytes32 findingId);
    error LockExpired(bytes32 findingId);
    error NotExpired(bytes32 findingId);
    error BadSplit();

    modifier onlyGate() {
        if (msg.sender != address(gate)) revert NotGate();
        _;
    }

    constructor(address token_, address treasury_, address burnBuffer_, address owner_) Ownable(owner_) {
        if (token_ == address(0) || treasury_ == address(0) || burnBuffer_ == address(0)) revert ZeroAddress();
        token = IERC20(token_);
        treasury = treasury_;
        burnBuffer = burnBuffer_;
        emit TreasurySet(treasury_);
        emit BurnBufferSet(burnBuffer_);
    }

    function fund(uint256 amount) external nonReentrant {
        _fund(amount);
    }

    function fundWithPermit(uint256 amount, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external nonReentrant {
        // A front-run permit spends the nonce but leaves the allowance, so a failed call is not fatal.
        try IERC20Permit(address(token)).permit(msg.sender, address(this), amount, deadline, v, r, s) {} catch {}
        _fund(amount);
    }

    function setTable(Table calldata t) external {
        Pot storage p = _pots[msg.sender];
        p.table = t;
        p.customTable = true;
        emit TableSet(msg.sender, t.crit, t.high, t.med, t.low);
    }

    function withdraw(uint256 amount) external nonReentrant {
        Pot storage p = _pots[msg.sender];
        if (amount > p.unlocked) revert InsufficientUnlocked(p.unlocked, amount);
        p.unlocked -= amount;
        token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    /// @notice Provisional lock taken at claim: the client's Critical price against the table in force
    /// now, capped by what is unlocked. The table is frozen into the lock for every later price.
    function lockForFinding(bytes32 findingId, address client, uint64 expiry)
        external
        onlyGate
        returns (uint256 amount)
    {
        if (_locks[findingId].status != LockStatus.None) revert LockExists(findingId);
        if (expiry <= block.timestamp) revert BadExpiry();
        Pot storage p = _pots[client];
        Table memory terms = _tableOf(p);
        amount = terms.crit < p.unlocked ? terms.crit : p.unlocked;
        p.unlocked -= amount;
        p.locked += amount;
        _locks[findingId] = Lock({
            client: client,
            expiry: expiry,
            severity: Severity.Critical,
            status: LockStatus.Locked,
            amount: uint128(amount),
            terms: terms
        });
        emit FindingLocked(findingId, client, amount, expiry);
    }

    /// @notice Prices a lock at `severity` against its frozen terms and moves its expiry. The amount can
    /// only fall: it becomes min(price, current amount) and the difference returns to the client. An
    /// expired lock already belongs back to the client and cannot be extended.
    function adjustLock(bytes32 findingId, Severity severity, uint64 expiry)
        external
        onlyGate
        returns (uint256 amount)
    {
        Lock storage l = _locks[findingId];
        if (l.status != LockStatus.Locked) revert NotLocked(findingId);
        if (block.timestamp > l.expiry) revert LockExpired(findingId);
        if (expiry <= block.timestamp) revert BadExpiry();
        uint256 old = l.amount;
        uint256 price = priceOf(l.terms, severity);
        amount = price < old ? price : old;
        _unlock(l.client, old - amount);
        l.amount = uint128(amount);
        l.severity = severity;
        l.expiry = expiry;
        emit LockAdjusted(findingId, severity, old, amount, expiry);
    }

    /// @notice Returns the whole lock to the client. A lock that reclaimExpired already refunded
    /// releases nothing rather than reverting, so a late rejection can always complete.
    function releaseLock(bytes32 findingId) external onlyGate returns (uint256 amount) {
        Lock storage l = _locks[findingId];
        if (l.status == LockStatus.Refunded) return 0;
        if (l.status != LockStatus.Locked) revert NotLocked(findingId);
        l.status = LockStatus.Released;
        amount = l.amount;
        _unlock(l.client, amount);
        emit LockReleased(findingId, l.client, amount);
    }

    function settle(bytes32 findingId) external nonReentrant {
        Lock storage l = _locks[findingId];
        if (l.status != LockStatus.Locked) revert NotLocked(findingId);
        if (block.timestamp > l.expiry) revert LockExpired(findingId);
        if (!gate.settleable(findingId)) revert NotSettleable(findingId);
        (address[] memory workers, uint16[] memory workerBps, address[] memory checkers) = gate.payees(findingId);
        if (workers.length == 0 || workers.length != workerBps.length) revert BadSplit();

        uint256 amount = l.amount;
        l.status = LockStatus.Settled;
        _pots[l.client].locked -= amount;

        // Credits only: no payee is called here, so a frozen or rejecting payee cannot block the rest.
        uint256 toWorkers;
        for (uint256 i; i < workers.length; ++i) {
            uint256 share = amount * WORKERS_BPS * workerBps[i] / (BPS * BPS);
            toWorkers += share;
            _credit(workers[i], findingId, share);
        }

        uint256 toCheckers;
        if (checkers.length != 0) {
            uint256 each = amount * CHECKERS_BPS / (BPS * checkers.length);
            for (uint256 i; i < checkers.length; ++i) {
                _credit(checkers[i], findingId, each);
            }
            toCheckers = each * checkers.length;
        }

        uint256 toBurn = amount * BURN_BPS / BPS;
        _credit(burnBuffer, findingId, toBurn);

        // Treasury takes its 10% plus every rounding remainder, so credits sum to the lock exactly.
        uint256 toTreasury = amount - toWorkers - toCheckers - toBurn;
        _credit(treasury, findingId, toTreasury);

        emit FindingSettled(findingId, amount, toWorkers, toTreasury, toCheckers, toBurn);
        gate.onSettled(findingId);
    }

    function reclaimExpired(bytes32 findingId) external nonReentrant {
        Lock storage l = _locks[findingId];
        if (l.status != LockStatus.Locked) revert NotLocked(findingId);
        if (block.timestamp <= l.expiry) revert NotExpired(findingId);
        l.status = LockStatus.Refunded;
        uint256 amount = l.amount;
        _unlock(l.client, amount);
        emit FindingExpiredRefunded(findingId, l.client, amount);
        // The refund is already booked; a failing gate cannot undo or block it.
        try gate.onExpired(findingId) {} catch {}
    }

    function withdrawEarnings(uint256 amount) external nonReentrant {
        _withdrawEarnings(msg.sender, amount);
    }

    function setGate(address gate_) external onlyOwner {
        if (gate_ == address(0)) revert ZeroAddress();
        if (address(gate) != address(0)) revert GateAlreadySet();
        gate = ISapperSettlementGate(gate_);
        emit GateSet(gate_);
    }

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setBurnBuffer(address burnBuffer_) external onlyOwner {
        if (burnBuffer_ == address(0)) revert ZeroAddress();
        burnBuffer = burnBuffer_;
        emit BurnBufferSet(burnBuffer_);
    }

    function unlockedBalance(address client) external view returns (uint256) {
        return _pots[client].unlocked;
    }

    function lockedBalance(address client) external view returns (uint256) {
        return _pots[client].locked;
    }

    function earningsOf(address payee) external view returns (uint256) {
        return _earnings[payee];
    }

    function lockOf(bytes32 findingId) external view returns (Lock memory) {
        return _locks[findingId];
    }

    function table(address client) external view returns (Table memory) {
        return _tableOf(_pots[client]);
    }

    function _fund(uint256 amount) private {
        token.safeTransferFrom(msg.sender, address(this), amount);
        _pots[msg.sender].unlocked += amount;
        emit Funded(msg.sender, amount);
    }

    function _unlock(address client, uint256 amount) private {
        Pot storage p = _pots[client];
        p.locked -= amount;
        p.unlocked += amount;
    }

    function _credit(address payee, bytes32 findingId, uint256 amount) private {
        if (amount == 0) return;
        _earnings[payee] += amount;
        emit EarningsCredited(payee, findingId, amount);
    }

    function _withdrawEarnings(address to, uint256 amount) private {
        uint256 earned = _earnings[msg.sender];
        if (amount > earned) revert InsufficientEarnings(earned, amount);
        _earnings[msg.sender] = earned - amount;
        token.safeTransfer(to, amount);
        emit EarningsWithdrawn(msg.sender, to, amount);
    }

    function _tableOf(Pot storage p) private view returns (Table memory) {
        if (p.customTable) return p.table;
        return Table({crit: DEFAULT_CRIT, high: DEFAULT_HIGH, med: DEFAULT_MED, low: DEFAULT_LOW});
    }
}
