--[[
	An implementation of Promises similar to Promise/A+.
]]

local PROMISE_DEBUG = false

--[[
	pcallWithTraceback is a wrapper around xpcall that:
	- Uses debug.traceback as the traceback function
	- Warns on failure if PROMISE_DEBUG is set
	- Passeses through to the function like pcall
]]
local function pcallWithTraceback(f, ...)
	local args = {...}
	local argsLength = select("#", ...)

	local body = function()
		return f(unpack(args, 1, argsLength))
	end

	local success, result = xpcall(body, debug.traceback)

	-- If promise debugging is on, warn whenever a pcall fails.
	-- This is useful for debugging issues within the Promise implementation
	-- itself.
	if PROMISE_DEBUG and not success then
		warn(result[2])
	end

	return success, result
end

--[[
	Creates a function that invokes a callback with correct error handling and
	resolution mechanisms.
]]
local function createAdvancer(callback, resolve, reject)
	return function(argument)
		local success, result = pcallWithTraceback(callback, argument)

		if success then
			resolve(result)
		else
			reject(result)
		end
	end
end

local function isListEmpty(t)
	return t[1] == nil
end

local function createSymbol(name)
	assert(type(name) == "string", "createSymbol requires `name` to be a string.")

	local symbol = newproxy(true)

	getmetatable(symbol).__tostring = function()
		return ("Symbol(%s)"):format(name)
	end

	return symbol
end

local PromiseMarker = createSymbol("PromiseMarker")

local Promise = {}
Promise.prototype = {}
Promise.__index = Promise.prototype

Promise.Status = {
	Started = createSymbol("Started"),
	Resolved = createSymbol("Resolved"),
	Rejected = createSymbol("Rejected"),
}

--[[
	Constructs a new Promise with the given initializing callback.

	This is generally only called when directly wrapping a non-promise API into
	a promise-based version.

	The callback will receive 'resolve' and 'reject' methods, used to start
	invoking the promise chain.

	For example:

		local function get(url)
			return Promise.new(function(resolve, reject)
				spawn(function()
					resolve(HttpService:GetAsync(url))
				end)
			end)
		end

		get("https://google.com")
			:andThen(function(stuff)
				print("Got some stuff!", stuff)
			end)
]]
function Promise.new(callback)
	local self = {
		-- Used to locate where a promise was created
		_source = debug.traceback(),

		-- A tag to identify us as a promise
		[PromiseMarker] = true,

		_status = Promise.Status.Started,

		-- The value held by the promise, only valid is _status is not Started
		_value = nil,

		-- If an error occurs with no observers, this will be set.
		_unhandledRejection = false,

		-- Queues representing functions we should invoke when we update!
		_queuedResolve = {},
		_queuedReject = {},
	}

	setmetatable(self, Promise)

	local function resolve(value)
		self:_resolve(value)
	end

	local function reject(value)
		self:_reject(value)
	end

	local success, result = pcallWithTraceback(callback, resolve, reject)

	if not success then
		reject(result)
	end

	return self
end

--[[
	Create a promise that represents the immediately resolved value.
]]
function Promise.resolve(value)
	return Promise.new(function(resolve)
		resolve(value)
	end)
end

--[[
	Create a promise that represents the immediately rejected value.
]]
function Promise.reject(value)
	return Promise.new(function(_, reject)
		reject(value)
	end)
end

--[[
	Returns a new promise that:
		* is resolved when all input promises resolve
		* is rejected if ANY input promises reject
]]
function Promise.all(promises)
	if type(promises) ~= "table" then
		error("Please pass a list of promises to Promise.all", 2)
	end

	-- If there are no values then return an already resolved promise.
	if isListEmpty(promises) then
		return Promise.resolve({})
	end

	-- We need to check that each value is a promise here so that we can produce
	-- a proper error rather than a rejected promise with our error.
	for index, promise in ipairs(promises) do
		if not Promise.is(promise) then
			error(("Non-promise value passed into Promise.all at index #%d"):format(index), 2)
		end
	end

	return Promise.new(function(resolve, reject)
		-- An array to contain our resolved values from the given promises.
		local resolvedValues = {}

		-- Keep a count of resolved promises because just checking the resolved
		-- values length wouldn't account for promises that resolve with nil.
		local resolvedCount = 0

		-- Called when a single value is resolved and resolves if all are done.
		local function resolveOne(index, value)
			resolvedValues[index] = value
			resolvedCount = resolvedCount + 1

			if resolvedCount == #promises then
				resolve(resolvedValues)
			end
		end

		-- We can assume the values inside `promises` are all promises since we
		-- checked above.
		for index, promise in ipairs(promises) do
			promise:andThen(
				function(value)
					resolveOne(index, value)
				end,
				reject
			)
		end
	end)
end

--[[
	Is the given object a Promise instance?
]]
function Promise.is(object)
	if type(object) ~= "table" then
		return false
	end

	return object[PromiseMarker] == true
end

function Promise.prototype:getStatus()
	return self._status
end

--[[
	Creates a new promise that receives the result of this promise.

	The given callbacks are invoked depending on that result.
]]
function Promise.prototype:andThen(successHandler, failureHandler)
	self._unhandledRejection = false

	-- Create a new promise to follow this part of the chain
	return Promise.new(function(resolve, reject)
		-- Our default callbacks just pass values onto the next promise.
		-- This lets success and failure cascade correctly!

		local successCallback = resolve
		if successHandler then
			successCallback = createAdvancer(successHandler, resolve, reject)
		end

		local failureCallback = reject
		if failureHandler then
			failureCallback = createAdvancer(failureHandler, resolve, reject)
		end

		if self._status == Promise.Status.Started then
			-- If we haven't resolved yet, put ourselves into the queue
			table.insert(self._queuedResolve, successCallback)
			table.insert(self._queuedReject, failureCallback)
		elseif self._status == Promise.Status.Resolved then
			-- This promise has already resolved! Trigger success immediately.
			successCallback(self._value)
		elseif self._status == Promise.Status.Rejected then
			-- This promise died a terrible death! Trigger failure immediately.
			failureCallback(self._value)
		end
	end)
end

--[[
	Used to catch any errors that may have occurred in the promise.
]]
function Promise.prototype:catch(failureCallback)
	return self:andThen(nil, failureCallback)
end

--[[
	Yield until the promise is completed.

	This matches the execution model of normal Roblox functions.
]]
function Promise.prototype:await()
	self._unhandledRejection = false

	if self._status == Promise.Status.Started then
		local result
		local bindable = Instance.new("BindableEvent")

		self:andThen(
			function(value)
				result = value
				bindable:Fire(true)
			end,
			function(value)
				result = value
				bindable:Fire(false)
			end
		)

		local success = bindable.Event:Wait()
		bindable:Destroy()

		return success, result
	elseif self._status == Promise.Status.Resolved then
		return true, self._value
	elseif self._status == Promise.Status.Rejected then
		return false, self._value
	end
end

--[[
	Intended for use in tests.

	Similar to await(), but instead of yielding if the promise is unresolved,
	_unwrap will throw. This indicates an assumption that a promise has
	resolved.
]]
function Promise.prototype:_unwrap()
	if self._status == Promise.Status.Started then
		error("Promise has not resolved or rejected.", 2)
	end

	local success = self._status == Promise.Status.Resolved

	return success, self._value
end

function Promise.prototype:_resolve(value)
	if self._status ~= Promise.Status.Started then
		return
	end

	-- If the resolved value was a Promise, we chain onto it!
	if Promise.is(value) then
		value:andThen(
			function(...)
				self:_resolve(...)
			end,
			function(...)
				self:_reject(...)
			end
		)
	else
		self._status = Promise.Status.Resolved
		self._value = value

		-- We assume that these callbacks will not throw errors.
		for _, callback in ipairs(self._queuedResolve) do
			callback(value)
		end
	end
end

function Promise.prototype:_reject(value)
	if self._status ~= Promise.Status.Started then
		return
	end

	self._status = Promise.Status.Rejected
	self._value = value

	-- If there are any rejection handlers, call those!
	if not isListEmpty(self._queuedReject) then
		-- We assume that these callbacks will not throw errors.
		for _, callback in ipairs(self._queuedReject) do
			callback(value)
		end
	else
		-- At this point, no one was able to observe the error.
		-- An error handler might still be attached if the error occurred
		-- synchronously. We'll wait one tick, and if there are still no
		-- observers, then we should put a message in the console.

		self._unhandledRejection = true
		local err = tostring(value)

		spawn(function()
			-- Someone observed the error, hooray!
			if not self._unhandledRejection then
				return
			end

			-- Build a reasonable message
			local message = ("Unhandled promise rejection:\n\n%s\n\n%s"):format(
				err,
				self._source
			)
			warn(message)
		end)
	end
end

return Promise