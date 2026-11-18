// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SapperScope} from "../src/SapperScope.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {SapperCheckerNet} from "../src/SapperCheckerNet.sol";
import {SapperSettlementGate} from "../src/SapperSettlementGate.sol";
import {SapperValidationRegistry} from "../src/SapperValidationRegistry.sol";
import {SapperReceiptLog} from "../src/SapperReceiptLog.sol";
import {MockUSDG, MockIdentity} from "./mocks/Mocks.sol";

contract DeployTest is Test {
    address usdg;
    address identity;
    address treasury = makeAddr("treasury");
    address keeper = makeAddr("keeper");
    address guardian = makeAddr("guardian");
    address resolver = makeAddr("resolver");
    address safe = makeAddr("safe");

    function setUp() public {
        usdg = address(new MockUSDG());
        identity = address(new MockIdentity());
        vm.setEnv("USDG", vm.toString(usdg));
        vm.setEnv("TREASURY", vm.toString(treasury));
        vm.setEnv("KEEPER", vm.toString(keeper));
        vm.setEnv("GUARDIAN", vm.toString(guardian));
        vm.setEnv("RESOLVER", vm.toString(resolver));
        vm.setEnv("IDENTITY_REGISTRY", vm.toString(identity));
        vm.setEnv("OWNER", vm.toString(safe));
    }

    function test_deploysAndWiresEverything() public {
        Deploy.Deployment memory d = new Deploy().run();

        SapperSettlementGate gate = SapperSettlementGate(d.gate);
        assertEq(address(gate.scope()), d.scope);
        assertEq(address(gate.pot()), d.pot);
        assertEq(address(gate.checkerNet()), d.checkerNet);
        assertEq(address(gate.validation()), d.validation);
        assertEq(gate.keeper(), keeper);
        assertEq(gate.guardian(), guardian);
        assertEq(gate.disputeResolver(), resolver);
        assertEq(gate.ratingWindow(), 7 days);

        SapperBountyPot pot = SapperBountyPot(d.pot);
        assertEq(address(pot.gate()), d.gate);
        assertEq(address(pot.token()), usdg);
        assertEq(pot.treasury(), treasury);
        assertEq(pot.burnBuffer(), d.burnBuffer);

        SapperCheckerNet net = SapperCheckerNet(d.checkerNet);
        assertEq(address(net.gate()), d.gate);
        assertEq(address(net.stakeToken()), usdg);
        assertEq(net.minStake(), 100e6);

        assertEq(SapperValidationRegistry(d.validation).getIdentityRegistry(), identity);
        assertEq(SapperReceiptLog(d.receiptLog).keeper(), keeper);
        assertEq(SapperScope(d.scope).controlAttester(), address(0));

        assertEq(gate.owner(), d.deployer);
        assertEq(gate.pendingOwner(), safe);
        assertEq(pot.pendingOwner(), safe);
        assertEq(net.pendingOwner(), safe);

        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/31337.json"));
        assertEq(vm.parseJsonAddress(json, ".SapperSettlementGate"), d.gate);
        assertEq(vm.parseJsonAddress(json, ".SapperBountyPot"), d.pot);
        assertEq(vm.parseJsonUint(json, ".chainId"), 31337);
        assertEq(vm.parseJsonUint(json, ".ratingWindow"), 7 days);
        assertEq(vm.parseJsonUint(json, ".settleGrace"), 14 days);

        vm.setEnv("RATING_WINDOW", vm.toString(uint256(2 days)));
        Deploy.Deployment memory e = new Deploy().run();
        assertEq(SapperSettlementGate(e.gate).ratingWindow(), 2 days);
        json = vm.readFile(string.concat(vm.projectRoot(), "/deployments/31337.json"));
        assertEq(vm.parseJsonUint(json, ".ratingWindow"), 2 days);
    }
}
