// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "@forge-std/Test.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {GameRewardsDistributor} from "../src/GameRewardsDistributor.sol";
import {ScopedVaultProxy} from "../src/ScopedVaultProxy.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {TellerWithMultiAssetSupport} from "boring-vault/base/Roles/TellerWithMultiAssetSupport.sol";
import {AccountantWithRateProviders} from "boring-vault/base/Roles/AccountantWithRateProviders.sol";
import {DelayedWithdraw} from "boring-vault/base/Roles/DelayedWithdraw.sol";

// ========================= MOCKS =========================

contract MockAToken is ERC20 {
    constructor() ERC20("Aave Base USDC", "aBasUSDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
    function simulateYield(address account, uint256 amount) external { _mint(account, amount); }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH", 18) {}
}

contract MockAavePool {
    MockUSDC public usdc;
    MockAToken public aUsdc;
    constructor(MockUSDC _usdc, MockAToken _aUsdc) { usdc = _usdc; aUsdc = _aUsdc; }
    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        aUsdc.mint(onBehalfOf, amount);
    }
    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        uint256 bal = aUsdc.balanceOf(msg.sender);
        uint256 withdrawAmount = amount == type(uint256).max ? bal : amount;
        aUsdc.burn(msg.sender, withdrawAmount);
        usdc.mint(to, withdrawAmount);
        return withdrawAmount;
    }
}

// ========================= INTEGRATION TESTS =========================

/// @notice Full integration: Teller deposit, Aave supply, game rewards, DelayedWithdraw.
contract IntegrationTest is Test {
    BoringVault vault;
    RolesAuthority auth;
    AccountantWithRateProviders accountant;
    TellerWithMultiAssetSupport teller;
    DelayedWithdraw delayedWithdraw;
    ScopedVaultProxy proxy;
    GameRewardsDistributor distributor;

    MockUSDC usdc;
    MockAToken aUsdc;
    MockWETH weth;
    MockAavePool aavePool;

    address owner = address(0xA);
    address gameMaster = address(0xB);
    address protocolWallet = address(0xC);
    address alice = address(0xD);
    address bob = address(0xE);
    address winner = address(0xF);

    uint8 constant MANAGER_ROLE = 1;
    uint8 constant TELLER_ROLE = 2;
    uint8 constant DELAYED_WITHDRAW_ROLE = 3;
    uint8 constant OWNER_ROLE = 8;
    uint8 constant GAME_MASTER_ROLE = 20;
    uint8 constant DISTRIBUTOR_ROLE = 21;

    uint32 constant WITHDRAW_DELAY = 1 days;
    uint32 constant COMPLETION_WINDOW = 7 days;

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        weth = new MockWETH();
        aavePool = new MockAavePool(usdc, aUsdc);

        auth = new RolesAuthority(owner, Authority(address(0)));
        vault = new BoringVault(owner, "Game Yield Vault", "gyvUSDC", 6);

        vm.startPrank(owner);
        vault.setAuthority(auth);

        // Deploy Accountant
        accountant = new AccountantWithRateProviders(
            owner, address(vault), owner, 1e6, address(usdc), 10_003, 9_997, 3600, 0, 0
        );

        // Deploy Teller
        teller = new TellerWithMultiAssetSupport(owner, address(vault), address(accountant), address(weth));

        // Deploy DelayedWithdraw
        delayedWithdraw = new DelayedWithdraw(owner, address(vault), address(accountant), owner);

        // Deploy ScopedVaultProxy
        proxy = new ScopedVaultProxy(owner, auth, vault, address(usdc), address(aavePool));

        // Deploy GameRewardsDistributor
        distributor = new GameRewardsDistributor(
            owner, auth, vault, ERC20(address(usdc)), ERC20(address(aUsdc)), proxy, protocolWallet
        );

        // Point Veda contracts to shared authority
        teller.setAuthority(auth);
        accountant.setAuthority(auth);
        delayedWithdraw.setAuthority(auth);

        // ========================= PERMISSIONS =========================

        // ScopedVaultProxy -> vault.manage()
        auth.setUserRole(address(proxy), MANAGER_ROLE, true);
        auth.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );

        // Teller -> vault.enter()
        auth.setUserRole(address(teller), TELLER_ROLE, true);
        auth.setRoleCapability(
            TELLER_ROLE, address(vault), bytes4(keccak256("enter(address,address,uint256,address,uint256)")), true
        );

        // DelayedWithdraw -> vault.exit()
        auth.setUserRole(address(delayedWithdraw), DELAYED_WITHDRAW_ROLE, true);
        auth.setRoleCapability(
            DELAYED_WITHDRAW_ROLE, address(vault),
            bytes4(keccak256("exit(address,address,uint256,address,uint256)")), true
        );

        // Distributor -> proxy
        auth.setUserRole(address(distributor), DISTRIBUTOR_ROLE, true);
        auth.setRoleCapability(DISTRIBUTOR_ROLE, address(proxy), ScopedVaultProxy.aaveWithdrawUsdc.selector, true);
        auth.setRoleCapability(DISTRIBUTOR_ROLE, address(proxy), ScopedVaultProxy.vaultTransferUsdc.selector, true);

        // GameMaster -> distributeRewards
        auth.setUserRole(gameMaster, GAME_MASTER_ROLE, true);
        auth.setRoleCapability(
            GAME_MASTER_ROLE, address(distributor), GameRewardsDistributor.distributeRewards.selector, true
        );

        // Owner admin on distributor
        auth.setUserRole(owner, OWNER_ROLE, true);
        auth.setRoleCapability(OWNER_ROLE, address(distributor), GameRewardsDistributor.setProtocolWallet.selector, true);
        auth.setRoleCapability(OWNER_ROLE, address(distributor), GameRewardsDistributor.setFeeSplits.selector, true);
        auth.setRoleCapability(OWNER_ROLE, address(distributor), GameRewardsDistributor.resetCheckpoint.selector, true);
        auth.setRoleCapability(OWNER_ROLE, address(distributor), GameRewardsDistributor.setPaused.selector, true);
        auth.setRoleCapability(OWNER_ROLE, address(distributor), GameRewardsDistributor.adjustCheckpoint.selector, true);

        // Public capabilities
        auth.setPublicCapability(address(teller), TellerWithMultiAssetSupport.deposit.selector, true);
        auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.requestWithdraw.selector, true);
        auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.cancelWithdraw.selector, true);
        auth.setPublicCapability(address(delayedWithdraw), DelayedWithdraw.completeWithdraw.selector, true);

        // Asset configuration
        teller.updateAssetData(ERC20(address(usdc)), true, false, 0);
        vault.setBeforeTransferHook(address(teller));

        // DelayedWithdraw: USDC with 1-day delay
        delayedWithdraw.setupWithdrawAsset(ERC20(address(usdc)), WITHDRAW_DELAY, COMPLETION_WINDOW, 0, 100);
        delayedWithdraw.setPullFundsFromVault(true);

        vm.stopPrank();

        // Seed vault with aUSDC (simulates prior Aave supply) and approve pool
        aUsdc.mint(address(vault), 1_000_000e6);
        vm.prank(address(vault));
        aUsdc.approve(address(aavePool), type(uint256).max);

        // Reset checkpoint after seeding
        vm.prank(owner);
        distributor.resetCheckpoint();

        // Give users USDC
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 5_000e6);
    }

    // ========================= DEPOSIT VIA TELLER =========================

    function test_deposit_viaTeller() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertEq(usdc.balanceOf(address(vault)), 1_000e6);
    }

    // ========================= DELAYED WITHDRAWAL =========================

    function test_delayedWithdraw_fullCycle() public {
        // Alice deposits
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);
        vm.stopPrank();

        // Request withdrawal
        vm.startPrank(alice);
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);

        // Wait 1 day
        vm.warp(block.timestamp + WITHDRAW_DELAY);

        // Complete withdrawal
        vm.prank(alice);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 1_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6); // Original balance restored
    }

    function test_delayedWithdraw_revertsBeforeDelay() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);

        // Try to complete immediately
        vm.expectRevert();
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);
        vm.stopPrank();
    }

    function test_delayedWithdraw_cancelReturnsShares() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        assertEq(vault.balanceOf(alice), 0);

        delayedWithdraw.cancelWithdraw(ERC20(address(usdc)));
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares);
    }

    function test_delayedWithdraw_thirdPartyComplete() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        vm.warp(block.timestamp + WITHDRAW_DELAY);

        // Bob completes Alice's withdrawal
        vm.prank(bob);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 1_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6); // Alice gets USDC
    }

    function test_viewOutstandingDebt() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        uint256 debt = delayedWithdraw.viewOutstandingDebt(ERC20(address(usdc)));
        assertEq(debt, 1_000e6);
    }

    // ========================= GAME + WITHDRAW COMBINED =========================

    function test_gameRewards_thenWithdraw() public {
        // Simulate yield on existing vault aUSDC
        aUsdc.simulateYield(address(vault), 1000e6);

        // GameMaster distributes rewards
        address[] memory winners = new address[](1);
        uint256[] memory bps = new uint256[](1);
        winners[0] = winner;
        bps[0] = 10_000;
        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        // Winner got 80%, protocol got 10%
        assertEq(usdc.balanceOf(winner), 800e6);
        assertEq(usdc.balanceOf(protocolWallet), 100e6);

        // Alice deposits fresh USDC
        vm.startPrank(alice);
        usdc.approve(address(vault), 2_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 2_000e6, 0);
        vm.stopPrank();

        // Alice requests withdrawal
        vm.startPrank(alice);
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        // Wait 1 day
        vm.warp(block.timestamp + WITHDRAW_DELAY);

        // Alice completes
        vm.prank(alice);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 2_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6); // 10000 - 2000 + 2000 back
    }

    function test_multipleDepositors_withdraw() public {
        // Both deposit
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        uint256 aliceShares = teller.deposit(ERC20(address(usdc)), 5_000e6, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 3_000e6);
        uint256 bobShares = teller.deposit(ERC20(address(usdc)), 3_000e6, 0);
        vm.stopPrank();

        // Both request withdrawal
        vm.startPrank(alice);
        vault.approve(address(delayedWithdraw), aliceShares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(aliceShares), 100, true);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.approve(address(delayedWithdraw), bobShares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(bobShares), 100, true);
        vm.stopPrank();

        // Check outstanding debt
        uint256 debt = delayedWithdraw.viewOutstandingDebt(ERC20(address(usdc)));
        assertEq(debt, 8_000e6);

        // Wait and complete
        vm.warp(block.timestamp + WITHDRAW_DELAY);

        vm.prank(alice);
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);
        assertEq(usdc.balanceOf(alice), 10_000e6);

        vm.prank(bob);
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), bob);
        assertEq(usdc.balanceOf(bob), 5_000e6);
    }
}
