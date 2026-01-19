Ghi chú kiểm toán - Hunger Battle Arena (OneChain Move)

## Phạm vi
- Modules: `hunger_battle_arena::match_manager`, `hunger_battle_arena::bet_engine`
- Mạng: OneChain Move 

## Tóm tắt
- `match_manager` quản lý vòng đời match và dữ liệu view.
- `bet_engine` quản lý pool bet, claim, và chia thưởng cho viewer/fighter.
- Trạng thái quan trọng đều on-chain; gameplay off-chain.

## Module: match_manager

Mục đích
- Tạo và theo dõi match (room).
- Start và end match.
- Cung cấp view read-only cho UI.

Object chính
- `Registry` (shared): lưu `match_ids`.
- `Match` (shared): trạng thái match và tổng bet.
- `AdminCap` (owned): bắt buộc khi end match.

Event chính
- `MatchCreated { match_id, fighter, name }`
- `MatchStarted { match_id, fighter }`
- `MatchEnded { match_id, fighter, is_win }`

Hàm public
- `start_match(match: &mut Match, ctx)`
  - Chỉ fighter được gọi; `CREATED -> IN_GAME`.
- `end_match(admin_cap: &AdminCap, match: &mut Match, is_win: bool)`
  - Chỉ admin được gọi; `IN_GAME -> ENDED`, set `result`.
- View:
  - `get_match_ids(registry: &Registry) -> vector<ID>`
    - Trả về danh sách match ID.
  - `match_view(match: &Match) -> MatchView`
    - Trả về dữ liệu UI (status/result/pool totals + counts).

Hàm nội bộ/package
- `create_match_internal(...) -> Match`
  - Được gọi bởi `bet_engine::create_match_with_bet_vault`.
- `set_vault_id(match, vault_id)`
  - Set `match.vault_id` 1 lần (có bảo vệ).
- Các helper getter dùng cho bet bookkeeping.

Kiểm soát truy cập
- `start_match`: chỉ fighter.
- `end_match`: cần `AdminCap`.

Bất biến trạng thái
- `status`: chỉ đi theo thứ tự `CREATED -> IN_GAME -> ENDED`.
- `result`: `None` trước end, chỉ được set một lần khi end match.
- `vault_id`: chỉ set một lần khi tạo bet vault.

## Module: bet_engine

Mục đích
- Tạo bet vault và quản lý OCT pool.
- Cho đặt bet WIN/LOSE.
- Chia thưởng cho viewer và fighter.

Object chính
- `BetVault` (shared): giữ `pool`, bảng claim, `match_id`.

Event chính
- `BetVaultCreated { match_id, fighter }`
- `BetPlaced { match_id, bettor, side, amount }`
- `ViewerRewardClaimed { match_id, viewer, amount }`
- `FighterRewardClaimed { match_id, fighter, amount }`

Hàm public
- `create_match_with_bet_vault(registry, name_bytes, ctx)`
  - Tạo `Match` + `BetVault` trong 1 tx, set `vault_id`, share cả hai.
- `place_bet(vault, match, side, bet, ctx)`
  - Chỉ khi match `CREATED`.
  - Chặn fighter bet và double bet.
- `claim_viewer_reward(vault, match, ctx)`
  - Chỉ sau end và chỉ bên thắng.
- `claim_fighter_reward(vault, match, ctx)`
  - Chỉ sau end và chỉ khi fighter win.
- View:
  - `user_bet_view(match, viewer)`
    - Trả về bet của viewer trong match (side + amount). Nếu viewer chưa bet thì trả None.
  - `preview_reward(match, viewer)`
    - Tính trước số OCT viewer sẽ nhận nếu match đã END và viewer ở phía thắng. Nếu chưa END hoặc viewer thua thì trả 0
  - `is_claimed(vault, viewer)`
    - Kiểm tra viewer đã claim thưởng trong vault chưa.
  - `is_fighter_claimed(vault)`
    - Kiểm tra fighter đã claim thưởng chưa.
  - `pool_balance(vault)`
    - Số OCT còn lại trong BetVault (sau khi một phần đã claim).
  - `fighter_reward_amount(total_pool)`
    - Tính phần thưởng cho fighter (10% tổng pool).

Kiểm soát truy cập
- `create_bet_vault` là `public(package)` chỉ fighter gọi; dùng nội bộ.
- `create_match_with_bet_vault` là entry public chính.
- Claim có kiểm tra bên thắng và chống claim 2 lần.

Công thức thưởng
- Fighter win:
  - Thưởng fighter = 10% tổng pool.
  - Thưởng viewer = (bet viewer / tổng win bets) * (total_pool - fighter_reward).
- Fighter lose:
  - Thưởng viewer = (bet viewer / tổng lose bets) * total_pool.

Kiểm soát an toàn
- `BetVault` dùng `Table` để chống double claim.
- Bên thua không được claim; abort `E_NOT_WINNER`.
- Pool được bảo toàn: tổng payout = total pool (fighter + viewers thắng).
