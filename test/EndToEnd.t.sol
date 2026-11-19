// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Fixture} from "./Fixture.sol";
import {SapperSettlementGate} from "../src/SapperSettlementGate.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {ISapperBountyPot, Severity} from "../src/interfaces/ISapperBountyPot.sol";
import {OwnedTarget} from "./mocks/Mocks.sol";

contract EndToEndTest is Fixture {
    function test_optInToSettle() public {
        address protocol = makeAddr("protocol");
        address vault = address(new OwnedTarget(protocol));
        bytes32 id = keccak256("vault-finding");

        vm.prank(protocol);
        scope.optIn(vault, chain, ROOT, disclosure, "");
        assertTrue(scope.isInScope(vault, chain));

        usdg.mint(protocol, 20_000e6);
        vm.startPrank(protocol);
        usdg.approve(address(pot), 20_000e6);
        pot.fund(20_000e6);
        pot.setTable(ISapperBountyPot.Table(12_000e6, 3_000e6, 600e6, 0));
        vm.stopPrank();
        assertEq(usdg.balanceOf(protocol), 0);
        assertEq(usdg.balanceOf(address(pot)), 20_000e6);

        vm.prank(keeper);
        gate.claim(id, vault, chain, uint64(block.number), keccak256("bundle"), breaker, agentId, 0);
        address[] memory assigned = net.round(id).assigned;
        assertEq(assigned.length, 3);
        assertEq(pot.lockedBalance(protocol), 12_000e6);
        assertEq(pot.unlockedBalance(protocol), 8_000e6);

        vm.prank(protocol);
        vm.expectRevert(abi.encodeWithSelector(SapperBountyPot.InsufficientUnlocked.selector, 8_000e6, 20_000e6));
        pot.withdraw(20_000e6);

        for (uint256 i; i < 3; ++i) {
            _commit(id, assigned[i], true, RESULT);
        }
        for (uint256 i; i < 3; ++i) {
            _reveal(id, assigned[i], true, RESULT);
        }
        net.finalize(id);
        assertEq(uint8(gate.status(id)), uint8(SapperSettlementGate.Status.Confirmed));

        _rate(id, Severity.Critical, ROOT_CAUSE);
        assertEq(uint8(gate.status(id)), uint8(SapperSettlementGate.Status.Review));
        assertEq(pot.lockedBalance(protocol), 12_000e6);
        assertEq(pot.unlockedBalance(protocol), 8_000e6);

        vm.warp(block.timestamp + 72 hours);
        pot.settle(id);
        assertEq(uint8(gate.status(id)), uint8(SapperSettlementGate.Status.Settled));

        assertEq(pot.earningsOf(breaker), 6_720e6);
        assertEq(pot.earningsOf(fixer), 2_880e6);
        assertEq(pot.earningsOf(treasury), 1_200e6);
        assertEq(pot.earningsOf(address(burn)), 600e6);
        assertEq(pot.lockedBalance(protocol), 0);
        assertEq(pot.unlockedBalance(protocol), 8_000e6);
        assertEq(usdg.balanceOf(address(pot)), 20_000e6);

        _withdrawEarnings(breaker);
        _withdrawEarnings(fixer);
        _withdrawEarnings(treasury);
        vm.prank(owner);
        burn.collect(pot);
        for (uint256 i; i < 3; ++i) {
            _withdrawEarnings(assigned[i]);
        }

        assertEq(usdg.balanceOf(breaker), 6_720e6);
        assertEq(usdg.balanceOf(fixer), 2_880e6);
        assertEq(usdg.balanceOf(treasury), 1_200e6);
        for (uint256 i; i < 3; ++i) {
            assertEq(usdg.balanceOf(assigned[i]), 200e6);
            assertEq(net.checkerOf(assigned[i]).stake, CHECKER_STAKE);
        }
        assertEq(usdg.balanceOf(address(burn)), 600e6);
        assertEq(usdg.balanceOf(address(pot)), 8_000e6);
        assertEq(usdg.balanceOf(address(net)), 3 * CHECKER_STAKE);

        (,, uint8 response,,,) = validation.getValidationStatus(gate.validationRequestOf(id));
        assertEq(response, 100);

        vm.prank(protocol);
        pot.withdraw(8_000e6);
        assertEq(usdg.balanceOf(protocol), 8_000e6);
        assertEq(usdg.balanceOf(address(pot)), 0);
    }

    function _withdrawEarnings(address payee) internal {
        uint256 amount = pot.earningsOf(payee);
        vm.prank(payee);
        pot.withdrawEarnings(amount);
        assertEq(pot.earningsOf(payee), 0);
    }
}
