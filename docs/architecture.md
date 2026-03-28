# ClawTogether Contract Architecture

## System Overview

```mermaid
graph TB
    subgraph External Actors
        GM["Game Master<br/><i>GAME_MASTER_ROLE</i>"]
        OW["Owner / Operator<br/><i>OWNER_ROLE</i>"]
        USER["User / Depositor"]
    end

    subgraph Veda Arctic Architecture
        TELLER["TellerWithMultiAssetSupport<br/><i>deposit & mint shares</i>"]
        ACCOUNTANT["AccountantWithRateProviders<br/><i>share pricing & exchange rates</i>"]
        DELAYED["DelayedWithdraw<br/><i>1-day withdrawal queue</i>"]
        VAULT["BoringVault<br/><i>holds aUSDC position</i><br/>clawUSDC shares"]
        MANAGER["ManagerWithMerkleVerification<br/><i>Merkle-scoped vault operations</i>"]
    end

    subgraph ClawTogether Contracts
        DECODER["ClawTogetherDecoderAndSanitizer<br/><i>calldata address extraction</i>"]
        DIST["GameRewardsDistributor<br/><i>yield accounting & distribution</i>"]
    end

    subgraph External Protocol
        AAVE["Aave V3 Pool<br/><i>USDC lending</i>"]
        USDC_TOK["USDC"]
        AUSDC["aBasUSDC<br/><i>yield-bearing token</i>"]
    end

    subgraph Recipients
        WINNERS["Winners (up to 10)"]
        PROTOCOL["Protocol Wallet"]
        DEPOSITORS["Vault Depositors<br/><i>yield stays as aUSDC</i>"]
    end

    USER -->|"deposit USDC"| TELLER
    TELLER -->|"mint clawUSDC shares"| VAULT
    USER -->|"request withdrawal"| DELAYED
    DELAYED -->|"after 1-day delay<br/>burn shares, return USDC"| USER

    GM -->|"distributeRewards(winners, bps)"| DIST
    GM -->|"supplyAndCheckpoint(amount)"| DIST
    GM -->|"withdrawAndCheckpoint(amount, to)"| DIST
    OW -->|"setFeeSplits / setPaused<br/>resetCheckpoint / adjustCheckpoint"| DIST

    DIST -->|"manageVaultWithMerkleVerification<br/>(proofs + calldata)"| MANAGER
    MANAGER -->|"verify Merkle proof<br/>+ decode via"| DECODER
    MANAGER -->|"vault.manage(approve)"| VAULT
    MANAGER -->|"vault.manage(pool.supply)"| VAULT
    MANAGER -->|"vault.manage(pool.withdraw)"| VAULT
    MANAGER -->|"vault.manage(usdc.transfer)"| VAULT

    VAULT <-->|"supply / withdraw"| AAVE
    AAVE -->|"mints"| AUSDC
    AAVE -->|"returns"| USDC_TOK
    VAULT -->|"USDC transfer"| DIST
    DIST -->|"safeTransfer USDC"| WINNERS
    DIST -->|"safeTransfer USDC"| PROTOCOL
    AUSDC -.->|"yield accrues<br/>(balance grows)"| DEPOSITORS

    ACCOUNTANT -.->|"rate oracle"| TELLER
    ACCOUNTANT -.->|"rate oracle"| DELAYED

    classDef external fill:#e1f5fe,stroke:#0288d1
    classDef veda fill:#f3e5f5,stroke:#7b1fa2
    classDef claw fill:#e8f5e9,stroke:#388e3c
    classDef protocol fill:#fff3e0,stroke:#f57c00
    classDef recipient fill:#fce4ec,stroke:#c62828
    classDef actor fill:#fffde7,stroke:#f9a825

    class GM,OW,USER actor
    class TELLER,ACCOUNTANT,DELAYED,VAULT,MANAGER veda
    class DECODER,DIST claw
    class AAVE,USDC_TOK,AUSDC protocol
    class WINNERS,PROTOCOL,DEPOSITORS recipient
```

## Reward Distribution Flow

```mermaid
sequenceDiagram
    autonumber
    participant GM as Game Master
    participant DIST as GameRewardsDistributor
    participant MGR as ManagerWithMerkleVerification
    participant VAULT as BoringVault
    participant AAVE as Aave V3 Pool
    participant W as Winners
    participant P as Protocol Wallet

    Note over DIST: aUSDC balance has grown<br/>since last checkpoint (yield)

    GM->>DIST: distributeRewards(winners, bps)
    activate DIST

    Note over DIST: Checks: auth, not paused,<br/>not reentrant, valid arrays

    DIST->>DIST: totalYield = aUSDC.balanceOf(vault) - lastCheckpoint
    DIST->>DIST: protocolAmount = totalYield * protocolBps / 10000
    DIST->>DIST: vaultAmount = totalYield * vaultBps / 10000
    DIST->>DIST: winnerTotal = totalYield - protocolAmount - vaultAmount

    Note over DIST: Update checkpoint BEFORE<br/>external calls (CEI pattern)
    DIST->>DIST: lastCheckpointBalance = newCheckpoint

    DIST->>MGR: manageVaultWithMerkleVerification<br/>(withdraw + transfer proofs)
    activate MGR
    MGR->>VAULT: manage(pool.withdraw(USDC, amount, vault))
    VAULT->>AAVE: withdraw(USDC, amount, vault)
    AAVE-->>VAULT: USDC returned to vault
    MGR->>VAULT: manage(usdc.transfer(distributor, amount))
    VAULT-->>DIST: USDC transferred to distributor
    deactivate MGR

    loop For each winner
        DIST->>W: safeTransfer(USDC, winner, amount)
    end

    DIST->>P: safeTransfer(USDC, protocolWallet, amount)

    Note over VAULT: vaultAmount stays as aUSDC<br/>(no action needed)

    DIST-->>GM: emit RewardsDistributed
    deactivate DIST
```

## Atomic Deposit Flow (supplyAndCheckpoint)

```mermaid
sequenceDiagram
    autonumber
    participant GM as Game Master
    participant DIST as GameRewardsDistributor
    participant MGR as ManagerWithMerkleVerification
    participant VAULT as BoringVault
    participant AAVE as Aave V3 Pool

    Note over VAULT: USDC already in vault<br/>(from user deposit via Teller)

    GM->>DIST: supplyAndCheckpoint(amount)
    activate DIST

    DIST->>MGR: manageVaultWithMerkleVerification<br/>(approve + supply proofs)
    activate MGR
    MGR->>VAULT: manage(usdc.approve(pool, amount))
    MGR->>VAULT: manage(pool.supply(USDC, amount, vault, 0))
    VAULT->>AAVE: supply(USDC, amount, vault, 0)
    AAVE-->>VAULT: aUSDC minted to vault
    deactivate MGR

    DIST->>DIST: lastCheckpointBalance += amount

    Note over DIST: Atomic: checkpoint always<br/>matches actual Aave supply.<br/>Deposit cannot be mistaken<br/>for yield.

    deactivate DIST
```

## Atomic Withdrawal Flow (withdrawAndCheckpoint)

```mermaid
sequenceDiagram
    autonumber
    participant GM as Game Master
    participant DIST as GameRewardsDistributor
    participant MGR as ManagerWithMerkleVerification
    participant VAULT as BoringVault
    participant AAVE as Aave V3 Pool
    participant USER as Recipient

    GM->>DIST: withdrawAndCheckpoint(amount, user)
    activate DIST

    DIST->>MGR: manageVaultWithMerkleVerification<br/>(withdraw + transfer proofs)
    activate MGR
    MGR->>VAULT: manage(pool.withdraw(USDC, amount, vault))
    VAULT->>AAVE: withdraw(USDC, amount, vault)
    AAVE-->>VAULT: USDC returned
    MGR->>VAULT: manage(usdc.transfer(distributor, amount))
    VAULT-->>DIST: USDC transferred to distributor
    deactivate MGR

    DIST->>USER: safeTransfer(USDC, user, amount)

    DIST->>DIST: lastCheckpointBalance -= amount

    Note over DIST: Atomic: checkpoint always<br/>matches actual Aave withdrawal.<br/>Withdrawal cannot create<br/>phantom negative yield.

    deactivate DIST
```

## Merkle Tree Structure

```mermaid
graph TB
    ROOT["Merkle Root<br/><i>set via manager.setManageRoot(distributor, root)</i>"]

    H01["Hash(Leaf0, Leaf1)"]
    H23["Hash(Leaf2, Leaf3)"]

    L0["Leaf 0: approve<br/><code>keccak256(decoder, USDC, approve.selector, [aavePool])</code>"]
    L1["Leaf 1: supply<br/><code>keccak256(decoder, aavePool, supply.selector, [USDC, vault])</code>"]
    L2["Leaf 2: withdraw<br/><code>keccak256(decoder, aavePool, withdraw.selector, [USDC, vault])</code>"]
    L3["Leaf 3: transfer<br/><code>keccak256(decoder, USDC, transfer.selector, [distributor])</code>"]

    ROOT --> H01
    ROOT --> H23
    H01 --> L0
    H01 --> L1
    H23 --> L2
    H23 --> L3

    classDef root fill:#e8eaf6,stroke:#283593
    classDef internal fill:#e3f2fd,stroke:#1565c0
    classDef leaf fill:#e8f5e9,stroke:#2e7d32

    class ROOT root
    class H01,H23 internal
    class L0,L1,L2,L3 leaf
```

## Access Control (RolesAuthority)

```mermaid
graph LR
    subgraph Roles
        GMR["GAME_MASTER_ROLE (20)"]
        OWR["OWNER_ROLE (8)"]
        MGR["MANAGER_ROLE (1)"]
        STRAT["STRATEGIST_ROLE (21)"]
    end

    subgraph "GameRewardsDistributor Functions"
        DR["distributeRewards()"]
        SAC["supplyAndCheckpoint()"]
        WAC["withdrawAndCheckpoint()"]
        AC["adjustCheckpoint()"]
        RC["resetCheckpoint()"]
        SPW["setProtocolWallet()"]
        SFS["setFeeSplits()"]
        SP["setPaused()"]
        SMP["setMerkleProofs()"]
    end

    subgraph "ManagerWithMerkleVerification Functions"
        MVM["manageVaultWithMerkleVerification()"]
    end

    subgraph "BoringVault Functions"
        MNG["manage()"]
    end

    GMR -->|"can call"| DR
    GMR -->|"can call"| SAC
    GMR -->|"can call"| WAC
    OWR -->|"can call"| AC
    OWR -->|"can call"| RC
    OWR -->|"can call"| SPW
    OWR -->|"can call"| SFS
    OWR -->|"can call"| SP
    OWR -->|"can call"| SMP

    STRAT -->|"can call"| MVM

    MGR -->|"can call"| MNG

    subgraph "Role Assignments"
        direction LR
        A1["Game Master address → GAME_MASTER_ROLE"]
        A2["Owner address → OWNER_ROLE"]
        A3["ManagerWithMerkleVerification → MANAGER_ROLE"]
        A4["GameRewardsDistributor → STRATEGIST_ROLE"]
    end

    classDef role fill:#e3f2fd,stroke:#1565c0
    classDef func fill:#f1f8e9,stroke:#558b2f
    classDef assignment fill:#fff8e1,stroke:#ff8f00

    class GMR,OWR,MGR,STRAT role
    class DR,SAC,WAC,AC,RC,SPW,SFS,SP,SMP,MVM,MNG func
    class A1,A2,A3,A4 assignment
```

## Fee Split (Default: 80 / 10 / 10)

```mermaid
pie title Yield Distribution (Default BPS)
    "Winners (8000 bps)" : 80
    "Protocol Wallet (1000 bps)" : 10
    "Vault Depositors (1000 bps)" : 10
```
