#[test_only]
module example::example_tests;

use example::brand_usdc;
use sui::coin_registry::{Self as coin_registry, CoinRegistry};
use sui::test_scenario::{Self as ts};
use stable_layer::stable_layer::{AdminCap, StableRegistry};

/// Test USD type for create_stable<U, _>
public struct USD has drop {}

/// Farm entity type for add_entity / create_stable<_, FARM>
public struct FARM1 has drop {}

public fun admin(): address { @0xad }

#[test]
fun test_decimals() {
    assert!(brand_usdc::decimals() == 6, 0);
}

#[test]
fun test_create_stable() {
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    // Tx1: System creates and shares CoinRegistry
    s.next_tx(@0x0);
    let coin_registry = coin_registry::create_coin_data_registry_for_testing(s.ctx());
    coin_registry::share_for_testing(coin_registry);

    // Tx2: Admin initializes stable_layer, adds USD type, lists farm entity
    s.next_tx(admin());
    stable_layer::stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut stable_registry = s.take_shared<StableRegistry>();
    stable_layer::stable_layer::add_usd_type<USD>(&admin_cap, &mut stable_registry, 6, s.ctx());
    stable_layer::stable_layer::list_entity<USD, FARM1>(&admin_cap, &mut stable_registry);
    s.return_to_sender(admin_cap);
    ts::return_shared(stable_registry);

    // Tx3: Mint BrandUSDC proof (init_for_testing)
    s.next_tx(admin());
    brand_usdc::init_for_testing(s.ctx());

    // Tx4: create_stable with proof
    s.next_tx(admin());
    let mut coin_registry = s.take_shared<CoinRegistry>();
    let mut stable_registry = s.take_shared<StableRegistry>();
    let proof = s.take_from_sender<brand_usdc::BrandUSDC>();

    let max_supply = 1_000_000 * 1_000_000; // 1M with 6 decimals
    brand_usdc::create_stable<USD, FARM1>(
        &mut coin_registry,
        &mut stable_registry,
        proof,
        max_supply,
        s.ctx(),
    );

    ts::return_shared(coin_registry);
    ts::return_shared(stable_registry);

    // Verify: FactoryCap was transferred to sender
    s.next_tx(admin());
    let _factory_cap = s.take_from_sender<
        stable_layer::stable_layer::FactoryCap<brand_usdc::BrandUSDC, USD>,
    >();
    s.return_to_sender(_factory_cap);

    scenario.end();
}
