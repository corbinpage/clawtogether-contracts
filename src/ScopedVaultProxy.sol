// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";

/// @title ScopedVaultProxy
/// @notice Tightly scoped proxy that holds MANAGER_ROLE on the BoringVault but
///         only exposes two operations: withdraw USDC from Aave, and transfer
///         USDC from the vault. This replaces giving the GameRewardsDistributor
///         unrestricted vault.manage() access.
///         Equivalent to a ManagerWithMerkleVerification with a 2-leaf tree, but
///         without the overhead of proof generation, necessary because the
///         winner address in transfer calls is dynamic (unknown at tree-build time).
contract ScopedVaultProxy is Auth {
    // ========================= ERRORS =========================

    error ScopedVaultProxy__ZeroAddress();
    error ScopedVaultProxy__ZeroAmount();
    error ScopedVaultProxy__TransferFailed();
    error ScopedVaultProxy__WithdrawReturnedLessThanRequested(uint256 requested, uint256 actual);

    // ========================= IMMUTABLES =========================

    BoringVault public immutable VAULT;
    address public immutable USDC;
    address public immutable AAVE_POOL;

    // ========================= CONSTRUCTOR =========================

    /// @param _owner     Owner address (for Auth).
    /// @param _authority Shared RolesAuthority.
    /// @param _vault     The BoringVault this proxy controls.
    /// @param _usdc      USDC token on Base.
    /// @param _aavePool  Aave V3 Pool on Base.
    constructor(
        address _owner,
        Authority _authority,
        BoringVault _vault,
        address _usdc,
        address _aavePool
    ) Auth(_owner, _authority) {
        if (address(_vault) == address(0) || _usdc == address(0) || _aavePool == address(0)) {
            revert ScopedVaultProxy__ZeroAddress();
        }
        VAULT = _vault;
        USDC = _usdc;
        AAVE_POOL = _aavePool;
    }

    // ========================= SCOPED OPERATIONS =========================

    /// @notice Withdraw USDC from Aave back to the vault. Hardcoded to only
    ///         withdraw USDC and only to the vault address.
    /// @dev Callable by DISTRIBUTOR_ROLE only.
    /// @param amount Amount of USDC to withdraw from Aave.
    /// @return actualAmount The amount actually withdrawn (from Aave's return value).
    function aaveWithdrawUsdc(uint256 amount) external requiresAuth returns (uint256 actualAmount) {
        if (amount == 0) revert ScopedVaultProxy__ZeroAmount();

        bytes memory returnData = VAULT.manage(
            AAVE_POOL,
            abi.encodeWithSignature(
                "withdraw(address,uint256,address)",
                USDC,
                amount,
                address(VAULT)
            ),
            0
        );

        actualAmount = abi.decode(returnData, (uint256));
        if (actualAmount < amount) {
            revert ScopedVaultProxy__WithdrawReturnedLessThanRequested(amount, actualAmount);
        }
    }

    /// @notice Transfer USDC from the vault to a recipient.
    /// @dev Callable by DISTRIBUTOR_ROLE only.
    /// @param to     Recipient address.
    /// @param amount Amount of USDC to transfer.
    function vaultTransferUsdc(address to, uint256 amount) external requiresAuth {
        if (to == address(0)) revert ScopedVaultProxy__ZeroAddress();
        if (amount == 0) revert ScopedVaultProxy__ZeroAmount();

        bytes memory returnData = VAULT.manage(
            USDC,
            abi.encodeWithSignature("transfer(address,uint256)", to, amount),
            0
        );

        bool success = abi.decode(returnData, (bool));
        if (!success) revert ScopedVaultProxy__TransferFailed();
    }
}
