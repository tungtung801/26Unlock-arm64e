# Vì sao bản arm64e không chạy và đã sửa gì

## 1. Build không phải là lỗi

Mổ `packages/com.blu-tek.26wave_0.0.1-174+debug_iphoneos-arm64.deb` (bản build cũ) ra kiểm tra:

| Kiểm tra | Kết quả |
|---|---|
| `26Unlock.dylib` | Mach-O **arm64e**, cpusubtype `0x80000002` (**PAC00**) ✅ |
| Chữ ký | `LC_CODE_SIGNATURE`, CodeDirectory v0x20400, ad-hoc ✅ |
| Đường dẫn | `var/jb/Library/MobileSubstrate/DynamicLibraries/` (rootless) ✅ |
| Filter plist | `Filter → Bundles → com.apple.springboard` ✅ |
| Hook có trong binary | `setState:`, `viewWillAppear:`, `viewDidDisappear:`, `hasAnimatedIconLayoutBefore`, `_shouldAnimateIconLaunch`, `setRootFolderViewControllerPresentationProgress:animated:completion:` ✅ |

→ Chuyển arm64e **đã xong**. Lỗi nằm ở logic chạy (runtime).

## 2. Lỗi thật sự: đảo ngược điều kiện kích hoạt

Bản `Tweak.xm` trong repo được dịch ngược lại từ binary gốc. Khi đối chiếu từng lệnh
(capstone, `26Unlock.dylib` trong `original.deb`), hai chỗ **trái ngược hoàn toàn**:

### Binary gốc (`original.deb`)

```
-[SBCoverSheetViewController viewWillAppear:]
    g_onLockScreen = 1;  g_panFired = 0;                    @0x61ec

-[UIGestureRecognizer setState:]   (chỉ nhận SBCoverSheetScreenEdgePanGestureRecognizer)
    Ended/Cancelled → g_lastVel = …, g_haveVel = 1,
                      g_panFired = 1, wave26_fire() NGAY   @0x60bc
    Possible        → chỉ đóng dấu thời gian                @0x60dc

-[SBCoverSheetViewController viewDidDisappear:]
    if (!g_onLockScreen) return;
    g_onLockScreen = 0;
    if (g_panFired) return;          ← pan đã chạy rồi thì thôi
    dispatch_after(0.35 s) → wave26_fire()   ← mở khóa KHÔNG quẹt
```

### Bản trong repo (sai)

```objc
if (!g_haveLastVel) return;          ← ngược lại: không có velocity thì BỎ CUỘC
dispatch_after(0.14 s)               ← 0.35 s trong binary (0x14DC9380 ns)
```

**Hậu quả:** `g_haveLastVel` chỉ thành `YES` khi hook `-setState:` gặp đúng class
`SBCoverSheetScreenEdgePanGestureRecognizer`. Nếu class này không tồn tại trên iOS của máy
(đổi tên/khác phiên bản) thì:

* hook gesture không bao giờ nhận diện được → `g_haveLastVel` mãi mãi `NO`;
* `viewDidDisappear:` cũng bỏ cuộc vì chính cái gate đó;

→ **tweak câm hoàn toàn, không bao giờ có hoạt ảnh**. Bản gốc thì khác: đường
0.35 s của nó tồn tại *chính để* lo trường hợp này (mở khóa bằng Face ID/mật mã,
hoặc không tìm thấy class pan), nên vẫn chạy.

Và đúng: `original.deb` (arm64) không chạy trên A12 là **chuyện bình thường** —
không inject được dylib arm64 vào SpringBoard arm64e. Không suy ra được gì từ việc đó.

## 3. Những gì đã sửa trong `26Unlock/Tweak.xm`

1. **Trả lại đúng logic gốc**: pan kết thúc → `wave26_fire()` ngay lập tức;
   màn hình khóa biến mất mà chưa có pan → fire sau **0.35 s**.
2. **Thêm đường dự phòng Darwin notify** `com.apple.springboard.lockstate`
   (state `0` = đã mở khóa): hoạt ảnh vẫn chạy ngay cả khi mọi lookup class
   SpringBoard đều trượt.
3. **Fallback tìm class pan**: `SBCoverSheetPanGestureRecognizer`, rồi
   `SBScreenEdgePanGestureRecognizer` (chỉ nhận cạnh dưới + đang ở màn hình khóa).
4. **`allWindows()` an toàn hơn**: duyệt `UIApplication.connectedScenes →
   UIWindowScene.windows` (iOS 13+) trước, rồi mới tới `UIApplication.windows`
   (deprecated — có bản iOS trả về rỗng), cộng `keyWindow`.
   Nếu vẫn không thấy icon → thử đi từ `SBIconController.sharedInstance.view`.
5. **Dock**: thử `- [SBIconController dockView]` nếu không quét được `SBDockView`.
6. **Retry**: chưa thấy `SBIconView` thì thử lại 3 lần cách nhau 0.12 s.
7. **Ghi log** ra `/var/mobile/26Unlock.log` (tự xoay khi > 200 KB) — nếu vẫn lỗi,
   mở file này bằng Filza gửi cho mình là biết ngay.

Phần toán hoạt ảnh (`WaveEngine.m`, `WaveTable.m`, cách tính cột/hàng, hằng số
`-1250`, `300`, `(1.5, 2.5)`…) **không đụng vào**.

## 4. Build & cài

```bash
git add -A && git commit -m "fix: restore original firing logic + arm64/arm64e" && git push
```

GitHub Actions (tab **Actions → Build 26Unlock → Run workflow**) sẽ build bằng
Xcode 16.4 + theos, ra artifact `26Unlock-rootless-arm64e`.

Package bây giờ chứa **cả hai slice `arm64` + `arm64e`** (dyld tự chọn), deployment
target hạ xuống **iOS 15.0**, version `0.0.2`.

Trên máy A12 (Dopamine 2):

1. Mở app **Dopamine → Settings → bật "Tweak Injection"** (và đã cài **ElleKit**).
2. Cài deb bằng Sileo.
3. Respring.

## 5. Nếu vẫn không chạy — khoanh vùng trong 2 phút

Việc đầu tiên: **cài thử một tweak bất kỳ từ repo rootless** (vd. một tweak đổi text
status bar). Nếu tweak đó cũng không chạy → vấn đề nằm ở injection (Dopamine/ElleKit),
không phải ở 26Unlock.

Nếu tweak khác chạy bình thường, mở **Filza → `/var/mobile/26Unlock.log`** và gửi mình
nội dung. Log sẽ cho biết ngay:

* Không có dòng `==== 26Unlock loaded ====` → **dylib không được inject** (injection/lỗi load).
* Có `MISSING` ở các class → iOS đó đổi tên class.
* Có `unlock pan ended` / `lockstate = 0` nhưng không có `wave played`, hoặc có dòng
  `no icon views yet` → vấn đề ở khâu tìm icon.

---

## Cập nhật 0.0.3 (2026-09-16)

### ✅ Đã chạy trên roothide A9 / iOS 15
Bản 0.0.2 đã có hiệu ứng trên máy A9 (roothide, iOS 15) → phần sửa logic kích hoạt
**đã đúng**. Vậy vấn đề còn lại trên A12 (iOS 16.5.1) là **khác biệt phiên bản iOS**,
không còn là chuyện arm64/arm64e nữa (cùng 1 deb, 2 slice, chạy được trên A9).

### 🐛 Bug thanh dock giật — đã fix
Triệu chứng: dock "hiện lên luôn" thay vì trượt mượt từ dưới lên.

Binary gốc, `-[WaveEngine animateDock:]`:

```
0x9e90  ldr d2, [0xb5e0]        ; 380.0
0x9e98  fadd d1, d1, d2         ; y + 380
0x9f08  ldr d0/d1 <- (x, y+380) -> valueWithCGPoint: -> setFromValue:   ← BẮT ĐẦU ở dưới
0x9f44  ldr d0/d1 <- vị trí gốc -> valueWithCGPoint: -> setToValue:     ← KẾT THÚC tại chỗ cũ
```

Repo đang để ngược (`from = gốc, to = +380`) → dock trượt **xuống** rồi giật ngược lại.
Đã đổi lại `fromValue = (x, y+380)`, `toValue = original` trong `26Unlock/WaveEngine.m`.

### ➕ Thêm đường kích hoạt thứ 4 (dự phòng cho iOS 16)
`setRootFolderViewControllerPresentationProgress:animated:completion:` khi
`progress >= 1.0` và vừa rời màn hình khóa trong vòng 2.5 s → fire sau 0.35 s.
(Có cửa sổ thời gian nên đóng app về home screen sẽ không bị chạy nhầm.)

### ❓ A12 / iOS 16.5.1 vẫn im lặng — cần log
Có 4 đường kích hoạt rồi nên nếu vẫn không có gì, khả năng cao **dylib không được
inject**. Cách biết ngay: sau khi cài + respring, mở **Filza → `/var/mobile/26Unlock.log`**.

* **Không có file** → dylib chưa bao giờ chạy → lỗi injection (Dopamine/ElleKit),
  không phải lỗi code.
* **Có file** → gửi nội dung, log chỉ rõ thiếu class nào / có thấy icon không.

---

## 🎯 Nguyên nhân cuối cùng trên A12 / iOS 16.5.1 (bản 0.0.4)

Kiểm tra trên máy: dylib + plist nằm đúng chỗ, Tweak Injection bật, tweak
SpringBoard khác chạy bình thường — **nhưng `/var/jb/Library/Frameworks/CydiaSubstrate.framework` không tồn tại**.

Mà dylib của chúng ta có:

```
LC_LOAD_DYLIB   @rpath/CydiaSubstrate.framework/CydiaSubstrate
LC_RPATH        /var/jb/Library/Frameworks
LC_RPATH        /var/jb/usr/lib
LC_RPATH        @loader_path/.jbroot/Library/Frameworks
LC_RPATH        @loader_path/.jbroot/usr/lib
```

→ `dlopen()` thất bại **trước khi constructor chạy** ⇒ không log, không hiệu ứng,
trông như "cài rồi mà chết". Đây là lý do bản 0.0.1/0.0.2 im lặng trên A12 dù
build arm64e hoàn toàn đúng.

**ElleKit trên Dopamine 2 (iOS 16) không cài `CydiaSubstrate.framework`**, chỉ có
`/var/jb/usr/lib/libsubstrate.dylib`. Các tweak khác chạy được vì chúng không
phụ thuộc framework đó.

### Cách sửa: không dùng Substrate nữa

* `Makefile`: bỏ `26Unlock_LIBRARIES = substrate`.
* `Tweak.xm`: bỏ toàn bộ Logos `%hook/%ctor/%orig` (`MSHookMessageEx`), thay bằng
  swizzle thuần Objective-C runtime: `class_getInstanceMethod` →
  `class_addMethod` (nếu kế thừa) / `class_replaceMethod`, lưu IMP gốc để gọi lại.

Dylib bây giờ chỉ phụ thuộc UIKit / QuartzCore / CoreGraphics / Foundation →
**load được trên mọi loại jailbreak** (Dopamine rootless, roothide, palera1n),
không cần bất kỳ thư viện hook nào.

Log sẽ ghi rõ từng hook có gắn được không, ví dụ:

```
hook UIGestureRecognizer setState: = 1
hook SBIconController hasAnimatedIconLayoutBefore = 1
hook SBIconController presentationProgress = 0     ← 0 = iOS này không có method
```

---

## 🧩 Vì sao A12 vẫn chết dù đã bỏ Substrate (bản 0.0.5 / roothide)

Ảnh Filza trên máy A12 cho thấy trong
`/var/jb/Library/MobileSubstrate/DynamicLibraries/`:

```
26Unlock.dylib                  203 KB
26Unlock.plist                  308 byte
26Unlock.dylib.roothidepatch    100 byte   lrwxr-xr-x   ← SYMLINK
```

Theo `roothide/DynamicPatches`: roothide tạo **symlink đuôi `.roothidepatch`**
cho mọi mach-o còn chứa chuỗi `/var/jb`, symlink này trỏ tới **module vá động**
(PatchLoader nạp module đó *trước* TweakLoader). Module vá hoạt động theo
**địa chỉ lệnh + thanh ghi**:

> "we can make a patch list of all instruction addresses and registers"

Dylib của ta là **fat (arm64 + arm64e)**:

| Máy | Slice được nạp | Module vá | Kết quả |
|---|---|---|---|
| A9 (arm64, iOS 15) | arm64 | vá đúng địa chỉ | chạy ngon ✅ |
| A12 (arm64e, iOS 16.5.1) | arm64e | **vá sai địa chỉ** | không load ❌ |

Nguyên nhân gốc của chuỗi `/var/jb` nằm ở 2 rpath do theos rootless tự thêm
(`vendor/mod/rootless/instance/rules.mk`):

```make
_THEOS_INTERNAL_LDFLAGS += -rpath $(THEOS_PACKAGE_INSTALL_PREFIX)/Library/Frameworks  # /var/jb/...
_THEOS_INTERNAL_LDFLAGS += -rpath $(THEOS_PACKAGE_INSTALL_PREFIX)/usr/lib             # /var/jb/...
```

### Cách sửa: build gói roothide bằng roothide/theos

Theo `roothide/Developer`, với tweak không dùng file API để truy cập file
jailbreak (26Unlock chỉ ghi `/var/mobile/26Unlock.log`, ngoài jbroot) thì chỉ
cần:

```bash
# cài roothide/theos (tương thích 100% theos gốc)
bash -c "$(curl -fsSL https://raw.githubusercontent.com/roothide/theos/master/bin/install-theos)"
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide ARCHS="arm64 arm64e"
```

→ kiến trúc gói thành `iphoneos-arm64e`, dylib **không còn chuỗi `/var/jb`** ⇒
roothide **không tạo `.roothidepatch`** ⇒ không có module vá ⇒ nạp sạch trên cả
arm64 lẫn arm64e.

Workflow mới: `.github/workflows/build-roothide.yml` (artifact `26Unlock-roothide`),
có bước kiểm tra `strings ... | grep -c "/var/jb"` phải ra **0**.
