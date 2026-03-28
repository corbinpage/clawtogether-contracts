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
///         Uses ManagerWithMerkleVerification instead of ScopedVaultProxy.
contract IntegrationTest is Test {
    BoringVault vault;
    RolesAuthority auth;
    AccountantWithRateProviders accountant;
    TellerWithMultiAssetSupport teller;
    DelayedWithdraw delayedWithdraw;
    ManagerWithMerkleVerification manager;
    ClawTogetherDecoderAndSanitizer decoder;
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
    uint8 constant STRATEGIST_ROLE = 21;

    uint32 constant WITHDRAW_DELAY = 1 days;
    uint32 constant COMPLETION_WINDOW = 7 days;

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

    function _computeLeaf(
        address _decoder, address target, bool valueNonZero, bytes4 selector, bytes memory packedAddresses
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(_decoder, target, valueNonZero, selector, packedAddresses));
    }

    function _buildTree4(bytes32 l0, bytes32 l1, bytes32 l2, bytes32 l3)
        internal pure returns (
            bytes32 root, bytes32[] memory p0, bytes32[] memory p1, bytes32[] memory p2, bytes32[] memory p3
        )
    {
        bytes32 h01 = _hashPair(l0, l1);
        bytes32 h23 = _hashPair(l2, l3);
        root = _hashPair(h01, h23);
        p0 = new bytes32[](2); p0[0] = l1; p0[1] = h23;
        p1 = new bytes32[](2); p1[0] = l0; p1[1] = h23;
        p2 = new bytes32[](2); p2[0] = l3; p2[1] = h01;
        p3 = new bytes32[](2); p3[0] = l2; p3[1] = h01;
    }

    function setUp() public {
        usdc = new MockUSDC();
        aUsdc = new MockAToken();
        weth = new MockWETH();
        aavePool = new MockAavePool(usdc, aUsdc);

        auth = new RolesAuthority(owner, Authority(address(0)));
        vault = new BoringVault(owner, "Game Yield Vault", "clawUSDC", 6);

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

        // Deploy Manager (balancerVault = address(0))
        manager = new ManagerWithMerkleVerification(owner, address(vault), address(0));
        manager.setAuthority(auth);

        // Deploy Decoder
        decoder = new ClawTogetherDecoderAndSanitizer(address(vault));

        // Deploy GameRewardsDistributor
        distributor = new GameRewardsDistributor(
            owner, auth, vault, ERC20(address(usdc)), ERC20(address(aUsdc)),
            manager, address(decoder), address(aavePool), protocolWallet
        );

        // Point Veda contracts to shared authority
        teller.setAuthority(auth);
        accountant.setAuthority(auth);
        delayedWithdraw.setAuthority(auth);

        // ========================= PERMISSIONS =========================

        // Manager -> vault.manage()
        auth.setUserRole(address(manager), MANAGER_ROLE, true);
        auth.setRoleCapability(
            MANAGER_ROLE, address(vault), bytes4(keccak256("manage(address,bytes,uint256)")), true
        );

        // Teller -> vault.enter()
        auth.setUserRole(address(teller), TELLER_ROLE, true);
        auth.setRoleCapability(
            TELLER_ROLE, address(vault),
            bytes4(keccak256("enter(address,address,uint256,address,uint256)")), true
        );

        // DelayedWithdraw -> vault.exit()
        auth.setUserRole(address(delayedWithdraw), DELAYED_WITHDRAW_ROLE, true);
        auth.setRoleCapability(
            DELAYED_WITHDRAW_ROLE, address(vault),
            bytes4(keccak256("exit(address,address,uint256,address,uint256)")), true
        );

        // Distributor -> manager.manageVaultWithMerkleVerification
        auth.setUserRole(address(distributor), STRATEGIST_ROLE, true);
        auth.setRoleCapability(
            STRATEGIST_ROLE, address(manager),
            ManagerWithMerkleVerification.manageVaultWithMerkleVerification.selector, true
        );

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
        auth.setRoleCapability(OWNER_ROLE, address(distributor), GameRewardsDistributor.setMerkleProofs.selector, true);

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
        vm.prank(address(vault));
        usdc.approve(address(aavePool), type(uint256).max);

        // Build Merkle tree and set proofs
        _setupMerkleTree();

        // Reset checkpoint after seeding
        vm.prank(owner);
        distributor.resetCheckpoint();

        // Give users USDC
        usdc.mint(alice, 10_000e6);
        usdc.mint(bob, 5_000e6);
    }

    function _setupMerkleTree() internal {
        bytes32 approveLeaf = _computeLeaf(
            address(decoder), address(usdc), false,
            bytes4(keccak256("approve(address,uint256)")),
            abi.encodePacked(address(aavePool))
        );
        bytes32 supplyLeaf = _computeLeaf(
            address(decoder), address(aavePool), false,
            bytes4(keccak256("supply(address,uint256,address,uint16)")),
            abi.encodePacked(address(usdc), address(vault))
        );
        bytes32 withdrawLeaf = _computeLeaf(
            address(decoder), address(aavePool), false,
            bytes4(keccak256("withdraw(address,uint256,address)")),
            abi.encodePacked(address(usdc), address(vault))
        );
        bytes32 transferLeaf = _computeLeaf(
            address(decoder), address(usdc), false,
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

        vm.startPrank(owner);
        manager.setManageRoot(address(distributor), root);
        distributor.setMerkleProofs(approveProof, supplyProof, withdrawProof, transferProof);
        vm.stopPrank();
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
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), 0);

        vm.warp(block.timestamp + WITHDRAW_DELAY);

        vm.prank(alice);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 1_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function test_delayedWithdraw_revertsBeforeDelay() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = teller.deposit(ERC20(address(usdc)), 1_000e6, 0);

        vault.approve(address(delayedWithdraw), shares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(shares), 100, true);

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

        vm.prank(bob);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 1_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6);
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

        vm.warp(block.timestamp + WITHDRAW_DELAY);

        vm.prank(alice);
        uint256 assetsOut = delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);

        assertEq(assetsOut, 2_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function test_multipleDepositors_withdraw() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 5_000e6);
        uint256 aliceShares = teller.deposit(ERC20(address(usdc)), 5_000e6, 0);
        vm.stopPrank();

        vm.startPrank(bob);
        usdc.approve(address(vault), 3_000e6);
        uint256 bobShares = teller.deposit(ERC20(address(usdc)), 3_000e6, 0);
        vm.stopPrank();

        vm.startPrank(alice);
        vault.approve(address(delayedWithdraw), aliceShares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(aliceShares), 100, true);
        vm.stopPrank();

        vm.startPrank(bob);
        vault.approve(address(delayedWithdraw), bobShares);
        delayedWithdraw.requestWithdraw(ERC20(address(usdc)), uint96(bobShares), 100, true);
        vm.stopPrank();

        uint256 debt = delayedWithdraw.viewOutstandingDebt(ERC20(address(usdc)));
        assertEq(debt, 8_000e6);

        vm.warp(block.timestamp + WITHDRAW_DELAY);

        vm.prank(alice);
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), alice);
        assertEq(usdc.balanceOf(alice), 10_000e6);

        vm.prank(bob);
        delayedWithdraw.completeWithdraw(ERC20(address(usdc)), bob);
        assertEq(usdc.balanceOf(bob), 5_000e6);
    }
}
