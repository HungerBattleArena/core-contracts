Hướng dẫn tích hợp on-chain cho Frontend (Testnet)

Tài liệu này mô tả cách FE đọc dữ liệu và gửi giao dịch tới các module
on-chain đã deploy trên testnet. Các ID nằm trong `testnet.md`.

Cấu hình testnet
- RPC: https://rpc-testnet.onelabs.cc:443
- PackageID: xem `testnet.md`
- Registry (Shared): xem `testnet.md`
- AdminCap (ví fighter/admin giữ): xem `testnet.md`

Modules
- `match_manager`: vòng đời phòng/match + trạng thái match.
- `bet_engine`: đặt cược + chia thưởng + vault.

Các object shared quan trọng
- `Registry`: lưu `match_ids` để list.
- `Match`: một phòng/match (shared).
- `BetVault`: pool OCT + trạng thái claim (shared).

View (hàm đọc dữ liệu)
Dùng `devInspectTransactionBlock` hoặc helper view của SDK.

`match_manager`:
- `get_match_ids(registry) -> vector<ID>`
- `match_view(match) -> MatchView` (trạng thái + pool + betters + `vault_id`)

`bet_engine`:
- `user_bet_view(match, viewer) -> Option<UserBetView>`
- `preview_reward(match, viewer) -> u64`
- `is_claimed(vault, viewer) -> bool`
- `is_fighter_claimed(vault) -> bool`
- `fighter_reward_amount(total_pool) -> u64` (10% tổng pool)

Schema BCS cho các hàm view

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

Luồng fighter
1) Tạo phòng + mở bet (1 giao dịch, 1 ký)
- Gọi `bet_engine::create_match_with_bet_vault(registry, name_bytes, ctx)`
- `registry` là object Registry shared từ `testnet.md`
- `name_bytes` <= 20 bytes UTF-8
- Kết quả: tạo `Match` shared + `BetVault` shared; lấy `match_id` từ event `MatchCreated`.

3) Start match
- Gọi `match_manager::start_match(match, ctx)`
- Yêu cầu đúng fighter; trạng thái CREATED -> IN_GAME.

4) End match
- Gọi `match_manager::end_match(admin_cap, match, is_win)`
- `admin_cap` là AdminCap object (fighter/admin).
- Trạng thái IN_GAME -> ENDED và set result.
- Dùng backend API (server ký admin), gọi:
  - `POST https://hunger-api.a-star.group/api/hunger-game/match/end`
  - Body JSON: `{ "matchId": "<MATCH_ID>", "isWin": true }`

4.1) Cancel match (fighter bỏ, admin cancel)
- Gọi `match_manager::cancel_match(admin_cap, match)`
- Chỉ dùng khi match đang CREATED hoặc IN_GAME.
- Trạng thái -> CANCELLED, mở refund cho viewer.
- Dùng backend API (server ký admin), gọi:
  - `POST https://hunger-api.a-star.group/api/hunger-game/match/cancel`
  - Body JSON: `{ "matchId": "<MATCH_ID>" }`

5) Fighter claim (chỉ khi win)
- Gọi `bet_engine::claim_fighter_reward(vault, match, ctx)`
- Nhận 10% tổng pool; chỉ khi fighter thắng và chưa claim.

Dữ liệu cho UI fighter
- Trạng thái phòng: `match_view(match).status`
- Pool + betters: `match_view(match)`
- Màn kết quả: `match_view(match).result`
- Reward (nếu win): `fighter_reward_amount(total_pool)`

Luồng viewer
1) Danh sách phòng (betting open)
- Gọi `match_manager::get_match_ids(registry)`
- Với mỗi `match_id`, fetch object `Match` và gọi:
  - `match_view(match)` để lấy tổng số liệu và lọc `status == CREATED` (betting open)

2) Chi tiết phòng / lock bet
- Đọc `match_view(match)` để lấy pool + count.
- Đọc `user_bet_view(match, viewer)` để hiện bet đã đặt (nếu có).
- Đặt bet:
  - Gọi `bet_engine::place_bet(vault, match, side, Coin<OCT>, ctx)`
  - `side`: `SIDE_WIN` hoặc `SIDE_LOSE`
  - Chỉ được khi status == CREATED.
  - Mỗi address chỉ bet 1 lần/match; fighter không được bet.

3) Màn chờ
- Poll `match_view(match).status` cho tới IN_GAME rồi ENDED.

4) Kết quả / claim
- Dùng `preview_reward(match, viewer)` để hiện thưởng dự kiến sau khi end.
- Dùng `is_claimed(vault, viewer)` để bật/tắt nút claim.
- Claim:
  - Gọi `bet_engine::claim_viewer_reward(vault, match, ctx)`
  - Chỉ claim được nếu viewer nằm ở bên thắng.

4.1) Refund khi match CANCELLED
- Xem số tiền refund: `user_bet_view(match, viewer)` -> `amount`.
- Gọi refund: `bet_engine::refund_bet(vault, match, ctx)`
- Chỉ được khi match CANCELLED.

Cách tìm BetVault theo Match
- Đọc `match_view(match).vault_id` để lấy object ID của `BetVault`.
- Mỗi match có 1 `BetVault`, và `vault_id` được set khi mở bet.

Targets (Move call format)
Dùng package ID trong `testnet.md`:
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
