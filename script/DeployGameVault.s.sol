// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console} from "@forge-std/Script.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {ScopedVaultProxy} from "../src/ScopedVaultProxy.sol";
import {GameRewardsDistributor} from "../src/GameRewardsDistributor.sol";

/// @title DeployGameVault
/// @notice Deploys the BoringVault + ScopedVaultProxy + GameRewardsDistributor
///         system on Base. The Teller, Accountant, and Manager are expected to
///         be deployed separately via Veda's standard Arctic Architecture tooling.
contract DeployGameVault is Script {
    // ========================= BASE ADDRESSES =========================

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;

    // ========================= ROLE IDs =========================
    // Standard Boring Vault roles
    uint8 constant MANAGER_ROLE = 1;
    uint8 constant OWNER_ROLE = 8;
    // Custom roles
    uint8 constant GAME_MASTER_ROLE = 20;
    uint8 constant DISTRIBUTOR_ROLE = 21;

    function run() external {
        address deployer = msg.sender;

        address owner = vm.envOr("OWNER", deployer);
        address protocolWallet = vm.envOr("PROTOCOL_WALLET", deployer);
        address gameMaster = vm.envOr("GAME_MASTER", deployer);

        vm.startBroadcast();

        // 1. Deploy RolesAuthority (deployer is initial owner, transferred later)
        RolesAuthority rolesAuthority = new RolesAuthority(deployer, Authority(address(0)));
        console.log("RolesAuthority:", address(rolesAuthority));

        // 2. Deploy BoringVault (deployer is initial owner so we can setAuthority)
        BoringVault vault = new BoringVault(deployer, "Game Yield Vault", "gyvUSDC", 6);
        console.log("BoringVault:", address(vault));

        // 3. Set vault authority (deployer is owner, so this works)
        vault.setAuthority(rolesAuthority);

        // 4. Deploy ScopedVaultProxy
        ScopedVaultProxy proxy = new ScopedVaultProxy(
            owner, rolesAuthority, vault, USDC, AAVE_V3_POOL
        );
        console.log("ScopedVaultProxy:", address(proxy));

        // 5. Deploy GameRewardsDistributor
        GameRewardsDistributor distributor = new GameRewardsDistributor(
            owner,
            rolesAuthority,
            vault,
            ERC20(USDC),
            ERC20(A_BAS_USDC),
            proxy,
            protocolWallet
        );
        console.log("GameRewardsDistributor:", address(distributor));

        // ========================= ROLE CONFIGURATION =========================

        // --- ScopedVaultProxy gets MANAGER_ROLE on the vault ---
        // This is the ONLY contract with vault.manage() access for rewards.
        rolesAuthority.setUserRole(address(proxy), MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")),
            true
        );

        // --- Distributor gets DISTRIBUTOR_ROLE on the proxy ---
        // Only the distributor can call the proxy's scoped functions.
        rolesAuthority.setUserRole(address(distributor), DISTRIBUTOR_ROLE, true);
        rolesAuthority.setRoleCapability(
            DISTRIBUTOR_ROLE,
            address(proxy),
            ScopedVaultProxy.aaveWithdrawUsdc.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            DISTRIBUTOR_ROLE,
            address(proxy),
            ScopedVaultProxy.vaultTransferUsdc.selector,
            true
        );

        // --- GameMaster can call distributeRewards ---
        rolesAuthority.setUserRole(gameMaster, GAME_MASTER_ROLE, true);
        rolesAuthority.setRoleCapability(
            GAME_MASTER_ROLE,
            address(distributor),
            GameRewardsDistributor.distributeRewards.selector,
            true
        );
        console.log("GameMaster role granted to:", gameMaster);

        // --- Owner can call admin functions on the distributor ---
        rolesAuthority.setUserRole(owner, OWNER_ROLE, true);
        rolesAuthority.setRoleCapability(
            OWNER_ROLE,
            address(distributor),
            GameRewardsDistributor.setProtocolWallet.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE,
            address(distributor),
            GameRewardsDistributor.setFeeSplits.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE,
            address(distributor),
            GameRewardsDistributor.resetCheckpoint.selector,
            true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE,
            address(distributor),
            GameRewardsDistributor.setPaused.selector,
            true
        );

        // --- Transfer vault ownership from deployer to owner ---
        vault.transferOwnership(owner);

        // --- Transfer RolesAuthority ownership from deployer to owner ---
        rolesAuthority.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Owner:", owner);
        console.log("Protocol Wallet:", protocolWallet);
        console.log("Game Master:", gameMaster);
        console.log("");
        console.log("Access chain: GameMaster -> Distributor -> ScopedProxy -> Vault");
        console.log("The proxy can ONLY withdraw USDC from Aave and transfer USDC.");
        console.log("");
        console.log("Next steps:");
        console.log("1. Deploy Teller, Accountant, Manager via Veda Arctic Architecture");
        console.log("2. Configure Teller to accept USDC deposits");
        console.log("3. Set Merkle root on Manager to allow Aave supply/withdraw");
        console.log("4. Strategist supplies vault USDC to Aave");
    }
}
