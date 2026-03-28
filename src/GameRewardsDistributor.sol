// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {ManagerWithMerkleVerification} from "boring-vault/base/Roles/ManagerWithMerkleVerification.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "@solmate/utils/SafeTransferLib.sol";
import {Auth, Authority} from "@solmate/auth/Auth.sol";

/// @title GameRewardsDistributor
/// @notice Distributes accrued Aave yield from a BoringVault to up to 10 game
///         winners, a protocol wallet, and vault depositors. Uses Veda's
///         ManagerWithMerkleVerification for scoped vault operations with a
///         4-leaf Merkle tree (approve, supply, withdraw, transfer-to-self).
contract GameRewardsDistributor is Auth {
    using SafeTransferLib for ERC20;

    // ========================= ERRORS =========================

    error InvalidBps();
    error ZeroAddress();
    error NoYieldToDistribute();
    error Reentrancy();
    error Paused();
    error TooManyWinners();
    error ArrayLengthMismatch();
    error WinnerBpsMustTotal10000();
    error MerkleProofsNotSet();

    // ========================= EVENTS =========================

    event RewardsDistributed(
        address[] winners,
        uint256[] winnerAmounts,
        uint256 protocolAmount,
        uint256 vaultAmount,
        uint256 totalYield
    );
    event ProtocolWalletUpdated(address indexed oldWallet, address indexed newWallet);
    event FeeSplitsUpdated(uint256 protocolBps, uint256 vaultBps);
    event CheckpointUpdated(uint256 oldCheckpoint, uint256 newCheckpoint);
    event PauseToggled(bool isPaused);
    event MerkleProofsSet();

    // ========================= CONSTANTS =========================

    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_PROTOCOL_BPS = 5_000;
    uint256 public constant MAX_VAULT_BPS = 5_000;
    uint256 public constant MAX_WINNERS = 10;

    // ========================= IMMUTABLES =========================

    BoringVault public immutable VAULT;
    ERC20 public immutable USDC;
    ERC20 public immutable A_USDC;
    ManagerWithMerkleVerification public immutable MANAGER;
    address public immutable DECODER;
    address public immutable AAVE_POOL;

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

    // ========================= MERKLE PROOF STORAGE =========================

    /// @notice Stored Merkle proofs for the 4 allowed vault operations.
    ///         Set once via setMerkleProofs after deployment and Merkle root setup.
    bytes32[] private _approveProof;
    bytes32[] private _supplyProof;
    bytes32[] private _withdrawProof;
    bytes32[] private _transferProof;

    /// @notice Whether Merkle proofs have been initialized.
    bool public merkleProofsSet;

    // ========================= REWARD TRACKING =========================

    mapping(address => uint256) public cumulativeRewards;
    address[] private _rewardRecipients;
    mapping(address => bool) private _isRecipient;
    uint256 public totalWinnerRewards;
    uint256 public totalProtocolRewards;
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
    /// @param _manager         The ManagerWithMerkleVerification for scoped vault calls.
    /// @param _decoder         The ClawTogetherDecoderAndSanitizer address.
    /// @param _aavePool        The Aave V3 Pool address on Base.
    /// @param _protocolWallet  Initial protocol wallet address.
    constructor(
        address _owner,
        Authority _authority,
        BoringVault _vault,
        ERC20 _usdc,
        ERC20 _aUsdc,
        ManagerWithMerkleVerification _manager,
        address _decoder,
        address _aavePool,
        address _protocolWallet
    ) Auth(_owner, _authority) {
        if (
            address(_vault) == address(0) || address(_usdc) == address(0) || address(_aUsdc) == address(0)
                || address(_manager) == address(0) || _decoder == address(0) || _aavePool == address(0)
                || _protocolWallet == address(0)
        ) {
            revert ZeroAddress();
        }

        VAULT = _vault;
        USDC = _usdc;
        A_USDC = _aUsdc;
        MANAGER = _manager;
        DECODER = _decoder;
        AAVE_POOL = _aavePool;
        protocolWallet = _protocolWallet;

        lastCheckpointBalance = _aUsdc.balanceOf(address(_vault));
    }

    // ========================= MERKLE PROOF SETUP =========================

    /// @notice Store the Merkle proofs for the 4 allowed vault operations.
    ///         Must be called after the Merkle root is set on the Manager.
    /// @dev Callable by OWNER_ROLE. The proofs correspond to these leaves:
    ///      - approve:  USDC.approve(AAVE_POOL, amount)
    ///      - supply:   AAVE_POOL.supply(USDC, amount, VAULT, 0)
    ///      - withdraw: AAVE_POOL.withdraw(USDC, amount, VAULT)
    ///      - transfer: USDC.transfer(distributor, amount)
    function setMerkleProofs(
        bytes32[] calldata approveProof,
        bytes32[] calldata supplyProof,
        bytes32[] calldata withdrawProof,
        bytes32[] calldata transferProof
    ) external requiresAuth {
        _approveProof = approveProof;
        _supplyProof = supplyProof;
        _withdrawProof = withdrawProof;
        _transferProof = transferProof;
        merkleProofsSet = true;
        emit MerkleProofsSet();
    }

    // ========================= GAME MASTER =========================

    /// @notice Distributes accrued Aave yield since the last checkpoint.
    /// @dev Flow: Aave → vault (withdraw) → distributor (transfer) → winners/protocol (direct).
    function distributeRewards(address[] calldata winners, uint256[] calldata winnerBps)
        external
        requiresAuth
        nonReentrant
        whenNotPaused
    {
        if (!merkleProofsSet) revert MerkleProofsNotSet();
        if (winners.length == 0 || winners.length > MAX_WINNERS) revert TooManyWinners();
        if (winners.length != winnerBps.length) revert ArrayLengthMismatch();

        {
            uint256 bpsSum;
            for (uint256 i; i < winners.length; ++i) {
                if (winners[i] == address(0)) revert ZeroAddress();
                bpsSum += winnerBps[i];
            }
            if (bpsSum != BPS_DENOMINATOR) revert WinnerBpsMustTotal10000();
        }

        uint256 currentBalance = A_USDC.balanceOf(address(VAULT));
        if (currentBalance <= lastCheckpointBalance) revert NoYieldToDistribute();

        uint256 totalYield = currentBalance - lastCheckpointBalance;

        uint256 protocolAmount = (totalYield * protocolBps) / BPS_DENOMINATOR;
        uint256 vaultAmount = (totalYield * vaultBps) / BPS_DENOMINATOR;
        uint256 totalWinnerAmount = totalYield - protocolAmount - vaultAmount;

        // --- Effects: update checkpoint BEFORE external calls (CEI pattern) ---
        {
            uint256 withdrawAmount = totalWinnerAmount + protocolAmount;
            uint256 expectedNewCheckpoint = currentBalance - withdrawAmount;
            emit CheckpointUpdated(lastCheckpointBalance, expectedNewCheckpoint);
            lastCheckpointBalance = expectedNewCheckpoint;
        }

        uint256[] memory winnerAmounts = _calcWinnerAmounts(winners.length, winnerBps, totalWinnerAmount);

        for (uint256 i; i < winners.length; ++i) {
            _recordReward(winners[i], winnerAmounts[i]);
        }
        _recordReward(protocolWallet, protocolAmount);
        totalWinnerRewards += totalWinnerAmount;
        totalProtocolRewards += protocolAmount;
        totalVaultRewards += vaultAmount;

        // --- Interactions ---
        _executeTransfers(winners, winnerAmounts, protocolAmount);

        emit RewardsDistributed(winners, winnerAmounts, protocolAmount, vaultAmount, totalYield);
    }

    function _calcWinnerAmounts(
        uint256 count,
        uint256[] calldata winnerBps,
        uint256 totalWinnerAmount
    ) internal pure returns (uint256[] memory amounts) {
        amounts = new uint256[](count);
        uint256 distributed;
        for (uint256 i; i < count; ++i) {
            if (i == count - 1) {
                amounts[i] = totalWinnerAmount - distributed;
            } else {
                amounts[i] = (totalWinnerAmount * winnerBps[i]) / BPS_DENOMINATOR;
                distributed += amounts[i];
            }
        }
    }

    /// @dev Withdraws from Aave via Manager, transfers USDC to this contract,
    ///      then distributes directly to winners and protocol wallet.
    function _executeTransfers(
        address[] calldata winners,
        uint256[] memory winnerAmounts,
        uint256 protocolAmount
    ) internal {
        uint256 withdrawAmount;
        for (uint256 i; i < winnerAmounts.length; ++i) {
            withdrawAmount += winnerAmounts[i];
        }
        withdrawAmount += protocolAmount;

        // Step 1: Via Manager — withdraw from Aave + transfer USDC to this contract
        _managerWithdrawAndTransferToSelf(withdrawAmount);

        // Step 2: Direct ERC20 transfers from this contract to recipients
        for (uint256 i; i < winners.length; ++i) {
            if (winnerAmounts[i] > 0) {
                USDC.safeTransfer(winners[i], winnerAmounts[i]);
            }
        }
        if (protocolAmount > 0) {
            USDC.safeTransfer(protocolWallet, protocolAmount);
        }
    }

    // ========================= ADMIN =========================

    function setProtocolWallet(address _protocolWallet) external requiresAuth {
        if (_protocolWallet == address(0)) revert ZeroAddress();
        emit ProtocolWalletUpdated(protocolWallet, _protocolWallet);
        protocolWallet = _protocolWallet;
    }

    function setFeeSplits(uint256 _protocolBps, uint256 _vaultBps) external requiresAuth {
        if (_protocolBps > MAX_PROTOCOL_BPS) revert InvalidBps();
        if (_vaultBps > MAX_VAULT_BPS) revert InvalidBps();
        if (_protocolBps + _vaultBps >= BPS_DENOMINATOR) revert InvalidBps();
        protocolBps = _protocolBps;
        vaultBps = _vaultBps;
        emit FeeSplitsUpdated(_protocolBps, _vaultBps);
    }

    function resetCheckpoint() external requiresAuth {
        uint256 newCheckpoint = A_USDC.balanceOf(address(VAULT));
        emit CheckpointUpdated(lastCheckpointBalance, newCheckpoint);
        lastCheckpointBalance = newCheckpoint;
    }

    /// @notice Atomically supply USDC from the vault into Aave and adjust checkpoint.
    function supplyAndCheckpoint(uint256 amount) external requiresAuth nonReentrant {
        if (!merkleProofsSet) revert MerkleProofsNotSet();
        uint256 oldCheckpoint = lastCheckpointBalance;
        _managerApproveAndSupply(amount);
        lastCheckpointBalance = oldCheckpoint + amount;
        emit CheckpointUpdated(oldCheckpoint, lastCheckpointBalance);
    }

    /// @notice Atomically withdraw USDC from Aave, send to recipient, and adjust checkpoint.
    function withdrawAndCheckpoint(uint256 amount, address to) external requiresAuth nonReentrant {
        if (!merkleProofsSet) revert MerkleProofsNotSet();
        if (to == address(0)) revert ZeroAddress();
        uint256 oldCheckpoint = lastCheckpointBalance;

        // Withdraw from Aave + transfer to this contract via Manager
        _managerWithdrawAndTransferToSelf(amount);

        // Direct transfer from this contract to recipient
        USDC.safeTransfer(to, amount);

        uint256 newCheckpoint = amount > oldCheckpoint ? 0 : oldCheckpoint - amount;
        lastCheckpointBalance = newCheckpoint;
        emit CheckpointUpdated(oldCheckpoint, newCheckpoint);
    }

    /// @notice Manual fallback for correcting drift or reconciliation.
    function adjustCheckpoint(int256 delta) external requiresAuth {
        uint256 oldCheckpoint = lastCheckpointBalance;
        uint256 newCheckpoint;
        if (delta >= 0) {
            newCheckpoint = oldCheckpoint + uint256(delta);
        } else {
            uint256 absDelta = uint256(-delta);
            newCheckpoint = absDelta > oldCheckpoint ? 0 : oldCheckpoint - absDelta;
        }
        emit CheckpointUpdated(oldCheckpoint, newCheckpoint);
        lastCheckpointBalance = newCheckpoint;
    }

    function setPaused(bool _isPaused) external requiresAuth {
        isPaused = _isPaused;
        emit PauseToggled(_isPaused);
    }

    // ========================= VIEW =========================

    function pendingYield() external view returns (uint256) {
        uint256 currentBalance = A_USDC.balanceOf(address(VAULT));
        if (currentBalance <= lastCheckpointBalance) return 0;
        return currentBalance - lastCheckpointBalance;
    }

    function rewardRecipientCount() external view returns (uint256) {
        return _rewardRecipients.length;
    }

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

    // ========================= INTERNAL: MANAGER CALLS =========================

    /// @dev Copies a storage proof array to memory.
    function _loadProof(bytes32[] storage proof) internal view returns (bytes32[] memory) {
        uint256 len = proof.length;
        bytes32[] memory result = new bytes32[](len);
        for (uint256 i; i < len; ++i) {
            result[i] = proof[i];
        }
        return result;
    }

    /// @dev Via Manager: withdraw from Aave + transfer USDC from vault to this contract.
    ///      2 batched calls in one manageVaultWithMerkleVerification.
    function _managerWithdrawAndTransferToSelf(uint256 amount) internal {
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = _loadProof(_withdrawProof);
        proofs[1] = _loadProof(_transferProof);

        address[] memory decoders = new address[](2);
        decoders[0] = DECODER;
        decoders[1] = DECODER;

        address[] memory targets = new address[](2);
        targets[0] = AAVE_POOL;
        targets[1] = address(USDC);

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature(
            "withdraw(address,uint256,address)", address(USDC), amount, address(VAULT)
        );
        data[1] = abi.encodeWithSignature(
            "transfer(address,uint256)", address(this), amount
        );

        uint256[] memory values = new uint256[](2);

        MANAGER.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    /// @dev Via Manager: approve Aave pool + supply USDC from vault to Aave.
    ///      2 batched calls in one manageVaultWithMerkleVerification.
    function _managerApproveAndSupply(uint256 amount) internal {
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = _loadProof(_approveProof);
        proofs[1] = _loadProof(_supplyProof);

        address[] memory decoders = new address[](2);
        decoders[0] = DECODER;
        decoders[1] = DECODER;

        address[] memory targets = new address[](2);
        targets[0] = address(USDC);
        targets[1] = AAVE_POOL;

        bytes[] memory data = new bytes[](2);
        data[0] = abi.encodeWithSignature(
            "approve(address,uint256)", AAVE_POOL, amount
        );
        data[1] = abi.encodeWithSignature(
            "supply(address,uint256,address,uint16)", address(USDC), amount, address(VAULT), uint16(0)
        );

        uint256[] memory values = new uint256[](2);

        MANAGER.manageVaultWithMerkleVerification(proofs, decoders, targets, data, values);
    }

    // ========================= INTERNAL: REWARD TRACKING =========================

    function _recordReward(address recipient, uint256 amount) internal {
        if (amount == 0) return;
        cumulativeRewards[recipient] += amount;
        if (!_isRecipient[recipient]) {
            _isRecipient[recipient] = true;
            _rewardRecipients.push(recipient);
        }
    }
}
