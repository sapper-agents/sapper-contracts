// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SapperValidationRegistry} from "../src/SapperValidationRegistry.sol";
import {IERC8004Validation} from "../src/interfaces/IERC8004.sol";
import {MockIdentity} from "./mocks/Mocks.sol";

contract SapperValidationRegistryTest is Test {
    MockIdentity identity;
    SapperValidationRegistry registry;

    address agentOwner = makeAddr("agentOwner");
    address validator = makeAddr("validator");
    address other = makeAddr("other");
    uint256 agentId;
    bytes32 constant REQ = keccak256("request");

    function setUp() public {
        identity = new MockIdentity();
        registry = new SapperValidationRegistry(address(identity));
        vm.prank(agentOwner);
        agentId = identity.register();
    }

    function test_requestByOwnerAndRespond() public {
        vm.expectEmit(address(registry));
        emit IERC8004Validation.ValidationRequest(validator, agentId, "ipfs://req", REQ);
        vm.prank(agentOwner);
        registry.validationRequest(validator, agentId, "ipfs://req", REQ);

        vm.warp(block.timestamp + 10);
        vm.expectEmit(address(registry));
        emit IERC8004Validation.ValidationResponse(
            validator, agentId, REQ, 100, "ipfs://res", bytes32(uint256(7)), "critical"
        );
        vm.prank(validator);
        registry.validationResponse(REQ, 100, "ipfs://res", bytes32(uint256(7)), "critical");

        (address v, uint256 id, uint8 response, bytes32 responseHash, string memory tag, uint256 lastUpdate) =
            registry.getValidationStatus(REQ);
        assertEq(v, validator);
        assertEq(id, agentId);
        assertEq(response, 100);
        assertEq(responseHash, bytes32(uint256(7)));
        assertEq(tag, "critical");
        assertEq(lastUpdate, block.timestamp);
        assertEq(registry.getIdentityRegistry(), address(identity));
    }

    function test_requestByOperatorOrApproved() public {
        vm.prank(agentOwner);
        identity.setApprovalForAll(other, true);
        vm.prank(other);
        registry.validationRequest(validator, agentId, "", REQ);

        address approved = makeAddr("approved");
        vm.prank(agentOwner);
        identity.approve(approved, agentId);
        vm.prank(approved);
        registry.validationRequest(validator, agentId, "", keccak256("second"));

        assertEq(registry.getAgentValidations(agentId).length, 2);
        assertEq(registry.getValidatorRequests(validator).length, 2);
    }

    function test_requestRejects() public {
        vm.prank(other);
        vm.expectRevert(SapperValidationRegistry.NotAgentOperator.selector);
        registry.validationRequest(validator, agentId, "", REQ);

        vm.startPrank(agentOwner);
        vm.expectRevert(SapperValidationRegistry.ZeroAddress.selector);
        registry.validationRequest(address(0), agentId, "", REQ);
        vm.expectRevert(SapperValidationRegistry.ZeroRequestHash.selector);
        registry.validationRequest(validator, agentId, "", bytes32(0));
        vm.expectRevert();
        registry.validationRequest(validator, 999, "", REQ);

        registry.validationRequest(validator, agentId, "", REQ);
        vm.expectRevert(abi.encodeWithSelector(SapperValidationRegistry.RequestExists.selector, REQ));
        registry.validationRequest(other, agentId, "", REQ);
        vm.stopPrank();
    }

    function test_responseRejects() public {
        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(SapperValidationRegistry.UnknownRequest.selector, REQ));
        registry.validationResponse(REQ, 100, "", 0, "");

        vm.prank(agentOwner);
        registry.validationRequest(validator, agentId, "", REQ);

        vm.prank(other);
        vm.expectRevert(SapperValidationRegistry.NotValidator.selector);
        registry.validationResponse(REQ, 100, "", 0, "");

        vm.prank(validator);
        vm.expectRevert(abi.encodeWithSelector(SapperValidationRegistry.ResponseOutOfRange.selector, 101));
        registry.validationResponse(REQ, 101, "", 0, "");
    }

    function test_validatorMayRespondAgain() public {
        vm.prank(agentOwner);
        registry.validationRequest(validator, agentId, "", REQ);
        vm.startPrank(validator);
        registry.validationResponse(REQ, 50, "", 0, "soft");
        registry.validationResponse(REQ, 100, "", 0, "hard");
        vm.stopPrank();
        (,, uint8 response,, string memory tag,) = registry.getValidationStatus(REQ);
        assertEq(response, 100);
        assertEq(tag, "hard");
    }

    function test_summaryFiltersByValidatorAndTag() public {
        address second = makeAddr("second");
        vm.startPrank(agentOwner);
        registry.validationRequest(validator, agentId, "", keccak256("a"));
        registry.validationRequest(validator, agentId, "", keccak256("b"));
        registry.validationRequest(second, agentId, "", keccak256("c"));
        registry.validationRequest(second, agentId, "", keccak256("unanswered"));
        vm.stopPrank();

        vm.startPrank(validator);
        registry.validationResponse(keccak256("a"), 100, "", 0, "critical");
        registry.validationResponse(keccak256("b"), 60, "", 0, "low");
        vm.stopPrank();
        vm.prank(second);
        registry.validationResponse(keccak256("c"), 20, "", 0, "critical");

        address[] memory none = new address[](0);
        (uint64 count, uint8 avg) = registry.getSummary(agentId, none, "");
        assertEq(count, 3);
        assertEq(avg, 60);

        (count, avg) = registry.getSummary(agentId, none, "critical");
        assertEq(count, 2);
        assertEq(avg, 60);

        address[] memory only = new address[](1);
        only[0] = validator;
        (count, avg) = registry.getSummary(agentId, only, "");
        assertEq(count, 2);
        assertEq(avg, 80);
    }
}
