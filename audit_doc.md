# Audit doc
## Project description
Hunger Battle Arena (HBA) is a 2D top-down survival arena game. Gameplay runs off-chain;
on-chain (OneChain Move) is the single source of truth for the match lifecycle,
OCT betting, and reward settlement. MVP gameplay flow:
- Fighter creates a room (Create Room).
- Viewer joins the room, locks OCT to bet, chooses WIN/LOSE, and inputs the bet amount.
- When enough players are ready, the fighter presses Start to lock bets and start the match.
- Gameplay (3 minutes):
  - The circle shrinks over time.
  - Fighter battles randomly spawned monsters.
  - Viewers use buff/debuff items to influence the fighter toward their bet side
    (each item has a cooldown).
- Match ends and rewards are settled:
  - Fighter survives (WIN): fighter and all WIN-side bets receive rewards.
  - Fighter dies (LOSE): all LOSE-side bets receive rewards.

## Scope
- Modules: `hunger_battle_arena::match_manager`, `hunger_battle_arena::bet_engine`
- Network: OneChain Move

## Summary
- `match_manager` manages the match lifecycle and view data.
- `bet_engine` manages the betting pool, claims, and rewards for viewers/fighter.
- All critical state is on-chain; gameplay is off-chain.

## Module: match_manager

Purpose
- Create and track matches (rooms).
- Start and end matches.
- Provide read-only views for UI.

Key objects
- `Registry` (shared): stores `match_ids`.
- `Match` (shared): match state and total bets.
- `AdminCap` (owned): required to end a match.

Key events
- `MatchCreated { match_id, fighter, name }`
- `MatchStarted { match_id, fighter }`
- `MatchEnded { match_id, fighter, is_win }`
- `MatchCancelled { match_id, fighter }`

Public functions
- `start_match(match: &mut Match, ctx)`
  - Only fighter can call; `CREATED -> IN_GAME`.
- `end_match(admin_cap: &AdminCap, match: &mut Match, is_win: bool)`
  - Only admin can call; `IN_GAME -> ENDED`, set `result`.
- `cancel_match(admin_cap: &AdminCap, match: &mut Match)`
  - Only admin can call; use when `CREATED` or `IN_GAME`, set `CANCELLED`.
- Views:
  - `get_match_ids(registry: &Registry) -> vector<ID>`
    - Returns the list of match IDs.
  - `match_view(match: &Match) -> MatchView`
    - Returns UI data (status/result/pool totals + counts).

Internal/package functions
- `create_match_internal(...) -> Match`
  - Called by `bet_engine::create_match_with_bet_vault`.
- `set_vault_id(match, vault_id)`
  - Set `match.vault_id` once (guarded).
- Helper getters used for bet bookkeeping.

Access control
- `start_match`: fighter only.
- `end_match`: requires `AdminCap`.

State invariants
- `status`: `CREATED -> IN_GAME -> ENDED` or `CREATED/IN_GAME -> CANCELLED`.
- `result`: `None` before end, can only be set once when ending a match.
- `vault_id`: can only be set once when creating the bet vault.

## Module: bet_engine

Purpose
- Create bet vaults and manage the OCT pool.
- Allow WIN/LOSE betting.
- Distribute rewards to viewers and fighter.

Key objects
- `BetVault` (shared): holds `pool`, claim table, `match_id`.

Key events
- `BetVaultCreated { match_id, fighter }`
- `BetPlaced { match_id, bettor, side, amount }`
- `ViewerRewardClaimed { match_id, viewer, amount }`
- `FighterRewardClaimed { match_id, fighter, amount }`

Public functions
- `create_match_with_bet_vault(registry, name_bytes, ctx)`
  - Create `Match` + `BetVault` in one tx, set `vault_id`, share both.
- `place_bet(vault, match, side, bet, ctx)`
  - Only when match is `CREATED`.
  - Blocks fighter bets and double bets.
- `claim_viewer_reward(vault, match, ctx)`
  - Only after end and only for the winning side.
- `claim_fighter_reward(vault, match, ctx)`
  - Only after end and only if fighter wins.
- `refund_bet(vault, match, ctx)`
  - Only when match is `CANCELLED`, viewer calls to refund bet.
- Views:
  - `user_bet_view(match, viewer)`
    - Returns viewer bet in match (side + amount). If none, returns None.
  - `preview_reward(match, viewer)`
    - Pre-computes viewer reward if match ended and viewer is on winning side.
      If not ended or viewer loses, returns 0.
  - `is_claimed(vault, viewer)`
    - Checks if viewer has claimed in the vault.
  - `is_fighter_claimed(vault)`
    - Checks if fighter has claimed.
  - `pool_balance(vault)`
    - Remaining OCT in the BetVault (after some claims).
  - `fighter_reward_amount(total_pool)`
    - Fighter reward (10% of total pool).

Access control
- `create_bet_vault` is `public(package)` and fighter-only; used internally.
- `create_match_with_bet_vault` is the main public entry.
- Claims check the winning side and prevent double claims.
- Refund only allowed when match is `CANCELLED`, and each viewer can refund once.

Reward formula
- Fighter win:
  - Fighter reward = 10% of total pool.
  - Viewer reward = (viewer bet / total win bets) * (total_pool - fighter_reward).
- Fighter lose:
  - Viewer reward = (viewer bet / total lose bets) * total_pool.

Safety checks
- `BetVault` uses `Table` to prevent double claim.
- Losing side cannot claim; abort `E_NOT_WINNER`.
- Pool conservation: total payout = total pool (fighter + winning viewers).
