# ClawTogether Contracts

A DeFi game vault built on [Veda's Boring Vault](https://github.com/Se7en-Seas/boring-vault) architecture, deployed on Base. The vault accepts USDC deposits, earns yield on Aave V3, and distributes that yield to game winners, a protocol wallet, and vault depositors. Users withdraw via a 1-day delayed withdrawal queue.

## Architecture

```
+-------------------------------------------------------------------------+
|                          RolesAuthority                                  |
|                     (shared access control)                              |
+--+--------+--------+--------+---------+--------+-----------------------+
   |        |        |        |         |        |
   v        v        v        v         v        v
+------+ +------+ +------+ +--------+ +-------+ +----------+
|Boring| |Accoun| |Teller| |Delayed | |Manager| |GameReward|
|Vault | |tant  | |      | |Withdraw| |Merkle | |Distribut.|<-- GameMaster
|(clawUSDC)       |      | |(1 day) | |Verify | |          |
+------+ +------+ +------+ +--------+ +-------+ +----------+
   ^        |   enter()|  exit()  | manage() |      |
   +--------+----------+----------+----------+------+
```

### How It Works

**Depositing:**
1. User approves USDC to the vault address
2. User calls `teller.deposit(USDC, amount, minimumShares)`
3. Teller calls `vault.enter()` -- USDC transfers in, `clawUSDC` shares mint to user

**Earning Yield:**
1. Vault's USDC is supplied to Aave V3 (via ManagerWithMerkleVerification or external strategist)
2. Aave yield accrues as the vault's aUSDC balance grows

**Game Rewards (per round):**
1. GameMaster calls `distributor.distributeRewards(winner)`
2. Yield since last checkpoint is split: 80% winner, 10% protocol, 10% vault depositors
3. Winner and protocol receive USDC; vault depositors' share stays as aUSDC

**Withdrawing (1-day delay):**
1. User approves vault shares to DelayedWithdraw
2. User calls `delayedWithdraw.requestWithdraw(USDC, shares, maxLoss, allowThirdParty)`
3. After 1 day, user calls `delayedWithdraw.completeWithdraw(USDC, user)` -- shares burn, USDC sent
4. Users can `cancelWithdraw()` anytime to get shares back

## Contracts

### `BoringVault` (Veda)

ERC20 vault token (`clawUSDC`, 6 decimals) and asset custodian. Holds aUSDC and USDC. All external calls go through `manage()`, gated by `requiresAuth`.

### `AccountantWithRateProviders` (Veda)

Tracks the USDC/share exchange rate. Used by Teller for deposit pricing and DelayedWithdraw for slippage protection.

### `TellerWithMultiAssetSupport` (Veda)

Handles USDC deposits. Configured with deposits enabled, direct withdrawals disabled (use DelayedWithdraw). Also serves as the vault's `beforeTransferHook` for share lock enforcement.

### `DelayedWithdraw` (Veda)

Handles user withdrawals with a 1-day time delay.

| Parameter | Value | Description |
|---|---|---|
| Withdraw delay | 1 day | Time user must wait after requesting |
| Completion window | 7 days | Window to complete after maturity |
| Withdraw fee | 0% | No fee on withdrawals |
| Max loss | 1% | Max exchange rate slippage allowed |
| Pull from vault | true | Pulls USDC from vault on completion |

### `ManagerWithMerkleVerification` (Veda)

Merkle tree-based permission system that holds `MANAGER_ROLE` on the vault. Each allowed vault operation is a leaf in a Merkle tree (target address + decoder + function selector). The `GameRewardsDistributor` calls `manageVaultWithMerkleVerification()` with proofs to execute scoped operations. Four leaves are configured:

| Leaf | Operation |
|---|---|
| `approve` | `USDC.approve(aavePool, amount)` |
| `supply` | `Pool.supply(USDC, amount, vault, 0)` |
| `withdraw` | `Pool.withdraw(USDC, amount, vault)` |
| `transfer` | `USDC.transfer(distributor, amount)` |

### `ClawTogetherDecoderAndSanitizer` -- [`src/ClawTogetherDecoderAndSanitizer.sol`](src/ClawTogetherDecoderAndSanitizer.sol)

Extracts and validates address arguments from calldata for Merkle leaf verification. Combines Aave V3 decoder with the base decoder.

### `GameRewardsDistributor` -- [`src/GameRewardsDistributor.sol`](src/GameRewardsDistributor.sol)

Core game logic. Tracks yield via aUSDC balance checkpoints and distributes on each game round.

#### `distributeRewards(winner)`

1. Reads vault's current aUSDC balance vs last checkpoint
2. Calculates `totalYield = currentBalance - lastCheckpointBalance`
3. Splits: **80% winner** (configurable), **10% protocol**, **10% vault depositors**
4. Winner + protocol shares withdrawn from Aave and sent as USDC
5. Vault depositors' share stays as aUSDC, increasing share value
6. Records cumulative rewards on-chain

#### Reward Tracking

| Function | Returns |
|---|---|
| `cumulativeRewards(address)` | Total USDC received by an address across all rounds |
| `totalWinnerRewards()` | Sum of all winner payouts |
| `totalProtocolRewards()` | Sum of all protocol payouts |
| `totalVaultRewards()` | Sum of all yield retained by depositors |
| `allRewardRecipients()` | All recipients + cumulative totals |
| `rewardRecipientsPaginated(offset, limit)` | Paginated version for large sets |

## Access Control

```
User (Public)
  ├─ teller.deposit()
  ├─ delayedWithdraw.requestWithdraw()
  ├─ delayedWithdraw.cancelWithdraw()
  └─ delayedWithdraw.completeWithdraw()

GameMaster EOA
  ├─ distributor.distributeRewards(winner)
  ├─ distributor.supplyAndCheckpoint(amount)
  └─ distributor.withdrawAndCheckpoint(amount, to)

Owner EOA
  ├─ distributor: setProtocolWallet, setFeeSplits, resetCheckpoint, setPaused
  ├─ teller: updateAssetData
  ├─ accountant: updateExchangeRate
  └─ delayedWithdraw: setupWithdrawAsset, changeWithdrawDelay, changeMaxLoss, pause/unpause
```

| Role | ID | Assigned To | Purpose |
|---|---|---|---|
| `MANAGER_ROLE` | 1 | ManagerWithMerkleVerification | `vault.manage()` |
| `TELLER_ROLE` | 2 | Teller | `vault.enter()` |
| `DELAYED_WITHDRAW_ROLE` | 3 | DelayedWithdraw | `vault.exit()` |
| `OWNER_ROLE` | 8 | Owner EOA | Admin config |
| `GAME_MASTER_ROLE` | 20 | GameMaster EOA | `distributeRewards` |
| `STRATEGIST_ROLE` | 21 | GameRewardsDistributor | `manager.manageVaultWithMerkleVerification` |

## Withdrawal Flow

```
User                    DelayedWithdraw                        Vault
  │                          │                                    │
  ├─requestWithdraw()───────>│                                    │
  │  (shares lock)           │                                    │
  │                          │                                    │
  │  ~~~ 1 day passes ~~~   │                                    │
  │                          │                                    │
  ├─completeWithdraw()──────>│                                    │
  │                          ├─vault.exit()──────────────────────>│
  │                          │                         (burn shares, send USDC)
  │<──────── USDC ───────────┘                                    │
```

## Base Addresses

| Contract | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| aBasUSDC | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| WETH | `0x4200000000000000000000000000000000000006` |

## Development

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

47 unit tests (GameRewardsDistributor) + 8 integration tests (Teller deposit + DelayedWithdraw + game rewards).

### Deploy

```bash
export OWNER=0x...
export PROTOCOL_WALLET=0x...
export GAME_MASTER=0x...

forge script script/DeployGameVault.s.sol --rpc-url base --broadcast
```

The deploy script handles the full system: BoringVault, Accountant, Teller, DelayedWithdraw, ManagerWithMerkleVerification, ClawTogetherDecoderAndSanitizer, GameRewardsDistributor, and all role/permission configuration.

**Post-deploy (owner must do manually):**
1. Compute Merkle tree (4 leaves: approve, supply, withdraw, transfer)
2. Call `manager.setManageRoot(distributor, merkleRoot)`
3. Call `distributor.setMerkleProofs(approveProof, supplyProof, withdrawProof, transferProof)`

### Post-Deployment Checklist

1. Verify all contracts on Basescan
2. Confirm RolesAuthority ownership transferred to OWNER
3. Supply vault USDC to Aave V3
4. Update Accountant exchange rate as yield accrues
5. GameMaster calls `distributeRewards(winner)` at the end of each game round

## License

MIT
