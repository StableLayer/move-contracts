module example::brand_usdc;

use sui::coin_registry::CoinRegistry;
use stable_layer::stable_layer::{StableRegistry, add_entity};

const DECIMALS: u8 = 6;
const SYMBOL: vector<u8> = b"brandUSDC";
const NAME: vector<u8> = b"brandUSDC";
const DESCRIPTION: vector<u8> = b"Brand USDC stablecoin backed by USDC";
const ICON_URL: vector<u8> = b"https://circle.com/usdc-icon";

/// One-time proof object: publisher must pass it to `create_stable` (then it is destroyed).
public struct BrandUSDC has key {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(BrandUSDC { id: object::new(ctx) }, ctx.sender());
}

#[allow(lint(self_transfer))]
public fun create_stable<U, FARM>(
    coin_registry: &mut CoinRegistry,
    stable_registry: &mut StableRegistry,
    proof: BrandUSDC,
    max_supply: u64,
    ctx: &mut TxContext,
) {
    let (initializer, treasury_cap) = coin_registry.new_currency<BrandUSDC>(
        decimals(),
        SYMBOL.to_string(),
        NAME.to_string(),
        DESCRIPTION.to_string(),
        ICON_URL.to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    transfer::public_transfer(metadata_cap, ctx.sender());
    let factory_cap = stable_layer::stable_layer::new<BrandUSDC, U>(
        stable_registry,
        treasury_cap,
        max_supply,
        ctx,
    );
    add_entity<BrandUSDC, U, FARM>(stable_registry, &factory_cap);
    transfer::public_transfer(factory_cap, ctx.sender());
    let BrandUSDC { id } = proof;
    id.delete();
}

public fun decimals(): u8 { DECIMALS }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    transfer::transfer(BrandUSDC { id: object::new(ctx) }, ctx.sender());
}
