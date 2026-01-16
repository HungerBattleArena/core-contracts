
module hunger_battle_arena::match_manager;

use one::event;
use one::object::{UID, ID};
use one::table::{Self, Table};
use one::transfer;
use one::tx_context::{Self, TxContext};
use std::option::{Self, Option};
use std::string::{Self, String};
use std::vector;

/* ===================== CONSTANTS ===================== */

const CREATED: u8 = 0;
const IN_GAME: u8 = 1;
const ENDED: u8 = 2;

const FIGHTER_ALIVE: u8 = 0;
const FIGHTER_DEAD: u8 = 1;

const E_NOT_FIGHTER: u64 = 0;
const E_INVALID_STATE: u64 = 2;
const E_ALREADY_ENDED: u64 = 3;
const E_NOT_IN_GAME: u64 = 4;
const E_NAME_TOO_LONG: u64 = 5;

/* ===================== EVENTS ===================== */

public struct MatchCreated has copy, drop {
    match_id: ID,
    fighter: address,
    name: String,
}

public struct MatchStarted has copy, drop {
    match_id: ID,
    fighter: address,
}

public struct MatchEnded has copy, drop {
    match_id: ID,
    fighter: address,
    is_win: bool,
}

/* ===================== CAPS ===================== */

public struct AdminCap has key, store {
    id: UID,
}

/* ===================== VIEW STRUCT ===================== */
/* dùng cho VIEW + UI */

public struct MatchView has copy, drop, store {
    match_id: ID,
    name: String,
    fighter: address,
    status: u8,
    total_pool: u64,
}

/* ===================== REGISTRY ===================== */

public struct Registry has key, store {
    id: UID,
    created_matches: vector<MatchView>,
}

/* ===================== MATCH (OBJECT) ===================== */

public struct Match has key, store {
    id: UID,
    name: String,
    fighter: address,
    fighter_state: u8,
    status: u8,
    result: Option<bool>,
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
        created_matches: vector::empty<MatchView>(),
    };

    transfer::public_share_object(registry);
}

/* ===================== MATCH CORE FUNCTION ===================== */

public fun create_match(
    registry: &mut Registry,
    name_bytes: vector<u8>,
    ctx: &mut TxContext,
) {
    assert!(vector::length(&name_bytes) <= 20, E_NAME_TOO_LONG);

    let fighter = tx_context::sender(ctx);
    let name = string::utf8(name_bytes);

    let m = Match {
        id: object::new(ctx),
        name,
        fighter,
        fighter_state: FIGHTER_ALIVE,
        status: CREATED,
        result: option::none(),
        total_pool: 0,
        total_bet_viewers: 0,
        win_bets_total: 0,
        lose_bets_total: 0,
        win_bets: table::new(ctx),
        lose_bets: table::new(ctx),
    };

    let match_id = object::id(&m);

    vector::push_back(
        &mut registry.created_matches,
        MatchView {
            match_id,
            name: m.name,
            fighter,
            status: CREATED,
            total_pool: 0,
        },
    );

    event::emit(MatchCreated {
        match_id,
        fighter,
        name: m.name,
    });

    transfer::public_share_object(m);
}

public fun start_match(
    registry: &mut Registry,
    m: &mut Match,
    ctx: &mut TxContext,
) {
    assert!(m.status == CREATED, E_INVALID_STATE);
    assert!(tx_context::sender(ctx) == m.fighter, E_NOT_FIGHTER);

    m.status = IN_GAME;

    let id = object::id(m);
    let (found, i) = vector::index_of(
        &registry.created_matches,
        &MatchView {
            match_id: id,
            name: m.name,
            fighter: m.fighter,
            status: CREATED,
            total_pool: m.total_pool,
        },
    );
    // assert!(found, E_INVALID_STATE);

    let view = vector::borrow_mut(&mut registry.created_matches, i);
    view.status = IN_GAME;

    event::emit(MatchStarted {
        match_id: id,
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
    m.fighter_state = if (is_win) { FIGHTER_ALIVE } else { FIGHTER_DEAD };

    event::emit(MatchEnded {
        match_id: object::id(m),
        fighter: m.fighter,
        is_win,
    });
}

/* ===================== VIEWS ===================== */

public fun get_created_matches(registry: &Registry): vector<MatchView> {
    registry.created_matches
}

public fun match_state(
    m: &Match,
): (String, address, u8, u8, Option<bool>, u64, u64) {
    (
        m.name,
        m.fighter,
        m.fighter_state,
        m.status,
        m.result,
        m.total_pool,
        m.total_bet_viewers,
    )
}

/* ===================== TESTS ===================== */

#[test_only]
use one::object;

#[test_only]
fun create_test_registry(ctx: &mut TxContext): Registry {
    Registry {
        id: object::new(ctx),
        created_matches: vector::empty<MatchView>(),
    }
}

#[test_only]
fun create_test_match(fighter: address, ctx: &mut TxContext): Match {
    Match {
        id: object::new(ctx),
        name: string::utf8(b"TestMatch"),
        fighter,
        fighter_state: FIGHTER_ALIVE,
        status: CREATED,
        result: option::none(),
        total_pool: 0,
        total_bet_viewers: 0,
        win_bets_total: 0,
        lose_bets_total: 0,
        win_bets: table::new(ctx),
        lose_bets: table::new(ctx),
    }
}

#[test_only]
fun create_test_admin(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

/* ---------- create_match ---------- */

#[test]
fun test_create_match_success() {
    let mut ctx = tx_context::dummy();
    let mut registry = create_test_registry(&mut ctx);

    create_match(&mut registry, b"MyMatch", &mut ctx);

    let views = get_created_matches(&registry);
    assert!(vector::length(&views) == 1, 1);

    let v = vector::borrow(&views, 0);
    assert!(v.status == CREATED, 2);
    transfer::transfer(registry, @0x0);
}



/* ---------- start_match ---------- */

#[test]
fun test_start_match_success() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let mut registry = create_test_registry(&mut ctx);
    create_match(&mut registry, b"TestMatch", &mut ctx);

    let mut m = create_test_match(fighter, &mut ctx);
    start_match(&mut registry, &mut m, &mut ctx);

    assert!(m.status == IN_GAME, 1);

    let views = get_created_matches(&registry);
    let v = vector::borrow(&views, 0);
    assert!(v.status == IN_GAME, 2);

    transfer::transfer(m, @0x0);
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

/* ---------- view ---------- */

#[test]
fun test_match_state_view() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let m = create_test_match(fighter, &mut ctx);

    let (name, f, fighter_state, status, result, pool, viewers) =
        match_state(&m);

    assert!(name == string::utf8(b"TestMatch"), 1);
    assert!(f == fighter, 2);
    assert!(fighter_state == FIGHTER_ALIVE, 3);
    assert!(status == CREATED, 4);
    assert!(option::is_none(&result), 5);
    assert!(pool == 0, 6);
    assert!(viewers == 0, 7);

    transfer::public_share_object(m);
}
