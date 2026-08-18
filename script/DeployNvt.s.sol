// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {Nvt} from "../src/Nvt.sol";

contract DeployNvt is Script {
    function run() external returns (Nvt) {
        // Endereços vêm do ambiente — nunca hardcode (admin é multisig, vault é cofre).
        address admin = vm.envAddress("NVT_ADMIN");
        address recoveryVault = vm.envAddress("NVT_RECOVERY_VAULT");

        vm.startBroadcast();
        Nvt nvt = new Nvt(admin, recoveryVault);
        vm.stopBroadcast();

        return nvt;
    }
}
