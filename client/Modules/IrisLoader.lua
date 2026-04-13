local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local IrisLoader = {}

local function tryRequire(moduleScript)
	local ok, result = pcall(require, moduleScript)
	if not ok then
		return nil, result
	end

	return result
end

local function ensureInitialized(irisModule)
	if type(irisModule) ~= "table" then
		return nil, "Iris module did not return a table"
	end

	if irisModule.Internal ~= nil then
		return irisModule
	end

	if type(irisModule.Init) == "function" then
		local ok, initialized = pcall(function()
			return irisModule.Init()
		end)

		if ok then
			return initialized
		end

		return nil, initialized
	end

	return nil, "Iris module did not expose Init()"
end

local function findModuleByName(root, name)
	if root == nil then
		return nil
	end

	return root:FindFirstChild(name, true)
end

function IrisLoader.load(config, modulesFolder)
	if config.Iris ~= nil then
		return ensureInitialized(config.Iris)
	end

	local moduleName = config.IrisModuleName or "Iris"
	local searchRoots = {
		modulesFolder,
		modulesFolder and modulesFolder.Parent,
		ReplicatedStorage,
		StarterPlayer,
	}

	for _, root in ipairs(searchRoots) do
		local candidate = findModuleByName(root, moduleName)
		if candidate and candidate:IsA("ModuleScript") then
			local required, requireError = tryRequire(candidate)
			if required ~= nil then
				return ensureInitialized(required)
			end

			return nil, requireError
		end
	end

	if type(getgenv) == "function" then
		local env = getgenv()
		if env and env.Iris ~= nil then
			return ensureInitialized(env.Iris)
		end
	end

	return nil, ("Unable to find an Iris ModuleScript named %q"):format(moduleName)
end

return IrisLoader
