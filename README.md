# Stable Layer

A generic factory system for creating asset-pegged stablecoins backed by USD. The Stable Layer allows projects to create their own stablecoins (e.g., BTC/USD) and earn yields on the underlying USD collateral through integration with farming protocols.

## Overview

Stable Layer provides a trustless mechanism for minting asset-pegged stablecoins by:
1. **Accepting USD deposits** (e.g., USDC via PSM)
2. **Creating USD-denominated loans** tracked in a Sheet-based accounting system
3. **Minting asset-pegged tokens** (e.g., BTC/USD) 1:1 with USD value
4. **Enabling yield generation** by deploying USD to farms (e.g., stable_vault_farm)
5. **Supporting controlled burn/repayment** through a request/fulfill pattern

## Architecture

### Core Components

#### StableRegistry
- **Central registry** managing all StableFactory instances
- **Version control** to ensure package compatibility
- **Dynamic object fields** for storing individual factories by type
- **Shared object** accessible to all users

#### StableFactory<STABLE, USD>
- **Individual factory** for a specific STABLE/USD pair (e.g., BTC_USD/USDC)
- **Treasury management** with TreasuryCap for minting/burning
- **Sheet-based accounting** tracking loans to farming entities
- **Max supply enforcement** to control token inflation
- **Claimer management** for yield collection access control

#### FactoryCap<STABLE, USD>
- **Capability token** for factory administration
- **Allows holder to**:
  - Add/ban farming entities
  - Manage claimer addresses
- **Transferable** to delegate administration

#### Sheet-Based Loan System
Uses `stable_layer_framework::sheet` module for tracking:
- **Loans** from factory to farms (when minting)
- **Repayments** from farms to factory (when burning)
- **Credit/debt balances** for each farming entity

### Type Parameters

- `STABLE`: The asset-pegged stablecoin type (e.g., `BTC_USD`)
- `USD`: The underlying USD token type (e.g., `USDC`, `USDB`)
- `FARM`: The farming entity receiving loans (e.g., `StableVaultFarm`)

## Key Features

### 1. Factory Creation

```move
public fun new<STABLE, USD>(
    registry: &mut StableRegistry,
    treasury_cap: TreasuryCap<STABLE>,
    max_supply: u64,
    ctx: &mut TxContext,
): FactoryCap<STABLE, USD>
```

- Creates a new StableFactory for STABLE/USD pair
- **Requires**: Treasury cap with zero total supply
- **Returns**: FactoryCap for administration
- **Emits**: `NewStable` event

**Convenience function**:
```move
public fun default<STABLE, USD>(...) // Transfers FactoryCap to sender
```

### 2. Minting Stable Tokens

```move
public fun mint<STABLE, USD, FARM>(
    registry: &mut StableRegistry,
    u_coin: Coin<USD>,
    ctx: &mut TxContext,
): (Coin<STABLE>, Loan<USD, StableFactoryEntity<STABLE, USD>, FARM>)
```

**Flow**:
1. User deposits USD coin
2. Factory creates a Loan to FARM entity (tracked in Sheet)
3. Factory mints STABLE tokens 1:1 with USD amount
4. Returns (STABLE coin, Loan) → Loan must be handled by FARM
5. **Enforces**: total_supply ≤ max_supply

**Emits**: `Mint` event with amounts and farm type

### 3. Burning Stable Tokens

Two-step process for safe repayment:

#### Step 1: Request Burn
```move
public fun request_burn<STABLE, USD>(
    registry: &mut StableRegistry,
    stable_coin: Coin<STABLE>,
): Request<USD, StableFactoryEntity<STABLE, USD>>
```

- Burns STABLE tokens immediately
- Creates a Request for USD repayment
- **Hot potato pattern**: Request must be fulfilled

#### Step 2: Fulfill Burn
```move
public fun fulfill_burn<STABLE, USD>(
    registry: &mut StableRegistry,
    burn_request: Request<USD, StableFactoryEntity<STABLE, USD>>,
    ctx: &mut TxContext,
): Coin<USD>
```

- **Requires**: Request fully repaid (shortage == 0)
- Collects USD from Sheet (farms have repaid their loans)
- Returns USD coin to user
- **Emits**: `Burn` event with farm repayments

**Flow**:
```
User → request_burn(STABLE) → Request
  ↓
Request → Farm.pay() → Farm calculates required USD
  ↓
Farm withdraws yield → Repays loan via Sheet.pay()
  ↓
Request (fully repaid) → fulfill_burn() → Returns USD to user
```

### 4. Entity Management

```move
public fun add_entity<STABLE, USD, FARM>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
)
```
- Adds FARM as authorized debtor in Sheet
- Required before FARM can receive loans

```move
public fun ban_entity<STABLE, USD, FARM>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
)
```
- Bans FARM from receiving new loans
- Existing loans remain valid

### 5. Claimer Management

```move
public fun add_claimer<STABLE, USD>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
    claimer: address,
)
```
- Adds address to claimer whitelist
- Claimers can collect yields/profits from farms

```move
public fun remove_claimer<STABLE, USD>(...)
```
- Removes address from claimer whitelist

```move
public fun assert_sender_is_claimer<STABLE, USD>(
    factory: &StableFactory<STABLE, USD>,
    acc_req: &AccountRequest,
)
```
- Validates sender is authorized claimer
- Used by farms to gate yield collection

### 6. Version Control

```move
public fun add_version(_admin_cap: &AdminCap, registry: &mut StableRegistry, version: u16)
public fun remove_version(_admin_cap: &AdminCap, registry: &mut StableRegistry, version: u16)
```
- AdminCap holder can manage allowed versions
- Prevents incompatible package interactions

## Error Codes

| Code | Name | Description |
|------|------|-------------|
| `0` | `EInvalidPackageVersion` | Package version not in registry's allowed versions |
| `1` | `ESenderIsNotClaimer` | Caller not in factory's claimer whitelist |
| `2` | `ERequestNotFulfilled` | Burn request has outstanding shortage (loans not fully repaid) |
| `3` | `ETreasuryCapNotEmpty` | Treasury cap has non-zero supply when creating factory |
| `4` | `EFactoryNotExists` | Requested factory not found in registry |
| `5` | `EExceedMaxSupply` | Minting would exceed factory's max_supply limit |

## Events

### NewStable
```move
public struct NewStable has copy, drop {
    u_type: String,
    stable_type: String,
    factory_id: ID,
    factory_cap_id: ID,
}
```
Emitted when a new factory is created.

### Mint
```move
public struct Mint has copy, drop {
    u_type: String,
    stable_type: String,
    mint_amount: u64,
    farm_type: String,
}
```
Emitted when STABLE tokens are minted.

### Burn
```move
public struct Burn has copy, drop {
    u_type: String,
    stable_type: String,
    burn_amount: u64,
    farm_types: vector<Entity>,
    repayment_amounts: vector<u64>,
}
```
Emitted when burn is fulfilled, showing which farms repaid and amounts.

## Usage Example

### Creating a BTC_USD Factory

```move
// 1. Create factory (admin)
let factory_cap = stable_factory::new<BTC_USD, USDC>(
    registry,
    btc_usd_treasury_cap, // Must have 0 supply
    1_000_000_000_000, // max_supply
    ctx
);

// 2. Add farm as authorized entity
stable_factory::add_entity<BTC_USD, USDC, StableVaultFarm>(
    registry,
    &factory_cap,
);

// 3. Add claimer for yield collection
stable_factory::add_claimer<BTC_USD, USDC>(
    registry,
    &factory_cap,
    farm_admin_address,
);
```

### Minting BTC_USDC

```move
// User deposits USDC, receives BTC/USD
let usdc_coin = /* 100 USDC */;
let (btc_usd_coin, loan) = stable_factory::mint<BTC_USD, USDC, StableVaultFarm>(
    registry,
    usdc_coin,
    ctx
);

// Farm receives the loan and deposits USD to yield strategy
stable_vault_farm::receive_loan(loan); // Farm handles loan internally
// → Farm converts USD to StableVault LP via StableVault
// → Stores in yield_table by STABLE type
```

### Burning BTC_USD

```move
// User initiates burn
let btc_usd_coin = /* 100 BTC/USD */;
let request = stable_factory::request_burn<BTC_USD, USDC>(
    registry,
    btc_usd_coin, // Burned immediately
);

// Farm repays the loan
let request = stable_vault_farm::pay<BTC_USD>(request);
// → Farm calculates required USDC (based on exchange rate)
// → Withdraws StableVault LP → Gets USDC
// → Repays loan via sheet::pay()

// User receives USDC back
let usdc_coin = stable_factory::fulfill_burn<BTC_USD, USDC>(
    registry,
    request, // Must have shortage == 0
    ctx
);
```

## Getter Functions

```move
public fun versions(registry: &StableRegistry): &VecSet<u16>
public fun borrow_factory<STABLE, USD>(registry: &StableRegistry): &StableFactory<STABLE, USD>
public fun sheet<STABLE, USD>(factory: &StableFactory<STABLE, USD>): &Sheet<...>
public fun total_supply<STABLE, USD>(factory: &StableFactory<STABLE, USD>): u64
public fun max_supply<STABLE, USD>(factory: &StableFactory<STABLE, USD>): u64
public fun claimers<STABLE, USD>(factory: &StableFactory<STABLE, USD>): &VecSet<address>
```

## Security Features

### Supply Control
- **Max supply enforcement** prevents unlimited minting
- **Treasury cap validation** ensures clean factory creation

### Access Control
- **FactoryCap** required for entity/claimer management
- **Claimer whitelist** gates yield collection
- **Entity whitelist** controls which farms can receive loans

### Version Safety
- **Package version checks** prevent incompatible interactions
- **AdminCap** required for version management

### Accounting Integrity
- **Sheet-based tracking** ensures loans always balanced
- **Hot potato Request** enforces full repayment before fulfillment
- **Atomic operations** prevent partial state updates

## Integration with Other Modules

### Dependencies
- **stable_layer_framework**: Sheet module for loan accounting, AccountRequest for identity

## Deployments

### Mainnet
**Package ID**
```
0xa4a78d8d3d1df62fb81d10068142e79b0d30ad4e3f578060487e36ed9ea764da
```

**StableRegistry** ( Init version `696362017`)
```
0x213f4d584c0770f455bb98c94a4ee5ea9ddbc3d4ebb98a0ad6d093eb6da41642
```

**AdminCap**
```
0xf328abfe0fbafcbe6440416bee3f68e360bc560e7e8c59ab5a062186447c2990
```

**UpgradeCap**
```
0x4acc8236a67a20a7cf51a0827c5951beffe2289451eddb15748bffccaafddc27
```

## Development

### Building
```bash
cd stable_layer
sui move build
```

### Testing
```bash
sui move test
```

### Package Version
Current version: `4`

Use `stable_layer::package_version()` to verify compatibility.
