// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Script, console} from "@forge-std/Script.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {TellerWithMultiAssetSupport} from "boring-vault/base/Roles/TellerWithMultiAssetSupport.sol";
import {AccountantWithRateProviders} from "boring-vault/base/Roles/AccountantWithRateProviders.sol";
import {DelayedWithdraw} from "boring-vault/base/Roles/DelayedWithdraw.sol";
import {ScopedVaultProxy} from "../src/ScopedVaultProxy.sol";
import {GameRewardsDistributor} from "../src/GameRewardsDistributor.sol";

/// @title DeployGameVault
/// @notice Deploys the full ClawTogether game vault system on Base:
///         BoringVault + Accountant + Teller + DelayedWithdraw +
///         ScopedVaultProxy + GameRewardsDistributor.
contract DeployGameVault is Script {
    // ========================= BASE ADDRESSES =========================

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // ========================= ROLE IDs =========================

    uint8 constant MANAGER_ROLE = 1;          // ScopedVaultProxy -> vault.manage()
    uint8 constant TELLER_ROLE = 2;           // Teller -> vault.enter()
    uint8 constant DELAYED_WITHDRAW_ROLE = 3; // DelayedWithdraw -> vault.exit()
    uint8 constant OWNER_ROLE = 8;            // Owner admin functions
    uint8 constant GAME_MASTER_ROLE = 20;     // GameMaster -> distributeRewards
    uint8 constant DISTRIBUTOR_ROLE = 21;     // Distributor -> proxy scoped calls

    // ========================= CONFIGURATION =========================

    uint32 constant WITHDRAW_DELAY = 1 days;
    uint32 constant COMPLETION_WINDOW = 7 days;
    uint16 constant WITHDRAW_FEE = 0;
    uint16 constant MAX_LOSS = 100;           // 1% max slippage

    // Accountant config
    uint96 constant STARTING_EXCHANGE_RATE = 1e6;  // 1:1 for 6-decimal USDC
    uint16 constant ALLOWED_RATE_CHANGE_UPPER = 10_003;
    uint16 constant ALLOWED_RATE_CHANGE_LOWER = 9_997;
    uint24 constant MIN_UPDATE_DELAY = 3600;
    uint16 constant PLATFORM_FEE = 0;
    uint16 constant PERFORMANCE_FEE = 0;

    function run() external {
        address deployer = msg.sender;

        address owner = vm.envOr("OWNER", deployer);
        address protocolWallet = vm.envOr("PROTOCOL_WALLET", deployer);
        address gameMaster = vm.envOr("GAME_MASTER", deployer);

        vm.startBroadcast();

        // 1. Deploy RolesAuthority
        RolesAuthority rolesAuthority = new RolesAuthority(deployer, Authority(address(0)));
        console.log("RolesAuthority:", address(rolesAuthority));

        // 2. Deploy BoringVault
        BoringVault vault = new BoringVault(deployer, "Game Yield Vault", "gyvUSDC", 6);
        console.log("BoringVault:", address(vault));
        vault.setAuthority(rolesAuthority);

        // 3. Deploy AccountantWithRateProviders
        AccountantWithRateProviders accountant = new AccountantWithRateProviders(
            deployer,
            address(vault),
            owner,
            STARTING_EXCHANGE_RATE,
            address(USDC),
            ALLOWED_RATE_CHANGE_UPPER,
            ALLOWED_RATE_CHANGE_LOWER,
            MIN_UPDATE_DELAY,
            PLATFORM_FEE,
            PERFORMANCE_FEE
        );
        console.log("Accountant:", address(accountant));

        // 4. Deploy TellerWithMultiAssetSupport
        TellerWithMultiAssetSupport teller = new TellerWithMultiAssetSupport(
            deployer,
            address(vault),
            address(accountant),
            WETH
        );
        console.log("Teller:", address(teller));

        // 5. Deploy DelayedWithdraw
        DelayedWithdraw delayedWithdraw = new DelayedWithdraw(
            deployer,
            address(vault),
            address(accountant),
            owner
        );
        console.log("DelayedWithdraw:", address(delayedWithdraw));

        // 6. Deploy ScopedVaultProxy
        ScopedVaultProxy proxy = new ScopedVaultProxy(
            owner, rolesAuthority, vault, USDC, AAVE_V3_POOL
        );
        console.log("ScopedVaultProxy:", address(proxy));

        // 7. Deploy GameRewardsDistributor
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

        // 8. Point Veda contracts to shared RolesAuthority
        teller.setAuthority(rolesAuthority);
        accountant.setAuthority(rolesAuthority);
        delayedWithdraw.setAuthority(rolesAuthority);

        // ========================= VAULT PERMISSIONS =========================

        // ScopedVaultProxy -> vault.manage()
        rolesAuthority.setUserRole(address(proxy), MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE,
            address(vault),
            bytes4(keccak256("manage(address,bytes,uint256)")),
            true
        );

        // Teller -> vault.enter()
        rolesAuthority.setUserRole(address(teller), TELLER_ROLE, true);
        rolesAuthority.setRoleCapability(
            TELLER_ROLE,
            address(vault),
            bytes4(keccak256("enter(address,address,uint256,address,uint256)")),
            true
        );

        // DelayedWithdraw -> vault.exit()
        rolesAuthority.setUserRole(address(delayedWithdraw), DELAYED_WITHDRAW_ROLE, true);
        rolesAuthority.setRoleCapability(
            DELAYED_WITHDRAW_ROLE,
            address(vault),
            bytes4(keccak256("exit(address,address,uint256,address,uint256)")),
            true
        );

        // ========================= GAME ROLES =========================

        // Distributor -> proxy scoped calls
        rolesAuthority.setUserRole(address(distributor), DISTRIBUTOR_ROLE, true);
        rolesAuthority.setRoleCapability(
            DISTRIBUTOR_ROLE, address(proxy), ScopedVaultProxy.aaveWithdrawUsdc.selector, true
        );
        rolesAuthority.setRoleCapability(
            DISTRIBUTOR_ROLE, address(proxy), ScopedVaultProxy.vaultTransferUsdc.selector, true
        );

        // GameMaster -> distributeRewards
        rolesAuthority.setUserRole(gameMaster, GAME_MASTER_ROLE, true);
        rolesAuthority.setRoleCapability(
            GAME_MASTER_ROLE,
            address(distributor),
            GameRewardsDistributor.distributeRewards.selector,
            true
        );

        // ========================= OWNER ADMIN =========================

        rolesAuthority.setUserRole(owner, OWNER_ROLE, true);
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.setProtocolWallet.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.setFeeSplits.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.resetCheckpoint.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.setPaused.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.adjustCheckpoint.selector, true
        );

        // Owner admin on Teller
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(teller), TellerWithMultiAssetSupport.updateAssetData.selector, true
        );

        // Owner admin on Accountant
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(accountant), AccountantWithRateProviders.updateExchangeRate.selector, true
        );

        // Owner admin on DelayedWithdraw
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(delayedWithdraw), DelayedWithdraw.setupWithdrawAsset.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(delayedWithdraw), DelayedWithdraw.changeWithdrawDelay.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(delayedWithdraw), DelayedWithdraw.changeMaxLoss.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(delayedWithdraw), DelayedWithdraw.pause.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(delayedWithdraw), DelayedWithdraw.unpause.selector, true
        );

        // ========================= PUBLIC CAPABILITIES =========================

        rolesAuthority.setPublicCapability(
            address(teller), TellerWithMultiAssetSupport.deposit.selector, true
        );
        rolesAuthority.setPublicCapability(
            address(delayedWithdraw), DelayedWithdraw.requestWithdraw.selector, true
        );
        rolesAuthority.setPublicCapability(
            address(delayedWithdraw), DelayedWithdraw.cancelWithdraw.selector, true
        );
        rolesAuthority.setPublicCapability(
            address(delayedWithdraw), DelayedWithdraw.completeWithdraw.selector, true
        );

        // ========================= ASSET CONFIGURATION =========================

        // Teller: USDC deposits allowed, no direct withdrawals
        teller.updateAssetData(ERC20(USDC), true, false, 0);

        // Set Teller as vault's beforeTransferHook
        vault.setBeforeTransferHook(address(teller));

        // DelayedWithdraw: USDC with 1-day delay
        delayedWithdraw.setupWithdrawAsset(
            ERC20(USDC), WITHDRAW_DELAY, COMPLETION_WINDOW, WITHDRAW_FEE, MAX_LOSS
        );
        delayedWithdraw.setPullFundsFromVault(true);

        // ========================= TRANSFER OWNERSHIP =========================

        vault.transferOwnership(owner);
        teller.transferOwnership(owner);
        accountant.transferOwnership(owner);
        delayedWithdraw.transferOwnership(owner);
        rolesAuthority.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Owner:", owner);
        console.log("Protocol Wallet:", protocolWallet);
        console.log("Game Master:", gameMaster);
        console.log("");
        console.log("User flow:");
        console.log("  Deposit:  User -> Teller.deposit(USDC) -> vault mints gyvUSDC shares");
        console.log("  Withdraw: User -> DelayedWithdraw.requestWithdraw() -> wait 1 day -> completeWithdraw()");
        console.log("");
        console.log("Game flow:");
        console.log("  GameMaster -> Distributor -> ScopedProxy -> Vault");
    }
}
