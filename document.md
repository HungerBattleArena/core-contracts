# Hunger Battle Arena on-chain document

## Project description
Hunger Battle Arena (HBA) is a 2D top-down survival arena game. Gameplay runs off-chain.
On-chain (OneChain Move) is the single source of truth for:
- match lifecycle
- fighter stake
- viewer betting
- reward settlement
- cancel/slash handling

MVP gameplay flow
- Fighter creates a room and deposits the default fighter stake.
- Viewers join the room, lock tokens, choose WIN or LOSE, and place bets.
- The fighter can start the match only when both WIN and LOSE pools are greater than 0.
- Gameplay runs off-chain.
- Match ends on-chain with an admin-signed result.
- Rewards, refunds, or slashed stake are claimed on-chain.

## Scope
- Modules: `hunger_battle_arena::match_manager`, `hunger_battle_arena::bet_engine`
- Network: OneChain Move

## Summary
- `match_manager` manages the room state, view data, and status transitions.
- `bet_engine` manages fighter stake, viewer pool, reward claims, refund claims, and slash settlement.
- All critical financial state is on-chain; gameplay is off-chain.

## Economic model

### Fighter stake
- The fighter stake is fixed by contract, not user-defined.
- Current default fighter stake: `10 HACKATHON` (`10000000000` base units)
- The fighter must deposit exactly the default stake amount when creating a match.

### Betting
- Viewers bet on `WIN` or `LOSE`.
- Minimum bet: `1 HACKATHON` (`1000000000` base units)
- Maximum bet: `1000 HACKATHON` (`1000000000000` base units)
- Each address can bet only once per match.
- The fighter cannot bet in their own match.
- Bets are only accepted while the match is in `CREATED`.

### Start conditions
- A match can start only if:
  - `WIN pool > 0`
  - `LOSE pool > 0`
  - match status is `CREATED`
  - caller is the fighter

### Settlement
If fighter wins:
- Fighter receives:
  - returned fighter stake
  - `20%` of the losing-side pool
- Winning viewers receive:
  - their original bet back
  - a proportional share of the remaining losing-side pool after subtracting the fighter share

If fighter loses:
- Fighter stake is slashed
- LOSE-side viewers receive:
  - their original bet back
  - a proportional share of the WIN-side pool

### Fee
- Fee = `2%` of each winner claim
- The fee is transferred to `Treasury.admin`
- Winner claim means:
  - viewer winning claim
  - fighter winning claim

### Cancel behavior
If the fighter cancels before both sides are funded:
- Match becomes `CANCELLED`
- Viewer bets can be refunded
- Fighter stake becomes refundable

If the fighter cancels after both sides are funded, or if admin cancels:
- Match becomes `CANCELLED`
- Viewer bets can still be refunded
- Fighter stake is slashed

## Module: match_manager

### Purpose
- Create and track matches
- Start and end matches
- Store room state for UI
- Store match-level totals and metadata

### Key objects
- `Registry` (shared): stores `match_ids`
- `Match` (shared): room state, fighter info, stake info, and bet totals
- `AdminCap` (owned): required to end a match and used by admin cancel path in `bet_engine`

### Key events
- `MatchCreated { match_id, fighter, name }`
- `MatchStarted { match_id, fighter }`
- `MatchEnded { match_id, fighter, is_win }`
- `MatchCancelled { match_id, fighter }`

### Main state in `Match`
- `fighter`
- `fighter_stake`
- `status`
- `result`
- `cancel_stake_refundable`
- `total_pool`
- `win_bets_total`
- `lose_bets_total`
- `vault_id`

### Public functions
- `start_match(match, ctx)`
  - fighter only
  - requires both sides funded
  - `CREATED -> IN_GAME`

- `end_match(admin_cap, match, is_win)`
  - admin only
  - `IN_GAME -> ENDED`
  - sets `result`

- `get_match_ids(registry) -> vector<ID>`
- `match_view(match) -> MatchView`
- `match_vault_id(match) -> Option<ID>`
- `default_fighter_stake() -> u64`

### Internal/package functions
- `create_match_internal(...) -> Match`
  - called by `bet_engine::create_match_with_bet_vault`
- `cancel_match_with_refund(match)`
  - used when cancel should preserve fighter stake
- `cancel_match_with_slash(match)`
  - used when cancel should slash fighter stake
- bookkeeping getters and mutators for bets/totals

### Access control
- `start_match`: fighter only
- `end_match`: admin only via `AdminCap`
- cancel transitions are invoked by `bet_engine`, not exposed directly as public frontend entry points in this module

### State invariants
- `status`: `CREATED -> IN_GAME -> ENDED` or `CREATED/IN_GAME -> CANCELLED`
- `result`: `None` before end, set once on end
- `vault_id`: set once
- `cancel_stake_refundable` is only meaningful when status is `CANCELLED`

## Module: bet_engine

### Purpose
- Create the vault and lock fighter stake
- Accept viewer bets
- Settle viewer rewards
- Settle fighter rewards
- Process viewer refunds
- Process fighter stake refunds or slashed stake collection

### Key objects
- `BetVault` (shared)
  - `viewer_pool`
  - `fighter_stake`
  - `claimed`
  - `fighter_claimed`
  - `match_id`
- `Treasury` (shared): fee receiver and slashed stake receiver

### Key events
- `BetVaultCreated { match_id, fighter }`
- `BetPlaced { match_id, bettor, side, amount }`
- `ViewerRewardClaimed { match_id, viewer, amount }`
- `FighterRewardClaimed { match_id, fighter, amount }`
- `FighterStakeRefunded { match_id, fighter, amount }`
- `SlashedStakeClaimed { match_id, amount }`

### Public functions
- `create_match_with_bet_vault(registry, name_bytes, fighter_stake_coin, ctx)`
  - creates `Match + BetVault`
  - requires deposited coin amount to equal `default_fighter_stake()`

- `place_bet(vault, match, side, bet, ctx)`
  - only while `match.status == CREATED`
  - blocks fighter bets
  - blocks double bets

- `claim_viewer_reward(treasury, vault, match, ctx)`
  - only after end
  - only for the winning side

- `claim_fighter_reward(treasury, vault, match, ctx)`
  - only after end
  - only if fighter wins

- `refund_bet(vault, match, ctx)`
  - viewer refund after `CANCELLED`

- `claim_cancelled_stake(vault, match, ctx)`
  - fighter claims stake back when cancelled in refundable mode

- `claim_slashed_stake(treasury, vault, match, ctx)`
  - treasury admin claims slashed fighter stake
  - used when fighter loses or when cancel is slash-mode

- `cancel_match(match, ctx)`
  - fighter-only cancel path
  - if two-sided betting is not funded yet -> refund mode
  - otherwise -> slash mode

- `cancel_match_as_admin(admin_cap, match)`
  - admin-only cancel path
  - always slash mode

### View functions
- `user_bet_view(match, viewer)`
- `preview_reward(match, viewer)`
- `is_claimed(vault, viewer)`
- `is_fighter_claimed(vault)`
- `pool_balance(vault)`
- `fighter_reward_amount(match)`
- `fee_bps()`
- `fighter_share_bps()`
- `treasury_admin(treasury)`

### Access control
- `create_bet_vault`: package-only and fighter-only
- `cancel_match`: fighter only
- `cancel_match_as_admin`: admin only
- `claim_fighter_reward`: fighter only
- `claim_cancelled_stake`: fighter only
- `claim_slashed_stake`: treasury admin only

## Reward formulas

### 1. Fighter wins
Let:
- `W = total WIN bets`
- `L = total LOSE bets`
- `fighter_share = L * 20%`

Then:
- fighter gross claim = `fighter_stake + fighter_share`
- each winning viewer gross claim = `viewer_win_bet + (viewer_win_bet / W) * (L - fighter_share)`

### 2. Fighter loses
Let:
- `W = total WIN bets`
- `L = total LOSE bets`

Then:
- fighter gross claim = `0`
- each winning LOSE viewer gross claim = `viewer_lose_bet + (viewer_lose_bet / L) * W`

### 3. Fee deduction
- net claim = `gross_claim - 2%`

## Safety checks
- `BetVault.claimed` prevents viewer double claim
- `fighter_claimed` prevents double fighter-side settlement
- losing viewers cannot claim rewards
- fighter cannot bet
- bet amount must stay within `[1, 1000]`
- start is blocked unless both sides have bets
- admin cancel always slashes fighter stake
- slash claim is only allowed when fighter actually lost or cancel entered slash mode

## Frontend-relevant notes
- `MatchView` includes `fighter_stake` and `cancel_stake_refundable`
- Frontend should use `default_fighter_stake()` to prefill and lock the create-room stake amount
- Frontend should not enable Start unless both side pools are greater than 0
- On `CANCELLED`:
  - viewers can refund bets
  - fighter can claim cancelled stake only when `cancel_stake_refundable == true`
  - treasury admin can claim slashed stake when `cancel_stake_refundable == false`
