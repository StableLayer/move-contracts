module example::stable_layer;

use sui::coin_registry::CoinRegistry;
use stable_layer::stable_layer::{Self as sl, StableRegistry, add_entity};

const DECIMALS: u8 = 6;
const SYMBOL: vector<u8> = b"brandUSDC";
const NAME: vector<u8> = b"brandUSDC";
const DESCRIPTION: vector<u8> = b"Brand USDC stablecoin backed by USDC";
const ICON_URL: vector<u8> = b"https://circle.com/usdc-icon";

public struct Stablecoin has key {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(Stablecoin { id: object::new(ctx) }, ctx.sender());
}

#[allow(lint(self_transfer))]
public fun create_stable<U, FARM>(
    coin_registry: &mut CoinRegistry,
    stable_registry: &mut StableRegistry,
    proof: Stablecoin,
    max_supply: u64,
    ctx: &mut TxContext,
) {
    let (initializer, treasury_cap) = coin_registry.new_currency<Stablecoin>(
        decimals(),
        SYMBOL.to_string(),
        NAME.to_string(),
        DESCRIPTION.to_string(),
        ICON_URL.to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    transfer::public_transfer(metadata_cap, ctx.sender());
    let factory_cap = sl::new<Stablecoin, U>(
        stable_registry,
        treasury_cap,
        max_supply,
        ctx,
    );
    add_entity<Stablecoin, U, FARM>(stable_registry, &factory_cap);
    transfer::public_transfer(factory_cap, ctx.sender());
    let Stablecoin { id } = proof;
    id.delete();
}

public fun decimals(): u8 { DECIMALS }

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    transfer::transfer(Stablecoin { id: object::new(ctx) }, ctx.sender());
}
