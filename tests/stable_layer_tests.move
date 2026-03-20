#[test_only]
module stable_layer::stable_layer_tests;

use sui::coin::{Self, Coin, TreasuryCap};
use sui::test_scenario::{Self as ts, Scenario};
use stable_layer_framework::sheet::{Self, entity};
use stable_layer::stable_layer::{
    Self, StableRegistry, AdminCap, FactoryCap,
};

/// Test coin types
public struct STABLE has drop {}
public struct STABLE2 has drop {}
public struct STABLE3 has drop {}
public struct USD has drop {}
public struct USD8 has drop {} // 8 decimals USD (like some wrapped tokens)
public struct FARM1 has drop {}
public struct FARM2 has drop {}
public struct FARM3 has drop {} // Unlisted farm for testing

/// Test addresses
public fun admin(): address { @0xad }
public fun user1(): address { @0x111 }
public fun user2(): address { @0x222 }

/// Helper functions
public fun usd(amount: u64): u64 { amount * 1_000_000 } // 6 decimals
public fun usd8(amount: u64): u64 { amount * 100_000_000 } // 8 decimals
public fun stable(amount: u64): u64 { amount * 1_000_000 } // 6 decimals

/// Setup function for tests - creates registry and admin cap
public fun setup(): Scenario {
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    // Initialize the module
    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();
    admin_cap.add_usd_type<USD>(&mut registry, 6, s.ctx());
    admin_cap.list_entity<USD, FARM1>(&mut registry);
    admin_cap.list_entity<USD, FARM2>(&mut registry);
    s.return_to_sender(admin_cap);
    ts::return_shared(registry);

    scenario
}

/// Create a test treasury cap with zero supply
public fun create_treasury_cap(scenario: &mut Scenario): TreasuryCap<STABLE> {
    let s = scenario;
    s.next_tx(admin());
    // Use the test-only function to create a treasury cap
    coin::create_treasury_cap_for_testing<STABLE>(s.ctx())
}

#[test]
fun test_init() {
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());

    // Check that registry was created and shared
    let registry = s.take_shared<StableRegistry>();
    assert!(registry.versions().contains(&stable_layer::package_version()));
    ts::return_shared(registry);

    // Check that AdminCap was transferred to sender
    let admin_cap = s.take_from_sender<AdminCap>();
    s.return_to_sender(admin_cap);

    scenario.end();
}

#[test]
fun test_new_factory() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);
    let max_supply = usd(1_000_000);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();

    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        max_supply,
        s.ctx()
    );

    // Verify factory was created
    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.stable_supply() == 0);
    assert!(factory.max_supply() == max_supply);
    assert!(factory.managers().contains(&admin()));

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_default_factory() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);
    let max_supply = usd(500_000);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();

    registry.default<STABLE, USD>(
        treasury_cap,
        max_supply,
        s.ctx()
    );

    ts::return_shared(registry);

    // Verify factory cap was transferred to sender
    s.next_tx(admin());
    let factory_cap = s.take_from_sender<FactoryCap<STABLE, USD>>();
    s.return_to_sender(factory_cap);

    scenario.end();
}

#[test]
fun test_add_and_remove_version() {
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    let new_version = stable_layer::package_version() + 1;
    stable_layer::add_version(&admin_cap, &mut registry, new_version);
    assert!(registry.versions().contains(&new_version));

    stable_layer::remove_version(&admin_cap, &mut registry, new_version);
    assert!(!registry.versions().contains(&new_version));

    s.return_to_sender(admin_cap);
    ts::return_shared(registry);

    scenario.end();
}

#[test]
fun test_add_and_ban_entity() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    // Add entity - this allows FARM1 to receive loans from the factory
    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);

    // Verify entity was added by successfully minting (which requires the entity to be added)
    let mint_amount = usd(100);
    let u_coin = coin::mint_for_testing<USD>(mint_amount, s.ctx());
    let (stable_coin, loan) = registry.mint<STABLE, USD, FARM1>(u_coin, s.ctx());

    // Verify minted amounts
    assert!(stable_coin.value() == mint_amount);
    assert!(loan.value() == mint_amount);

    // Clean up the loan
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    transfer::public_transfer(stable_coin, admin());

    // Ban entity
    registry.ban_entity<STABLE, USD, FARM1>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_add_and_remove_manager() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    // Add manager
    let new_manager = user1();
    registry.add_manager<STABLE, USD>(&factory_cap, new_manager);

    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.managers().contains(&new_manager));
    assert!(factory.managers().contains(&admin()));

    // Remove manager
    registry.remove_manager<STABLE, USD>(&factory_cap, new_manager);

    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(!factory.managers().contains(&new_manager));

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_set_max_supply() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    let new_max_supply = usd(2_000_000);
    registry.set_max_supply<STABLE, USD>(&factory_cap, new_max_supply);

    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.max_supply() == new_max_supply);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_mint_and_burn() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);
    let max_supply = usd(1_000_000);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        max_supply,
        s.ctx()
    );

    // Add entity that will receive the loan
    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    // Mint stable coins
    let mint_amount = usd(100);
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin = coin::mint_for_testing<USD>(mint_amount, s.ctx());

    let (stable_coin, loan) = registry.mint<STABLE, USD, FARM1>(u_coin, s.ctx());

    assert!(stable_coin.value() == mint_amount);
    assert!(loan.value() == mint_amount);

    // Verify factory state
    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.stable_supply() == mint_amount);

    // Verify registry total supply
    assert!(registry.total_supply() == mint_amount);

    // Store the loan (simulate farm receiving it)
    let loan_amount = loan.value();
    // Create a mock sheet for the farm to receive the loan
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received_balance = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received_balance.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);

    // Request burn
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();

    let mut burn_request = registry.request_burn<STABLE, USD>(stable_coin);

    // Verify factory state after burn request (stable_supply goes to 0 immediately)
    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.stable_supply() == 0);

    // Note: total_supply is not yet updated, will be decremented in fulfill_burn

    // Pay back the loan
    let repayment = coin::mint_for_testing<USD>(loan_amount, s.ctx());
    let mut farm_sheet = sheet::new(FARM1 {});
    let debtor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_debtor(&mut farm_sheet, debtor_entity, FARM1 {});
    sheet::pay(&mut farm_sheet, &mut burn_request, repayment.into_balance(), FARM1 {});
    farm_sheet.destroy_for_testing();

    // Fulfill burn
    let u_coin_out = registry.fulfill_burn<STABLE, USD>(burn_request, s.ctx());
    assert!(u_coin_out.value() == mint_amount);

    // Verify registry total supply is now 0 after fulfill_burn
    assert!(registry.total_supply() == 0);

    transfer::public_transfer(u_coin_out, user1());
    ts::return_shared(registry);

    scenario.end();
}

#[test]
fun test_mint_multiple_farms() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    // Add two farms
    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);
    registry.add_entity<STABLE, USD, FARM2>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    // Farm 1 mints
    let mint_amount_1 = usd(100);
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin_1 = coin::mint_for_testing<USD>(mint_amount_1, s.ctx());

    let (stable_coin_1, loan_1) = registry.mint<STABLE, USD, FARM1>(u_coin_1, s.ctx());

    // Verify minted stable coin and loan amounts for Farm 1
    assert!(stable_coin_1.value() == mint_amount_1);
    assert!(loan_1.value() == mint_amount_1);

    transfer::public_transfer(stable_coin_1, user1());
    let mut farm_sheet_1 = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet_1, creditor_entity, FARM1 {});
    let received_1 = sheet::receive(&mut farm_sheet_1, loan_1, FARM1 {});
    received_1.destroy_for_testing();
    farm_sheet_1.destroy_for_testing();

    ts::return_shared(registry);

    // Farm 2 mints
    let mint_amount_2 = usd(200);
    s.next_tx(user2());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin_2 = coin::mint_for_testing<USD>(mint_amount_2, s.ctx());

    let (stable_coin_2, loan_2) = registry.mint<STABLE, USD, FARM2>(u_coin_2, s.ctx());

    // Verify minted stable coin and loan amounts for Farm 2
    assert!(stable_coin_2.value() == mint_amount_2);
    assert!(loan_2.value() == mint_amount_2);

    // Verify total supply
    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.stable_supply() == mint_amount_1 + mint_amount_2);

    // Verify registry total supply across all factories
    assert!(registry.total_supply() == mint_amount_1 + mint_amount_2);

    transfer::public_transfer(stable_coin_2, user2());
    let mut farm_sheet_2 = sheet::new(FARM2 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet_2, creditor_entity, FARM2 {});
    let received_2 = sheet::receive(&mut farm_sheet_2, loan_2, FARM2 {});
    received_2.destroy_for_testing();
    farm_sheet_2.destroy_for_testing();

    ts::return_shared(registry);

    scenario.end();
}

#[test]
fun test_getters() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);
    let max_supply = usd(1_000_000);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();

    // Test versions getter
    let versions = registry.versions();
    assert!(versions.contains(&stable_layer::package_version()));

    // Test registry total_supply getter (should be 0 initially)
    assert!(registry.total_supply() == 0);

    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        max_supply,
        s.ctx()
    );

    // Test factory getters
    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.stable_supply() == 0);
    assert!(factory.max_supply() == max_supply);
    assert!(factory.managers().contains(&admin()));

    // Test sheet getter
    let sheet = factory.sheet();
    assert!(sheet.total_credit() == 0);
    assert!(sheet.total_debt() == 0);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

/// Error case tests

#[test, expected_failure(abort_code = stable_layer::EInvalidPackageVersion)]
fun test_error_invalid_package_version() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Remove the current package version
    stable_layer::remove_version(&admin_cap, &mut registry, stable_layer::package_version());

    // This should fail with EInvalidPackageVersion
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    transfer::public_transfer(factory_cap, admin());
    s.return_to_sender(admin_cap);
    ts::return_shared(registry);

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EFactoryAlreadyExists)]
fun test_error_factory_already_exists() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap_1 = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();

    let factory_cap_1 = registry.new<STABLE, USD>(
        treasury_cap_1,
        usd(1_000_000),
        s.ctx()
    );

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap_1, admin());

    // Create second treasury cap
    let treasury_cap_2 = create_treasury_cap(s);

    // Try to create another factory with same type parameters
    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();

    // This should fail with EFactoryAlreadyExists
    let factory_cap_2 = registry.new<STABLE, USD>(
        treasury_cap_2,
        usd(2_000_000),
        s.ctx()
    );

    transfer::public_transfer(factory_cap_2, admin());
    ts::return_shared(registry);

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::ETreasuryCapNotEmpty)]
fun test_error_treasury_cap_not_empty() {
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());

    // Create treasury cap using test function
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE>(s.ctx());

    // Mint some coins so treasury cap is not empty
    let stable_coin = treasury_cap.mint(usd(100), s.ctx());
    transfer::public_transfer(stable_coin, admin());

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();

    // This should fail with ETreasuryCapNotEmpty
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    transfer::public_transfer(factory_cap, admin());
    ts::return_shared(registry);

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EFactoryNotExists)]
fun test_error_factory_not_exists() {
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let registry = s.take_shared<StableRegistry>();

    // This should fail with EFactoryNotExists
    let _factory = registry.borrow_factory<STABLE, USD>();

    ts::return_shared(registry);

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::ERequestNotFulfilled)]
fun test_error_request_not_fulfilled() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    // Mint stable coins
    let mint_amount = usd(100);
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin = coin::mint_for_testing<USD>(mint_amount, s.ctx());

    let (stable_coin, loan) = registry.mint<STABLE, USD, FARM1>(u_coin, s.ctx());

    // Verify minted amounts
    assert!(stable_coin.value() == mint_amount);
    assert!(loan.value() == mint_amount);

    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received_balance = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received_balance.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);

    // Request burn but don't pay the full amount
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();

    let mut burn_request = registry.request_burn<STABLE, USD>(stable_coin);

    // Only pay partial amount
    let partial_payment = coin::mint_for_testing<USD>(mint_amount / 2, s.ctx());
    let mut farm_sheet = sheet::new(FARM1 {});
    let debtor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_debtor(&mut farm_sheet, debtor_entity, FARM1 {});
    sheet::pay(&mut farm_sheet, &mut burn_request, partial_payment.into_balance(), FARM1 {});
    farm_sheet.destroy_for_testing();

    // This should fail with ERequestNotFulfilled because shortage > 0
    let u_coin_out = registry.fulfill_burn<STABLE, USD>(burn_request, s.ctx());

    transfer::public_transfer(u_coin_out, user1());
    ts::return_shared(registry);

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EExceedMaxSupply)]
fun test_error_exceed_max_supply() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);
    let max_supply = usd(100); // Set a low max supply

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        max_supply,
        s.ctx()
    );

    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    // Try to mint more than max supply
    let mint_amount = usd(200); // Exceeds max_supply
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin = coin::mint_for_testing<USD>(mint_amount, s.ctx());

    // This should fail with EExceedMaxSupply
    let (stable_coin, loan) = registry.mint<STABLE, USD, FARM1>(u_coin, s.ctx());

    transfer::public_transfer(stable_coin, user1());
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);

    scenario.end();
}

#[test]
fun test_burn_with_multiple_payers() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);
    registry.add_entity<STABLE, USD, FARM2>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    // Farm 1 mints
    let mint_amount_1 = usd(60);
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin_1 = coin::mint_for_testing<USD>(mint_amount_1, s.ctx());

    let (_stable_coin_1, loan_1) = registry.mint<STABLE, USD, FARM1>(u_coin_1, s.ctx());

    // Verify Farm 1 mint amounts
    assert!(_stable_coin_1.value() == mint_amount_1);
    assert!(loan_1.value() == mint_amount_1);
    let loan_1_value = loan_1.value();

    let mut farm_sheet_1 = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet_1, creditor_entity, FARM1 {});
    let received_1 = sheet::receive(&mut farm_sheet_1, loan_1, FARM1 {});
    received_1.destroy_for_testing();
    farm_sheet_1.destroy_for_testing();

    transfer::public_transfer(_stable_coin_1, user1());
    ts::return_shared(registry);

    // Farm 2 mints
    let mint_amount_2 = usd(40);
    s.next_tx(user2());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin_2 = coin::mint_for_testing<USD>(mint_amount_2, s.ctx());

    let (_stable_coin_2, loan_2) = registry.mint<STABLE, USD, FARM2>(u_coin_2, s.ctx());

    // Verify Farm 2 mint amounts
    assert!(_stable_coin_2.value() == mint_amount_2);
    assert!(loan_2.value() == mint_amount_2);
    let loan_2_value = loan_2.value();

    let mut farm_sheet_2 = sheet::new(FARM2 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet_2, creditor_entity, FARM2 {});
    let received_2 = sheet::receive(&mut farm_sheet_2, loan_2, FARM2 {});
    received_2.destroy_for_testing();
    farm_sheet_2.destroy_for_testing();

    transfer::public_transfer(_stable_coin_2, user2());
    ts::return_shared(registry);

    // Merge coins and burn
    s.next_tx(user1());
    let mut stable_coin_1 = s.take_from_sender<Coin<STABLE>>();

    s.next_tx(user2());
    let stable_coin_2 = s.take_from_sender<Coin<STABLE>>();

    stable_coin_1.join(stable_coin_2);

    let total_burn = mint_amount_1 + mint_amount_2;

    // Verify merged stable coin amount
    assert!(stable_coin_1.value() == total_burn);

    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();

    let mut burn_request = registry.request_burn<STABLE, USD>(stable_coin_1);

    // Both farms pay their portions
    let repayment_1 = coin::mint_for_testing<USD>(loan_1_value, s.ctx());
    let repayment_2 = coin::mint_for_testing<USD>(loan_2_value, s.ctx());

    let mut farm_sheet_1 = sheet::new(FARM1 {});
    let debtor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_debtor(&mut farm_sheet_1, debtor_entity, FARM1 {});
    sheet::pay(&mut farm_sheet_1, &mut burn_request, repayment_1.into_balance(), FARM1 {});
    farm_sheet_1.destroy_for_testing();

    let mut farm_sheet_2 = sheet::new(FARM2 {});
    let debtor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_debtor(&mut farm_sheet_2, debtor_entity, FARM2 {});
    sheet::pay(&mut farm_sheet_2, &mut burn_request, repayment_2.into_balance(), FARM2 {});
    farm_sheet_2.destroy_for_testing();

    let u_coin_out = registry.fulfill_burn<STABLE, USD>(burn_request, s.ctx());
    assert!(u_coin_out.value() == total_burn);

    // Verify registry total supply is now 0 after fulfill_burn
    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.stable_supply() == 0);
    assert!(registry.total_supply() == 0);

    transfer::public_transfer(u_coin_out, user1());
    ts::return_shared(registry);

    scenario.end();
}

#[test]
fun test_max_supply_at_limit() {
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);
    let max_supply = usd(100);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        max_supply,
        s.ctx()
    );

    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    // Mint exactly at max supply - should succeed
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin = coin::mint_for_testing<USD>(max_supply, s.ctx());

    let (stable_coin, loan) = registry.mint<STABLE, USD, FARM1>(u_coin, s.ctx());

    // Verify minted amounts at max supply
    assert!(stable_coin.value() == max_supply);
    assert!(loan.value() == max_supply);

    let factory = registry.borrow_factory<STABLE, USD>();
    assert!(factory.stable_supply() == max_supply);

    // Verify registry total supply at max limit
    assert!(registry.total_supply() == max_supply);

    transfer::public_transfer(stable_coin, user1());
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);

    scenario.end();
}

#[test]
fun test_list_and_delist_entity() {
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Add USD type first
    admin_cap.add_usd_type<USD>(&mut registry, 6, s.ctx());

    // List FARM1
    admin_cap.list_entity<USD, FARM1>(&mut registry);

    // Create factory and add entity - should succeed
    let treasury_cap = coin::create_treasury_cap_for_testing<STABLE>(s.ctx());
    let factory_cap = registry.new<STABLE, USD>(treasury_cap, usd(1_000_000), s.ctx());
    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);

    // Delist FARM1 from USD type whitelist
    admin_cap.delist_entity<USD, FARM1>(&mut registry);

    // Note: Existing entities in factories are not affected by delist
    // They can still operate, but new add_entity calls for this entity will fail

    s.return_to_sender(admin_cap);
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidUsdType)]
fun test_error_invalid_usd_type_on_add_entity() {
    // Test that add_entity fails if USD type is not registered
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();

    // DO NOT add USD type

    // Create factory
    let treasury_cap = coin::create_treasury_cap_for_testing<STABLE>(s.ctx());
    let factory_cap = registry.new<STABLE, USD>(treasury_cap, usd(1_000_000), s.ctx());

    // This should fail with EInvalidUsdType because valid_entities<USD>() requires USD type
    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidEntity)]
fun test_error_invalid_entity() {
    // Test that adding an entity not in the whitelist fails
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    // FARM3 is NOT in the valid_entities list (setup only adds FARM1 and FARM2)
    // This should fail with EInvalidEntity
    registry.add_entity<STABLE, USD, FARM3>(&factory_cap);

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_total_supply_with_different_decimals() {
    // Test that total_supply is correctly normalized across different USD decimals
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Add two USD types with different decimals
    admin_cap.add_usd_type<USD>(&mut registry, 6, s.ctx()); // 6 decimals
    admin_cap.add_usd_type<USD8>(&mut registry, 8, s.ctx()); // 8 decimals

    // List entities for both USD types
    admin_cap.list_entity<USD, FARM1>(&mut registry);
    admin_cap.list_entity<USD8, FARM1>(&mut registry);

    s.return_to_sender(admin_cap);
    ts::return_shared(registry);

    // Create factory for 6-decimal USD
    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let treasury_cap_1 = coin::create_treasury_cap_for_testing<STABLE>(s.ctx());
    let factory_cap_1 = registry.new<STABLE, USD>(treasury_cap_1, usd(1_000_000), s.ctx());
    registry.add_entity<STABLE, USD, FARM1>(&factory_cap_1);

    // Mint 100 USD (6 decimals) = 100_000_000 units
    let mint_amount_6dec = usd(100); // 100 * 10^6 = 100_000_000
    let u_coin_1 = coin::mint_for_testing<USD>(mint_amount_6dec, s.ctx());
    let (stable_coin_1, loan_1) = registry.mint<STABLE, USD, FARM1>(u_coin_1, s.ctx());

    // total_supply should be 100_000_000 (normalized to 6 decimals)
    assert!(registry.total_supply() == mint_amount_6dec);

    transfer::public_transfer(stable_coin_1, admin());
    let mut farm_sheet_1 = sheet::new(FARM1 {});
    let creditor_entity_1 = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet_1, creditor_entity_1, FARM1 {});
    let received_1 = sheet::receive(&mut farm_sheet_1, loan_1, FARM1 {});
    received_1.destroy_for_testing();
    farm_sheet_1.destroy_for_testing();

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap_1, admin());

    // Create factory for 8-decimal USD
    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let treasury_cap_2 = coin::create_treasury_cap_for_testing<STABLE2>(s.ctx());
    let factory_cap_2 = registry.new<STABLE2, USD8>(treasury_cap_2, usd8(1_000_000), s.ctx());
    registry.add_entity<STABLE2, USD8, FARM1>(&factory_cap_2);

    // Mint 100 USD8 (8 decimals) = 10_000_000_000 units
    let mint_amount_8dec = usd8(100); // 100 * 10^8 = 10_000_000_000
    let u_coin_2 = coin::mint_for_testing<USD8>(mint_amount_8dec, s.ctx());
    let (stable_coin_2, loan_2) = registry.mint<STABLE2, USD8, FARM1>(u_coin_2, s.ctx());

    // total_supply should now be 100_000_000 + 100_000_000 = 200_000_000
    // because 10_000_000_000 (8 dec) normalized to 6 dec = 100_000_000
    // Formula: (10_000_000_000 * 10^6) / 10^8 = 100_000_000
    let expected_total = mint_amount_6dec + usd(100);
    assert!(registry.total_supply() == expected_total);

    transfer::public_transfer(stable_coin_2, admin());
    let mut farm_sheet_2 = sheet::new(FARM1 {});
    let creditor_entity_2 = entity<stable_layer::StableFactoryEntity<STABLE2, USD8>>();
    sheet::add_creditor(&mut farm_sheet_2, creditor_entity_2, FARM1 {});
    let received_2 = sheet::receive(&mut farm_sheet_2, loan_2, FARM1 {});
    received_2.destroy_for_testing();
    farm_sheet_2.destroy_for_testing();

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap_2, admin());

    scenario.end();
}

#[test]
fun test_default_decimal() {
    // Test that default_decimal returns 6
    assert!(stable_layer::default_decimal() == 6);
}

#[test, expected_failure(abort_code = stable_layer::EInvalidPackageVersion)]
fun test_error_invalid_version_on_list_entity() {
    // Test that list_entity fails with invalid package version
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Add USD type first
    admin_cap.add_usd_type<USD>(&mut registry, 6, s.ctx());

    // Remove current version
    stable_layer::remove_version(&admin_cap, &mut registry, stable_layer::package_version());

    // This should fail with EInvalidPackageVersion
    admin_cap.list_entity<USD, FARM1>(&mut registry);

    s.return_to_sender(admin_cap);
    ts::return_shared(registry);

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidPackageVersion)]
fun test_error_invalid_version_on_add_usd_type() {
    // Test that add_usd_type fails with invalid package version
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Remove current version first
    stable_layer::remove_version(&admin_cap, &mut registry, stable_layer::package_version());

    // This should fail with EInvalidPackageVersion
    admin_cap.add_usd_type<USD>(&mut registry, 6, s.ctx());

    s.return_to_sender(admin_cap);
    ts::return_shared(registry);

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidPackageVersion)]
fun test_error_invalid_version_on_delist_entity() {
    // Test that delist_entity fails with invalid package version
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Remove current version
    stable_layer::remove_version(&admin_cap, &mut registry, stable_layer::package_version());

    // This should fail with EInvalidPackageVersion
    admin_cap.delist_entity<USD, FARM1>(&mut registry);

    s.return_to_sender(admin_cap);
    ts::return_shared(registry);

    scenario.end();
}

/// New tests for audit coverage

#[test]
fun test_unban_entity() {
    // Tests the M-01 audit fix: unban_entity function
    let mut scenario = setup();
    let s = &mut scenario;

    let treasury_cap = create_treasury_cap(s);

    s.next_tx(admin());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap,
        usd(1_000_000),
        s.ctx()
    );

    // Add and then ban entity
    registry.add_entity<STABLE, USD, FARM1>(&factory_cap);
    registry.ban_entity<STABLE, USD, FARM1>(&factory_cap);

    // Unban entity (M-01 fix)
    registry.unban_entity<STABLE, USD, FARM1>(&factory_cap);

    // Verify entity can mint again after unbanning
    let mint_amount = usd(100);
    let u_coin = coin::mint_for_testing<USD>(mint_amount, s.ctx());
    let (stable_coin, loan) = registry.mint<STABLE, USD, FARM1>(u_coin, s.ctx());

    assert!(stable_coin.value() == mint_amount);
    assert!(loan.value() == mint_amount);

    // Cleanup
    transfer::public_transfer(stable_coin, admin());
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

/// Tests for new_with_initial_coin

#[test]
fun test_new_with_initial_coin() {
    let mut scenario = setup();
    let s = &mut scenario;

    // Create treasury cap and pre-mint tokens to simulate existing circulation
    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(500);
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1()); // simulate circulating supply

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    // Create USD coin for backing
    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    // Verify factory was created with correct state
    let factory = registry.borrow_factory<STABLE3, USD>();
    assert!(factory.stable_supply() == initial_amount);
    assert!(factory.max_supply() == usd(1_000_000));
    assert!(factory.managers().contains(&admin()));

    // Verify loan amount matches
    assert!(loan.value() == initial_amount);

    // Verify registry total_supply was updated
    assert!(registry.total_supply() == initial_amount);

    // Verify sheet has credit tracked
    let sheet = factory.sheet();
    assert!(sheet.total_credit() == initial_amount);

    // Cleanup
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE3, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_new_with_initial_coin_total_supply_consistency() {
    // Verify total_supply is consistent between new_with_initial_coin and subsequent mint
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(100);
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    // total_supply should reflect the initial amount
    assert!(registry.total_supply() == initial_amount);

    // Add entity for subsequent mints
    registry.add_entity<STABLE3, USD, FARM1>(&factory_cap);

    // Cleanup initial loan
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE3, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    // Now mint additional tokens
    let additional_amount = usd(200);
    s.next_tx(user1());
    let mut registry = s.take_shared<StableRegistry>();
    let u_coin = coin::mint_for_testing<USD>(additional_amount, s.ctx());
    let (stable_coin_2, loan_2) = registry.mint<STABLE3, USD, FARM1>(u_coin, s.ctx());

    // total_supply should be initial + additional
    assert!(registry.total_supply() == initial_amount + additional_amount);

    // Verify factory stable_supply
    let factory = registry.borrow_factory<STABLE3, USD>();
    assert!(factory.stable_supply() == initial_amount + additional_amount);

    // Cleanup
    transfer::public_transfer(stable_coin_2, user1());
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE3, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan_2, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);

    scenario.end();
}

#[test]
fun test_new_with_initial_coin_max_supply_at_limit() {
    // Test creating with initial amount exactly at max_supply
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(100);
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    // max_supply == initial_amount, should succeed
    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        initial_amount, // exactly at limit
        s.ctx(),
    );

    let factory = registry.borrow_factory<STABLE3, USD>();
    assert!(factory.stable_supply() == initial_amount);
    assert!(factory.max_supply() == initial_amount);

    // Cleanup
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE3, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidTreasuryCapSupply)]
fun test_error_new_with_initial_coin_supply_mismatch_too_low() {
    // treasury_cap.total_supply() != usd_coin.value() (supply < coin)
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    // Pre-mint only 50 USD worth of STABLE
    let stable_coin = treasury_cap.mint(usd(50), s.ctx());
    transfer::public_transfer(stable_coin, user1());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    // But provide 100 USD as backing (mismatch)
    let usd_coin = coin::mint_for_testing<USD>(usd(100), s.ctx());

    // Should fail: treasury supply (50) != usd amount (100)
    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    loan.destroy_for_testing().destroy_for_testing();
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidTreasuryCapSupply)]
fun test_error_new_with_initial_coin_supply_mismatch_too_high() {
    // treasury_cap.total_supply() != usd_coin.value() (supply > coin)
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    // Pre-mint 200 USD worth of STABLE
    let stable_coin = treasury_cap.mint(usd(200), s.ctx());
    transfer::public_transfer(stable_coin, user1());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    // But only provide 100 USD as backing (mismatch)
    let usd_coin = coin::mint_for_testing<USD>(usd(100), s.ctx());

    // Should fail: treasury supply (200) != usd amount (100)
    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    loan.destroy_for_testing().destroy_for_testing();
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidTreasuryCapSupply)]
fun test_error_new_with_initial_coin_zero_supply() {
    // treasury_cap.total_supply() == 0 but usd_coin > 0
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    let usd_coin = coin::mint_for_testing<USD>(usd(100), s.ctx());

    // Should fail: treasury supply (0) != usd amount (100)
    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    loan.destroy_for_testing().destroy_for_testing();
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EExceedMaxSupply)]
fun test_error_new_with_initial_coin_exceed_max_supply() {
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(200);
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    // max_supply (100) < treasury supply (200) - should fail
    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(100), // max_supply < initial amount
        s.ctx(),
    );

    loan.destroy_for_testing().destroy_for_testing();
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidEntity)]
fun test_error_new_with_initial_coin_invalid_entity() {
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(100);
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1());

    let mut registry = s.take_shared<StableRegistry>();

    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    // FARM3 is not in valid_entities - should fail
    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM3>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    loan.destroy_for_testing().destroy_for_testing();
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EFactoryAlreadyExists)]
fun test_error_new_with_initial_coin_factory_already_exists() {
    let mut scenario = setup();
    let s = &mut scenario;

    // First create a factory for STABLE3 using `new`
    s.next_tx(admin());
    let treasury_cap_1 = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let mut registry = s.take_shared<StableRegistry>();
    let factory_cap_1 = registry.new<STABLE3, USD>(
        treasury_cap_1,
        usd(1_000_000),
        s.ctx(),
    );
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap_1, admin());

    // Now try new_with_initial_coin with same STABLE3 type
    s.next_tx(admin());
    let mut treasury_cap_2 = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(100);
    let stable_coin = treasury_cap_2.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    // Should fail: factory for STABLE3 already exists
    let (factory_cap_2, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap_2,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    loan.destroy_for_testing().destroy_for_testing();
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap_2, admin());

    scenario.end();
}

#[test, expected_failure(abort_code = stable_layer::EInvalidPackageVersion)]
fun test_error_new_with_initial_coin_invalid_version() {
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(100);
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1());

    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Remove current version
    stable_layer::remove_version(&admin_cap, &mut registry, stable_layer::package_version());
    s.return_to_sender(admin_cap);

    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    // Should fail with EInvalidPackageVersion
    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    loan.destroy_for_testing().destroy_for_testing();
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_new_with_initial_coin_burn_flow() {
    // Full lifecycle: new_with_initial_coin then burn then fulfill
    let mut scenario = setup();
    let s = &mut scenario;

    s.next_tx(admin());
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd(500);
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());

    // FARM1 already listed in setup()
    let mut registry = s.take_shared<StableRegistry>();

    let usd_coin = coin::mint_for_testing<USD>(initial_amount, s.ctx());

    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD, FARM1>(
        treasury_cap,
        usd_coin,
        usd(1_000_000),
        s.ctx(),
    );

    assert!(registry.total_supply() == initial_amount);

    // Receive loan in farm
    let loan_value = loan.value();
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE3, USD>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    // Request burn with the circulating stable coin
    let mut burn_request = registry.request_burn<STABLE3, USD>(stable_coin);

    // Verify factory stable_supply is now 0
    let factory = registry.borrow_factory<STABLE3, USD>();
    assert!(factory.stable_supply() == 0);

    // Repay the burn request
    let repayment = coin::mint_for_testing<USD>(loan_value, s.ctx());
    let mut farm_sheet = sheet::new(FARM1 {});
    let debtor_entity = entity<stable_layer::StableFactoryEntity<STABLE3, USD>>();
    sheet::add_debtor(&mut farm_sheet, debtor_entity, FARM1 {});
    sheet::pay(&mut farm_sheet, &mut burn_request, repayment.into_balance(), FARM1 {});
    farm_sheet.destroy_for_testing();

    // Fulfill burn
    let u_coin_out = registry.fulfill_burn<STABLE3, USD>(burn_request, s.ctx());
    assert!(u_coin_out.value() == initial_amount);

    // Total supply should be 0 after full burn
    assert!(registry.total_supply() == 0);

    transfer::public_transfer(u_coin_out, admin());
    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}

#[test]
fun test_new_with_initial_coin_different_decimals() {
    // Test with 8-decimal USD type to verify normalized total_supply
    let mut scenario = ts::begin(admin());
    let s = &mut scenario;

    stable_layer::init_for_testing(s.ctx());

    s.next_tx(admin());
    let admin_cap = s.take_from_sender<AdminCap>();
    let mut registry = s.take_shared<StableRegistry>();

    // Register 8-decimal USD type
    admin_cap.add_usd_type<USD8>(&mut registry, 8, s.ctx());
    admin_cap.list_entity<USD8, FARM1>(&mut registry);
    s.return_to_sender(admin_cap);

    // Create treasury with 8-decimal amount
    let mut treasury_cap = coin::create_treasury_cap_for_testing<STABLE3>(s.ctx());
    let initial_amount = usd8(100); // 100 * 10^8 = 10_000_000_000
    let stable_coin = treasury_cap.mint(initial_amount, s.ctx());
    transfer::public_transfer(stable_coin, user1());

    let usd_coin = coin::mint_for_testing<USD8>(initial_amount, s.ctx());

    let (factory_cap, loan) = registry.new_with_initial_coin<STABLE3, USD8, FARM1>(
        treasury_cap,
        usd_coin,
        usd8(1_000_000),
        s.ctx(),
    );

    // total_supply should be normalized to 6 decimals
    // 10_000_000_000 * 10^6 / 10^8 = 100_000_000
    assert!(registry.total_supply() == usd(100));

    // Cleanup
    let mut farm_sheet = sheet::new(FARM1 {});
    let creditor_entity = entity<stable_layer::StableFactoryEntity<STABLE3, USD8>>();
    sheet::add_creditor(&mut farm_sheet, creditor_entity, FARM1 {});
    let received = sheet::receive(&mut farm_sheet, loan, FARM1 {});
    received.destroy_for_testing();
    farm_sheet.destroy_for_testing();

    ts::return_shared(registry);
    transfer::public_transfer(factory_cap, admin());

    scenario.end();
}
