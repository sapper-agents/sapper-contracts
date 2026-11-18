// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SapperBountyPot} from "../../src/SapperBountyPot.sol";
import {SapperValidationRegistry} from "../../src/SapperValidationRegistry.sol";

/// Runs only when RH_RPC_URL is set. Deploys directly rather than through the deploy script,
/// so it never writes a deployments/4663.json.
contract RobinhoodForkTest is Test {
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant IDENTITY = 0x8004A169FB4a3325136EB29fA0ceB6D2e539a432;
    uint256 constant CLIENT_KEY = 0xC11E;

    bool live;

    modifier onFork() {
        if (!live) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory url = vm.envOr("RH_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        vm.createSelectFork(url);
        live = true;
    }

    function test_usdgAndIdentityMatchAssumptions() public onFork {
        assertEq(block.chainid, 4663);
        assertEq(IERC20Metadata(USDG).decimals(), 6);
        assertTrue(IERC20Permit(USDG).DOMAIN_SEPARATOR() != bytes32(0));
        assertGt(IDENTITY.code.length, 0);
        assertEq(address(new SapperValidationRegistry(IDENTITY)).code.length > 0, true);
    }

    function test_fundWithPermitAndWithdrawRealUsdg() public onFork {
        address client = vm.addr(CLIENT_KEY);
        SapperBountyPot pot = new SapperBountyPot(USDG, makeAddr("treasury"), makeAddr("burn"), address(this));
        deal(USDG, client, 1_000e6);

        uint256 deadline = block.timestamp + 1 hours;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"),
                client,
                address(pot),
                1_000e6,
                IERC20Permit(USDG).nonces(client),
                deadline
            )
        );
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(CLIENT_KEY, keccak256(abi.encodePacked("\x19\x01", IERC20Permit(USDG).DOMAIN_SEPARATOR(), structHash)));

        vm.startPrank(client);
        pot.fundWithPermit(1_000e6, deadline, v, r, s);
        assertEq(pot.unlockedBalance(client), 1_000e6);
        pot.withdraw(1_000e6);
        vm.stopPrank();
        assertEq(IERC20Metadata(USDG).balanceOf(client), 1_000e6);
    }
}
