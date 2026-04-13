local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local function getGlobalScope()
	if type(getgenv) == "function" then
		return getgenv()
	end

	return _G
end

local function getRemoteState()
	local scope = getGlobalScope()
	local state = scope.__DartRemote

	if state == nil then
		state = {}
		scope.__DartRemote = state
	end

	state.cache = state.cache or {}
	state.repoOwner = state.repoOwner or "PuzzleFP"
	state.repoName = state.repoName or "Dart"
	state.repoRef = state.repoRef or "main"
	state.modulesPath = state.modulesPath or "client/Modules"
	state.rawBaseUrl = state.rawBaseUrl or ("https://raw.githubusercontent.com/%s/%s/%s/"):format(
		state.repoOwner,
		state.repoName,
		state.repoRef
	)
	state.modulesBaseUrl = state.modulesBaseUrl or (state.rawBaseUrl .. state.modulesPath .. "/")

	return state
end

local function httpGet(url)
	local ok, result = pcall(function()
		return game:HttpGet(url)
	end)

	if ok and type(result) == "string" then
		return result
	end

	ok, result = pcall(function()
		return game.HttpGet(game, url)
	end)

	if ok and type(result) == "string" then
		return result
	end

	ok, result = pcall(function()
		return game:GetService("HttpService"):GetAsync(url)
	end)

	if ok and type(result) == "string" then
		return result
	end

	error(("Failed to download %s: %s"):format(url, tostring(result)))
end

local function loadRemoteModule(moduleName)
	local state = getRemoteState()
	local cached = state.cache[moduleName]

	if cached ~= nil then
		return cached
	end

	local url = state.modulesBaseUrl .. moduleName .. ".lua"
	local source = httpGet(url)
	local chunk, compileError = loadstring(source)

	if not chunk then
		error(("Failed to compile %s: %s"):format(url, tostring(compileError)))
	end

	local ok, result = pcall(chunk)
	if not ok then
		error(("Failed to execute %s: %s"):format(url, tostring(result)))
	end

	state.cache[moduleName] = result
	return result
end

local Helpers = loadRemoteModule("Helpers")
local IrisBytecodeViewer = loadRemoteModule("IrisBytecodeViewer")

local ClientApp = {}

local started = false

local function onCharacterAdded(config, character)
	Helpers.debugPrint(config.Debug, ("[Client] Character ready: %s"):format(character.Name))
end

function ClientApp.start(config)
	if started then
		return
	end

	if not RunService:IsClient() then
		error("ClientApp.start must be run from the client")
	end

	local localPlayer = Players.LocalPlayer
	if not localPlayer then
		error("LocalPlayer is not available")
	end

	started = true

	Helpers.debugPrint(config.Debug, ("[Client] %s booting"):format(config.GameName))

	if config.ShowWelcomeNotification then
		Helpers.safeNotify(config.GameName, "Client script loaded.")
	end

	if config.EnableIrisBytecodeViewer then
		local ok, err = pcall(function()
			IrisBytecodeViewer.start(config)
		end)

		if not ok then
			warn(("[Client] Iris viewer failed to start: %s"):format(err))
		end
	end

	onCharacterAdded(config, Helpers.getLocalCharacter(localPlayer))

	localPlayer.CharacterAdded:Connect(function(character)
		onCharacterAdded(config, character)
	end)
end

return ClientApp
