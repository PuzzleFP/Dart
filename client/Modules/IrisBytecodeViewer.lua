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

local LuauChunk = loadRemoteModule("LuauChunk")
local LuauBytecode = loadRemoteModule("LuauBytecode")
local IrisLoader = loadRemoteModule("IrisLoader")
local Players = game:GetService("Players")

local IrisBytecodeViewer = {}

local started = false

local function trimText(text)
	return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function splitLines(text)
	local lines = {}

	for line in string.gmatch(text, "([^\n]*)\n?") do
		if line == "" and #lines > 0 and lines[#lines] == "" then
			break
		end

		table.insert(lines, line)
	end

	return lines
end

local function containsFilter(text, filter)
	if filter == "" then
		return true
	end

	return string.find(string.lower(text), string.lower(filter), 1, true) ~= nil
end

local function formatChunkResult(chunk, showRawOpcode, metadata)
	local prettyOutput = LuauChunk.formatPrettyChunk(chunk, {
		showRawOpcode = showRawOpcode,
	})

	local result = {
		chunk = chunk,
		prettyOutput = prettyOutput,
		prettyLines = splitLines(prettyOutput),
	}

	if metadata then
		for key, value in pairs(metadata) do
			result[key] = value
		end
	end

	return result
end

local function safeParseFile(path, inputFormat, showRawOpcode)
	local ok, chunk = pcall(function()
		return LuauChunk.parseFile(path, {
			inputFormat = inputFormat,
		})
	end)

	if not ok then
		return nil, chunk
	end

	return formatChunkResult(chunk, showRawOpcode, {
		sourceKind = "file",
		sourceLabel = path,
	}), nil
end

local function splitInstancePath(path)
	local parts = {}

	for part in string.gmatch(path, "[^%./\\]+") do
		table.insert(parts, part)
	end

	return parts
end

local function tryGetInstanceProperty(instance, propertyName)
	local ok, value = pcall(function()
		return instance[propertyName]
	end)

	if ok and typeof(value) == "Instance" then
		return value
	end

	return nil
end

local function resolveRootSegment(segment)
	if segment == "game" or segment == "Game" then
		return game
	end

	local ok, service = pcall(function()
		return game:GetService(segment)
	end)

	if ok and typeof(service) == "Instance" then
		return service
	end

	return game:FindFirstChild(segment)
end

local function resolveInstanceByPath(path)
	local normalizedPath = trimText(path)
	if normalizedPath == "" then
		error("No script path provided")
	end

	local parts = splitInstancePath(normalizedPath)
	if #parts == 0 then
		error(("Invalid script path %q"):format(normalizedPath))
	end

	local current = resolveRootSegment(parts[1])
	if current == nil then
		error(("Unable to resolve root segment %q"):format(parts[1]))
	end

	for index = 2, #parts do
		local segment = parts[index]
		local nextInstance = tryGetInstanceProperty(current, segment)

		if nextInstance == nil then
			nextInstance = current:FindFirstChild(segment)
		end

		if nextInstance == nil then
			error(("Unable to resolve %q under %s"):format(segment, current:GetFullName()))
		end

		current = nextInstance
	end

	return current
end

local function safeParseScript(scriptPath, showRawOpcode)
	local ok, scriptInstance = pcall(function()
		return resolveInstanceByPath(scriptPath)
	end)

	if not ok then
		return nil, scriptInstance
	end

	ok, scriptInstance = pcall(function()
		if not scriptInstance:IsA("LuaSourceContainer") then
			error(("Resolved instance is %s, not a LuaSourceContainer"):format(scriptInstance.ClassName))
		end

		return scriptInstance
	end)

	if not ok then
		return nil, scriptInstance
	end

	local chunk
	ok, chunk = pcall(function()
		return LuauChunk.parseScriptBytecode(scriptInstance)
	end)

	if not ok then
		return nil, chunk
	end

	return formatChunkResult(chunk, showRawOpcode, {
		sourceKind = "script",
		sourceLabel = scriptInstance:GetFullName(),
		scriptPath = scriptPath,
	}), nil
end

local function isScriptLike(instance)
	return instance:IsA("LuaSourceContainer")
end

local function collectScriptBrowserRoots()
	local roots = {}
	local seen = {}

	local function push(instance)
		if typeof(instance) ~= "Instance" or seen[instance] then
			return
		end

		seen[instance] = true
		table.insert(roots, instance)
	end

	push(game:GetService("ReplicatedFirst"))
	push(game:GetService("ReplicatedStorage"))
	push(game:GetService("StarterGui"))
	push(game:GetService("StarterPack"))
	push(game:GetService("StarterPlayer"))
	push(game:GetService("Workspace"))

	local localPlayer = Players.LocalPlayer
	if localPlayer then
		push(localPlayer)
		push(localPlayer:FindFirstChildOfClass("PlayerScripts"))
		push(localPlayer:FindFirstChildOfClass("PlayerGui"))
		push(localPlayer:FindFirstChildOfClass("Backpack"))
	end

	return roots
end

local function buildScriptBrowserNode(instance)
	local childNodes = {}

	for _, child in ipairs(instance:GetChildren()) do
		local childNode = buildScriptBrowserNode(child)
		if childNode ~= nil then
			table.insert(childNodes, childNode)
		end
	end

	if not isScriptLike(instance) and #childNodes == 0 then
		return nil
	end

	table.sort(childNodes, function(left, right)
		if left.isScript ~= right.isScript then
			return not left.isScript
		end

		return string.lower(left.name) < string.lower(right.name)
	end)

	return {
		instance = instance,
		name = instance.Name,
		path = instance:GetFullName(),
		className = instance.ClassName,
		isScript = isScriptLike(instance),
		children = childNodes,
	}
end

local function buildScriptBrowserTree()
	local roots = {}

	for _, root in ipairs(collectScriptBrowserRoots()) do
		local node = buildScriptBrowserNode(root)
		if node ~= nil then
			table.insert(roots, node)
		end
	end

	table.sort(roots, function(left, right)
		return string.lower(left.name) < string.lower(right.name)
	end)

	return roots
end

local function renderScriptBrowserNode(Iris, node, selectedPath, onOpen)
	local label = ("%s [%s]"):format(node.name, node.className)

	if #node.children > 0 then
		Iris.Tree({ label })
		do
			if node.isScript then
				local buttonText = selectedPath == node.path and "Viewing" or "Open"
				if Iris.SmallButton({ buttonText }).clicked() then
					onOpen(node.path)
				end
			end

			for _, childNode in ipairs(node.children) do
				renderScriptBrowserNode(Iris, childNode, selectedPath, onOpen)
			end
		end
		Iris.End()
		return
	end

	local buttonText = selectedPath == node.path and "Viewing" or "Open"
	if Iris.SmallButton({ buttonText }).clicked() then
		onOpen(node.path)
	end

	Iris.SameLine()
	do
		Iris.Text({ label })
	end
	Iris.End()
end

local function renderScriptBrowser(Iris, scriptBrowserTree, scriptBrowserError, selectedPath, onOpen, onRefresh)
	Iris.CollapsingHeader({ "Script Browser" })
	do
		if Iris.Button({ "Refresh Tree" }).clicked() then
			onRefresh()
		end

		if scriptBrowserError ~= nil then
			Iris.TextColored({ "Tree Error: " .. tostring(scriptBrowserError), Color3.fromRGB(255, 110, 110) })
		elseif #scriptBrowserTree == 0 then
			Iris.Text({ "No scripts discovered in the current client view." })
		else
			for _, rootNode in ipairs(scriptBrowserTree) do
				renderScriptBrowserNode(Iris, rootNode, selectedPath, onOpen)
			end
		end
	end
	Iris.End()
end

local function renderOverview(Iris, result)
	local chunk = result.chunk

	Iris.SeparatorText({ "Chunk Overview" })
	Iris.Text({ ("Version: %d"):format(chunk.version) })
	Iris.Text({ ("Type Version: %d"):format(chunk.typesVersion or 0) })
	Iris.Text({ ("Proto Count: %d"):format(chunk.protoCount or 0) })
	Iris.Text({ ("Main Proto: %d"):format(chunk.mainProtoIndex or 0) })
	Iris.Text({ ("Opcode Decode Multiplier: %d"):format(chunk.opcodeDecodeMultiplier or 1) })
end

local function renderStrings(Iris, result)
	local chunk = result.chunk

	Iris.CollapsingHeader({ ("String Table (%d entries)"):format(#chunk.strings) })
	do
		for index, value in ipairs(chunk.strings) do
			Iris.Text({ ("S%d = %q"):format(index, value) })
		end
	end
	Iris.End()
end

local function renderConstants(Iris, proto)
	Iris.Tree({ ("Constant Table (%d entries)"):format(#proto.constants) })
	do
		for index, constant in ipairs(proto.constants) do
			Iris.Text({ ("K%d = %s"):format(index - 1, LuauBytecode.formatConstant(constant)) })
		end
	end
	Iris.End()
end

local function renderInstructions(Iris, proto, filterText, showRawOpcodes)
	Iris.Tree({ ("Instructions (%d words)"):format(proto.sizeCode) })
	do
		for _, instruction in ipairs(proto.disassembly.instructions) do
			local line = LuauBytecode.formatInstruction(instruction, {
				constants = proto.constants,
				showRawOpcode = showRawOpcodes,
			})

			if containsFilter(line, filterText) then
				Iris.TextWrapped({ line })
			end
		end

		for _, err in ipairs(proto.disassembly.errors) do
			Iris.TextColored({ "[error] " .. err, Color3.fromRGB(255, 110, 110) })
		end
	end
	Iris.End()
end

local function renderProto(Iris, proto, filterText, showConstants, showRawOpcodes, isMain)
	Iris.CollapsingHeader({ ("Proto %d%s"):format(proto.index, isMain and " <main>" or "") })
	do
		Iris.Text({ ("Debug Name: %s"):format(proto.debugName or "<anonymous>") })
		Iris.Text({ ("Params=%d Upvalues=%d MaxStack=%d Vararg=%s"):format(
			proto.numParams,
			proto.numUpvalues,
			proto.maxStackSize,
			tostring(proto.isVararg)
		) })

		if proto.behaviorSummary then
			Iris.TextColored({ "Likely Behavior: " .. proto.behaviorSummary, Color3.fromRGB(140, 220, 160) })
		end

		if showConstants then
			renderConstants(Iris, proto)
		end

		renderInstructions(Iris, proto, filterText, showRawOpcodes)
	end
	Iris.End()
end

local function renderPrettyOutput(Iris, result, filterText)
	Iris.CollapsingHeader({ "Pretty Output" })
	do
		for _, line in ipairs(result.prettyLines) do
			if containsFilter(line, filterText) then
				Iris.TextWrapped({ line == "" and " " or line })
			end
		end
	end
	Iris.End()
end

function IrisBytecodeViewer.start(config)
	if started then
		return
	end

	local Iris, irisError = IrisLoader.load(config)
	if not Iris then
		error(irisError)
	end

	started = true

	local sourceMode = Iris.State(config.DefaultBytecodeSourceMode or "script")
	local scriptPath = Iris.State(config.DefaultScriptPath or "")
	local filePath = Iris.State(config.DefaultBytecodeFilePath or "")
	local inputFormat = Iris.State(config.DefaultBytecodeInputFormat or "binary")
	local filterText = Iris.State("")
	local showStrings = Iris.State(config.ShowStringTableByDefault == true)
	local showConstants = Iris.State(config.ShowConstantTableByDefault ~= false)
	local showRawOpcodes = Iris.State(config.ShowRawOpcodes ~= false)
	local windowSize = Iris.State(Vector2.new(820, 680))
	local windowPosition = Iris.State(Vector2.new(60, 40))

	local lastResult = nil
	local lastError = nil
	local lastLoadedSourceMode = nil
	local lastLoadedTarget = nil
	local scriptBrowserTree = {}
	local scriptBrowserError = nil

	local function refreshScriptBrowser()
		local ok, result = pcall(buildScriptBrowserTree)
		if ok then
			scriptBrowserTree = result
			scriptBrowserError = nil
			return
		end

		scriptBrowserTree = {}
		scriptBrowserError = result
	end

	local function loadFileTarget()
		local path = filePath.value
		if path == nil or path == "" then
			lastResult = nil
			lastLoadedSourceMode = nil
			lastLoadedTarget = nil
			lastError = "No file path provided"
			return
		end

		local result, err = safeParseFile(path, inputFormat.value, showRawOpcodes.value)
		lastResult = result
		lastLoadedSourceMode = "file"
		lastLoadedTarget = path
		lastError = err
	end

	local function loadScriptTarget()
		local path = trimText(scriptPath.value)
		if path == "" then
			lastResult = nil
			lastLoadedSourceMode = nil
			lastLoadedTarget = nil
			lastError = "No script path provided"
			return
		end

		local result, err = safeParseScript(path, showRawOpcodes.value)
		lastResult = result
		lastLoadedSourceMode = "script"
		lastLoadedTarget = path
		lastError = err
	end

	local function loadCurrentTarget()
		if sourceMode.value == "script" then
			loadScriptTarget()
			return
		end

		loadFileTarget()
	end

	local function reloadLastTarget()
		if lastLoadedSourceMode == "script" and lastLoadedTarget ~= nil then
			sourceMode:set("script")
			scriptPath:set(lastLoadedTarget)
			loadScriptTarget()
			return
		end

		if lastLoadedSourceMode == "file" and lastLoadedTarget ~= nil then
			sourceMode:set("file")
			filePath:set(lastLoadedTarget)
			loadFileTarget()
			return
		end
	end

	local function openScriptFromBrowser(path)
		sourceMode:set("script")
		scriptPath:set(path)
		loadScriptTarget()
	end

	refreshScriptBrowser()

	if sourceMode.value == "script" and trimText(scriptPath.value) ~= "" then
		loadScriptTarget()
	elseif filePath.value ~= "" then
		loadFileTarget()
	end

	Iris:Connect(function()
		Iris.Window({ "Luau Bytecode Viewer" }, {
			size = windowSize,
			position = windowPosition,
		})
		do
			Iris.Text({ "Inspect Luau bytecode from a live script instance or a raw bytecode file." })
			renderScriptBrowser(
				Iris,
				scriptBrowserTree,
				scriptBrowserError,
				lastResult and lastResult.sourceKind == "script" and lastResult.sourceLabel or nil,
				openScriptFromBrowser,
				refreshScriptBrowser
			)

			Iris.SeparatorText({ "Source" })
			Iris.RadioButton({ "Script", "script" }, { index = sourceMode })
			Iris.SameLine()
			Iris.RadioButton({ "File", "file" }, { index = sourceMode })
			Iris.End()

			if sourceMode.value == "script" then
				Iris.PushConfig({ ContentWidth = UDim.new(1, -160) })
				Iris.InputText({ "Script Instance Path" }, { text = scriptPath })
				Iris.PopConfig()

				Iris.SameLine()
				do
					if Iris.Button({ "Load Script" }).clicked() then
						loadScriptTarget()
					end

					if Iris.Button({ "Reload" }).clicked() and lastLoadedTarget ~= nil then
						reloadLastTarget()
					end
				end
				Iris.End()

				Iris.TextWrapped({ "Example: Players.LocalPlayer.PlayerScripts.YourLocalScript" })
			else
				Iris.PushConfig({ ContentWidth = UDim.new(1, -160) })
				Iris.InputText({ "Bytecode File Path" }, { text = filePath })
				Iris.PopConfig()

				Iris.SameLine()
				do
					if Iris.Button({ "Load File" }).clicked() then
						loadFileTarget()
					end

					if Iris.Button({ "Reload" }).clicked() and lastLoadedTarget ~= nil then
						reloadLastTarget()
					end
				end
				Iris.End()

				Iris.SameLine()
				do
					Iris.RadioButton({ "Binary", "binary" }, { index = inputFormat })
					Iris.RadioButton({ "Hex", "hex" }, { index = inputFormat })
				end
				Iris.End()
			end

			Iris.PushConfig({ ContentWidth = UDim.new(1, -160) })
			Iris.InputText({ "Filter" }, { text = filterText })
			Iris.PopConfig()

			Iris.SameLine()
			do
				Iris.Checkbox({ "Show Strings" }, { isChecked = showStrings })
				Iris.Checkbox({ "Show Constants" }, { isChecked = showConstants })
				Iris.Checkbox({ "Show Raw Opcodes" }, { isChecked = showRawOpcodes })
				if Iris.Button({ "Reformat" }).clicked() and lastLoadedTarget ~= nil then
					reloadLastTarget()
				end
				if Iris.Button({ "Load Current" }).clicked() then
					loadCurrentTarget()
				end
			end
			Iris.End()

			Iris.Separator()

			if lastError then
				Iris.TextColored({ "Load Error: " .. tostring(lastError), Color3.fromRGB(255, 110, 110) })
			elseif lastResult == nil then
				Iris.Text({ "No bytecode source loaded yet." })
			else
				Iris.TextColored({ "Loaded: " .. tostring(lastResult.sourceLabel or lastLoadedTarget), Color3.fromRGB(140, 210, 255) })

				renderOverview(Iris, lastResult)
				renderPrettyOutput(Iris, lastResult, filterText.value)

				if showStrings.value then
					renderStrings(Iris, lastResult)
				end

				Iris.SeparatorText({ "Protos" })
				for _, proto in ipairs(lastResult.chunk.protos) do
					renderProto(
						Iris,
						proto,
						filterText.value,
						showConstants.value,
						showRawOpcodes.value,
						proto.index == lastResult.chunk.mainProtoIndex
					)
				end
			end
		end
		Iris.End()
	end)
end

return IrisBytecodeViewer
