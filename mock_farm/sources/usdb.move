module mock_farm::usdb;

use sui::coin::{TreasuryCap};
use sui::coin_registry::{CoinRegistry, MetadataCap};

public struct USDB has key {
    id: UID,
}

public(package) fun initialize(
    coin_registry: &mut CoinRegistry,
    ctx: &mut TxContext,
): (TreasuryCap<USDB>, MetadataCap<USDB>) {
    let (initializer, treasury_cap) = coin_registry.new_currency<USDB>(
        decimals(),
        b"USDB".to_string(),
        b"Bucket USD".to_string(),
        b"USDB is a decentralized, overcollateralized stablecoin of bucketprotocol.io, pegged to 1 USD and backed by crypto assets via CDP and PSM mechanisms.".to_string(),
        b"https://www.bucketprotocol.io/icons/USDB.svg".to_string(),
        ctx,
    );
    let metadata_cap = initializer.finalize(ctx);
    (treasury_cap, metadata_cap)
}

public fun decimals(): u8 { 6 }
