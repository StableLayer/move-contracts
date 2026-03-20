module stable_layer::stable_layer;

use std::ascii::{String};
use std::type_name::{TypeName, with_defining_ids as get};
use sui::coin::{TreasuryCap, Coin};
use sui::vec_set::{Self, VecSet};
use sui::dynamic_object_field as dof;
use sui::event::{emit};
use stable_layer_framework::sheet::{
    Self, Sheet, entity, Loan, Request, Entity,
};

/// Version

const PACKAGE_VERSION: u16 = 4;
public fun package_version(): u16 { PACKAGE_VERSION }

const DEFAULT_DECIMAL: u8 = 6;
public fun default_decimal(): u8 { DEFAULT_DECIMAL }

/// Errors

const EInvalidPackageVersion: u64 = 0;
fun err_invalid_package_version() { abort EInvalidPackageVersion }

const EFactoryAlreadyExists: u64 = 1;
fun err_factory_already_exists() { abort EFactoryAlreadyExists }

const ERequestNotFulfilled: u64 = 2;
fun err_request_not_fulfilled() { abort ERequestNotFulfilled }

const ETreasuryCapNotEmpty: u64 = 3;
fun err_treasury_cap_not_empty() { abort ETreasuryCapNotEmpty }

const EFactoryNotExists: u64 = 4;
fun err_factory_not_exists() { abort EFactoryNotExists }

const EExceedMaxSupply: u64 = 5;
fun err_exceed_max_supply() { abort EExceedMaxSupply }

const EInvalidUsdType: u64 = 6;
fun err_invalid_usd_type() { abort EInvalidUsdType }

const EInvalidEntity: u64 = 7;
fun err_invalid_entity() { abort EInvalidEntity }

const EInvalidTreasuryCapSupply: u64 = 8;
fun err_invalid_treasury_cap_supply() { abort EInvalidTreasuryCapSupply }

/// Events

public struct NewStable has copy, drop {
    u_type: String,
    stable_type: String,
    factory_id: ID,
    factory_cap_id: ID,
}

public struct Mint has copy, drop {
    u_type: String,
    stable_type: String,
    mint_amount: u64,
    farm_type: String,
}

public struct Burn has copy, drop {
    u_type: String,
    stable_type: String,
    burn_amount: u64,
    farm_types: vector<Entity>,
    repayment_amounts: vector<u64>,
}

/// Structs

public struct StableFactoryEntity<phantom STABLE, phantom USD> has drop {}

/// Objects

public struct StableRegistry has key {
    id: UID,
    versions: VecSet<u16>,
    total_supply: u64,
}

public struct AdminCap has key, store {
    id: UID,
}

public struct StableFactory<phantom STABLE, phantom USD> has key, store {
    id: UID,
    treasury_cap: TreasuryCap<STABLE>,
    max_supply: u64,
    sheet: Sheet<USD, StableFactoryEntity<STABLE, USD>>,
    managers: VecSet<address>,
}

public struct FactoryCap<phantom STABLE, phantom USD> has key, store {
    id: UID,
    factory_id: ID,
}

// USD config

public struct UsdType<phantom USD> has copy, drop, store {}

public struct UsdConfig has key, store {
    id: UID,
    valid_entities: VecSet<Entity>,
    decimal: u8,
}

/// Init

fun init(ctx: &mut TxContext) {
    let registry = StableRegistry {
        id: object::new(ctx),
        versions: vec_set::singleton(package_version()),
        total_supply: 0,
    };
    transfer::share_object(registry);
    let cap = AdminCap { id: object::new(ctx) };
    transfer::transfer(cap, ctx.sender());
}

/// Admin Funs

public fun new<STABLE, USD>(
    registry: &mut StableRegistry,
    treasury_cap: TreasuryCap<STABLE>,
    max_supply: u64,
    ctx: &mut TxContext,
): FactoryCap<STABLE, USD> {
    registry.assert_valid_package_version();
    if (treasury_cap.total_supply() > 0) {
        err_treasury_cap_not_empty();
    };
    let factory = StableFactory {
        id: object::new(ctx),
        treasury_cap,
        max_supply,
        sheet: sheet::new(StableFactoryEntity<STABLE, USD> {}),
        managers: vec_set::singleton(ctx.sender()),
    };

    let factory_cap = FactoryCap {
        id: object::new(ctx),
        factory_id: object::id(&factory),
    };

    emit(NewStable {
        u_type: get<USD>().into_string(),
        stable_type: get<STABLE>().into_string(),
        factory_id: object::id(&factory),
        factory_cap_id: object::id(&factory_cap),
    });
    let factory_name = get<STABLE>();
    if (dof::exists_(&registry.id, factory_name)) {
        err_factory_already_exists();
    };
    dof::add(&mut registry.id, factory_name, factory);

    factory_cap
}

public fun new_with_initial_coin<STABLE, USD, FARM>(
    registry: &mut StableRegistry,
    treasury_cap: TreasuryCap<STABLE>,
    usd_coin: Coin<USD>,
    max_supply: u64,
    ctx: &mut TxContext,
): (FactoryCap<STABLE, USD>, Loan<USD, StableFactoryEntity<STABLE, USD>, FARM>) {
    registry.assert_valid_package_version();
    let usd_amount = usd_coin.value();
    if (treasury_cap.total_supply() != usd_amount) {
        err_invalid_treasury_cap_supply();
    };
    if (treasury_cap.total_supply() > max_supply) {
        err_exceed_max_supply();
    };
    let mut factory = StableFactory {
        id: object::new(ctx),
        treasury_cap,
        max_supply,
        sheet: sheet::new(StableFactoryEntity<STABLE, USD> {}),
        managers: vec_set::singleton(ctx.sender()),
    };

    let factory_cap = FactoryCap {
        id: object::new(ctx),
        factory_id: object::id(&factory),
    };

    emit(NewStable {
        u_type: get<USD>().into_string(),
        stable_type: get<STABLE>().into_string(),
        factory_id: object::id(&factory),
        factory_cap_id: object::id(&factory_cap),
    });

    let farm_entity = entity<FARM>();
    if (!registry.valid_entities<USD>().contains(&farm_entity)) {
        err_invalid_entity();
    };
    factory.sheet.add_debtor(farm_entity, StableFactoryEntity<STABLE, USD> {});

    let loan = factory.sheet.lend(
        usd_coin.into_balance(),
        StableFactoryEntity<STABLE, USD> {},
    );

    emit(Mint {
        u_type: get<USD>().into_string(),
        stable_type: get<STABLE>().into_string(),
        mint_amount: usd_amount,
        farm_type: get<FARM>().into_string(),
    });

    let factory_name = get<STABLE>();
    if (dof::exists_(&registry.id, factory_name)) {
        err_factory_already_exists();
    };
    dof::add(&mut registry.id, factory_name, factory);

    registry.total_supply = registry.total_supply + registry.normalized_supply<USD>(usd_amount);

    (factory_cap, loan)
}

#[allow(lint(share_owned, self_transfer))]
public fun default<STABLE, USD>(
    registry: &mut StableRegistry,
    treasury_cap: TreasuryCap<STABLE>,
    max_supply: u64,
    ctx: &mut TxContext,
) {
    let factory_cap = registry.new<STABLE, USD>(
        treasury_cap, max_supply, ctx,
    );
    transfer::transfer(factory_cap, ctx.sender());
}

/// Admin Funs

public fun add_version(
    _admin_cap: &AdminCap,
    registry: &mut StableRegistry,
    version: u16,
) {
    registry.versions.insert(version);
}

public fun remove_version(
    _admin_cap: &AdminCap,
    registry: &mut StableRegistry,
    version: u16,
) {
    registry.versions.remove(&version);
}

public fun add_usd_type<USD>(
    _admin_cap: &AdminCap,
    registry: &mut StableRegistry,
    decimal: u8,
    ctx: &mut TxContext,
) {
    registry.assert_valid_package_version();
    dof::add(&mut registry.id, UsdType<USD> {}, UsdConfig {
        id: object::new(ctx),
        valid_entities: vec_set::empty(),
        decimal,
    });
}

public fun list_entity<USD, FARM>(
    _admin_cap: &AdminCap,
    registry: &mut StableRegistry,
) {
    registry.assert_valid_package_version();
    dof::borrow_mut<UsdType<USD>, UsdConfig>(
        &mut registry.id, UsdType<USD> {}
    )
    .valid_entities
    .insert(entity<FARM>());
}

public fun delist_entity<USD, FARM>(
    _admin_cap: &AdminCap,
    registry: &mut StableRegistry,
) {
    registry.assert_valid_package_version();
    dof::borrow_mut<UsdType<USD>, UsdConfig>(
        &mut registry.id, UsdType<USD> {}
    )
    .valid_entities
    .remove(&entity<FARM>());
}

/// Factory Cap Funs

public fun add_entity<STABLE, USD, FARM>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
) {
    let farm_entity = entity<FARM>();
    if (!registry.valid_entities<USD>().contains(&farm_entity)) {
        err_invalid_entity();
    };
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    factory.sheet.add_debtor(farm_entity, StableFactoryEntity<STABLE, USD> {});
}

public fun ban_entity<STABLE, USD, FARM>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
) {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    factory.sheet.ban(entity<FARM>(), StableFactoryEntity<STABLE, USD> {});
}

public fun unban_entity<STABLE, USD, FARM>( // M-01
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
) {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    factory.sheet.unban(entity<FARM>(), StableFactoryEntity<STABLE, USD> {});
}

public fun add_manager<STABLE, USD>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
    manager: address,
) {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    factory.managers.insert(manager);
}

public fun remove_manager<STABLE, USD>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
    manager: address,
) {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    factory.managers.remove(&manager);
}

public fun set_max_supply<STABLE, USD>(
    registry: &mut StableRegistry,
    _factory_cap: &FactoryCap<STABLE, USD>,
    max_supply: u64,
) {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    factory.max_supply = max_supply;
}

/// Public Funs

public fun mint<STABLE, USD, FARM>(
    registry: &mut StableRegistry,
    u_coin: Coin<USD>,
    ctx: &mut TxContext,
): (Coin<STABLE>, Loan<USD, StableFactoryEntity<STABLE, USD>, FARM>) {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    let u_amount = u_coin.value();
    let loan = factory.sheet.lend(
        u_coin.into_balance(),
        StableFactoryEntity<STABLE, USD> {},
    );
    let stable_out = factory.treasury_cap.mint(u_amount, ctx);
    if (factory.stable_supply() > factory.max_supply()) {
        err_exceed_max_supply();
    };
    emit(Mint {
        u_type: get<USD>().into_string(),
        stable_type: get<STABLE>().into_string(),
        mint_amount: u_amount,
        farm_type: get<FARM>().into_string(),
    });
    registry.total_supply = registry.total_supply + registry.normalized_supply<USD>(u_amount);
    (stable_out, loan)
}

public fun request_burn<STABLE, USD>(
    registry: &mut StableRegistry,
    stable_coin: Coin<STABLE>,
): Request<USD, StableFactoryEntity<STABLE, USD>> {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    let stable_amount = stable_coin.value();
    factory.treasury_cap.burn(stable_coin);
    sheet::request(
        stable_amount,
        option::none(),
        StableFactoryEntity<STABLE, USD> {},
    )
}

public fun fulfill_burn<STABLE, USD>(
    registry: &mut StableRegistry,
    burn_request: Request<USD, StableFactoryEntity<STABLE, USD>>,
    ctx: &mut TxContext,
): Coin<USD> {
    let factory = registry.borrow_factory_mut<STABLE, USD>();
    if (burn_request.shortage() > 0) {
        err_request_not_fulfilled();
    };
    let farm_types = burn_request.payer_debts().keys();
    let repayment_amounts = farm_types.map_ref!(|farm_type| {
        burn_request.payer_debts().get(farm_type).value()
    });
    emit(Burn {
        u_type: get<USD>().into_string(),
        stable_type: get<STABLE>().into_string(),
        burn_amount: burn_request.balance(),
        farm_types,
        repayment_amounts,
    });
    let u_coin = factory
        .sheet
        .collect(burn_request, StableFactoryEntity<STABLE, USD> {})
        .into_coin(ctx);
    registry.total_supply = registry.total_supply - registry.normalized_supply<USD>(u_coin.value());
    u_coin
}

/// Getter Fun

public fun versions(registry: &StableRegistry): &VecSet<u16> {
    &registry.versions
}

public fun total_supply(registry: &StableRegistry): u64 {
    registry.total_supply
}

public fun borrow_factory<STABLE, USD>(registry: &StableRegistry): &StableFactory<STABLE, USD> {
    let name = get<STABLE>();
    if (!dof::exists_(&registry.id, name)) {
        err_factory_not_exists();
    };
    dof::borrow<TypeName, StableFactory<STABLE, USD>>(&registry.id, name)
}

public fun sheet<STABLE, USD>(
    factory: &StableFactory<STABLE, USD>,
): &Sheet<USD, StableFactoryEntity<STABLE, USD>> {
    &factory.sheet
}

public fun stable_supply<STABLE, USD>(
    factory: &StableFactory<STABLE, USD>,
): u64 {
    factory.treasury_cap.total_supply()
}

public fun max_supply<STABLE, USD>(
    factory: &StableFactory<STABLE, USD>,
): u64 {
    factory.max_supply
}

public fun managers<STABLE, USD>(
    factory: &StableFactory<STABLE, USD>,
): &VecSet<address> {
    &factory.managers
}

// Internal Fun

fun assert_valid_package_version(registry: &StableRegistry) {
    if (!registry.versions().contains(&package_version())) {
        err_invalid_package_version();
    };
}

fun borrow_factory_mut<STABLE, USD>(registry: &mut StableRegistry): &mut StableFactory<STABLE, USD> {
    registry.assert_valid_package_version();
    let name = get<STABLE>();
    if (!dof::exists_(&registry.id, name)) {
        err_factory_not_exists();
    };
    dof::borrow_mut<TypeName, StableFactory<STABLE, USD>>(&mut registry.id, name)
}

fun valid_entities<USD>(registry: &StableRegistry): &VecSet<Entity> {
    let usd_type = UsdType<USD> {};
    if (!dof::exists_<UsdType<USD>>(&registry.id, usd_type)) {
        err_invalid_usd_type();
    };
    &dof::borrow<UsdType<USD>, UsdConfig>(&registry.id, usd_type).valid_entities

}

fun normalized_supply<USD>(registry: &StableRegistry, u_amount: u64): u64 { // L-01
    let usd_type = UsdType<USD> {};
    if (!dof::exists_<UsdType<USD>>(&registry.id, usd_type)) {
        err_invalid_usd_type();
    };
    let u_decimal = dof::borrow<UsdType<USD>, UsdConfig>(&registry.id, usd_type).decimal;
    ((u_amount as u128) * (10u128.pow(default_decimal())) / (10u128.pow(u_decimal)) as u64)
}

/// Test-only
#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}
