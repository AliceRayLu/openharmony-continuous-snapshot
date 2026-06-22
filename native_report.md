# Native Node-API 最终结论

## 结论

最开始的问题是：

> 在 DAYU200 + DevEco Studio 5.0.1 + OpenHarmony 5.0.1 / API 13 环境下，ArkTS 能否成功加载本地 Node-API 模块 `libentry.so`，并调用最小导出函数？

**最终答案：可以，已经调通。**

成功证据：
- 日志中出现：
  - `RegisterEntryModule invoked.`
  - `Init invoked.`
  - `GetVersion invoked.`
- 屏幕显示：
  - `getVersion() => hello from native`

这说明：
- `libentry.so` 已被成功加载
- Node-API 模块已成功注册
- ArkTS 已成功调用 native 导出函数

---

## 相比之前的尝试，最终真正起作用的关键点

### 1. 项目级配置必须改成 OpenHarmony 风格

之前如果还是 HarmonyOS 风格配置，例如：

```json5
"compatibleSdkVersion": "5.0.1(13)",
"runtimeOS": "HarmonyOS"
```

那么对 DAYU200 的 OpenHarmony 环境并不匹配。

最终需要改成：

```json5
"compileSdkVersion": 13,
"compatibleSdkVersion": 13,
"targetSdkVersion": 13,
"runtimeOS": "OpenHarmony"
```

注意：
- 不只是改 `runtimeOS`
- `compatibleSdkVersion` 也不能再用字符串 `"5.0.1(13)"`
- 切到 OpenHarmony 后，相关 SDK 字段要改成整数风格

---

### 2. 模块级 ABI 不能只打 `arm64-v8a`，要同时支持 `armeabi-v7a` 和 `arm64-v8a`

这是这次最终调通的**最关键变化**。

最终模块级配置是：

```json5
"abiFilters": [
  "armeabi-v7a",
  "arm64-v8a"
]
```

为什么这一步关键：
- 板子 CPU 虽然是 `aarch64`
- 但实际查到板端相关系统库（如 `libace_napi.z.so`）只有 **32 位 arm** 版本
- 之前如果只打 `arm64-v8a`，运行时会直接 `Load native module failed`
- 改成 `armeabi-v7a + arm64-v8a` 后，native 模块才真正被加载成功

注意：
- OpenHarmony 不允许 `armeabi-v7a` 单独作为唯一 ABI
- 所以不能只写：

```json5
"abiFilters": ["armeabi-v7a"]
```

必须至少同时带上：
- `arm64-v8a`
  或
- `x86_64`

在本次验证里，成功配置是：

```json5
"abiFilters": ["armeabi-v7a", "arm64-v8a"]
```

---

## 其他补充，但不是最核心原因

### 3. 命名要保持一致

下面几处名字要一致：
- CMake target：`entry`
- so 名：`libentry.so`
- `nm_modname`：`entry`
- ArkTS import：`libentry.so`

这些是必要条件，但**不是这次最终从失败到成功的最关键增量**。

### 4. native 日志很有帮助

在 native 侧加 constructor / Init / 导出函数日志，可以帮助判断：
- 是 loader 前失败
- 还是已经进入 native 代码

这一步主要用于定位问题，不是最终根因本身。

---

## 给原始项目 agent 的直接建议

如果原始项目还在报：

```text
ArkCompiler [GetNativeOrCjsExports:50] Load native module failed, so is @normalized:Y&&&libentry.so&
```

优先检查这两点：

1. **工程级 `build-profile.json5` 是否已经切到 OpenHarmony 风格**

```json5
"compileSdkVersion": 13,
"compatibleSdkVersion": 13,
"targetSdkVersion": 13,
"runtimeOS": "OpenHarmony"
```

2. **模块级 `build-profile.json5` 是否已经改成双 ABI**

```json5
"abiFilters": ["armeabi-v7a", "arm64-v8a"]
```

如果只能记住一个最关键点，那就是：

> **不要只打 `arm64-v8a`，要改成同时打 `armeabi-v7a` 和 `arm64-v8a`。**

---

## 最终一句话

这次最小 demo 已经证明：

> **DAYU200 是可以跑通本地 Node-API `libentry.so` 的。**

相比之前的尝试，最终真正让它成功的核心就是：

1. **改成 OpenHarmony 项目配置**
2. **ABI 改成 `armeabi-v7a + arm64-v8a` 双支持**
