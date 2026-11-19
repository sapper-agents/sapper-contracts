// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC8004Identity, IERC8004Validation} from "./interfaces/IERC8004.sol";

/// @notice Minimal ERC-8004 validation registry bound to an existing identity registry.
contract SapperValidationRegistry is IERC8004Validation {
    struct Record {
        address validatorAddress;
        uint8 response;
        bool responded;
        uint256 agentId;
        bytes32 responseHash;
        uint256 lastUpdate;
        string tag;
    }

    IERC8004Identity public immutable identityRegistry;

    mapping(bytes32 => Record) private _records;
    mapping(uint256 => bytes32[]) private _agentValidations;
    mapping(address => bytes32[]) private _validatorRequests;

    error ZeroAddress();
    error ZeroRequestHash();
    error RequestExists(bytes32 requestHash);
    error UnknownRequest(bytes32 requestHash);
    error NotAgentOperator();
    error NotValidator();
    error ResponseOutOfRange(uint8 response);

    constructor(address identity) {
        if (identity == address(0)) revert ZeroAddress();
        identityRegistry = IERC8004Identity(identity);
    }

    function getIdentityRegistry() external view returns (address) {
        return address(identityRegistry);
    }

    function validationRequest(
        address validatorAddress,
        uint256 agentId,
        string calldata requestURI,
        bytes32 requestHash
    ) external {
        if (validatorAddress == address(0)) revert ZeroAddress();
        if (requestHash == 0) revert ZeroRequestHash();
        if (_records[requestHash].validatorAddress != address(0)) revert RequestExists(requestHash);
        if (!_operates(msg.sender, agentId)) revert NotAgentOperator();

        Record storage r = _records[requestHash];
        r.validatorAddress = validatorAddress;
        r.agentId = agentId;
        r.lastUpdate = block.timestamp;
        _agentValidations[agentId].push(requestHash);
        _validatorRequests[validatorAddress].push(requestHash);
        emit ValidationRequest(validatorAddress, agentId, requestURI, requestHash);
    }

    /// @dev A validator may respond again to the same request, e.g. to move from soft to hard finality.
    function validationResponse(
        bytes32 requestHash,
        uint8 response,
        string calldata responseURI,
        bytes32 responseHash,
        string calldata tag
    ) external {
        Record storage r = _records[requestHash];
        if (r.validatorAddress == address(0)) revert UnknownRequest(requestHash);
        if (msg.sender != r.validatorAddress) revert NotValidator();
        if (response > 100) revert ResponseOutOfRange(response);

        r.response = response;
        r.responded = true;
        r.responseHash = responseHash;
        r.tag = tag;
        r.lastUpdate = block.timestamp;
        emit ValidationResponse(msg.sender, r.agentId, requestHash, response, responseURI, responseHash, tag);
    }

    function getValidationStatus(bytes32 requestHash)
        external
        view
        returns (
            address validatorAddress,
            uint256 agentId,
            uint8 response,
            bytes32 responseHash,
            string memory tag,
            uint256 lastUpdate
        )
    {
        Record storage r = _records[requestHash];
        return (r.validatorAddress, r.agentId, r.response, r.responseHash, r.tag, r.lastUpdate);
    }

    function getSummary(uint256 agentId, address[] calldata validatorAddresses, string calldata tag)
        external
        view
        returns (uint64 count, uint8 averageResponse)
    {
        bytes32[] storage hashes = _agentValidations[agentId];
        bytes32 tagHash = keccak256(bytes(tag));
        bool anyTag = bytes(tag).length == 0;
        uint256 sum;
        for (uint256 i; i < hashes.length; ++i) {
            Record storage r = _records[hashes[i]];
            if (!r.responded) continue;
            if (!anyTag && keccak256(bytes(r.tag)) != tagHash) continue;
            if (validatorAddresses.length != 0 && !_contains(validatorAddresses, r.validatorAddress)) continue;
            ++count;
            sum += r.response;
        }
        if (count != 0) averageResponse = uint8(sum / count);
    }

    function getAgentValidations(uint256 agentId) external view returns (bytes32[] memory) {
        return _agentValidations[agentId];
    }

    function getValidatorRequests(address validatorAddress) external view returns (bytes32[] memory) {
        return _validatorRequests[validatorAddress];
    }

    function _operates(address account, uint256 agentId) private view returns (bool) {
        address owner = identityRegistry.ownerOf(agentId);
        return account == owner || identityRegistry.isApprovedForAll(owner, account)
            || identityRegistry.getApproved(agentId) == account;
    }

    function _contains(address[] calldata list, address a) private pure returns (bool) {
        for (uint256 i; i < list.length; ++i) {
            if (list[i] == a) return true;
        }
        return false;
    }
}
