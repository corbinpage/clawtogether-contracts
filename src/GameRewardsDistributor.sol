// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {ScopedVaultProxy} from "./ScopedVaultProxy.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";

/// @title GameRewardsDistributor
/// @notice Distributes accrued Aave yield from a BoringVault to a game winner,
///         a protocol wallet, and vault depositors. Designed to sit alongside
///         Veda's Boring Vault architecture on Base.
contract GameRewardsDistributor is Auth {
    // ========================= ERRORS =========================

    error InvalidBps();
    error ZeroAddress();
    error NoYieldToDistribute();
    error Reentrancy();
    error Paused();

    // ========================= EVENTS =========================

    event RewardsDistributed(
        address indexed winner,
        uint256 winnerAmount,
        uint256 protocolAmount,
        uint256 vaultAmount,
        uint256 totalYield
    );
    event ProtocolWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event FeeSplitsUpdated(uint256 protocolBps, uint256 vaultBps);
    event CheckpointUpdated(uint256 oldCheckpoint, uint256 newCheckpoint);
    event GameMasterUpdated(address indexed gameMaster, bool granted);
    event PauseToggled(bool isPaused);

    // ========================= CONSTANTS =========================

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_PROTOCOL_BPS = 5_000;
    uint256 public constant MAX_VAULT_BPS = 5_000;

    // ========================= IMMUTABLES =========================

    BoringVault public immutable VAULT;
    ERC20 public immutable USDC;
    ERC20 public immutable A_USDC;
    ScopedVaultProxy public immutable PROXY;

    // ========================= STATE =========================

    /// @notice Address that receives the protocol's share of yield.
    address public protocolWallet;

    /// @notice Basis points of yield sent to the protocol wallet.
    uint256 public protocolBps = 1_000; // 10%

    /// @notice Basis points of yield that stays in the vault for depositors.
    uint256 public vaultBps = 1_000; // 10%

    /// @notice aUSDC balance of the vault at last checkpoint.
    uint256 public lastCheckpointBalance;

    /// @notice Pause flag for distributeRewards.
    bool public isPaused;

    /// @notice Reentrancy lock.
    uint256 private _locked = 1;

    // ========================= REWARD TRACKING =========================

    /// @notice Cumulative rewards received by each address (winner or protocol).
    mapping(address => uint256) public cumulativeRewards;

    /// @notice Ordered list of unique addresses that have received rewards.
    address[] private _rewardRecipients;

    /// @notice Whether an address is already in the _rewardRecipients array.
    mapping(address => bool) private _isRecipient;

    /// @notice Total rewards distributed to all winners across all rounds.
    uint256 public totalWinnerRewards;

    /// @notice Total rewards distributed to the protocol wallet across all rounds.
    uint256 public totalProtocolRewards;

    /// @notice Total rewards accrued to vault depositors across all rounds.
    uint256 public totalVaultRewards;

    // ========================= MODIFIERS =========================

    modifier nonReentrant() {
        if (_locked == 2) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    modifier whenNotPaused() {
        if (isPaused) revert Paused();
        _;
    }

    // ========================= CONSTRUCTOR =========================

    /// @param _owner           Admin address.
    /// @param _authority       The RolesAuthority shared with the BoringVault system.
    /// @param _vault           The BoringVault holding the Aave position.
    /// @param _usdc            USDC token address on Base.
    /// @param _aUsdc           aBasUSDC token address on Base.
    /// @param _proxy           The ScopedVaultProxy for tightly scoped vault calls.
    /// @param _protocolWallet  Initial protocol wallet address.
    constructor(
        address _owner,
        Authority _authority,
        BoringVault _vault,
        ERC20 _usdc,
        ERC20 _aUsdc,
        ScopedVaultProxy _proxy,
        address _protocolWallet
    ) Auth(_owner, _authority) {
        if (
            address(_vault) == address(0) || address(_usdc) == address(0) || address(_aUsdc) == address(0)
                || address(_proxy) == address(0) || _protocolWallet == address(0)
        ) {
            revert ZeroAddress();
        }

        VAULT = _vault;
        USDC = _usdc;
        A_USDC = _aUsdc;
        PROXY = _proxy;
        protocolWallet = _protocolWallet;

        lastCheckpointBalance = _aUsdc.balanceOf(address(_vault));
    }

    // ========================= GAME MASTER =========================

    /// @notice Distributes accrued Aave yield since the last checkpoint.
    /// @dev Callable by GAME_MASTER_ROLE (set via RolesAuthority).
    ///      The winner's share is (BPS_DENOMINATOR - protocolBps - vaultBps).
    /// @param winner Address that receives the winner's share of yield.
    function distributeRewards(address winner) external requiresAuth nonReentrant whenNotPaused {
        if (winner == address(0)) revert ZeroAddress();

        uint256 currentBalance = A_USDC.balanceOf(address(VAULT));
        if (currentBalance <= lastCheckpointBalance) revert NoYieldToDistribute();

        uint256 totalYield = currentBalance - lastCheckpointBalance;

        uint256 protocolAmount = (totalYield * protocolBps) / BPS_DENOMINATOR;
        uint256 vaultAmount = (totalYield * vaultBps) / BPS_DENOMINATOR;
        uint256 winnerAmount = totalYield - protocolAmount - vaultAmount;

        uint256 withdrawAmount = winnerAmount + protocolAmount;

        // --- Effects: update checkpoint BEFORE external calls (CEI pattern) ---
        uint256 expectedNewCheckpoint = currentBalance - withdrawAmount;
        emit CheckpointUpdated(lastCheckpointBalance, expectedNewCheckpoint);
        lastCheckpointBalance = expectedNewCheckpoint;

        // Track cumulative rewards
        _recordReward(winner, winnerAmount);
        _recordReward(protocolWallet, protocolAmount);
        totalWinnerRewards += winnerAmount;
        totalProtocolRewards += protocolAmount;
        totalVaultRewards += vaultAmount;

        // --- Interactions: external calls via scoped proxy ---

        // Step 1: Withdraw from Aave (reverts if actual < requested)
        PROXY.aaveWithdrawUsdc(withdrawAmount);

        // Step 2: Transfer winner's share
        if (winnerAmount > 0) {
            PROXY.vaultTransferUsdc(winner, winnerAmount);
        }

        // Step 3: Transfer protocol's share
        if (protocolAmount > 0) {
            PROXY.vaultTransferUsdc(protocolWallet, protocolAmount);
        }

        // Step 4: vaultAmount stays as aUSDC in the vault -- no action needed.

        emit RewardsDistributed(winner, winnerAmount, protocolAmount, vaultAmount, totalYield);
    }

    // ========================= ADMIN =========================

    /// @notice Update the protocol wallet address.
    /// @dev Callable by OWNER_ROLE.
    function setProtocolWallet(address _protocolWallet) external requiresAuth {
        if (_protocolWallet == address(0)) revert ZeroAddress();
        emit ProtocolWalletUpdated(protocolWallet, _protocolWallet);
        protocolWallet = _protocolWallet;
    }

    /// @notice Update the fee split between protocol and vault depositors.
    /// @dev The winner always gets (10000 - protocolBps - vaultBps).
    ///      Callable by OWNER_ROLE.
    /// @param _protocolBps Basis points for the protocol wallet.
    /// @param _vaultBps    Basis points that stay in the vault for depositors.
    function setFeeSplits(uint256 _protocolBps, uint256 _vaultBps) external requiresAuth {
        if (_protocolBps > MAX_PROTOCOL_BPS) revert InvalidBps();
        if (_vaultBps > MAX_VAULT_BPS) revert InvalidBps();
        if (_protocolBps + _vaultBps >= BPS_DENOMINATOR) revert InvalidBps();

        protocolBps = _protocolBps;
        vaultBps = _vaultBps;

        emit FeeSplitsUpdated(_protocolBps, _vaultBps);
    }

    /// @notice Manually reset the checkpoint to the current aUSDC balance.
    /// @dev Callable by OWNER_ROLE.
    function resetCheckpoint() external requiresAuth {
        uint256 newCheckpoint = A_USDC.balanceOf(address(VAULT));
        emit CheckpointUpdated(lastCheckpointBalance, newCheckpoint);
        lastCheckpointBalance = newCheckpoint;
    }

    /// @notice Pause or unpause reward distribution.
    /// @dev Callable by OWNER_ROLE.
    function setPaused(bool _isPaused) external requiresAuth {
        isPaused = _isPaused;
        emit PauseToggled(_isPaused);
    }

    // ========================= VIEW =========================

    /// @notice Returns the yield accrued since the last checkpoint.
    function pendingYield() external view returns (uint256) {
        uint256 currentBalance = A_USDC.balanceOf(address(VAULT));
        if (currentBalance <= lastCheckpointBalance) return 0;
        return currentBalance - lastCheckpointBalance;
    }

    /// @notice Returns the number of unique addresses that have received rewards.
    function rewardRecipientCount() external view returns (uint256) {
        return _rewardRecipients.length;
    }

    /// @notice Returns all addresses that have ever received rewards and their
    ///         cumulative totals.
    function allRewardRecipients()
        external
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        uint256 len = _rewardRecipients.length;
        recipients = new address[](len);
        amounts = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            address r = _rewardRecipients[i];
            recipients[i] = r;
            amounts[i] = cumulativeRewards[r];
        }
    }

    /// @notice Returns a paginated slice of reward recipients.
    /// @param offset Start index.
    /// @param limit  Max entries to return.
    function rewardRecipientsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory recipients, uint256[] memory amounts)
    {
        uint256 len = _rewardRecipients.length;
        if (offset >= len) {
            return (new address[](0), new uint256[](0));
        }
        uint256 end = offset + limit;
        if (end > len) end = len;
        uint256 size = end - offset;
        recipients = new address[](size);
        amounts = new uint256[](size);
        for (uint256 i; i < size; ++i) {
            address r = _rewardRecipients[offset + i];
            recipients[i] = r;
            amounts[i] = cumulativeRewards[r];
        }
    }

    // ========================= INTERNAL =========================

    /// @dev Records a reward for an address. Adds to the recipient set if new.
    function _recordReward(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        cumulativeRewards[recipient] += amount;
        if (!_isRecipient[recipient]) {
            _isRecipient[recipient] = true;
            _rewardRecipients.push(recipient);
        }
    }
}
