/* module hunger_battle_arena::bet_engine;

use hunger_battle_arena::match_manager::Match;
use one::coin::{Self, Coin};
use one::event;
use one::object::{Self, ID, UID};
use one::oct::OCT;
use one::table::{Self, Table};
use one::transfer;
use one::tx_context::{Self, TxContext};
use std::option::{Self, Option};

const CREATED: u8 = 0;
const IN_GAME: u8 = 1;
const ENDED: u8 = 2;

const SIDE_WIN: u8 = 0;
const SIDE_LOSE: u8 = 1;

const E_MATCH_MISMATCH: u64 = 0;
const E_BETS_LOCKED: u64 = 1;
const E_INVALID_SIDE: u64 = 2;
const E_ALREADY_BET: u64 = 3;
const E_ZERO_BET: u64 = 4;
const E_MATCH_NOT_ENDED: u64 = 5;
const E_NOT_WINNER: u64 = 6;
const E_ALREADY_CLAIMED: u64 = 7;
const E_FIGHTER_ONLY: u64 = 8;
const E_FIGHTER_LOST: u64 = 9;
const E_FIGHTER_CANNOT_BET: u64 = 10;
const E_NO_POOL: u64 = 11;

public struct BetVaultCreated has copy, drop {
    match_id: ID,
    fighter: address,
}

public struct BetPlaced has copy, drop {
    match_id: ID,
    bettor: address,
    side: u8,
    amount: u64,
}

public struct ViewerRewardClaimed has copy, drop {
    match_id: ID,
    viewer: address,
    amount: u64,
}

public struct FighterRewardClaimed has copy, drop {
    match_id: ID,
    fighter: address,
    amount: u64,
}

public struct BetVault has key {
    id: UID,
    match_id: ID,
    pool: Option<Coin<OCT>>,
    claimed: Table<address, bool>,
    fighter_claimed: bool,
}

public entry fun create_bet_vault(m: &Match, ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);
    assert!(sender == m.fighter, E_FIGHTER_ONLY);

    let vault = BetVault {
        id: object::new(ctx),
        match_id: object::id(m),
        pool: option::none(),
        claimed: table::new(ctx),
        fighter_claimed: false,
    };

    event::emit(BetVaultCreated {
        match_id: object::id(m),
        fighter: sender,
    });

    transfer::public_share_object(vault);
}

public entry fun place_bet(
    vault: &mut BetVault,
    m: &mut Match,
    side: u8,
    bet: Coin<OCT>,
    ctx: &mut TxContext,
) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(m.status == CREATED, E_BETS_LOCKED);

    let sender = tx_context::sender(ctx);
    assert!(sender != m.fighter, E_FIGHTER_CANNOT_BET);
    assert!(
        !table::contains(&m.win_bets, sender) && !table::contains(&m.lose_bets, sender),
        E_ALREADY_BET
    );

    let amount = coin::value(&bet);
    assert!(amount > 0, E_ZERO_BET);

    if (side == SIDE_WIN) {
        table::add(&mut m.win_bets, sender, amount);
        m.win_bets_total = m.win_bets_total + amount;
    } else if (side == SIDE_LOSE) {
        table::add(&mut m.lose_bets, sender, amount);
        m.lose_bets_total = m.lose_bets_total + amount;
    } else {
        abort E_INVALID_SIDE
    };

    m.total_pool = m.total_pool + amount;
    m.total_bet_viewers = m.total_bet_viewers + 1;

    if (option::is_none(&vault.pool)) {
        vault.pool = option::some(bet);
    } else {
        let pool_ref = option::borrow_mut(&mut vault.pool);
        coin::merge(pool_ref, bet);
    };

    event::emit(BetPlaced {
        match_id: object::id(m),
        bettor: sender,
        side,
        amount,
    });
}

public entry fun claim_viewer_reward(vault: &mut BetVault, m: &mut Match, ctx: &mut TxContext) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(m.status == ENDED && option::is_some(&m.result), E_MATCH_NOT_ENDED);

    let sender = tx_context::sender(ctx);
    assert!(!table::contains(&vault.claimed, sender), E_ALREADY_CLAIMED);
    assert!(option::is_some(&vault.pool), E_NO_POOL);

    let is_win = *option::borrow(&m.result);
    let mut reward = 0;

    if (is_win) {
        assert!(table::contains(&m.win_bets, sender), E_NOT_WINNER);
        let bet_amount = *table::borrow(&m.win_bets, sender);
        let fighter_reward = fighter_reward_amount(m.total_pool);
        let viewers_pool = m.total_pool - fighter_reward;
        reward = (bet_amount * viewers_pool) / m.win_bets_total;
    } else {
        assert!(table::contains(&m.lose_bets, sender), E_NOT_WINNER);
        let bet_amount = *table::borrow(&m.lose_bets, sender);
        reward = (bet_amount * m.total_pool) / m.lose_bets_total;
    };

    table::add(&mut vault.claimed, sender, true);

    if (reward > 0) {
        let pool_ref = option::borrow_mut(&mut vault.pool);
        let payout = coin::split(pool_ref, reward, ctx);
        transfer::public_transfer(payout, sender);
    };

    event::emit(ViewerRewardClaimed {
        match_id: object::id(m),
        viewer: sender,
        amount: reward,
    });
}

public entry fun claim_fighter_reward(vault: &mut BetVault, m: &mut Match, ctx: &mut TxContext) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(m.status == ENDED && option::is_some(&m.result), E_MATCH_NOT_ENDED);

    let sender = tx_context::sender(ctx);
    assert!(sender == m.fighter, E_FIGHTER_ONLY);
    assert!(!vault.fighter_claimed, E_ALREADY_CLAIMED);
    assert!(option::is_some(&vault.pool), E_NO_POOL);

    let is_win = *option::borrow(&m.result);
    assert!(is_win, E_FIGHTER_LOST);

    let reward = fighter_reward_amount(m.total_pool);
    vault.fighter_claimed = true;

    if (reward > 0) {
        let pool_ref = option::borrow_mut(&mut vault.pool);
        let payout = coin::split(pool_ref, reward, ctx);
        transfer::public_transfer(payout, sender);
    };

    event::emit(FighterRewardClaimed {
        match_id: object::id(m),
        fighter: sender,
        amount: reward,
    });
}

public fun fighter_reward_amount(total_pool: u64): u64 {
    total_pool / 10
}

#[test_only]
use hunger_battle_arena::match_manager;
#[test_only]
use one::test_scenario::{Self as ts};

#[test]
fun test_bet_and_claim_flow() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(100, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let admin = match_manager::create_test_admin(scenario.ctx());
    match_manager::start_match(&mut m, scenario.ctx());
    match_manager::end_match(&admin, &mut m, true, scenario.ctx());
    transfer::public_share_object(m);
    transfer::transfer(admin, fighter);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_viewer_reward(&mut v, &mut m, scenario.ctx());
    let pool_ref = option::borrow(&v.pool);
    assert!(coin::value(pool_ref) == 10, 1);
    assert!(table::contains(&v.claimed, viewer), 2);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_fighter_reward(&mut v, &mut m, scenario.ctx());
    let pool_ref = option::borrow(&v.pool);
    assert!(coin::value(pool_ref) == 0, 3);
    assert!(v.fighter_claimed, 4);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_ALREADY_BET)]
fun test_double_bet_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet1 = coin::mint_for_testing<OCT>(10, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet1, scenario.ctx());
    let bet2 = coin::mint_for_testing<OCT>(5, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet2, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_INVALID_SIDE)]
fun test_invalid_side_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(10, scenario.ctx());
    place_bet(&mut v, &mut m, 2, bet, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_MATCH_NOT_ENDED)]
fun test_claim_before_end_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(10, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_viewer_reward(&mut v, &mut m, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_FIGHTER_CANNOT_BET)]
fun test_fighter_bet_rejected() {
    let fighter = @0xA;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(10, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_BETS_LOCKED)]
fun test_bet_when_in_game_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    match_manager::start_match(&mut m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(10, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_ALREADY_CLAIMED)]
fun test_double_claim_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(10, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let admin = match_manager::create_test_admin(scenario.ctx());
    match_manager::start_match(&mut m, scenario.ctx());
    match_manager::end_match(&admin, &mut m, true, scenario.ctx());
    transfer::public_share_object(m);
    transfer::transfer(admin, fighter);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_viewer_reward(&mut v, &mut m, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_viewer_reward(&mut v, &mut m, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_FIGHTER_LOST)]
fun test_claim_fighter_when_lose_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut m = match_manager::create_test_match(fighter, scenario.ctx());
    create_bet_vault(&m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(10, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let admin = match_manager::create_test_admin(scenario.ctx());
    match_manager::start_match(&mut m, scenario.ctx());
    match_manager::end_match(&admin, &mut m, false, scenario.ctx());
    transfer::public_share_object(m);
    transfer::transfer(admin, fighter);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_fighter_reward(&mut v, &mut m, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}
 */
