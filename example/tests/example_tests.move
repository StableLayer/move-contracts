#[test_only]
module example::example_tests;

use example::stable_layer as brand;
use sui::coin_registry::{Self as coin_registry, CoinRegistry};
use sui::test_scenario::{Self as ts};
use stable_layer::stable_layer::{Self as sl, AdminCap, StableRegistry};

public struct USD has drop {}

public struct FARM1 has drop {}

public fun admin(): address { @0xad }

#[test]
fun test_decimals() {
    assert!(brand::decimals() == 6, 0);
}

#[test]
fun test_create_stable() {
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    s.next_tx(@0x0);
    let coin_registry = coin_registry::create_coin_data_registry_for_testing(s.ctx());
    coin_registry::share_for_testing(coin_registry);

    s.next_tx(admin());
    sl::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut stable_registry = s.take_shared<StableRegistry>();
    sl::add_usd_type<USD>(&admin_cap, &mut stable_registry, 6, s.ctx());
    sl::list_entity<USD, FARM1>(&admin_cap, &mut stable_registry);
    s.return_to_sender(admin_cap);
    ts::return_shared(stable_registry);

    s.next_tx(admin());
    brand::init_for_testing(s.ctx());

    s.next_tx(admin());
    let mut coin_registry = s.take_shared<CoinRegistry>();
    let mut stable_registry = s.take_shared<StableRegistry>();
    let proof = s.take_from_sender<brand::Stablecoin>();

    let max_supply = 1_000_000 * 1_000_000;
    brand::create_stable<USD, FARM1>(
        &mut coin_registry,
        &mut stable_registry,
        proof,
        max_supply,
        s.ctx(),
    );

    ts::return_shared(coin_registry);
    ts::return_shared(stable_registry);

    s.next_tx(admin());
    let _factory_cap = s.take_from_sender<
        sl::FactoryCap<brand::Stablecoin, USD>,
    >();
    s.return_to_sender(_factory_cap);

    scenario.end();
}
