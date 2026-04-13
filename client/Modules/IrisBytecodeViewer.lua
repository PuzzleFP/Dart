local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")

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
local NativeUi = loadRemoteModule("NativeUi")

local BytecodeViewer = {}

local started = false
local GUI_NAME = "EclipsisControlGui"

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

local function formatChunkResult(chunk, metadata)
	local result = {
		chunk = chunk,
	}

	if metadata ~= nil then
		for key, value in pairs(metadata) do
			result[key] = value
		end
	end

	return result
end

local function safeParseFile(path, inputFormat)
	local ok, chunk = pcall(function()
		return LuauChunk.parseFile(path, {
			inputFormat = inputFormat,
		})
	end)

	if not ok then
		return nil, chunk
	end

	return formatChunkResult(chunk, {
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

local function safeParseScript(scriptPath)
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

	return formatChunkResult(chunk, {
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
	if localPlayer ~= nil then
		push(localPlayer)
		push(localPlayer:FindFirstChildOfClass("PlayerScripts"))
		push(localPlayer:FindFirstChildOfClass("PlayerGui"))
		push(localPlayer:FindFirstChildOfClass("Backpack"))
	end

	return roots
end

local function buildScriptBrowserNode(instance, depth)
	local childNodes = {}

	for _, child in ipairs(instance:GetChildren()) do
		local childNode = buildScriptBrowserNode(child, depth + 1)
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
		name = instance.Name,
		path = instance:GetFullName(),
		className = instance.ClassName,
		isScript = isScriptLike(instance),
		children = childNodes,
		depth = depth,
	}
end

local function buildScriptBrowserTree()
	local roots = {}

	for _, root in ipairs(collectScriptBrowserRoots()) do
		local node = buildScriptBrowserNode(root, 0)
		if node ~= nil then
			table.insert(roots, node)
		end
	end

	table.sort(roots, function(left, right)
		return string.lower(left.name) < string.lower(right.name)
	end)

	return roots
end

local function appendSection(lines, title)
	if #lines > 0 then
		table.insert(lines, "")
	end

	table.insert(lines, title)
end

local function appendKeyValue(lines, label, value)
	table.insert(lines, ("  %-16s %s"):format(label .. ":", tostring(value)))
end

local function formatCodeView(chunk, showRawOpcodes)
	local lines = {
		"Code View",
	}

	appendKeyValue(lines, "Version", chunk.version)
	appendKeyValue(lines, "Protos", chunk.protoCount or 0)
	appendKeyValue(lines, "Main Proto", chunk.mainProtoIndex or 0)

	for _, proto in ipairs(chunk.protos) do
		appendSection(lines, ("Proto %d%s"):format(
			proto.index,
			proto.index == chunk.mainProtoIndex and " <main>" or ""
		))

		appendKeyValue(lines, "Debug Name", proto.debugName or "<anonymous>")
		appendKeyValue(lines, "Params", proto.numParams)
		appendKeyValue(lines, "Max Stack", proto.maxStackSize)

		if proto.behaviorSummary then
			appendKeyValue(lines, "Likely", proto.behaviorSummary)
		end

		table.insert(lines, "  Instructions")

		for _, instruction in ipairs(proto.disassembly.instructions) do
			table.insert(lines, "    " .. LuauBytecode.formatInstruction(instruction, {
				constants = proto.constants,
				showRawOpcode = showRawOpcodes,
			}))
		end

		for _, err in ipairs(proto.disassembly.errors) do
			table.insert(lines, "    [error] " .. err)
		end
	end

	return table.concat(lines, "\n")
end

local function formatDataView(chunk)
	local lines = {
		"Data View",
	}

	appendKeyValue(lines, "Byte Count", chunk.byteCount)
	appendKeyValue(lines, "Version", chunk.version)
	appendKeyValue(lines, "Type Version", chunk.typesVersion or 0)
	appendKeyValue(lines, "Protos", chunk.protoCount or 0)
	appendKeyValue(lines, "Main Proto", chunk.mainProtoIndex or 0)
	appendKeyValue(lines, "Strings", chunk.stringCount or 0)

	appendSection(lines, "String Table")
	if #chunk.strings == 0 then
		table.insert(lines, "  <empty>")
	else
		for index, value in ipairs(chunk.strings) do
			table.insert(lines, ("  S%-17d %q"):format(index, value))
		end
	end

	for _, proto in ipairs(chunk.protos) do
		appendSection(lines, ("Proto %d Data"):format(proto.index))
		appendKeyValue(lines, "Debug Name", proto.debugName or "<anonymous>")
		appendKeyValue(lines, "Params", proto.numParams)
		appendKeyValue(lines, "Upvalues", proto.numUpvalues)
		appendKeyValue(lines, "Max Stack", proto.maxStackSize)
		appendKeyValue(lines, "Vararg", proto.isVararg)
		appendKeyValue(lines, "Constants", proto.sizeConstants or #proto.constants)

		table.insert(lines, "  Constants")
		if #proto.constants == 0 then
			table.insert(lines, "    <empty>")
		else
			for index, constant in ipairs(proto.constants) do
				table.insert(lines, ("    K%-16d %s"):format(index - 1, LuauBytecode.formatConstant(constant)))
			end
		end
	end

	return table.concat(lines, "\n")
end

local function filterTreeNode(node, filterText)
	if filterText == "" then
		return node
	end

	local filteredChildren = {}
	for _, child in ipairs(node.children) do
		local filteredChild = filterTreeNode(child, filterText)
		if filteredChild ~= nil then
			table.insert(filteredChildren, filteredChild)
		end
	end

	local matches = containsFilter(node.name, filterText)
		or containsFilter(node.path, filterText)
		or containsFilter(node.className, filterText)

	if not matches and #filteredChildren == 0 then
		return nil
	end

	return {
		name = node.name,
		path = node.path,
		className = node.className,
		isScript = node.isScript,
		children = filteredChildren,
		depth = node.depth,
	}
end

local function getFilteredTree(tree, filterText)
	if filterText == "" then
		return tree
	end

	local filtered = {}
	for _, node in ipairs(tree) do
		local filteredNode = filterTreeNode(node, filterText)
		if filteredNode ~= nil then
			table.insert(filtered, filteredNode)
		end
	end

	return filtered
end

local function makeState(config)
	return {
		activeTab = config.DefaultTab or "main",
		sourceMode = config.DefaultBytecodeSourceMode or "script",
		viewMode = config.DefaultBytecodeViewMode or "code",
		scriptPath = trimText(config.DefaultScriptPath or ""),
		filePath = trimText(config.DefaultBytecodeFilePath or ""),
		inputFormat = config.DefaultBytecodeInputFormat or "binary",
		filterText = "",
		treeFilterText = "",
		showRawOpcodes = config.ShowRawOpcodes ~= false,
		lastResult = nil,
		lastError = nil,
		lastLoadedSourceMode = nil,
		lastLoadedTarget = nil,
		selectedScriptPath = nil,
		scriptBrowserTree = {},
		scriptBrowserError = nil,
		expandedNodes = {},
	}
end

local function destroyExistingGui()
	local existing = CoreGui:FindFirstChild(GUI_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
end

local function makeSectionTitle(parent, text)
	return NativeUi.makeLabel(parent, text, {
		Font = Enum.Font.GothamBold,
		TextSize = 14,
		TextColor3 = NativeUi.Theme.Text,
		Size = UDim2.new(1, 0, 0, 22),
	})
end

local function createGui(state)
	destroyExistingGui()

	local refs = {}

	local screenGui = NativeUi.create("ScreenGui", {
		Name = GUI_NAME,
		DisplayOrder = 999,
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = CoreGui,
	})

	local main = NativeUi.makePanel(screenGui, {
		Name = "Main",
		BackgroundColor3 = NativeUi.Theme.Background,
		Position = UDim2.new(0.5, -500, 0.5, -320),
		Size = UDim2.fromOffset(1000, 640),
	})

	local topBar = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 34),
		Parent = main,
	})
	NativeUi.corner(topBar, 10)

	NativeUi.makeLabel(topBar, "Eclipsis Control", {
		Font = Enum.Font.GothamBlack,
		TextSize = 15,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(0, 150, 1, 0),
	})

	local mainTabButton = NativeUi.makeButton(topBar, "Main", {
		Position = UDim2.fromOffset(168, 4),
		Size = UDim2.fromOffset(62, 24),
		TextSize = 12,
	})

	local bytecodeTabButton = NativeUi.makeButton(topBar, "Bytecode", {
		Position = UDim2.fromOffset(236, 4),
		Size = UDim2.fromOffset(84, 24),
		TextSize = 12,
	})

	local closeButton = NativeUi.makeButton(topBar, "X", {
		Position = UDim2.new(1, -32, 0, 3),
		Size = UDim2.fromOffset(26, 26),
	})

	local resizeGrip = NativeUi.create("TextButton", {
		Name = "ResizeGrip",
		Active = true,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		Position = UDim2.new(1, -24, 1, -24),
		Size = UDim2.fromOffset(18, 18),
		Text = "///",
		TextColor3 = NativeUi.Theme.TextDim,
		TextSize = 10,
		ZIndex = 3,
		Parent = main,
	})

	local mainTabPanel = NativeUi.makePanel(main, {
		Position = UDim2.fromOffset(10, 42),
		Size = UDim2.new(1, -20, 1, -52),
		Visible = false,
	})

	local mainScroll, mainContent = NativeUi.makeScrollList(mainTabPanel, {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 1, -16),
		Padding = 8,
		ContentPadding = 10,
	})

	local mainHeroPanel = NativeUi.makePanel(mainContent, {
		Size = UDim2.new(1, 0, 0, 78),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	NativeUi.makeLabel(mainHeroPanel, "EIC Player Panel", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(12, 10),
		Size = UDim2.new(1, -24, 0, 24),
	})

	NativeUi.makeLabel(mainHeroPanel, "Main controls stay here. Bytecode tools live on their own tab.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 13,
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -24, 0, 18),
	})

	local mainStatusLabel = NativeUi.makeLabel(mainHeroPanel, "Ready", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 54),
		Size = UDim2.new(1, -24, 0, 16),
	})

	local movementPanel = NativeUi.makePanel(mainContent, {
		Size = UDim2.new(1, 0, 0, 152),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local movementTitle = makeSectionTitle(movementPanel, "Movement")
	movementTitle.Position = UDim2.fromOffset(12, 10)

	local walkSpeedLabel = NativeUi.makeLabel(movementPanel, "WalkSpeed", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.fromOffset(88, 24),
	})

	local walkSpeedBox = NativeUi.makeTextBox(movementPanel, "", {
		Position = UDim2.fromOffset(104, 40),
		Size = UDim2.new(1, -198, 0, 28),
		TextSize = 12,
	})

	local walkSpeedButton = NativeUi.makeButton(movementPanel, "Apply", {
		Position = UDim2.new(1, -84, 0, 41),
		Size = UDim2.fromOffset(72, 26),
		TextSize = 12,
	})

	local jumpPowerLabel = NativeUi.makeLabel(movementPanel, "JumpPower", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 76),
		Size = UDim2.fromOffset(88, 24),
	})

	local jumpPowerBox = NativeUi.makeTextBox(movementPanel, "", {
		Position = UDim2.fromOffset(104, 74),
		Size = UDim2.new(1, -198, 0, 28),
		TextSize = 12,
	})

	local jumpPowerButton = NativeUi.makeButton(movementPanel, "Apply", {
		Position = UDim2.new(1, -84, 0, 75),
		Size = UDim2.fromOffset(72, 26),
		TextSize = 12,
	})

	local hipHeightLabel = NativeUi.makeLabel(movementPanel, "HipHeight", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 110),
		Size = UDim2.fromOffset(88, 24),
	})

	local hipHeightBox = NativeUi.makeTextBox(movementPanel, "", {
		Position = UDim2.fromOffset(104, 108),
		Size = UDim2.new(1, -198, 0, 28),
		TextSize = 12,
	})

	local hipHeightButton = NativeUi.makeButton(movementPanel, "Apply", {
		Position = UDim2.new(1, -84, 0, 109),
		Size = UDim2.fromOffset(72, 26),
		TextSize = 12,
	})

	local worldPanel = NativeUi.makePanel(mainContent, {
		Size = UDim2.new(1, 0, 0, 118),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local worldTitle = makeSectionTitle(worldPanel, "World")
	worldTitle.Position = UDim2.fromOffset(12, 10)

	local gravityLabel = NativeUi.makeLabel(worldPanel, "Gravity", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.fromOffset(88, 24),
	})

	local gravityBox = NativeUi.makeTextBox(worldPanel, "", {
		Position = UDim2.fromOffset(104, 40),
		Size = UDim2.new(1, -198, 0, 28),
		TextSize = 12,
	})

	local gravityButton = NativeUi.makeButton(worldPanel, "Apply", {
		Position = UDim2.new(1, -84, 0, 41),
		Size = UDim2.fromOffset(72, 26),
		TextSize = 12,
	})

	local refreshStatsButton = NativeUi.makeButton(worldPanel, "Refresh Stats", {
		Position = UDim2.fromOffset(12, 78),
		Size = UDim2.fromOffset(110, 26),
		TextSize = 12,
	})

	local resetCharacterButton = NativeUi.makeButton(worldPanel, "Reset Character", {
		Position = UDim2.fromOffset(130, 78),
		Size = UDim2.fromOffset(124, 26),
		TextSize = 12,
	})

	local leftPanel = NativeUi.makePanel(main, {
		Position = UDim2.fromOffset(10, 42),
		Size = UDim2.new(0, 284, 1, -52),
	})

	local rightPanel = NativeUi.makePanel(main, {
		Position = UDim2.new(0, 302, 0, 42),
		Size = UDim2.new(1, -312, 1, -52),
	})

	local leftHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 0, 54),
		Parent = leftPanel,
	})

	makeSectionTitle(leftHeader, "Scripts")

	local refreshTreeButton = NativeUi.makeButton(leftHeader, "Refresh", {
		Position = UDim2.new(1, -74, 0, 0),
		Size = UDim2.fromOffset(74, 24),
		TextSize = 12,
	})

	local treeSearchBox = NativeUi.makeTextBox(leftHeader, "", {
		PlaceholderText = "Filter scripts",
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 26),
		TextSize = 12,
	})

	local treeScroll, treeContent = NativeUi.makeScrollList(leftPanel, {
		Position = UDim2.fromOffset(8, 70),
		Size = UDim2.new(1, -16, 1, -78),
		Padding = 4,
		ContentPadding = 6,
	})

	local toolbarPanel = NativeUi.makePanel(rightPanel, {
		Position = UDim2.fromOffset(8, 8),
		Size = UDim2.new(1, -16, 0, 118),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local toolbarContent = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 1, -20),
		Parent = toolbarPanel,
	})

	local statusLabel = NativeUi.makeLabel(toolbarContent, "Ready", {
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -250, 0, 18),
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
	})

	local codeViewButton = NativeUi.makeButton(toolbarContent, "Code", {
		Position = UDim2.new(1, -204, 0, 0),
		Size = UDim2.fromOffset(60, 24),
		TextSize = 12,
	})

	local decompileViewButton = NativeUi.makeButton(toolbarContent, "Decompile", {
		Position = UDim2.new(1, -172, 0, 0),
		Size = UDim2.fromOffset(94, 24),
		TextSize = 12,
	})

	local dataViewButton = NativeUi.makeButton(toolbarContent, "Data", {
		Position = UDim2.new(1, -72, 0, 0),
		Size = UDim2.fromOffset(60, 24),
		TextSize = 12,
	})

	local modeRow = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 28),
		Size = UDim2.new(1, 0, 0, 26),
		Parent = toolbarContent,
	})

	local scriptModeButton = NativeUi.makeButton(modeRow, "Script", {
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(70, 26),
		TextSize = 12,
	})

	local fileModeButton = NativeUi.makeButton(modeRow, "File", {
		Position = UDim2.fromOffset(76, 0),
		Size = UDim2.fromOffset(56, 26),
		TextSize = 12,
	})

	local binaryButton = NativeUi.makeButton(modeRow, "Binary", {
		Position = UDim2.fromOffset(146, 0),
		Size = UDim2.fromOffset(72, 26),
		TextSize = 12,
	})

	local hexButton = NativeUi.makeButton(modeRow, "Hex", {
		Position = UDim2.fromOffset(224, 0),
		Size = UDim2.fromOffset(52, 26),
		TextSize = 12,
	})

	local rawOpcodesButton = NativeUi.makeButton(modeRow, "Raw", {
		Position = UDim2.fromOffset(286, 0),
		Size = UDim2.fromOffset(56, 26),
		TextSize = 12,
	})

	local targetBox = NativeUi.makeTextBox(toolbarContent, "", {
		PlaceholderText = "Players.LocalPlayer.PlayerScripts.YourLocalScript",
		Position = UDim2.fromOffset(0, 58),
		Size = UDim2.new(1, -152, 0, 28),
		TextSize = 12,
	})

	local loadButton = NativeUi.makeButton(toolbarContent, "Load", {
		Position = UDim2.new(1, -144, 0, 59),
		Size = UDim2.fromOffset(66, 26),
		TextSize = 12,
	})

	local reloadButton = NativeUi.makeButton(toolbarContent, "Reload", {
		Position = UDim2.new(1, -72, 0, 59),
		Size = UDim2.fromOffset(66, 26),
		TextSize = 12,
	})

	local filterBox = NativeUi.makeTextBox(toolbarContent, "", {
		PlaceholderText = "Filter output",
		Position = UDim2.fromOffset(0, 90),
		Size = UDim2.new(1, -96, 0, 28),
		TextSize = 12,
	})

	local refreshViewButton = NativeUi.makeButton(toolbarContent, "Apply", {
		Position = UDim2.new(1, -88, 0, 91),
		Size = UDim2.fromOffset(82, 26),
		TextSize = 12,
	})

	local outputScroll, outputContent = NativeUi.makeScrollList(rightPanel, {
		Position = UDim2.fromOffset(8, 134),
		Size = UDim2.new(1, -16, 1, -142),
		Padding = 4,
		ContentPadding = 8,
	})

	NativeUi.makeDraggable(topBar, main)
	NativeUi.makeResizable(resizeGrip, main, {
		MinSize = Vector2.new(860, 520),
	})

	refs.gui = screenGui
	refs.main = main
	refs.resizeGrip = resizeGrip
	refs.mainTabButton = mainTabButton
	refs.bytecodeTabButton = bytecodeTabButton
	refs.mainTabPanel = mainTabPanel
	refs.mainStatusLabel = mainStatusLabel
	refs.walkSpeedBox = walkSpeedBox
	refs.walkSpeedButton = walkSpeedButton
	refs.jumpPowerBox = jumpPowerBox
	refs.jumpPowerButton = jumpPowerButton
	refs.hipHeightBox = hipHeightBox
	refs.hipHeightButton = hipHeightButton
	refs.gravityBox = gravityBox
	refs.gravityButton = gravityButton
	refs.refreshStatsButton = refreshStatsButton
	refs.resetCharacterButton = resetCharacterButton
	refs.leftPanel = leftPanel
	refs.rightPanel = rightPanel
	refs.treeContent = treeContent
	refs.outputContent = outputContent
	refs.treeSearchBox = treeSearchBox
	refs.targetBox = targetBox
	refs.statusLabel = statusLabel
	refs.codeViewButton = codeViewButton
	refs.decompileViewButton = decompileViewButton
	refs.dataViewButton = dataViewButton
	refs.scriptModeButton = scriptModeButton
	refs.fileModeButton = fileModeButton
	refs.binaryButton = binaryButton
	refs.hexButton = hexButton
	refs.rawOpcodesButton = rawOpcodesButton
	refs.filterBox = filterBox

	closeButton.MouseButton1Click:Connect(function()
		started = false
		screenGui:Destroy()
	end)

	refs.refreshTreeButton = refreshTreeButton
	refs.loadButton = loadButton
	refs.reloadButton = reloadButton
	refs.refreshViewButton = refreshViewButton

	return refs
end

function BytecodeViewer.start(config)
	if started then
		return
	end

	started = true

	local state = makeState(config)
	local refs = createGui(state)

	local LuauDecompiler = loadRemoteModule("LuauDecompiler")

	local function setStatus(text, color)
		refs.statusLabel.Text = text
		refs.statusLabel.TextColor3 = color or NativeUi.Theme.TextMuted
	end

	local function setMainStatus(text, color)
		refs.mainStatusLabel.Text = text
		refs.mainStatusLabel.TextColor3 = color or NativeUi.Theme.TextMuted
	end

	local function getActiveTargetText()
		if state.sourceMode == "script" then
			return state.scriptPath
		end

		return state.filePath
	end

	local function setActiveTargetText(text)
		if state.sourceMode == "script" then
			state.scriptPath = trimText(text)
			return
		end

		state.filePath = trimText(text)
	end

	local function getActiveTargetPlaceholder()
		if state.sourceMode == "script" then
			return "Players.LocalPlayer.PlayerScripts.YourLocalScript"
		end

		return "C:\\Users\\Marin\\Downloads\\Test.txt"
	end

	local function getLocalHumanoid()
		local localPlayer = Players.LocalPlayer
		if localPlayer == nil or localPlayer.Character == nil then
			return nil
		end

		return localPlayer.Character:FindFirstChildOfClass("Humanoid")
	end

	local function runMainAction(actionName, value)
		local handlers = config.ActionHandlers
		local customHandler = handlers and handlers[actionName]

		if type(customHandler) == "function" then
			return pcall(customHandler, value)
		end

		local defaultHandler

		if actionName == "setWalkSpeed" then
			defaultHandler = function()
				local humanoid = getLocalHumanoid()
				if humanoid == nil then
					error("Humanoid not found")
				end

				humanoid.WalkSpeed = value
				return ("WalkSpeed set to %s"):format(value)
			end
		elseif actionName == "setJumpPower" then
			defaultHandler = function()
				local humanoid = getLocalHumanoid()
				if humanoid == nil then
					error("Humanoid not found")
				end

				humanoid.UseJumpPower = true
				humanoid.JumpPower = value
				return ("JumpPower set to %s"):format(value)
			end
		elseif actionName == "setHipHeight" then
			defaultHandler = function()
				local humanoid = getLocalHumanoid()
				if humanoid == nil then
					error("Humanoid not found")
				end

				humanoid.HipHeight = value
				return ("HipHeight set to %s"):format(value)
			end
		elseif actionName == "setGravity" then
			defaultHandler = function()
				game:GetService("Workspace").Gravity = value
				return ("Gravity set to %s"):format(value)
			end
		elseif actionName == "resetCharacter" then
			defaultHandler = function()
				local localPlayer = Players.LocalPlayer
				if localPlayer == nil then
					error("LocalPlayer not found")
				end

				if localPlayer.LoadCharacter ~= nil then
					localPlayer:LoadCharacter()
				elseif localPlayer.Character ~= nil then
					localPlayer.Character:BreakJoints()
				else
					error("Character not found")
				end

				return "Character reset"
			end
		end

		if defaultHandler == nil then
			return false, ("No handler configured for %s"):format(actionName)
		end

		return pcall(defaultHandler)
	end

	local function refreshMainFields()
		local humanoid = getLocalHumanoid()
		local workspaceInstance = game:GetService("Workspace")

		if humanoid ~= nil then
			refs.walkSpeedBox.Text = tostring(humanoid.WalkSpeed)
			refs.jumpPowerBox.Text = tostring(humanoid.JumpPower)
			refs.hipHeightBox.Text = tostring(humanoid.HipHeight)
		end

		refs.gravityBox.Text = tostring(workspaceInstance.Gravity)
	end

	local function applyNumericAction(box, actionName, label)
		local value = tonumber(trimText(box.Text))
		if value == nil then
			setMainStatus(label .. " must be a number", NativeUi.Theme.Error)
			return
		end

		local ok, result = runMainAction(actionName, value)
		if ok then
			setMainStatus(tostring(result or (label .. " updated")), NativeUi.Theme.Success)
			refreshMainFields()
			return
		end

		setMainStatus(tostring(result), NativeUi.Theme.Error)
	end

	local function collectOutputLines()
		if state.lastResult == nil then
			return {}
		end

		local outputText

		if state.viewMode == "code" then
			outputText = formatCodeView(state.lastResult.chunk, state.showRawOpcodes)
		elseif state.viewMode == "decompile" then
			outputText = LuauDecompiler.decompileChunk(state.lastResult.chunk)
		else
			outputText = formatDataView(state.lastResult.chunk)
		end

		local filtered = {}
		for _, line in ipairs(splitLines(outputText)) do
			if containsFilter(line, state.filterText) then
				table.insert(filtered, line)
			end
		end

		return filtered
	end

	local function syncControlState()
		refs.mainTabPanel.Visible = state.activeTab == "main"
		refs.leftPanel.Visible = state.activeTab == "bytecode"
		refs.rightPanel.Visible = state.activeTab == "bytecode"

		refs.targetBox.Text = getActiveTargetText()
		refs.targetBox.PlaceholderText = getActiveTargetPlaceholder()
		refs.filterBox.Text = state.filterText
		refs.treeSearchBox.Text = state.treeFilterText

		NativeUi.setButtonSelected(refs.scriptModeButton, state.sourceMode == "script")
		NativeUi.setButtonSelected(refs.fileModeButton, state.sourceMode == "file")
		NativeUi.setButtonSelected(refs.mainTabButton, state.activeTab == "main")
		NativeUi.setButtonSelected(refs.bytecodeTabButton, state.activeTab == "bytecode")
		NativeUi.setButtonSelected(refs.codeViewButton, state.viewMode == "code")
		NativeUi.setButtonSelected(refs.decompileViewButton, state.viewMode == "decompile")
		NativeUi.setButtonSelected(refs.dataViewButton, state.viewMode == "data")
		NativeUi.setButtonSelected(refs.binaryButton, state.inputFormat == "binary")
		NativeUi.setButtonSelected(refs.hexButton, state.inputFormat == "hex")
		NativeUi.setButtonSelected(refs.rawOpcodesButton, state.showRawOpcodes)

		local isFileMode = state.sourceMode == "file"
		refs.binaryButton.Visible = isFileMode
		refs.hexButton.Visible = isFileMode
		refs.rawOpcodesButton.Position = isFileMode and UDim2.fromOffset(286, 0) or UDim2.fromOffset(146, 0)
	end

	local function renderOutputView()
		NativeUi.clear(refs.outputContent)

		if state.lastError ~= nil then
			setStatus("Load error", NativeUi.Theme.Error)
			NativeUi.makeCodeLabel(refs.outputContent, tostring(state.lastError), {
				TextColor3 = NativeUi.Theme.Error,
			})
			return
		end

		if state.lastResult == nil then
			setStatus("Ready", NativeUi.Theme.TextMuted)
			NativeUi.makeLabel(refs.outputContent, "Select a script from the tree or load a bytecode file.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			return
		end

		local sourceText = ("Loaded: %s"):format(state.lastResult.sourceLabel or "<unknown>")
		local accentColor = state.lastResult.sourceKind == "script" and NativeUi.Theme.Accent or NativeUi.Theme.Success
		setStatus(sourceText, accentColor)

		local lines = collectOutputLines()
		if #lines == 0 then
			NativeUi.makeLabel(refs.outputContent, "No lines match the current filter.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			return
		end

		NativeUi.makeCodeLabel(refs.outputContent, table.concat(lines, "\n"), {
			TextColor3 = NativeUi.Theme.Text,
			TextSize = 13,
		})
	end

	local function refreshScriptBrowser()
		local ok, result = pcall(buildScriptBrowserTree)
		if ok then
			state.scriptBrowserTree = result
			state.scriptBrowserError = nil
			return
		end

		state.scriptBrowserTree = {}
		state.scriptBrowserError = result
	end

	local function isNodeExpanded(node)
		local value = state.expandedNodes[node.path]
		if value ~= nil then
			return value
		end

		return node.depth < 2
	end

	local function loadFileTarget()
		local path = trimText(state.filePath)
		if path == "" then
			state.lastResult = nil
			state.lastError = "No file path provided"
			state.lastLoadedSourceMode = nil
			state.lastLoadedTarget = nil
			renderOutputView()
			return
		end

		local result, err = safeParseFile(path, state.inputFormat)
		state.lastResult = result
		state.lastError = err

		if result ~= nil then
			state.lastLoadedSourceMode = "file"
			state.lastLoadedTarget = path
			state.selectedScriptPath = nil
		end

		renderOutputView()
	end

	local function loadScriptTarget()
		local path = trimText(state.scriptPath)
		if path == "" then
			state.lastResult = nil
			state.lastError = "No script path provided"
			state.lastLoadedSourceMode = nil
			state.lastLoadedTarget = nil
			renderOutputView()
			return
		end

		local result, err = safeParseScript(path)
		state.lastResult = result
		state.lastError = err

		if result ~= nil then
			state.lastLoadedSourceMode = "script"
			state.lastLoadedTarget = path
			state.selectedScriptPath = result.sourceLabel
		end

		renderOutputView()
	end

	local function loadCurrentTarget()
		if state.sourceMode == "script" then
			loadScriptTarget()
			return
		end

		loadFileTarget()
	end

	local renderTreeView

	local function renderTreeNode(node)
		local row = NativeUi.makeRow(refs.treeContent, 24)
		row.BackgroundTransparency = 1

		local indent = node.depth * 14
		local x = indent
		local expanded = isNodeExpanded(node)

		if #node.children > 0 then
			local toggle = NativeUi.makeButton(row, expanded and "-" or "+", {
				Position = UDim2.fromOffset(x, 1),
				Size = UDim2.fromOffset(22, 22),
			})
			toggle.MouseButton1Click:Connect(function()
				state.expandedNodes[node.path] = not expanded
				renderTreeView()
			end)
			x = x + 28
		else
			x = x + 8
		end

		local labelText = ("%s [%s]"):format(node.name, node.className)
		if node.isScript then
			local openButton = NativeUi.makeButton(row, labelText, {
				Position = UDim2.fromOffset(x, 0),
				Size = UDim2.new(1, -(x + 2), 0, 24),
				Font = Enum.Font.Code,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			NativeUi.setButtonSelected(openButton, state.selectedScriptPath == node.path)
			openButton.MouseButton1Click:Connect(function()
				state.activeTab = "bytecode"
				state.sourceMode = "script"
				state.scriptPath = node.path
				syncControlState()
				loadScriptTarget()
				renderTreeView()
			end)
		else
			NativeUi.makeLabel(row, labelText, {
				Position = UDim2.fromOffset(x, 0),
				Size = UDim2.new(1, -(x + 2), 1, 0),
				TextColor3 = NativeUi.Theme.TextMuted,
				Font = Enum.Font.Code,
				TextSize = 13,
			})
		end

		if expanded then
			for _, childNode in ipairs(node.children) do
				renderTreeNode(childNode)
			end
		end
	end

	renderTreeView = function()
		NativeUi.clear(refs.treeContent)

		if state.scriptBrowserError ~= nil then
			NativeUi.makeCodeLabel(refs.treeContent, tostring(state.scriptBrowserError), {
				TextColor3 = NativeUi.Theme.Error,
			})
			return
		end

		local visibleTree = getFilteredTree(state.scriptBrowserTree, state.treeFilterText)
		if #visibleTree == 0 then
			local emptyMessage = state.treeFilterText ~= ""
				and "No scripts match the current filter."
				or "No scripts discovered in the current client view."

			NativeUi.makeLabel(refs.treeContent, emptyMessage, {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			return
		end

		for _, rootNode in ipairs(visibleTree) do
			renderTreeNode(rootNode)
		end
	end

	refs.mainTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "main"
		syncControlState()
	end)

	refs.bytecodeTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "bytecode"
		syncControlState()
	end)

	refs.refreshTreeButton.MouseButton1Click:Connect(function()
		refreshScriptBrowser()
		renderTreeView()
	end)

	refs.loadButton.MouseButton1Click:Connect(function()
		setActiveTargetText(refs.targetBox.Text)
		loadCurrentTarget()
		renderTreeView()
	end)

	refs.reloadButton.MouseButton1Click:Connect(function()
		setActiveTargetText(refs.targetBox.Text)
		loadCurrentTarget()
		renderTreeView()
	end)

	refs.refreshViewButton.MouseButton1Click:Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end)

	refs.scriptModeButton.MouseButton1Click:Connect(function()
		state.sourceMode = "script"
		syncControlState()
	end)

	refs.fileModeButton.MouseButton1Click:Connect(function()
		state.sourceMode = "file"
		syncControlState()
	end)

	refs.binaryButton.MouseButton1Click:Connect(function()
		state.inputFormat = "binary"
		syncControlState()
	end)

	refs.hexButton.MouseButton1Click:Connect(function()
		state.inputFormat = "hex"
		syncControlState()
	end)

	refs.rawOpcodesButton.MouseButton1Click:Connect(function()
		state.showRawOpcodes = not state.showRawOpcodes
		syncControlState()
		renderOutputView()
	end)

	refs.codeViewButton.MouseButton1Click:Connect(function()
		state.viewMode = "code"
		syncControlState()
		renderOutputView()
	end)

	refs.decompileViewButton.MouseButton1Click:Connect(function()
		state.viewMode = "decompile"
		syncControlState()
		renderOutputView()
	end)

	refs.dataViewButton.MouseButton1Click:Connect(function()
		state.viewMode = "data"
		syncControlState()
		renderOutputView()
	end)

	refs.targetBox.FocusLost:Connect(function()
		setActiveTargetText(refs.targetBox.Text)
	end)

	refs.treeSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.treeFilterText = refs.treeSearchBox.Text
		renderTreeView()
	end)

	refs.filterBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end)

	refs.walkSpeedButton.MouseButton1Click:Connect(function()
		applyNumericAction(refs.walkSpeedBox, "setWalkSpeed", "WalkSpeed")
	end)

	refs.jumpPowerButton.MouseButton1Click:Connect(function()
		applyNumericAction(refs.jumpPowerBox, "setJumpPower", "JumpPower")
	end)

	refs.hipHeightButton.MouseButton1Click:Connect(function()
		applyNumericAction(refs.hipHeightBox, "setHipHeight", "HipHeight")
	end)

	refs.gravityButton.MouseButton1Click:Connect(function()
		applyNumericAction(refs.gravityBox, "setGravity", "Gravity")
	end)

	refs.refreshStatsButton.MouseButton1Click:Connect(function()
		refreshMainFields()
		setMainStatus("Pulled current values", NativeUi.Theme.TextMuted)
	end)

	refs.resetCharacterButton.MouseButton1Click:Connect(function()
		local ok, result = runMainAction("resetCharacter")
		if ok then
			setMainStatus(tostring(result or "Character reset"), NativeUi.Theme.Success)
			return
		end

		setMainStatus(tostring(result), NativeUi.Theme.Error)
	end)

	refreshScriptBrowser()
	refreshMainFields()
	syncControlState()
	renderTreeView()

	if state.activeTab == "bytecode" and state.sourceMode == "script" and state.scriptPath ~= "" then
		loadScriptTarget()
		renderTreeView()
	elseif state.activeTab == "bytecode" and state.sourceMode == "file" and state.filePath ~= "" then
		loadFileTarget()
	end

	renderOutputView()
end

return BytecodeViewer
