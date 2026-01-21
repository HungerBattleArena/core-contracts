Frontend on-chain integration guide (Testnet)

This document describes how the frontend reads data and sends transactions to
on-chain modules deployed on testnet. IDs are listed in `testnet.md`.

Testnet configuration
- RPC: https://rpc-testnet.onelabs.cc:443
- PackageID: see `testnet.md`
- Registry (Shared): see `testnet.md`
- AdminCap (held by admin wallet): see `testnet.md`
- Treasury (Shared, fee receiver): see `testnet.md`

Modules
- `match_manager`: match lifecycle and state.
- `bet_engine`: betting, rewards distribution, and vault.

Key shared objects
- `Registry`: stores `match_ids` for listing.
- `Match`: a match/room (shared).
- `BetVault`: OCT pool + claim state (shared).
- `Treasury`: fee receiver (shared).

View (read-only functions)
Use `devInspectTransactionBlock` or SDK view helpers.

`match_manager`:
- `get_match_ids(registry) -> vector<ID>`
- `match_view(match) -> MatchView` (status + pool + betters + `vault_id`)

`bet_engine`:
- `user_bet_view(match, viewer) -> Option<UserBetView>`
- `preview_reward(match, viewer) -> u64` (net reward after 5% fee)
- `is_claimed(vault, viewer) -> bool`
- `is_fighter_claimed(vault) -> bool`
- `fighter_reward_amount(total_pool) -> u64` (10% of total pool)
- `fee_bps() -> u64` (500 = 5%)
- `treasury_admin(treasury) -> address`

BCS schema for view functions

MatchView
```ts
import { bcs } from "@mysten/sui/bcs";

const MatchView = bcs.struct("MatchView", {
  match_id: bcs.Address,
  vault_id: bcs.option(bcs.Address),
  name: bcs.string(),
  fighter: bcs.Address,
  status: bcs.u8(),                 // 0=CREATED, 1=IN_GAME, 2=ENDED, 3=CANCELLED
  result: bcs.option(bcs.bool()),
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
  side: bcs.u8(),
  amount: bcs.u64(),
});
```

- `get_match_ids` -> `bcs.vector(bcs.Address)`
- `match_view` -> `MatchView`
- `user_bet_view` -> `bcs.option(UserBetView)`
- `preview_reward` -> `bcs.u64()`
- `is_claimed` -> `bcs.bool()`
- `is_fighter_claimed` -> `bcs.bool()`
- `fighter_reward_amount` -> `bcs.u64()`
- `fee_bps` -> `bcs.u64()`
- `treasury_admin` -> `bcs.Address`

Fighter flow
1) Create room + open bets (1 tx, 1 signature)
- Call `bet_engine::create_match_with_bet_vault(registry, name_bytes, ctx)`
- `registry` is the shared Registry object from `testnet.md`
- `name_bytes` <= 20 UTF-8 bytes
- Result: creates shared `Match` + `BetVault`; get `match_id` from `MatchCreated` event.

3) Start match
- Call `match_manager::start_match(match, ctx)`
- Requires fighter; status `CREATED -> IN_GAME`.

4) End match
- Call `match_manager::end_match(admin_cap, match, is_win)`
- `admin_cap` is the AdminCap object (admin).
- Status `IN_GAME -> ENDED` and set result.
- If using backend API (server signs as admin), call:
  - `POST https://hunger-api.a-star.group/api/hunger-game/match/end`
  - JSON body: `{ "matchId": "<MATCH_ID>", "isWin": true }`

4.1) Cancel match (fighter quits, admin cancels)
- Call `match_manager::cancel_match(admin_cap, match)`
- Only when match is `CREATED` or `IN_GAME`.
- Status -> `CANCELLED`, enable refund for viewers.
- If using backend API (server signs as admin), call:
  - `POST https://hunger-api.a-star.group/api/hunger-game/match/cancel`
  - JSON body: `{ "matchId": "<MATCH_ID>" }`

5) Fighter claim (only when win)
- Call `bet_engine::claim_fighter_reward(treasury, vault, match, ctx)`
- Receive 10% of total pool, then pay 5% fee from the reward.

Data for fighter UI
- Room status: `match_view(match).status`
- Pool + betters: `match_view(match)`
- Result screen: `match_view(match).result`
- Reward (if win): `fighter_reward_amount(total_pool)`
- Reward (net): `preview_reward(match, fighter)` after end

Viewer flow
1) Room list (betting open)
- Call `match_manager::get_match_ids(registry)`
- For each `match_id`, fetch the `Match` object and call:
  - `match_view(match)` to get totals and filter `status == CREATED` (betting open)

2) Room detail / lock bet
- Read `match_view(match)` for pool + counts.
- Read `user_bet_view(match, viewer)` to show existing bet (if any).
- Place bet:
  - Call `bet_engine::place_bet(vault, match, side, Coin<OCT>, ctx)`
  - `side`: `SIDE_WIN` or `SIDE_LOSE`
  - Only when status == CREATED.
  - Each address can bet only once per match; fighter cannot bet.

3) Waiting screen
- Poll `match_view(match).status` until IN_GAME then ENDED.

4) Result / claim
- Use `preview_reward(match, viewer)` to show estimated reward after end (net, fee already applied).
- Use `is_claimed(vault, viewer)` to enable/disable claim button.
- Claim:
  - Call `bet_engine::claim_viewer_reward(treasury, vault, match, ctx)`
  - Can only claim if viewer is on the winning side.

4.1) Refund when match is CANCELLED
- Refund amount: `user_bet_view(match, viewer)` -> `amount`.
- Call refund: `bet_engine::refund_bet(vault, match, ctx)`
- Only when match is CANCELLED.

How to find BetVault by Match
- Read `match_view(match).vault_id` to get the `BetVault` object ID.
- Each match has one `BetVault`, and `vault_id` is set when opening bets.

Targets (Move call format)
Use package ID from `testnet.md`:
- `0x...::match_manager::start_match`
- `0x...::match_manager::end_match`
- `0x...::match_manager::cancel_match`
- `0x...::match_manager::get_match_ids`
- `0x...::match_manager::match_view`
- `0x...::bet_engine::create_match_with_bet_vault`
- `0x...::bet_engine::place_bet`
- `0x...::bet_engine::claim_viewer_reward`
- `0x...::bet_engine::claim_fighter_reward`
- `0x...::bet_engine::refund_bet`
- `0x...::bet_engine::user_bet_view`
- `0x...::bet_engine::preview_reward`
- `0x...::bet_engine::is_claimed`
- `0x...::bet_engine::is_fighter_claimed`
- `0x...::bet_engine::fee_bps`
- `0x...::bet_engine::treasury_admin`
