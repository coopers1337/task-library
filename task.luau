--[[
	task
	Recreation of Roblox's engine task library for old clients.
	Plain Lua 5.1 syntax, so it runs on pre-Luau clients and on Luau.

	INSTALL
		Put this in a ModuleScript named "task" in ReplicatedStorage, then at the top of each script:
			local task = require(game:GetService("ReplicatedStorage").task)
		Require it once as early as possible (e.g. from a Script in ServerScriptService and a
		LocalScript in ReplicatedFirst) so the global patches are in place before other code runs.
		Clients from before ModuleScript existed: paste it into a Script instead and use _G.task.

	API (same as https://create.roblox.com/docs/reference/engine/libraries/task)
		task.spawn(functionOrThread, ...)           -> thread
		task.defer(functionOrThread, ...)           -> thread
		task.delay(duration, functionOrThread, ...) -> thread
		task.wait(duration?)                        -> number
		task.cancel(thread)
		task.synchronize()
		task.desynchronize()

	HOW IT WORKS
		Scheduler
			- Threads wait on a BindableEvent, so the engine itself resumes them: errors print exactly
			  like normal script errors, with the engine's stack trace and no lines from this module.
			- task.wait / task.delay resume on the first Heartbeat after they're due, with no throttling.
		task.defer
			- Deferred threads run at the end of the current resumption cycle. For anything this module
			  resumed (task.*, and wait/spawn/delay when TAKE_OVER_WAIT is on) that is exact.
			- For code the engine resumed (a script's main body, event handlers, Event:wait()), they run
			  as soon as this module can tell that code's turn is over: the next call into task/wait from
			  any other thread, or the next Stepped/Heartbeat/RenderStepped, whichever comes first.
		Serial / parallel phases
			- Every thread is in the serial or the parallel phase. task.desynchronize suspends the thread
			  and resumes it in the next parallel phase; task.synchronize suspends it and resumes it in
			  the next serial phase. spawn/defer/delay/wait keep the caller's phase, like the engine.
			- The parallel phase runs once per frame, right after Heartbeat. Old clients have one Lua
			  thread, so "parallel" threads run one after another inside that phase.
			- Like the engine, they error unless called from a script inside an Actor (or a ModuleScript
			  called by one). On clients without the Actor class, a Model named ACTOR_NAME counts.
		Global patches (old clients only, turn off with the flags below)
			- coroutine.status/resume/wrap are patched and coroutine.close is added when it's missing,
			  so a cancelled thread really looks and acts dead.
			- wait/spawn/delay are rebuilt on this scheduler (TAKE_OVER_WAIT): same return values as the
			  engine's, no throttling, cancellable, and exact task.defer timing in code they resume.
			- pcall is swapped for ypcall when pcall can't yield, so task.wait works inside pcall.
			- If the client blocks editing shared globals, these patches silently do nothing.
]]

-- Return the engine's own task library when the client already has one. Set to false to test this module.
local USE_NATIVE_TASK = true
-- Patch coroutine.* and pcall for every script (only on clients that need it)
local PATCH_GLOBALS = true
-- Rebuild the global wait/spawn/delay on this scheduler
local TAKE_OVER_WAIT = true
-- task.synchronize/desynchronize error outside an Actor, like the engine
local REQUIRE_ACTOR = true
-- On clients without the Actor class, a Model with this name counts as an Actor
local ACTOR_NAME = "Actor"

local nativeTask = task
if USE_NATIVE_TASK and type(nativeTask) == "table" and type(nativeTask.spawn) == "function" then
	return nativeTask
end

-- Keep the originals before anything gets patched
local pcall = pcall
local error = error
local getfenv = getfenv
local unpack = unpack or table.unpack
local typeof = typeof or type
local rawCreate = coroutine.create
local rawResume = coroutine.resume
local rawStatus = coroutine.status
local rawRunning = coroutine.running
local rawYield = coroutine.yield
local rawClose = coroutine.close
local rawWait = wait
local rawDelay = delay

local RunService = game:GetService("RunService")

-- os.clock is CPU time on some old clients, so only trust it on Luau
local clock = tick
if _VERSION == "Luau" and type(os) == "table" and type(os.clock) == "function" then
	clock = os.clock
end

-- Second value returned by the engine's wait()
local gameTime = clock
if type(elapsedTime) == "function" then
	gameTime = elapsedTime
elseif type(ElapsedTime) == "function" then
	gameTime = ElapsedTime
end

local MAX_DEFER_DEPTH = 80
local MIN_LEGACY_WAIT = 1 / 30 -- the engine's wait()/spawn()/delay() never yield less than this
local ARG_WORD = (_VERSION == "Luau") and "invalid" or "bad"

local function pack(...)
	return { n = select("#", ...), ... }
end

local function getSignal(name)
	local ok, signal = pcall(function()
		return RunService[name]
	end)
	if ok then
		return signal
	end
	return nil
end

local Heartbeat = getSignal("Heartbeat") or getSignal("Stepped")
assert(Heartbeat, "task: RunService has no Heartbeat or Stepped event")

local function newBindable()
	local ok, event = pcall(Instance.new, "BindableEvent")
	if ok then
		return event
	end
	return nil
end

-- Native waking only works when BindableEvent:Fire resumes a waiting thread on the spot
-- (true on every client from before deferred events). Otherwise fall back to coroutine.resume.
local function fireWakesInstantly()
	local event = newBindable()
	if not event then
		return false
	end
	local woke = false
	local thread = rawCreate(function()
		event.Event:wait()
		woke = true
	end)
	local ok = rawResume(thread)
	if not ok or rawStatus(thread) ~= "suspended" then
		return false
	end
	local fired = pcall(function()
		event:Fire()
	end)
	pcall(function()
		event:Destroy()
	end)
	return fired and woke
end

local NATIVE_WAKE = fireWakesInstantly()

local ACTOR_CLASS_EXISTS = pcall(function()
	Instance.new("Actor"):Destroy()
end)

--------------------------------------------------------------------------------
-- Error output
--------------------------------------------------------------------------------

-- error itself is the handler, so the printed stack has no lines from this module
local function printError(message)
	local event = newBindable()
	if event then
		event.Event:connect(error)
		event:Fire(message, 0)
	else
		rawDelay(0, function()
			error(message, 0)
		end)
	end
end

-- Only used for raw coroutines; threads made by this module report through the engine
local function reportError(thread, err)
	local message = tostring(err)
	if type(err) == "string" and type(debug) == "table" and type(debug.traceback) == "function" then
		local ok, trace = pcall(debug.traceback, thread, err)
		if ok and type(trace) == "string" then
			message = trace
		end
	end
	printError(message)
end

--------------------------------------------------------------------------------
-- Scheduler state
--------------------------------------------------------------------------------

local function weakKeys()
	return setmetatable({}, { __mode = "k" })
end

local waiting = {} -- timed entries (task.wait, task.delay, wait, spawn, delay), checked every Heartbeat
local resumingNow = {} -- entries being resumed right now (kept so task.cancel can reach them)
local serialDefers = { items = {}, flushing = false } -- task.defer from the serial phase
local parallelDefers = { items = {}, flushing = false } -- task.defer from the parallel phase
local parallelQueue = {} -- entries to resume in the next parallel phase
local serialQueue = {} -- entries to resume in the next serial phase (task.synchronize)

local cancelled = weakKeys() -- cancelled threads (when coroutine.close is missing)
local inParallel = weakKeys() -- threads currently in the parallel phase
local parkedOn = weakKeys() -- thread -> { event, id } it is waiting on
local wakeArgs = weakKeys() -- thread -> values handed over when it is woken
local threadEvent = weakKeys() -- thread -> its reusable BindableEvent

local scheduleCount = 0
local parkCount = 0
local deferDepth = 0 -- re-entrancy depth of the deferred thread running right now
local ownedDepth = 0 -- > 0 while this module is resuming a thread
local cycleOwner = nil -- engine-resumed thread whose resumption cycle our current resume is part of
local schedulerRunning = false -- true while this module drives the cycle (it flushes defers itself)

-- Which engine-resumed thread's cycle a task.defer belongs to (nil when this module owns the cycle)
local function currentOwner()
	if schedulerRunning then
		return nil
	end
	if ownedDepth > 0 then
		return cycleOwner
	end
	return rawRunning()
end

--------------------------------------------------------------------------------
-- Parking: suspend a thread so that the engine is the one that resumes it
--------------------------------------------------------------------------------

local function retireEvent(thread, event)
	if threadEvent[thread] == event then
		threadEvent[thread] = nil
	end
	pcall(function()
		event:Destroy()
	end)
end

local function park(entry)
	local thread = rawRunning()
	local event = nil
	if NATIVE_WAKE then
		event = threadEvent[thread]
		if not event then
			event = newBindable()
			threadEvent[thread] = event
		end
	end
	if not event then
		return rawYield()
	end

	parkCount = parkCount + 1
	parkedOn[thread] = { event = event, id = parkCount }
	if entry then
		entry.parkId = parkCount
	end

	local results = pack(event.Event:wait())

	local args = wakeArgs[thread]
	wakeArgs[thread] = nil
	local parked = parkedOn[thread]
	if parked and parked.event == event then
		-- Resumed directly with coroutine.resume instead of by the scheduler: never reuse this event
		parkedOn[thread] = nil
		retireEvent(thread, event)
		if entry then
			entry.cancelled = true
		end
	end

	-- A cancelled thread never continues
	while cancelled[thread] do
		rawYield()
	end

	if args then
		return unpack(args, 1, args.n)
	end
	return unpack(results, 1, results.n)
end

local function unpark(thread)
	local parked = parkedOn[thread]
	if parked then
		parkedOn[thread] = nil
		retireEvent(thread, parked.event)
	end
end

local function resumeThread(thread, ...)
	if ownedDepth == 0 and not schedulerRunning then
		cycleOwner = rawRunning()
	end
	ownedDepth = ownedDepth + 1
	local parked = parkedOn[thread]
	if parked then
		parkedOn[thread] = nil
		wakeArgs[thread] = pack(...)
		parked.event:Fire()
	else
		local ok, err = rawResume(thread, ...)
		if not ok then
			reportError(thread, err)
		end
	end
	ownedDepth = ownedDepth - 1
end

-- Threads made from functions park straight away, so even their first run comes from the engine
local function newThread(fn)
	if not NATIVE_WAKE then
		return rawCreate(fn)
	end
	local thread = rawCreate(function()
		local args = pack(park(nil))
		return fn(unpack(args, 1, args.n)) -- tail call: no frame from this module in stack traces
	end)
	rawResume(thread)
	return thread
end

--------------------------------------------------------------------------------
-- Argument checks (level 3 points the error at the script that called task.*)
--------------------------------------------------------------------------------

local function toThread(value, index, name)
	local valueType = type(value)
	if valueType == "function" then
		return newThread(value)
	elseif valueType == "thread" then
		return value
	end
	error(string.format("invalid argument #%d to '%s' (function or thread expected)", index, name), 3)
end

local function toDuration(value, index, name)
	local number = tonumber(value)
	if number == nil then
		error(string.format("invalid argument #%d to '%s' (number expected, got %s)", index, name, typeof(value)), 3)
	end
	-- NaN and negative durations resume on the next Heartbeat
	if number ~= number or number < 0 then
		number = 0
	end
	return number
end

--------------------------------------------------------------------------------
-- Scheduler
--------------------------------------------------------------------------------

-- Entry kinds where the thread suspended itself (and may have been resumed by someone else since)
local SELF_PARKED = { wait = true, legacyWait = true, phase = true }

local function resumeValues(entry)
	local kind = entry.kind
	if kind == "wait" then
		return pack(clock() - entry.start)
	elseif kind == "legacyWait" or kind == "legacyStart" then
		return pack(clock() - entry.start, gameTime())
	elseif kind == "phase" then
		return pack()
	end
	return entry.args
end

local function resumeEntry(entry)
	local thread = entry.thread
	if cancelled[thread] then
		return
	end
	local status = rawStatus(thread)
	if SELF_PARKED[entry.kind] then
		-- Skip quietly if something else already resumed the thread
		if status ~= "suspended" then
			return
		end
		local parked = parkedOn[thread]
		if entry.parkId and not (parked and parked.id == entry.parkId) then
			return
		end
	else
		if status ~= "suspended" then
			printError("cannot resume " .. (status == "dead" and "dead" or "non-suspended") .. " coroutine")
			return
		end
		inParallel[thread] = entry.parallel or nil
	end
	local values = resumeValues(entry)
	resumeThread(thread, unpack(values, 1, values.n))
end

local function schedule(entry)
	scheduleCount = scheduleCount + 1
	entry.order = scheduleCount
	waiting[#waiting + 1] = entry
end

local function markCancelled(list, thread, selfParkedOnly)
	for i = 1, #list do
		local entry = list[i]
		if entry.thread == thread and (not selfParkedOnly or SELF_PARKED[entry.kind]) then
			entry.cancelled = true
		end
	end
end

-- Forget everything queued for a thread (or only what it is waiting in itself)
local function dropPending(thread, selfParkedOnly)
	markCancelled(waiting, thread, selfParkedOnly)
	markCancelled(resumingNow, thread, selfParkedOnly)
	markCancelled(parallelQueue, thread, selfParkedOnly)
	markCancelled(serialQueue, thread, selfParkedOnly)
	markCancelled(serialDefers.items, thread, selfParkedOnly)
	markCancelled(parallelDefers.items, thread, selfParkedOnly)
end

local function runDeferQueue(queue)
	-- Threads deferred during this loop are appended and run in the same pass, like the engine
	local items = queue.items
	local index = 1
	while index <= #items do
		local entry = items[index]
		index = index + 1
		if not entry.cancelled then
			entry.cancelled = true
			local previousDepth = deferDepth
			deferDepth = entry.depth
			resumeEntry(entry)
			deferDepth = previousDepth
		end
	end
end

local function flushQueue(queue)
	if queue.flushing or #queue.items == 0 then
		return
	end
	queue.flushing = true
	local wasRunning = schedulerRunning
	local savedDepth = deferDepth
	schedulerRunning = true
	local ok, err = pcall(runDeferQueue, queue)
	queue.items = {}
	queue.flushing = false
	schedulerRunning = wasRunning
	deferDepth = savedDepth
	if not ok then
		printError("task: " .. tostring(err))
	end
end

-- Run serial defers whose engine-resumed thread has finished its turn (it isn't running any more)
local function flushEndedCycles()
	local queue = serialDefers
	if schedulerRunning or queue.flushing or #queue.items == 0 then
		return
	end
	local items = queue.items
	for i = 1, #items do
		local owner = items[i].owner
		if owner and not items[i].cancelled then
			local status = rawStatus(owner)
			if status == "running" or status == "normal" then
				return
			end
		end
	end
	flushQueue(queue)
end

-- Resume every entry of a phase; deferred threads run after each one, in the same phase
local function runPhase(queue, parallel)
	resumingNow = queue
	local defers = parallel and parallelDefers or serialDefers
	for i = 1, #queue do
		local entry = queue[i]
		if not entry.cancelled then
			entry.cancelled = true
			resumeEntry(entry)
			flushQueue(defers)
		end
	end
	flushQueue(defers)
	resumingNow = {}
end

local function sortByDueTime(a, b)
	if a.resumeAt == b.resumeAt then
		return a.order < b.order
	end
	return a.resumeAt < b.resumeAt
end

local function stepBody()
	flushQueue(serialDefers)

	-- Threads that called task.synchronize outside a parallel phase
	local syncQueue = serialQueue
	serialQueue = {}
	runPhase(syncQueue, false)

	-- Collect everything that's due; anything scheduled from now on waits for the next Heartbeat
	local now = clock()
	local due = {}
	local remaining = {}
	for i = 1, #waiting do
		local entry = waiting[i]
		if not entry.cancelled then
			if entry.resumeAt <= now then
				due[#due + 1] = entry
			else
				remaining[#remaining + 1] = entry
			end
		end
	end
	waiting = remaining
	table.sort(due, sortByDueTime)

	local serialDue = {}
	for i = 1, #due do
		local entry = due[i]
		if entry.parallel then
			parallelQueue[#parallelQueue + 1] = entry
		else
			serialDue[#serialDue + 1] = entry
		end
	end
	runPhase(serialDue, false)

	-- Parallel phase
	local parallelNow = parallelQueue
	parallelQueue = {}
	runPhase(parallelNow, true)

	-- Next serial phase: threads that called task.synchronize during the parallel phase
	syncQueue = serialQueue
	serialQueue = {}
	runPhase(syncQueue, false)
end

local function step()
	local wasRunning = schedulerRunning
	schedulerRunning = true
	local ok, err = pcall(stepBody)
	schedulerRunning = wasRunning
	resumingNow = {}
	if not ok then
		printError("task: " .. tostring(err))
	end
end

Heartbeat:connect(step)

-- Extra flush points for task.defer calls made from code the engine resumed
local function flushSerialDefers()
	flushQueue(serialDefers)
end

local flushSignalNames = { "Stepped", "RenderStepped" }
for i = 1, #flushSignalNames do
	local signal = getSignal(flushSignalNames[i])
	if signal then
		pcall(function()
			signal:connect(flushSerialDefers)
		end)
	end
end

local function cancelThread(thread)
	dropPending(thread, false)
	inParallel[thread] = nil
	if rawClose then
		rawClose(thread)
	else
		cancelled[thread] = true
	end
	unpark(thread)
end

--------------------------------------------------------------------------------
-- Actors
--------------------------------------------------------------------------------

local function isInActor(instance)
	local ok, result = pcall(function()
		local current = instance
		while current do
			if current.ClassName == "Actor" then
				return true
			end
			if not ACTOR_CLASS_EXISTS and current.Name == ACTOR_NAME and current:IsA("Model") then
				return true
			end
			current = current.Parent
		end
		return false
	end)
	return ok and result == true
end

-- True when any script on the calling thread's stack is inside an Actor
-- (so a ModuleScript counts when an Actor script called it, like the engine)
local function calledFromActor()
	if not REQUIRE_ACTOR then
		return true
	end
	if type(getfenv) ~= "function" then
		return false
	end
	local seen = {}
	-- Through pcall, level 1 is pcall, 2 this function, 3 task.(de)synchronize, 4 the caller
	for level = 4, 200 do
		local ok, env = pcall(getfenv, level)
		if not ok then
			break
		end
		if type(env) == "table" and not seen[env] then
			seen[env] = true
			local okScript, scriptObject = pcall(function()
				return env.script
			end)
			if okScript and scriptObject and isInActor(scriptObject) then
				return true
			end
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Library
--------------------------------------------------------------------------------

local task = {}

function task.spawn(functionOrThread, ...)
	flushEndedCycles()
	local parallel = inParallel[rawRunning()]
	local thread = toThread(functionOrThread, 1, "spawn")
	local status = rawStatus(thread)
	if status == "dead" or cancelled[thread] then
		error("cannot resume dead coroutine", 2)
	elseif status ~= "suspended" then
		error("cannot resume non-suspended coroutine", 2)
	end
	-- Resuming a thread early ends whatever it was waiting in
	dropPending(thread, true)
	-- Runs in the caller's phase
	inParallel[thread] = parallel or nil
	resumeThread(thread, ...)
	return thread
end

function task.defer(functionOrThread, ...)
	flushEndedCycles()
	local parallel = inParallel[rawRunning()] == true
	local thread = toThread(functionOrThread, 1, "defer")
	local depth = deferDepth + 1
	if depth > MAX_DEFER_DEPTH then
		error("Maximum re-entrancy depth (" .. MAX_DEFER_DEPTH .. ") exceeded calling task.defer", 2)
	end
	local queue = parallel and parallelDefers or serialDefers
	queue.items[#queue.items + 1] = {
		thread = thread,
		kind = "defer",
		depth = depth,
		args = pack(...),
		parallel = parallel,
		owner = currentOwner(),
	}
	return thread
end

function task.delay(duration, functionOrThread, ...)
	flushEndedCycles()
	local parallel = inParallel[rawRunning()] == true
	duration = toDuration(duration, 1, "delay")
	local thread = toThread(functionOrThread, 2, "delay")
	schedule({
		thread = thread,
		kind = "delay",
		resumeAt = clock() + duration,
		args = pack(...),
		parallel = parallel,
	})
	return thread
end

function task.wait(duration)
	flushEndedCycles()
	if duration == nil then
		duration = 0
	else
		duration = toDuration(duration, 1, "wait")
	end
	local thread = rawRunning()
	if thread == nil then
		error("attempt to yield from outside a coroutine", 2)
	end
	local start = clock()
	local entry = {
		thread = thread,
		kind = "wait",
		start = start,
		resumeAt = start + duration,
		parallel = inParallel[thread] == true,
	}
	schedule(entry)
	return park(entry)
end

function task.cancel(thread)
	flushEndedCycles()
	if type(thread) ~= "thread" then
		error(string.format("invalid argument #1 to 'cancel' (thread expected, got %s)", typeof(thread)), 2)
	end
	local status = rawStatus(thread)
	if status == "running" or status == "normal" then
		error("cannot cancel thread", 2)
	end
	if status == "suspended" and not cancelled[thread] then
		cancelThread(thread)
	else
		dropPending(thread, false)
	end
end

function task.desynchronize()
	flushEndedCycles()
	if not calledFromActor() then
		error("task.desynchronize() should only be called from a script that is a descendant of an Actor", 2)
	end
	local thread = rawRunning()
	if inParallel[thread] then
		return -- already parallel: returns immediately
	end
	inParallel[thread] = true
	local entry = { thread = thread, kind = "phase" }
	parallelQueue[#parallelQueue + 1] = entry
	park(entry)
end

function task.synchronize()
	flushEndedCycles()
	if not calledFromActor() then
		error("task.synchronize() should only be called from a script that is a descendant of an Actor", 2)
	end
	local thread = rawRunning()
	if not inParallel[thread] then
		return -- already serial: returns immediately
	end
	inParallel[thread] = nil
	local entry = { thread = thread, kind = "phase" }
	serialQueue[#serialQueue + 1] = entry
	park(entry)
end

--------------------------------------------------------------------------------
-- wait / spawn / delay rebuilt on this scheduler (TAKE_OVER_WAIT)
--------------------------------------------------------------------------------

local function legacyDuration(value)
	local number = tonumber(value)
	if number == nil or number ~= number or number < MIN_LEGACY_WAIT then
		number = MIN_LEGACY_WAIT
	end
	return number
end

local function legacyWait(duration)
	flushEndedCycles()
	local thread = rawRunning()
	local start = clock()
	local entry = {
		thread = thread,
		kind = "legacyWait",
		start = start,
		resumeAt = start + legacyDuration(duration),
		parallel = inParallel[thread] == true,
	}
	schedule(entry)
	return park(entry)
end

local function legacyStart(name, index, duration, callback)
	if type(callback) ~= "function" then
		error(string.format("%s argument #%d to '%s' (function expected, got %s)", ARG_WORD, index, name, typeof(callback)), 3)
	end
	local start = clock()
	schedule({
		thread = newThread(callback),
		kind = "legacyStart",
		start = start,
		resumeAt = start + duration,
		parallel = false,
	})
end

local function legacySpawn(callback)
	flushEndedCycles()
	legacyStart("spawn", 1, MIN_LEGACY_WAIT, callback)
end

local function legacyDelay(duration, callback)
	flushEndedCycles()
	legacyStart("delay", 2, legacyDuration(duration), callback)
end

--------------------------------------------------------------------------------
-- Global patches (old clients only)
--------------------------------------------------------------------------------

-- coroutine.* that treat cancelled threads as dead
local function patchedStatus(co)
	if cancelled[co] then
		return "dead"
	end
	return rawStatus(co)
end

local function patchedResume(co, ...)
	if cancelled[co] then
		return false, "cannot resume dead coroutine"
	end
	return rawResume(co, ...)
end

local function patchedWrap(f)
	if type(f) ~= "function" then
		error(string.format("%s argument #1 to 'wrap' (function expected, got %s)", ARG_WORD, typeof(f)), 2)
	end
	local co = rawCreate(f)
	return function(...)
		local results = pack(patchedResume(co, ...))
		if results[1] then
			return unpack(results, 2, results.n)
		end
		error(results[2], 2)
	end
end

local function closePolyfill(co)
	if type(co) ~= "thread" then
		error(string.format("%s argument #1 to 'close' (thread expected, got %s)", ARG_WORD, typeof(co)), 2)
	end
	local status = patchedStatus(co)
	if status == "running" or status == "normal" then
		error("cannot close " .. status .. " coroutine", 2)
	end
	if status == "suspended" then
		cancelThread(co)
	end
	return true
end

-- The engine's wait(), except a cancelled thread never continues (used when TAKE_OVER_WAIT is off)
local function patchedWait(...)
	local results = pack(rawWait(...))
	local thread = rawRunning()
	while cancelled[thread] do
		rawYield()
	end
	return unpack(results, 1, results.n)
end

-- The table every script's globals come from, so a patch reaches all scripts
local function findSharedGlobals()
	if type(getfenv) ~= "function" then
		return nil
	end
	-- Called directly (not through pcall) so level 1 is this module's own function
	local candidates = { getfenv(0) }
	local env = getfenv(1)
	if type(env) == "table" then
		local okMeta, meta = pcall(getmetatable, env)
		if okMeta and type(meta) == "table" and type(meta.__index) == "table" then
			candidates[#candidates + 1] = meta.__index
		end
	end
	for i = 1, #candidates do
		local candidate = candidates[i]
		-- Shared globals have the built-ins but no per-script "script" value
		if type(candidate) == "table" and type(rawget(candidate, "wait")) == "function" and rawget(candidate, "script") == nil then
			return candidate
		end
	end
	return nil
end

local function patchGlobal(globals, name, value)
	local old = rawget(globals, name)
	if old == nil then
		return false
	end
	if not pcall(rawset, globals, name, value) then
		return false
	end
	-- Make sure scripts actually see it (this module's env looks globals up like any script); undo if not
	local env = getfenv(1)
	if type(env) ~= "table" or env[name] ~= value then
		pcall(rawset, globals, name, old)
		return false
	end
	return true
end

local function canYieldInside(protectedCall)
	local co = rawCreate(function()
		protectedCall(rawYield)
	end)
	rawResume(co)
	local yielded = rawStatus(co) == "suspended"
	if yielded then
		rawResume(co)
	end
	return yielded
end

if PATCH_GLOBALS and not rawClose then
	pcall(function()
		coroutine.status = patchedStatus
		coroutine.resume = patchedResume
		coroutine.wrap = patchedWrap
		coroutine.close = closePolyfill
	end)
end

local globals = (PATCH_GLOBALS or TAKE_OVER_WAIT) and findSharedGlobals()
if globals then
	local tookOverWait = false
	if TAKE_OVER_WAIT and NATIVE_WAKE then
		tookOverWait = patchGlobal(globals, "wait", legacyWait)
		patchGlobal(globals, "Wait", legacyWait)
		patchGlobal(globals, "spawn", legacySpawn)
		patchGlobal(globals, "Spawn", legacySpawn)
		patchGlobal(globals, "delay", legacyDelay)
		patchGlobal(globals, "Delay", legacyDelay)
	end
	if PATCH_GLOBALS and not tookOverWait and not rawClose and type(rawWait) == "function" then
		patchGlobal(globals, "wait", patchedWait)
	end
	if PATCH_GLOBALS and type(ypcall) == "function" and not canYieldInside(pcall) and canYieldInside(ypcall) then
		patchGlobal(globals, "pcall", ypcall)
	end
end

if type(_G) == "table" and _G.task == nil then
	_G.task = task
end

return task
