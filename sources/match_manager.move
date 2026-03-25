
module hunger_battle_arena::match_manager;

use one::event;
use one::table::{Self, Table};
use std::string::{Self, String};

/* ===================== CONSTANTS ===================== */

const CREATED: u8 = 0;
const IN_GAME: u8 = 1;
const ENDED: u8 = 2;
const CANCELLED: u8 = 3;

const E_NOT_FIGHTER: u64 = 0;
const E_INVALID_STATE: u64 = 2;
const E_ALREADY_ENDED: u64 = 3;
const E_NOT_IN_GAME: u64 = 4;
const E_NAME_TOO_LONG: u64 = 5;
const E_VAULT_ALREADY_SET: u64 = 6;
const E_NOT_CANCELABLE: u64 = 7;
const E_START_REQUIRES_BOTH_SIDES: u64 = 8;
const E_TWO_SIDES_ALREADY_MET: u64 = 10;
const COIN_DECIMALS_FACTOR: u64 = 1000000000;
const DEFAULT_FIGHTER_STAKE: u64 = 10 * COIN_DECIMALS_FACTOR;

/* ===================== EVENTS ===================== */

public struct MatchCreated has copy, drop {
    match_id: object::ID,
    fighter: address,
    name: String,
}

public struct MatchStarted has copy, drop {
    match_id: object::ID,
    fighter: address,
}

public struct MatchEnded has copy, drop {
    match_id: object::ID,
    fighter: address,
    is_win: bool,
}

public struct MatchCancelled has copy, drop {
    match_id: object::ID,
    fighter: address,
}

/* ===================== CAPS ===================== */

public struct AdminCap has key, store {
    id: object::UID,
}

/* ===================== VIEW STRUCT ===================== */
/* dùng cho VIEW + UI */

public struct MatchView has copy, drop, store {
    match_id: object::ID,
    vault_id: Option<object::ID>,
    name: String,
    fighter: address,
    fighter_stake: u64,
    status: u8,
    result: Option<bool>,
    cancel_stake_refundable: bool,
    total_pool: u64,
    total_bet_viewers: u64,
    win_bets_total: u64,
    lose_bets_total: u64,
    win_bettors_count: u64,
    lose_bettors_count: u64,
}

/* ===================== REGISTRY ===================== */

public struct Registry has key, store {
    id: object::UID,
    match_ids: vector<object::ID>,
}

/* ===================== MATCH (OBJECT) ===================== */

public struct Match has key, store {
    id: object::UID,
    vault_id: Option<object::ID>,
    name: String,
    fighter: address,
    fighter_stake: u64,
    status: u8,
    result: Option<bool>,
    cancel_stake_refundable: bool,
    total_pool: u64,
    total_bet_viewers: u64,
    win_bets_total: u64,
    lose_bets_total: u64,
    win_bets: Table<address, u64>,
    lose_bets: Table<address, u64>,
}

/* ===================== INIT ===================== */

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        AdminCap { id: object::new(ctx) },
        tx_context::sender(ctx),
    );

    let registry = Registry {
        id: object::new(ctx),
        match_ids: vector::empty<object::ID>(),
    };

    transfer::public_share_object(registry);
}

/* ===================== MATCH CORE FUNCTION ===================== */

public(package) fun create_match_internal(
    registry: &mut Registry,
    name_bytes: vector<u8>,
    ctx: &mut TxContext,
): Match {
    assert!(vector::length(&name_bytes) <= 20, E_NAME_TOO_LONG);

    let fighter = tx_context::sender(ctx);
    let name = string::utf8(name_bytes);

    let m = Match {
        id: object::new(ctx),
        vault_id: option::none(),
        name,
        fighter,
        fighter_stake: DEFAULT_FIGHTER_STAKE,
        status: CREATED,
        result: option::none(),
        cancel_stake_refundable: false,
        total_pool: 0,
        total_bet_viewers: 0,
        win_bets_total: 0,
        lose_bets_total: 0,
        win_bets: table::new(ctx),
        lose_bets: table::new(ctx),
    };

    let match_id = object::id(&m);

    vector::push_back(&mut registry.match_ids, match_id);

    event::emit(MatchCreated {
        match_id,
        fighter,
        name: m.name,
    });

    m
}

public fun start_match(m: &mut Match, ctx: &mut TxContext) {
    assert!(m.status == CREATED, E_INVALID_STATE);
    assert!(tx_context::sender(ctx) == m.fighter, E_NOT_FIGHTER);
    assert!(m.win_bets_total > 0 && m.lose_bets_total > 0, E_START_REQUIRES_BOTH_SIDES);

    m.status = IN_GAME;

    event::emit(MatchStarted {
        match_id: object::id(m),
        fighter: m.fighter,
    });
}

public fun end_match(
    _: &AdminCap,
    m: &mut Match,
    is_win: bool,
) {
    assert!(m.status == IN_GAME, E_NOT_IN_GAME);
    assert!(option::is_none(&m.result), E_ALREADY_ENDED);

    m.status = ENDED;
    m.result = option::some(is_win);

    event::emit(MatchEnded {
        match_id: object::id(m),
        fighter: m.fighter,
        is_win,
    });
}

public(package) fun cancel_match_with_refund(m: &mut Match) {
    assert!(m.status == CREATED, E_NOT_CANCELABLE);
    assert!(option::is_none(&m.result), E_ALREADY_ENDED);
    assert!(!(m.win_bets_total > 0 && m.lose_bets_total > 0), E_TWO_SIDES_ALREADY_MET);

    m.status = CANCELLED;
    m.result = option::none();
    m.cancel_stake_refundable = true;

    event::emit(MatchCancelled {
        match_id: object::id(m),
        fighter: m.fighter,
    });
}

public(package) fun cancel_match_with_slash(m: &mut Match) {
    assert!(m.status == CREATED || m.status == IN_GAME, E_NOT_CANCELABLE);
    assert!(option::is_none(&m.result), E_ALREADY_ENDED);

    m.status = CANCELLED;
    m.result = option::none();
    m.cancel_stake_refundable = false;

    event::emit(MatchCancelled {
        match_id: object::id(m),
        fighter: m.fighter,
    });
}

/* ===================== VIEWS ===================== */

public fun get_match_ids(registry: &Registry): vector<object::ID> {
    registry.match_ids
}

public fun match_view(m: &Match): MatchView {
    MatchView {
        match_id: object::id(m),
        vault_id: m.vault_id,
        name: m.name,
        fighter: m.fighter,
        fighter_stake: m.fighter_stake,
        status: m.status,
        result: m.result,
        cancel_stake_refundable: m.cancel_stake_refundable,
        total_pool: m.total_pool,
        total_bet_viewers: m.total_bet_viewers,
        win_bets_total: m.win_bets_total,
        lose_bets_total: m.lose_bets_total,
        win_bettors_count: table::length(&m.win_bets),
        lose_bettors_count: table::length(&m.lose_bets),
    }
}

public fun match_vault_id(m: &Match): Option<object::ID> {
    m.vault_id
}

public(package) fun is_created(m: &Match): bool {
    m.status == CREATED
}

public(package) fun is_ended(m: &Match): bool {
    m.status == ENDED && option::is_some(&m.result)
}

public(package) fun is_cancelled(m: &Match): bool {
    m.status == CANCELLED
}

public(package) fun fighter(m: &Match): address {
    m.fighter
}

public(package) fun fighter_stake(m: &Match): u64 {
    m.fighter_stake
}

public fun default_fighter_stake(): u64 {
    DEFAULT_FIGHTER_STAKE
}

public(package) fun result_value(m: &Match): bool {
    *option::borrow(&m.result)
}

public(package) fun has_two_sided_bets(m: &Match): bool {
    m.win_bets_total > 0 && m.lose_bets_total > 0
}

public(package) fun cancel_stake_refundable(m: &Match): bool {
    m.status == CANCELLED && m.cancel_stake_refundable
}

public(package) fun has_win_bet(m: &Match, bettor: address): bool {
    table::contains(&m.win_bets, bettor)
}

public(package) fun has_lose_bet(m: &Match, bettor: address): bool {
    table::contains(&m.lose_bets, bettor)
}

public(package) fun win_bet_amount(m: &Match, bettor: address): u64 {
    *table::borrow(&m.win_bets, bettor)
}

public(package) fun lose_bet_amount(m: &Match, bettor: address): u64 {
    *table::borrow(&m.lose_bets, bettor)
}

public(package) fun win_bets_total(m: &Match): u64 {
    m.win_bets_total
}

public(package) fun lose_bets_total(m: &Match): u64 {
    m.lose_bets_total
}

public(package) fun total_pool(m: &Match): u64 {
    m.total_pool
}

public(package) fun set_vault_id(m: &mut Match, vault_id: object::ID) {
    assert!(option::is_none(&m.vault_id), E_VAULT_ALREADY_SET);
    m.vault_id = option::some(vault_id);
}

public(package) fun add_win_bet(m: &mut Match, bettor: address, amount: u64) {
    table::add(&mut m.win_bets, bettor, amount);
    m.win_bets_total = m.win_bets_total + amount;
    m.total_pool = m.total_pool + amount;
    m.total_bet_viewers = m.total_bet_viewers + 1;
}

public(package) fun add_lose_bet(m: &mut Match, bettor: address, amount: u64) {
    table::add(&mut m.lose_bets, bettor, amount);
    m.lose_bets_total = m.lose_bets_total + amount;
    m.total_pool = m.total_pool + amount;
    m.total_bet_viewers = m.total_bet_viewers + 1;
}

/* ===================== TESTS ===================== */

#[test_only]
public(package) fun create_test_registry(ctx: &mut TxContext): Registry {
    Registry {
        id: object::new(ctx),
        match_ids: vector::empty<object::ID>(),
    }
}

#[test_only]
public(package) fun create_test_match(fighter: address, ctx: &mut TxContext): Match {
    Match {
        id: object::new(ctx),
        vault_id: option::none(),
        name: string::utf8(b"TestMatch"),
        fighter,
        fighter_stake: DEFAULT_FIGHTER_STAKE,
        status: CREATED,
        result: option::none(),
        cancel_stake_refundable: false,
        total_pool: 0,
        total_bet_viewers: 0,
        win_bets_total: 0,
        lose_bets_total: 0,
        win_bets: table::new(ctx),
        lose_bets: table::new(ctx),
    }
}

#[test_only]
public(package) fun create_test_admin(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

#[test_only]
public(package) fun destroy_test_admin(admin: AdminCap) {
    let AdminCap { id } = admin;
    object::delete(id);
}

#[test_only]
public(package) fun set_status_in_game(m: &mut Match) {
    m.status = IN_GAME;
}

#[test_only]
public(package) fun test_units(amount: u64): u64 {
    amount * COIN_DECIMALS_FACTOR
}

/* ---------- create_match ---------- */

#[test]
fun test_create_match_success() {
    let mut ctx = tx_context::dummy();
    let mut registry = create_test_registry(&mut ctx);

    let m = create_match_internal(&mut registry, b"MyMatch", &mut ctx);

    let ids = get_match_ids(&registry);
    assert!(vector::length(&ids) == 1, 1);
    transfer::transfer(m, @0x0);
    transfer::transfer(registry, @0x0);
}



/* ---------- start_match ---------- */

#[test]
fun test_start_match_success() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);
    let viewer_win = @0xB;
    let viewer_lose = @0xC;

    let mut registry = create_test_registry(&mut ctx);
    let m_created = create_match_internal(&mut registry, b"TestMatch", &mut ctx);

    let mut m = create_test_match(fighter, &mut ctx);
    add_win_bet(&mut m, viewer_win, test_units(10));
    add_lose_bet(&mut m, viewer_lose, test_units(10));
    start_match(&mut m, &mut ctx);

    assert!(m.status == IN_GAME, 1);

    let v = match_view(&m);
    assert!(v.status == IN_GAME, 2);

    transfer::transfer(m, @0x0);
    transfer::transfer(m_created, @0x0);
    transfer::transfer(registry, @0x0);
}


/* ---------- end_match ---------- */

#[test]
fun test_end_match_win() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let admin = create_test_admin(&mut ctx);
    let mut m = create_test_match(fighter, &mut ctx);
    m.status = IN_GAME;
    end_match(&admin, &mut m, true);

    assert!(m.status == ENDED, 1);
    assert!(option::contains(&m.result, &true), 2);

    transfer::transfer(m, @0x0);
    transfer::transfer(admin, @0x0);
}

#[test]
fun test_cancel_match_created() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let mut m = create_test_match(fighter, &mut ctx);
    cancel_match_with_refund(&mut m);

    assert!(m.status == CANCELLED, 1);
    assert!(option::is_none(&m.result), 2);
    assert!(m.cancel_stake_refundable, 3);

    transfer::transfer(m, @0x0);
}

#[test]
fun test_cancel_match_in_game() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let mut m = create_test_match(fighter, &mut ctx);
    m.status = IN_GAME;
    cancel_match_with_slash(&mut m);

    assert!(m.status == CANCELLED, 1);
    assert!(option::is_none(&m.result), 2);
    assert!(!m.cancel_stake_refundable, 3);

    transfer::transfer(m, @0x0);
}

/* ---------- view ---------- */

#[test]
fun test_match_view() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let m = create_test_match(fighter, &mut ctx);

    let v = match_view(&m);

    assert!(option::is_none(&v.vault_id), 1);
    assert!(v.name == string::utf8(b"TestMatch"), 2);
    assert!(v.fighter == fighter, 3);
    assert!(v.fighter_stake == DEFAULT_FIGHTER_STAKE, 4);
    assert!(v.status == CREATED, 5);
    assert!(option::is_none(&v.result), 6);
    assert!(!v.cancel_stake_refundable, 7);
    assert!(v.total_pool == 0, 8);
    assert!(v.total_bet_viewers == 0, 9);

    transfer::public_share_object(m);
}
