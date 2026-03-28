// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "@forge-std/Test.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {GameRewardsDistributor} from "../src/GameRewardsDistributor.sol";
import {ScopedVaultProxy} from "../src/ScopedVaultProxy.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

// ========================= MOCKS =========================

contract MockAToken is ERC20 {
    constructor() ERC20("Aave Base USDC", "aBasUSDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function simulateYield(address account, uint256 amount) external { _mint(account, amount); }
    function burn(address from, uint256 amount) external { _burn(from, amount); }
}

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

// Mock Aave Pool. Burns aUSDC from caller, mints USDC to recipient.
contract MockAavePool {
    MockUSDC public usdc;
    MockAToken public aUsdc;
    constructor(MockUSDC _usdc, MockAToken _aUsdc) { usdc = _usdc; aUsdc = _aUsdc; }
    function supply(address, uint256 amount, address onBehalfOf, uint16) external {
        usdc.transferFrom(msg.sender, address(this), amount);
        aUsdc.mint(onBehalfOf, amount);
    }
    function withdraw(address, uint256 amount, address to) external returns (uint256) {
        aUsdc.transferFrom(msg.sender, address(0xdead), amount);
        usdc.mint(to, amount);
        return amount;
    }
}

// ========================= TESTS =========================

contract GameRewardsDistributorTest is Test {
    event RewardsDistributed(
        address[] winners, uint256[] winnerAmounts, uint256 protocolAmount, uint256 vaultAmount, uint256 totalYield
    );
    event PauseToggled(bool isPaused);
    event FeeSplitsUpdated(uint256 protocolBps, uint256 vaultBps);
    event CheckpointUpdated(uint256 oldCheckpoint, uint256 newCheckpoint);

    BoringVault vault;
    RolesAuthority rolesAuthority;
    ScopedVaultProxy proxy;
    GameRewardsDistributor distributor;
    MockUSDC usdc;
    MockAToken aUsdc;
    MockAavePool aavePool;

    address owner = address(0xA);
    address gameMaster = address(0xB);
    address protocolWallet = address(0xC);
    address winner = address(0xD);

    uint8 constant MANAGER_ROLE = 1;
    uint8 constant OWNER_ROLE = 8;
    uint8 constant GAME_MASTER_ROLE = 20;
    uint8 constant DISTRIBUTOR_ROLE = 21;

    // Helpers to build single-winner arrays
    function _single(address w) internal pure returns (address[] memory winners, uint256[] memory bps) {
        winners = new address[](1);
        bps = new uint256[](1);
        winners[0] = w;
        bps[0] = 10_000;
    }

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        aavePool = new MockAavePool(usdc, aUsdc);

        rolesAuthority = new RolesAuthority(owner, Authority(address(0)));
        vault = new BoringVault(owner, "Game Yield Vault", "gyvUSDC", 6);

        vm.prank(owner);
        vault.setAuthority(rolesAuthority);

        proxy = new ScopedVaultProxy(owner, rolesAuthority, vault, address(usdc), address(aavePool));

        distributor = new GameRewardsDistributor(
            owner, rolesAuthority, vault, ERC20(address(usdc)), ERC20(address(aUsdc)), proxy, protocolWallet
        );

        vm.startPrank(owner);

        // Proxy gets MANAGER_ROLE on vault
        rolesAuthority.setUserRole(address(proxy), MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );

        // Distributor gets DISTRIBUTOR_ROLE on proxy
        rolesAuthority.setUserRole(address(distributor), DISTRIBUTOR_ROLE, true);
        rolesAuthority.setRoleCapability(
            DISTRIBUTOR_ROLE, address(proxy), ScopedVaultProxy.aaveWithdrawUsdc.selector, true
        );
        rolesAuthority.setRoleCapability(
            DISTRIBUTOR_ROLE, address(proxy), ScopedVaultProxy.vaultTransferUsdc.selector, true
        );

        // Game master can call distributeRewards
        rolesAuthority.setUserRole(gameMaster, GAME_MASTER_ROLE, true);
        rolesAuthority.setRoleCapability(
            GAME_MASTER_ROLE, address(distributor), GameRewardsDistributor.distributeRewards.selector, true
        );

        // Owner admin functions
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

        vm.stopPrank();

        // Seed the vault with aUSDC and approve the pool
        aUsdc.mint(address(vault), 1_000_000e6);
        vm.prank(address(vault));
        aUsdc.approve(address(aavePool), type(uint256).max);

        // Reset checkpoint after seeding
        vm.prank(owner);
        distributor.resetCheckpoint();
    }

    // ========================= SINGLE WINNER (backward compat) =========================

    function test_distributeRewards_singleWinner() public {
        aUsdc.simulateYield(address(vault), 1000e6);
        assertEq(distributor.pendingYield(), 1000e6);

        (address[] memory winners, uint256[] memory bps) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        assertEq(usdc.balanceOf(winner), 800e6);
        assertEq(usdc.balanceOf(protocolWallet), 100e6);
        assertEq(distributor.pendingYield(), 0);
    }

    function test_distributeRewards_customSplits() public {
        vm.prank(owner);
        distributor.setFeeSplits(2_000, 500);

        aUsdc.simulateYield(address(vault), 1000e6);

        (address[] memory winners, uint256[] memory bps) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        assertEq(usdc.balanceOf(winner), 750e6);
        assertEq(usdc.balanceOf(protocolWallet), 200e6);
    }

    // ========================= MULTI-WINNER =========================

    function test_distributeRewards_twoWinners() public {
        aUsdc.simulateYield(address(vault), 1000e6);

        address winner2 = address(0xE);
        address[] memory winners = new address[](2);
        uint256[] memory bps = new uint256[](2);
        winners[0] = winner;
        winners[1] = winner2;
        bps[0] = 7_000; // 70% of winner share
        bps[1] = 3_000; // 30% of winner share

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        // Winner share is 80% of 1000 = 800
        // winner gets 70% of 800 = 560
        // winner2 gets 30% of 800 = 240
        assertEq(usdc.balanceOf(winner), 560e6);
        assertEq(usdc.balanceOf(winner2), 240e6);
        assertEq(usdc.balanceOf(protocolWallet), 100e6);
    }

    function test_distributeRewards_threeWinners_equalSplit() public {
        aUsdc.simulateYield(address(vault), 900e6);

        address winner2 = address(0xE);
        address winner3 = address(0xF);
        address[] memory winners = new address[](3);
        uint256[] memory bps = new uint256[](3);
        winners[0] = winner;
        winners[1] = winner2;
        winners[2] = winner3;
        // ~33.33% each
        bps[0] = 3_334;
        bps[1] = 3_333;
        bps[2] = 3_333;

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        // Winner share = 80% of 900 = 720
        // winner:  720 * 3334 / 10000 = 240.048 -> 240048000 (240.048e6)
        // winner2: 720 * 3333 / 10000 = 239.976 -> 239976000 (239.976e6)
        // winner3: gets remainder = 720 - 240.048 - 239.976 = 239.976
        uint256 w1 = usdc.balanceOf(winner);
        uint256 w2 = usdc.balanceOf(winner2);
        uint256 w3 = usdc.balanceOf(winner3);

        assertEq(w1 + w2 + w3, 720e6);
        assertGt(w1, 0);
        assertGt(w2, 0);
        assertGt(w3, 0);
    }

    function test_distributeRewards_tenWinners() public {
        aUsdc.simulateYield(address(vault), 10_000e6);

        address[] memory winners = new address[](10);
        uint256[] memory bps = new uint256[](10);
        for (uint256 i; i < 10; i++) {
            winners[i] = address(uint160(0x100 + i));
            bps[i] = 1_000; // 10% each
        }

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        // Winner share = 80% of 10000 = 8000, each gets 800
        uint256 totalDistributed;
        for (uint256 i; i < 10; i++) {
            totalDistributed += usdc.balanceOf(winners[i]);
        }
        assertEq(totalDistributed, 8_000e6);
        assertEq(usdc.balanceOf(protocolWallet), 1_000e6);
    }

    function test_revert_elevenWinners() public {
        aUsdc.simulateYield(address(vault), 1000e6);

        address[] memory winners = new address[](11);
        uint256[] memory bps = new uint256[](11);
        for (uint256 i; i < 11; i++) {
            winners[i] = address(uint160(0x100 + i));
            bps[i] = 909;
        }
        bps[10] = 910; // adjust to sum to 10000

        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("TooManyWinners()"));
        distributor.distributeRewards(winners, bps);
    }

    function test_revert_emptyWinners() public {
        aUsdc.simulateYield(address(vault), 1000e6);

        address[] memory winners = new address[](0);
        uint256[] memory bps = new uint256[](0);

        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("TooManyWinners()"));
        distributor.distributeRewards(winners, bps);
    }

    function test_revert_lengthMismatch() public {
        aUsdc.simulateYield(address(vault), 1000e6);

        address[] memory winners = new address[](2);
        uint256[] memory bps = new uint256[](1);
        winners[0] = winner;
        winners[1] = address(0xE);
        bps[0] = 10_000;

        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("ArrayLengthMismatch()"));
        distributor.distributeRewards(winners, bps);
    }

    function test_revert_bpsDontSumTo10000() public {
        aUsdc.simulateYield(address(vault), 1000e6);

        address[] memory winners = new address[](2);
        uint256[] memory bps = new uint256[](2);
        winners[0] = winner;
        winners[1] = address(0xE);
        bps[0] = 5_000;
        bps[1] = 4_000; // sums to 9000, not 10000

        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("WinnerBpsMustTotal10000()"));
        distributor.distributeRewards(winners, bps);
    }

    function test_revert_zeroAddressInWinners() public {
        aUsdc.simulateYield(address(vault), 1000e6);

        address[] memory winners = new address[](2);
        uint256[] memory bps = new uint256[](2);
        winners[0] = winner;
        winners[1] = address(0);
        bps[0] = 5_000;
        bps[1] = 5_000;

        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        distributor.distributeRewards(winners, bps);
    }

    // ========================= MULTIPLE ROUNDS =========================

    function test_distributeRewards_multipleRounds() public {
        aUsdc.simulateYield(address(vault), 500e6);
        (address[] memory w1, uint256[] memory b1) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w1, b1);
        assertEq(usdc.balanceOf(winner), 400e6);

        address winner2 = address(0xE);
        aUsdc.simulateYield(address(vault), 200e6);
        (address[] memory w2, uint256[] memory b2) = _single(winner2);
        vm.prank(gameMaster);
        distributor.distributeRewards(w2, b2);

        assertEq(usdc.balanceOf(winner2), 160e6);
        assertEq(usdc.balanceOf(protocolWallet), 70e6);
    }

    // ========================= REWARD TRACKING =========================

    function test_cumulativeRewards_tracked() public {
        aUsdc.simulateYield(address(vault), 1000e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(distributor.cumulativeRewards(winner), 800e6);
        assertEq(distributor.cumulativeRewards(protocolWallet), 100e6);
        assertEq(distributor.totalWinnerRewards(), 800e6);
        assertEq(distributor.totalProtocolRewards(), 100e6);
        assertEq(distributor.totalVaultRewards(), 100e6);
    }

    function test_cumulativeRewards_multiWinner() public {
        aUsdc.simulateYield(address(vault), 1000e6);

        address winner2 = address(0xE);
        address[] memory winners = new address[](2);
        uint256[] memory bps = new uint256[](2);
        winners[0] = winner;
        winners[1] = winner2;
        bps[0] = 6_000;
        bps[1] = 4_000;

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        // Winner share = 800, winner gets 60% = 480, winner2 gets 40% = 320
        assertEq(distributor.cumulativeRewards(winner), 480e6);
        assertEq(distributor.cumulativeRewards(winner2), 320e6);
        assertEq(distributor.rewardRecipientCount(), 3); // winner, winner2, protocolWallet
    }

    function test_allRewardRecipients() public {
        address winner2 = address(0xE);
        address winner3 = address(0xF);

        aUsdc.simulateYield(address(vault), 300e6);
        (address[] memory w1, uint256[] memory b1) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w1, b1);

        aUsdc.simulateYield(address(vault), 300e6);
        (address[] memory w2, uint256[] memory b2) = _single(winner2);
        vm.prank(gameMaster);
        distributor.distributeRewards(w2, b2);

        aUsdc.simulateYield(address(vault), 300e6);
        (address[] memory w3, uint256[] memory b3) = _single(winner3);
        vm.prank(gameMaster);
        distributor.distributeRewards(w3, b3);

        (address[] memory recipients,) = distributor.allRewardRecipients();
        // 4 unique: winner, protocolWallet, winner2, winner3
        assertEq(recipients.length, 4);
        assertEq(distributor.cumulativeRewards(protocolWallet), 90e6);
    }

    function test_rewardRecipientsPaginated() public {
        address winner2 = address(0xE);

        aUsdc.simulateYield(address(vault), 500e6);
        (address[] memory w1, uint256[] memory b1) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w1, b1);

        aUsdc.simulateYield(address(vault), 500e6);
        (address[] memory w2, uint256[] memory b2) = _single(winner2);
        vm.prank(gameMaster);
        distributor.distributeRewards(w2, b2);

        (address[] memory r1,) = distributor.rewardRecipientsPaginated(0, 2);
        assertEq(r1.length, 2);

        (address[] memory r2,) = distributor.rewardRecipientsPaginated(2, 2);
        assertEq(r2.length, 1);

        (address[] memory r3,) = distributor.rewardRecipientsPaginated(10, 5);
        assertEq(r3.length, 0);
    }

    // ========================= ADJUST CHECKPOINT =========================

    function test_adjustCheckpoint_positiveDeposit() public {
        uint256 before = distributor.lastCheckpointBalance();

        // Simulate: user deposits 500 USDC, operator supplies to Aave
        aUsdc.mint(address(vault), 500e6);

        // Admin adjusts checkpoint so the 500 isn't counted as yield
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(500e6));

        assertEq(distributor.lastCheckpointBalance(), before + 500e6);
        assertEq(distributor.pendingYield(), 0);
    }

    function test_adjustCheckpoint_negativeWithdrawal() public {
        uint256 before = distributor.lastCheckpointBalance();

        // Simulate: user withdraws, 200 aUSDC burned from vault
        aUsdc.burn(address(vault), 200e6);

        // Admin adjusts checkpoint down so it's not seen as negative yield
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(200e6));

        assertEq(distributor.lastCheckpointBalance(), before - 200e6);
        assertEq(distributor.pendingYield(), 0);
    }

    function test_adjustCheckpoint_yieldStillTrackedAfterDeposit() public {
        // Deposit 500 + adjust checkpoint
        aUsdc.mint(address(vault), 500e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(500e6));
        assertEq(distributor.pendingYield(), 0);

        // Now simulate 100 yield
        aUsdc.simulateYield(address(vault), 100e6);
        assertEq(distributor.pendingYield(), 100e6);

        // Distribute works on the 100 yield only
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 80e6); // 80% of 100
    }

    function test_adjustCheckpoint_floorsToZero() public {
        // Try to subtract more than checkpoint
        uint256 checkpoint = distributor.lastCheckpointBalance();

        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(checkpoint + 1_000e6));

        assertEq(distributor.lastCheckpointBalance(), 0);
    }

    function test_revert_adjustCheckpoint_unauthorized() public {
        vm.prank(gameMaster);
        vm.expectRevert("UNAUTHORIZED");
        distributor.adjustCheckpoint(int256(100e6));
    }

    // ========================= SCENARIO: DEPOSITS/WITHDRAWALS BETWEEN DISTRIBUTIONS =========================

    /// @notice Core scenario: deposit between two distributions should NOT inflate yield.
    function test_scenario_depositBetweenDistributions() public {
        // Round 1: 500 yield accrues
        aUsdc.simulateYield(address(vault), 500e6);
        assertEq(distributor.pendingYield(), 500e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        // winner: 80% of 500 = 400
        // protocol: 10% of 500 = 50
        // vault depositors: 10% of 500 = 50 (stays as aUSDC)
        assertEq(usdc.balanceOf(winner), 400e6);
        assertEq(usdc.balanceOf(protocolWallet), 50e6);
        assertEq(distributor.pendingYield(), 0);

        // --- Between rounds: user deposits 2000 USDC, operator supplies to Aave ---
        aUsdc.mint(address(vault), 2_000e6); // aUSDC minted from Aave supply
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(2_000e6));
        assertEq(distributor.pendingYield(), 0); // deposit is NOT yield

        // Round 2: 300 yield accrues ON TOP of the deposit
        aUsdc.simulateYield(address(vault), 300e6);
        assertEq(distributor.pendingYield(), 300e6);

        address winner2 = address(0xE);
        (address[] memory w2, uint256[] memory b2) = _single(winner2);
        vm.prank(gameMaster);
        distributor.distributeRewards(w2, b2);

        // winner2: 80% of 300 = 240
        // protocol: 10% of 300 = 30 (cumulative: 50 + 30 = 80)
        assertEq(usdc.balanceOf(winner2), 240e6);
        assertEq(usdc.balanceOf(protocolWallet), 80e6);
        assertEq(distributor.pendingYield(), 0);
    }

    /// @notice Withdrawal between distributions should NOT create phantom negative yield.
    function test_scenario_withdrawalBetweenDistributions() public {
        // Round 1: 1000 yield
        aUsdc.simulateYield(address(vault), 1000e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 800e6);
        assertEq(usdc.balanceOf(protocolWallet), 100e6);

        // --- Between rounds: user withdraws 5000, aUSDC burned ---
        aUsdc.burn(address(vault), 5_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(5_000e6));
        assertEq(distributor.pendingYield(), 0);

        // Round 2: 200 yield accrues on the now-smaller balance
        aUsdc.simulateYield(address(vault), 200e6);
        assertEq(distributor.pendingYield(), 200e6);

        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        // winner: 800 + 160 = 960
        // protocol: 100 + 20 = 120
        assertEq(usdc.balanceOf(winner), 960e6);
        assertEq(usdc.balanceOf(protocolWallet), 120e6);
    }

    /// @notice Multiple deposits AND withdrawals between a single distribution.
    function test_scenario_multipleDepositsAndWithdrawals_thenDistribute() public {
        // Start: vault has 1M aUSDC, checkpoint = 1M

        // Deposit 1: +500
        aUsdc.mint(address(vault), 500e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(500e6));

        // Withdrawal 1: -200
        aUsdc.burn(address(vault), 200e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(200e6));

        // Deposit 2: +1000
        aUsdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(1_000e6));

        // Withdrawal 2: -300
        aUsdc.burn(address(vault), 300e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(300e6));

        // Net deposit effect: +500 -200 +1000 -300 = +1000
        // Vault aUSDC: 1M + 1000 = 1,001,000
        // Checkpoint:  1M + 1000 = 1,001,000
        assertEq(distributor.pendingYield(), 0);

        // NOW yield accrues: +777
        aUsdc.simulateYield(address(vault), 777e6);
        assertEq(distributor.pendingYield(), 777e6);

        // Distribute: only the 777 yield goes out
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        // winner: 80% of 777 = 621.6 -> 621600000
        // protocol: 10% of 777 = 77.7 -> 77700000
        // vault: 10% of 777 = 77.7 -> stays
        uint256 expectedWinner = (777e6 * 8_000) / 10_000;
        uint256 expectedProtocol = (777e6 * 1_000) / 10_000;
        uint256 expectedVault = 777e6 - expectedWinner - expectedProtocol;

        assertEq(usdc.balanceOf(winner), expectedWinner);
        assertEq(usdc.balanceOf(protocolWallet), expectedProtocol);
        assertEq(distributor.totalVaultRewards(), expectedVault);
        assertEq(distributor.pendingYield(), 0);
    }

    /// @notice Three full rounds with deposits between each. Verify cumulative tracking is exact.
    function test_scenario_threeRounds_depositsEachTime() public {
        uint256 cumulativeWinner;
        uint256 cumulativeProtocol;
        uint256 cumulativeVault;

        // Round 1: 100 yield, no deposits
        aUsdc.simulateYield(address(vault), 100e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        cumulativeWinner += 80e6;
        cumulativeProtocol += 10e6;
        cumulativeVault += 10e6;
        assertEq(usdc.balanceOf(winner), cumulativeWinner);

        // Deposit 5000 between rounds
        aUsdc.mint(address(vault), 5_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(5_000e6));

        // Round 2: 250 yield
        aUsdc.simulateYield(address(vault), 250e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        cumulativeWinner += 200e6;
        cumulativeProtocol += 25e6;
        cumulativeVault += 25e6;
        assertEq(usdc.balanceOf(winner), cumulativeWinner);

        // Deposit 3000 between rounds
        aUsdc.mint(address(vault), 3_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(3_000e6));

        // Round 3: 400 yield
        aUsdc.simulateYield(address(vault), 400e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        cumulativeWinner += 320e6;
        cumulativeProtocol += 40e6;
        cumulativeVault += 40e6;

        assertEq(usdc.balanceOf(winner), cumulativeWinner); // 80 + 200 + 320 = 600
        assertEq(usdc.balanceOf(protocolWallet), cumulativeProtocol); // 10 + 25 + 40 = 75
        assertEq(distributor.totalWinnerRewards(), cumulativeWinner);
        assertEq(distributor.totalProtocolRewards(), cumulativeProtocol);
        assertEq(distributor.totalVaultRewards(), cumulativeVault); // 10 + 25 + 40 = 75
        assertEq(distributor.cumulativeRewards(winner), cumulativeWinner);
    }

    /// @notice Multi-winner distribution with deposit in between. Verify each winner gets correct share.
    function test_scenario_multiWinner_withDepositBetween() public {
        address winner2 = address(0xE);
        address winner3 = address(0xF);

        // Round 1: 600 yield, 3 winners at 50/30/20
        aUsdc.simulateYield(address(vault), 600e6);

        address[] memory winners = new address[](3);
        uint256[] memory bps = new uint256[](3);
        winners[0] = winner;
        winners[1] = winner2;
        winners[2] = winner3;
        bps[0] = 5_000;
        bps[1] = 3_000;
        bps[2] = 2_000;

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

        // Winner share = 80% of 600 = 480
        // winner:  50% of 480 = 240
        // winner2: 30% of 480 = 144
        // winner3: 20% of 480 = 96 (remainder: 480 - 240 - 144 = 96)
        assertEq(usdc.balanceOf(winner), 240e6);
        assertEq(usdc.balanceOf(winner2), 144e6);
        assertEq(usdc.balanceOf(winner3), 96e6);
        assertEq(usdc.balanceOf(protocolWallet), 60e6);

        // Large deposit between rounds
        aUsdc.mint(address(vault), 10_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(10_000e6));

        // Round 2: 1000 yield, 2 winners at 70/30
        aUsdc.simulateYield(address(vault), 1000e6);

        address[] memory w2 = new address[](2);
        uint256[] memory b2 = new uint256[](2);
        w2[0] = winner;
        w2[1] = winner2;
        b2[0] = 7_000;
        b2[1] = 3_000;

        vm.prank(gameMaster);
        distributor.distributeRewards(w2, b2);

        // Winner share = 80% of 1000 = 800
        // winner:  70% of 800 = 560
        // winner2: 30% of 800 = 240
        assertEq(usdc.balanceOf(winner), 240e6 + 560e6); // 800 total
        assertEq(usdc.balanceOf(winner2), 144e6 + 240e6); // 384 total
        assertEq(usdc.balanceOf(protocolWallet), 60e6 + 100e6); // 160 total
    }

    /// @notice Ensure that if NO yield accrues between deposit adjustments, distribution reverts.
    function test_scenario_depositOnly_noYield_reverts() public {
        // Multiple deposits, no yield
        aUsdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(1_000e6));

        aUsdc.mint(address(vault), 2_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(2_000e6));

        assertEq(distributor.pendingYield(), 0);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("NoYieldToDistribute()"));
        distributor.distributeRewards(w, b);
    }

    /// @notice Simultaneous deposit and yield in the same "block" — only yield is distributed.
    function test_scenario_depositAndYield_sameTime() public {
        // Deposit 5000 and 300 yield arrive "simultaneously"
        aUsdc.mint(address(vault), 5_300e6); // 5000 deposit + 300 yield

        // Admin adjusts for the deposit portion only
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(5_000e6));

        // pendingYield should reflect the 300 yield
        assertEq(distributor.pendingYield(), 300e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 240e6); // 80% of 300
        assertEq(usdc.balanceOf(protocolWallet), 30e6); // 10% of 300
    }

    /// @notice Large withdrawal that nearly empties the vault, then small yield, then distribute.
    function test_scenario_nearTotalWithdrawal_thenYield() public {
        // Vault has 1M aUSDC. Withdraw 999,000.
        aUsdc.burn(address(vault), 999_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(999_000e6));

        // Only 1000 aUSDC remains. Checkpoint = 1000.
        assertEq(distributor.lastCheckpointBalance(), 1_000e6);
        assertEq(distributor.pendingYield(), 0);

        // Tiny yield: 5 USDC
        aUsdc.simulateYield(address(vault), 5e6);
        assertEq(distributor.pendingYield(), 5e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        // winner: 80% of 5 = 4
        // protocol: 10% of 5 = 0.5 -> 500000
        assertEq(usdc.balanceOf(winner), 4e6);
        assertEq(usdc.balanceOf(protocolWallet), 500_000); // 0.5 USDC
    }

    /// @notice Stress test: 5 rounds with alternating deposits/withdrawals/yield.
    function test_scenario_fiveRounds_complexFlow() public {
        uint256 totalYieldDistributed;

        // === Round 1: 100 yield ===
        aUsdc.simulateYield(address(vault), 100e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        totalYieldDistributed += 100e6;

        // Deposit 2000
        aUsdc.mint(address(vault), 2_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(2_000e6));

        // === Round 2: 50 yield ===
        aUsdc.simulateYield(address(vault), 50e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        totalYieldDistributed += 50e6;

        // Withdraw 500
        aUsdc.burn(address(vault), 500e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(500e6));

        // Deposit 1000
        aUsdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(1_000e6));

        // === Round 3: 200 yield ===
        aUsdc.simulateYield(address(vault), 200e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        totalYieldDistributed += 200e6;

        // Withdraw 3000
        aUsdc.burn(address(vault), 3_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(3_000e6));

        // === Round 4: 75 yield ===
        aUsdc.simulateYield(address(vault), 75e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        totalYieldDistributed += 75e6;

        // Deposit 10000, Withdraw 4000 (net +6000)
        aUsdc.mint(address(vault), 10_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(10_000e6));
        aUsdc.burn(address(vault), 4_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(4_000e6));

        // === Round 5: 500 yield ===
        aUsdc.simulateYield(address(vault), 500e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        totalYieldDistributed += 500e6;

        // Verify totals: all yield = 100 + 50 + 200 + 75 + 500 = 925
        assertEq(totalYieldDistributed, 925e6);

        uint256 expectedWinnerTotal = (totalYieldDistributed * 8_000) / 10_000; // 740
        uint256 expectedProtocolTotal = (totalYieldDistributed * 1_000) / 10_000; // 92.5

        assertEq(usdc.balanceOf(winner), expectedWinnerTotal);
        assertEq(usdc.balanceOf(protocolWallet), expectedProtocolTotal);
        assertEq(distributor.totalWinnerRewards(), expectedWinnerTotal);
        assertEq(distributor.totalProtocolRewards(), expectedProtocolTotal);
        assertEq(distributor.pendingYield(), 0);
    }

    /// @notice Verify accounting holds with a fee split change mid-stream between deposits.
    function test_scenario_feeSplitChange_betweenDeposits() public {
        // Round 1: default splits (80/10/10), 1000 yield
        aUsdc.simulateYield(address(vault), 1000e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 800e6);
        assertEq(usdc.balanceOf(protocolWallet), 100e6);

        // Deposit 5000 between rounds
        aUsdc.mint(address(vault), 5_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(5_000e6));

        // Change fee splits to 60/20/20
        vm.prank(owner);
        distributor.setFeeSplits(2_000, 2_000);

        // Round 2: 500 yield
        aUsdc.simulateYield(address(vault), 500e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        // winner: 60% of 500 = 300 (cumulative: 800 + 300 = 1100)
        // protocol: 20% of 500 = 100 (cumulative: 100 + 100 = 200)
        assertEq(usdc.balanceOf(winner), 1100e6);
        assertEq(usdc.balanceOf(protocolWallet), 200e6);
        assertEq(distributor.totalVaultRewards(), 100e6 + 100e6); // 10% of 1000 + 20% of 500
    }

    /// @notice Forgotten adjustCheckpoint after deposit inflates yield — shows why adjustment is critical.
    function test_scenario_forgottenAdjust_inflatesYield() public {
        // Deposit 5000 WITHOUT calling adjustCheckpoint
        aUsdc.mint(address(vault), 5_000e6);

        // The system thinks this is yield!
        assertEq(distributor.pendingYield(), 5_000e6);

        // If distributeRewards is called, the deposit gets distributed as "yield"
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        // This is WRONG behavior but proves the invariant:
        // without adjustCheckpoint, deposits are treated as yield
        assertEq(usdc.balanceOf(winner), 4_000e6); // 80% of 5000 (should be 0)
    }

    // ========================= PAUSE =========================

    function test_pause_blocksDistribution() public {
        aUsdc.simulateYield(address(vault), 100e6);

        vm.prank(owner);
        distributor.setPaused(true);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("Paused()"));
        distributor.distributeRewards(w, b);
    }

    function test_unpause_allowsDistribution() public {
        aUsdc.simulateYield(address(vault), 100e6);

        vm.prank(owner);
        distributor.setPaused(true);

        vm.prank(owner);
        distributor.setPaused(false);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 80e6);
    }

    // ========================= SCOPED PROXY =========================

    function test_proxy_rejectsUnauthorizedCaller() public {
        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        proxy.aaveWithdrawUsdc(100e6);

        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        proxy.vaultTransferUsdc(winner, 100e6);
    }

    function test_proxy_distributorIsOnlyAuthorizedCaller() public {
        vm.prank(gameMaster);
        vm.expectRevert("UNAUTHORIZED");
        proxy.aaveWithdrawUsdc(100e6);
    }

    function test_proxy_rejectsZeroAddress() public {
        vm.prank(address(distributor));
        vm.expectRevert(abi.encodeWithSignature("ScopedVaultProxy__ZeroAddress()"));
        proxy.vaultTransferUsdc(address(0), 100e6);
    }

    function test_proxy_rejectsZeroAmount() public {
        vm.prank(address(distributor));
        vm.expectRevert(abi.encodeWithSignature("ScopedVaultProxy__ZeroAmount()"));
        proxy.aaveWithdrawUsdc(0);
    }

    // ========================= REENTRANCY =========================

    function test_reentrancy_lockResets() public {
        aUsdc.simulateYield(address(vault), 100e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        aUsdc.simulateYield(address(vault), 100e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 160e6);
    }

    // ========================= ACCESS CONTROL =========================

    function test_revert_noYield() public {
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("NoYieldToDistribute()"));
        distributor.distributeRewards(w, b);
    }

    function test_revert_unauthorizedDistribute() public {
        aUsdc.simulateYield(address(vault), 100e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(address(0xBAD));
        vm.expectRevert("UNAUTHORIZED");
        distributor.distributeRewards(w, b);
    }

    function test_revert_unauthorizedSetFees() public {
        vm.prank(gameMaster);
        vm.expectRevert("UNAUTHORIZED");
        distributor.setFeeSplits(500, 500);
    }

    function test_revert_unauthorizedPause() public {
        vm.prank(gameMaster);
        vm.expectRevert("UNAUTHORIZED");
        distributor.setPaused(true);
    }

    function test_revert_invalidBps() public {
        vm.startPrank(owner);

        vm.expectRevert(abi.encodeWithSignature("InvalidBps()"));
        distributor.setFeeSplits(6_000, 1_000);

        vm.expectRevert(abi.encodeWithSignature("InvalidBps()"));
        distributor.setFeeSplits(1_000, 6_000);

        vm.expectRevert(abi.encodeWithSignature("InvalidBps()"));
        distributor.setFeeSplits(5_000, 5_000);

        vm.stopPrank();
    }

    // ========================= ADMIN =========================

    function test_setProtocolWallet() public {
        address newWallet = address(0xF);
        vm.prank(owner);
        distributor.setProtocolWallet(newWallet);
        assertEq(distributor.protocolWallet(), newWallet);
    }

    function test_resetCheckpoint() public {
        aUsdc.simulateYield(address(vault), 500e6);
        assertEq(distributor.pendingYield(), 500e6);

        vm.prank(owner);
        distributor.resetCheckpoint();

        assertEq(distributor.pendingYield(), 0);
    }

    function test_pendingYield_view() public {
        assertEq(distributor.pendingYield(), 0);

        aUsdc.simulateYield(address(vault), 123e6);
        assertEq(distributor.pendingYield(), 123e6);

        aUsdc.simulateYield(address(vault), 77e6);
        assertEq(distributor.pendingYield(), 200e6);
    }

    // ========================= EVENTS =========================

    function test_event_pauseToggled() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit PauseToggled(true);
        distributor.setPaused(true);
    }

    function test_event_feeSplitsUpdated() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit FeeSplitsUpdated(2_000, 500);
        distributor.setFeeSplits(2_000, 500);
    }
}
