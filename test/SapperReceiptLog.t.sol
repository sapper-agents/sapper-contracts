// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {SapperReceiptLog} from "../src/SapperReceiptLog.sol";

contract SapperReceiptLogTest is Test {
    SapperReceiptLog receipts;
    address keeper = makeAddr("keeper");
    bytes32 constant JOB = keccak256("job-1");
    bytes32 constant ROOT = keccak256("root");

    function setUp() public {
        receipts = new SapperReceiptLog(address(this), keeper);
    }

    function test_anchorOncePerJob() public {
        vm.expectEmit(address(receipts));
        emit SapperReceiptLog.ReceiptRootAnchored(JOB, ROOT, 12);
        vm.prank(keeper);
        receipts.anchor(JOB, ROOT, 12);

        SapperReceiptLog.Anchor memory a = receipts.anchorOf(JOB);
        assertEq(a.root, ROOT);
        assertEq(a.steps, 12);
        assertEq(a.anchoredAt, block.timestamp);

        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SapperReceiptLog.AlreadyAnchored.selector, JOB));
        receipts.anchor(JOB, keccak256("other"), 3);
    }

    function test_keeperOnly() public {
        vm.expectRevert(SapperReceiptLog.NotKeeper.selector);
        receipts.anchor(JOB, ROOT, 1);

        vm.prank(keeper);
        vm.expectRevert(SapperReceiptLog.ZeroRoot.selector);
        receipts.anchor(JOB, bytes32(0), 1);

        address next = makeAddr("next");
        receipts.setKeeper(next);
        vm.prank(keeper);
        vm.expectRevert(SapperReceiptLog.NotKeeper.selector);
        receipts.anchor(JOB, ROOT, 1);
        vm.prank(next);
        receipts.anchor(JOB, ROOT, 1);
    }

    function test_setKeeperOwnerOnly() public {
        vm.prank(keeper);
        vm.expectRevert();
        receipts.setKeeper(keeper);
    }
}
