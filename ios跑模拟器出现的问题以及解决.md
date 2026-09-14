# iOS 跑模拟器出现的问题以及解决

把已发布的 `gemstone-swift` 拉下来、编成一个能在 iOS 模拟器里跑的 App，
中间踩的坑和解法。**所有结论都标注了是实测还是推断。**

环境：macOS (Apple Silicon) · Xcode 26.5 · `2.114.10` · 2026-09-14

对照篇：[安卓跑apk出现的问题以及解决.md](安卓跑apk出现的问题以及解决.md)

---

## 0. 先说结论

最终两条链路都在模拟器里跑通了：

```
Gemstone lib version: 2.114.10          ← FFI 正向：Swift 调 Rust
https://httpbin.org/get?foo=bar
-> 200, 464 bytes                        ← 反向回调：Rust 调 Swift 实现的 AlienProvider
```

消费的是 **GitHub Releases 上已发布的 `gemstone-swift 2.114.10`**
（`swift package resolve` 下载 zip + 校验 checksum），
与 Android 侧消费已发布 AAR 是对等的验证强度。

一条命令复跑：

```bash
cd ~/Desktop/gem/GemIOSDemo && ./build.sh
```

---

## 1. 🔴 最大的坑：iOS 示例工程不是 App

本以为能照搬 Android 的做法——编现成示例、装进模拟器。但：

```
core/gemstone/tests/ios/
├── GemTest/
│   ├── Package.swift          ← 这是个 SwiftPM 库，不是 App
│   └── GemTest/
│       ├── GemTestApp.swift   ← 存在，但被 exclude 掉了
│       └── ContentView.swift
└── Packages/Gemstone/
    └── Sources/GemstoneFFI/
        └── shim.c             ← 只有这一个文件，绑定和 .a 都是 gitignore 的
```

`GemTest/Package.swift` 里写得很清楚：

```swift
products: [ .library(name: "GemTest", targets: ["GemTest"]) ],
targets: [
    .target(
        name: "GemTest",
        exclude: [ "Assets.xcassets", "GemTestApp.swift", "Preview Content" ],
        //                             ^^^^^^^^^^^^^^^^ App 入口被排除
```

### 与 Android 的不对称

| | Android | iOS |
|---|---|---|
| 示例形态 | **可运行的 App**（有 Activity、能出 APK） | **SwiftPM 库**（无 App target） |
| 依赖方式 | 可传参拉远端 AAR | 硬编码本地路径 `../Packages/Gemstone` |
| 能否直接跑 | ✅ `adb install` | ❌ 没有 `.app` 可装 |

> 📌 **`.xcodeproj` 的情况要说准**：仓库里是有的——`ios/Gem.xcodeproj`，
> 那是 gem 主 App（GPL-3.0，不能拿来做我们的基座）。
> 但 `core/gemstone/tests/ios/` 下**全历史都没有过** `.pbxproj`，
> 用 `git log --all --name-only -- "*.pbxproj"` 可验证。

### 解法：另建一个最小 Demo

新建 `~/Desktop/gem/GemIOSDemo`，直接依赖**已发布**的包：

```swift
dependencies: [
    .package(url: "https://github.com/weaver-max/gemstone-swift.git", exact: "2.114.10")
]
```

这比改造现有示例更有价值——现有示例走本地路径，**永远验证不到发布产物**。

---

## 2. 不用 Xcode 工程，手工构建 .app

机器上没装 XcodeGen / Tuist，而手写 `project.pbxproj` 是几百行带 UUID 的样板。

选择用 `swiftc` 手工编 + 组 bundle。**这不只是权宜之计**：
每一环（取包 → 编 module → 链接 → 装包）都显式可见，
哪一步出问题能精确定位，比 Xcode 黑盒更适合验证场景。

> 真实项目当然用 Xcode 工程 + SPM 依赖，本文的手工流程只服务于「验证发布产物」。

### 产物结构

```bash
swift package resolve
```

拉下来的东西：

```
.build/checkouts/gemstone-swift/Sources/Gemstone/Gemstone.swift    24,331 行（UniFFI 生成）
.build/artifacts/gemstone-swift/GemstoneFFI/GemstoneFFI.xcframework/
├── ios-arm64/                      真机切片
└── ios-arm64-simulator/            模拟器切片
    ├── libgemstone.a
    └── Headers/
        ├── GemstoneFFI.h
        └── module.modulemap
```

---

## 3. 🔴 `import Gemstone` 报 no such module

第一版把两个文件一起编：

```bash
swiftc ... "$GEN" App.swift -o build/GemIOSDemo
```

结果：

```
App.swift:2:8: error: no such module 'Gemstone'
```

**原因**：Swift 里一次编译的所有源文件属于**同一个 module**。
`Gemstone.swift` 和 `App.swift` 一起编就成了一个 module，
`App.swift` 再去 `import Gemstone` 自然找不到。

### 解法：拆成两步

```bash
# 第 1 步：Gemstone.swift 单独编成 module
swiftc -target "$TARGET" -sdk "$SDK" \
    -module-name Gemstone \
    -emit-module -emit-module-path build/Gemstone.swiftmodule \
    -emit-library -static -o build/libGemstoneSwift.a \
    -I "$XCF/Headers" \
    "$GEN"

# 第 2 步：App 链接它
swiftc -target "$TARGET" -sdk "$SDK" -parse-as-library \
    -I build -I "$XCF/Headers" \
    -L build -lGemstoneSwift \
    -L "$XCF" -lgemstone \
    App.swift -o build/GemIOSDemo
```

拆开后还有个附带好处：App 代码写的是真正的 `import Gemstone`，
和下游 iOS 开发者的写法一致，不是为了编过而特调的版本。

---

## 4. 我加了一堆没用的编译参数

第一版为了让 clang 找到 modulemap，加了：

```bash
-Xcc -fmodule-map-file="$XCF/Headers/module.modulemap"
-Xcc -isysroot -Xcc "$SDK"
```

后来做了对照实验：

| 参数组合 | 能否编过 | 产物 |
|---|:---:|---|
| 完全不带 `-Xcc` | ✅ | 21 M · IOSSIMULATOR · minos 17.0 |
| 只带 `-fmodule-map-file` | ✅ | 完全一致 |
| 两个都带 | ✅ | 完全一致 |

**三者产物完全等价，`-Xcc` 全是多余的。**

原因：`-I "$XCF/Headers"` 指向的目录里就有 `module.modulemap`，
clang 会自动发现同目录的 modulemap，不需要显式指定路径。

> 💡 **教训**：加参数解决问题后，要回头验证它是不是真的在起作用。
> 我这几个参数加上去「问题就没了」，但其实问题从来不是它们解决的。

---

## 5. 又踩了一次全角括号

```bash
step "安装并启动（$SIM_NAME）"
```

报错：

```
./build.sh: line 91: SIM_NAME）: unbound variable
```

bash 把全角 `）` 当成了变量名的一部分，`set -u` 下直接判定未定义。

**这是本项目第二次踩同一个坑** —— `scripts/preflight.sh` 里
`bad "$t 缺失（rustup target add $t）"` 是完全一样的问题。

```bash
# 错
step "安装并启动（$SIM_NAME）"
# 对
step "安装并启动（${SIM_NAME}）"
```

> 🔴 **规则：中文括号、引号紧跟变量时，一律写 `${VAR}` 显式界定。**
> 半角 `)` 不会有这个问题，所以只在中文文案里踩。

---

## 6. 一条消不掉但无害的警告

```
clang: warning: using sysroot for 'MacOSX' but targeting 'iPhone' [-Wincompatible-sysroot]
```

试过所有 `-Xcc` 组合都消不掉（见 §4 的对照表，三种组合都出现）。
是 swiftc 内部调用链接器驱动时带出来的，与脚本传的参数无关。

### 凭什么说它无害

不靠「看起来没事」，靠产物本身：

```bash
$ vtool -show-build-version build/GemIOSDemo
   platform IOSSIMULATOR      ← 不是 MACOS
      minos 17.0
        sdk 26.5

$ otool -L build/GemIOSDemo
   /System/Library/Frameworks/SwiftUI.framework/SwiftUI
   /System/Library/Frameworks/CFNetwork.framework/CFNetwork
   ...                        ← 全是 iOS 框架
```

### 与其压制警告，不如加自检

脚本里加了硬校验，真编错平台会直接失败退出：

```bash
vtool -show-build-version build/GemIOSDemo | grep -q "IOSSIMULATOR" \
    || { echo "error: 产物平台不是 IOSSIMULATOR" >&2; exit 1; }
```

> 把「警告」换成「断言」比把警告静音更安全 —— 静音之后真出问题就没人知道了。

---

## 7. iOS 模拟器没有 `adb input tap`

Android 那边可以：

```bash
adb shell input tap 156 168
```

`simctl` **没有对应命令**。可选路径：

| 方案 | 问题 |
|---|---|
| `osascript` 点击模拟器窗口 | 依赖辅助功能授权，坐标易漂 |
| XCUITest | 要建完整测试 target，太重 |
| **进页面自动跑一次** | ✅ 采用 |

```swift
.task { fetch() }   // 按钮保留，可手动重跑
```

反向回调走的是同一条代码路径，自动触发不降低验证强度，
反而让无人值守的验证成为可能。

---

## 8. 完整流程

```bash
cd ~/Desktop/gem/GemIOSDemo
./build.sh                    # 默认 iPhone 17
./build.sh "iPhone 17 Pro"    # 指定机型
```

脚本五步：

```
1. swift package resolve           拉已发布的包，校验 checksum
2. 编 Gemstone module              -emit-module + -emit-library -static
3. 编 App 并链接                    + vtool 平台自检
4. 组 .app bundle                  Info.plist + plutil -lint
5. simctl install / launch         自动 boot 模拟器
```

截图：

```bash
xcrun simctl io <UDID> screenshot /tmp/s.png
```

### 文件清单

```
~/Desktop/gem/GemIOSDemo/
├── Package.swift      依赖已发布的 gemstone-swift 2.114.10
├── App.swift          SwiftUI App + NativeProvider（AlienProvider 实现）
├── build.sh           五步构建脚本
└── .gitignore         忽略 .build/ 和 build/
```

---

## 9. 双端对照

| | Android | iOS |
|---|---|---|
| 消费的制品 | GitHub Packages 的 AAR | GitHub Releases 的 XCFramework |
| 是否需要鉴权 | ✅ 要（即使 public） | ❌ 不要 |
| 示例工程可用性 | ✅ 现成 App | ❌ 只有库，需自建 |
| 注入输入 | `adb shell input tap` | ❌ 无，改用自动触发 |
| 正向 FFI | ✅ 版本号上屏 | ✅ 版本号上屏 |
| 反向回调 | ✅ 200, 311 bytes | ✅ 200, 464 bytes |
| 遇到的真实 bug | ktor 3.0.0 CIO TLS | 无（问题都在构建姿势上） |

> 字节数不同是因为 httpbin 会回显 `User-Agent` 等请求头，
> 两端的 HTTP 客户端不同（Ktor vs URLSession），响应体自然不等长。

---

## 10. 方法论小结

**1. 先确认示例工程到底是什么形态。**
我默认 iOS 示例和 Android 一样是 App，直接开始找 `.xcodeproj`，
浪费了一轮。读 `Package.swift` 的 `products` 和 `exclude` 就能一眼看出来。

**2. 加参数解决问题后，要验证它是否真的在起作用。**
§4 那几个 `-Xcc` 加上去「问题消失了」，但对照实验证明产物完全等价——
问题根本不是它们解决的。不做对照就会把噪音当经验传下去。

**3. 同一个坑踩第二次，说明第一次只修了实例没提炼规则。**
全角括号在 `preflight.sh` 里修过一次，这次又中。
现在写成规则了：中文括号紧跟变量一律 `${VAR}`。

**4. 消不掉的警告，用断言替代静音。**
sysroot 警告压不下去，那就加 `vtool` 平台自检——
真出问题时会硬失败，比把警告静音安全。

**5. 环境能力不对等时，调整验证方式而不是降低标准。**
iOS 没有 `input tap`，改成自动触发，走的仍是同一条代码路径，
验证强度没打折。

---

*本文档由 AI 辅助整理，所有命令、报错、产物尺寸均为 2026-09-14 实测记录。*
