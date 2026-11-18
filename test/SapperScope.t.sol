// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SapperScope} from "../src/SapperScope.sol";
import {ISapperScope} from "../src/interfaces/ISapperScope.sol";
import {
    OwnedTarget,
    AdminTarget,
    RoleTarget,
    RevertingTarget,
    ShortReturnTarget,
    DirtyReturnTarget,
    Wallet1271
} from "./mocks/Mocks.sol";

contract SapperScopeTest is Test {
    SapperScope scope;

    uint256 constant ATTESTER_KEY = 0xA77E57;
    uint256 constant CONTROLLER_KEY = 0xC0117201;
    address attester = vm.addr(ATTESTER_KEY);
    address controller = vm.addr(CONTROLLER_KEY);
    address client = makeAddr("client");
    address disclosure = makeAddr("disclosure");
    bytes32 constant ROOT = keccak256("invariants");
    uint64 chain;

    function setUp() public {
        scope = new SapperScope(address(this), attester);
        chain = uint64(block.chainid);
    }

    function test_optIn_ownerEcho() public {
        address target = address(new OwnedTarget(client));
        vm.expectEmit(address(scope));
        emit SapperScope.OptedIn(target, chain, client, ROOT, disclosure);
        vm.prank(client);
        scope.optIn(target, chain, ROOT, disclosure, "");

        ISapperScope.Entry memory e = scope.entry(target, chain);
        assertEq(e.target, target);
        assertEq(e.chainId, chain);
        assertEq(e.invariantsRoot, ROOT);
        assertEq(e.disclosureAddr, disclosure);
        assertEq(e.client, client);
        assertTrue(e.active);
        assertEq(e.optedInAt, block.timestamp);
        assertTrue(scope.isInScope(target, chain));
    }

    function test_optIn_adminEcho() public {
        address target = address(new AdminTarget(client));
        vm.prank(client);
        scope.optIn(target, chain, ROOT, disclosure, "");
        assertTrue(scope.isInScope(target, chain));
    }

    function test_optIn_defaultAdminRole() public {
        address target = address(new RoleTarget(client));
        vm.prank(client);
        scope.optIn(target, chain, ROOT, disclosure, "");
        assertTrue(scope.isInScope(target, chain));
    }

    function testFuzz_optIn_rejectsStranger(address stranger) public {
        vm.assume(stranger != client && stranger != address(0));
        address[3] memory targets =
            [address(new OwnedTarget(client)), address(new AdminTarget(client)), address(new RoleTarget(client))];
        for (uint256 i; i < targets.length; ++i) {
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(SapperScope.NotController.selector, stranger));
            scope.optIn(targets[i], chain, ROOT, disclosure, "");
        }
    }

    function test_optIn_badTargetsCountAsNo() public {
        address[4] memory targets = [
            address(new RevertingTarget()),
            address(new ShortReturnTarget()),
            address(new DirtyReturnTarget(client)),
            makeAddr("eoa")
        ];
        for (uint256 i; i < targets.length; ++i) {
            assertFalse(scope.controls(targets[i], client));
            vm.prank(client);
            vm.expectRevert(abi.encodeWithSelector(SapperScope.NotController.selector, client));
            scope.optIn(targets[i], chain, ROOT, disclosure, "");
        }
    }

    function test_optIn_eoaSignature() public {
        address target = address(new OwnedTarget(controller));
        bytes memory sig = _sign(CONTROLLER_KEY, _optInDigest(target, client, 0));
        vm.prank(client);
        scope.optIn(target, chain, ROOT, disclosure, abi.encode(controller, sig));
        assertEq(scope.entry(target, chain).client, client);
        assertEq(scope.nonces(controller, client), 1);
    }

    function test_optIn_erc1271Signature() public {
        Wallet1271 safe = new Wallet1271(controller);
        address target = address(new OwnedTarget(address(safe)));
        bytes memory sig = _sign(CONTROLLER_KEY, _optInDigest(target, client, 0));
        vm.prank(client);
        scope.optIn(target, chain, ROOT, disclosure, abi.encode(address(safe), sig));
        assertEq(scope.entry(target, chain).client, client);
    }

    function test_optIn_signatureMustComeFromController() public {
        address target = address(new OwnedTarget(controller));
        bytes memory sig = _sign(ATTESTER_KEY, _optInDigest(target, client, 0));
        vm.prank(client);
        vm.expectRevert(SapperScope.BadSignature.selector);
        scope.optIn(target, chain, ROOT, disclosure, abi.encode(controller, sig));
    }

    function test_optIn_signerMustControlTarget() public {
        address target = address(new OwnedTarget(makeAddr("realOwner")));
        bytes memory sig = _sign(CONTROLLER_KEY, _optInDigest(target, client, 0));
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SapperScope.NotController.selector, controller));
        scope.optIn(target, chain, ROOT, disclosure, abi.encode(controller, sig));
    }

    function test_optIn_signatureBoundToClient() public {
        address target = address(new OwnedTarget(controller));
        bytes memory sig = _sign(CONTROLLER_KEY, _optInDigest(target, client, 0));
        vm.prank(makeAddr("thief"));
        vm.expectRevert(SapperScope.BadSignature.selector);
        scope.optIn(target, chain, ROOT, disclosure, abi.encode(controller, sig));
    }

    function test_optIn_replayedSignatureFails() public {
        address target = address(new OwnedTarget(controller));
        bytes memory proof = abi.encode(controller, _sign(CONTROLLER_KEY, _optInDigest(target, client, 0)));
        vm.startPrank(client);
        scope.optIn(target, chain, ROOT, disclosure, proof);
        scope.optOut(target, chain);
        vm.expectRevert(SapperScope.BadSignature.selector);
        scope.optIn(target, chain, ROOT, disclosure, proof);
        vm.stopPrank();
    }

    function test_remote_attesterPath() public {
        address target = makeAddr("baseContract");
        uint64 remote = 8453;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(ATTESTER_KEY, _remoteDigest(target, remote, client, deadline, 0));
        vm.prank(client);
        scope.optIn(target, remote, ROOT, disclosure, abi.encode(deadline, sig));
        assertTrue(scope.isInScope(target, remote));
        assertFalse(scope.isInScope(target, chain));
    }

    function test_remote_replayFails() public {
        address target = makeAddr("baseContract");
        uint64 remote = 8453;
        uint64 deadline = uint64(block.timestamp + 1 hours);
        bytes memory proof = abi.encode(deadline, _sign(ATTESTER_KEY, _remoteDigest(target, remote, client, deadline, 0)));
        vm.startPrank(client);
        scope.optIn(target, remote, ROOT, disclosure, proof);
        scope.optOut(target, remote);
        vm.expectRevert(SapperScope.BadSignature.selector);
        scope.optIn(target, remote, ROOT, disclosure, proof);
        vm.stopPrank();
    }

    function test_remote_rejectsExpiredWrongSignerOrMissingAttester() public {
        address target = makeAddr("baseContract");
        uint64 remote = 42161;
        uint64 deadline = uint64(block.timestamp + 1 hours);

        bytes memory wrong = _sign(CONTROLLER_KEY, _remoteDigest(target, remote, client, deadline, 0));
        vm.prank(client);
        vm.expectRevert(SapperScope.BadSignature.selector);
        scope.optIn(target, remote, ROOT, disclosure, abi.encode(deadline, wrong));

        bytes memory good = _sign(ATTESTER_KEY, _remoteDigest(target, remote, client, deadline, 0));
        vm.warp(deadline + 1);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(SapperScope.ProofExpired.selector, deadline));
        scope.optIn(target, remote, ROOT, disclosure, abi.encode(deadline, good));

        scope.setControlAttester(address(0));
        vm.prank(client);
        vm.expectRevert(SapperScope.NoAttester.selector);
        scope.optIn(target, remote, ROOT, disclosure, abi.encode(deadline, good));
    }

    function test_remote_attesterCannotBeSkippedWithOwnerEcho() public {
        address target = address(new OwnedTarget(client));
        vm.prank(client);
        vm.expectRevert(SapperScope.MissingProof.selector);
        scope.optIn(target, 1, ROOT, disclosure, "");
    }

    function test_secondClientOnlyWhileInactive() public {
        address other = makeAddr("other");
        RoleTarget target = new RoleTarget(client);
        vm.prank(client);
        target.grantRole(0x00, other);

        vm.prank(client);
        scope.optIn(address(target), chain, ROOT, disclosure, "");
        vm.prank(other);
        vm.expectRevert(SapperScope.AlreadyInScope.selector);
        scope.optIn(address(target), chain, ROOT, disclosure, "");

        vm.prank(client);
        scope.optOut(address(target), chain);
        vm.prank(other);
        scope.optIn(address(target), chain, bytes32(uint256(2)), disclosure, "");
        assertEq(scope.entry(address(target), chain).client, other);
    }

    function test_updatesAreClientOnly() public {
        address target = address(new OwnedTarget(client));
        vm.prank(client);
        scope.optIn(target, chain, ROOT, disclosure, "");

        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(SapperScope.NotClient.selector);
        scope.updateInvariants(target, chain, bytes32(uint256(1)));
        vm.expectRevert(SapperScope.NotClient.selector);
        scope.updateDisclosure(target, chain, stranger);
        vm.expectRevert(SapperScope.NotClient.selector);
        scope.optOut(target, chain);
        vm.stopPrank();

        bytes32 root = keccak256("v2");
        address addr = makeAddr("newDisclosure");
        vm.startPrank(client);
        vm.expectEmit(address(scope));
        emit SapperScope.InvariantsUpdated(target, chain, client, root);
        scope.updateInvariants(target, chain, root);
        vm.expectEmit(address(scope));
        emit SapperScope.DisclosureUpdated(target, chain, client, addr);
        scope.updateDisclosure(target, chain, addr);
        vm.expectEmit(address(scope));
        emit SapperScope.OptedOut(target, chain, client);
        scope.optOut(target, chain);
        vm.expectRevert(SapperScope.NotInScope.selector);
        scope.updateInvariants(target, chain, root);
        vm.stopPrank();

        ISapperScope.Entry memory e = scope.entry(target, chain);
        assertEq(e.invariantsRoot, root);
        assertEq(e.disclosureAddr, addr);
        assertFalse(e.active);
        assertFalse(scope.isInScope(target, chain));
    }

    function test_attesterIsOwnerOnly() public {
        vm.prank(client);
        vm.expectRevert();
        scope.setControlAttester(client);
    }

    function _optInDigest(address target, address forClient, uint256 nonce) internal view returns (bytes32) {
        return MessageHashUtils.toTypedDataHash(
            _domain(),
            keccak256(abi.encode(scope.OPT_IN_TYPEHASH(), target, chain, ROOT, disclosure, forClient, nonce))
        );
    }

    function _remoteDigest(address target, uint64 chainId, address forClient, uint64 deadline, uint256 nonce)
        internal
        view
        returns (bytes32)
    {
        return MessageHashUtils.toTypedDataHash(
            _domain(), keccak256(abi.encode(scope.REMOTE_CONTROL_TYPEHASH(), target, chainId, forClient, deadline, nonce))
        );
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SapperScope"),
                keccak256("1"),
                block.chainid,
                address(scope)
            )
        );
    }

    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
}
