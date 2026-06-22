# Node-API verification task for a fresh OpenHarmony project

## Goal
Create a brand-new **minimal OpenHarmony / HarmonyOS Stage project** in **DevEco Studio 5.0.1** and verify one very specific thing:

> Can ArkTS successfully load a local Node-API native module (`libentry.so`) and call a trivial exported function like `getVersion()` on a **DAYU200 development board**?

This is **not** a feature task and **not** a recording task. It is an environment / integration verification task.

---

## Why this verification is needed
In the existing project, we repeatedly failed at the exact same runtime step when loading a local native Node-API module from ArkTS.

The current failure is:

- `ArkCompiler [GetNativeOrCjsExports:50] Load native module failed, so is @normalized:Y&&&libentry.so&`
- ArkTS side then sees native module import as undefined/default export missing

Even after reducing the native bridge to a **minimal C implementation** with only one function (`getVersion()`), the same failure still occurs.

That means we need a clean-room validation in a fresh project to answer:

1. Is the problem caused by the current project structure/configuration?
2. Or does the DAYU200 + current system image + DevEco/SDK environment fail to load even a minimal local Node-API module?

---

## Current environment facts
- Device: **DAYU200 development board**
- IDE: **DevEco Studio 5.0.1**
- Intended SDK/API line: **OpenHarmony 5.0.1 / API 13**
- We already tried DevEco 5.0.2 before; switching to 5.0.1 did **not** change the runtime failure

---

## What has already been validated in the old project
These are important because they reduce the search space.

### Already true in the old project
- Native build is connected through module-level `entry/build-profile.json5` using:
  - `externalNativeOptions.path = ./src/main/cpp/CMakeLists.txt`
- The native shared library is actually built and packaged
- The final HAP contains:
  - `libs/arm64-v8a/libentry.so`
- Loader metadata recognizes the local `.so` dependency
- `pkgContextInfo.json` and `loader.json` both include `libentry.so`
- The built `libentry.so` contains key symbols such as:
  - `napi_register_module_v1`
  - `InitScreenRecorderModule`
  - native constructor symbol
- We reduced the native implementation to a minimal Node-API module written in C
- The minimal module exports only one function:
  - `getVersion(): string`

### But runtime still fails
Despite all that, runtime still reports:

- `ArkCompiler [GetNativeOrCjsExports:50] Load native module failed, so is @normalized:Y&&&libentry.so&`

And importantly:
- none of our native constructor / registration logs ever appear
- which strongly suggests the failure happens **before execution enters our native module code**

---

## Important conclusion from previous work
The old project is no longer a good place to keep guessing.

We now need a **fresh minimal project** that is as close as possible to an official / canonical local Node-API integration example.

This fresh project should help determine whether:
- the environment itself is broken / unsupported, or
- the old project differs from the canonical template in some crucial way

---

## Task to perform in the fresh project
Please create a brand-new minimal project and wire in a local Node-API module with the smallest possible surface area.

### The project should contain only:
1. A simple ArkTS page with:
   - one button
   - one status/result text area
2. A local native module `libentry.so`
3. One exported function from native:
   - `getVersion()` returning a fixed string, for example:
     - `"hello from native"`
4. ArkTS code that imports `libentry.so` and calls `getVersion()` when the button is pressed

---

## Desired native side shape
Please prefer the most minimal and standard approach possible.

### Native side requirements
- Use module name / target name aligned with `libentry.so`
- Prefer canonical Node-API registration shape for Harmony/OpenHarmony
- Keep the implementation as tiny as possible
- Avoid unrelated business logic
- Avoid recording logic, screen APIs, media APIs, virtual screen APIs, permissions beyond what the blank app normally needs

### Minimal native behavior
- `getVersion()` returns a fixed string
- optionally print one or two native logs if possible, but logging is secondary

---

## Desired ArkTS side shape
- One page only
- One button only
- One call only: `getVersion()`
- Display success/failure directly on screen
- Also log concise messages to console, e.g.:
  - success: `[NodeApiDemo] getVersion() => ...`
  - failure: `[NodeApiDemo] failed: ...`

---

## What to verify
After the fresh project is created and run on DAYU200, verify exactly this:

### Success condition
ArkTS successfully loads `libentry.so` and `getVersion()` returns the fixed string.

Example successful outcome:
- screen shows something like:
  - `Status: Success`
  - `getVersion() => hello from native`
- no `GetNativeOrCjsExports` failure in logs

### Failure condition
The new project still shows a runtime error like:
- `ArkCompiler [GetNativeOrCjsExports:50] Load native module failed, so is @normalized:Y&&&libentry.so&`

If that happens in the fresh project too, then the correct conclusion is:
- the issue is **not specific to the old app**
- it is likely an environment / board-image / runtime support problem

---

## Please report back with
1. The exact fresh-project file layout used
2. The exact `build-profile.json5` module-level native config
3. The exact `oh-package.json5` local dependency config
4. The exact `types/libentry/oh-package.json5` and `Index.d.ts` used
5. The exact native registration code used
6. The exact ArkTS import shape used
7. The exact runtime result on DAYU200
   - success, or
   - full failure logs

---

## Important note
Do **not** spend time adding real business logic, recording logic, virtual screen logic, AVRecorder logic, or bridge abstraction layers.

This task is only to answer:

> Does a fresh, minimal, canonical local Node-API `libentry.so` demo load successfully on this DAYU200 environment or not?
