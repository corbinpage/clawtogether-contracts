# Contributing to ClawTogether

Thank you for your interest in contributing to ClawTogether! This document provides guidelines and information for contributing to this DeFi game vault built on Veda's Boring Vault architecture.

## Table of Contents

- [Development Setup](#development-setup)
- [Project Architecture](#project-architecture)
- [Coding Standards](#coding-standards)
- [Testing](#testing)
- [Security Considerations](#security-considerations)
- [Areas for Contribution](#areas-for-contribution)
- [Submitting Changes](#submitting-changes)
- [Security Disclosure](#security-disclosure)

## Development Setup

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (latest stable)
- [Git](https://git-scm.com/downloads)
- Node.js 18+ (for auxiliary tooling)

### Installation

```bash
# Clone the repository
git clone https://github.com/corbinpage/clawtogether-contracts.git
cd clawtogether-contracts

# Install dependencies
forge install

# Run tests to verify setup
forge test
```

### Build

```bash
# Compile contracts
forge build

# Build with gas report
forge build --gas-report
```

## Project Architecture

ClawTogether is built on [Veda's Boring Vault](https://github.com/Se7en-Seas/boring-vault) architecture with the following components:

### Core Contracts

| Contract | Purpose |
|----------|---------|
| `ClawTogetherTeller.sol` | Extended teller with `depositFor()` for on-behalf deposits with referral tracking |
| `GameRewardsDistributor.sol` | Distributes Aave yield to game winners, protocol, and depositors |
| `ClawTogetherDecoderAndSanitizer.sol` | Decodes and sanitizes vault operations for Merkle verification |

### Key Design Patterns

**Boring Vault Architecture:**
- `BoringVault`: Holds assets and issues `clawUSDC` shares
- `Teller`: Handles deposits/exits with share minting/burning
- `Accountant`: Manages share pricing and exchange rates
- `DelayedWithdraw`: 1-day withdrawal queue for security
- `ManagerWithMerkleVerification`: Scoped operations via 4-leaf Merkle trees

**Yield Distribution:**
- 80% → Game winners (up to 10 per round)
- 10% → Protocol wallet
- 10% → Vault depositors (auto-compounds)

## Coding Standards

### Solidity Style

- **Version**: `pragma solidity ^0.8.21;`
- **EVM Version**: Cancun
- **Optimizer**: Enabled with 200 runs
- **License**: MIT

### Naming Conventions

```solidity
// Constants: UPPER_SNAKE_CASE
uint256 public constant BPS_DENOMINATOR = 10_000;

// Immutable: camelCase with leading underscore
address public immutable protocolWallet;

// State variables: camelCase
uint256 public protocolBps;

// Events: PascalCase with indexed params for addresses
event RewardsDistributed(
    address[] winners,
    uint256[] winnerAmounts,
    uint256 protocolAmount,
    uint256 vaultAmount,
    uint256 totalYield
);

// Errors: ContractName__PascalCase
error GameRewardsDistributor__InvalidBps();
```

### Code Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 1. Imports (grouped by source)
import {BoringVault} from "boring-vault/base/BoringVault.sol";
import {ERC20} from "@solmate/tokens/ERC20.sol";

// 2. NatSpec documentation
/// @title ContractName
/// @notice Brief description
/// @dev Implementation details
contract ContractName {
    // 3. Type declarations
    // 4. State variables
    // 5. Events
    // 6. Errors
    // 7. Modifiers
    // 8. Constructor
    // 9. External functions
    // 10. Public functions
    // 11. Internal functions
    // 12. Private functions
}
```

## Testing

### Running Tests

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vv

# Run specific test
forge test --match-test test_DepositFor

# Run with gas report
forge test --gas-report

# Run coverage
forge coverage
```

### Test Structure

Tests are organized by component:

```
test/
├── DepositFor.t.sol          # Teller deposit functionality
├── GameRewardsDistributor.t.sol  # Reward distribution logic
└── Integration.t.sol         # End-to-end integration tests
```

### Writing Tests

```solidity
function test_DepositFor_MintsSharesToOnBehalfOf() public {
    // Setup
    uint256 depositAmount = 1000e6;
    address depositor = address(1);
    address onBehalfOf = address(2);
    
    // Execute
    vm.prank(depositor);
    uint256 shares = teller.depositFor(USDC, depositAmount, onBehalfOf, address(0));
    
    // Assert
    assertEq(vault.balanceOf(onBehalfOf), shares);
    assertEq(vault.balanceOf(depositor), 0);
}
```

### Coverage Requirements

- Minimum 80% line coverage
- 100% coverage for critical paths (deposits, withdrawals, reward distribution)
- All error conditions must be tested

## Security Considerations

### Critical Invariants

1. **Share/Asset Ratio**: `clawUSDC` shares must always be redeemable for underlying USDC
2. **Yield Distribution**: Total distributed must equal total yield (accounting for rounding)
3. **Access Control**: Only `GameMaster` can call `distributeRewards()`
4. **Withdrawal Queue**: 1-day delay must be enforced for all withdrawals

### Common Vulnerabilities to Avoid

- **Reentrancy**: All external calls use `nonReentrant` modifier
- **Integer Overflow**: Use Solidity 0.8+ built-in overflow checks
- **Access Control**: Verify all authority checks via `RolesAuthority`
- **Merkle Verification**: All vault operations require valid Merkle proofs

### Boring Vault Security Model

The vault uses a defense-in-depth approach:
- **RolesAuthority**: Granular permission system
- **Merkle Verification**: Operations scoped to specific function selectors
- **Delayed Withdrawals**: Time delay prevents instant exits
- **Accountant**: Share pricing prevents manipulation

## Areas for Contribution

### High Priority

- **Additional Yield Strategies**: Integrate other yield sources beyond Aave V3
- **Game Integration**: Examples of how games can integrate with the reward distributor
- **Frontend Examples**: React/Vue components for deposit/withdrawal UI
- **Monitoring Tools**: Scripts to track yield accrual and distributions

### Medium Priority

- **Gas Optimizations**: Reduce gas costs for deposit/withdrawal operations
- **Additional Test Coverage**: Edge cases and fuzzing tests
- **Documentation**: Architecture diagrams and integration guides
- **Deployment Scripts**: Automated deployment and configuration

### Low Priority

- **Code Comments**: Additional inline documentation
- **Refactoring**: Code organization improvements
- **Linting**: Solhint configuration and fixes

## Submitting Changes

1. **Fork** the repository
2. **Create a branch**: `git checkout -b feature/your-feature-name`
3. **Make changes** following coding standards
4. **Add tests** for new functionality
5. **Run tests**: `forge test`
6. **Commit** with clear messages: `feat: add yield strategy for Compound`
7. **Push** to your fork: `git push origin feature/your-feature-name`
8. **Open a Pull Request** with detailed description

### PR Checklist

- [ ] Tests pass (`forge test`)
- [ ] New code has tests
- [ ] Coverage maintained at 80%+
- [ ] Code follows style guide
- [ ] NatSpec documentation added
- [ ] No compiler warnings
- [ ] Gas snapshot updated if relevant

## Security Disclosure

If you discover a security vulnerability, please report it responsibly:

1. **DO NOT** open a public issue
2. Email security concerns to: [project security contact]
3. Allow reasonable time for response before public disclosure

### Scope

Security issues within scope:
- Smart contract vulnerabilities
- Access control bypasses
- Yield calculation errors
- Share pricing manipulation

Out of scope:
- Frontend/UI issues
- Documentation errors
- Gas optimization suggestions

---

Thank you for contributing to ClawTogether! 🎮💰