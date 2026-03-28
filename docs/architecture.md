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
        VAULT["BoringVault<br/><i>holds aUSDC position</i><br/>gyvUSDC shares"]
    end

    subgraph ClawTogether Contracts
        PROXY["ScopedVaultProxy<br/><i>MANAGER_ROLE on vault</i>"]
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
    TELLER -->|"mint gyvUSDC shares"| VAULT
    USER -->|"request withdrawal"| DELAYED
    DELAYED -->|"after 1-day delay<br/>burn shares, return USDC"| USER

    GM -->|"distributeRewards(winners, bps)"| DIST
    OW -->|"supplyAndCheckpoint(amount)"| DIST
    OW -->|"withdrawAndCheckpoint(amount, to)"| DIST
    OW -->|"setFeeSplits / setPaused<br/>resetCheckpoint / adjustCheckpoint"| DIST

    DIST -->|"aaveSupplyUsdc(amount)"| PROXY
    DIST -->|"aaveWithdrawUsdc(amount)"| PROXY
    DIST -->|"vaultTransferUsdc(to, amount)"| PROXY

    PROXY -->|"vault.manage(pool.supply)"| VAULT
    PROXY -->|"vault.manage(pool.withdraw)"| VAULT
    PROXY -->|"vault.manage(usdc.transfer)"| VAULT

    VAULT <-->|"supply / withdraw"| AAVE
    AAVE -->|"mints"| AUSDC
    AAVE -->|"returns"| USDC_TOK
    VAULT -->|"USDC transfers"| WINNERS
    VAULT -->|"USDC transfers"| PROTOCOL
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
    class TELLER,ACCOUNTANT,DELAYED,VAULT veda
    class PROXY,DIST claw
    class AAVE,USDC_TOK,AUSDC protocol
    class WINNERS,PROTOCOL,DEPOSITORS recipient
```

## Reward Distribution Flow

```mermaid
sequenceDiagram
    autonumber
    participant GM as Game Master
    participant DIST as GameRewardsDistributor
    participant PROXY as ScopedVaultProxy
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

    DIST->>PROXY: aaveWithdrawUsdc(winnerTotal + protocolAmount)
    activate PROXY
    PROXY->>VAULT: manage(pool.withdraw)
    VAULT->>AAVE: withdraw(USDC, amount, vault)
    AAVE-->>VAULT: USDC returned to vault
    PROXY-->>DIST: actualAmount
    deactivate PROXY

    loop For each winner
        DIST->>PROXY: vaultTransferUsdc(winner, amount)
        PROXY->>VAULT: manage(usdc.transfer)
        VAULT-->>W: USDC
    end

    DIST->>PROXY: vaultTransferUsdc(protocolWallet, protocolAmount)
    PROXY->>VAULT: manage(usdc.transfer)
    VAULT-->>P: USDC

    Note over VAULT: vaultAmount stays as aUSDC<br/>(no action needed)

    DIST-->>GM: emit RewardsDistributed
    deactivate DIST
```

## Atomic Deposit Flow (supplyAndCheckpoint)

```mermaid
sequenceDiagram
    autonumber
    participant OP as Owner / Operator
    participant DIST as GameRewardsDistributor
    participant PROXY as ScopedVaultProxy
    participant VAULT as BoringVault
    participant AAVE as Aave V3 Pool

    Note over VAULT: USDC already in vault<br/>(from user deposit via Teller)

    OP->>DIST: supplyAndCheckpoint(amount)
    activate DIST

    DIST->>PROXY: aaveSupplyUsdc(amount)
    activate PROXY
    PROXY->>VAULT: manage(usdc.approve(pool, amount))
    PROXY->>VAULT: manage(pool.supply(USDC, amount, vault))
    VAULT->>AAVE: supply(USDC, amount, vault, 0)
    AAVE-->>VAULT: aUSDC minted to vault
    deactivate PROXY

    DIST->>DIST: lastCheckpointBalance += amount

    Note over DIST: Atomic: checkpoint always<br/>matches actual Aave supply.<br/>Deposit cannot be mistaken<br/>for yield.

    deactivate DIST
```

## Atomic Withdrawal Flow (withdrawAndCheckpoint)

```mermaid
sequenceDiagram
    autonumber
    participant OP as Owner / Operator
    participant DIST as GameRewardsDistributor
    participant PROXY as ScopedVaultProxy
    participant VAULT as BoringVault
    participant AAVE as Aave V3 Pool
    participant USER as Recipient

    OP->>DIST: withdrawAndCheckpoint(amount, user)
    activate DIST

    DIST->>PROXY: aaveWithdrawUsdc(amount)
    activate PROXY
    PROXY->>VAULT: manage(pool.withdraw)
    VAULT->>AAVE: withdraw(USDC, amount, vault)
    AAVE-->>VAULT: USDC returned
    deactivate PROXY

    DIST->>PROXY: vaultTransferUsdc(user, amount)
    PROXY->>VAULT: manage(usdc.transfer(user, amount))
    VAULT-->>USER: USDC

    DIST->>DIST: lastCheckpointBalance -= amount

    Note over DIST: Atomic: checkpoint always<br/>matches actual Aave withdrawal.<br/>Withdrawal cannot create<br/>phantom negative yield.

    deactivate DIST
```

## Access Control (RolesAuthority)

```mermaid
graph LR
    subgraph Roles
        GMR["GAME_MASTER_ROLE (20)"]
        OWR["OWNER_ROLE (8)"]
        MGR["MANAGER_ROLE (1)"]
        DISTR["DISTRIBUTOR_ROLE (21)"]
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
    end

    subgraph "ScopedVaultProxy Functions"
        AWU["aaveWithdrawUsdc()"]
        ASU["aaveSupplyUsdc()"]
        VTU["vaultTransferUsdc()"]
    end

    subgraph "BoringVault Functions"
        MNG["manage()"]
    end

    GMR -->|"can call"| DR
    OWR -->|"can call"| SAC
    OWR -->|"can call"| WAC
    OWR -->|"can call"| AC
    OWR -->|"can call"| RC
    OWR -->|"can call"| SPW
    OWR -->|"can call"| SFS
    OWR -->|"can call"| SP

    DISTR -->|"can call"| AWU
    DISTR -->|"can call"| ASU
    DISTR -->|"can call"| VTU

    MGR -->|"can call"| MNG

    subgraph "Role Assignments"
        direction LR
        A1["Game Master address → GAME_MASTER_ROLE"]
        A2["Owner address → OWNER_ROLE"]
        A3["ScopedVaultProxy → MANAGER_ROLE"]
        A4["GameRewardsDistributor → DISTRIBUTOR_ROLE"]
    end

    classDef role fill:#e3f2fd,stroke:#1565c0
    classDef func fill:#f1f8e9,stroke:#558b2f
    classDef assignment fill:#fff8e1,stroke:#ff8f00

    class GMR,OWR,MGR,DISTR role
    class DR,SAC,WAC,AC,RC,SPW,SFS,SP,AWU,ASU,VTU,MNG func
    class A1,A2,A3,A4 assignment
```

## Fee Split (Default: 80 / 10 / 10)

```mermaid
pie title Yield Distribution (Default BPS)
    "Winners (8000 bps)" : 80
    "Protocol Wallet (1000 bps)" : 10
    "Vault Depositors (1000 bps)" : 10
```
