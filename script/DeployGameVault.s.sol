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
import {ManagerWithMerkleVerification} from "boring-vault/base/Roles/ManagerWithMerkleVerification.sol";
import {ClawTogetherDecoderAndSanitizer} from "../src/ClawTogetherDecoderAndSanitizer.sol";
import {ClawTogetherTeller} from "../src/ClawTogetherTeller.sol";
import {GameRewardsDistributor} from "../src/GameRewardsDistributor.sol";

/// @title DeployGameVault
/// @notice Deploys the full ClawTogether game vault system on Base:
///         BoringVault + Accountant + Teller + DelayedWithdraw +
///         ManagerWithMerkleVerification + Decoder + GameRewardsDistributor.
/// @dev After deployment, the owner must:
///      1. Compute Merkle tree (4 leaves: approve, supply, withdraw, transfer)
///      2. Call manager.setManageRoot(distributor, root)
///      3. Call distributor.setMerkleProofs(...)
contract DeployGameVault is Script {
    // ========================= BASE ADDRESSES =========================

    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;
    address constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // ========================= ROLE IDs =========================

    uint8 constant MANAGER_ROLE = 1;          // Manager -> vault.manage()
    uint8 constant TELLER_ROLE = 2;           // Teller -> vault.enter()
    uint8 constant DELAYED_WITHDRAW_ROLE = 3; // DelayedWithdraw -> vault.exit()
    uint8 constant OWNER_ROLE = 8;            // Owner admin functions
    uint8 constant GAME_MASTER_ROLE = 20;     // GameMaster -> distributeRewards
    uint8 constant STRATEGIST_ROLE = 21;      // Distributor -> manager.manageVaultWithMerkleVerification

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

    // Shared state set during deployment for use across helper functions
    RolesAuthority internal _auth;
    BoringVault internal _vault;
    ManagerWithMerkleVerification internal _manager;
    GameRewardsDistributor internal _distributor;
    address internal _teller;

    function run() external {
        address deployer = msg.sender;
        address owner = vm.envOr("OWNER", deployer);
        address protocolWallet = vm.envOr("PROTOCOL_WALLET", deployer);
        address gameMaster = vm.envOr("GAME_MASTER", deployer);

        vm.startBroadcast();

        _deployCore(deployer, owner);
        _deployVeda(deployer, owner);
        _deployGame(owner, protocolWallet);
        _setupPermissions(owner, gameMaster);

        // Transfer ownership
        _vault.transferOwnership(owner);
        _auth.transferOwnership(owner);
        _manager.transferOwnership(owner);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("Owner:", owner);
        console.log("POST-DEPLOY: Owner must compute Merkle tree and call:");
        console.log("  1. manager.setManageRoot(distributor, merkleRoot)");
        console.log("  2. distributor.setMerkleProofs(approve, supply, withdraw, transfer)");
    }

    function _deployCore(address deployer, address owner) internal {
        _auth = new RolesAuthority(deployer, Authority(address(0)));
        _vault = new BoringVault(deployer, "Game Yield Vault", "clawUSDC", 6);
        _vault.setAuthority(_auth);

        _manager = new ManagerWithMerkleVerification(deployer, address(_vault), address(0));
        _manager.setAuthority(_auth);

        console.log("RolesAuthority:", address(_auth));
        console.log("BoringVault:", address(_vault));
        console.log("Manager:", address(_manager));
    }

    function _deployVeda(address deployer, address owner) internal {
        AccountantWithRateProviders accountant = new AccountantWithRateProviders(
            deployer, address(_vault), owner, STARTING_EXCHANGE_RATE, address(USDC),
            ALLOWED_RATE_CHANGE_UPPER, ALLOWED_RATE_CHANGE_LOWER, MIN_UPDATE_DELAY, PLATFORM_FEE, PERFORMANCE_FEE
        );
        ClawTogetherTeller teller_ = new ClawTogetherTeller(
            deployer, address(_vault), address(accountant), WETH
        );
        _teller = address(teller_);
        DelayedWithdraw delayedWithdraw = new DelayedWithdraw(deployer, address(_vault), address(accountant), owner);

        teller_.setAuthority(_auth);
        accountant.setAuthority(_auth);
        delayedWithdraw.setAuthority(_auth);

        // Teller permissions
        _auth.setUserRole(address(teller_), TELLER_ROLE, true);
        _auth.setRoleCapability(TELLER_ROLE, address(_vault), bytes4(keccak256("enter(address,address,uint256,address,uint256)")), true);
        _auth.setPublicCapability(address(teller_), TellerWithMultiAssetSupport.deposit.selector, true);
        _auth.setPublicCapability(address(teller_), ClawTogetherTeller.depositFor.selector, true);
        teller_.updateAssetData(ERC20(USDC), true, false, 0);
        _vault.setBeforeTransferHook(address(teller_));

        // DelayedWithdraw permissions
        _auth.setUserRole(address(delayedWithdraw), DELAYED_WITHDRAW_ROLE, true);
        _auth.setRoleCapability(DELAYED_WITHDRAW_ROLE, address(_vault), bytes4(keccak256("exit(address,address,uint256,address,uint256)")), true);
        _auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.requestWithdraw.selector, true);
        _auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.cancelWithdraw.selector, true);
        _auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.completeWithdraw.selector, true);
        delayedWithdraw.setupWithdrawAsset(ERC20(USDC), WITHDRAW_DELAY, COMPLETION_WINDOW, WITHDRAW_FEE, MAX_LOSS);
        delayedWithdraw.setPullFundsFromVault(true);

        teller_.transferOwnership(owner);
        accountant.transferOwnership(owner);
        delayedWithdraw.transferOwnership(owner);

        console.log("Accountant:", address(accountant));
        console.log("Teller:", address(teller_));
        console.log("DelayedWithdraw:", address(delayedWithdraw));
    }

    function _deployGame(address owner, address protocolWallet) internal {
        ClawTogetherDecoderAndSanitizer decoder = new ClawTogetherDecoderAndSanitizer(address(_vault));

        _distributor = new GameRewardsDistributor(
            owner, _auth, _vault, ERC20(USDC), ERC20(A_BAS_USDC), _manager, address(decoder), AAVE_V3_POOL, protocolWallet
        );

        console.log("Decoder:", address(decoder));
        console.log("GameRewardsDistributor:", address(_distributor));
    }

    function _setupPermissions(address owner, address gameMaster) internal {
        // Manager -> vault.manage()
        _auth.setUserRole(address(_manager), MANAGER_ROLE, true);
        _auth.setRoleCapability(MANAGER_ROLE, address(_vault), bytes4(keccak256("manage(address,bytes,uint256)")), true);

        // Distributor -> manager
        _auth.setUserRole(address(_distributor), STRATEGIST_ROLE, true);
        _auth.setRoleCapability(STRATEGIST_ROLE, address(_manager), ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector, true);

        // GameMaster -> distributeRewards, supplyAndCheckpoint, withdrawAndCheckpoint
        _auth.setUserRole(gameMaster, GAME_MASTER_ROLE, true);
        _auth.setRoleCapability(GAME_MASTER_ROLE, address(_distributor), GameRewardsDistributor.distributeRewards.selector, true);
        _auth.setRoleCapability(GAME_MASTER_ROLE, address(_distributor), GameRewardsDistributor.supplyAndCheckpoint.selector, true);
        _auth.setRoleCapability(GAME_MASTER_ROLE, address(_distributor), GameRewardsDistributor.withdrawAndCheckpoint.selector, true);
        _auth.setRoleCapability(GAME_MASTER_ROLE, address(_distributor), GameRewardsDistributor.resetCheckpoint.selector, true);

        // Owner admin
        _auth.setUserRole(owner, OWNER_ROLE, true);
        _auth.setRoleCapability(OWNER_ROLE, address(_distributor), GameRewardsDistributor.setProtocolWallet.selector, true);
        _auth.setRoleCapability(OWNER_ROLE, address(_distributor), GameRewardsDistributor.setFeeSplits.selector, true);
        _auth.setRoleCapability(OWNER_ROLE, address(_distributor), GameRewardsDistributor.setPaused.selector, true);
        _auth.setRoleCapability(OWNER_ROLE, address(_distributor), GameRewardsDistributor.adjustCheckpoint.selector, true);
        _auth.setRoleCapability(OWNER_ROLE, address(_distributor), GameRewardsDistributor.setMerkleProofs.selector, true);
    }
}
