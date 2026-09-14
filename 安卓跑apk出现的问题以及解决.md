# 安卓跑 APK 出现的问题以及解决

把 `core/gemstone/tests/android/GemTest` 这个示例工程编成 APK、装进模拟器跑起来，
中间踩的坑和最终的解法。**所有结论都标注了是实测还是推断**，没有验证的地方会明说。

环境：macOS (Apple Silicon) · `2.114.10` · 2026-09-14

---

## 0. 先说结论

| 阶段 | 结果 |
|---|:---:|
| 模拟器环境搭建 | ✅ 通 |
| APK 安装 | ✅ 通 |
| App 启动 + FFI 正向调用 | ✅ 通 |
| Fetch Data 反向回调 | ✅ 通（修了一个 ktor 的坑） |
| 构建过程本身 | ⚠️ 网络抖动，靠重试过的 |

最终两条链路都验证通了：

```
屏幕显示  Gemstone lib version: 2.114.10          ← FFI 正向：Kotlin 调 Rust
logcat    [NativeProvider] https://httpbin.org/get?foo=bar -> 200, 311 bytes
          request ok                               ← 反向回调：Rust 调 Kotlin
```

> 编译期的四个坑（401 / `AlienResponse` 无 getter / `jvmTarget` / `compileSdk`）
> 不在本文范围，见 [开发前的任务清单.md](开发前的任务清单.md) 的 E10 小节。
> 本文只讲**编出来之后怎么跑起来**。

---

## 1. 模拟器环境：三个组件缺两个

`adb` 有，但 `emulator` 和系统镜像都没装。

```bash
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
SDKM="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"

yes | "$SDKM" --install "emulator" "system-images;android-35;google_apis;arm64-v8a"
```

**镜像选型**：

| 要素 | 取值 | 原因 |
|---|---|---|
| API | `android-35` | ≥ `minSdk 28`，且本地 `platforms/android-35` 已有 |
| ABI | `arm64-v8a` | Apple Silicon，用 x86 镜像会走模拟转译，很慢 |
| tag | `google_apis` | 不需要 Play 商店，`google_apis` 够用且体积小 |

实测磁盘占用 **4.9 GB**（`emulator` 1.1 G + 系统镜像 3.8 G）。

> 💡 不要选 `android-37`：Android 37 起是 major.minor 方案，
> 模拟器镜像和 `platforms` 的版本对应关系更绕，没必要在验证环节引入变量。

---

## 2. 建 AVD：一个可以忽略的报错

```bash
"$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager" \
  create avd -n GemTest -k "system-images;android-35;google_apis;arm64-v8a" -d pixel_7
```

会报：

```
Error: Could not load devices from .../arm64-v8a/devices.xml
```

**但 AVD 实际已经建出来了** —— `emulator -list-avds` 能看到 `GemTest`。

`-d pixel_7` 是设备画像（分辨率、密度等），命令行工具包里没带 `devices.xml`，
所以加载失败。默认值本身是合理的（1080×2400 / 420dpi），不影响使用。

### 🔴 我在这里制造了一个新问题

看到报错后我手贱往 `config.ini` 追加了一遍屏幕参数：

```bash
cat >> ~/.android/avd/GemTest.avd/config.ini <<'EOF'
hw.lcd.width=1080
hw.lcd.height=2400
...
EOF
```

结果发现**原本就已经有这些 key 了**，追加造成重复键。`config.ini` 是
`key=value` 的扁平格式，重复键的行为不保证。

清理方式（保留每个 key 首次出现的那条）：

```bash
CFG=~/.android/avd/GemTest.avd/config.ini
awk -F= '!/^$/ && !seen[$1]++' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"
```

**教训**：改配置前先 `grep` 一下有没有，别看见报错就往里塞。

---

## 3. 启动与安装：顺利

```bash
ADB="$ANDROID_HOME/platform-tools/adb"

# 启动（后台）
nohup "$ANDROID_HOME/emulator/emulator" -avd GemTest \
      -no-snapshot-load -gpu auto > /tmp/emulator.log 2>&1 &

# 等开机真正完成 —— wait-for-device 只等到 adb 可连，不等于系统起来了
"$ADB" wait-for-device
until [ "$("$ADB" shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done

"$ADB" install -r app/build/outputs/apk/debug/app-debug.apk
```

> ⚠️ `adb wait-for-device` 返回 ≠ 系统可用。必须再轮询 `sys.boot_completed`，
> 否则 `install` 会遇到各种莫名其妙的失败。

---

## 4. 验证 FFI 真的通了

启动 App 后，**不要只看屏幕**，要看 `nativeloader` 的日志：

```bash
"$ADB" shell am start -n com.example.gemtest/.MainActivity
"$ADB" logcat -d | grep -iE "gemstone|UnsatisfiedLink|FATAL"
```

期望看到：

```
nativeloader: Load .../lib/arm64-v8a/libgemstone.so    using ns clns-7 ... : ok
nativeloader: Load .../lib/arm64-v8a/libjnidispatch.so using ns clns-7 ... : ok
```

屏幕上则是：

```
Gemstone lib version: 2.114.10
```

**这个字符串的价值在于它不是硬编码的** —— 来自 `libVersion()`，是一次真实的
Rust 调用。它同时证明了三件事：`.so` 被加载、JNA 桥接可用、UniFFI 绑定正确。

### 分清三种「成功」

| 现象 | 证明了什么 | 不能证明什么 |
|---|---|---|
| Gradle 编译通过 | 坐标能解析、API 签名对得上 | `.so` 有没有被打进包 |
| APK 里有 `.so` | 打包正确 | 运行时能不能加载 |
| **`nativeloader ... : ok` + 版本号上屏** | **真的跑通了** | — |

前两条我在发布验收里已经查过，这一轮补上的是第三条。

---

## 5. 🔴 Fetch Data 必崩 —— 走了一次弯路

点按钮直接闪退：

```
FATAL EXCEPTION: main
java.io.EOFException: Not enough data available
  at io.ktor.utils.io.ByteReadChannelOperationsKt.readByte(ByteReadChannelOperations.kt:48)
  at io.ktor.utils.io.ByteReadChannelOperationsKt$readByte$1.invokeSuspend
  ...
```

**关键观察：整个堆栈里没有任何 `gemstone` / `uniffi` 帧**，
崩在 Ktor 读响应体的过程中，还没走到 FFI 边界。所以第一时间可以排除 AAR 的问题。

### 错误的第一假设：模拟器 DNS

查网络时看到：

```
$ adb shell ping -c 2 httpbin.org
2 packets transmitted, 0 received, 100% packet loss
```

宿主机同一个地址是 HTTP 200。于是判断是模拟器 DNS 挂了，带显式 DNS 重启：

```bash
emulator -avd GemTest -dns-server 8.8.8.8,1.1.1.1 ...
```

DNS 确实通了，**但 App 照崩不误**。假设被推翻。

> 🔴 **模拟器里的 `ping` 不能当网络测试用。**
> 仔细看输出：`0.000 rtt` 加 `+1 duplicates` —— 这是模拟器的伪 ICMP 响应，
> 和真实网络可达性没有关系。用它做判断会把人带偏。

### 真正的原因：Ktor 3.0.0 的 CIO 引擎

```groovy
implementation("io.ktor:ktor-client-core:3.0.0")
implementation("io.ktor:ktor-client-cio:3.0.0")
```

CIO 引擎用的是 **Ktor 自研的 TLS 实现**（不像 OkHttp 引擎那样复用系统栈），
3.0.0 那版走 HTTPS 有问题。升到 3.5.2：

```groovy
implementation("io.ktor:ktor-client-core:3.5.2")
implementation("io.ktor:ktor-client-cio:3.5.2")
```

实测通过：

```
I System.out: Kotlin <> Rust
I System.out: [NativeProvider] https://httpbin.org/get?foo=bar -> 200, 311 bytes
I System.out: request ok
```

### 归因为什么是可靠的

中间改过两样东西（DNS 和 ktor 版本），容易混淆功劳。但：

**DNS 改完之后单独测过一次，仍然崩。** 所以修好它的确定是 ktor 升级，
不是两个改动叠加生效。排查时保留这种「单变量验证」的中间步骤很重要。

已提交：`a9312af2d7`

---

## 6. 构建过程的网络抖动 —— 一个我没查出根因的问题

升 ktor 时构建连续失败：

```
Could not resolve io.ktor:ktor-client-core:3.5.2
  > Remote host terminated the handshake
```

而且 **Maven Central、`dl.google.com`、GitHub Packages 三家同时挂**。

### 假设与验证过程

| 假设 | 怎么测的 | 结果 |
|---|---|:---:|
| 网络整体不通 | 宿主机 curl 同一个 URL | ❌ 直连 12/12 成功 |
| SOCKS 代理不稳 | 走代理 vs 直连 各 12 次 | ⚠️ 代理 9/12，**确实不稳** |
| **代理导致 Gradle 失败** | 查 daemon 的 `-D*proxy` 参数 | ❌ **Gradle 无代理参数** |
| Java 自动读 `http_proxy` | 打印三个 proxy 系统属性 | ❌ 全是 `null` |
| 并发握手打爆隧道 | 并发 20 条 TLS 握手 | ❌ 20/20 成功 |

**所以代理虽然不稳，但 Gradle 压根不走它** —— 这个解释被自己的证据推翻了。

### 唯一还站得住的线索

主机有 VPN 在跑，`utun4` 持有默认路由：

```
default            192.168.1.1        UGScg       en0
default            link#25            UCSIg       utun4     ← VPN

utun4: flags=8051<UP,POINTOPOINT,RUNNING,MULTICAST> mtu 1210
```

**两次观测之间 MTU 从 1215 变成了 1210** —— 说明 VPN 当时在重新协商。
构建失败集中在那个窗口，之后再没复现。三家仓库同时挂也更像链路层抖动，
而不是某个仓库出问题。

> ⚠️ **这是推断，不是证明。** 我事后无法复现，也就无法证实。
> 写在这里是为了留下线索，不是给出结论。

### 实际的应对

重试。后台跑 10 轮，**第 3 次就过了**：

```bash
NET="-Dorg.gradle.internal.repository.max.retries=10"
NET="$NET -Dorg.gradle.internal.repository.initial.backoff=2000"
NET="$NET -Dorg.gradle.internal.http.connectionTimeout=120000"
NET="$NET -Dorg.gradle.internal.http.socketTimeout=120000"

for i in $(seq 1 10); do
  ./gradlew --quiet $NET -PgemstoneVersion=2.114.10 assembleDebug && break
  sleep 8
done
```

`scripts/release.sh` 里已经内置了同样的重试参数。

想更稳的话，构建前临时关掉 VPN，或把这三个域名加进 VPN 的分流白名单。

---

## 7. 完整复现步骤

```bash
export ANDROID_HOME="/opt/homebrew/share/android-commandlinetools"
SDKM="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDM="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
ADB="$ANDROID_HOME/platform-tools/adb"
EMU="$ANDROID_HOME/emulator/emulator"

# 1. 装模拟器与镜像（实测占 4.9 GB）
yes | "$SDKM" --install "emulator" "system-images;android-35;google_apis;arm64-v8a"

# 2. 建 AVD（devices.xml 的报错可忽略）
echo no | "$AVDM" create avd -n GemTest -k "system-images;android-35;google_apis;arm64-v8a"

# 3. 启动并等真正开机完成
nohup "$EMU" -avd GemTest -no-snapshot-load -gpu auto > /tmp/emulator.log 2>&1 &
"$ADB" wait-for-device
until [ "$("$ADB" shell getprop sys.boot_completed | tr -d '\r')" = "1" ]; do sleep 5; done

# 4. 编 APK（需要 GitHub Packages 凭据）
cd core/gemstone/tests/android/GemTest
GITHUB_PACKAGES_REPO="weaver-max/wallet" \
GITHUB_ACTOR="$GITHUB_ACTOR" GITHUB_TOKEN="$GH_TOKEN" \
  ./gradlew -PgemstoneVersion=2.114.10 assembleDebug

# 5. 装 + 跑
"$ADB" install -r app/build/outputs/apk/debug/app-debug.apk
"$ADB" logcat -c
"$ADB" shell am start -n com.example.gemtest/.MainActivity

# 6. 验证 .so 加载
"$ADB" logcat -d | grep -E "libgemstone|UnsatisfiedLink|FATAL"

# 7. 点 Fetch Data 测反向回调（坐标按 1080×2400 屏）
"$ADB" shell input tap 156 168
sleep 8
"$ADB" logcat -d | grep -E "System.out|FATAL"

# 8. 截图
"$ADB" shell screencap -p /sdcard/s.png && "$ADB" pull /sdcard/s.png /tmp/gemtest.png
```

---

## 8. 排查方法上的几点总结

**1. 先看堆栈里有没有你关心的那一层。**
Fetch Data 崩溃的堆栈全是 ktor 的，一眼就能排除 AAR 的嫌疑，
省掉了在 FFI 层空转的时间。

**2. 环境里的诊断工具未必可信。**
模拟器的 `ping` 返回 `0.000 rtt` 和 `+1 duplicates`，是伪造的响应。
拿它判断网络会直接把排查方向带歪。

**3. 改多个变量后，要保留单变量验证的中间结果。**
DNS 和 ktor 版本都改了，但因为 DNS 改完单独测过一次仍崩，
才能确定是 ktor 的功劳。

**4. 假设被自己的证据推翻时，要认。**
「代理不稳」是真的（9/12），但 Gradle 不走代理也是真的。
两个事实摆在一起，前者就不能用来解释后者。

**5. 查不出根因时，标明「这是推断」。**
VPN 的 MTU 波动只是线索，没复现出来就不能写成结论。

---

*本文档由 AI 辅助整理，所有命令与报错均为 2026-09-14 实测记录。
标注「推断」的部分未经证实，后续复现到请补充。*
