module mock_farm::farm;

use std::type_name::{TypeName, with_defining_ids as get};
use sui::coin::{TreasuryCap, Coin};
use sui::balance::{Self, Balance};
use sui::clock::{Clock};
use sui::coin_registry::{CoinRegistry};
use sui::table::{Self, Table};
use sui::dynamic_object_field as dof;
use stable_layer_framework::sheet::{Self, Sheet, Loan, Request, Entity, entity};
use stable_layer_framework::double::{Self, Double};
use stable_layer::stable_layer::{StableRegistry, StableFactoryEntity};
use mock_farm::usdb::{Self, USDB};

/// Errors

#[error]
const ENotSupportedCoinType: vector<u8> = b"not supported coin type";

#[error]
const ESenderIsNotManager: vector<u8> = b"sender is not manager";

/// Witness

public struct MockFarmEntity has drop {}

/// Objects

public struct AdminCap has key, store {
    id: UID,
}

public struct FarmRegistry has key {
    id: UID,
    usdb_treasury_cap: Option<TreasuryCap<USDB>>,
    saving_rate: Double,
}

public struct Farm<phantom USD> has key, store {
    id: UID,
    sheet: Sheet<USD, MockFarmEntity>,
    states: Table<Entity, State<USD>>,
}

public struct State<phantom USD> has store {
    stake: Balance<USD>,
    reward: Balance<USDB>,
    timestamp: u64,
}

/// Init

fun init(ctx: &mut TxContext) {
    transfer::transfer(AdminCap { id: object::new(ctx) }, ctx.sender());
}

/// Admin Functions

#[allow(lint(self_transfer))]
public fun create_registry(
    _cap: &AdminCap,
    coin_registry: &mut CoinRegistry,
    saving_rate_bps: u64,
    ctx: &mut TxContext,
) {
    let (usdb_treasury_cap, usdb_metadata_cap) = usdb::initialize(coin_registry, ctx);
    let farm_registry = FarmRegistry {
        id: object::new(ctx),
        usdb_treasury_cap: option::some(usdb_treasury_cap),
        saving_rate: double::from_bps(saving_rate_bps),
    };
    transfer::share_object(farm_registry);
    transfer::public_transfer(usdb_metadata_cap, ctx.sender());
}

public fun create_farm<USD>(
    _cap: &AdminCap,
    farm_registry: &mut FarmRegistry,
    ctx: &mut TxContext,
) {
    let farm = Farm<USD> {
        id: object::new(ctx),
        sheet: sheet::new(stamp()),
        states: table::new(ctx),
    };
    dof::add(&mut farm_registry.id, get<USD>(), farm);
}

/// Public Function

public fun receive<STABLE, USD>(
    farm_registry: &mut FarmRegistry,
    loan: Loan<USD, StableFactoryEntity<STABLE, USD>, MockFarmEntity>,
    clock: &Clock,
) {
    let saving_rate = farm_registry.saving_rate;
    let mut usdb_treasury_cap = farm_registry.usdb_treasury_cap.extract();
    let farm_mut = farm_registry.borrow_farm_mut<USD>();
    let factory_entity = entity<StableFactoryEntity<STABLE, USD>>();
    if (!farm_mut.sheet.debts().contains(&factory_entity)) {
        farm_mut.sheet.add_creditor(factory_entity, stamp());
    };
    let u_balance = farm_mut.sheet.receive(loan, stamp());
    let state_mut = farm_mut.borrow_state_mut(factory_entity, clock);
    state_mut.settle_reward(&mut usdb_treasury_cap, saving_rate, clock);
    state_mut.stake.join(u_balance);
    farm_registry.usdb_treasury_cap.fill(usdb_treasury_cap);
}

public fun pay<STABLE, USD>(
    farm_registry: &mut FarmRegistry,
    clock: &Clock,
    request: &mut Request<USD, StableFactoryEntity<STABLE, USD>>,
) {
    let saving_rate = farm_registry.saving_rate;
    let mut usdb_treasury_cap = farm_registry.usdb_treasury_cap.extract();
    let farm_mut = farm_registry.borrow_farm_mut<USD>();
    let factory_entity = entity<StableFactoryEntity<STABLE, USD>>();
    let state_mut = farm_mut.borrow_state_mut(factory_entity, clock);
    state_mut.settle_reward(&mut usdb_treasury_cap, saving_rate, clock);
    let u_balance = state_mut.stake.split(request.shortage());
    farm_mut.sheet.pay(request, u_balance, stamp());
    farm_registry.usdb_treasury_cap.fill(usdb_treasury_cap);
}

public fun claim<STABLE, USD>(
    farm_registry: &mut FarmRegistry,
    stable_registry: &StableRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<USDB> {
    let managers = stable_registry.borrow_factory<STABLE, USD>().managers();
    assert!(managers.contains(&ctx.sender()), ESenderIsNotManager);
    let factory_entity = entity<StableFactoryEntity<STABLE, USD>>();
    farm_registry
        .borrow_farm_mut<USD>()
        .borrow_state_mut(factory_entity, clock)
        .reward
        .withdraw_all()
        .into_coin(ctx)
}

/// Internal Functions

fun one_year(): u64 { 86400_000 * 365 }

fun borrow_farm_mut<U>(farm_registry: &mut FarmRegistry): &mut Farm<U> {
    let coin_type = get<U>();
    assert!(
        dof::exists_<TypeName>(&farm_registry.id, coin_type),
        ENotSupportedCoinType,
    );
    dof::borrow_mut(&mut farm_registry.id, coin_type)
}

fun borrow_state_mut<U>(farm: &mut Farm<U>, entity: Entity, clock: &Clock): &mut State<U> {
    if (!farm.states.contains(entity)) {
        farm.states.add(entity, State {
            stake: balance::zero(),
            reward: balance::zero(),
            timestamp: clock.timestamp_ms(),
        });
    };
    farm.states.borrow_mut(entity)
}

fun settle_reward<U>(
    state_mut: &mut State<U>,
    usdb_treasury_cap: &mut TreasuryCap<USDB>,
    saving_rate: Double,
    clock: &Clock,
) {
    let now = clock.timestamp_ms();
    let reward_amount = saving_rate
        .mul_u64(state_mut.stake.value())
        .div_u64(one_year())
        .mul_u64(now - state_mut.timestamp)
        .floor();
    let reward = usdb_treasury_cap.mint_balance(reward_amount);
    state_mut.timestamp = now;
    state_mut.reward.join(reward);
}

fun stamp(): MockFarmEntity { MockFarmEntity {} }
