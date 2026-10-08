# task — Roblox task library for old revivals

A drop-in recreation of Roblox's [`task` library](https://create.roblox.com/docs/reference/engine/libraries/task) for old Roblox revival clients that don't have it.

Modern Roblox code is full of `task.wait`, `task.spawn`, `task.defer` and `task.delay`. Old clients (2008–2021) don't have them, so that code breaks. Drop in this module and the code runs the way it does on modern Roblox.

- Same API, return values and error messages as the official library
- Written in plain **Lua 5.1** syntax, so it runs on pre-Luau clients and on Luau clients
- No throttling: `task.wait` and `task.delay` resume on the first Heartbeat after they're due
- Errors inside spawned threads print like normal script errors, with the engine's own stack trace
- Working `task.synchronize` / `task.desynchronize` with serial and parallel phases
- If the client already has a built-in `task` library, the module just returns that one

---

## Installation

1. In Studio, create a **ModuleScript** named `task` in **ReplicatedStorage**.
2. Paste the contents of [`task.lua`](task.lua) into it.
3. At the top of every script that uses `task`, add:

```lua
local task = require(game:GetService("ReplicatedStorage").task)
```

**Require it as early as possible.** The module patches some globals for every script (see [Global patches](#global-patches)), so require it once from code that runs first:

- a **Script** in `ServerScriptService` for the server
- a **LocalScript** in `ReplicatedFirst` for the client

**Clients from before ModuleScript existed:** paste the code into a regular **Script** instead. It sets `_G.task`, so other scripts can use:

```lua
local task = _G.task
```

---

## Usage

```lua
local task = require(game:GetService("ReplicatedStorage").task)

-- Wait without throttling; returns the time that actually passed
local elapsed = task.wait(1)
print("Waited", elapsed)

-- Run a function right away in a new thread
task.spawn(function(message)
	print(message)
	task.wait(1)
	print("One second later, inside the spawned thread")
end, "Running instantly")

-- Run a function at the end of the current resumption cycle
task.defer(function()
	print("Runs after the current code yields")
end)

-- Run a function after 2 seconds
local thread = task.delay(2, function()
	print("This never prints")
end)

-- Cancel it before it runs
task.cancel(thread)
```

### Serial and parallel phases

`task.synchronize` and `task.desynchronize` only work in scripts inside an **Actor**, like on modern Roblox. Old clients don't have the Actor class, so on those **a Model named `Actor`** counts as one.

```lua
-- Script inside a Model named "Actor"
local task = require(game:GetService("ReplicatedStorage").task)

task.desynchronize()
-- Now in the parallel phase
local result = heavyCalculation()

task.synchronize()
-- Back in the serial phase
workspace.Part.Name = result
```

---

## API

| Function | Returns | Description |
|---|---|---|
| `task.spawn(functionOrThread, ...)` | `thread` | Calls/resumes the function or thread immediately. Arguments after the first are passed to it. |
| `task.defer(functionOrThread, ...)` | `thread` | Calls/resumes it at the end of the current resumption cycle. |
| `task.delay(duration, functionOrThread, ...)` | `thread` | Calls/resumes it on the first Heartbeat after `duration` seconds have passed. |
| `task.wait(duration?)` | `number` | Yields until the first Heartbeat after `duration` seconds (default `0`). Returns the time that actually passed. |
| `task.cancel(thread)` | — | Cancels a thread so it is never resumed. |
| `task.desynchronize()` | — | Suspends the thread and resumes it in the next parallel phase. Returns immediately if already parallel. |
| `task.synchronize()` | — | Suspends the thread and resumes it in the next serial phase. Returns immediately if already serial. |

### Error messages

These follow the official library's wording:

| Situation | Error |
|---|---|
| `task.spawn(nil)` | `invalid argument #1 to 'spawn' (function or thread expected)` |
| `task.defer(nil)` | `invalid argument #1 to 'defer' (function or thread expected)` |
| `task.delay(1, nil)` | `invalid argument #2 to 'delay' (function or thread expected)` |
| `task.delay("abc", f)` | `invalid argument #1 to 'delay' (number expected, got string)` |
| `task.wait("abc")` | `invalid argument #1 to 'wait' (number expected, got string)` |
| `task.cancel(nil)` | `invalid argument #1 to 'cancel' (thread expected, got nil)` |
| `task.spawn` on a dead thread | `cannot resume dead coroutine` |
| `task.spawn` on a running thread | `cannot resume non-suspended coroutine` |
| `task.cancel` on a running thread | `cannot cancel thread` |
| `task.defer` nested more than 80 deep | `Maximum re-entrancy depth (80) exceeded calling task.defer` |
| `task.(de)synchronize` outside an Actor | `task.desynchronize() should only be called from a script that is a descendant of an Actor` |

The "function or thread expected", "thread expected", "cannot resume" and "cannot cancel thread" messages match ones reported from the official library. The rest are a best match and may differ slightly from the official text.

---

## Configuration

Settings are at the top of `task.lua`:

| Setting | Default | What it does |
|---|---|---|
| `USE_NATIVE_TASK` | `true` | Return the client's built-in `task` library if it has one. Set to `false` to test this module on a modern client. |
| `PATCH_GLOBALS` | `true` | Patch `coroutine.*` and `pcall` for every script (only on clients that need it). |
| `TAKE_OVER_WAIT` | `true` | Rebuild the global `wait`, `spawn` and `delay` on this module's scheduler. |
| `REQUIRE_ACTOR` | `true` | Make `task.synchronize` / `task.desynchronize` error outside an Actor, like the engine. |
| `ACTOR_NAME` | `"Actor"` | On clients without the Actor class, a Model with this name counts as an Actor. |

---

## How it works

**Scheduler.** One Heartbeat connection drives everything. Each frame it resumes every thread that is due, in due-time order, with no throttling. Anything scheduled while resuming waits for the next Heartbeat, like the engine.

**Native waking.** Threads don't wait with `coroutine.yield`. Each one waits on its own `BindableEvent`, and the scheduler fires it, so Roblox itself resumes the thread. Errors then print exactly like normal script errors, with the engine's stack trace and no lines from this module. The module checks on startup that the client resumes waiting threads immediately on `Fire()`. If it doesn't, the module falls back to `coroutine.resume`.

**`task.defer`.** Deferred threads go into a queue and run at the end of the current resumption cycle:

- **Code this module resumed** (anything run by `task.*`, or by `wait`/`spawn`/`delay` when `TAKE_OVER_WAIT` is on): the queue runs right after that code yields or finishes. This is exact.
- **Code Roblox resumed directly** (a script's first run, event handlers, code after `Event:wait()`): the queue runs as soon as the module can tell that code is finished. That's the next call into `task` or `wait` from another thread, or the next Stepped, Heartbeat or RenderStepped, whichever comes first.

**Phases.** Every thread is in either the serial or the parallel phase. The parallel phase runs once per frame, right after Heartbeat, followed by a serial phase for threads that called `task.synchronize`. `spawn`, `defer`, `delay` and `wait` keep the caller's phase.

### Global patches

These only apply on clients that need them, and only if the client allows editing shared globals. The module checks that each patch took effect and undoes it if not.

| Patch | When | Why |
|---|---|---|
| `coroutine.status`, `coroutine.resume`, `coroutine.wrap`, and a new `coroutine.close` | Client has no `coroutine.close` | A cancelled thread reports `"dead"` and can't be resumed, like on modern Roblox. |
| `wait`, `spawn`, `delay` (and `Wait`, `Spawn`, `Delay`) | `TAKE_OVER_WAIT` is on | Rebuilt on this scheduler so they can be cancelled and `task.defer` timing is exact in code they resume. They return the same values as the old ones, with a minimum wait of 1/30 s, but no throttling. |
| `wait` (wrapped) | `TAKE_OVER_WAIT` is off and there's no `coroutine.close` | A thread cancelled while inside `wait()` never continues. |
| `pcall` → `ypcall` | `pcall` can't yield but `ypcall` can | `task.wait` works inside `pcall` on clients from before about 2019. |

---

## Differences from the official library

These can't be fixed from Lua. They would need changes to the client's C++ source.

- **`task.defer` from code Roblox started.** It runs when the module notices that code has finished (see [How it works](#how-it-works)), not at the exact instant it yields.
- **Parallel isn't truly parallel.** Old clients run Lua on one core, so threads in the parallel phase run one after another. Writing to instances during the parallel phase isn't blocked the way it is on modern Roblox.
- **Cancelling threads in other engine yields.** A thread cancelled while blocked in `Event:wait()`, `WaitForChild` or another engine yield still continues when that yield finishes. `wait()` and `task.wait` are covered.
- **Raw coroutines.** Errors in threads made with `coroutine.create` and resumed by `task.*` print with the traceback inside the error message. Functions passed to `task.*` print exactly like engine errors.
- **`xpcall` can't yield** on clients from before about 2019. There's no yielding version to swap in.
- **Timing precision.** On non-Luau clients, time is measured with `tick()`.

---

## Troubleshooting

**`attempt to yield across metamethod/C-call boundary` when using `task.wait` inside `pcall`.** The `pcall` patch didn't apply on your client. Use `ypcall` instead of `pcall` around code that waits.

**`task.wait` never returns.** RunService.Heartbeat isn't firing, for example in Studio edit mode or a plugin. The scheduler only runs while Heartbeat fires.

**Errors print with the stack trace inside the message.** Your client doesn't resume BindableEvent waiters immediately, so the module fell back to `coroutine.resume`. Everything still works; only the error format changes.

**`task.synchronize` errors on an old client.** Put the script inside a Model named `Actor` (or whatever `ACTOR_NAME` is set to), or set `REQUIRE_ACTOR = false`.
