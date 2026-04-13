local IrisLoader = {}

local function getGlobalScope()
	if type(getgenv) == "function" then
		return getgenv()
	end

	return _G
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
			return irisModule.Init(nil, nil, true)
		end)

		if ok then
			return initialized
		end

		return nil, initialized
	end

	return nil, "Iris module did not expose Init()"
end

local function trimTrailingSlash(url)
	return (url:gsub("/+$", ""))
end

local function tryHttpGet(url)
	local ok, result = pcall(function()
		return game:HttpGet(url)
	end)

	if ok and type(result) == "string" then
		return result, nil
	end

	ok, result = pcall(function()
		return game.HttpGet(game, url)
	end)

	if ok and type(result) == "string" then
		return result, nil
	end

	ok, result = pcall(function()
		return game:GetService("HttpService"):GetAsync(url)
	end)

	if ok and type(result) == "string" then
		return result, nil
	end

	return nil, tostring(result)
end

local function httpGet(url)
	local source, err = tryHttpGet(url)
	if source ~= nil then
		return source
	end

	error(("Failed to download %s: %s"):format(url, tostring(err)))
end

local function executeLoadstring(source, chunkName)
	local chunk, compileError = loadstring(source)
	if not chunk then
		return nil, ("Failed to compile %s: %s"):format(chunkName, tostring(compileError))
	end

	local ok, result = pcall(chunk)
	if not ok then
		return nil, ("Failed to execute %s: %s"):format(chunkName, tostring(result))
	end

	return result
end

local function splitPath(path)
	local parts = {}

	if path == nil or path == "" then
		return parts
	end

	for part in string.gmatch(path, "[^/]+") do
		table.insert(parts, part)
	end

	return parts
end

local function joinPath(parts, maxIndex)
	local stopIndex = maxIndex or #parts
	if stopIndex <= 0 then
		return ""
	end

	return table.concat(parts, "/", 1, stopIndex)
end

local function getParentPath(path)
	local parts = splitPath(path)
	if #parts == 0 then
		return nil
	end

	return joinPath(parts, #parts - 1)
end

local function getNodeName(path, fallbackName)
	local parts = splitPath(path)
	return parts[#parts] or fallbackName or "Package"
end

local function getPackageStore()
	local scope = getGlobalScope()
	scope.__DartRemotePackages = scope.__DartRemotePackages or {}
	return scope.__DartRemotePackages
end

local function createPackage(baseUrl, cacheKey, name)
	return {
		baseUrl = trimTrailingSlash(baseUrl),
		cacheKey = cacheKey,
		name = name or "Package",
		modules = {},
		loading = {},
		references = {},
	}
end

local function createReference(package, logicalPath)
	local cacheKey = logicalPath or ""
	local cached = package.references[cacheKey]
	if cached ~= nil then
		return cached
	end

	local reference = {
		__package = package,
		__logicalPath = cacheKey,
	}

	package.references[cacheKey] = setmetatable(reference, {
		__index = function(self, key)
			if key == "Name" then
				return getNodeName(cacheKey, package.name)
			end

			if key == "Parent" then
				local parentPath = getParentPath(cacheKey)
				if parentPath == nil then
					return nil
				end

				return createReference(package, parentPath)
			end

			if key == "ClassName" then
				return "ModuleScript"
			end

			if key == "IsA" then
				return function(_, className)
					return className == "ModuleScript" or className == "LuaSourceContainer" or className == "Instance"
				end
			end

			if key == "WaitForChild" then
				return function(_, childName)
					local childPath = cacheKey == "" and childName or (cacheKey .. "/" .. childName)
					return createReference(package, childPath)
				end
			end

			if key == "GetFullName" then
				return function()
					if cacheKey == "" then
						return package.name
					end

					return package.name .. "." .. cacheKey:gsub("/", ".")
				end
			end

			local childPath = cacheKey == "" and key or (cacheKey .. "/" .. key)
			return createReference(package, childPath)
		end,
	})

	return package.references[cacheKey]
end

local function buildCandidateUrls(package, logicalPath)
	if logicalPath == "" then
		return {
			package.baseUrl .. "/init.lua",
		}
	end

	return {
		package.baseUrl .. "/" .. logicalPath .. ".lua",
		package.baseUrl .. "/" .. logicalPath .. "/init.lua",
	}
end

local function fetchPackageSource(package, logicalPath)
	local lastError

	for _, url in ipairs(buildCandidateUrls(package, logicalPath)) do
		local source, err = tryHttpGet(url)
		if source ~= nil then
			return url, source
		end

		lastError = err
	end

	return nil, nil, lastError
end

local function loadPackageModule(package, logicalPath)
	local cacheKey = logicalPath or ""
	local cached = package.modules[cacheKey]

	if cached ~= nil then
		return cached
	end

	if package.loading[cacheKey] then
		error(("Circular remote module load detected for %s"):format(cacheKey == "" and package.name or cacheKey))
	end

	local url, source, fetchError = fetchPackageSource(package, cacheKey)
	if source == nil then
		error(("Unable to resolve remote module %s from %s: %s"):format(
			cacheKey == "" and package.name or cacheKey,
			package.baseUrl,
			tostring(fetchError)
		))
	end

	local wrappedSource = "return function(require, script)\n" .. source .. "\nend"
	local factory, compileError = executeLoadstring(wrappedSource, url)
	if factory == nil then
		error(compileError)
	end

	package.loading[cacheKey] = true

	local function remoteRequire(target)
		if type(target) == "table" and rawget(target, "__package") == package then
			return loadPackageModule(package, rawget(target, "__logicalPath") or "")
		end

		if type(target) == "string" then
			return loadPackageModule(package, target)
		end

		error(("Unsupported remote require target: %s"):format(typeof(target)))
	end

	local ok, result = pcall(factory, remoteRequire, createReference(package, cacheKey))
	package.loading[cacheKey] = nil

	if not ok then
		error(("Failed to execute %s: %s"):format(url, tostring(result)))
	end

	package.modules[cacheKey] = result
	return result
end

local function loadSingleFileUrl(url)
	local source = httpGet(url)
	return executeLoadstring(source, url)
end

local function loadRemotePackage(config)
	local baseUrl = config.IrisPackageBaseUrl
	if type(baseUrl) ~= "string" or baseUrl == "" then
		return nil, "Config.IrisPackageBaseUrl is not set"
	end

	local packageStore = getPackageStore()
	local cacheKey = config.IrisPackageCacheKey or baseUrl
	local package = packageStore[cacheKey]

	if package == nil then
		package = createPackage(baseUrl, cacheKey, "Iris")
		packageStore[cacheKey] = package
	end

	local ok, result = pcall(function()
		return loadPackageModule(package, "")
	end)

	if not ok then
		return nil, result
	end

	return result
end

function IrisLoader.load(config)
	if config.Iris ~= nil then
		return ensureInitialized(config.Iris)
	end

	if type(getgenv) == "function" then
		local env = getgenv()
		if env and env.Iris ~= nil then
			return ensureInitialized(env.Iris)
		end
	end

	if type(config.IrisLoadstringUrl) == "string" and config.IrisLoadstringUrl ~= "" then
		local result, loadError = loadSingleFileUrl(config.IrisLoadstringUrl)
		if result ~= nil then
			return ensureInitialized(result)
		end

		return nil, loadError
	end

	local result, loadError = loadRemotePackage(config)
	if result ~= nil then
		return ensureInitialized(result)
	end

	return nil, loadError
end

return IrisLoader
