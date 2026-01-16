module hunger_battle_arena::match_manager;

friend hunger_battle_arena::bet_engine;

use one::event;
use one::object::{Self, UID, ID};
use one::table::{Self, Table};
use one::transfer;
use one::tx_context::{Self, TxContext};
use std::option::{Self, Option};
use std::string::{Self, String};
use std::vector;

const CREATED: u8 = 0;
const IN_GAME: u8 = 1;
const ENDED: u8 = 2;

const FIGHTER_ALIVE: u8 = 0;
const FIGHTER_DEAD: u8 = 1;
const FIGHTER_INACTIVE: u8 = 2;

const E_NOT_FIGHTER: u64 = 0;
const E_NOT_ADMIN: u64 = 1;
const E_INVALID_STATE: u64 = 2;
const E_ALREADY_ENDED: u64 = 3;
const E_NOT_IN_GAME: u64 = 4;
const E_NAME_TOO_LONG: u64 = 5;

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

public struct AdminAdded has copy, drop {
    new_admin: address,
}

public struct AdminCap has key {
    id: UID,
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        AdminCap { id: object::new(ctx) },
        tx_context::sender(ctx),
    );
}

public entry fun add_admin(_: &AdminCap, new_admin: address, ctx: &mut TxContext) {
    let new_cap = AdminCap { id: object::new(ctx) };
    transfer::transfer(new_cap, new_admin);
    event::emit(AdminAdded { new_admin });
}

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

public entry fun create_match(name_bytes: vector<u8>, ctx: &mut TxContext) {
    let fighter = tx_context::sender(ctx);
    assert!(vector::length(&name_bytes) <= 20, E_NAME_TOO_LONG);

    let match_name = string::utf8(name_bytes);

    let m = Match {
        id: object::new(ctx),
        name: match_name,
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

    event::emit(MatchCreated {
        match_id,
        fighter,
        name: match_name,
    });

    transfer::public_share_object(m);
}

public fun start_match(m: &mut Match, ctx: &mut TxContext) {
    assert!(m.status == CREATED, E_INVALID_STATE);
    assert!(tx_context::sender(ctx) == m.fighter, E_NOT_FIGHTER);

    m.status = IN_GAME;

    event::emit(MatchStarted {
        match_id: object::id(m),
        fighter: m.fighter,
    });
}

public fun end_match(_: &AdminCap, m: &mut Match, is_win: bool, _ctx: &mut TxContext) {
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


public fun match_state(m: &Match): (String, address, u8, u8, Option<bool>, u64, u64) {
    (m.name, m.fighter, m.fighter_state, m.status, m.result, m.total_pool, m.total_bet_viewers)
}

public fun betting_info(m: &Match): (u64, u64, u64, u64, u64) {
    (
        m.total_pool,
        m.win_bets_total,
        m.lose_bets_total,
        table::length(&m.win_bets),
        table::length(&m.lose_bets),
    )
}
#[test_only]
public fun create_test_admin(ctx: &mut TxContext): AdminCap {
    AdminCap { id: object::new(ctx) }
}

#[test_only]
public fun create_test_match(fighter: address, ctx: &mut TxContext): Match {
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

    #[test]
    fun test_create_match_success() {
        let mut ctx = tx_context::dummy();

        let sender = tx_context::sender(&ctx);
        create_match(b"MyMatch", &mut ctx);

        let m = create_test_match(sender, &mut ctx);

        let (name, fighter, fighter_state, status, result, pool, viewers) =
            match_state(&m);

        assert!(name == string::utf8(b"TestMatch"), 1);
        assert!(fighter == sender, 2);
        assert!(fighter_state == FIGHTER_ALIVE, 3);
        assert!(status == CREATED, 4);
        assert!(option::is_none(&result), 5);
        assert!(pool == 0, 6);
        assert!(viewers == 0, 7);

        transfer::transfer(m, @0x0);
    }

#[test]
#[expected_failure] 
fun test_create_match_name_too_long() {
    let mut ctx = tx_context::dummy();

    let long_name = b"123456789012345678901";

    create_match(long_name, &mut ctx);
}

#[test]
fun test_start_match_success() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let mut m = create_test_match(fighter, &mut ctx);

    start_match(&mut m, &mut ctx);

    assert!(m.status == IN_GAME, 1);

    transfer::transfer(m, @0x0);
}

#[test]
#[expected_failure(abort_code = E_NOT_FIGHTER)]
fun test_start_match_wrong_sender() {
    let mut ctx = tx_context::dummy();
    let fighter = @0x1;

    let mut m = create_test_match(fighter, &mut ctx);
    start_match(&mut m, &mut ctx);

    transfer::transfer(m, @0x0);
}

#[test]
fun test_end_match_win() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let admin = create_test_admin(&mut ctx);
    let mut m = create_test_match(fighter, &mut ctx);

    start_match(&mut m, &mut ctx);
    end_match(&admin, &mut m, true, &mut ctx);

    assert!(m.status == ENDED, 1);
    assert!(option::contains(&m.result, &true), 1);
    assert!(m.fighter_state == FIGHTER_ALIVE, 3);

    transfer::transfer(m, @0x0);
    transfer::transfer(admin, @0x0);
}

#[test]
fun test_end_match_lose() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let admin = create_test_admin(&mut ctx);
    let mut m = create_test_match(fighter, &mut ctx);

    start_match(&mut m, &mut ctx);
    end_match(&admin, &mut m, false, &mut ctx);

    assert!(m.status == ENDED, 1);
    assert!(option::contains(&m.result, &false), 1);
    assert!(m.fighter_state == FIGHTER_DEAD, 3);

    transfer::transfer(m, @0x0);
    transfer::transfer(admin, @0x0);
}

#[test]
fun test_match_state_view() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let mut m = create_test_match(fighter, &mut ctx);

    let (name, f, fighter_state, status, result, pool, viewers) =
        match_state(&m);

    assert!(name == string::utf8(b"TestMatch"), 1);
    assert!(f == fighter, 2);
    assert!(fighter_state == FIGHTER_ALIVE, 3);
    assert!(status == CREATED, 4);
    assert!(option::is_none(&result), 5);
    assert!(pool == 0, 6);
    assert!(viewers == 0, 7);

    transfer::transfer(m, @0x0);
}

#[test]
fun test_betting_info_view() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let m = create_test_match(fighter, &mut ctx);

    let (pool, win_total, lose_total, win_count, lose_count) =
        betting_info(&m);

    assert!(pool == 0, 1);
    assert!(win_total == 0, 2);
    assert!(lose_total == 0, 3);
    assert!(win_count == 0, 4);
    assert!(lose_count == 0, 5);

    transfer::transfer(m, @0x0);
}

#[test]
fun test_add_admin() {
    let mut ctx = tx_context::dummy();

    let admin = create_test_admin(&mut ctx);
    let new_admin = @0x2;

    add_admin(&admin, new_admin, &mut ctx);

    transfer::transfer(admin, @0x0);
}
