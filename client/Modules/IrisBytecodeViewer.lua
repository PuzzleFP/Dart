local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")

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
local SESSION_KEY = "__DartViewerCleanup"

local function trimText(text)
	return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function splitLines(text)
	local lines = {}

	for line in string.gmatch(text or "", "([^\n]*)\n?") do
		if line == "" and #lines > 0 and lines[#lines] == "" then
			break
		end

		table.insert(lines, line)
	end

	return lines
end

local function containsFilter(text, filterText)
	if filterText == "" then
		return true
	end

	return string.find(string.lower(text or ""), string.lower(filterText), 1, true) ~= nil
end

local function clamp(value, minValue, maxValue)
	return math.max(minValue, math.min(maxValue, value))
end

local function appendSection(lines, title)
	if #lines > 0 then
		table.insert(lines, "")
	end

	table.insert(lines, title)
end

local function appendKeyValue(lines, label, value)
	table.insert(lines, ("  %-18s %s"):format(label .. ":", tostring(value)))
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
	push(Workspace)

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

local function formatCodeView(chunk, showRawOpcodes)
	local lines = {
		"Code View",
	}

	appendKeyValue(lines, "Version", chunk.version)
	appendKeyValue(lines, "Type Version", chunk.typesVersion or 0)
	appendKeyValue(lines, "Proto Count", chunk.protoCount or 0)
	appendKeyValue(lines, "Main Proto", chunk.mainProtoIndex or 0)
	appendKeyValue(lines, "Opcode Decode", chunk.opcodeDecodeMultiplier or 1)

	for _, proto in ipairs(chunk.protos) do
		appendSection(lines, ("Proto %d%s"):format(
			proto.index,
			proto.index == chunk.mainProtoIndex and " <main>" or ""
		))

		appendKeyValue(lines, "Debug Name", proto.debugName or "<anonymous>")
		appendKeyValue(lines, "Params", proto.numParams)
		appendKeyValue(lines, "Upvalues", proto.numUpvalues)
		appendKeyValue(lines, "Max Stack", proto.maxStackSize)
		appendKeyValue(lines, "Vararg", proto.isVararg)

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
	appendKeyValue(lines, "Proto Count", chunk.protoCount or 0)
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
		appendKeyValue(lines, "Code Words", proto.sizeCode or #proto.codeWords)

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

local function makeState(config)
	return {
		activeTab = config.DefaultTab or "main",
		sourceMode = config.DefaultBytecodeSourceMode or "script",
		viewMode = config.DefaultBytecodeViewMode or "code",
		inputFormat = config.DefaultBytecodeInputFormat or "binary",
		showRawOpcodes = config.ShowRawOpcodes ~= false,
		scriptPath = trimText(config.DefaultScriptPath or ""),
		filePath = trimText(config.DefaultBytecodeFilePath or ""),
		filterText = "",
		treeFilterText = "",
		playerFilterText = "",
		selectedPlayerName = Players.LocalPlayer and Players.LocalPlayer.Name or "",
		selectedScriptPath = nil,
		scriptBrowserTree = {},
		scriptBrowserError = nil,
		expandedNodes = {},
		lastResult = nil,
		lastError = nil,
		lastLoadedSourceMode = nil,
		lastLoadedTarget = nil,
		mainControlsWidth = 500,
		bytecodeSidebarWidth = 280,
		bytecodeInspectorWidth = 320,
		windowMinSize = Vector2.new(1100, 700),
		windowMaxSize = nil,
		infiniteJump = false,
		noClip = false,
		fullBright = false,
		lightingSnapshot = nil,
		walkSpeedValue = 16,
		jumpPowerValue = 50,
		hipHeightValue = 0,
		gravityValue = Workspace.Gravity,
	}
end

local function destroyExistingGui()
	local scope = getGlobalScope()
	local cleanup = scope[SESSION_KEY]
	if type(cleanup) == "function" then
		pcall(cleanup)
		scope[SESSION_KEY] = nil
	end

	local existing = CoreGui:FindFirstChild(GUI_NAME)
	if existing ~= nil then
		existing:Destroy()
	end
end

local function makeSectionTitle(parent, text, accentColor)
	return NativeUi.makeLabel(parent, text, {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		Text = text,
		TextColor3 = accentColor or NativeUi.Theme.Text,
		TextSize = 14,
		Size = UDim2.new(1, 0, 0, 22),
	})
end

local function makeBodyLabel(parent, text, properties)
	local label = NativeUi.makeLabel(parent, text, {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
	})

	for key, value in pairs(properties or {}) do
		label[key] = value
	end

	return label
end

local function applyGradient(target, colors)
	return NativeUi.create("UIGradient", {
		Rotation = 135,
		Color = ColorSequence.new(colors),
		Parent = target,
	})
end

local function makeOutputViewer(parent)
	local scroll = NativeUi.create("ScrollingFrame", {
		Active = true,
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		BackgroundColor3 = Color3.fromRGB(16, 20, 28),
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		Position = UDim2.fromOffset(0, 0),
		ScrollBarImageColor3 = NativeUi.Theme.TextDim,
		ScrollBarThickness = 7,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = parent,
	})
	NativeUi.corner(scroll, 10)
	NativeUi.stroke(scroll, NativeUi.Theme.Border, 1, 0)

	local padding = 12

	local codeLabel = NativeUi.create("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		Position = UDim2.fromOffset(padding, padding),
		Size = UDim2.fromOffset(300, 0),
		Text = "",
		TextColor3 = NativeUi.Theme.Text,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = scroll,
	})

	local function syncCanvas()
		local width = math.max(220, scroll.AbsoluteSize.X - padding * 2 - 10)
		local text = codeLabel.Text ~= "" and codeLabel.Text or " "
		local ok, bounds = pcall(function()
			return TextService:GetTextSize(text, codeLabel.TextSize, codeLabel.Font, Vector2.new(width, 100000))
		end)

		local height = scroll.AbsoluteSize.Y
		if ok and bounds then
			height = math.max(height, bounds.Y + padding * 2 + 6)
		else
			local lineCount = math.max(1, #splitLines(text))
			height = math.max(height, lineCount * 16 + padding * 2 + 6)
		end

		codeLabel.Size = UDim2.fromOffset(width, height - padding * 2)
		scroll.CanvasSize = UDim2.fromOffset(0, height)
	end

	return scroll, codeLabel, syncCanvas
end

local function makeSliderRow(parent, y, labelText)
	local row = NativeUi.makeRow(parent, 52, {
		Position = UDim2.new(0, 12, 0, y),
		Size = UDim2.new(1, -24, 0, 52),
	})

	local label = NativeUi.makeLabel(row, labelText, {
		Font = Enum.Font.GothamSemibold,
		TextSize = 13,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -140, 0, 18),
	})

	local valueLabel = NativeUi.makeLabel(row, "0", {
		Font = Enum.Font.Code,
		TextSize = 12,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -130, 0, 0),
		Size = UDim2.fromOffset(72, 18),
	})

	local applyButton = NativeUi.makeButton(row, "Apply", {
		Position = UDim2.new(1, -52, 0, -2),
		Size = UDim2.fromOffset(52, 24),
		TextSize = 11,
	})

	local track = NativeUi.create("Frame", {
		BackgroundColor3 = Color3.fromRGB(27, 33, 44),
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 30),
		Size = UDim2.new(1, 0, 0, 8),
		Parent = row,
	})
	NativeUi.corner(track, 999)

	local fill = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 1, 0),
		Parent = track,
	})
	NativeUi.corner(fill, 999)
	applyGradient(fill, {
		ColorSequenceKeypoint.new(0, Color3.fromRGB(84, 168, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(56, 116, 236)),
	})

	local knob = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(234, 240, 248),
		BorderSizePixel = 0,
		Position = UDim2.new(0, -7, 0.5, -7),
		Size = UDim2.fromOffset(14, 14),
		Text = "",
		ZIndex = 3,
		Parent = track,
	})
	NativeUi.corner(knob, 999)
	NativeUi.stroke(knob, Color3.fromRGB(95, 112, 140), 1, 0)

	return {
		row = row,
		label = label,
		valueLabel = valueLabel,
		applyButton = applyButton,
		track = track,
		fill = fill,
		knob = knob,
	}
end

local function makeToggleRow(parent, y, labelText, description)
	local row = NativeUi.makeRow(parent, 54, {
		Position = UDim2.new(0, 12, 0, y),
		Size = UDim2.new(1, -24, 0, 54),
	})

	local title = NativeUi.makeLabel(row, labelText, {
		Font = Enum.Font.GothamSemibold,
		TextSize = 13,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -90, 0, 18),
	})

	local desc = makeBodyLabel(row, description, {
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, -90, 0, 0),
	})

	local toggle = NativeUi.makeButton(row, "OFF", {
		Position = UDim2.new(1, -62, 0, 10),
		Size = UDim2.fromOffset(62, 26),
		TextSize = 11,
	})

	return {
		row = row,
		title = title,
		desc = desc,
		toggle = toggle,
	}
end

local function createGui(state)
	destroyExistingGui()

	local refs = {
		connections = {},
	}

	local function trackConnection(connection)
		table.insert(refs.connections, connection)
		return connection
	end

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
		Position = UDim2.new(0.5, -620, 0.5, -360),
		Size = UDim2.fromOffset(1240, 720),
		ClipsDescendants = true,
	})

	local shadow = NativeUi.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.55,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0.5, 10),
		Size = UDim2.new(1, 28, 1, 28),
		ZIndex = -1,
		Parent = main,
	})
	NativeUi.corner(shadow, 20)

	local topBar = NativeUi.create("Frame", {
		BackgroundColor3 = Color3.fromRGB(20, 24, 33),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 46),
		Parent = main,
	})
	NativeUi.corner(topBar, 12)
	NativeUi.stroke(topBar, Color3.fromRGB(58, 70, 88), 1, 0)

	local brandMark = NativeUi.create("Frame", {
		BackgroundColor3 = Color3.fromRGB(245, 247, 251),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(14, 11),
		Size = UDim2.fromOffset(20, 20),
		Parent = topBar,
	})
	NativeUi.corner(brandMark, 6)

	local brandCut = NativeUi.create("Frame", {
		BackgroundColor3 = topBar.BackgroundColor3,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(9, 2),
		Size = UDim2.fromOffset(9, 7),
		Parent = brandMark,
	})
	NativeUi.corner(brandCut, 4)

	local title = NativeUi.makeLabel(topBar, "Eclipsis Intelligence Suite", {
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Position = UDim2.fromOffset(44, 6),
		Size = UDim2.fromOffset(260, 18),
	})

	local subtitle = NativeUi.makeLabel(topBar, "Operations, targets, and bytecode analysis", {
		TextColor3 = NativeUi.Theme.TextDim,
		TextSize = 11,
		Position = UDim2.fromOffset(44, 23),
		Size = UDim2.fromOffset(260, 16),
	})

	local mainTabButton = NativeUi.makeButton(topBar, "Main", {
		Position = UDim2.fromOffset(320, 9),
		Size = UDim2.fromOffset(74, 28),
		TextSize = 12,
	})

	local bytecodeTabButton = NativeUi.makeButton(topBar, "Bytecode Lab", {
		Position = UDim2.fromOffset(402, 9),
		Size = UDim2.fromOffset(110, 28),
		TextSize = 12,
	})

	local profilesTabButton = NativeUi.makeButton(topBar, "Profiles", {
		Position = UDim2.fromOffset(520, 9),
		Size = UDim2.fromOffset(82, 28),
		TextSize = 12,
	})

	local suiteStatus = NativeUi.makeLabel(topBar, "Command center ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -300, 0, 0),
		Size = UDim2.fromOffset(240, 46),
	})

	local closeButton = NativeUi.makeButton(topBar, "X", {
		Position = UDim2.new(1, -34, 0, 9),
		Size = UDim2.fromOffset(26, 28),
		TextSize = 12,
		Palette = {
			Base = Color3.fromRGB(42, 20, 24),
			Hover = Color3.fromRGB(72, 30, 34),
			Pressed = Color3.fromRGB(92, 40, 42),
			Selected = Color3.fromRGB(255, 118, 118),
			Text = Color3.fromRGB(238, 222, 222),
			SelectedText = Color3.fromRGB(21, 7, 7),
		},
	})

	local mainWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 70),
		Size = UDim2.new(1, -24, 1, -82),
		Parent = main,
	})

	local bytecodeWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 70),
		Size = UDim2.new(1, -24, 1, -82),
		Parent = main,
	})

	local profilesWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 70),
		Size = UDim2.new(1, -24, 1, -82),
		Parent = main,
	})

	local mainControlsPanel = NativeUi.makePanel(mainWorkspace, {
		BackgroundColor3 = Color3.fromRGB(18, 23, 31),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(0, 500, 1, 0),
	})

	local mainSplitter = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(38, 46, 58),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(508, 0),
		Size = UDim2.fromOffset(6, 100),
		Text = "",
		Parent = mainWorkspace,
	})
	NativeUi.corner(mainSplitter, 999)

	local mainPlayersPanel = NativeUi.makePanel(mainWorkspace, {
		BackgroundColor3 = Color3.fromRGB(18, 23, 31),
		Position = UDim2.fromOffset(522, 0),
		Size = UDim2.new(1, -522, 1, 0),
	})

	local controlsScroll, controlsContent = NativeUi.makeScrollList(mainControlsPanel, {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 1, -24),
		Padding = 10,
		ContentPadding = 0,
		BackgroundColor3 = Color3.fromRGB(18, 23, 31),
	})

	local heroCard = NativeUi.makePanel(controlsContent, {
		Size = UDim2.new(1, 0, 0, 110),
		BackgroundColor3 = Color3.fromRGB(24, 32, 48),
	})
	applyGradient(heroCard, {
		ColorSequenceKeypoint.new(0, Color3.fromRGB(31, 64, 132)),
		ColorSequenceKeypoint.new(0.6, Color3.fromRGB(28, 44, 83)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(22, 29, 45)),
	})

	local heroTitle = NativeUi.makeLabel(heroCard, "Operations", {
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local heroBody = makeBodyLabel(heroCard, "Keep the live controls compact here. Bytecode work stays isolated in its own lab so the suite reads cleanly even during heavy analysis.", {
		TextColor3 = Color3.fromRGB(214, 222, 238),
		TextSize = 12,
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -32, 0, 0),
	})

	local mainStatusLabel = NativeUi.makeLabel(heroCard, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 84),
		Size = UDim2.new(1, -32, 0, 16),
	})

	local movementSection = NativeUi.makePanel(controlsContent, {
		Size = UDim2.new(1, 0, 0, 196),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local movementTitle = makeSectionTitle(movementSection, "Movement", Color3.fromRGB(206, 220, 248))
	movementTitle.Position = UDim2.fromOffset(12, 10)

	local walkSlider = makeSliderRow(movementSection, 40, "Walk Speed")
	local jumpSlider = makeSliderRow(movementSection, 92, "Jump Power")
	local hipSlider = makeSliderRow(movementSection, 144, "Hip Height")

	local worldSection = NativeUi.makePanel(controlsContent, {
		Size = UDim2.new(1, 0, 0, 138),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local worldTitle = makeSectionTitle(worldSection, "World", Color3.fromRGB(240, 214, 165))
	worldTitle.Position = UDim2.fromOffset(12, 10)

	local gravitySlider = makeSliderRow(worldSection, 40, "Gravity")
	local refreshStatsButton = NativeUi.makeButton(worldSection, "Refresh Stats", {
		Position = UDim2.fromOffset(12, 94),
		Size = UDim2.fromOffset(110, 28),
		TextSize = 12,
	})

	local resetCharacterButton = NativeUi.makeButton(worldSection, "Reset", {
		Position = UDim2.fromOffset(130, 94),
		Size = UDim2.fromOffset(74, 28),
		TextSize = 12,
	})

	local automationSection = NativeUi.makePanel(controlsContent, {
		Size = UDim2.new(1, 0, 0, 188),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local automationTitle = makeSectionTitle(automationSection, "Automation", Color3.fromRGB(170, 242, 187))
	automationTitle.Position = UDim2.fromOffset(12, 10)

	local infiniteJumpToggle = makeToggleRow(automationSection, 40, "Infinite Jump", "Keeps jump requests hot for the local character when enabled.")
	local noClipToggle = makeToggleRow(automationSection, 94, "NoClip", "Suppresses part collisions on the local character during stepped updates.")
	local fullBrightToggle = makeToggleRow(automationSection, 148, "FullBright", "Pins lighting into a bright analysis state and restores it when disabled.")

	local targetsHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 90),
		Parent = mainPlayersPanel,
	})

	local targetsTitle = makeSectionTitle(targetsHeader, "Targets", Color3.fromRGB(255, 215, 156))
	targetsTitle.Position = UDim2.fromOffset(0, 0)

	local targetsBody = makeBodyLabel(targetsHeader, "Player selection is separated from the control rail so the suite stays readable once remote handlers are wired in.", {
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, 0, 0, 0),
	})

	local selectedPlayerLabel = NativeUi.makeLabel(targetsHeader, "Selected: -", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(0, 66),
		Size = UDim2.new(1, 0, 0, 16),
	})

	local playerSearchBox = NativeUi.makeTextBox(mainPlayersPanel, "", {
		PlaceholderText = "Filter players",
		Position = UDim2.fromOffset(12, 110),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	local playerScroll, playerContent = NativeUi.makeScrollList(mainPlayersPanel, {
		Position = UDim2.fromOffset(12, 150),
		Size = UDim2.new(1, -24, 1, -162),
		Padding = 6,
		ContentPadding = 8,
		BackgroundColor3 = Color3.fromRGB(20, 25, 34),
	})

	local scriptPanel = NativeUi.makePanel(bytecodeWorkspace, {
		BackgroundColor3 = Color3.fromRGB(18, 23, 31),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(280, 100),
	})

	local bytecodeSplitter = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(38, 46, 58),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(288, 0),
		Size = UDim2.fromOffset(6, 100),
		Text = "",
		Parent = bytecodeWorkspace,
	})
	NativeUi.corner(bytecodeSplitter, 999)

	local outputPanel = NativeUi.makePanel(bytecodeWorkspace, {
		BackgroundColor3 = Color3.fromRGB(18, 23, 31),
		Position = UDim2.fromOffset(302, 0),
		Size = UDim2.fromOffset(500, 100),
	})

	local inspectorSplitter = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundColor3 = Color3.fromRGB(38, 46, 58),
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(810, 0),
		Size = UDim2.fromOffset(6, 100),
		Text = "",
		Parent = bytecodeWorkspace,
	})
	NativeUi.corner(inspectorSplitter, 999)

	local inspectorPanel = NativeUi.makePanel(bytecodeWorkspace, {
		BackgroundColor3 = Color3.fromRGB(18, 23, 31),
		Position = UDim2.fromOffset(824, 0),
		Size = UDim2.new(1, -824, 1, 0),
	})

	local scriptHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 86),
		Parent = scriptPanel,
	})

	local scriptTitle = makeSectionTitle(scriptHeader, "Script Tree", Color3.fromRGB(171, 210, 255))
	scriptTitle.Position = UDim2.fromOffset(0, 0)

	local scriptCountLabel = NativeUi.makeLabel(scriptHeader, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, -90, 0, 16),
	})

	local refreshTreeButton = NativeUi.makeButton(scriptHeader, "Refresh", {
		Position = UDim2.new(1, -80, 0, 0),
		Size = UDim2.fromOffset(80, 26),
		TextSize = 12,
	})

	local treeSearchBox = NativeUi.makeTextBox(scriptHeader, "", {
		PlaceholderText = "Filter scripts",
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 0, 30),
		TextSize = 12,
	})

	local treeScroll, treeContent = NativeUi.makeScrollList(scriptPanel, {
		Position = UDim2.fromOffset(12, 108),
		Size = UDim2.new(1, -24, 1, -120),
		Padding = 4,
		ContentPadding = 8,
		BackgroundColor3 = Color3.fromRGB(20, 25, 34),
	})

	local outputHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 82),
		Parent = outputPanel,
	})

	local outputTitle = makeSectionTitle(outputHeader, "Bytecode Output", Color3.fromRGB(255, 224, 171))
	outputTitle.Position = UDim2.fromOffset(0, 0)

	local outputSourceLabel = NativeUi.makeLabel(outputHeader, "No target loaded", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(0, 24),
		Size = UDim2.new(1, 0, 0, 16),
	})

	local outputSummaryLabel = makeBodyLabel(outputHeader, "Load a script or file to inspect chunk structure, opcode listings, and the heuristic decompile output.", {
		Position = UDim2.fromOffset(0, 46),
		Size = UDim2.new(1, 0, 0, 0),
	})

	local outputViewerHost = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 104),
		Size = UDim2.new(1, -24, 1, -116),
		Parent = outputPanel,
	})

	local outputScroll, outputCodeLabel, syncOutputCanvas = makeOutputViewer(outputViewerHost)

	local inspectorScroll, inspectorContent = NativeUi.makeScrollList(inspectorPanel, {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 1, -24),
		Padding = 10,
		ContentPadding = 0,
		BackgroundColor3 = Color3.fromRGB(18, 23, 31),
	})

	local intelCard = NativeUi.makePanel(inspectorContent, {
		Size = UDim2.new(1, 0, 0, 108),
		BackgroundColor3 = Color3.fromRGB(52, 34, 16),
	})
	applyGradient(intelCard, {
		ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 117, 36)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(82, 50, 23)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 24, 21)),
	})

	local intelTitle = NativeUi.makeLabel(intelCard, "Signal", {
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local inspectorStatusLabel = NativeUi.makeLabel(intelCard, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = Color3.fromRGB(241, 232, 214),
		TextSize = 12,
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -32, 0, 16),
	})

	local inspectorInfoLabel = makeBodyLabel(intelCard, "Script mode uses getscriptbytecode directly. File mode stays available as a fallback for offline chunk testing.", {
		TextColor3 = Color3.fromRGB(246, 236, 218),
		Position = UDim2.fromOffset(16, 66),
		Size = UDim2.new(1, -32, 0, 0),
	})

	local inputSection = NativeUi.makePanel(inspectorContent, {
		Size = UDim2.new(1, 0, 0, 192),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local inputTitle = makeSectionTitle(inputSection, "Input", Color3.fromRGB(205, 221, 248))
	inputTitle.Position = UDim2.fromOffset(12, 10)

	local scriptModeButton = NativeUi.makeButton(inputSection, "Script", {
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.fromOffset(82, 28),
		TextSize = 12,
	})

	local fileModeButton = NativeUi.makeButton(inputSection, "File", {
		Position = UDim2.fromOffset(100, 42),
		Size = UDim2.fromOffset(62, 28),
		TextSize = 12,
	})

	local binaryButton = NativeUi.makeButton(inputSection, "Binary", {
		Position = UDim2.fromOffset(172, 42),
		Size = UDim2.fromOffset(72, 28),
		TextSize = 12,
	})

	local hexButton = NativeUi.makeButton(inputSection, "Hex", {
		Position = UDim2.fromOffset(250, 42),
		Size = UDim2.fromOffset(58, 28),
		TextSize = 12,
	})

	local targetBox = NativeUi.makeTextBox(inputSection, "", {
		PlaceholderText = "Players.LocalPlayer.PlayerScripts.YourLocalScript",
		Position = UDim2.fromOffset(12, 82),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	local loadButton = NativeUi.makeButton(inputSection, "Load", {
		Position = UDim2.fromOffset(12, 122),
		Size = UDim2.fromOffset(74, 28),
		TextSize = 12,
	})

	local reloadButton = NativeUi.makeButton(inputSection, "Reload", {
		Position = UDim2.fromOffset(94, 122),
		Size = UDim2.fromOffset(74, 28),
		TextSize = 12,
	})

	local activeTargetLabel = NativeUi.makeLabel(inputSection, "Active target: -", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 160),
		Size = UDim2.new(1, -24, 0, 16),
	})

	local viewSection = NativeUi.makePanel(inspectorContent, {
		Size = UDim2.new(1, 0, 0, 142),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local viewTitle = makeSectionTitle(viewSection, "View", Color3.fromRGB(205, 221, 248))
	viewTitle.Position = UDim2.fromOffset(12, 10)

	local codeViewButton = NativeUi.makeButton(viewSection, "Code", {
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.fromOffset(66, 28),
		TextSize = 12,
	})

	local decompileViewButton = NativeUi.makeButton(viewSection, "Decompile", {
		Position = UDim2.fromOffset(84, 42),
		Size = UDim2.fromOffset(92, 28),
		TextSize = 12,
	})

	local dataViewButton = NativeUi.makeButton(viewSection, "Data", {
		Position = UDim2.fromOffset(182, 42),
		Size = UDim2.fromOffset(64, 28),
		TextSize = 12,
	})

	local rawOpcodesButton = NativeUi.makeButton(viewSection, "Raw Opcodes", {
		Position = UDim2.fromOffset(12, 82),
		Size = UDim2.fromOffset(116, 28),
		TextSize = 12,
	})

	local viewHint = makeBodyLabel(viewSection, "Code is the fast default. Decompile is heuristic v1 and will stay conservative around control flow.", {
		Position = UDim2.fromOffset(12, 116),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local filterSection = NativeUi.makePanel(inspectorContent, {
		Size = UDim2.new(1, 0, 0, 126),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local filterTitle = makeSectionTitle(filterSection, "Filter", Color3.fromRGB(205, 221, 248))
	filterTitle.Position = UDim2.fromOffset(12, 10)

	local filterBox = NativeUi.makeTextBox(filterSection, "", {
		PlaceholderText = "Filter visible output lines",
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	local refreshViewButton = NativeUi.makeButton(filterSection, "Apply Filter", {
		Position = UDim2.fromOffset(12, 82),
		Size = UDim2.fromOffset(100, 28),
		TextSize = 12,
	})

	local filterHint = NativeUi.makeLabel(filterSection, "Live filter over the rendered output surface", {
		TextColor3 = NativeUi.Theme.TextDim,
		TextSize = 11,
		Position = UDim2.fromOffset(122, 88),
		Size = UDim2.new(1, -134, 0, 16),
	})

	local summarySection = NativeUi.makePanel(inspectorContent, {
		Size = UDim2.new(1, 0, 0, 128),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local summaryTitle = makeSectionTitle(summarySection, "Summary", Color3.fromRGB(205, 221, 248))
	summaryTitle.Position = UDim2.fromOffset(12, 10)

	local chunkSummaryLabel = makeBodyLabel(summarySection, "No chunk loaded", {
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local profilesHero = NativeUi.makePanel(profilesWorkspace, {
		BackgroundColor3 = Color3.fromRGB(20, 25, 34),
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 0, 140),
	})
	applyGradient(profilesHero, {
		ColorSequenceKeypoint.new(0, Color3.fromRGB(34, 52, 97)),
		ColorSequenceKeypoint.new(0.55, Color3.fromRGB(22, 29, 48)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(15, 21, 33)),
	})

	local profilesTitle = NativeUi.makeLabel(profilesHero, "Profiles", {
		Font = Enum.Font.GothamBlack,
		TextSize = 26,
		Position = UDim2.fromOffset(18, 18),
		Size = UDim2.new(1, -36, 0, 28),
	})

	local profilesBody = makeBodyLabel(profilesHero, "Reserve this workspace for paid presets, saved operations, and target-specific modules once the remote contract is finalized.", {
		TextColor3 = Color3.fromRGB(214, 222, 238),
		TextSize = 13,
		Position = UDim2.fromOffset(18, 56),
		Size = UDim2.new(1, -36, 0, 0),
	})

	local profilesCardA = NativeUi.makePanel(profilesWorkspace, {
		BackgroundColor3 = Color3.fromRGB(25, 34, 49),
		Position = UDim2.fromOffset(0, 152),
		Size = UDim2.fromOffset(320, 148),
	})
	applyGradient(profilesCardA, {
		ColorSequenceKeypoint.new(0, Color3.fromRGB(28, 64, 132)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(19, 31, 54)),
	})

	local profilesCardATitle = makeSectionTitle(profilesCardA, "Operations Stack", Color3.fromRGB(247, 250, 255))
	profilesCardATitle.Position = UDim2.fromOffset(14, 12)

	local profilesCardABody = makeBodyLabel(profilesCardA, "Movement, world, and automation modules can be saved here as role-based presets.", {
		TextColor3 = Color3.fromRGB(230, 235, 244),
		Position = UDim2.fromOffset(14, 44),
		Size = UDim2.new(1, -28, 0, 0),
	})

	local profilesCardB = NativeUi.makePanel(profilesWorkspace, {
		BackgroundColor3 = Color3.fromRGB(43, 31, 17),
		Position = UDim2.fromOffset(336, 152),
		Size = UDim2.fromOffset(320, 148),
	})
	applyGradient(profilesCardB, {
		ColorSequenceKeypoint.new(0, Color3.fromRGB(183, 118, 39)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(64, 39, 18)),
	})

	local profilesCardBTitle = makeSectionTitle(profilesCardB, "Bytecode Lab", Color3.fromRGB(255, 246, 230))
	profilesCardBTitle.Position = UDim2.fromOffset(14, 12)

	local profilesCardBBody = makeBodyLabel(profilesCardB, "Keep decode multipliers, file test sets, and future decompiler passes isolated as saved analysis profiles.", {
		TextColor3 = Color3.fromRGB(255, 238, 214),
		Position = UDim2.fromOffset(14, 44),
		Size = UDim2.new(1, -28, 0, 0),
	})

	local profilesCardC = NativeUi.makePanel(profilesWorkspace, {
		BackgroundColor3 = Color3.fromRGB(20, 44, 32),
		Position = UDim2.fromOffset(672, 152),
		Size = UDim2.fromOffset(320, 148),
	})
	applyGradient(profilesCardC, {
		ColorSequenceKeypoint.new(0, Color3.fromRGB(35, 123, 79)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(18, 48, 35)),
	})

	local profilesCardCTitle = makeSectionTitle(profilesCardC, "Signals", Color3.fromRGB(234, 255, 242))
	profilesCardCTitle.Position = UDim2.fromOffset(14, 12)

	local profilesCardCBody = makeBodyLabel(profilesCardC, "Use this lane for remote-driven alerts, target heuristics, and audit logs once the game-side structure is defined.", {
		TextColor3 = Color3.fromRGB(224, 250, 232),
		Position = UDim2.fromOffset(14, 44),
		Size = UDim2.new(1, -28, 0, 0),
	})

	local rightResizeHandle = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(10, 100),
		Text = "",
		Parent = main,
	})

	local leftResizeHandle = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(10, 100),
		Text = "",
		Parent = main,
	})

	local topResizeHandle = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(100, 10),
		Text = "",
		Parent = main,
	})

	local bottomResizeHandle = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(100, 10),
		Text = "",
		Parent = main,
	})

	local bottomRightResizeHandle = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.Code,
		Position = UDim2.new(1, -26, 1, -22),
		Size = UDim2.fromOffset(18, 18),
		Text = "///",
		TextColor3 = NativeUi.Theme.TextDim,
		TextSize = 10,
		Parent = main,
	})

	local function bindDrag(handle, target)
		local dragging = false
		local dragStart
		local targetStart

		trackConnection(handle.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			dragging = true
			dragStart = input.Position
			targetStart = target.Position

			trackConnection(input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end))
		end))

		trackConnection(UserInputService.InputChanged:Connect(function(input)
			if not dragging then
				return
			end

			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			local delta = input.Position - dragStart
			target.Position = UDim2.new(
				targetStart.X.Scale,
				targetStart.X.Offset + delta.X,
				targetStart.Y.Scale,
				targetStart.Y.Offset + delta.Y
			)
		end))
	end

	local function bindWindowResize(handle, edge)
		local resizing = false
		local dragStart
		local sizeStart
		local positionStart

		trackConnection(handle.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			resizing = true
			dragStart = input.Position
			sizeStart = Vector2.new(main.AbsoluteSize.X, main.AbsoluteSize.Y)
			positionStart = main.Position

			trackConnection(input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					resizing = false
				end
			end))
		end))

		trackConnection(UserInputService.InputChanged:Connect(function(input)
			if not resizing then
				return
			end

			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			local delta = input.Position - dragStart
			local width = sizeStart.X
			local height = sizeStart.Y
			local posX = positionStart.X.Offset
			local posY = positionStart.Y.Offset

			if string.find(edge, "right", 1, true) ~= nil then
				width = width + delta.X
			end

			if string.find(edge, "left", 1, true) ~= nil then
				width = width - delta.X
			end

			if string.find(edge, "bottom", 1, true) ~= nil then
				height = height + delta.Y
			end

			if string.find(edge, "top", 1, true) ~= nil then
				height = height - delta.Y
			end

			width = clamp(width, state.windowMinSize.X, state.windowMaxSize and state.windowMaxSize.X or width)
			height = clamp(height, state.windowMinSize.Y, state.windowMaxSize and state.windowMaxSize.Y or height)

			if string.find(edge, "left", 1, true) ~= nil then
				posX = positionStart.X.Offset + (sizeStart.X - width)
			end

			if string.find(edge, "top", 1, true) ~= nil then
				posY = positionStart.Y.Offset + (sizeStart.Y - height)
			end

			main.Position = UDim2.new(positionStart.X.Scale, posX, positionStart.Y.Scale, posY)
			main.Size = UDim2.fromOffset(width, height)
		end))
	end

	local function bindVerticalSplitter(handle, stateKey, minValue, maxValueFn)
		local dragging = false
		local dragStart
		local startValue

		trackConnection(handle.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			dragging = true
			dragStart = input.Position
			startValue = state[stateKey]

			trackConnection(input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end))
		end))

		trackConnection(UserInputService.InputChanged:Connect(function(input)
			if not dragging then
				return
			end

			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			local delta = input.Position - dragStart
			state[stateKey] = clamp(startValue + delta.X, minValue, maxValueFn())
			if refs.applyLayout then
				refs.applyLayout()
			end
		end))
	end

	local function applyLayout()
		local width = main.AbsoluteSize.X
		local height = main.AbsoluteSize.Y
		local workspaceWidth = width - 24
		local workspaceHeight = height - 82
		local panelGap = 16
		local splitterWidth = 6

		rightResizeHandle.Position = UDim2.new(1, -5, 0, 14)
		rightResizeHandle.Size = UDim2.new(0, 10, 1, -28)
		leftResizeHandle.Position = UDim2.fromOffset(-5, 14)
		leftResizeHandle.Size = UDim2.new(0, 10, 1, -28)
		topResizeHandle.Position = UDim2.fromOffset(14, -5)
		topResizeHandle.Size = UDim2.new(1, -28, 0, 10)
		bottomResizeHandle.Position = UDim2.new(0, 14, 1, -5)
		bottomResizeHandle.Size = UDim2.new(1, -28, 0, 10)
		bottomRightResizeHandle.Position = UDim2.new(1, -26, 1, -22)

		mainWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		bytecodeWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		profilesWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)

		state.mainControlsWidth = clamp(state.mainControlsWidth, 420, math.max(520, workspaceWidth - 280))
		mainControlsPanel.Size = UDim2.fromOffset(state.mainControlsWidth, workspaceHeight)
		mainSplitter.Position = UDim2.fromOffset(state.mainControlsWidth + 8, 0)
		mainSplitter.Size = UDim2.fromOffset(splitterWidth, workspaceHeight)
		mainPlayersPanel.Position = UDim2.fromOffset(state.mainControlsWidth + panelGap, 0)
		mainPlayersPanel.Size = UDim2.fromOffset(workspaceWidth - state.mainControlsWidth - panelGap, workspaceHeight)

		local maxSidebar = math.max(240, workspaceWidth - state.bytecodeInspectorWidth - 420)
		local maxInspector = math.max(280, workspaceWidth - state.bytecodeSidebarWidth - 420)
		state.bytecodeSidebarWidth = clamp(state.bytecodeSidebarWidth, 240, maxSidebar)
		state.bytecodeInspectorWidth = clamp(state.bytecodeInspectorWidth, 280, maxInspector)

		local outputWidth = workspaceWidth - state.bytecodeSidebarWidth - state.bytecodeInspectorWidth - 2 * panelGap
		if outputWidth < 320 then
			local deficit = 320 - outputWidth
			state.bytecodeInspectorWidth = clamp(state.bytecodeInspectorWidth - deficit, 280, maxInspector)
			outputWidth = workspaceWidth - state.bytecodeSidebarWidth - state.bytecodeInspectorWidth - 2 * panelGap
		end

		scriptPanel.Size = UDim2.fromOffset(state.bytecodeSidebarWidth, workspaceHeight)
		bytecodeSplitter.Position = UDim2.fromOffset(state.bytecodeSidebarWidth + 8, 0)
		bytecodeSplitter.Size = UDim2.fromOffset(splitterWidth, workspaceHeight)
		outputPanel.Position = UDim2.fromOffset(state.bytecodeSidebarWidth + panelGap, 0)
		outputPanel.Size = UDim2.fromOffset(outputWidth, workspaceHeight)
		inspectorSplitter.Position = UDim2.fromOffset(state.bytecodeSidebarWidth + panelGap + outputWidth + 8, 0)
		inspectorSplitter.Size = UDim2.fromOffset(splitterWidth, workspaceHeight)
		inspectorPanel.Position = UDim2.fromOffset(state.bytecodeSidebarWidth + outputWidth + panelGap * 2, 0)
		inspectorPanel.Size = UDim2.fromOffset(state.bytecodeInspectorWidth, workspaceHeight)

		treeScroll.Size = UDim2.new(1, -24, 1, -120)
		outputViewerHost.Size = UDim2.new(1, -24, 1, -116)
		outputScroll.Size = UDim2.new(1, 0, 1, 0)
		inspectorScroll.Size = UDim2.new(1, -24, 1, -24)

		syncOutputCanvas()
	end

	refs.applyLayout = applyLayout

	bindDrag(topBar, main)
	bindWindowResize(rightResizeHandle, "right")
	bindWindowResize(leftResizeHandle, "left")
	bindWindowResize(topResizeHandle, "top")
	bindWindowResize(bottomResizeHandle, "bottom")
	bindWindowResize(bottomRightResizeHandle, "bottomright")
	bindVerticalSplitter(mainSplitter, "mainControlsWidth", 420, function()
		return math.max(520, main.AbsoluteSize.X - 320)
	end)
	bindVerticalSplitter(bytecodeSplitter, "bytecodeSidebarWidth", 240, function()
		return math.max(280, main.AbsoluteSize.X - state.bytecodeInspectorWidth - 420)
	end)
	bindVerticalSplitter(inspectorSplitter, "bytecodeInspectorWidth", 280, function()
		return math.max(320, main.AbsoluteSize.X - state.bytecodeSidebarWidth - 420)
	end)

	trackConnection(main:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout))
	trackConnection(outputScroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncOutputCanvas))
	applyLayout()

	refs.gui = screenGui
	refs.main = main
	refs.closeButton = closeButton
	refs.suiteStatus = suiteStatus
	refs.mainTabButton = mainTabButton
	refs.bytecodeTabButton = bytecodeTabButton
	refs.profilesTabButton = profilesTabButton
	refs.mainWorkspace = mainWorkspace
	refs.bytecodeWorkspace = bytecodeWorkspace
	refs.profilesWorkspace = profilesWorkspace
	refs.mainStatusLabel = mainStatusLabel
	refs.selectedPlayerLabel = selectedPlayerLabel
	refs.playerSearchBox = playerSearchBox
	refs.playerContent = playerContent
	refs.scriptCountLabel = scriptCountLabel
	refs.treeSearchBox = treeSearchBox
	refs.treeContent = treeContent
	refs.refreshTreeButton = refreshTreeButton
	refs.outputSourceLabel = outputSourceLabel
	refs.outputSummaryLabel = outputSummaryLabel
	refs.outputCodeLabel = outputCodeLabel
	refs.syncOutputCanvas = syncOutputCanvas
	refs.inspectorStatusLabel = inspectorStatusLabel
	refs.chunkSummaryLabel = chunkSummaryLabel
	refs.scriptModeButton = scriptModeButton
	refs.fileModeButton = fileModeButton
	refs.binaryButton = binaryButton
	refs.hexButton = hexButton
	refs.targetBox = targetBox
	refs.loadButton = loadButton
	refs.reloadButton = reloadButton
	refs.activeTargetLabel = activeTargetLabel
	refs.codeViewButton = codeViewButton
	refs.decompileViewButton = decompileViewButton
	refs.dataViewButton = dataViewButton
	refs.rawOpcodesButton = rawOpcodesButton
	refs.filterBox = filterBox
	refs.refreshViewButton = refreshViewButton
	refs.walkSlider = walkSlider
	refs.jumpSlider = jumpSlider
	refs.hipSlider = hipSlider
	refs.gravitySlider = gravitySlider
	refs.refreshStatsButton = refreshStatsButton
	refs.resetCharacterButton = resetCharacterButton
	refs.infiniteJumpToggle = infiniteJumpToggle
	refs.noClipToggle = noClipToggle
	refs.fullBrightToggle = fullBrightToggle
	refs.inspectorInfoLabel = inspectorInfoLabel

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
	local scope = getGlobalScope()
	local cleanupTasks = {}
	local cleaning = false

	local function trackConnection(connection)
		table.insert(cleanupTasks, connection)
		return connection
	end

	local function trackCleanup(fn)
		table.insert(cleanupTasks, fn)
		return fn
	end

	local function restoreLighting()
		if state.lightingSnapshot == nil then
			return
		end

		for key, value in pairs(state.lightingSnapshot) do
			pcall(function()
				Lighting[key] = value
			end)
		end
	end

	local function runCleanup()
		if cleaning then
			return
		end

		cleaning = true
		started = false

		for _, item in ipairs(refs.connections) do
			pcall(function()
				item:Disconnect()
			end)
		end

		for _, item in ipairs(cleanupTasks) do
			if typeof(item) == "RBXScriptConnection" then
				pcall(function()
					item:Disconnect()
				end)
			elseif type(item) == "function" then
				pcall(item)
			end
		end

		if state.fullBright then
			restoreLighting()
		end

		if refs.gui and refs.gui.Parent then
			refs.gui:Destroy()
		end

		if scope[SESSION_KEY] == runCleanup then
			scope[SESSION_KEY] = nil
		end
	end

	scope[SESSION_KEY] = runCleanup

	local function setSuiteStatus(text, color)
		refs.suiteStatus.Text = text
		refs.suiteStatus.TextColor3 = color or NativeUi.Theme.TextMuted
	end

	local function setStatus(text, color)
		refs.inspectorStatusLabel.Text = text
		refs.inspectorStatusLabel.TextColor3 = color or Color3.fromRGB(241, 232, 214)
		setSuiteStatus(text, color or NativeUi.Theme.TextMuted)
	end

	local function setMainStatus(text, color)
		refs.mainStatusLabel.Text = text
		refs.mainStatusLabel.TextColor3 = color or NativeUi.Theme.TextMuted
	end

	local function getSelectedPlayer()
		if state.selectedPlayerName == "" then
			return Players.LocalPlayer
		end

		return Players:FindFirstChild(state.selectedPlayerName)
	end

	local function getLocalCharacter()
		local player = Players.LocalPlayer
		return player and player.Character or nil
	end

	local function getLocalHumanoid()
		local character = getLocalCharacter()
		return character and character:FindFirstChildOfClass("Humanoid") or nil
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

	local function syncToggleButton(toggleRow, enabled)
		toggleRow.toggle.Text = enabled and "ON" or "OFF"
		NativeUi.setButtonSelected(toggleRow.toggle, enabled)
	end

	local function runMainAction(actionName, value)
		local handlers = config.ActionHandlers
		local customHandler = handlers and handlers[actionName]
		local context = {
			selectedPlayer = getSelectedPlayer(),
			localPlayer = Players.LocalPlayer,
			state = state,
		}

		if type(customHandler) == "function" then
			return pcall(customHandler, value, context)
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
				Workspace.Gravity = value
				return ("Gravity set to %s"):format(value)
			end
		elseif actionName == "resetCharacter" then
			defaultHandler = function()
				local player = Players.LocalPlayer
				if player == nil then
					error("LocalPlayer not found")
				end

				if player.LoadCharacter ~= nil then
					player:LoadCharacter()
				elseif player.Character ~= nil then
					player.Character:BreakJoints()
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

	local function setToggleState(toggleName, enabled)
		local handlers = config.ActionHandlers
		local context = {
			selectedPlayer = getSelectedPlayer(),
			localPlayer = Players.LocalPlayer,
			state = state,
		}
		local handlerName = ({
			infiniteJump = "toggleInfiniteJump",
			noClip = "toggleNoClip",
			fullBright = "toggleFullBright",
		})[toggleName]

		local customHandler = handlerName and handlers and handlers[handlerName]
		if type(customHandler) == "function" then
			return pcall(customHandler, enabled, context)
		end

		if toggleName == "fullBright" then
			if enabled and state.lightingSnapshot == nil then
				state.lightingSnapshot = {
					Ambient = Lighting.Ambient,
					Brightness = Lighting.Brightness,
					ColorShift_Bottom = Lighting.ColorShift_Bottom,
					ColorShift_Top = Lighting.ColorShift_Top,
					ClockTime = Lighting.ClockTime,
					FogEnd = Lighting.FogEnd,
					OutdoorAmbient = Lighting.OutdoorAmbient,
				}
			end

			if enabled then
				Lighting.Ambient = Color3.fromRGB(190, 190, 190)
				Lighting.OutdoorAmbient = Color3.fromRGB(205, 205, 205)
				Lighting.Brightness = 2.5
				Lighting.ClockTime = 14
				Lighting.FogEnd = 100000
				Lighting.ColorShift_Bottom = Color3.new()
				Lighting.ColorShift_Top = Color3.new()
			else
				restoreLighting()
				state.lightingSnapshot = nil
			end
		end

		state[toggleName] = enabled
		return true, ((enabled and "Enabled " or "Disabled ") .. toggleName)
	end

	local function collectOutputText()
		if state.lastResult == nil then
			return ""
		end

		local outputText
		if state.viewMode == "code" then
			outputText = formatCodeView(state.lastResult.chunk, state.showRawOpcodes)
		elseif state.viewMode == "decompile" then
			outputText = LuauDecompiler.decompileChunk(state.lastResult.chunk)
		else
			outputText = formatDataView(state.lastResult.chunk)
		end

		if state.filterText == "" then
			return outputText
		end

		local filtered = {}
		for _, line in ipairs(splitLines(outputText)) do
			if containsFilter(line, state.filterText) then
				table.insert(filtered, line)
			end
		end

		return table.concat(filtered, "\n")
	end

	local function renderOutputView()
		if state.lastError ~= nil then
			refs.outputSourceLabel.Text = "Load error"
			refs.outputSourceLabel.TextColor3 = NativeUi.Theme.Error
			refs.outputSummaryLabel.Text = tostring(state.lastError)
			refs.outputCodeLabel.Text = tostring(state.lastError)
			refs.outputCodeLabel.TextColor3 = NativeUi.Theme.Error
			refs.chunkSummaryLabel.Text = "No chunk loaded due to the current error."
			setStatus("Load error", NativeUi.Theme.Error)
			refs.syncOutputCanvas()
			return
		end

		if state.lastResult == nil then
			refs.outputSourceLabel.Text = "No target loaded"
			refs.outputSourceLabel.TextColor3 = NativeUi.Theme.TextMuted
			refs.outputSummaryLabel.Text = "Select a script in the tree or load a bytecode file from the inspector."
			refs.outputCodeLabel.Text = "No output yet."
			refs.outputCodeLabel.TextColor3 = NativeUi.Theme.TextMuted
			refs.chunkSummaryLabel.Text = "No chunk loaded"
			setStatus("Ready", Color3.fromRGB(241, 232, 214))
			refs.syncOutputCanvas()
			return
		end

		local chunk = state.lastResult.chunk
		local sourceKind = state.lastResult.sourceKind
		local sourceColor = sourceKind == "script" and NativeUi.Theme.Accent or NativeUi.Theme.Success
		refs.outputSourceLabel.Text = ("Loaded: %s"):format(state.lastResult.sourceLabel or "<unknown>")
		refs.outputSourceLabel.TextColor3 = sourceColor

		local outputText = collectOutputText()
		if outputText == "" then
			outputText = "No lines match the current filter."
			refs.outputCodeLabel.TextColor3 = NativeUi.Theme.TextMuted
		else
			refs.outputCodeLabel.TextColor3 = NativeUi.Theme.Text
		end

		refs.outputCodeLabel.Text = outputText
		refs.outputSummaryLabel.Text = ("version=%s  protos=%s  mode=%s  source=%s"):format(
			tostring(chunk.version),
			tostring(chunk.protoCount or 0),
			state.viewMode,
			sourceKind or "unknown"
		)

		local summary = {
			("Version %s"):format(tostring(chunk.version)),
			("Type %s"):format(tostring(chunk.typesVersion or 0)),
			("Protos %s"):format(tostring(chunk.protoCount or 0)),
			("Main %s"):format(tostring(chunk.mainProtoIndex or 0)),
		}

		if chunk.protos[1] and chunk.protos[1].behaviorSummary then
			table.insert(summary, chunk.protos[1].behaviorSummary)
		end

		refs.chunkSummaryLabel.Text = table.concat(summary, "\n")
		setStatus(("Loaded %s"):format(state.lastResult.sourceLabel or "<unknown>"), sourceColor)
		refs.syncOutputCanvas()
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

	local function loadScriptTarget()
		local path = trimText(state.scriptPath)
		if path == "" then
			state.lastResult = nil
			state.lastError = "No script path provided"
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

	local function loadFileTarget()
		local path = trimText(state.filePath)
		if path == "" then
			state.lastResult = nil
			state.lastError = "No file path provided"
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

	local function loadCurrentTarget()
		if state.sourceMode == "script" then
			loadScriptTarget()
		else
			loadFileTarget()
		end
	end

	local function refreshMainFields()
		local humanoid = getLocalHumanoid()
		if humanoid ~= nil then
			state.walkSpeedValue = humanoid.WalkSpeed
			state.jumpPowerValue = humanoid.JumpPower
			state.hipHeightValue = humanoid.HipHeight
		end

		state.gravityValue = Workspace.Gravity
	end

	local function bindSlider(sliderRef, minimum, maximum, initialValue, step, formatter, onChanged)
		local dragging = false
		local value = initialValue

		local function roundStep(nextValue)
			if step <= 0 then
				return nextValue
			end

			return math.floor((nextValue / step) + 0.5) * step
		end

		local function setValue(nextValue, fire)
			value = clamp(roundStep(nextValue), minimum, maximum)
			local alpha = (value - minimum) / (maximum - minimum)
			sliderRef.fill.Size = UDim2.new(alpha, 0, 1, 0)
			sliderRef.knob.Position = UDim2.new(alpha, -7, 0.5, -7)
			sliderRef.valueLabel.Text = formatter(value)

			if fire and onChanged then
				onChanged(value)
			end
		end

		local function valueFromPosition(positionX)
			local width = math.max(1, sliderRef.track.AbsoluteSize.X)
			local alpha = clamp((positionX - sliderRef.track.AbsolutePosition.X) / width, 0, 1)
			return minimum + (maximum - minimum) * alpha
		end

		local function beginDrag(input)
			dragging = true
			setValue(valueFromPosition(input.Position.X), true)

			trackConnection(input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end))
		end

		trackConnection(sliderRef.track.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				beginDrag(input)
			end
		end))

		trackConnection(sliderRef.knob.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				beginDrag(input)
			end
		end))

		trackConnection(UserInputService.InputChanged:Connect(function(input)
			if not dragging then
				return
			end

			if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
				return
			end

			setValue(valueFromPosition(input.Position.X), true)
		end))

		setValue(initialValue, false)

		return {
			setValue = function(nextValue)
				setValue(nextValue, false)
			end,
			getValue = function()
				return value
			end,
		}
	end

	local walkSpeedSlider = bindSlider(refs.walkSlider, 0, 200, state.walkSpeedValue, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.walkSpeedValue = value
	end)

	local jumpPowerSlider = bindSlider(refs.jumpSlider, 0, 250, state.jumpPowerValue, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.jumpPowerValue = value
	end)

	local hipHeightSlider = bindSlider(refs.hipSlider, -5, 25, state.hipHeightValue, 0.5, function(value)
		return string.format("%.1f", value)
	end, function(value)
		state.hipHeightValue = value
	end)

	local gravitySlider = bindSlider(refs.gravitySlider, 0, 400, state.gravityValue, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.gravityValue = value
	end)

	local function refreshPlayersList()
		NativeUi.clear(refs.playerContent)

		local players = Players:GetPlayers()
		table.sort(players, function(left, right)
			return string.lower(left.Name) < string.lower(right.Name)
		end)

		local shown = 0
		for _, player in ipairs(players) do
			local searchable = player.Name .. " " .. (player.DisplayName or "")
			if containsFilter(searchable, state.playerFilterText) then
				shown = shown + 1
				local button = NativeUi.makeButton(refs.playerContent, player.DisplayName ~= player.Name and (player.DisplayName .. " @" .. player.Name) or player.Name, {
					Size = UDim2.new(1, 0, 0, 30),
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
				})
				NativeUi.setButtonSelected(button, state.selectedPlayerName == player.Name)

				button.MouseButton1Click:Connect(function()
					state.selectedPlayerName = player.Name
					refs.selectedPlayerLabel.Text = ("Selected: %s"):format(player.Name)
					refreshPlayersList()
				end)
			end
		end

		if shown == 0 then
			NativeUi.makeLabel(refs.playerContent, "No players match the current filter.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
		end
	end

	local renderTreeView
	local syncControlState

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
				TextSize = 11,
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
			local button = NativeUi.makeButton(row, labelText, {
				Font = Enum.Font.Code,
				Position = UDim2.fromOffset(x, 0),
				Size = UDim2.new(1, -(x + 2), 0, 24),
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			NativeUi.setButtonSelected(button, state.selectedScriptPath == node.path)

			button.MouseButton1Click:Connect(function()
				state.activeTab = "bytecode"
				state.sourceMode = "script"
				state.scriptPath = node.path
				state.selectedScriptPath = node.path
				refs.targetBox.Text = state.scriptPath
				loadScriptTarget()
				renderTreeView()
				syncControlState()
			end)
		else
			NativeUi.makeLabel(row, labelText, {
				Font = Enum.Font.Code,
				Position = UDim2.fromOffset(x, 0),
				Size = UDim2.new(1, -(x + 2), 1, 0),
				TextColor3 = NativeUi.Theme.TextMuted,
				TextSize = 12,
			})
		end

		if expanded then
			for _, child in ipairs(node.children) do
				renderTreeNode(child)
			end
		end
	end

	renderTreeView = function()
		NativeUi.clear(refs.treeContent)

		if state.scriptBrowserError ~= nil then
			NativeUi.makeLabel(refs.treeContent, tostring(state.scriptBrowserError), {
				TextColor3 = NativeUi.Theme.Error,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
			refs.scriptCountLabel.Text = "Tree error"
			return
		end

		local visibleTree = getFilteredTree(state.scriptBrowserTree, state.treeFilterText)
		refs.scriptCountLabel.Text = ("Visible roots: %d"):format(#visibleTree)

		if #visibleTree == 0 then
			NativeUi.makeLabel(refs.treeContent, state.treeFilterText ~= "" and "No scripts match the current filter." or "No script-like instances were discovered in the current client view.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
			return
		end

		for _, rootNode in ipairs(visibleTree) do
			renderTreeNode(rootNode)
		end
	end

	syncControlState = function()
		refs.mainWorkspace.Visible = state.activeTab == "main"
		refs.bytecodeWorkspace.Visible = state.activeTab == "bytecode"
		refs.profilesWorkspace.Visible = state.activeTab == "profiles"

		NativeUi.setButtonSelected(refs.mainTabButton, state.activeTab == "main")
		NativeUi.setButtonSelected(refs.bytecodeTabButton, state.activeTab == "bytecode")
		NativeUi.setButtonSelected(refs.profilesTabButton, state.activeTab == "profiles")
		NativeUi.setButtonSelected(refs.scriptModeButton, state.sourceMode == "script")
		NativeUi.setButtonSelected(refs.fileModeButton, state.sourceMode == "file")
		NativeUi.setButtonSelected(refs.binaryButton, state.inputFormat == "binary")
		NativeUi.setButtonSelected(refs.hexButton, state.inputFormat == "hex")
		NativeUi.setButtonSelected(refs.codeViewButton, state.viewMode == "code")
		NativeUi.setButtonSelected(refs.decompileViewButton, state.viewMode == "decompile")
		NativeUi.setButtonSelected(refs.dataViewButton, state.viewMode == "data")
		NativeUi.setButtonSelected(refs.rawOpcodesButton, state.showRawOpcodes)

		syncToggleButton(refs.infiniteJumpToggle, state.infiniteJump)
		syncToggleButton(refs.noClipToggle, state.noClip)
		syncToggleButton(refs.fullBrightToggle, state.fullBright)

		refs.binaryButton.Visible = state.sourceMode == "file"
		refs.hexButton.Visible = state.sourceMode == "file"
		refs.targetBox.PlaceholderText = getActiveTargetPlaceholder()
		refs.targetBox.Text = getActiveTargetText()
		refs.filterBox.Text = state.filterText
		refs.treeSearchBox.Text = state.treeFilterText
		refs.playerSearchBox.Text = state.playerFilterText
		refs.activeTargetLabel.Text = ("Active target: %s"):format(getActiveTargetText() ~= "" and getActiveTargetText() or "-")
		refs.selectedPlayerLabel.Text = ("Selected: %s"):format(state.selectedPlayerName ~= "" and state.selectedPlayerName or "-")
	end

	local function applyNumericAction(actionName, value, label)
		local ok, result = runMainAction(actionName, value)
		if ok then
			setMainStatus(tostring(result or (label .. " updated")), NativeUi.Theme.Success)
			refreshMainFields()
			walkSpeedSlider.setValue(state.walkSpeedValue)
			jumpPowerSlider.setValue(state.jumpPowerValue)
			hipHeightSlider.setValue(state.hipHeightValue)
			gravitySlider.setValue(state.gravityValue)
			return
		end

		setMainStatus(tostring(result), NativeUi.Theme.Error)
	end

	local function toggleFeature(toggleName)
		local nextValue = not state[toggleName]
		local ok, result = setToggleState(toggleName, nextValue)
		if ok then
			setMainStatus(tostring(result), NativeUi.Theme.Success)
		else
			setMainStatus(tostring(result), NativeUi.Theme.Error)
		end

		syncControlState()
	end

	trackCleanup(restoreLighting)

	trackConnection(UserInputService.JumpRequest:Connect(function()
		if not state.infiniteJump then
			return
		end

		local humanoid = getLocalHumanoid()
		if humanoid ~= nil then
			humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
		end
	end))

	trackConnection(RunService.Stepped:Connect(function()
		if not state.noClip then
			return
		end

		local character = getLocalCharacter()
		if character == nil then
			return
		end

		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("BasePart") then
				descendant.CanCollide = false
			end
		end
	end))

	trackConnection(Players.PlayerAdded:Connect(refreshPlayersList))
	trackConnection(Players.PlayerRemoving:Connect(function(player)
		if state.selectedPlayerName == player.Name then
			state.selectedPlayerName = Players.LocalPlayer and Players.LocalPlayer.Name or ""
		end
		refreshPlayersList()
	end))

	trackConnection(refs.closeButton.MouseButton1Click:Connect(runCleanup))
	trackConnection(refs.mainTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "main"
		syncControlState()
	end))
	trackConnection(refs.bytecodeTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "bytecode"
		syncControlState()
	end))
	trackConnection(refs.profilesTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "profiles"
		syncControlState()
	end))
	trackConnection(refs.refreshTreeButton.MouseButton1Click:Connect(function()
		refreshScriptBrowser()
		renderTreeView()
	end))
	trackConnection(refs.loadButton.MouseButton1Click:Connect(function()
		setActiveTargetText(refs.targetBox.Text)
		loadCurrentTarget()
		syncControlState()
		renderTreeView()
	end))
	trackConnection(refs.reloadButton.MouseButton1Click:Connect(function()
		if state.lastLoadedTarget ~= nil then
			if state.lastLoadedSourceMode == "script" then
				state.sourceMode = "script"
				state.scriptPath = state.lastLoadedTarget
			elseif state.lastLoadedSourceMode == "file" then
				state.sourceMode = "file"
				state.filePath = state.lastLoadedTarget
			end
		end

		loadCurrentTarget()
		syncControlState()
		renderTreeView()
	end))
	trackConnection(refs.refreshViewButton.MouseButton1Click:Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end))
	trackConnection(refs.scriptModeButton.MouseButton1Click:Connect(function()
		state.sourceMode = "script"
		syncControlState()
	end))
	trackConnection(refs.fileModeButton.MouseButton1Click:Connect(function()
		state.sourceMode = "file"
		syncControlState()
	end))
	trackConnection(refs.binaryButton.MouseButton1Click:Connect(function()
		state.inputFormat = "binary"
		syncControlState()
	end))
	trackConnection(refs.hexButton.MouseButton1Click:Connect(function()
		state.inputFormat = "hex"
		syncControlState()
	end))
	trackConnection(refs.codeViewButton.MouseButton1Click:Connect(function()
		state.viewMode = "code"
		syncControlState()
		renderOutputView()
	end))
	trackConnection(refs.decompileViewButton.MouseButton1Click:Connect(function()
		state.viewMode = "decompile"
		syncControlState()
		renderOutputView()
	end))
	trackConnection(refs.dataViewButton.MouseButton1Click:Connect(function()
		state.viewMode = "data"
		syncControlState()
		renderOutputView()
	end))
	trackConnection(refs.rawOpcodesButton.MouseButton1Click:Connect(function()
		state.showRawOpcodes = not state.showRawOpcodes
		syncControlState()
		renderOutputView()
	end))
	trackConnection(refs.targetBox.FocusLost:Connect(function()
		setActiveTargetText(refs.targetBox.Text)
		syncControlState()
	end))
	trackConnection(refs.treeSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.treeFilterText = refs.treeSearchBox.Text
		renderTreeView()
	end))
	trackConnection(refs.playerSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.playerFilterText = refs.playerSearchBox.Text
		refreshPlayersList()
	end))
	trackConnection(refs.filterBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end))
	trackConnection(refs.walkSlider.applyButton.MouseButton1Click:Connect(function()
		applyNumericAction("setWalkSpeed", math.floor(walkSpeedSlider.getValue() + 0.5), "WalkSpeed")
	end))
	trackConnection(refs.jumpSlider.applyButton.MouseButton1Click:Connect(function()
		applyNumericAction("setJumpPower", math.floor(jumpPowerSlider.getValue() + 0.5), "JumpPower")
	end))
	trackConnection(refs.hipSlider.applyButton.MouseButton1Click:Connect(function()
		applyNumericAction("setHipHeight", hipHeightSlider.getValue(), "HipHeight")
	end))
	trackConnection(refs.gravitySlider.applyButton.MouseButton1Click:Connect(function()
		applyNumericAction("setGravity", math.floor(gravitySlider.getValue() + 0.5), "Gravity")
	end))
	trackConnection(refs.refreshStatsButton.MouseButton1Click:Connect(function()
		refreshMainFields()
		walkSpeedSlider.setValue(state.walkSpeedValue)
		jumpPowerSlider.setValue(state.jumpPowerValue)
		hipHeightSlider.setValue(state.hipHeightValue)
		gravitySlider.setValue(state.gravityValue)
		setMainStatus("Pulled current values", NativeUi.Theme.TextMuted)
	end))
	trackConnection(refs.resetCharacterButton.MouseButton1Click:Connect(function()
		local ok, result = runMainAction("resetCharacter")
		if ok then
			setMainStatus(tostring(result), NativeUi.Theme.Success)
		else
			setMainStatus(tostring(result), NativeUi.Theme.Error)
		end
	end))
	trackConnection(refs.infiniteJumpToggle.toggle.MouseButton1Click:Connect(function()
		toggleFeature("infiniteJump")
	end))
	trackConnection(refs.noClipToggle.toggle.MouseButton1Click:Connect(function()
		toggleFeature("noClip")
	end))
	trackConnection(refs.fullBrightToggle.toggle.MouseButton1Click:Connect(function()
		toggleFeature("fullBright")
	end))

	refreshMainFields()
	walkSpeedSlider.setValue(state.walkSpeedValue)
	jumpPowerSlider.setValue(state.jumpPowerValue)
	hipHeightSlider.setValue(state.hipHeightValue)
	gravitySlider.setValue(state.gravityValue)
	refreshPlayersList()
	refreshScriptBrowser()
	syncControlState()
	renderTreeView()
	renderOutputView()
	setMainStatus("Ready", NativeUi.Theme.TextMuted)
end

return BytecodeViewer
