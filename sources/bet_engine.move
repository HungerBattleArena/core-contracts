module hunger_battle_arena::bet_engine;

use hunger_battle_arena::match_manager::{Self as match_manager, AdminCap, Match, Registry};
use one::coin::{Self, Coin};
use one::event;
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
const E_MATCH_NOT_CANCELLED: u64 = 11;
const E_NOT_BETTOR: u64 = 12;
const E_ZERO_STAKE: u64 = 13;
const E_INVALID_STAKE_AMOUNT: u64 = 14;
const E_STAKE_NOT_REFUNDABLE: u64 = 15;
const E_NO_SLASHED_STAKE: u64 = 16;
const E_NOT_TREASURY_ADMIN: u64 = 17;
const E_BET_TOO_LARGE: u64 = 18;

const COIN_DECIMALS_FACTOR: u64 = 1000000000;
const FEE_BPS: u64 = 200;
const FIGHTER_SHARE_BPS: u64 = 2000;
const BPS_DENOM: u64 = 10000;
const MIN_BET: u64 = 1 * COIN_DECIMALS_FACTOR;
const MAX_BET: u64 = 1000 * COIN_DECIMALS_FACTOR;

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

public struct FighterStakeRefunded has copy, drop {
    match_id: ID,
    fighter: address,
    amount: u64,
}

public struct SlashedStakeClaimed has copy, drop {
    match_id: ID,
    amount: u64,
}

public struct UserBetView has copy, drop {
    side: u8,
    amount: u64,
}

#[allow(lint(coin_field))]
public struct BetVault<phantom T> has key, store {
    id: UID,
    match_id: ID,
    viewer_pool: Coin<T>,
    fighter_stake: Coin<T>,
    claimed: Table<address, bool>,
    fighter_claimed: bool,
}

public struct Treasury has key, store {
    id: UID,
    admin: address,
}

fun init(ctx: &mut TxContext) {
    let treasury = Treasury {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
    };
    transfer::public_share_object(treasury);
}

#[allow(lint(share_owned))]
public fun create_match_with_bet_vault<T>(
    registry: &mut Registry,
    name_bytes: vector<u8>,
    fighter_stake: Coin<T>,
    ctx: &mut TxContext,
) {
    let stake_amount = coin::value(&fighter_stake);
    assert!(stake_amount > 0, E_ZERO_STAKE);
    assert!(stake_amount == match_manager::default_fighter_stake(), E_INVALID_STAKE_AMOUNT);

    let mut m = match_manager::create_match_internal(registry, name_bytes, ctx);
    create_bet_vault<T>(&mut m, fighter_stake, ctx);
    transfer::public_share_object(m);
}

public(package) fun create_bet_vault<T>(m: &mut Match, fighter_stake: Coin<T>, ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);
    assert!(sender == match_manager::fighter(m), E_FIGHTER_ONLY);

    let vault = BetVault<T> {
        id: object::new(ctx),
        match_id: object::id(m),
        viewer_pool: coin::zero<T>(ctx),
        fighter_stake,
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

public fun place_bet<T>(
    vault: &mut BetVault<T>,
    m: &mut Match,
    side: u8,
    bet: Coin<T>,
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
    assert!(amount >= MIN_BET, E_ZERO_BET);
    assert!(amount <= MAX_BET, E_BET_TOO_LARGE);

    if (side == SIDE_WIN) {
        match_manager::add_win_bet(m, sender, amount);
    } else if (side == SIDE_LOSE) {
        match_manager::add_lose_bet(m, sender, amount);
    } else {
        abort E_INVALID_SIDE
    };

    coin::join(&mut vault.viewer_pool, bet);

    event::emit(BetPlaced {
        match_id: object::id(m),
        bettor: sender,
        side,
        amount,
    });
}

#[allow(lint(self_transfer))]
public fun claim_viewer_reward<T>(
    treasury: &Treasury,
    vault: &mut BetVault<T>,
    m: &mut Match,
    ctx: &mut TxContext,
) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_ended(m), E_MATCH_NOT_ENDED);

    let sender = tx_context::sender(ctx);
    assert!(!table::contains(&vault.claimed, sender), E_ALREADY_CLAIMED);

    let is_win = match_manager::result_value(m);
    let reward = if (is_win) {
        assert!(match_manager::has_win_bet(m, sender), E_NOT_WINNER);
        let bet_amount = match_manager::win_bet_amount(m, sender);
        let viewers_reward_pool = match_manager::lose_bets_total(m) - fighter_reward_amount(m);
        let reward_u128 =
            (bet_amount as u128) * (viewers_reward_pool as u128)
                / (match_manager::win_bets_total(m) as u128);
        reward_u128 as u64
    } else {
        assert!(match_manager::has_lose_bet(m, sender), E_NOT_WINNER);
        let bet_amount = match_manager::lose_bet_amount(m, sender);
        let reward_u128 =
            (bet_amount as u128) * (match_manager::win_bets_total(m) as u128)
                / (match_manager::lose_bets_total(m) as u128);
        reward_u128 as u64
    };

    let bet_amount = winning_bet_amount(m, sender);
    let fee = fee_amount(reward);
    let payout_amount = bet_amount + reward - fee;

    table::add(&mut vault.claimed, sender, true);

    if (payout_amount > 0) {
        let payout = coin::split(&mut vault.viewer_pool, payout_amount, ctx);
        transfer::public_transfer(payout, sender);
    };

    if (fee > 0) {
        let fee_coin = coin::split(&mut vault.viewer_pool, fee, ctx);
        transfer::public_transfer(fee_coin, treasury.admin);
    };

    event::emit(ViewerRewardClaimed {
        match_id: object::id(m),
        viewer: sender,
        amount: payout_amount,
    });
}

#[allow(lint(self_transfer))]
public fun claim_fighter_reward<T>(
    treasury: &Treasury,
    vault: &mut BetVault<T>,
    m: &mut Match,
    ctx: &mut TxContext,
) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_ended(m), E_MATCH_NOT_ENDED);

    let sender = tx_context::sender(ctx);
    assert!(sender == match_manager::fighter(m), E_FIGHTER_ONLY);
    assert!(!vault.fighter_claimed, E_ALREADY_CLAIMED);

    let is_win = match_manager::result_value(m);
    assert!(is_win, E_FIGHTER_LOST);

    let reward = fighter_reward_amount(m);
    let fee = fee_amount(reward);
    let payout_amount = match_manager::fighter_stake(m) + reward - fee;
    vault.fighter_claimed = true;

    if (payout_amount > 0) {
        let mut payout = coin::split(&mut vault.fighter_stake, match_manager::fighter_stake(m), ctx);
        if (reward > 0) {
            let reward_coin = coin::split(&mut vault.viewer_pool, reward, ctx);
            coin::join(&mut payout, reward_coin);
        };
        if (fee > 0) {
            let fee_coin = coin::split(&mut payout, fee, ctx);
            transfer::public_transfer(fee_coin, treasury.admin);
        };
        transfer::public_transfer(payout, sender);
    };

    event::emit(FighterRewardClaimed {
        match_id: object::id(m),
        fighter: sender,
        amount: payout_amount,
    });
}

#[allow(lint(self_transfer))]
public fun refund_bet<T>(vault: &mut BetVault<T>, m: &mut Match, ctx: &mut TxContext) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_cancelled(m), E_MATCH_NOT_CANCELLED);

    let sender = tx_context::sender(ctx);
    assert!(!table::contains(&vault.claimed, sender), E_ALREADY_CLAIMED);

    let refund = if (match_manager::has_win_bet(m, sender)) {
        match_manager::win_bet_amount(m, sender)
    } else if (match_manager::has_lose_bet(m, sender)) {
        match_manager::lose_bet_amount(m, sender)
    } else {
        abort E_NOT_BETTOR
    };

    table::add(&mut vault.claimed, sender, true);

    if (refund > 0) {
        let payout = coin::split(&mut vault.viewer_pool, refund, ctx);
        transfer::public_transfer(payout, sender);
    };
}

#[allow(lint(self_transfer))]
public fun claim_cancelled_stake<T>(vault: &mut BetVault<T>, m: &mut Match, ctx: &mut TxContext) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_cancelled(m), E_MATCH_NOT_CANCELLED);
    assert!(match_manager::cancel_stake_refundable(m), E_STAKE_NOT_REFUNDABLE);

    let sender = tx_context::sender(ctx);
    assert!(sender == match_manager::fighter(m), E_FIGHTER_ONLY);
    assert!(!vault.fighter_claimed, E_ALREADY_CLAIMED);

    let amount = match_manager::fighter_stake(m);
    vault.fighter_claimed = true;

    if (amount > 0) {
        let payout = coin::split(&mut vault.fighter_stake, amount, ctx);
        transfer::public_transfer(payout, sender);
    };

    event::emit(FighterStakeRefunded {
        match_id: object::id(m),
        fighter: sender,
        amount,
    });
}

#[allow(lint(self_transfer))]
public fun claim_slashed_stake<T>(
    treasury: &Treasury,
    vault: &mut BetVault<T>,
    m: &mut Match,
    ctx: &mut TxContext,
) {
    assert!(vault.match_id == object::id(m), E_MATCH_MISMATCH);
    assert!(match_manager::is_cancelled(m) || match_manager::is_ended(m), E_MATCH_NOT_ENDED);
    assert!(tx_context::sender(ctx) == treasury.admin, E_NOT_TREASURY_ADMIN);
    assert!(!vault.fighter_claimed, E_ALREADY_CLAIMED);

    if (match_manager::is_ended(m)) {
        assert!(!match_manager::result_value(m), E_NO_SLASHED_STAKE);
    } else {
        assert!(!match_manager::cancel_stake_refundable(m), E_NO_SLASHED_STAKE);
    };

    let amount = match_manager::fighter_stake(m);
    vault.fighter_claimed = true;

    if (amount > 0) {
        let payout = coin::split(&mut vault.fighter_stake, amount, ctx);
        transfer::public_transfer(payout, treasury.admin);
    };

    event::emit(SlashedStakeClaimed {
        match_id: object::id(m),
        amount,
    });
}

public fun cancel_match(m: &mut Match, ctx: &mut TxContext) {
    let sender = tx_context::sender(ctx);
    assert!(sender == match_manager::fighter(m), E_FIGHTER_ONLY);

    if (!match_manager::has_two_sided_bets(m)) {
        match_manager::cancel_match_with_refund(m);
    } else {
        match_manager::cancel_match_with_slash(m);
    };
}

public fun cancel_match_as_admin(_: &AdminCap, m: &mut Match) {
    match_manager::cancel_match_with_slash(m);
}

public fun fighter_reward_amount(m: &Match): u64 {
    if (match_manager::result_value(m)) {
        (match_manager::lose_bets_total(m) * FIGHTER_SHARE_BPS) / BPS_DENOM
    } else {
        0
    }
}

public fun fee_amount(amount: u64): u64 {
    (amount * FEE_BPS) / BPS_DENOM
}

public fun net_amount(amount: u64): u64 {
    amount - fee_amount(amount)
}

fun winning_bet_amount(m: &Match, viewer: address): u64 {
    if (match_manager::result_value(m)) {
        match_manager::win_bet_amount(m, viewer)
    } else {
        match_manager::lose_bet_amount(m, viewer)
    }
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

public fun is_claimed<T>(vault: &BetVault<T>, viewer: address): bool {
    table::contains(&vault.claimed, viewer)
}

public fun is_fighter_claimed<T>(vault: &BetVault<T>): bool {
    vault.fighter_claimed
}

public fun pool_balance<T>(vault: &BetVault<T>): u64 {
    coin::value(&vault.viewer_pool) + coin::value(&vault.fighter_stake)
}

public fun treasury_admin(treasury: &Treasury): address {
    treasury.admin
}

public fun fee_bps(): u64 {
    FEE_BPS
}

public fun fighter_share_bps(): u64 {
    FIGHTER_SHARE_BPS
}

public fun preview_reward(m: &Match, viewer: address): u64 {
    if (match_manager::is_cancelled(m)) {
        0
    } else if (!match_manager::is_ended(m)) {
        0
    } else if (match_manager::result_value(m)) {
        if (!match_manager::has_win_bet(m, viewer)) {
            0
        } else {
            let bet_amount = match_manager::win_bet_amount(m, viewer);
            let viewers_reward_pool = match_manager::lose_bets_total(m) - fighter_reward_amount(m);
            let reward_u128 =
                (bet_amount as u128) * (viewers_reward_pool as u128)
                    / (match_manager::win_bets_total(m) as u128);
            let profit = reward_u128 as u64;
            bet_amount + net_amount(profit)
        }
    } else {
        if (!match_manager::has_lose_bet(m, viewer)) {
            0
        } else {
            let bet_amount = match_manager::lose_bet_amount(m, viewer);
            let reward_u128 =
                (bet_amount as u128) * (match_manager::win_bets_total(m) as u128)
                    / (match_manager::lose_bets_total(m) as u128);
            let profit = reward_u128 as u64;
            bet_amount + net_amount(profit)
        }
    }
}

#[test_only]
use one::oct::OCT;
#[test_only]
use one::test_scenario::{Self as ts};

#[test_only]
fun new_test_vault(m: &Match, ctx: &mut TxContext): BetVault<OCT> {
    BetVault<OCT> {
        id: object::new(ctx),
        match_id: object::id(m),
        viewer_pool: coin::zero<OCT>(ctx),
        fighter_stake: coin::mint_for_testing<OCT>(match_manager::fighter_stake(m), ctx),
        claimed: table::new(ctx),
        fighter_claimed: false,
    }
}

#[test_only]
fun new_test_treasury(ctx: &mut TxContext): Treasury {
    Treasury {
        id: object::new(ctx),
        admin: tx_context::sender(ctx),
    }
}

#[test_only]
fun default_test_stake(ctx: &mut TxContext): Coin<OCT> {
    coin::mint_for_testing<OCT>(match_manager::default_fighter_stake(), ctx)
}

#[test_only]
fun test_units(amount: u64): u64 {
    amount * COIN_DECIMALS_FACTOR
}

#[test]
fun test_place_bet_updates_totals() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;
    let viewer = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(test_units(50), &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet, &mut ctx);

    assert!(match_manager::win_bets_total(&m) == test_units(50), 1);
    assert!(match_manager::total_pool(&m) == test_units(50), 2);
    assert!(coin::value(&v.viewer_pool) == test_units(50), 3);
    assert!(!is_claimed(&v, viewer), 4);
    assert!(pool_balance(&v) == test_units(60), 5);

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

    let bet = coin::mint_for_testing<OCT>(test_units(25), &mut ctx);
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, &mut ctx);

    let view_opt = user_bet_view(&m, viewer);
    assert!(option::is_some(&view_opt), 1);
    let view = option::borrow(&view_opt);
    assert!(view.side == SIDE_LOSE, 2);
    assert!(view.amount == test_units(25), 3);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
fun test_preview_reward_win() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;
    let viewer_win = @0xB;
    let viewer_lose = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let win_bet = coin::mint_for_testing<OCT>(test_units(100), &mut ctx);
    match_manager::add_win_bet(&mut m, viewer_win, test_units(100));
    coin::join(&mut v.viewer_pool, win_bet);
    let lose_bet = coin::mint_for_testing<OCT>(test_units(50), &mut ctx);
    match_manager::add_lose_bet(&mut m, viewer_lose, test_units(50));
    coin::join(&mut v.viewer_pool, lose_bet);

    let admin = match_manager::create_test_admin(&mut ctx);
    match_manager::set_status_in_game(&mut m);
    match_manager::end_match(&admin, &mut m, true);
    match_manager::destroy_test_admin(admin);

    assert!(preview_reward(&m, viewer_win) == 139200000000, 1);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
}

#[test]
fun test_preview_reward_lose() {
    let mut ctx = tx_context::dummy();
    let fighter = @0xA;
    let viewer_win = @0xB;
    let viewer_lose = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let win_bet = coin::mint_for_testing<OCT>(test_units(20), &mut ctx);
    match_manager::add_win_bet(&mut m, viewer_win, test_units(20));
    coin::join(&mut v.viewer_pool, win_bet);
    let lose_bet = coin::mint_for_testing<OCT>(test_units(80), &mut ctx);
    match_manager::add_lose_bet(&mut m, viewer_lose, test_units(80));
    coin::join(&mut v.viewer_pool, lose_bet);

    let admin = match_manager::create_test_admin(&mut ctx);
    match_manager::set_status_in_game(&mut m);
    match_manager::end_match(&admin, &mut m, false);
    match_manager::destroy_test_admin(admin);

    assert!(preview_reward(&m, viewer_lose) == 99600000000, 1);

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

    let bet1 = coin::mint_for_testing<OCT>(test_units(10), &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet1, &mut ctx);
    let bet2 = coin::mint_for_testing<OCT>(test_units(5), &mut ctx);
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

    let bet = coin::mint_for_testing<OCT>(test_units(10), &mut ctx);
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
    let treasury = new_test_treasury(&mut ctx);

    let bet = coin::mint_for_testing<OCT>(test_units(10), &mut ctx);
    place_bet(&mut v, &mut m, SIDE_WIN, bet, &mut ctx);

    claim_viewer_reward(&treasury, &mut v, &mut m, &mut ctx);

    transfer::public_transfer(m, @0x0);
    transfer::transfer(v, @0x0);
    transfer::transfer(treasury, @0x0);
}

#[test]
#[expected_failure(abort_code = E_FIGHTER_CANNOT_BET)]
fun test_fighter_bet_rejected() {
    let mut ctx = tx_context::dummy();
    let fighter = tx_context::sender(&ctx);

    let mut m = match_manager::create_test_match(fighter, &mut ctx);
    let mut v = new_test_vault(&m, &mut ctx);

    let bet = coin::mint_for_testing<OCT>(test_units(10), &mut ctx);
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
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);
    let treasury = new_test_treasury(scenario.ctx());
    transfer::public_share_object(treasury);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(100), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_lose);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(50), scenario.ctx());
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
    let mut v: BetVault<OCT> = scenario.take_shared();
    let treasury: Treasury = scenario.take_shared();
    assert!(preview_reward(&m, viewer_win) == 139200000000, 1);
    claim_viewer_reward(&treasury, &mut v, &mut m, scenario.ctx());
    assert!(coin::value(&v.viewer_pool) == 10000000000, 2);
    assert!(coin::value(&v.fighter_stake) == match_manager::default_fighter_stake(), 3);
    assert!(table::contains(&v.claimed, viewer_win), 3);
    transfer::public_share_object(m);
    transfer::public_share_object(v);
    transfer::public_share_object(treasury);

    scenario.next_tx(viewer_lose);
    let m: Match = scenario.take_shared();
    let v: BetVault<OCT> = scenario.take_shared();
    assert!(preview_reward(&m, viewer_lose) == 0, 4);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let treasury: Treasury = scenario.take_shared();
    claim_fighter_reward(&treasury, &mut v, &mut m, scenario.ctx());
    assert!(coin::value(&v.viewer_pool) == 0, 5);
    assert!(coin::value(&v.fighter_stake) == 0, 6);
    assert!(v.fighter_claimed, 7);
    transfer::public_share_object(m);
    transfer::public_share_object(v);
    transfer::public_share_object(treasury);

    ts::end(scenario);
}

#[test]
fun test_create_match_with_bet_vault() {
    let fighter = @0xA;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());

    let ids = match_manager::get_match_ids(&registry);
    assert!(vector::length(&ids) == 1, 1);
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(fighter);
    let m: Match = scenario.take_shared();
    let v: BetVault<OCT> = scenario.take_shared();
    let vault_id = match_manager::match_vault_id(&m);
    assert!(option::is_some(&vault_id), 2);
    assert!(v.match_id == object::id(&m), 3);
    assert!(coin::value(&v.fighter_stake) == match_manager::default_fighter_stake(), 4);

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    ts::end(scenario);
}

#[test]
#[expected_failure]
fun test_start_without_both_sides_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    match_manager::start_match(&mut m, scenario.ctx());

    transfer::public_share_object(m);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_BETS_LOCKED)]
fun test_bet_when_in_game_rejected() {
    let fighter = @0xA;
    let viewer_win = @0xB;
    let viewer_lose = @0xC;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_lose);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    match_manager::start_match(&mut m, scenario.ctx());
    transfer::public_share_object(m);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
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
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);
    let treasury = new_test_treasury(scenario.ctx());
    transfer::public_share_object(treasury);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(@0xC);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
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

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let treasury: Treasury = scenario.take_shared();
    claim_viewer_reward(&treasury, &mut v, &mut m, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);
    transfer::public_share_object(treasury);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let treasury: Treasury = scenario.take_shared();
    claim_viewer_reward(&treasury, &mut v, &mut m, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    transfer::public_share_object(treasury);
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
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);
    let treasury = new_test_treasury(scenario.ctx());
    transfer::public_share_object(treasury);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(100), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_lose);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(50), scenario.ctx());
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
    let mut v: BetVault<OCT> = scenario.take_shared();
    let treasury: Treasury = scenario.take_shared();
    claim_viewer_reward(&treasury, &mut v, &mut m, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    transfer::public_share_object(treasury);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = E_FIGHTER_LOST)]
fun test_claim_fighter_when_lose_rejected() {
    let fighter = @0xA;
    let viewer = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);
    let treasury = new_test_treasury(scenario.ctx());
    transfer::public_share_object(treasury);

    scenario.next_tx(viewer);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_LOSE, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(@0xC);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet_win = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet_win, scenario.ctx());
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
    let mut v: BetVault<OCT> = scenario.take_shared();
    let treasury: Treasury = scenario.take_shared();
    claim_fighter_reward(&treasury, &mut v, &mut m, scenario.ctx());

    transfer::public_share_object(m);
    transfer::public_share_object(v);
    transfer::public_share_object(treasury);
    ts::end(scenario);
}

#[test]
fun test_refund_bet_after_cancel() {
    let fighter = @0xA;
    let viewer_win = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(40), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    cancel_match(&mut m, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    refund_bet(&mut v, &mut m, scenario.ctx());
    assert!(table::contains(&v.claimed, viewer_win), 1);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(fighter);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    claim_cancelled_stake(&mut v, &mut m, scenario.ctx());
    assert!(coin::value(&v.viewer_pool) == 0, 2);
    assert!(coin::value(&v.fighter_stake) == 0, 3);
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    ts::end(scenario);
}

#[test]
fun test_admin_can_cancel_match() {
    let fighter = @0xA;
    let viewer_win = @0xB;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(40), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(@0xD);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let admin = match_manager::create_test_admin(scenario.ctx());
    cancel_match_as_admin(&admin, &mut m);
    assert!(match_manager::is_cancelled(&m), 1);
    assert!(!match_manager::cancel_stake_refundable(&m), 2);
    transfer::public_share_object(m);
    transfer::public_share_object(v);
    match_manager::destroy_test_admin(admin);

    ts::end(scenario);
}

#[test]
fun test_slashed_stake_claim_after_loss() {
    let fighter = @0xA;
    let viewer_win = @0xB;
    let viewer_lose = @0xC;

    let mut scenario = ts::begin(fighter);
    let mut registry = match_manager::create_test_registry(scenario.ctx());
    let stake = default_test_stake(scenario.ctx());
    create_match_with_bet_vault<OCT>(&mut registry, b"Room", stake, scenario.ctx());
    transfer::public_transfer(registry, @0x0);
    let treasury = new_test_treasury(scenario.ctx());
    transfer::public_share_object(treasury);

    scenario.next_tx(viewer_win);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
    place_bet(&mut v, &mut m, SIDE_WIN, bet, scenario.ctx());
    transfer::public_share_object(m);
    transfer::public_share_object(v);

    scenario.next_tx(viewer_lose);
    let mut m: Match = scenario.take_shared();
    let mut v: BetVault<OCT> = scenario.take_shared();
    let bet = coin::mint_for_testing<OCT>(test_units(10), scenario.ctx());
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
    let mut v: BetVault<OCT> = scenario.take_shared();
    let treasury: Treasury = scenario.take_shared();
    claim_slashed_stake(&treasury, &mut v, &mut m, scenario.ctx());
    assert!(coin::value(&v.fighter_stake) == 0, 1);
    assert!(v.fighter_claimed, 2);
    transfer::public_share_object(m);
    transfer::public_share_object(v);
    transfer::public_share_object(treasury);

    ts::end(scenario);
}
