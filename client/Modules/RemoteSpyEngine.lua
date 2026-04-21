local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local RemoteSpyEngine = {}
RemoteSpyEngine.__index = RemoteSpyEngine

local BRIDGE_KEY = "__DartRemoteSpyBridge"

local function getGlobalScope()
	if type(getgenv) == "function" then
		return getgenv()
	end

	return _G
end

local function getGlobalValue(name)
	local scope = getGlobalScope()
	if type(scope) == "table" and scope[name] ~= nil then
		return scope[name]
	end

	if _G[name] ~= nil then
		return _G[name]
	end

	return nil
end

local function getPotassiumApi()
	local debugLibrary = getGlobalValue("debug") or debug
	return {
		checkcaller = getGlobalValue("checkcaller"),
		getcallingscript = getGlobalValue("getcallingscript"),
		getinstances = getGlobalValue("getinstances"),
		getnamecallmethod = getGlobalValue("getnamecallmethod"),
		getnilinstances = getGlobalValue("getnilinstances"),
		getrawmetatable = getGlobalValue("getrawmetatable"),
		hookfunction = getGlobalValue("hookfunction"),
		hookmetamethod = getGlobalValue("hookmetamethod"),
		identifyexecutor = getGlobalValue("identifyexecutor"),
		isreadonly = getGlobalValue("isreadonly"),
		newcclosure = getGlobalValue("newcclosure"),
		setreadonly = getGlobalValue("setreadonly"),
		debug_getinfo = type(debugLibrary) == "table" and debugLibrary.getinfo or nil,
	}
end

local function getBridge()
	local scope = getGlobalScope()
	local bridge = scope[BRIDGE_KEY]
	if type(bridge) ~= "table" then
		bridge = {
			methods = {},
		}
		scope[BRIDGE_KEY] = bridge
	end
	bridge.methods = bridge.methods or {}
	return bridge
end

local function packArgs(...)
	local count = select("#", ...)
	local packed = {
		n = count,
	}
	for index = 1, count do
		packed[index] = select(index, ...)
	end
	return packed
end

local function packArgsAfterFirst(...)
	local count = select("#", ...)
	local packed = {
		n = math.max(count - 1, 0),
	}
	for index = 2, count do
		packed[index - 1] = select(index, ...)
	end
	return packed
end

local function normalizeMethod(method)
	if method == "fireServer" then
		return "FireServer"
	elseif method == "invokeServer" then
		return "InvokeServer"
	elseif method == "fire" then
		return "Fire"
	elseif method == "invoke" then
		return "Invoke"
	end
	return method
end

local function isRemoteLike(instance)
	return typeof(instance) == "Instance"
		and (
			instance:IsA("RemoteEvent")
			or instance:IsA("RemoteFunction")
			or instance:IsA("BindableEvent")
			or instance:IsA("BindableFunction")
			or instance.ClassName == "UnreliableRemoteEvent"
		)
end

local function getRemoteMethod(instance, method)
	method = normalizeMethod(method)
	if type(method) ~= "string" or not isRemoteLike(instance) then
		return nil
	end

	if method == "FireServer" and (instance:IsA("RemoteEvent") or instance.ClassName == "UnreliableRemoteEvent") then
		return method
	elseif method == "InvokeServer" and instance:IsA("RemoteFunction") then
		return method
	elseif method == "Fire" and instance:IsA("BindableEvent") then
		return method
	elseif method == "Invoke" and instance:IsA("BindableFunction") then
		return method
	end

	return nil
end

local function getRemotePath(instance)
	if typeof(instance) ~= "Instance" then
		return tostring(instance)
	end

	return instance:GetFullName()
end

local function getRemoteKey(instance)
	if typeof(instance) ~= "Instance" then
		return tostring(instance)
	end

	local ok, debugId = pcall(function()
		return instance:GetDebugId(0)
	end)
	if ok and type(debugId) == "string" and debugId ~= "" then
		return debugId
	end

	return instance:GetFullName()
end

local function getCallingScriptPath()
	local getter = getPotassiumApi().getcallingscript
	if type(getter) ~= "function" then
		return nil
	end

	local ok, scriptInstance = pcall(getter)
	if not ok or typeof(scriptInstance) ~= "Instance" then
		return nil
	end

	return scriptInstance:GetFullName()
end

local function getDebugFunction()
	local getter = getPotassiumApi().debug_getinfo
	if type(getter) ~= "function" then
		return nil
	end

	local ok, info = pcall(getter, 3)
	if ok and type(info) == "table" then
		return info.func
	end

	return nil
end

local function classMethodPairs()
	return {
		{ "RemoteEvent", "FireServer" },
		{ "RemoteFunction", "InvokeServer" },
		{ "BindableEvent", "Fire" },
		{ "BindableFunction", "Invoke" },
		{ "UnreliableRemoteEvent", "FireServer" },
	}
end

local function createHookClosure(fn)
	local newCClosure = getPotassiumApi().newcclosure
	if type(newCClosure) == "function" then
		return newCClosure(fn)
	end
	return fn
end

local function addRoot(roots, seen, instance)
	if typeof(instance) ~= "Instance" or seen[instance] then
		return
	end

	seen[instance] = true
	table.insert(roots, instance)
end

function RemoteSpyEngine.new(config)
	config = config or {}

	local self = setmetatable({
		enabled = false,
		records = {},
		recordsByKey = {},
		logs = {},
		connections = {},
		inboundConnections = {},
		nextCallId = 0,
		maxGlobalLogs = tonumber(config.MaxGlobalLogs) or 300,
		maxLogsPerRemote = tonumber(config.MaxLogsPerRemote) or 140,
		onCapture = config.OnCapture,
		onRecordsChanged = config.OnRecordsChanged,
		diagnostics = {},
		bridge = getBridge(),
	}, RemoteSpyEngine)

	self:_refreshDiagnostics()
	self.bridge.callback = function(direction, remote, method, args, hookName)
		self:_capture(direction, remote, method, args, hookName)
	end
	self.bridge.enabled = self.enabled

	return self
end

function RemoteSpyEngine:_refreshDiagnostics()
	local api = getPotassiumApi()
	local executorName = nil
	local executorVersion = nil
	if type(api.identifyexecutor) == "function" then
		local ok, name, version = pcall(api.identifyexecutor)
		if ok then
			executorName = tostring(name)
			executorVersion = tostring(version)
		end
	end

	self.diagnostics = {
		checkcaller = type(api.checkcaller) == "function",
		debug_getinfo = type(api.debug_getinfo) == "function",
		executorName = executorName,
		executorVersion = executorVersion,
		getcallingscript = type(api.getcallingscript) == "function",
		getinstances = type(api.getinstances) == "function",
		getnamecallmethod = type(api.getnamecallmethod) == "function",
		getnilinstances = type(api.getnilinstances) == "function",
		getrawmetatable = type(api.getrawmetatable) == "function",
		hookfunction = type(api.hookfunction) == "function",
		hookmetamethod = type(api.hookmetamethod) == "function",
		isreadonly = type(api.isreadonly) == "function",
		newcclosure = type(api.newcclosure) == "function",
		setreadonly = type(api.setreadonly) == "function",
	}
end

function RemoteSpyEngine:GetDiagnostics()
	self:_refreshDiagnostics()
	self.diagnostics.directError = self.bridge.directError
	self.diagnostics.enabled = self.enabled
	self.diagnostics.lastScanError = self.lastScanError
	self.diagnostics.methods = self.bridge.methods or {}
	self.diagnostics.namecallError = self.bridge.namecallError
	self.diagnostics.lastCapture = self.lastCapture
	return self.diagnostics
end

function RemoteSpyEngine:SetCaptureCallback(callback)
	self.onCapture = callback
end

function RemoteSpyEngine:SetRecordsChangedCallback(callback)
	self.onRecordsChanged = callback
end

function RemoteSpyEngine:IsRemoteLike(instance)
	return isRemoteLike(instance)
end

function RemoteSpyEngine:GetRemoteKey(instance)
	return getRemoteKey(instance)
end

function RemoteSpyEngine:GetRemotePath(instance)
	return getRemotePath(instance)
end

function RemoteSpyEngine:_ensureRecord(remote)
	if not isRemoteLike(remote) then
		return nil, false
	end

	local key = getRemoteKey(remote)
	local record = self.recordsByKey[key]
	local created = false
	if record == nil then
		record = {
			Instance = remote,
			Key = key,
			Name = remote.Name,
			ClassName = remote.ClassName,
			Path = getRemotePath(remote),
			Calls = 0,
			Logs = {},
			LastCall = nil,
		}
		self.recordsByKey[key] = record
		table.insert(self.records, record)
		created = true
	else
		record.Instance = remote
		record.Name = remote.Name
		record.ClassName = remote.ClassName
		record.Path = getRemotePath(remote)
	end

	return record, created
end

function RemoteSpyEngine:_capture(direction, remote, method, args, hookName)
	if not self.enabled or not isRemoteLike(remote) then
		return
	end

	method = normalizeMethod(method)
	if getRemoteMethod(remote, method) == nil and method ~= "OnClientEvent" and method ~= "Event" then
		return
	end

	args = type(args) == "table" and args or {}
	args.n = tonumber(args.n) or #args

	local record, created = self:_ensureRecord(remote)
	if record == nil then
		return
	end

	self.nextCallId = self.nextCallId + 1
	record.Calls = record.Calls + 1

	local call = {
		Id = self.nextCallId,
		RecordCall = record.Calls,
		Remote = remote,
		RemoteKey = record.Key,
		RemoteName = record.Name,
		ClassName = record.ClassName,
		Path = record.Path,
		Direction = direction or "OUT",
		Method = tostring(method or "?"),
		Args = args,
		ArgCount = args.n,
		Hook = hookName or "?",
		Time = os.clock(),
		Timestamp = os.date("%H:%M:%S"),
		Script = getCallingScriptPath(),
		Func = getDebugFunction(),
	}

	record.LastCall = call
	table.insert(record.Logs, 1, call)
	while #record.Logs > self.maxLogsPerRemote do
		table.remove(record.Logs)
	end

	table.insert(self.logs, 1, call)
	while #self.logs > self.maxGlobalLogs do
		table.remove(self.logs)
	end

	self.lastCapture = {
		id = call.Id,
		path = call.Path,
		method = call.Method,
		hook = call.Hook,
		argCount = call.ArgCount,
		timestamp = call.Timestamp,
	}

	if created and type(self.onRecordsChanged) == "function" then
		self.onRecordsChanged(record)
	end
	if type(self.onCapture) == "function" then
		self.onCapture(record, call)
	end
end

function RemoteSpyEngine:_connectInbound(remote)
	if self.inboundConnections[remote] ~= nil then
		return
	end

	local signal
	local direction = "IN"
	local method = "OnClientEvent"
	if remote:IsA("RemoteEvent") or remote.ClassName == "UnreliableRemoteEvent" then
		signal = remote.OnClientEvent
	elseif remote:IsA("BindableEvent") then
		signal = remote.Event
		direction = "LOCAL"
		method = "Event"
	end

	if signal == nil then
		return
	end

	self.inboundConnections[remote] = signal:Connect(function(...)
		self:_capture(direction, remote, method, packArgs(...), method)
	end)
end

function RemoteSpyEngine:_collectRoots()
	local roots = {}
	local seen = {}

	addRoot(roots, seen, ReplicatedStorage)
	addRoot(roots, seen, ReplicatedFirst)
	addRoot(roots, seen, Workspace)

	local localPlayer = Players.LocalPlayer
	if localPlayer ~= nil then
		addRoot(roots, seen, localPlayer)
		addRoot(roots, seen, localPlayer:FindFirstChildOfClass("PlayerGui"))
		addRoot(roots, seen, localPlayer:FindFirstChildOfClass("Backpack"))
		addRoot(roots, seen, localPlayer.Character)
	end

	return roots
end

function RemoteSpyEngine:Scan()
	local changed = false

	local api = getPotassiumApi()
	local function scanInstanceList(scanner, label)
		if type(scanner) ~= "function" then
			return
		end

		local ok, instances = pcall(scanner)
		if not ok or type(instances) ~= "table" then
			self.lastScanError = ("%s failed: %s"):format(label, tostring(instances))
			return
		end

		for _, instance in ipairs(instances) do
			if isRemoteLike(instance) then
				local _, created = self:_ensureRecord(instance)
				changed = changed or created
				self:_connectInbound(instance)
			end
		end
	end

	scanInstanceList(api.getinstances, "getinstances")
	scanInstanceList(api.getnilinstances, "getnilinstances")

	for _, root in ipairs(self:_collectRoots()) do
		if isRemoteLike(root) then
			local _, created = self:_ensureRecord(root)
			changed = changed or created
			self:_connectInbound(root)
		end

		for _, descendant in ipairs(root:GetDescendants()) do
			if isRemoteLike(descendant) then
				local _, created = self:_ensureRecord(descendant)
				changed = changed or created
				self:_connectInbound(descendant)
			end
		end
	end

	table.sort(self.records, function(left, right)
		if left.Calls ~= right.Calls then
			return left.Calls > right.Calls
		end
		return string.lower(left.Path) < string.lower(right.Path)
	end)

	if changed and type(self.onRecordsChanged) == "function" then
		self.onRecordsChanged()
	end

	return self.records
end

function RemoteSpyEngine:BindMutationWatchers()
	if self.mutationWatchersBound then
		return
	end
	self.mutationWatchersBound = true

	for _, root in ipairs(self:_collectRoots()) do
		table.insert(self.connections, root.DescendantAdded:Connect(function(descendant)
			if isRemoteLike(descendant) then
				local _, created = self:_ensureRecord(descendant)
				self:_connectInbound(descendant)
				if created and type(self.onRecordsChanged) == "function" then
					self.onRecordsChanged()
				end
			end
		end))
	end
end

function RemoteSpyEngine:_installDirectHooks()
	if self.bridge.directInstalled then
		self.bridge.methods.direct = true
		return true
	end

	local hookFunction = getPotassiumApi().hookfunction
	if type(hookFunction) ~= "function" then
		self.bridge.directError = "hookfunction unavailable"
		return false
	end

	local installed = false
	self.bridge.directOriginals = self.bridge.directOriginals or {}

	for _, item in ipairs(classMethodPairs()) do
		local className = item[1]
		local methodName = item[2]
		local hookKey = className .. "." .. methodName
		if self.bridge.directOriginals[hookKey] ~= nil then
			installed = true
		else
			local okSample, sample = pcall(function()
				return Instance.new(className)
			end)
			if okSample and sample ~= nil then
				local originalMethod = sample[methodName]
				sample:Destroy()
				if type(originalMethod) == "function" then
					local original
					local okHook, hookError = pcall(function()
						original = hookFunction(originalMethod, createHookClosure(function(...)
							local remote = ...
							local bridge = getBridge()
							if bridge.enabled == true and type(bridge.callback) == "function" and getRemoteMethod(remote, methodName) ~= nil then
								bridge.callback("OUT", remote, methodName, packArgsAfterFirst(...), "direct")
							end
							return original(...)
						end))
					end)

					if okHook then
						self.bridge.directOriginals[hookKey] = original
						installed = true
					else
						self.bridge.directError = tostring(hookError)
					end
				end
			end
		end
	end

	self.bridge.directInstalled = installed
	if installed then
		self.bridge.methods.direct = true
	end
	return installed
end

function RemoteSpyEngine:_installNamecallHook()
	if self.bridge.namecallInstalled then
		self.bridge.methods.namecall = true
		return true
	end

	local api = getPotassiumApi()
	local getNamecallMethod = api.getnamecallmethod
	if type(getNamecallMethod) ~= "function" then
		self.bridge.namecallError = "getnamecallmethod unavailable"
		return false
	end

	local hookMetaMethod = api.hookmetamethod
	if type(hookMetaMethod) ~= "function" then
		self.bridge.namecallError = "hookmetamethod unavailable"
		return false
	end

	local originalNamecall
	local ok, hookError = pcall(function()
		originalNamecall = hookMetaMethod(game, "__namecall", createHookClosure(function(self, ...)
			local method = normalizeMethod(getNamecallMethod())
			local bridge = getBridge()
			if bridge.enabled == true and type(bridge.callback) == "function" and getRemoteMethod(self, method) ~= nil then
				bridge.callback("OUT", self, method, packArgs(...), "namecall")
			end
			return originalNamecall(self, ...)
		end))
	end)

	if ok then
		self.bridge.namecallInstalled = true
		self.bridge.originalNamecall = originalNamecall
		self.bridge.methods.namecall = true
		return true
	end

	self.bridge.namecallError = tostring(hookError)
	return false
end

function RemoteSpyEngine:InstallHooks()
	local direct = self:_installDirectHooks()
	local namecall = self:_installNamecallHook()
	self:_refreshDiagnostics()
	return direct or namecall
end

function RemoteSpyEngine:SetEnabled(enabled)
	self.enabled = enabled == true
	self.bridge.enabled = self.enabled
	if self.enabled then
		self:InstallHooks()
		self:Scan()
		self:BindMutationWatchers()
	end
end

function RemoteSpyEngine:GetRecords(filterText)
	filterText = string.lower(tostring(filterText or ""))
	local filtered = {}

	for _, record in ipairs(self.records) do
		local matches = filterText == ""
			or string.find(string.lower(record.Name or ""), filterText, 1, true) ~= nil
			or string.find(string.lower(record.ClassName or ""), filterText, 1, true) ~= nil
			or string.find(string.lower(record.Path or ""), filterText, 1, true) ~= nil
		if matches then
			table.insert(filtered, record)
		end
	end

	table.sort(filtered, function(left, right)
		if left.Calls ~= right.Calls then
			return left.Calls > right.Calls
		end
		return string.lower(left.Path) < string.lower(right.Path)
	end)

	return filtered
end

function RemoteSpyEngine:GetRecord(key)
	return self.recordsByKey[key]
end

function RemoteSpyEngine:GetCall(record, callId)
	if record == nil then
		return nil
	end

	for _, call in ipairs(record.Logs) do
		if call.Id == callId then
			return call
		end
	end

	return record.Logs[1]
end

function RemoteSpyEngine:ClearLogs()
	self.logs = {}
	self.nextCallId = 0
	self.lastCapture = nil
	for _, record in ipairs(self.records) do
		record.Calls = 0
		record.Logs = {}
		record.LastCall = nil
	end
	if type(self.onRecordsChanged) == "function" then
		self.onRecordsChanged()
	end
end

function RemoteSpyEngine:Destroy()
	self:SetEnabled(false)
	if self.bridge.callback ~= nil then
		self.bridge.callback = nil
	end
	for _, connection in ipairs(self.connections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	for _, connection in pairs(self.inboundConnections) do
		pcall(function()
			connection:Disconnect()
		end)
	end
	self.connections = {}
	self.inboundConnections = {}
end

RemoteSpyEngine.packArgs = packArgs
RemoteSpyEngine.formatPath = getRemotePath

return RemoteSpyEngine
