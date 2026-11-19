// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ISapperScope} from "./interfaces/ISapperScope.sol";
import {ISapperBountyPot, Severity} from "./interfaces/ISapperBountyPot.sol";
import {ISapperCheckerNet} from "./interfaces/ISapperCheckerNet.sol";
import {ISapperSettlementGate} from "./interfaces/ISapperSettlementGate.sol";
import {IERC8004Validation} from "./interfaces/IERC8004.sol";

/// @notice Finding lifecycle and the only writer into the bounty pot and the checker net.
/// @dev Claimed -> Confirmed | Rejected (checker consensus) -> Review | Rejected (rate, duplicate)
/// -> Disputed -> Review | Rejected (resolve) -> Settled (pot). Any open status ends Expired when
/// the pot refunds an expired lock. A claim locks the client's Critical price provisionally until
/// `ratingWindow` ends; rejection releases it and rating can only lower it. The guardian can pause
/// new claims only; nothing here can stop a client's withdrawal or an expiry refund.
contract SapperSettlementGate is ISapperSettlementGate, Ownable2Step {
    enum Status {
        None,
        Claimed,
        Confirmed,
        Review,
        Disputed,
        Settled,
        Rejected,
        Expired
    }

    struct Finding {
        address target;
        uint64 chainId;
        address client;
        uint64 forkBlock;
        address breakerOperator;
        Status status;
        Severity severity;
        uint64 reviewEndsAt;
        uint256 agentId;
        bytes32 bundleHash;
        bytes32 resultHash;
        bytes32 rootCauseHash;
        address[] workers;
        uint16[] workerBps;
    }

    struct Dispute {
        Severity proposedSeverity;
        bytes32 duplicateOf;
    }

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_WORKERS = 16;
    uint8 public constant BASE_CHECKERS = 3;
    uint8 public constant MAX_TIER = 2;
    uint8 public constant CONFIRMED_RESPONSE = 100;
    uint64 public constant MAX_RATING_WINDOW = 30 days;
    uint64 public constant MAX_REVIEW_WINDOW = 30 days;
    uint64 public constant MAX_SETTLE_GRACE = 60 days;

    ISapperScope public immutable scope;
    ISapperBountyPot public immutable pot;
    ISapperCheckerNet public immutable checkerNet;
    IERC8004Validation public immutable validation;

    address public keeper;
    address public guardian;
    address public disputeResolver;
    bool public claimsPaused;
    uint64 public ratingWindow = 7 days;
    uint64 public reviewWindow = 72 hours;
    uint64 public settleGrace = 14 days;
    string public validationBaseURI;

    /// @dev keccak(client, target, chainId, rootCauseHash) => the finding that first confirmed it.
    mapping(bytes32 => bytes32) public rootCauseFinding;

    /// @dev findingId => ERC-8004 request hash posted on settle (zero if none was posted).
    mapping(bytes32 => bytes32) public validationRequestOf;

    mapping(bytes32 => Finding) private _findings;
    mapping(bytes32 => Dispute) private _disputes;

    event FindingClaimed(
        bytes32 indexed findingId,
        address indexed target,
        address indexed client,
        uint64 chainId,
        uint64 forkBlock,
        bytes32 bundleHash,
        address breakerOperator,
        uint256 agentId
    );
    event CheckerConsensus(bytes32 indexed findingId, bool confirmed, bytes32 resultHash);
    event FindingRated(
        bytes32 indexed findingId, Severity severity, bytes32 rootCauseHash, uint256 locked, uint64 reviewEndsAt
    );
    event DuplicateRejected(bytes32 indexed findingId, bytes32 indexed original, bytes32 rootCauseHash);
    event FindingDisputed(bytes32 indexed findingId, Severity proposedSeverity, bytes32 duplicateOf);
    event DisputeResolved(bytes32 indexed findingId, Severity severity, bool rejected, uint256 locked);
    event FindingClosed(bytes32 indexed findingId, Status status);
    event ValidationPosted(bytes32 indexed findingId, uint256 indexed agentId, bytes32 requestHash);
    event ValidationSkipped(bytes32 indexed findingId, uint256 indexed agentId);
    event KeeperSet(address keeper);
    event GuardianSet(address guardian);
    event DisputeResolverSet(address resolver);
    event ClaimsPausedSet(bool paused);
    event RatingWindowSet(uint64 ratingWindow);
    event ReviewWindowSet(uint64 reviewWindow);
    event SettleGraceSet(uint64 settleGrace);
    event ValidationBaseURISet(string uri);

    error ZeroAddress();
    error ZeroFinding();
    error ZeroRootCause();
    error NotKeeper();
    error NotGuardian();
    error NotResolver();
    error NotClient();
    error NotPot();
    error NotCheckerNet();
    error ClaimsArePaused();
    error FindingExists(bytes32 findingId);
    error NotInScope(address target, uint64 chainId);
    error BadTier(uint8 tier);
    error BadStatus(bytes32 findingId, Status status);
    error BadSplit();
    error ReviewClosed(uint64 reviewEndsAt);
    error CannotRaiseSeverity();
    error BadConfig();

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    modifier onlyPot() {
        if (msg.sender != address(pot)) revert NotPot();
        _;
    }

    constructor(
        address scope_,
        address pot_,
        address checkerNet_,
        address validation_,
        address keeper_,
        address guardian_,
        address resolver_,
        address owner_
    ) Ownable(owner_) {
        if (
            scope_ == address(0) || pot_ == address(0) || checkerNet_ == address(0) || validation_ == address(0)
                || keeper_ == address(0) || guardian_ == address(0) || resolver_ == address(0)
        ) revert ZeroAddress();
        scope = ISapperScope(scope_);
        pot = ISapperBountyPot(pot_);
        checkerNet = ISapperCheckerNet(checkerNet_);
        validation = IERC8004Validation(validation_);
        keeper = keeper_;
        guardian = guardian_;
        disputeResolver = resolver_;
        emit KeeperSet(keeper_);
        emit GuardianSet(guardian_);
        emit DisputeResolverSet(resolver_);
    }

    /// @notice Opens a checker round and locks the client's Critical price, capped by its unlocked
    /// balance, until `ratingWindow` ends. An unrated claim is refundable by anyone after that.
    /// @param tier Size tier picked by the keeper: 0, 1, 2 draw 3, 4, 5 checkers.
    function claim(
        bytes32 findingId,
        address target,
        uint64 chainId,
        uint64 forkBlock,
        bytes32 bundleHash,
        address breakerOperator,
        uint256 agentId,
        uint8 tier
    ) external onlyKeeper {
        if (claimsPaused) revert ClaimsArePaused();
        if (findingId == 0) revert ZeroFinding();
        if (breakerOperator == address(0)) revert ZeroAddress();
        if (tier > MAX_TIER) revert BadTier(tier);
        Finding storage f = _findings[findingId];
        if (f.status != Status.None) revert FindingExists(findingId);
        ISapperScope.Entry memory e = scope.entry(target, chainId);
        if (!e.active) revert NotInScope(target, chainId);

        f.target = target;
        f.chainId = chainId;
        f.client = e.client;
        f.forkBlock = forkBlock;
        f.breakerOperator = breakerOperator;
        f.agentId = agentId;
        f.bundleHash = bundleHash;
        f.status = Status.Claimed;

        address[] memory exclude = new address[](1);
        exclude[0] = breakerOperator;
        checkerNet.openRound(findingId, BASE_CHECKERS + tier, exclude);
        pot.lockForFinding(findingId, e.client, uint64(block.timestamp) + ratingWindow);
        emit FindingClaimed(findingId, target, e.client, chainId, forkBlock, bundleHash, breakerOperator, agentId);
    }

    /// @dev Never reverts for a finding the pot already refunded, so the checker net can always
    /// finalize its round and release its checkers.
    function onCheckerConsensus(bytes32 findingId, bool confirmed, bytes32 resultHash) external {
        if (msg.sender != address(checkerNet)) revert NotCheckerNet();
        emit CheckerConsensus(findingId, confirmed, resultHash);
        if (_findings[findingId].status == Status.Expired) return;
        Finding storage f = _expect(findingId, Status.Claimed);
        f.resultHash = resultHash;
        if (confirmed) {
            f.status = Status.Confirmed;
            return;
        }
        f.status = Status.Rejected;
        pot.releaseLock(findingId);
    }

    function rate(
        bytes32 findingId,
        Severity severity,
        bytes32 rootCauseHash,
        address[] calldata workers,
        uint16[] calldata workerBps
    ) external onlyKeeper {
        Finding storage f = _expect(findingId, Status.Confirmed);
        if (rootCauseHash == 0) revert ZeroRootCause();
        _checkSplit(workers, workerBps);
        f.rootCauseHash = rootCauseHash;

        bytes32 key = _rootKey(f, rootCauseHash);
        bytes32 original = rootCauseFinding[key];
        if (original != 0) {
            f.status = Status.Rejected;
            pot.releaseLock(findingId);
            emit DuplicateRejected(findingId, original, rootCauseHash);
            return;
        }
        rootCauseFinding[key] = findingId;

        uint64 reviewEndsAt = uint64(block.timestamp) + reviewWindow;
        f.severity = severity;
        f.workers = workers;
        f.workerBps = workerBps;
        f.reviewEndsAt = reviewEndsAt;
        f.status = Status.Review;
        uint256 locked = pot.adjustLock(findingId, severity, reviewEndsAt + settleGrace);
        emit FindingRated(findingId, severity, rootCauseHash, locked, reviewEndsAt);
    }

    function dispute(bytes32 findingId, Severity proposedSeverity, bytes32 duplicateOf) external {
        Finding storage f = _expect(findingId, Status.Review);
        if (msg.sender != f.client) revert NotClient();
        if (block.timestamp >= f.reviewEndsAt) revert ReviewClosed(f.reviewEndsAt);
        f.status = Status.Disputed;
        _disputes[findingId] = Dispute(proposedSeverity, duplicateOf);
        emit FindingDisputed(findingId, proposedSeverity, duplicateOf);
    }

    /// @notice Settles a dispute. A re-rate can only lower severity; the new amount is priced
    /// against the table frozen at claim time and capped by what is locked.
    function resolve(bytes32 findingId, Severity finalSeverity, bool reject) external {
        if (msg.sender != disputeResolver) revert NotResolver();
        Finding storage f = _expect(findingId, Status.Disputed);

        if (reject) {
            f.status = Status.Rejected;
            delete rootCauseFinding[_rootKey(f, f.rootCauseHash)];
            pot.releaseLock(findingId);
            emit DisputeResolved(findingId, f.severity, true, 0);
            return;
        }

        if (finalSeverity > f.severity) revert CannotRaiseSeverity();
        ISapperBountyPot.Lock memory l = pot.lockOf(findingId);
        uint256 amount = l.amount;
        if (finalSeverity < f.severity) {
            amount = pot.adjustLock(findingId, finalSeverity, l.expiry);
            f.severity = finalSeverity;
        }
        f.status = Status.Review;
        f.reviewEndsAt = uint64(block.timestamp);
        emit DisputeResolved(findingId, finalSeverity, false, amount);
    }

    function onSettled(bytes32 findingId) external onlyPot {
        Finding storage f = _expect(findingId, Status.Review);
        f.status = Status.Settled;
        emit FindingClosed(findingId, Status.Settled);
        if (f.agentId != 0) _postValidation(findingId, f);
    }

    function onExpired(bytes32 findingId) external onlyPot {
        Finding storage f = _findings[findingId];
        Status s = f.status;
        if (s != Status.Claimed && s != Status.Confirmed && s != Status.Review && s != Status.Disputed) return;
        f.status = Status.Expired;
        emit FindingClosed(findingId, Status.Expired);
    }

    function setClaimsPaused(bool paused) external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardian();
        claimsPaused = paused;
        emit ClaimsPausedSet(paused);
    }

    function setKeeper(address keeper_) external onlyOwner {
        if (keeper_ == address(0)) revert ZeroAddress();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setGuardian(address guardian_) external onlyOwner {
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    function setDisputeResolver(address resolver_) external onlyOwner {
        if (resolver_ == address(0)) revert ZeroAddress();
        disputeResolver = resolver_;
        emit DisputeResolverSet(resolver_);
    }

    function setRatingWindow(uint64 window) external onlyOwner {
        if (window == 0 || window > MAX_RATING_WINDOW) revert BadConfig();
        ratingWindow = window;
        emit RatingWindowSet(window);
    }

    function setReviewWindow(uint64 window) external onlyOwner {
        if (window == 0 || window > MAX_REVIEW_WINDOW) revert BadConfig();
        reviewWindow = window;
        emit ReviewWindowSet(window);
    }

    function setSettleGrace(uint64 grace) external onlyOwner {
        if (grace == 0 || grace > MAX_SETTLE_GRACE) revert BadConfig();
        settleGrace = grace;
        emit SettleGraceSet(grace);
    }

    function setValidationBaseURI(string calldata uri) external onlyOwner {
        validationBaseURI = uri;
        emit ValidationBaseURISet(uri);
    }

    function settleable(bytes32 findingId) external view returns (bool) {
        Finding storage f = _findings[findingId];
        return f.status == Status.Review && block.timestamp >= f.reviewEndsAt;
    }

    function payees(bytes32 findingId)
        external
        view
        returns (address[] memory workers, uint16[] memory workerBps, address[] memory checkers)
    {
        Finding storage f = _findings[findingId];
        return (f.workers, f.workerBps, checkerNet.consensusCheckers(findingId));
    }

    function status(bytes32 findingId) external view returns (Status) {
        return _findings[findingId].status;
    }

    function finding(bytes32 findingId) external view returns (Finding memory) {
        return _findings[findingId];
    }

    function disputeOf(bytes32 findingId) external view returns (Dispute memory) {
        return _disputes[findingId];
    }

    /// @dev Needs this gate to be an operator of `agentId` on the identity registry. A refusal
    /// there is recorded as skipped so it can never block a payout. The hash commits to the
    /// settle block so nobody can occupy it in the registry ahead of time.
    function _postValidation(bytes32 findingId, Finding storage f) private {
        bytes32 requestHash =
            keccak256(abi.encode(block.chainid, address(this), findingId, f.resultHash, block.number));
        string memory uri = bytes(validationBaseURI).length == 0
            ? ""
            : string.concat(validationBaseURI, Strings.toHexString(uint256(findingId), 32));
        try validation.validationRequest(address(this), f.agentId, uri, requestHash) {}
        catch {
            emit ValidationSkipped(findingId, f.agentId);
            return;
        }
        validation.validationResponse(requestHash, CONFIRMED_RESPONSE, uri, f.resultHash, _tag(f.severity));
        validationRequestOf[findingId] = requestHash;
        emit ValidationPosted(findingId, f.agentId, requestHash);
    }

    function _expect(bytes32 findingId, Status s) private view returns (Finding storage f) {
        f = _findings[findingId];
        if (f.status != s) revert BadStatus(findingId, f.status);
    }

    function _checkSplit(address[] calldata workers, uint16[] calldata workerBps) private pure {
        uint256 n = workers.length;
        if (n == 0 || n > MAX_WORKERS || n != workerBps.length) revert BadSplit();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (workers[i] == address(0)) revert BadSplit();
            sum += workerBps[i];
        }
        if (sum != BPS) revert BadSplit();
    }

    function _rootKey(Finding storage f, bytes32 rootCauseHash) private view returns (bytes32) {
        return keccak256(abi.encode(f.client, f.target, f.chainId, rootCauseHash));
    }

    function _tag(Severity s) private pure returns (string memory) {
        if (s == Severity.Critical) return "critical";
        if (s == Severity.High) return "high";
        if (s == Severity.Medium) return "medium";
        return "low";
    }
}
