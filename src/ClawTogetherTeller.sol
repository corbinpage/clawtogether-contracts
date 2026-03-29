// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {TellerWithMultiAssetSupport} from "boring-vault/base/Roles/TellerWithMultiAssetSupport.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

/// @title ClawTogetherTeller
/// @notice Extends TellerWithMultiAssetSupport with a public depositFor function
///         that allows depositing on behalf of another address with optional referral tracking.
contract ClawTogetherTeller is TellerWithMultiAssetSupport {
    // ========================= EVENTS =========================

    event DepositFor(
        address indexed depositor,
        address indexed onBehalfOf,
        address indexed referral,
        uint256 depositAmount,
        uint256 sharesMinted
    );

    // ========================= ERRORS =========================

    error ClawTogetherTeller__ZeroAddress();

    // ========================= CONSTRUCTOR =========================

    constructor(address _owner, address _vault, address _accountant, address _weth)
        TellerWithMultiAssetSupport(_owner, _vault, _accountant, _weth)
    {}

    // ========================= PUBLIC FUNCTIONS =========================

    /// @notice Deposit on behalf of another address. Shares are minted to `onBehalfOf`.
    /// @param depositAsset The ERC20 asset to deposit (must be approved to this contract).
    /// @param depositAmount The amount to deposit.
    /// @param onBehalfOf The address that will receive the minted shares.
    /// @param referral An optional referral address (only emitted in event, not used otherwise).
    /// @return shares The number of shares minted.
    function depositFor(ERC20 depositAsset, uint256 depositAmount, address onBehalfOf, address referral)
        external
        nonReentrant
        returns (uint256 shares)
    {
        if (onBehalfOf == address(0)) revert ClawTogetherTeller__ZeroAddress();

        Asset memory asset = _beforeDeposit(depositAsset);
        shares = _erc20Deposit(depositAsset, depositAmount, 0, msg.sender, onBehalfOf, asset);

        emit DepositFor(msg.sender, onBehalfOf, referral, depositAmount, shares);
    }
}
