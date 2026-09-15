# Sửa hoạt ảnh 26Unlock cho khớp bản gốc

**Repo:** `26Unlock-arm64e` · **Gốc đối chiếu:** `original.deb` trong repo (bản tweak gốc, dylib arm64, minos 16.0)
**Phương pháp:** dịch ngược `26Unlock.dylib` gốc (Objective-C metadata + `__TEXT,__const` + disassembly arm64) rồi đối chiếu từng hằng số / từng bước tính với source.

> ⚠️ `26Unlock_original` **không** phải bản dịch ngược trung thực — binary bác bỏ nhiều giá trị trong đó.
> Chỉ `original.deb` là chân lý. (Toolkit `/home/user/animation-restore/` vì vậy **không** dùng được cho hoạt ảnh.)

---

## 1. Năm lỗi đã tìm ra và sửa

| # | Lỗi | Trong repo (sai) | Binary gốc | Ảnh hưởng |
|---|-----|------------------|------------|-----------|
| 1 | `position.fromValue` / `toValue` **bị đảo** | `from = original`, `to = target` | `from = target`, `to = original` | **Lỗi chính.** Mỗi icon bị bắn ra xa 800 pt rồi bật ngược về → icon dính/lệch chỗ, giật |
| 2 | Dấu `halfDeltaX` | `(left − right) * 0.5` → **âm** | `(right − left) * 0.5` → **dương** | 2 cột giữa (sóng 1) **hoán đổi vị trí cho nhau**: `col==1 → center − d`, còn lại `center + d` |
| 3 | `stiffness` sóng 1–3 | `150.0` | `300.0` | 12 icon giữa quá mềm → trôi/giật thay vì bật vào nhanh |
| 4 | `WaveTable.center` | `(1.5, 2.0)` | **`(1.5, 2.5)`** | Sai khoảng cách lưới → sai hệ số `stretch = 4.5 + 2.1(1−f)` → biên độ bay ra sai |
| 5 | Vận tốc mặc định | `0.0` | **`−1250.0`** | `damping = 42 − 8·min(1,|v|/2500)`: 42.0 thay vì 38.0 → độ tắt khác gốc |

### Thêm: cách gán cột/hàng (`wave26_registerHome`)

Repo cũ dùng **chỉ số mảng**: `col = index % 4`, `row = MIN(index / 4, 5)`.
Binary gốc **không** dùng chỉ số — nó hình học hoá:

```
frame = [view convertRect:view.bounds toView:nil]      // toạ độ window
if (CGRectIsNull(frame) || CGRectIsEmpty(frame)) skip;  // + bỏ icon ở dải dock
minX/maxX/minY/maxY  = bbox của TÂM các icon còn lại
cellW = MAX(1.0, maxX - minX) / 4.0                     // 0x270
cellH = MAX(1.0, maxY - minY) / 6.0                     // 0x268
col = clamp((NSInteger)((midX - minX) / cellW), 0, 3)   // 0x7928-0x7960
row = clamp((NSInteger)((midY - minY) / cellH), 0, 5)   // 0x7964-0x799c
```

Chia `/4` và `/6` **cố tình vượt 1 ô** ở cột/hàng cuối (toạ độ tâm → 0, 1.33, 2.67, **4.0**); chính phép **kẹp (clamp)** mới đưa về `3` và `5`. Đây là lý do không được bỏ clamp.

### Bảng sóng & các hằng số khác (đã xác nhận là **đúng**, không cần sửa)

```
kWaveMap[row][col] = 8 7 7 8 / 6 4 4 6 / 3 1 1 3 / 2 1 1 2 / 3 1 1 3 / 5 4 4 5
microOffset = 0.015 khi row==1 && (col==0 || col==3)
delay = wave==0 ? 0 : (wave−1)·interval + micro − (wave≥4 ? 0.055 : 0)
damping:  42 − 8·n   (wave 1..3)   |   26 − 2.1·n  (còn lại),  n = min(1, |v|/2500)
mass 1.5 · initialVelocity 12.0 · spring dock: 380.0 / 22.0 / 115.0 / 1.5 / 0.0
horizontalFly: ±0.8 theo `original.x ≥ screenMidX`, chia 150.0 · đẩy ra 800.0
stretch 4.5 + 2.1·(1 − f),  f = min(1, hypot(col+0.5−1.5, row+0.5−2.5) / 3.0)
row == 5 → zPosition = −1 · waveInterval = 0.055
```

---

## 2. File đã sửa (chỉ file hoạt ảnh)

| File | Sửa gì |
|------|--------|
| `26Unlock/WaveEngine.m` | đảo `fromValue`/`toValue`; dấu `halfDeltaX`; `stiffness` 150→300; sửa comment center |
| `26Unlock/WaveTable.m` | `center` → `(1.5, 2.5)` |
| `26Unlock/Tweak.xm` + `Tweak.xm` (bản sao ở repo root) | `registerHome` hình học; vận tốc mặc định `−1250.0` |
| `tools/check-animation-truth.sh` | script tự kiểm tra 32 điểm so với binary |
| `PATCH_ANIMATION_FIX.diff` | patch để `git apply` |

**Không** đụng tới hook, `WaveIcon`, Makefile, control, plist → build arm64e rootless vẫn nguyên.

---

## 3. Kiểm tra & build

```bash
bash tools/check-animation-truth.sh          # 32 PASS / 0 FAIL

THEOS=/path/theos PATH=$THEOS/toolchain/linux/iphone/bin:$PATH \
  make -C 26Unlock package FINALPACKAGE=1
```

Kết quả build tại chỗ:

* `26Unlock/packages/com.blu-tek.26wave_0.0.1-174+debug_iphoneos-arm64.deb`
  sha256 `e99130bbf2f87777c034c52a3880ced598f4e7d00ae98276f904cc0852217b6c`
* payload: `var/jb/Library/MobileSubstrate/DynamicLibraries/26Unlock.dylib` (70128 B, **Mach-O arm64e, caps PAC00**) + `26Unlock.plist` (`Filter→Bundles→com.apple.springboard`)
* Control: `com.blu-tek.26wave` · `iphoneos-arm64` · `0.0.1-174+debug`

---

## 4. Còn lại / chưa xác minh

* **Chưa thử trên máy** — mọi kết luận ở trên là từ disassembly + build, không phải từ iPhone.
* Hai hằng số trong binary **0.9** (0x6730, 0x7370) dùng cho bộ lọc "icon nằm trong 90% chiều cao khung" (dải dock).
  Bản này thay bằng `isInDock(...)` sẵn có + kiểm tra frame hợp lệ — hiệu ứng tương đương trên lưới 4×6 đầy đủ.
* Giá trị `−inf/+inf` (khởi tạo min/max) đã dùng đúng qua `INFINITY/-INFINITY`.
