--[[
	An implementation of Promises similar to Promise/A+.
]]

local PROMISE_DEBUG = false

--[[
	Packs a number of arguments into a table and returns its length.

	Used to cajole varargs without dropping sparse values.
]]
local function pack(...)
	return select("#", ...), { ... }
end

--[[
	wpcallPacked is a version of xpcall that:
	* Returns the length of the result first
	* Returns the result packed into a table
	* Passes extra arguments through to passed function, which xpcall doesn't
	* Issues a warning if PROMISE_DEBUG is enabled
]]
local function wpcallPacked(f, ...)
	local argsLength, args = pack(...)

	local body = function()
		return f(unpack(args, 1, argsLength))
	end

	local resultLength, result = pack(xpcall(body, debug.traceback))

	-- If promise debugging is on, warn whenever a pcall fails.
	-- This is for debugging issues within the Promise implementation itself.
	if PROMISE_DEBUG and not result[1] then
		warn(result[2])
	end

	return resultLength, result
end

--[[
	Creates a function that invokes a callback with correct error handling and
	resolution mechanisms.
]]
local function createAdvancer(callback, resolve, reject)
	return function(...)
		local resultLength, result = wpcallPacked(callback, ...)
		local ok = result[1]

		if ok then
			resolve(unpack(result, 2, resultLength))
		else
			reject(unpack(result, 2, resultLength))
		end
	end
end

local Promise = {}
Promise.__index = {}

Promise.Status = {
	Started = newproxy(false),
	Resolved = newproxy(false),
	Rejected = newproxy(false),
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
	local promise = {
		-- Used to locate where a promise was created
		_source = debug.traceback(),

		-- A tag to identify us as a promise
		_type = "Promise",

		_status = Promise.Status.Started,

		-- A table containing a list of all results, whether success or failure.
		-- Only valid if _status is set to something besides Started
		_values = nil,

		-- Lua doesn't like sparse arrays very much, so we explicitly store the
		-- length of _values to handle middle nils.
		_valuesLength = -1,

		-- If an error occurs with no observers, this will be set.
		_unhandledRejection = false,

		-- Lists of functions to invoke when our status updates
		_queuedResolve = {},
		_queuedReject = {},
	}

	setmetatable(promise, Promise)

	local function resolve(...)
		promise:_resolve(...)
	end

	local function reject(...)
		promise:_reject(...)
	end

	local _, result = wpcallPacked(callback, resolve, reject)
	local ok = result[1]
	local err = result[2]

	if not ok and promise._status == Promise.Status.Started then
		reject(err)
	end

	return promise
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
function Promise.all(...)
	error("unimplemented", 2)
end

--[[
	Is the given object a Promise instance?
]]
function Promise.is(object)
	if type(object) ~= "table" then
		return false
	end

	return object._type == "Promise"
end

function Promise.__index:getStatus()
	return self._status
end

--[[
	Creates a new promise that receives the result of this promise.

	The given callbacks are invoked depending on that result.
]]
function Promise.__index:andThen(successHandler, failureHandler)
	self._unhandledRejection = false

	-- Create a new promise to follow this part of the chain
	return Promise.new(function(resolve, reject)
		-- Our default callbacks just pass values onto the next promise.
		-- This lets success and failure cascade correctly!

		-- Avoid unnecessary Advancer creation when promises already resolved!
		local successCallback = self._status ~= Promise.Status.Rejected and
			(successHandler and createAdvancer(successHandler, resolve, reject) or resolve)

		local failureCallback = self._status ~= Promise.Status.Resolved and
			(failureHandler and createAdvancer(failureHandler, resolve, reject) or reject)

		if successCallback then
			if failureCallback then
				-- If we haven't resolved yet, put ourselves into the queue
				table.insert(self._queuedResolve, successCallback)
				table.insert(self._queuedReject, failureCallback)
			else
				-- This promise already resolved! Trigger success immediately.
				successCallback(unpack(self._values, 1, self._valuesLength))
			end
		else
			-- This promise died a terrible death! Trigger failure immediately.
			failureCallback(unpack(self._values, 1, self._valuesLength))
		end
	end)
end

--[[
	Used to catch any errors that may have occurred in the promise.
]]
function Promise.__index:catch(failureCallback)
	return self:andThen(nil, failureCallback)
end

--[[
	Yield until the promise is completed.

	This matches the execution model of normal Roblox functions.
]]
function Promise.__index:await()
	self._unhandledRejection = false

	if self._status == Promise.Status.Started then
		local resultLength, result
		local bindable = Instance.new("BindableEvent")

		self:andThen(function(...)
			resultLength, result = pack(...)
			bindable:Fire(true)
		end, function(...)
			resultLength, result = pack(...)
			bindable:Fire(false)
		end)

		local ok = bindable.Event:Wait()
		bindable:Destroy()

		return ok, unpack(result, 1, resultLength)
	elseif self._status == Promise.Status.Resolved then
		return true, unpack(self._values, 1, self._valuesLength)
	elseif self._status == Promise.Status.Rejected then
		return false, unpack(self._values, 1, self._valuesLength)
	end
end

function Promise.__index:_resolve(...)
	if self._status ~= Promise.Status.Started then return end

	-- If the resolved value was a Promise, we chain onto it!
	if Promise.is((...)) then
		-- Without this warning, arguments sometimes mysteriously disappear
		if select("#", ...) > 1 then
			local message = (
				"When returning a Promise from andThen, extra arguments are " ..
				"discarded! See:\n\n%s"
			):format(
				self._source
			)
			warn(message)
		end

		(...):andThen(function(...)
			self:_resolve(...)
		end, function(...)
			self:_reject(...)
		end)
	else
		self._status = Promise.Status.Resolved
		self._valuesLength, self._values = pack(...)

		-- We assume that these callbacks will not throw errors.
		for i = 1, #self._queuedResolve do
			self._queuedResolve[i](...)
		end
	end
end

function Promise.__index:_reject(...)
	if self._status ~= Promise.Status.Started then return end

	self._status = Promise.Status.Rejected
	self._valuesLength, self._values = pack(...)

	local numRejectionHandlers = #self._queuedReject

	-- If there are any rejection handlers, call those!
	if numRejectionHandlers > 0 then
		-- We assume that these callbacks will not throw errors.
		for i = 1, numRejectionHandlers do
			self._queuedReject[i](...)
		end
	else
		-- At this point, no one was able to observe the error.
		-- An error handler might still be attached if the error occurred
		-- synchronously. We'll wait one tick, and if there are still no
		-- observers, then we should put a message in the console.

		self._unhandledRejection = true
		local err = tostring((...))

		spawn(function()
			-- Nobody observed the error, oh no!
			if self._unhandledRejection then
				-- Build a reasonable message
				local message = ("Unhandled promise rejection:\n\n%s\n\n%s"):format(
					err,
					self._source
				)
				warn(message)
			end
		end)
	end
end

return Promise
