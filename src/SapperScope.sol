// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ISapperScope} from "./interfaces/ISapperScope.sol";

/// @notice Opt-in registry. A client proves control of a target once and Sapper watches it; no keys are held.
contract SapperScope is ISapperScope, Ownable2Step, EIP712 {
    bytes32 public constant OPT_IN_TYPEHASH = keccak256(
        "OptIn(address target,uint64 chainId,bytes32 invariantsRoot,address disclosureAddr,address client,uint256 nonce)"
    );
    bytes32 public constant REMOTE_CONTROL_TYPEHASH =
        keccak256("RemoteControl(address target,uint64 chainId,address client,uint64 deadline,uint256 nonce)");

    address public controlAttester;

    /// @dev Keyed by signer and client, so a shared signer (the attester) can have proofs outstanding for many clients.
    mapping(address signer => mapping(address client => uint256)) public nonces;

    mapping(bytes32 => Entry) private _entries;

    event OptedIn(
        address indexed target,
        uint64 indexed chainId,
        address indexed client,
        bytes32 invariantsRoot,
        address disclosureAddr
    );
    event InvariantsUpdated(address indexed target, uint64 indexed chainId, address indexed client, bytes32 invariantsRoot);
    event DisclosureUpdated(address indexed target, uint64 indexed chainId, address indexed client, address disclosureAddr);
    event OptedOut(address indexed target, uint64 indexed chainId, address indexed client);
    event ControlAttesterSet(address attester);

    error ZeroTarget();
    error ZeroChainId();
    error ZeroDisclosure();
    error AlreadyInScope();
    error NotInScope();
    error NotClient();
    error NotController(address account);
    error BadSignature();
    error ProofExpired(uint64 deadline);
    error NoAttester();
    error MissingProof();

    constructor(address owner_, address attester) Ownable(owner_) EIP712("SapperScope", "1") {
        controlAttester = attester;
        emit ControlAttesterSet(attester);
    }

    function optIn(
        address target,
        uint64 chainId,
        bytes32 invariantsRoot,
        address disclosureAddr,
        bytes calldata controlProof
    ) external {
        if (target == address(0)) revert ZeroTarget();
        if (chainId == 0) revert ZeroChainId();
        if (disclosureAddr == address(0)) revert ZeroDisclosure();
        bytes32 key = _key(target, chainId);
        if (_entries[key].active) revert AlreadyInScope();

        if (chainId == block.chainid) _proveLocal(target, chainId, invariantsRoot, disclosureAddr, controlProof);
        else _proveRemote(target, chainId, controlProof);

        _entries[key] = Entry({
            target: target,
            chainId: chainId,
            invariantsRoot: invariantsRoot,
            disclosureAddr: disclosureAddr,
            client: msg.sender,
            active: true,
            optedInAt: uint64(block.timestamp)
        });
        emit OptedIn(target, chainId, msg.sender, invariantsRoot, disclosureAddr);
    }

    function updateInvariants(address target, uint64 chainId, bytes32 newRoot) external {
        _own(target, chainId).invariantsRoot = newRoot;
        emit InvariantsUpdated(target, chainId, msg.sender, newRoot);
    }

    function updateDisclosure(address target, uint64 chainId, address addr) external {
        if (addr == address(0)) revert ZeroDisclosure();
        _own(target, chainId).disclosureAddr = addr;
        emit DisclosureUpdated(target, chainId, msg.sender, addr);
    }

    function optOut(address target, uint64 chainId) external {
        _own(target, chainId).active = false;
        emit OptedOut(target, chainId, msg.sender);
    }

    function setControlAttester(address attester) external onlyOwner {
        controlAttester = attester;
        emit ControlAttesterSet(attester);
    }

    function isInScope(address target, uint64 chainId) external view returns (bool) {
        return _entries[_key(target, chainId)].active;
    }

    function entry(address target, uint64 chainId) external view returns (Entry memory) {
        return _entries[_key(target, chainId)];
    }

    /// @notice True when `target` names `account` through owner(), admin() or DEFAULT_ADMIN_ROLE.
    /// A reverting, empty or short return counts as no.
    function controls(address target, address account) public view returns (bool) {
        if (account == address(0)) return false;
        return _returns(target, abi.encodeWithSignature("owner()"), uint160(account))
            || _returns(target, abi.encodeWithSignature("admin()"), uint160(account))
            || _returns(target, abi.encodeCall(IAccessControl.hasRole, (bytes32(0), account)), 1);
    }

    function _proveLocal(
        address target,
        uint64 chainId,
        bytes32 invariantsRoot,
        address disclosureAddr,
        bytes calldata proof
    ) private {
        if (proof.length == 0) {
            if (!controls(target, msg.sender)) revert NotController(msg.sender);
            return;
        }
        (address controller, bytes memory sig) = abi.decode(proof, (address, bytes));
        if (!controls(target, controller)) revert NotController(controller);
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(
                    OPT_IN_TYPEHASH,
                    target,
                    chainId,
                    invariantsRoot,
                    disclosureAddr,
                    msg.sender,
                    nonces[controller][msg.sender]++
                )
            )
        );
        if (!SignatureChecker.isValidSignatureNow(controller, digest, sig)) revert BadSignature();
    }

    function _proveRemote(address target, uint64 chainId, bytes calldata proof) private {
        address attester = controlAttester;
        if (attester == address(0)) revert NoAttester();
        if (proof.length == 0) revert MissingProof();
        (uint64 deadline, bytes memory sig) = abi.decode(proof, (uint64, bytes));
        if (block.timestamp > deadline) revert ProofExpired(deadline);
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(REMOTE_CONTROL_TYPEHASH, target, chainId, msg.sender, deadline, nonces[attester][msg.sender]++)
            )
        );
        if (!SignatureChecker.isValidSignatureNow(attester, digest, sig)) revert BadSignature();
    }

    function _own(address target, uint64 chainId) private view returns (Entry storage e) {
        e = _entries[_key(target, chainId)];
        if (!e.active) revert NotInScope();
        if (e.client != msg.sender) revert NotClient();
    }

    function _returns(address target, bytes memory data, uint256 expected) private view returns (bool) {
        (bool ok, bytes memory ret) = target.staticcall(data);
        return ok && ret.length >= 32 && abi.decode(ret, (uint256)) == expected;
    }

    function _key(address target, uint64 chainId) private pure returns (bytes32) {
        return keccak256(abi.encode(target, chainId));
    }
}
