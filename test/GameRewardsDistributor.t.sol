// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "@forge-std/Test.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {ManagerWithMerkleVerification} from "boring-vault/base/Roles/ManagerWithMerkleVerification.sol";
import {GameRewardsDistributor} from "../src/GameRewardsDistributor.sol";
import {ClawTogetherDecoderAndSanitizer} from "../src/ClawTogetherDecoderAndSanitizer.sol";
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

// Mock Aave Pool.
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
    ManagerWithMerkleVerification manager;
    ClawTogetherDecoderAndSanitizer decoder;
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
    uint8 constant STRATEGIST_ROLE = 21;

    // Helpers to build single-winner arrays
    function _single(address w) internal pure returns (address[] memory winners, uint256[] memory bps) {
        winners = new address[](1);
        bps = new uint256[](1);
        winners[0] = w;
        bps[0] = 10_000;
    }

    // ========================= MERKLE TREE HELPERS =========================

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? _efficientHash(a, b) : _efficientHash(b, a);
    }

    function _efficientHash(bytes32 a, bytes32 b) internal pure returns (bytes32 value) {
        assembly {
            mstore(0x00, a)
            mstore(0x20, b)
            value := keccak256(0x00, 0x40)
        }
    }

    /// @dev Computes Merkle leaf matching ManagerWithMerkleVerification._verifyManageProof
    function _computeLeaf(
        address _decoder,
        address target,
        bool valueNonZero,
        bytes4 selector,
        bytes memory packedAddresses
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_decoder, target, valueNonZero, selector, packedAddresses));
    }

    /// @dev Builds a 4-leaf Merkle tree and returns root + proofs for each leaf.
    function _buildTree4(bytes32 l0, bytes32 l1, bytes32 l2, bytes32 l3)
        internal
        pure
        returns (
            bytes32 root,
            bytes32[] memory proof0,
            bytes32[] memory proof1,
            bytes32[] memory proof2,
            bytes32[] memory proof3
        )
    {
        bytes32 h01 = _hashPair(l0, l1);
        bytes32 h23 = _hashPair(l2, l3);
        root = _hashPair(h01, h23);

        proof0 = new bytes32[](2);
        proof0[0] = l1;
        proof0[1] = h23;

        proof1 = new bytes32[](2);
        proof1[0] = l0;
        proof1[1] = h23;

        proof2 = new bytes32[](2);
        proof2[0] = l3;
        proof2[1] = h01;

        proof3 = new bytes32[](2);
        proof3[0] = l2;
        proof3[1] = h01;
    }

    // ========================= SETUP =========================

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        aavePool = new MockAavePool(usdc, aUsdc);

        rolesAuthority = new RolesAuthority(owner, Authority(address(0)));
        vault = new BoringVault(owner, "Game Yield Vault", "clawUSDC", 6);

        vm.prank(owner);
        vault.setAuthority(rolesAuthority);

        // Deploy Manager (balancerVault = address(0), not needed)
        manager = new ManagerWithMerkleVerification(owner, address(vault), address(0));
        vm.prank(owner);
        manager.setAuthority(rolesAuthority);

        // Deploy Decoder
        decoder = new ClawTogetherDecoderAndSanitizer(address(vault));

        // Deploy Distributor
        distributor = new GameRewardsDistributor(
            owner,
            rolesAuthority,
            vault,
            ERC20(address(usdc)),
            ERC20(address(aUsdc)),
            manager,
            address(decoder),
            address(aavePool),
            protocolWallet
        );

        vm.startPrank(owner);

        // Manager gets MANAGER_ROLE on vault
        rolesAuthority.setUserRole(address(manager), MANAGER_ROLE, true);
        rolesAuthority.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );

        // Distributor gets STRATEGIST_ROLE on Manager
        rolesAuthority.setUserRole(address(distributor), STRATEGIST_ROLE, true);
        rolesAuthority.setRoleCapability(
            STRATEGIST_ROLE,
            address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector,
            true
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
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.setMerkleProofs.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.supplyAndCheckpoint.selector, true
        );
        rolesAuthority.setRoleCapability(
            OWNER_ROLE, address(distributor), GameRewardsDistributor.withdrawAndCheckpoint.selector, true
        );

        vm.stopPrank();

        // Seed the vault with aUSDC and approve the pool
        aUsdc.mint(address(vault), 1_000_000e6);
        vm.prank(address(vault));
        aUsdc.approve(address(aavePool), type(uint256).max);
        // Also approve USDC for supply path
        vm.prank(address(vault));
        usdc.approve(address(aavePool), type(uint256).max);

        // Build Merkle tree and set proofs
        _setupMerkleTree();

        // Reset checkpoint after seeding
        vm.prank(owner);
        distributor.resetCheckpoint();
    }

    function _setupMerkleTree() internal {
        // 4 leaves matching the operations the distributor will perform:
        // Leaf 0: approve(aavePool) on USDC
        bytes32 approveLeaf = _computeLeaf(
            address(decoder),
            address(usdc),
            false,
            bytes4(keccak256("approve(address,uint256)")),
            abi.encodePacked(address(aavePool))
        );

        // Leaf 1: supply(USDC, *, vault, *) on aavePool
        bytes32 supplyLeaf = _computeLeaf(
            address(decoder),
            address(aavePool),
            false,
            bytes4(keccak256("supply(address,uint256,address,uint16)")),
            abi.encodePacked(address(usdc), address(vault))
        );

        // Leaf 2: withdraw(USDC, *, vault) on aavePool
        bytes32 withdrawLeaf = _computeLeaf(
            address(decoder),
            address(aavePool),
            false,
            bytes4(keccak256("withdraw(address,uint256,address)")),
            abi.encodePacked(address(usdc), address(vault))
        );

        // Leaf 3: transfer(distributor, *) on USDC
        bytes32 transferLeaf = _computeLeaf(
            address(decoder),
            address(usdc),
            false,
            bytes4(keccak256("transfer(address,uint256)")),
            abi.encodePacked(address(distributor))
        );

        (
            bytes32 root,
            bytes32[] memory approveProof,
            bytes32[] memory supplyProof,
            bytes32[] memory withdrawProof,
            bytes32[] memory transferProof
        ) = _buildTree4(approveLeaf, supplyLeaf, withdrawLeaf, transferLeaf);

        // Owner sets Merkle root on Manager for the distributor
        vm.prank(owner);
        manager.setManageRoot(address(distributor), root);

        // Owner stores proofs in distributor
        vm.prank(owner);
        distributor.setMerkleProofs(approveProof, supplyProof, withdrawProof, transferProof);
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
        bps[0] = 7_000;
        bps[1] = 3_000;

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

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
        bps[0] = 3_334;
        bps[1] = 3_333;
        bps[2] = 3_333;

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

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
            bps[i] = 1_000;
        }

        vm.prank(gameMaster);
        distributor.distributeRewards(winners, bps);

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
        bps[10] = 910;

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
        bps[1] = 4_000;

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

        assertEq(distributor.cumulativeRewards(winner), 480e6);
        assertEq(distributor.cumulativeRewards(winner2), 320e6);
        assertEq(distributor.rewardRecipientCount(), 3);
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
        uint256 before_ = distributor.lastCheckpointBalance();
        aUsdc.mint(address(vault), 500e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(500e6));
        assertEq(distributor.lastCheckpointBalance(), before_ + 500e6);
        assertEq(distributor.pendingYield(), 0);
    }

    function test_adjustCheckpoint_negativeWithdrawal() public {
        uint256 before_ = distributor.lastCheckpointBalance();
        aUsdc.burn(address(vault), 200e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(200e6));
        assertEq(distributor.lastCheckpointBalance(), before_ - 200e6);
        assertEq(distributor.pendingYield(), 0);
    }

    function test_adjustCheckpoint_yieldStillTrackedAfterDeposit() public {
        aUsdc.mint(address(vault), 500e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(500e6));
        assertEq(distributor.pendingYield(), 0);

        aUsdc.simulateYield(address(vault), 100e6);
        assertEq(distributor.pendingYield(), 100e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        assertEq(usdc.balanceOf(winner), 80e6);
    }

    function test_adjustCheckpoint_floorsToZero() public {
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

    function test_scenario_depositBetweenDistributions() public {
        aUsdc.simulateYield(address(vault), 500e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 400e6);
        assertEq(usdc.balanceOf(protocolWallet), 50e6);

        aUsdc.mint(address(vault), 2_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(2_000e6));
        assertEq(distributor.pendingYield(), 0);

        aUsdc.simulateYield(address(vault), 300e6);
        assertEq(distributor.pendingYield(), 300e6);

        address winner2 = address(0xE);
        (address[] memory w2, uint256[] memory b2) = _single(winner2);
        vm.prank(gameMaster);
        distributor.distributeRewards(w2, b2);

        assertEq(usdc.balanceOf(winner2), 240e6);
        assertEq(usdc.balanceOf(protocolWallet), 80e6);
    }

    function test_scenario_multipleDepositsAndWithdrawals_thenDistribute() public {
        aUsdc.mint(address(vault), 500e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(500e6));

        aUsdc.burn(address(vault), 200e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(200e6));

        aUsdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(int256(1_000e6));

        aUsdc.burn(address(vault), 300e6);
        vm.prank(owner);
        distributor.adjustCheckpoint(-int256(300e6));

        assertEq(distributor.pendingYield(), 0);

        aUsdc.simulateYield(address(vault), 777e6);
        assertEq(distributor.pendingYield(), 777e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        uint256 expectedWinner = (777e6 * 8_000) / 10_000;
        uint256 expectedProtocol = (777e6 * 1_000) / 10_000;
        assertEq(usdc.balanceOf(winner), expectedWinner);
        assertEq(usdc.balanceOf(protocolWallet), expectedProtocol);
    }

    function test_scenario_forgottenAdjust_inflatesYield() public {
        aUsdc.mint(address(vault), 5_000e6);
        assertEq(distributor.pendingYield(), 5_000e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 4_000e6);
    }

    // ========================= ATOMIC SUPPLY / WITHDRAW =========================

    function test_supplyAndCheckpoint_basic() public {
        uint256 checkpointBefore = distributor.lastCheckpointBalance();
        usdc.mint(address(vault), 500e6);
        vm.prank(owner);
        distributor.supplyAndCheckpoint(500e6);
        assertEq(distributor.lastCheckpointBalance(), checkpointBefore + 500e6);
        assertEq(distributor.pendingYield(), 0);
    }

    function test_withdrawAndCheckpoint_basic() public {
        uint256 checkpointBefore = distributor.lastCheckpointBalance();
        address user = address(0x123);
        vm.prank(owner);
        distributor.withdrawAndCheckpoint(200e6, user);
        assertEq(distributor.lastCheckpointBalance(), checkpointBefore - 200e6);
        assertEq(usdc.balanceOf(user), 200e6);
        assertEq(distributor.pendingYield(), 0);
    }

    function test_supplyAndCheckpoint_cannotCreatePhantomYield() public {
        usdc.mint(address(vault), 5_000e6);
        vm.prank(owner);
        distributor.supplyAndCheckpoint(5_000e6);
        assertEq(distributor.pendingYield(), 0);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("NoYieldToDistribute()"));
        distributor.distributeRewards(w, b);
    }

    function test_supplyAndCheckpoint_multipleSupplies_thenYield() public {
        usdc.mint(address(vault), 1_000e6);
        vm.prank(owner);
        distributor.supplyAndCheckpoint(1_000e6);

        usdc.mint(address(vault), 2_000e6);
        vm.prank(owner);
        distributor.supplyAndCheckpoint(2_000e6);

        aUsdc.simulateYield(address(vault), 300e6);
        assertEq(distributor.pendingYield(), 300e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);

        assertEq(usdc.balanceOf(winner), 240e6);
        assertEq(usdc.balanceOf(protocolWallet), 30e6);
    }

    function test_withdrawAndCheckpoint_thenYield() public {
        address user = address(0x123);
        vm.prank(owner);
        distributor.withdrawAndCheckpoint(500_000e6, user);
        assertEq(distributor.pendingYield(), 0);

        aUsdc.simulateYield(address(vault), 100e6);
        assertEq(distributor.pendingYield(), 100e6);

        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        assertEq(usdc.balanceOf(winner), 80e6);
    }

    function test_supplyAndWithdraw_mixedBetweenDistributions() public {
        address user = address(0x123);

        aUsdc.simulateYield(address(vault), 200e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        assertEq(usdc.balanceOf(winner), 160e6);

        usdc.mint(address(vault), 3_000e6);
        vm.prank(owner);
        distributor.supplyAndCheckpoint(3_000e6);

        vm.prank(owner);
        distributor.withdrawAndCheckpoint(1_000e6, user);

        assertEq(distributor.pendingYield(), 0);

        aUsdc.simulateYield(address(vault), 500e6);
        vm.prank(gameMaster);
        distributor.distributeRewards(w, b);
        assertEq(usdc.balanceOf(winner), 560e6);
        assertEq(usdc.balanceOf(protocolWallet), 70e6);
    }

    function test_withdrawAndCheckpoint_fullWithdrawal() public {
        uint256 checkpoint = distributor.lastCheckpointBalance();
        vm.prank(owner);
        distributor.withdrawAndCheckpoint(checkpoint, address(0x123));
        assertEq(distributor.lastCheckpointBalance(), 0);
        assertEq(usdc.balanceOf(address(0x123)), checkpoint);
    }

    function test_revert_withdrawAndCheckpoint_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        distributor.withdrawAndCheckpoint(100e6, address(0));
    }

    function test_revert_supplyAndCheckpoint_unauthorized() public {
        usdc.mint(address(vault), 100e6);
        vm.prank(gameMaster);
        vm.expectRevert("UNAUTHORIZED");
        distributor.supplyAndCheckpoint(100e6);
    }

    function test_revert_withdrawAndCheckpoint_unauthorized() public {
        vm.prank(gameMaster);
        vm.expectRevert("UNAUTHORIZED");
        distributor.withdrawAndCheckpoint(100e6, winner);
    }

    // ========================= MERKLE PROOFS NOT SET =========================

    function test_revert_distributeRewards_merkleProofsNotSet() public {
        // Deploy a fresh distributor without proofs
        GameRewardsDistributor freshDist = new GameRewardsDistributor(
            owner, rolesAuthority, vault, ERC20(address(usdc)), ERC20(address(aUsdc)),
            manager, address(decoder), address(aavePool), protocolWallet
        );
        vm.startPrank(owner);
        rolesAuthority.setRoleCapability(
            GAME_MASTER_ROLE, address(freshDist), GameRewardsDistributor.distributeRewards.selector, true
        );
        vm.stopPrank();

        aUsdc.simulateYield(address(vault), 100e6);
        (address[] memory w, uint256[] memory b) = _single(winner);
        vm.prank(gameMaster);
        vm.expectRevert(abi.encodeWithSignature("MerkleProofsNotSet()"));
        freshDist.distributeRewards(w, b);
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
