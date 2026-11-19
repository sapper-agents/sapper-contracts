// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISapperCheckerNet} from "./interfaces/ISapperCheckerNet.sol";
import {ISapperSettlementGate} from "./interfaces/ISapperSettlementGate.sol";

/// @notice Staked checkers replay a finding and vote by commit/reveal. A strict majority of the
/// assigned checkers on the same (passed, resultHash) decides; everyone else assigned is slashed.
contract SapperCheckerNet is ISapperCheckerNet, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant SLASH_BPS = 1_000;
    uint8 public constant MAX_STRIKES = 3;
    uint8 public constant MIN_ROUND = 3;
    uint8 public constant MAX_ROUND = 5;
    uint64 public constant MAX_COOLDOWN = 30 days;
    uint64 public constant MAX_WINDOW = 1 days;

    struct Checker {
        uint256 stake;
        uint256 pending;
        uint64 unlockAt;
        uint32 openRounds;
        uint8 strikes;
        bool removed;
    }

    struct Vote {
        bool assigned;
        bool revealed;
        bool passed;
        bytes32 commitment;
        bytes32 resultHash;
    }

    struct Round {
        uint64 commitEnd;
        uint64 revealEnd;
        uint8 committed;
        uint8 revealed;
        bool finalized;
        bool confirmed;
        bytes32 resultHash;
        address[] assigned;
        address[] consensus;
    }

    IERC20 public immutable stakeToken;
    ISapperSettlementGate public gate;
    address public treasury;
    uint256 public minStake;
    uint64 public cooldown = 7 days;
    uint64 public commitWindow = 5 minutes;
    uint64 public revealWindow = 30 minutes;

    address[] private _pool;
    mapping(address => uint256) private _poolSlot;
    mapping(address => Checker) private _checkers;
    mapping(bytes32 => Round) private _rounds;
    mapping(bytes32 => mapping(address => Vote)) private _votes;

    event Staked(address indexed checker, uint256 amount, uint256 total);
    event UnstakeRequested(address indexed checker, uint256 amount, uint64 unlockAt);
    event StakeWithdrawn(address indexed checker, uint256 amount);
    event RoundOpened(bytes32 indexed findingId, address[] checkers, uint64 commitEnd, uint64 revealEnd);
    event Committed(bytes32 indexed findingId, address indexed checker, bytes32 commitment);
    event Revealed(bytes32 indexed findingId, address indexed checker, bool passed, bytes32 resultHash);
    event RoundFinalized(bytes32 indexed findingId, bool confirmed, bytes32 resultHash, address[] consensus);
    event Slashed(address indexed checker, bytes32 indexed findingId, uint256 amount, uint8 strikes);
    event CheckerRemoved(address indexed checker);
    event GateSet(address gate);
    event TreasurySet(address treasury);
    event MinStakeSet(uint256 minStake);
    event CooldownSet(uint64 cooldown);
    event WindowsSet(uint64 commitWindow, uint64 revealWindow);

    error ZeroAddress();
    error ZeroAmount();
    error NotGate();
    error GateAlreadySet();
    error Removed();
    error ExceedsFreeStake(uint256 free, uint256 requested);
    error NothingPending();
    error CooldownActive(uint64 unlockAt);
    error AssignedToOpenRound(uint32 openRounds);
    error BadRoundSize(uint8 n);
    error RoundExists(bytes32 findingId);
    error NoRound(bytes32 findingId);
    error NotEnoughCheckers(uint256 eligible, uint256 needed);
    error NotAssigned();
    error CommitClosed();
    error AlreadyCommitted();
    error EmptyCommitment();
    error NotCommitted();
    error AlreadyRevealed();
    error RevealNotOpen();
    error RevealClosed();
    error CommitmentMismatch();
    error RoundStillOpen();
    error AlreadyFinalized();
    error BadConfig();

    modifier onlyGate() {
        if (msg.sender != address(gate)) revert NotGate();
        _;
    }

    constructor(address stakeToken_, address treasury_, uint256 minStake_, address owner_) Ownable(owner_) {
        if (stakeToken_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        if (minStake_ == 0) revert BadConfig();
        stakeToken = IERC20(stakeToken_);
        treasury = treasury_;
        minStake = minStake_;
        emit TreasurySet(treasury_);
        emit MinStakeSet(minStake_);
    }

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Checker storage c = _checkers[msg.sender];
        if (c.removed) revert Removed();
        stakeToken.safeTransferFrom(msg.sender, address(this), amount);
        c.stake += amount;
        if (_poolSlot[msg.sender] == 0) {
            _pool.push(msg.sender);
            _poolSlot[msg.sender] = _pool.length;
        }
        emit Staked(msg.sender, amount, c.stake);
    }

    function requestUnstake(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        Checker storage c = _checkers[msg.sender];
        uint256 free = c.stake - c.pending;
        if (amount > free) revert ExceedsFreeStake(free, amount);
        c.pending += amount;
        c.unlockAt = uint64(block.timestamp) + cooldown;
        emit UnstakeRequested(msg.sender, amount, c.unlockAt);
    }

    function withdrawStake() external nonReentrant {
        Checker storage c = _checkers[msg.sender];
        uint256 amount = c.pending;
        if (amount == 0) revert NothingPending();
        if (block.timestamp < c.unlockAt) revert CooldownActive(c.unlockAt);
        if (c.openRounds != 0) revert AssignedToOpenRound(c.openRounds);
        c.pending = 0;
        c.unlockAt = 0;
        c.stake -= amount;
        if (c.stake == 0) _leave(msg.sender);
        stakeToken.safeTransfer(msg.sender, amount);
        emit StakeWithdrawn(msg.sender, amount);
    }

    /// @dev Seed is keccak(findingId, blockhash(n-1)): prevrandao is constant on Arbitrum Orbit chains.
    /// The sequencer and the keeper choosing findingId can bias the draw; accepted while Sapper
    /// operates every checker. Commit-based selection replaces this when outside checkers join.
    function openRound(bytes32 findingId, uint8 n, address[] calldata exclude)
        external
        onlyGate
        returns (address[] memory drawn)
    {
        if (n < MIN_ROUND || n > MAX_ROUND) revert BadRoundSize(n);
        Round storage r = _rounds[findingId];
        if (r.assigned.length != 0) revert RoundExists(findingId);

        address[] memory pool = _pool;
        uint256 left = pool.length;
        bytes32 seed = keccak256(abi.encode(findingId, blockhash(block.number - 1)));
        drawn = new address[](n);
        uint256 picked;
        for (uint256 i; picked < n && left != 0; ++i) {
            uint256 j = uint256(keccak256(abi.encode(seed, i))) % left;
            address a = pool[j];
            pool[j] = pool[--left];
            if (!_eligible(_checkers[a]) || _listed(exclude, a)) continue;
            drawn[picked++] = a;
        }
        if (picked < n) revert NotEnoughCheckers(picked, n);

        for (uint256 i; i < n; ++i) {
            r.assigned.push(drawn[i]);
            _votes[findingId][drawn[i]].assigned = true;
            ++_checkers[drawn[i]].openRounds;
        }
        r.commitEnd = uint64(block.timestamp) + commitWindow;
        r.revealEnd = r.commitEnd + revealWindow;
        emit RoundOpened(findingId, drawn, r.commitEnd, r.revealEnd);
    }

    function commit(bytes32 findingId, bytes32 commitment) external {
        Round storage r = _rounds[findingId];
        Vote storage v = _votes[findingId][msg.sender];
        if (!v.assigned) revert NotAssigned();
        if (block.timestamp > r.commitEnd) revert CommitClosed();
        if (v.commitment != 0) revert AlreadyCommitted();
        if (commitment == 0) revert EmptyCommitment();
        v.commitment = commitment;
        ++r.committed;
        emit Committed(findingId, msg.sender, commitment);
    }

    /// @dev Reveals open when the commit window closes, or as soon as every assigned checker has committed.
    function reveal(bytes32 findingId, bool passed, bytes32 resultHash, bytes32 salt) external {
        Round storage r = _rounds[findingId];
        Vote storage v = _votes[findingId][msg.sender];
        if (v.commitment == 0) revert NotCommitted();
        if (v.revealed) revert AlreadyRevealed();
        if (block.timestamp <= r.commitEnd && r.committed < r.assigned.length) revert RevealNotOpen();
        if (block.timestamp > r.revealEnd) revert RevealClosed();
        if (commitmentOf(findingId, msg.sender, passed, resultHash, salt) != v.commitment) revert CommitmentMismatch();
        v.revealed = true;
        v.passed = passed;
        v.resultHash = resultHash;
        ++r.revealed;
        emit Revealed(findingId, msg.sender, passed, resultHash);
    }

    function finalize(bytes32 findingId) external nonReentrant {
        Round storage r = _rounds[findingId];
        uint256 n = r.assigned.length;
        if (n == 0) revert NoRound(findingId);
        if (r.finalized) revert AlreadyFinalized();
        if (block.timestamp <= r.revealEnd && r.revealed < n) revert RoundStillOpen();
        r.finalized = true;

        (bool found, bool passed, bytes32 resultHash) = _majority(findingId, r.assigned);
        bool confirmed = found && passed;
        r.confirmed = confirmed;
        r.resultHash = resultHash;

        uint256 slashed;
        for (uint256 i; i < n; ++i) {
            address a = r.assigned[i];
            Checker storage c = _checkers[a];
            --c.openRounds;
            Vote storage v = _votes[findingId][a];
            if (found && v.revealed && v.passed == passed && v.resultHash == resultHash) {
                r.consensus.push(a);
            } else if (found || !v.revealed) {
                slashed += _slash(a, c, findingId);
            }
        }
        if (slashed != 0) stakeToken.safeTransfer(treasury, slashed);

        emit RoundFinalized(findingId, confirmed, resultHash, r.consensus);
        gate.onCheckerConsensus(findingId, confirmed, resultHash);
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

    function setMinStake(uint256 minStake_) external onlyOwner {
        if (minStake_ == 0) revert BadConfig();
        minStake = minStake_;
        emit MinStakeSet(minStake_);
    }

    function setCooldown(uint64 cooldown_) external onlyOwner {
        if (cooldown_ > MAX_COOLDOWN) revert BadConfig();
        cooldown = cooldown_;
        emit CooldownSet(cooldown_);
    }

    function setWindows(uint64 commitWindow_, uint64 revealWindow_) external onlyOwner {
        if (commitWindow_ == 0 || revealWindow_ == 0 || commitWindow_ > MAX_WINDOW || revealWindow_ > MAX_WINDOW) {
            revert BadConfig();
        }
        commitWindow = commitWindow_;
        revealWindow = revealWindow_;
        emit WindowsSet(commitWindow_, revealWindow_);
    }

    function consensusCheckers(bytes32 findingId) external view returns (address[] memory) {
        return _rounds[findingId].consensus;
    }

    function round(bytes32 findingId) external view returns (Round memory) {
        return _rounds[findingId];
    }

    function voteOf(bytes32 findingId, address checker) external view returns (Vote memory) {
        return _votes[findingId][checker];
    }

    function checkerOf(address account) external view returns (Checker memory) {
        return _checkers[account];
    }

    function isEligible(address account) external view returns (bool) {
        return _poolSlot[account] != 0 && _eligible(_checkers[account]);
    }

    function poolSize() external view returns (uint256) {
        return _pool.length;
    }

    function commitmentOf(bytes32 findingId, address checker, bool passed, bytes32 resultHash, bytes32 salt)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(findingId, checker, passed, resultHash, salt));
    }

    function _majority(bytes32 findingId, address[] storage assigned)
        private
        view
        returns (bool found, bool passed, bytes32 resultHash)
    {
        uint256 n = assigned.length;
        for (uint256 i; i < n; ++i) {
            Vote storage a = _votes[findingId][assigned[i]];
            if (!a.revealed) continue;
            uint256 count;
            for (uint256 j; j < n; ++j) {
                Vote storage b = _votes[findingId][assigned[j]];
                if (b.revealed && b.passed == a.passed && b.resultHash == a.resultHash) ++count;
            }
            if (count * 2 > n) return (true, a.passed, a.resultHash);
        }
    }

    function _slash(address account, Checker storage c, bytes32 findingId) private returns (uint256 amount) {
        amount = c.stake * SLASH_BPS / BPS;
        c.stake -= amount;
        if (c.pending > c.stake) c.pending = c.stake;
        ++c.strikes;
        emit Slashed(account, findingId, amount, c.strikes);
        if (c.strikes >= MAX_STRIKES && !c.removed) {
            c.removed = true;
            _leave(account);
            emit CheckerRemoved(account);
        }
    }

    function _eligible(Checker storage c) private view returns (bool) {
        return !c.removed && c.stake - c.pending >= minStake;
    }

    function _leave(address account) private {
        uint256 slot = _poolSlot[account];
        if (slot == 0) return;
        address last = _pool[_pool.length - 1];
        _pool[slot - 1] = last;
        _poolSlot[last] = slot;
        _pool.pop();
        delete _poolSlot[account];
    }

    function _listed(address[] calldata list, address a) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}
