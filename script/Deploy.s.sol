// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {SapperScope} from "../src/SapperScope.sol";
import {SapperBurnBuffer} from "../src/SapperBurnBuffer.sol";
import {SapperBountyPot} from "../src/SapperBountyPot.sol";
import {SapperCheckerNet} from "../src/SapperCheckerNet.sol";
import {SapperValidationRegistry} from "../src/SapperValidationRegistry.sol";
import {SapperSettlementGate} from "../src/SapperSettlementGate.sol";
import {SapperReceiptLog} from "../src/SapperReceiptLog.sol";

/// @notice Deploys the full set and writes deployments/<chainId>.json.
/// Required env: USDG, TREASURY, KEEPER, GUARDIAN, RESOLVER, IDENTITY_REGISTRY.
/// Optional env: CONTROL_ATTESTER (0 disables remote opt-in), STAKE_TOKEN (defaults to USDG),
/// MIN_STAKE (atomic units, default 100e6), RATING_WINDOW (seconds, default 7 days, at most
/// 30 days), OWNER (receives a two-step ownership offer).
contract Deploy is Script {
    struct Deployment {
        address deployer;
        address scope;
        address burnBuffer;
        address pot;
        address checkerNet;
        address validation;
        address gate;
        address receiptLog;
    }

    struct Config {
        address usdg;
        address treasury;
        address keeper;
        address guardian;
        address resolver;
        address identity;
        address attester;
        address stakeToken;
        uint256 minStake;
        uint64 ratingWindow;
        address owner;
    }

    function run() external returns (Deployment memory d) {
        Config memory c = _config();

        vm.startBroadcast();
        (, d.deployer,) = vm.readCallers();
        d.scope = address(new SapperScope(d.deployer, c.attester));
        d.burnBuffer = address(new SapperBurnBuffer(d.deployer));
        d.pot = address(new SapperBountyPot(c.usdg, c.treasury, d.burnBuffer, d.deployer));
        d.checkerNet = address(new SapperCheckerNet(c.stakeToken, c.treasury, c.minStake, d.deployer));
        d.validation = address(new SapperValidationRegistry(c.identity));
        d.gate = address(
            new SapperSettlementGate(
                d.scope, d.pot, d.checkerNet, d.validation, c.keeper, c.guardian, c.resolver, d.deployer
            )
        );
        d.receiptLog = address(new SapperReceiptLog(d.deployer, c.keeper));
        SapperBountyPot(d.pot).setGate(d.gate);
        SapperCheckerNet(d.checkerNet).setGate(d.gate);
        if (c.ratingWindow != 0) SapperSettlementGate(d.gate).setRatingWindow(c.ratingWindow);

        if (c.owner != address(0) && c.owner != d.deployer) {
            address[6] memory owned = [d.scope, d.burnBuffer, d.pot, d.checkerNet, d.gate, d.receiptLog];
            for (uint256 i; i < owned.length; ++i) {
                Ownable2Step(owned[i]).transferOwnership(c.owner);
            }
        }
        vm.stopBroadcast();

        _write(c, d);
    }

    function _config() private view returns (Config memory c) {
        c.usdg = vm.envAddress("USDG");
        c.treasury = vm.envAddress("TREASURY");
        c.keeper = vm.envAddress("KEEPER");
        c.guardian = vm.envAddress("GUARDIAN");
        c.resolver = vm.envAddress("RESOLVER");
        c.identity = vm.envAddress("IDENTITY_REGISTRY");
        c.attester = vm.envOr("CONTROL_ATTESTER", address(0));
        c.stakeToken = vm.envOr("STAKE_TOKEN", c.usdg);
        c.minStake = vm.envOr("MIN_STAKE", uint256(100e6));
        c.ratingWindow = uint64(vm.envOr("RATING_WINDOW", uint256(0)));
        c.owner = vm.envOr("OWNER", address(0));
    }

    function _write(Config memory c, Deployment memory d) private {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "block", block.number);
        vm.serializeAddress(k, "deployer", d.deployer);
        vm.serializeAddress(k, "pendingOwner", c.owner);
        vm.serializeAddress(k, "usdg", c.usdg);
        vm.serializeAddress(k, "stakeToken", c.stakeToken);
        vm.serializeUint(k, "minStake", c.minStake);
        vm.serializeAddress(k, "treasury", c.treasury);
        vm.serializeAddress(k, "keeper", c.keeper);
        vm.serializeAddress(k, "guardian", c.guardian);
        vm.serializeAddress(k, "disputeResolver", c.resolver);
        vm.serializeAddress(k, "controlAttester", c.attester);
        vm.serializeAddress(k, "identityRegistry", c.identity);
        SapperSettlementGate gate = SapperSettlementGate(d.gate);
        vm.serializeUint(k, "ratingWindow", gate.ratingWindow());
        vm.serializeUint(k, "reviewWindow", gate.reviewWindow());
        vm.serializeUint(k, "settleGrace", gate.settleGrace());
        vm.serializeAddress(k, "SapperScope", d.scope);
        vm.serializeAddress(k, "SapperBurnBuffer", d.burnBuffer);
        vm.serializeAddress(k, "SapperBountyPot", d.pot);
        vm.serializeAddress(k, "SapperCheckerNet", d.checkerNet);
        vm.serializeAddress(k, "SapperValidationRegistry", d.validation);
        vm.serializeAddress(k, "SapperSettlementGate", d.gate);
        string memory json = vm.serializeAddress(k, "SapperReceiptLog", d.receiptLog);
        string memory dir = string.concat(vm.projectRoot(), "/deployments");
        vm.createDir(dir, true);
        vm.writeJson(json, string.concat(dir, "/", vm.toString(block.chainid), ".json"));
    }
}
