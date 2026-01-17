module hunger_battle_arena::bet_engine;

use hunger_battle_arena::match_manager::{Self as match_manager, Match, Registry};
use one::coin::{Self, Coin};
use one::event;
use one::oct::OCT;
use one::table::{Self, Table};

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

public struct UserBetView has copy, drop {
    side: u8,
    amount: u64,
}

#[allow(lint(coin_field))]
public struct BetVault has key, store {
    id: UID,
    match_id: ID,
    pool: Coin<OCT>,
    claimed: Table<address, bool>,
    fighter_claimed: bool,
}

#[allow(lint(share_owned))]
public fun create_match_with_bet_vault(
    registry: &mut Registry,
    name_bytes: vector<u8>,
    ctx: &mut TxContext,
) {
    let mut m = match_manager::create_match_internal(registry, name_bytes, ctx);
    create_bet_vault(&mut m, ctx);
    transfer::public_share_object(m);
}

public(package) fun create_bet_vault(m: &mut Match, ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);
    assert!(sender == match_manager::fighter(m), E_FIGHTER_ONLY);

    let vault = BetVault {
        id: object::new(ctx),
        match_id: object::id(m),
        pool: coin::zero(ctx),
        claimed: table::new(ctx),
        fighter_claimed: false,
    };

    match_manager::set_vault_id(m, object::id(&vault));

    event::emit(BetVaultCreated {
        match_id: object::id(m),
        fighter: sender,
    });

    transfer::public_share_object(vault);
}

public fun place_bet(
    vault: &mut BetVault,
    m: &mut Match,
    side: u8,
    bet: Coin<OCT>,
    ctx: &mut TxContext,
) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_created(m), E_BETS_LOCKED);

    let sender = tx_context::sender(ctx);
    assert!(sender != match_manager::fighter(m), E_FIGHTER_CANNOT_BET);
    assert!(
        !match_manager::has_win_bet(m, sender) && !match_manager::has_lose_bet(m, sender),
        E_ALREADY_BET
    );

    let amount = coin::value(&bet);
    assert!(amount > 0, E_ZERO_BET);

    if (side == SIDE_WIN) {
        match_manager::add_win_bet(m, sender, amount);
    } else if (side == SIDE_LOSE) {
        match_manager::add_lose_bet(m, sender, amount);
    } else {
        abort E_INVALID_SIDE
    };

    coin::join(&mut vault.pool, bet);

    event::emit(BetPlaced {
        match_id: object::id(m),
        bettor: sender,
        side,
        amount,
    });
}

#[allow(lint(self_transfer))]
public fun claim_viewer_reward(vault: &mut BetVault, m: &mut Match, ctx: &mut TxContext) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_ended(m), E_MATCH_NOT_ENDED);

    let sender = tx_context::sender(ctx);
    assert!(!table::contains(&vault.claimed, sender), E_ALREADY_CLAIMED);

    let is_win = match_manager::result_value(m);
    let reward = if (is_win) {
        assert!(match_manager::has_win_bet(m, sender), E_NOT_WINNER);
        let bet_amount = match_manager::win_bet_amount(m, sender);
        let fighter_reward = fighter_reward_amount(match_manager::total_pool(m));
        let viewers_pool = match_manager::total_pool(m) - fighter_reward;
        (bet_amount * viewers_pool) / match_manager::win_bets_total(m)
    } else {
        assert!(match_manager::has_lose_bet(m, sender), E_NOT_WINNER);
        let bet_amount = match_manager::lose_bet_amount(m, sender);
        (bet_amount * match_manager::total_pool(m)) / match_manager::lose_bets_total(m)
    };

    table::add(&mut vault.claimed, sender, true);

    if (reward > 0) {
        let payout = coin::split(&mut vault.pool, reward, ctx);
        transfer::public_transfer(payout, sender);
    };

    event::emit(ViewerRewardClaimed {
        match_id: object::id(m),
        viewer: sender,
        amount: reward,
    });
}

#[allow(lint(self_transfer))]
public fun claim_fighter_reward(vault: &mut BetVault, m: &mut Match, ctx: &mut TxContext) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_ended(m), E_MATCH_NOT_ENDED);

    let sender = tx_context::sender(ctx);
    assert!(sender == match_manager::fighter(m), E_FIGHTER_ONLY);
    assert!(!vault.fighter_claimed, E_ALREADY_CLAIMED);

    let is_win = match_manager::result_value(m);
    assert!(is_win, E_FIGHTER_LOST);

    let reward = fighter_reward_amount(match_manager::total_pool(m));
    vault.fighter_claimed = true;

    if (reward > 0) {
        let payout = coin::split(&mut vault.pool, reward, ctx);
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

public fun user_bet_view(m: &Match, viewer: address): option::Option<UserBetView> {
    if (match_manager::has_win_bet(m, viewer)) {
        option::some(UserBetView {
            side: SIDE_WIN,
            amount: match_manager::win_bet_amount(m, viewer),
        })
    } else if (match_manager::has_lose_bet(m, viewer)) {
        option::some(UserBetView {
            side: SIDE_LOSE,
            amount: match_manager::lose_bet_amount(m, viewer),
        })
    } else {
        option::none()
    }
}

public fun is_claimed(vault: &BetVault, viewer: address): bool {
    table::contains(&vault.claimed, viewer)
}

public fun is_fighter_claimed(vault: &BetVault): bool {
    vault.fighter_claimed
}

public fun pool_balance(vault: &BetVault): u64 {
    coin::value(&vault.pool)
}

public fun preview_reward(m: &Match, viewer: address): u64 {
    if (!match_manager::is_ended(m)) {
        0
    } else if (match_manager::result_value(m)) {
        if (!match_manager::has_win_bet(m, viewer)) {
            0
        } else {
            let bet_amount = match_manager::win_bet_amount(m, viewer);
            let fighter_reward = fighter_reward_amount(match_manager::total_pool(m));
            let viewers_pool = match_manager::total_pool(m) - fighter_reward;
            (bet_amount * viewers_pool) / match_manager::win_bets_total(m)
        }
    } else {
        if (!match_manager::has_lose_bet(m, viewer)) {
            0
        } else {
            let bet_amount = match_manager::lose_bet_amount(m, viewer);
            (bet_amount * match_manager::total_pool(m)) / match_manager::lose_bets_total(m)
        }
    }
}

#[test_only]
use one::test_scenario::{Self as ts};

#[test_only]
fun new_test_vault(m: &Match, ctx: &mut TxContext): BetVault {
    BetVault {
        id: object::new(ctx),
        match_id: object::id(m),
        pool: coin::zero(ctx),
        claimed: table::new(ctx),
        fighter_claimed: false,
    }
}

#[test]
fun test_place_bet_updates_totals() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;
    let viewer = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(50, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet, &mut ctx);

    assert!(match_manager::win_bets_total(&m) == 50, 1);
    assert!(match_manager::total_pool(&m) == 50, 2);
    assert!(coin::value(&v.pool) == 50, 3);
    assert!(!is_claimed(&v, viewer), 4);
    assert!(pool_balance(&v) == 50, 5);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
fun test_user_bet_view() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;
    let viewer = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(25, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, &mut ctx);

    let view_opt = user_bet_view(&m, viewer);
    assert!(option::is_some(&view_opt), 1);
    let view = option::borrow(&view_opt);
    assert!(view.side == SIDE_LOSE, 2);
    assert!(view.amount == 25, 3);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
fun test_preview_reward_win() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;
    let viewer = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(100, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet, &mut ctx);

    let admin = match_manager::create_test_admin(&mut ctx);
    match_manager::set_status_in_game(&mut m);
    match_manager::end_match(&admin, &mut m, true);
    match_manager::destroy_test_admin(admin);

    assert!(preview_reward(&m, viewer) == 90, 1);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
fun test_preview_reward_lose() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;
    let viewer = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(80, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, &mut ctx);

    let admin = match_manager::create_test_admin(&mut ctx);
    match_manager::set_status_in_game(&mut m);
    match_manager::end_match(&admin, &mut m, false);
    match_manager::destroy_test_admin(admin);

    assert!(preview_reward(&m, viewer) == 80, 1);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
#[expected_failure(abort_code = E_ALREADY_BET)]
fun test_double_bet_rejected() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet1 = coin::mint_for_testing<OCT>(10, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet1, &mut ctx);
    let bet2 = coin::mint_for_testing<OCT>(5, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet2, &mut ctx);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
#[expected_failure(abort_code = E_INVALID_SIDE)]
fun test_invalid_side_rejected() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(10, &mut ctx);
    place_bet(&mut v, &mut m, 2, bet, &mut ctx);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
#[expected_failure(abort_code = E_MATCH_NOT_ENDED)]
fun test_claim_before_end_rejected() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(10, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet, &mut ctx);

    claim_viewer_reward(&mut v, &mut m, &mut ctx);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
#[expected_failure(abort_code = E_FIGHTER_CANNOT_BET)]
fun test_fighter_bet_rejected() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(10, &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet, &mut ctx);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
fun test_bet_and_claim_flow() {
    let fighter = @0xA;
    let viewer_win = @0xB;
    let viewer_lose = @0xC;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    create_match_with_bet_vault(&mut registry, b"Room", scenario.ctx());
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(100, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_lose);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(50, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let admin = match_manager::create_test_admin(scenario.ctx());
    match_manager::start_match(&mut m, scenario.ctx());
    match_manager::end_match(&admin, &mut m, true);
    transfer::public_share_object(m);
    match_manager::destroy_test_admin(admin);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    assert!(preview_reward(&m, viewer_win) == 135, 1);
    claim_viewer_reward(&mut v, &mut m, scenario.ctx());
    assert!(coin::value(&v.pool) == 15, 2);
    assert!(table::contains(&v.claimed, viewer_win), 3);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_lose);
    let m: Match = scenario.take_shared();
    let v: BetVault = scenario.take_shared();
    assert!(preview_reward(&m, viewer_lose) == 0, 4);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_fighter_reward(&mut v, &mut m, scenario.ctx());
    assert!(coin::value(&v.pool) == 0, 5);
    assert!(v.fighter_claimed, 6);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    ts::end(scenario);
}

#[test]
fun test_create_match_with_bet_vault() {
    let fighter = @0xA;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    create_match_with_bet_vault(&mut registry, b"Room", scenario.ctx());

    let ids = match_manager::get_match_ids(&registry);
    assert!(vector::length(&ids) == 1, 1);
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(fighter);
    let m: Match = scenario.take_shared();
    let v: BetVault = scenario.take_shared();
    let vault_id = match_manager::match_vault_id(&m);
    assert!(option::is_some(&vault_id), 2);
    assert!(v.match_id == object::id(&m), 3);

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
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    create_match_with_bet_vault(&mut registry, b"Room", scenario.ctx());
    transfer::public_transfer(registry, @0x0);

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
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    create_match_with_bet_vault(&mut registry, b"Room", scenario.ctx());
    transfer::public_transfer(registry, @0x0);

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
    match_manager::end_match(&admin, &mut m, true);
    transfer::public_share_object(m);
    match_manager::destroy_test_admin(admin);

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
#[expected_failure(abort_code = E_NOT_WINNER)]
fun test_loser_claim_rejected() {
    let fighter = @0xA;
    let viewer_win = @0xB;
    let viewer_lose = @0xC;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    create_match_with_bet_vault(&mut registry, b"Room", scenario.ctx());
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(100, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_lose);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(50, scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let admin = match_manager::create_test_admin(scenario.ctx());
    match_manager::start_match(&mut m, scenario.ctx());
    match_manager::end_match(&admin, &mut m, true);
    transfer::public_share_object(m);
    match_manager::destroy_test_admin(admin);

    scenario.next_tx(viewer_lose);
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
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    create_match_with_bet_vault(&mut registry, b"Room", scenario.ctx());
    transfer::public_transfer(registry, @0x0);

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
    match_manager::end_match(&admin, &mut m, false);
    transfer::public_share_object(m);
    match_manager::destroy_test_admin(admin);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault = scenario.take_shared();
    claim_fighter_reward(&mut v, &mut m, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}
