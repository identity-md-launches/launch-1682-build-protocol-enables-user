// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {SwarmExit} from "../src/SwarmExit.sol";

/// @notice Reviewable deployment of SwarmExit. The IMD launch deploys from bytecode through its
/// factory with `$owner`; this script is for rehearsals on a fork or a local chain.
contract DeployScript is Script {
    /// @notice Owner from the launch terms.
    address public constant OWNER = 0x0acE1DBE8AAb293cd58D5e3Ea38814f0ccb74782;

    function deploy(address owner) public returns (SwarmExit exit) {
        exit = new SwarmExit(owner);
    }

    function run() external returns (SwarmExit exit) {
        vm.startBroadcast();
        exit = deploy(OWNER);
        vm.stopBroadcast();
    }
}
