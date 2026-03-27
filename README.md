# ClawTogether Contracts

A DeFi game vault built on [Veda's Boring Vault](https://github.com/Se7en-Seas/boring-vault) architecture, deployed on Base. The vault accepts USDC deposits, earns yield on Aave V3, and distributes that yield to game winners, a protocol wallet, and vault depositors.

## Architecture

```
+------------------------------------------------------------------+
|                        RolesAuthority                             |
|                   (shared access control)                         |
+---------+---------------+-------------------+--------------------+
          |               |                   |
          v               v                   v
+--------------+  +---------------+  +------------------------+
| BoringVault  |  | ScopedVault   |  | GameRewards            |
|  (gyvUSDC)   |<-|    Proxy      |<-|   Distributor          |<-- GameMaster
|              |  |               |  |                        |
| holds aUSDC  |  | MANAGER_ROLE  |  | DISTRIBUTOR_ROLE       |
| holds USDC   |  | on vault      |  | on proxy               |
+--------------+  +---------------+  +------------------------+
       ^
       | deposit/withdraw
       |
+------+-----------------------------------------------------------+
|  Veda Arctic Architecture (deployed separately)                   |
|  +----------------------+ +-----------------+ +-----------------+ |
|  | TellerWithMultiAsset | |   Accountant    | |    Manager      | |
|  |      Support         | | WithRateProviders| |  WithMerkle    | |
|  +----------------------+ +-----------------+ +-----------------+ |
+-------------------------------------------------------------------+
```

## Contracts

### `BoringVault` (Veda)

The core vault contract. An ERC20 token (`gyvUSDC`, 6 decimals) that also serves as the asset custodian. It holds aUSDC (Aave V3 interest-bearing USDC) and can make arbitrary external calls via `manage()`, gated by `requiresAuth`.

- **Not ERC-4626.** Uses a custom `enter`/`exit` pattern for deposits and withdrawals.
- The vault is intentionally "boring" -- all logic lives in surrounding contracts.

### `ScopedVaultProxy` -- [`src/ScopedVaultProxy.sol`](src/ScopedVaultProxy.sol)

A tightly scoped intermediary that holds `MANAGER_ROLE` on the vault but only exposes two hardcoded operations:

| Function | What it does |
|---|---|
| `aaveWithdrawUsdc(amount)` | Calls `Pool.withdraw(USDC, amount, vault)` -- always withdraws USDC, always to the vault |
| `vaultTransferUsdc(to, amount)` | Calls `USDC.transfer(to, amount)` from the vault |

This replaces giving the distributor unrestricted `vault.manage()` access. Even if the distributor had a bug, it could only withdraw USDC from Aave and transfer USDC -- it cannot touch other assets, approve arbitrary spenders, or make arbitrary calls.

Both functions validate return values: `aaveWithdrawUsdc` reverts if Aave returns less than requested, and `vaultTransferUsdc` reverts if the ERC20 transfer returns false.

### `GameRewardsDistributor` -- [`src/GameRewardsDistributor.sol`](src/GameRewardsDistributor.sol)

The core game logic. Tracks yield accrual via aUSDC balance checkpoints and distributes it on each game round.

#### Roles

| Role | ID | Can call |
|---|---|---|
| **GameMaster** | 20 | `distributeRewards(address winner)` |
| **Owner** | 8 | `setProtocolWallet`, `setFeeSplits`, `resetCheckpoint`, `setPaused` |

#### `distributeRewards(winner)`

Called by the GameMaster at the end of each game round:

1. Reads the vault's current aUSDC balance and compares to the last checkpoint
2. Calculates `totalYield = currentBalance - lastCheckpointBalance`
3. Splits the yield:
   - **Winner** receives `10000 - protocolBps - vaultBps` (default **80%**) -- withdrawn from Aave, sent as USDC
   - **Protocol wallet** receives `protocolBps` (default **10%**) -- withdrawn from Aave, sent as USDC
   - **Vault depositors** keep `vaultBps` (default **10%**) -- stays as aUSDC in the vault, increasing share value
4. Updates the checkpoint
5. Records cumulative rewards for tracking

#### Fee Configuration

The Owner can call `setFeeSplits(protocolBps, vaultBps)` to change the split. The winner's share is always the remainder (`10000 - protocolBps - vaultBps`). Both protocol and vault shares are capped at 50% each, and their sum must be less than 100%.

#### Reward Tracking

Every recipient's cumulative USDC rewards are tracked on-chain:

| Function | Returns |
|---|---|
| `cumulativeRewards(address)` | Total USDC received by an address across all rounds |
| `totalWinnerRewards()` | Sum of all winner payouts |
| `totalProtocolRewards()` | Sum of all protocol payouts |
| `totalVaultRewards()` | Sum of all yield retained by depositors |
| `rewardRecipientCount()` | Number of unique reward recipients |
| `allRewardRecipients()` | All recipients + their cumulative totals |
| `rewardRecipientsPaginated(offset, limit)` | Paginated version for large sets |

#### Safety Features

- **Reentrancy guard** -- `nonReentrant` modifier on `distributeRewards`
- **Checks-effects-interactions** -- checkpoint updated before external calls
- **Pause** -- Owner can call `setPaused(true)` to halt distributions in an emergency
- **Scoped access** -- distributor can only call proxy's two functions, not `vault.manage()` directly

## Access Chain

```
GameMaster EOA
    |
    | distributeRewards(winner)
    v
GameRewardsDistributor  [GAME_MASTER_ROLE required]
    |
    | aaveWithdrawUsdc(amount)
    | vaultTransferUsdc(to, amount)
    v
ScopedVaultProxy        [DISTRIBUTOR_ROLE required]
    |
    | vault.manage(aavePool, withdrawData, 0)
    | vault.manage(usdc, transferData, 0)
    v
BoringVault             [MANAGER_ROLE required]
```

No single contract has more authority than it needs. The proxy can only make USDC-related calls. The distributor can only call the proxy. The GameMaster can only trigger distributions.

## Base Addresses

| Contract | Address |
|---|---|
| USDC | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |
| aBasUSDC | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |

## Development

### Build

```bash
forge build
```

### Test

```bash
forge test -vvv
```

### Deploy

```bash
# Set environment variables
export OWNER=0x...
export PROTOCOL_WALLET=0x...
export GAME_MASTER=0x...

# Deploy to Base
forge script script/DeployGameVault.s.sol --rpc-url base --broadcast
```

### Post-Deployment Steps

1. Deploy Teller, Accountant, and Manager via Veda's [Arctic Architecture](https://github.com/Se7en-Seas/boring-vault) tooling
2. Configure the Teller to accept USDC deposits (no withdrawal queue)
3. Set the Manager's Merkle root to whitelist Aave `supply`/`withdraw` calls
4. Strategist supplies the vault's USDC into Aave V3
5. GameMaster calls `distributeRewards(winner)` at the end of each game round

## License

MIT
