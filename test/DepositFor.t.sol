// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Test} from "@forge-std/Test.sol";
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Authority} from "@solmate/auth/Auth.sol";
import {RolesAuthority} from "@solmate/auth/authorities/RolesAuthority.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

// ========================= MOCKS =========================

contract MockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC", 6) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH", 18) {}
}

// ========================= TESTS =========================

/// @dev Uses deployCode() to avoid Solidity 0.8.21 NatSpec compiler bug
///      triggered by importing TellerWithMultiAssetSupport in test files.
contract DepositForTest is Test {
    BoringVault vault;
    RolesAuthority auth;
    address accountant;
    address teller;
    MockUSDC usdc;
    MockWETH weth;

    address owner = address(0xA);
    address alice = address(0xD);
    address bob = address(0xE);
    address referrer = address(0xF);

    uint8 constant TELLER_ROLE = 2;

    // Local event declaration to avoid importing ClawTogetherTeller
    event DepositFor(
        address indexed depositor,
        address indexed onBehalfOf,
        address indexed referral,
        uint256 depositAmount,
        uint256 sharesMinted
    );

    function setUp() public {
        usdc = new MockUSDC();
        weth = new MockWETH();

        auth = new RolesAuthority(owner, Authority(address(0)));
        vault = new BoringVault(owner, "Game Yield Vault", "clawUSDC", 6);

        vm.startPrank(owner);
        vault.setAuthority(auth);

        // Deploy via deployCode to avoid NatSpec bug
        accountant = deployCode(
            "AccountantWithRateProviders.sol:AccountantWithRateProviders",
            abi.encode(owner, address(vault), owner, uint96(1e6), address(usdc), uint16(10_003), uint16(9_997), uint24(3600), uint16(0), uint16(0))
        );

        teller = deployCode(
            "ClawTogetherTeller.sol:ClawTogetherTeller",
            abi.encode(owner, address(vault), accountant, address(weth))
        );

        // Set authority on teller
        (bool ok,) = teller.call(abi.encodeWithSignature("setAuthority(address)", address(auth)));
        require(ok, "setAuthority failed");

        // Teller -> vault.enter()
        auth.setUserRole(teller, TELLER_ROLE, true);
        auth.setRoleCapability(
            TELLER_ROLE, address(vault),
            bytes4(keccak256("enter(address,address,uint256,address,uint256)")), true
        );

        // Public: deposit and depositFor
        // deposit selector: deposit(address,uint256,uint256) = 0x...
        auth.setPublicCapability(teller, bytes4(keccak256("deposit(address,uint256,uint256)")), true);
        // depositFor selector: depositFor(address,uint256,address,address)
        auth.setPublicCapability(teller, bytes4(keccak256("depositFor(address,uint256,address,address)")), true);

        // Configure USDC as deposit asset
        (ok,) = teller.call(
            abi.encodeWithSignature("updateAssetData(address,bool,bool,uint16)", address(usdc), true, false, uint16(0))
        );
        require(ok, "updateAssetData failed");

        vault.setBeforeTransferHook(teller);

        vm.stopPrank();

        // Give alice USDC
        usdc.mint(alice, 10_000e6);
    }

    // Helper to call depositFor on teller
    function _depositFor(ERC20 asset, uint256 amount, address onBehalfOf, address referral) internal returns (uint256 shares) {
        (bool ok, bytes memory data) = teller.call(
            abi.encodeWithSignature("depositFor(address,uint256,address,address)", address(asset), amount, onBehalfOf, referral)
        );
        require(ok, "depositFor failed");
        shares = abi.decode(data, (uint256));
    }

    // Helper to call deposit on teller
    function _deposit(ERC20 asset, uint256 amount) internal returns (uint256 shares) {
        (bool ok, bytes memory data) = teller.call(
            abi.encodeWithSignature("deposit(address,uint256,uint256)", address(asset), amount, uint256(0))
        );
        require(ok, "deposit failed");
        shares = abi.decode(data, (uint256));
    }

    // ========================= BASIC DEPOSIT FOR =========================

    function test_depositFor_mintsSharesTo_onBehalfOf() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = _depositFor(ERC20(address(usdc)), 1_000e6, bob, address(0));
        vm.stopPrank();

        assertGt(shares, 0, "shares should be > 0");
        assertEq(vault.balanceOf(bob), shares, "bob should hold the shares");
        assertEq(vault.balanceOf(alice), 0, "alice should hold no shares");
        assertEq(usdc.balanceOf(address(vault)), 1_000e6, "vault should hold the USDC");
    }

    function test_depositFor_deductsUSDCFromCaller() public {
        uint256 balBefore = usdc.balanceOf(alice);

        vm.startPrank(alice);
        usdc.approve(address(vault), 500e6);
        _depositFor(ERC20(address(usdc)), 500e6, bob, address(0));
        vm.stopPrank();

        assertEq(usdc.balanceOf(alice), balBefore - 500e6, "alice USDC should decrease");
    }

    function test_depositFor_emitsEvent() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);

        vm.expectEmit(true, true, true, true);
        emit DepositFor(alice, bob, referrer, 1_000e6, 1_000e6);

        _depositFor(ERC20(address(usdc)), 1_000e6, bob, referrer);
        vm.stopPrank();
    }

    function test_depositFor_emitsEventWithZeroReferral() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 500e6);

        vm.expectEmit(true, true, true, true);
        emit DepositFor(alice, bob, address(0), 500e6, 500e6);

        _depositFor(ERC20(address(usdc)), 500e6, bob, address(0));
        vm.stopPrank();
    }

    // ========================= SELF-DEPOSIT =========================

    function test_depositFor_toSelf() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);
        uint256 shares = _depositFor(ERC20(address(usdc)), 1_000e6, alice, address(0));
        vm.stopPrank();

        assertEq(vault.balanceOf(alice), shares, "alice deposits for herself");
    }

    // ========================= MULTIPLE DEPOSITS =========================

    function test_depositFor_multipleToDifferentRecipients() public {
        address carol = address(0x123);

        vm.startPrank(alice);
        usdc.approve(address(vault), 3_000e6);

        uint256 shares1 = _depositFor(ERC20(address(usdc)), 1_000e6, bob, referrer);
        uint256 shares2 = _depositFor(ERC20(address(usdc)), 2_000e6, carol, address(0));
        vm.stopPrank();

        assertEq(vault.balanceOf(bob), shares1);
        assertEq(vault.balanceOf(carol), shares2);
        assertEq(vault.balanceOf(alice), 0);
    }

    // ========================= REVERTS =========================

    function test_depositFor_revertsOnZeroAddress() public {
        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);

        (bool ok,) = teller.call(
            abi.encodeWithSignature("depositFor(address,uint256,address,address)", address(usdc), 1_000e6, address(0), referrer)
        );
        assertFalse(ok, "should revert on zero address");
        vm.stopPrank();
    }

    function test_depositFor_revertsOnZeroAmount() public {
        vm.prank(alice);
        (bool ok,) = teller.call(
            abi.encodeWithSignature("depositFor(address,uint256,address,address)", address(usdc), uint256(0), bob, referrer)
        );
        assertFalse(ok, "should revert on zero amount");
    }

    function test_depositFor_revertsOnUnsupportedAsset() public {
        address fakeToken = address(new MockWETH());

        vm.prank(alice);
        (bool ok,) = teller.call(
            abi.encodeWithSignature("depositFor(address,uint256,address,address)", fakeToken, 1_000e6, bob, referrer)
        );
        assertFalse(ok, "should revert on unsupported asset");
    }

    function test_depositFor_revertsWhenPaused() public {
        vm.prank(owner);
        (bool ok1,) = teller.call(abi.encodeWithSignature("pause()"));
        require(ok1, "pause failed");

        vm.startPrank(alice);
        usdc.approve(address(vault), 1_000e6);

        (bool ok2,) = teller.call(
            abi.encodeWithSignature("depositFor(address,uint256,address,address)", address(usdc), 1_000e6, bob, referrer)
        );
        assertFalse(ok2, "should revert when paused");
        vm.stopPrank();
    }

    function test_depositFor_revertsWithoutApproval() public {
        vm.prank(alice);
        (bool ok,) = teller.call(
            abi.encodeWithSignature("depositFor(address,uint256,address,address)", address(usdc), 1_000e6, bob, referrer)
        );
        assertFalse(ok, "should revert without approval");
    }

    // ========================= MIXED WITH REGULAR DEPOSIT =========================

    function test_depositFor_andRegularDeposit_coexist() public {
        // Alice deposits for bob via depositFor
        vm.startPrank(alice);
        usdc.approve(address(vault), 2_000e6);
        uint256 sharesBob = _depositFor(ERC20(address(usdc)), 1_000e6, bob, referrer);

        // Alice deposits for herself via regular deposit
        uint256 sharesAlice = _deposit(ERC20(address(usdc)), 1_000e6);
        vm.stopPrank();

        assertEq(vault.balanceOf(bob), sharesBob);
        assertEq(vault.balanceOf(alice), sharesAlice);
        assertEq(usdc.balanceOf(address(vault)), 2_000e6);
    }
}
