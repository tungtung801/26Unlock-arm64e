# 26Unlock-arm64e

Tái hiện hoạt ảnh mở khóa kiểu iOS 26 trên màn hình khóa iOS 16 (tweak gốc của
blu_tek, bản gốc chỉ build arm64 cho A11 trở xuống).

Repo này patch lại để chạy trên **arm64e (A12 trở lên)** và build `.deb` bằng GitHub Actions.

## Tình trạng & nguyên nhân lỗi trước đây

Bản gốc (`original.deb`) hoạt động tốt, nhưng bản build arm64e thì **không có hoạt ảnh**.
Không phải lỗi build — dylib arm64e/rootless/chữ ký/filter đều đúng. Nguyên nhân là
logic kích hoạt bị dịch ngược **ngược dấu** so với binary gốc.

👉 Xem phân tích đầy đủ (kèm địa chỉ lệnh asm) trong **[DIAGNOSE.md](DIAGNOSE.md)**.

Tóm tắt:

| | Binary gốc | Bản dựng lại cũ (sai) |
|---|---|---|
| Pan kết thúc | `g_panFired = 1` → fire **ngay** | fire gián tiếp |
| Màn hình khóa biến mất | `if (g_panFired) return;` → pan chưa chạy thì fire sau **0.35 s** | `if (!g_haveLastVel) return;` → **bỏ cuộc** |

Hệ quả: nếu class `SBCoverSheetScreenEdgePanGestureRecognizer` không tồn tại trên
iOS của máy, bản cũ câm hoàn toàn; bản gốc vẫn chạy nhờ đường 0.35 s.

## Cấu trúc

```
26Unlock/
  Tweak.xm              hook SpringBoard + kích hoạt hoạt ảnh (đã sửa logic)
  WaveEngine.m/.h       bộ sinh hoạt ảnh (toán học giống hệt bản gốc)
  WaveTable.m/.h        bảng sóng 4x6, delay
  WaveIcon.m/.h         model icon
  PrivateHeaders/       khai báo class riêng của SpringBoard
  Makefile              ARCHS = arm64 arm64e · rootless · min iOS 15.0
  control               com.blu-tek.26wave 0.0.2 · iphoneos-arm64
original.deb           tweak gốc của tác giả (arm64) — nguồn chân lý để đối chiếu
ANIMATION_FIX.md       đối chiếu các hằng số hoạt ảnh với binary gốc
DIAGNOSE.md            phân tích lỗi kích hoạt + cách khoanh vùng
```

## Build

Đẩy code lên nhánh `main` (hoặc chạy tay workflow) → Actions build bằng Xcode + theos:

```bash
git add -A && git commit -m "..." && git push
```

Artifact: `26Unlock-rootless-arm64e` (chứa `.deb`).

## Chẩn đoán trên máy

Tweak ghi log ra `/var/mobile/26Unlock.log` (mở bằng Filza). Mỗi lần mở khóa sẽ có
dòng `fire: wave played - N icons …`. Nếu không có gì → xem mục 5 trong
[DIAGNOSE.md](DIAGNOSE.md).
