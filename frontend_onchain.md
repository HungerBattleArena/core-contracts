Frontend on-chain integration guide (Testnet)

This document describes how the frontend reads data and sends transactions to
the on-chain modules deployed on testnet. IDs are listed in `testnet.md`.

Testnet configuration
- RPC: https://rpc-testnet.onelabs.cc:443
- PackageID: see `testnet.md`
- Registry (Shared): see `testnet.md`
- Treasury (Shared, fee receiver): see `testnet.md`
- AdminCap (held by admin wallet): see `testnet.md`

Modules
- `match_manager`: match lifecycle and room state.
- `bet_engine`: match creation with stake, betting, cancel flow, and reward settlement.

Key shared objects
- `Registry`: stores `match_ids` for listing.
- `Match`: a match/room (shared).
- `BetVault`: viewer pool + fighter stake + claim state (shared).
- `Treasury`: fee receiver (shared).

Token configuration
Coin type (Hackathon): `0x8b76fc2a2317d45118770cefed7e57171a08c477ed16283616b15f099391f120::hackathon::HACKATHON`
Decimals: 9

Economic model used by the current contracts
- Fighter stake is fixed by contract: `default_fighter_stake()`
- Current fighter stake: `10 HACKATHON` (`10000000000` base units)
- Frontend should not let the fighter choose an arbitrary stake amount
- Match can start only when both `WIN` pool and `LOSE` pool are greater than 0
- Fighter share = 20% of losing-side pool on fighter win
- Fee = 2% of profit only
- Minimum bet = `1 HACKATHON` (`1000000000` base units)
- Maximum bet = `1000 HACKATHON` (`1000000000000` base units)
- If fighter wins:
  - fighter claim = `fighter stake + 20% of losing-side pool`, and the 2% fee is charged only on the `20%` profit part
  - winning viewers split the remaining losing-side pool proportionally, and each viewer pays 2% fee only on the profit part, not on the original bet
- If fighter loses:
  - LOSE-side viewers split the WIN-side pool proportionally and pay 2% fee only on the profit part
- If match is cancelled before both sides are funded:
  - viewers refund bets manually
  - fighter claims stake back manually
- If match is cancelled in slash mode or fighter loses:
  - treasury admin claims the slashed fighter stake

View (read-only functions)
Use `devInspectTransactionBlock` or SDK view helpers.

`match_manager`
- `get_match_ids(registry) -> vector<ID>`
- `match_view(match) -> MatchView`
- `match_vault_id(match) -> Option<ID>`
- `default_fighter_stake() -> u64`

`bet_engine`
- `user_bet_view(match, viewer) -> Option<UserBetView>`
- `preview_reward(match, viewer) -> u64`
- `is_claimed(vault, viewer) -> bool`
- `is_fighter_claimed(vault) -> bool`
- `pool_balance(vault) -> u64`
- `fighter_reward_amount(match) -> u64`
- `fee_bps() -> u64`
- `fighter_share_bps() -> u64`
- `treasury_admin(treasury) -> address`

Notes for frontend
- `preview_reward` already returns net amount after the 2% profit-only fee
- `is_fighter_claimed(vault)` is used for both fighter reward claim and fighter stake claim/slash settlement
- `pool_balance(vault)` includes both viewer pool and fighter stake

BCS schema for view functions

MatchView
```ts
import { bcs } from "@mysten/sui/bcs";

const MatchView = bcs.struct("MatchView", {
  match_id: bcs.Address,
  vault_id: bcs.option(bcs.Address),
  name: bcs.string(),
  fighter: bcs.Address,
  fighter_stake: bcs.u64(),
  status: bcs.u8(),                 // 0=CREATED, 1=IN_GAME, 2=ENDED, 3=CANCELLED
  result: bcs.option(bcs.bool()),
  cancel_stake_refundable: bcs.bool(),
  total_pool: bcs.u64(),
  total_bet_viewers: bcs.u64(),
  win_bets_total: bcs.u64(),
  lose_bets_total: bcs.u64(),
  win_bettors_count: bcs.u64(),
  lose_bettors_count: bcs.u64(),
});
```

UserBetView
```ts
const UserBetView = bcs.struct("UserBetView", {
  side: bcs.u8(), // 0=WIN, 1=LOSE
  amount: bcs.u64(),
});
```

Return types
- `get_match_ids` -> `bcs.vector(bcs.Address)`
- `match_view` -> `MatchView`
- `match_vault_id` -> `bcs.option(bcs.Address)`
- `default_fighter_stake` -> `bcs.u64()`
- `user_bet_view` -> `bcs.option(UserBetView)`
- `preview_reward` -> `bcs.u64()`
- `is_claimed` -> `bcs.bool()`
- `is_fighter_claimed` -> `bcs.bool()`
- `pool_balance` -> `bcs.u64()`
- `fighter_reward_amount` -> `bcs.u64()`
- `fee_bps` -> `bcs.u64()`
- `fighter_share_bps` -> `bcs.u64()`
- `treasury_admin` -> `bcs.Address`

Fighter flow
1) Create room + open bets
- First read `match_manager::default_fighter_stake()`
- The fighter must provide exactly that amount of coin when creating the room
- Call `bet_engine::create_match_with_bet_vault<T>(registry, name_bytes, fighter_stake_coin, ctx)`
- `name_bytes` must be <= 20 UTF-8 bytes
- Result: creates shared `Match` + `BetVault`

2) Wait for bets
- Read `match_view(match)` and show:
  - `fighter_stake`
  - `win_bets_total`
  - `lose_bets_total`
  - `total_bet_viewers`
- Frontend should only enable the Start button when:
  - `status == CREATED`
  - `win_bets_total > 0`
  - `lose_bets_total > 0`

3) Start match
- Call `match_manager::start_match(match, ctx)`
- Fighter only
- Contract will abort if either side has zero bets

4) End match
- Call `match_manager::end_match(admin_cap, match, is_win)`
- Admin only
- If using backend API (server signs as admin), call:
  - `POST https://hunger-api.a-star.group/api/hunger-game/match/end`
  - JSON body: `{ "matchId": "<MATCH_ID>", "isWin": true }`

5) Cancel match
- Fighter cancel:
  - Call `bet_engine::cancel_match(match, ctx)`
  - If both sides are not funded yet, contract marks the cancel as refundable for fighter stake
  - Otherwise contract marks the cancel as slash
- Admin cancel:
  - Call `bet_engine::cancel_match_as_admin(admin_cap, match)`
  - Admin cancel always goes to slash mode
- If using backend API for admin cancel, keep the backend aligned with `cancel_match_as_admin`

6) Fighter settlement
- If fighter wins:
  - Call `bet_engine::claim_fighter_reward<T>(treasury, vault, match, ctx)`
- If match is cancelled with `cancel_stake_refundable == true`:
  - Call `bet_engine::claim_cancelled_stake<T>(vault, match, ctx)`
- If fighter loses or match is cancelled in slash mode:
  - fighter cannot claim stake
  - treasury admin must call `bet_engine::claim_slashed_stake<T>(treasury, vault, match, ctx)`

Data for fighter UI
- Room status: `match_view(match).status`
- Room stake: `match_view(match).fighter_stake`
- Cancel refund flag: `match_view(match).cancel_stake_refundable`
- Fighter reward preview after end:
  - profit = `fighter_reward_amount(match)`
  - gross fighter win reward = `fighter_stake + profit`
  - net reward = `fighter_stake + profit * (10000 - fee_bps()) / 10000`

Viewer flow
1) Room list
- Call `match_manager::get_match_ids(registry)`
- For each `match_id`, fetch the `Match` object and call:
  - `match_view(match)`
- Show only rooms with `status == CREATED` as open for betting

2) Room detail / place bet
- Read `match_view(match)` for:
  - room status
  - win/lose pool totals
  - fighter stake
  - bettor counts
- Read `user_bet_view(match, viewer)` to show existing bet
- Place bet:
  - Call `bet_engine::place_bet<T>(vault, match, side, Coin<T>, ctx)`
  - `side`: `0 = WIN`, `1 = LOSE`
  - Only allowed while `status == CREATED`
  - Each address can bet only once
  - Fighter cannot bet

3) Waiting screen
- Poll `match_view(match).status` until it becomes `IN_GAME` then `ENDED` or `CANCELLED`

4) Result / claim
- Use `preview_reward(match, viewer)` to show estimated net payout
- Use `is_claimed(vault, viewer)` to enable or disable the claim button
- Winning viewer claim:
  - Call `bet_engine::claim_viewer_reward<T>(treasury, vault, match, ctx)`

5) Refund when match is CANCELLED
- Refund amount is the original bet amount from `user_bet_view(match, viewer)`
- Call `bet_engine::refund_bet<T>(vault, match, ctx)`
- Frontend should show this only when:
  - `status == CANCELLED`
  - `is_claimed(vault, viewer) == false`

How to find BetVault by Match
- Read `match_view(match).vault_id`
- Or call `match_manager::match_vault_id(match)`
- Each match has exactly one vault

Recommended frontend rules
- Disable Start unless both pools are > 0
- On create room, always prefill and lock fighter stake using `default_fighter_stake()`
- After `CANCELLED`:
  - if current user is fighter and `cancel_stake_refundable == true`, show `Claim Stake Back`
  - if current user is viewer, show `Refund Bet`
  - if current user is admin and `cancel_stake_refundable == false`, show `Claim Slashed Stake`
- After `ENDED`:
  - if fighter won, show fighter claim button
  - if fighter lost, only winning viewers can claim; treasury admin can claim slashed stake

Targets (Move call format)
Use package ID from `testnet.md`
- `0x...::match_manager::start_match`
- `0x...::match_manager::end_match`
- `0x...::match_manager::get_match_ids`
- `0x...::match_manager::match_view`
- `0x...::match_manager::match_vault_id`
- `0x...::match_manager::default_fighter_stake`
- `0x...::bet_engine::create_match_with_bet_vault` (typeArgs: `[coinType]`)
- `0x...::bet_engine::place_bet` (typeArgs: `[coinType]`)
- `0x...::bet_engine::cancel_match`
- `0x...::bet_engine::cancel_match_as_admin`
- `0x...::bet_engine::claim_viewer_reward` (typeArgs: `[coinType]`)
- `0x...::bet_engine::claim_fighter_reward` (typeArgs: `[coinType]`)
- `0x...::bet_engine::refund_bet` (typeArgs: `[coinType]`)
- `0x...::bet_engine::claim_cancelled_stake` (typeArgs: `[coinType]`)
- `0x...::bet_engine::claim_slashed_stake` (typeArgs: `[coinType]`)
- `0x...::bet_engine::user_bet_view`
- `0x...::bet_engine::preview_reward`
- `0x...::bet_engine::is_claimed`
- `0x...::bet_engine::is_fighter_claimed`
- `0x...::bet_engine::pool_balance`
- `0x...::bet_engine::fighter_reward_amount`
- `0x...::bet_engine::fee_bps`
- `0x...::bet_engine::fighter_share_bps`
- `0x...::bet_engine::treasury_admin`
