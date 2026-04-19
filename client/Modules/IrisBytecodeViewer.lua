local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")

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
	local requestUrl = url .. (string.find(url, "?", 1, true) and "&" or "?") .. "t=" .. tostring(os.time())
	local source = httpGet(requestUrl)
	local chunk, compileError = loadstring(source)

	if not chunk then
		error(("Failed to compile %s: %s"):format(requestUrl, tostring(compileError)))
	end

	local ok, result = pcall(chunk)
	if not ok then
		error(("Failed to execute %s: %s"):format(requestUrl, tostring(result)))
	end

	state.cache[moduleName] = result
	return result
end

local LuauChunk = loadRemoteModule("LuauChunk")
local LuauBytecode = loadRemoteModule("LuauBytecode")
local NativeUi = loadRemoteModule("NativeUi")
local SuiteTheme = loadRemoteModule("Suite/Theme")
local SuiteMotion = loadRemoteModule("Suite/Motion")
local SuiteComponents = loadRemoteModule("Suite/Components")

if type(SuiteTheme.applyToNativeUi) == "function" then
	SuiteTheme.applyToNativeUi(NativeUi)
end

local BytecodeViewer = {}

local started = false
local GUI_NAME = "EclipsisControlGui"
local SESSION_KEY = "__DartViewerCleanup"
local MAX_AIM_MOUSE_STEP = 120
local NIL_SCRIPT_PATH_PREFIX = "__nil_script:"
local NIL_SCAN_LIMIT = 3000
local nilScriptRegistry = setmetatable({}, { __mode = "v" })
local nilScriptBrowserRoot = nil
local dynamicWorkspaceScripts = setmetatable({}, { __mode = "k" })
local UI_ICON = {
	main = "[+]",
	esp = "[E]",
	spy = "[S]",
	guns = "[G]",
	build = "[B]",
	remote = "[R]",
	code = "[C]",
	refresh = "[~]",
	copy = "[#]",
	load = "[>]",
	clear = "[x]",
	watch = "[!]",
}
local WORKSPACE_COPY = {
	main = {
		kicker = "MAIN",
		title = "Movement and utility",
		subtitle = "Fast local controls with compact automation and session state.",
		search = "Search movement, world, utility",
	},
	esp = {
		kicker = "ESP",
		title = "Fast visibility tools",
		subtitle = "Quick player, resource, and structure highlights without mass clutter.",
		search = "Search players, teams, structures",
	},
	spy = {
		kicker = "SPY",
		title = "Focused target intelligence",
		subtitle = "One priority read with recon, situation summary, and quick actions.",
		search = "Search members or teams",
	},
	guns = {
		kicker = "GUNS",
		title = "Scoped combat behaviour",
		subtitle = "Aimbot and target-part configuration isolated from build tools.",
		search = "Search combat settings",
	},
	build = {
		kicker = "BUILD",
		title = "Placement and route utilities",
		subtitle = "Building controls stay separate from guns and visibility.",
		search = "Search build tools",
	},
	remote = {
		kicker = "REMOTE",
		title = "Remote debugging",
		subtitle = "Inspect remotes and watch client remote traffic without firing calls.",
		search = "Search remote events, functions, logs",
	},
	bytecode = {
		kicker = "CODE",
		title = "Script inspection workflow",
		subtitle = "Three-pane bytecode, decompile, and control-flow analysis.",
		search = "Search scripts, commands or output",
	},
}

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

local function withLineNumbers(text)
	local numbered = {}
	local width = 4

	for index, line in ipairs(splitLines(text or "")) do
		table.insert(numbered, ("%0" .. tostring(width) .. "d | %s"):format(index, line))
	end

	if #numbered == 0 then
		return "0001 | "
	end

	return table.concat(numbered, "\n")
end

local function writeClipboard(text)
	local writer

	if type(setclipboard) == "function" then
		writer = setclipboard
	elseif type(toclipboard) == "function" then
		writer = toclipboard
	elseif type(set_clipboard) == "function" then
		writer = set_clipboard
	elseif type(writeclipboard) == "function" then
		writer = writeclipboard
	elseif type(syn) == "table" and type(syn.write_clipboard) == "function" then
		writer = syn.write_clipboard
	end

	if writer == nil then
		return false, "Clipboard API unavailable in this executor"
	end

	local ok, result = pcall(writer, tostring(text or ""))
	if not ok then
		return false, result
	end

	return true
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
	local scriptInstance = nilScriptRegistry[scriptPath]
	local ok = true

	if scriptInstance == nil then
		ok, scriptInstance = pcall(function()
			return resolveInstanceByPath(scriptPath)
		end)
	end

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

local function buildNilScriptBrowserNode(scriptInstance, index)
	local path = NIL_SCRIPT_PATH_PREFIX .. tostring(index) .. ":" .. scriptInstance.Name
	nilScriptRegistry[path] = scriptInstance

	return {
		name = scriptInstance.Name,
		path = path,
		className = scriptInstance.ClassName .. " nil",
		isScript = true,
		children = {},
		depth = 1,
	}
end

local function buildNilScriptBrowserRoot(forceScan)
	if not forceScan then
		return nilScriptBrowserRoot
	end

	for path in pairs(nilScriptRegistry) do
		nilScriptRegistry[path] = nil
	end
	nilScriptBrowserRoot = nil

	if type(getnilinstances) ~= "function" then
		return nil
	end

	local objects = getnilinstances()
	if type(objects) ~= "table" then
		return nil
	end

	local nodes = {}
	local seen = {}
	local scanned = 0

	for _, value in pairs(objects) do
		scanned = scanned + 1
		if scanned > NIL_SCAN_LIMIT then
			break
		end

		if typeof(value) == "Instance" and isScriptLike(value) and not seen[value] then
			seen[value] = true
			table.insert(nodes, buildNilScriptBrowserNode(value, #nodes + 1))
		end
	end

	if #nodes == 0 then
		return nil
	end

	table.sort(nodes, function(left, right)
		return string.lower(left.name) < string.lower(right.name)
	end)

	nilScriptBrowserRoot = {
		name = "Nil Instances",
		path = "__nil_instances",
		className = ("nil %d"):format(#nodes),
		isScript = false,
		children = nodes,
		depth = 0,
	}

	return nilScriptBrowserRoot
end

local function buildDynamicWorkspaceScriptRoot()
	local nodes = {}

	for scriptInstance in pairs(dynamicWorkspaceScripts) do
		if typeof(scriptInstance) == "Instance" and scriptInstance.Parent ~= nil and isScriptLike(scriptInstance) then
			table.insert(nodes, {
				name = scriptInstance.Name,
				path = scriptInstance:GetFullName(),
				className = scriptInstance.ClassName .. " live",
				isScript = true,
				children = {},
				depth = 1,
			})
		else
			dynamicWorkspaceScripts[scriptInstance] = nil
		end
	end

	if #nodes == 0 then
		return nil
	end

	table.sort(nodes, function(left, right)
		return string.lower(left.path) < string.lower(right.path)
	end)

	return {
		name = "Live Workspace Scripts",
		path = "__workspace_live_scripts",
		className = ("workspace %d"):format(#nodes),
		isScript = false,
		children = nodes,
		depth = 0,
	}
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

	local localPlayer = Players.LocalPlayer
	if localPlayer ~= nil then
		push(localPlayer)
		push(localPlayer:FindFirstChildOfClass("PlayerScripts"))
		push(localPlayer:FindFirstChildOfClass("PlayerGui"))
		push(localPlayer:FindFirstChildOfClass("Backpack"))
		push(localPlayer.Character)
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

local function buildScriptBrowserTree(forceNilScan)
	local roots = {}

	for _, root in ipairs(collectScriptBrowserRoots()) do
		local node = buildScriptBrowserNode(root, 0)
		if node ~= nil then
			table.insert(roots, node)
		end
	end

	local workspaceRoot = buildDynamicWorkspaceScriptRoot()
	if workspaceRoot ~= nil then
		table.insert(roots, workspaceRoot)
	end

	local nilRoot = buildNilScriptBrowserRoot(forceNilScan)
	if nilRoot ~= nil then
		table.insert(roots, nilRoot)
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

local function isRemoteLike(instance)
	return typeof(instance) == "Instance"
		and (instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") or instance.ClassName == "UnreliableRemoteEvent")
end

local function getRemotePath(instance)
	if typeof(instance) ~= "Instance" then
		return tostring(instance)
	end

	return instance:GetFullName()
end

local function collectRemoteBrowserRoots()
	local roots = {}
	local seen = {}

	local function push(instance)
		if typeof(instance) ~= "Instance" or seen[instance] then
			return
		end

		seen[instance] = true
		table.insert(roots, instance)
	end

	push(game:GetService("ReplicatedStorage"))
	push(game:GetService("ReplicatedFirst"))
	push(Workspace)

	local localPlayer = Players.LocalPlayer
	if localPlayer ~= nil then
		push(localPlayer)
		push(localPlayer:FindFirstChildOfClass("PlayerGui"))
		push(localPlayer:FindFirstChildOfClass("Backpack"))
		push(localPlayer.Character)
	end

	return roots
end

local function buildRemoteBrowserList()
	local remotes = {}
	local seen = {}

	for _, root in ipairs(collectRemoteBrowserRoots()) do
		if isRemoteLike(root) and not seen[root] then
			seen[root] = true
			table.insert(remotes, root)
		end

		for _, descendant in ipairs(root:GetDescendants()) do
			if isRemoteLike(descendant) and not seen[descendant] then
				seen[descendant] = true
				table.insert(remotes, descendant)
			end
		end
	end

	table.sort(remotes, function(left, right)
		return string.lower(getRemotePath(left)) < string.lower(getRemotePath(right))
	end)

	return remotes
end

local function packRemoteArgs(...)
	return {
		n = select("#", ...),
		...,
	}
end

local function getPackedArgCount(args)
	if type(args) ~= "table" then
		return 0
	end

	return tonumber(args.n) or #args
end

local function formatRemoteValue(value, depth, seen)
	depth = depth or 0
	seen = seen or {}
	if depth > 3 then
		return "..."
	end

	if value == nil then
		return "nil"
	end

	local valueType = typeof(value)
	if valueType == "Instance" then
		return value:GetFullName()
	elseif valueType == "string" then
		return string.format("%q", value)
	elseif valueType == "number" or valueType == "boolean" then
		return tostring(value)
	elseif valueType == "Vector3" then
		return ("Vector3(%s, %s, %s)"):format(math.floor(value.X * 100) / 100, math.floor(value.Y * 100) / 100, math.floor(value.Z * 100) / 100)
	elseif valueType == "Vector2" then
		return ("Vector2(%s, %s)"):format(math.floor(value.X * 100) / 100, math.floor(value.Y * 100) / 100)
	elseif valueType == "Color3" then
		return ("Color3(%s, %s, %s)"):format(math.floor(value.R * 255), math.floor(value.G * 255), math.floor(value.B * 255))
	elseif valueType == "BrickColor" then
		return ("BrickColor(%q)"):format(value.Name)
	elseif valueType == "EnumItem" then
		return tostring(value)
	elseif valueType == "CFrame" then
		local position = value.Position
		return ("CFrame(%s, %s, %s, ...)"):format(math.floor(position.X * 100) / 100, math.floor(position.Y * 100) / 100, math.floor(position.Z * 100) / 100)
	elseif type(value) == "table" then
		if seen[value] then
			return "{...cycle...}"
		end

		seen[value] = true
		local parts = {}
		local count = 0
		for key, item in pairs(value) do
			count = count + 1
			if count > 8 then
				table.insert(parts, "...")
				break
			end
			table.insert(parts, ("%s=%s"):format(formatRemoteValue(key, depth + 1, seen), formatRemoteValue(item, depth + 1, seen)))
		end
		seen[value] = nil
		return "{" .. table.concat(parts, ", ") .. "}"
	end

	return tostring(value)
end

local function formatRemoteArgs(args)
	local parts = {}
	local count = getPackedArgCount(args)
	for index = 1, count do
		parts[index] = formatRemoteValue(args[index], 0)
	end
	return table.concat(parts, ", ")
end

local function formatRemoteArgLines(args)
	local lines = {}
	local count = getPackedArgCount(args)
	if count == 0 then
		return "  <no args>"
	end

	for index = 1, count do
		local value = args[index]
		table.insert(lines, ("  [%d] %s = %s"):format(index, typeof(value), formatRemoteValue(value, 0)))
	end
	return table.concat(lines, "\n")
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
		espPlayerFilterText = "",
		selectedPlayerName = Players.LocalPlayer and Players.LocalPlayer.Name or "",
		selectedScriptPath = nil,
		scriptBrowserTree = {},
		scriptBrowserError = nil,
		expandedNodes = {},
		remoteFilterText = "",
		remoteLogs = {},
		remoteList = {},
		selectedRemotePath = nil,
		remoteWatcherEnabled = false,
		remoteHookInstalled = false,
		remoteHookError = nil,
		notifications = {},
		nextNotificationId = 0,
		lastResult = nil,
		lastError = nil,
		lastLoadedSourceMode = nil,
		lastLoadedTarget = nil,
		mainControlsWidth = 500,
		bytecodeSidebarWidth = 280,
		bytecodeInspectorWidth = 320,
		windowMinSize = Vector2.new(1100, 700),
		windowMaxSize = nil,
		isMinimized = false,
		restoredSize = nil,
		espPlayersWidth = 330,
		infiniteJump = false,
		noClip = false,
		fullBright = false,
		aimbotEnabled = false,
		aimHoldActive = false,
		aimTargetPart = "nearest",
		aimLockedPlayerName = "",
		aimLockedPartName = "",
		highlightFillTransparency = 0.65,
		highlightedPlayers = {},
		highlightAllPlayers = false,
		espObjectToggles = {
			spawnPoint = false,
			wellPump = false,
			iridium = false,
			spireWell = false,
			well = false,
		},
		iridiumMinFullness = 0.5,
		wellDistance = 600,
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
		Font = Enum.Font.GothamSemibold,
		Text = text,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Size = UDim2.new(1, 0, 0, 18),
	})
end

local function addSectionTitle(parent, text, y, x)
	local label = makeSectionTitle(parent, text)
	label.Position = UDim2.fromOffset(x or 12, y or 10)
	return label
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

local function makeOutputViewer(parent)
	local scroll = NativeUi.create("ScrollingFrame", {
		Active = true,
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		BackgroundColor3 = NativeUi.Theme.Panel,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		Position = UDim2.fromOffset(0, 0),
		ScrollBarImageColor3 = NativeUi.Theme.TextDim,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.XY,
		Size = UDim2.new(1, 0, 1, 0),
		Parent = parent,
	})
	NativeUi.corner(scroll, 10)
	NativeUi.stroke(scroll, NativeUi.Theme.Border, 1, 0.18)
	SuiteComponents.decorateScroll(scroll, SuiteTheme, SuiteTheme.Variants.Code)

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
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Parent = scroll,
	})

	local function syncCanvas()
		local text = codeLabel.Text ~= "" and codeLabel.Text or " "
		local ok, bounds = pcall(function()
			return TextService:GetTextSize(text, codeLabel.TextSize, codeLabel.Font, Vector2.new(100000, 100000))
		end)

		local height = scroll.AbsoluteSize.Y
		local width = math.max(220, scroll.AbsoluteSize.X - padding * 2 - 10)
		if ok and bounds then
			width = math.max(width, bounds.X + 20)
			height = math.max(height, bounds.Y + padding * 2 + 6)
		else
			local lineCount = math.max(1, #splitLines(text))
			height = math.max(height, lineCount * 16 + padding * 2 + 6)
		end

		codeLabel.Size = UDim2.fromOffset(width, height - padding * 2)
		scroll.CanvasSize = UDim2.fromOffset(width + padding * 2, height)
	end

	return scroll, codeLabel, syncCanvas
end

local function makeSliderRow(parent, y, labelText)
	local row = NativeUi.makePanel(parent, {
		Position = UDim2.new(0, 12, 0, y),
		Size = UDim2.new(1, -24, 0, 54),
		BackgroundColor3 = NativeUi.Theme.Surface,
		CornerRadius = 8,
	})

	local label = NativeUi.makeLabel(row, labelText, {
		Font = Enum.Font.GothamSemibold,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 8),
		Size = UDim2.new(1, -144, 0, 18),
	})

	local valueLabel = NativeUi.makeLabel(row, "0", {
		Font = Enum.Font.Code,
		TextSize = 11,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -112, 0, 8),
		Size = UDim2.fromOffset(42, 18),
	})

	local applyButton = NativeUi.makeButton(row, "Set", {
		Position = UDim2.new(1, -56, 0, 6),
		Size = UDim2.fromOffset(44, 22),
		TextSize = 11,
	})

	local track = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Surface,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -24, 0, 6),
		Parent = row,
	})
	NativeUi.corner(track, 999)
	NativeUi.stroke(track, NativeUi.Theme.Border, 1, 0.35)

	local fill = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Accent,
		BorderSizePixel = 0,
		Size = UDim2.new(0, 0, 1, 0),
		Parent = track,
	})
	NativeUi.corner(fill, 999)
	local knob = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundColor3 = NativeUi.Theme.Text,
		BorderSizePixel = 0,
		Position = UDim2.new(0, -6, 0.5, -6),
		Size = UDim2.fromOffset(12, 12),
		Text = "",
		ZIndex = 3,
		Parent = track,
	})
	NativeUi.corner(knob, 999)
	NativeUi.stroke(knob, NativeUi.Theme.Border, 1, 0.1)

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
	local row = NativeUi.makeButton(parent, "", {
		Position = UDim2.new(0, 12, 0, y),
		Size = UDim2.new(1, -24, 0, 40),
		TextSize = 1,
		Palette = {
			Base = NativeUi.Theme.Surface,
			Hover = NativeUi.Theme.SurfaceHover,
			Pressed = NativeUi.Theme.SurfaceActive,
			Selected = NativeUi.Theme.Success,
			Disabled = Color3.fromRGB(17, 20, 26),
			Text = NativeUi.Theme.Text,
			SelectedText = NativeUi.Theme.Text,
			DisabledText = NativeUi.Theme.TextDim,
		},
	})
	row.Text = ""

	local title = NativeUi.makeLabel(row, labelText, {
		Font = Enum.Font.GothamSemibold,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -48, 1, 0),
	})

	local indicator = NativeUi.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(245, 248, 252),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(1, -21, 0.5, 0),
		Size = UDim2.fromOffset(8, 8),
		Parent = row,
	})
	NativeUi.corner(indicator, 3)

	return {
		row = row,
		title = title,
		toggle = row,
		indicator = indicator,
		description = description,
	}
end

local function makeOverlayPanel(parent, properties, radius, strokeColor, strokeTransparency)
	local panel = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Overlay,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Parent = parent,
	})

	for key, value in pairs(properties or {}) do
		if key ~= "CornerRadius" then
			panel[key] = value
		end
	end

	NativeUi.corner(panel, radius or ((properties and properties.CornerRadius) or 18))
	NativeUi.stroke(panel, strokeColor or NativeUi.Theme.Border, 1, strokeTransparency or 0.1)
	SuiteComponents.stylePanel(panel, SuiteTheme, {
		background = NativeUi.Theme.Overlay,
		transparency = 0,
		radius = radius or ((properties and properties.CornerRadius) or 18),
		stroke = strokeColor or NativeUi.Theme.Border,
		strokeTransparency = strokeTransparency or SuiteTheme.Transparency.StrokeStrong,
		gradient = true,
	})
	return panel
end

local function createOverlayLayers(screenGui, refs)
	local dynamicIsland = makeOverlayPanel(screenGui, {
		Name = "DynamicIsland",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 18),
		Size = UDim2.fromOffset(220, 52),
		ZIndex = 40,
	}, 26, NativeUi.Theme.Border, 0.05)
	SuiteComponents.stylePanel(dynamicIsland, SuiteTheme, SuiteTheme.Variants.Island)

	refs.dynamicIsland = dynamicIsland
	refs.dynamicIslandDot = NativeUi.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = NativeUi.Theme.Success,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(28, 26),
		Size = UDim2.fromOffset(9, 9),
		ZIndex = 41,
		Parent = dynamicIsland,
	})
	NativeUi.corner(refs.dynamicIslandDot, 999)

	refs.dynamicIslandTitle = NativeUi.makeLabel(dynamicIsland, "Assist", {
		Font = Enum.Font.GothamBold,
		TextSize = 13,
		Position = UDim2.fromOffset(48, 10),
		Size = UDim2.new(1, -92, 0, 18),
		ZIndex = 41,
	})

	refs.dynamicIslandDetail = NativeUi.makeLabel(dynamicIsland, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		Position = UDim2.fromOffset(48, 28),
		Size = UDim2.new(1, -92, 0, 14),
		TextWrapped = true,
		ZIndex = 41,
	})

	refs.dynamicIslandBadge = NativeUi.makeLabel(dynamicIsland, "LIVE", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -68, 0, 17),
		Size = UDim2.fromOffset(48, 18),
		ZIndex = 41,
	})

	local alertRail = NativeUi.create("Frame", {
		Name = "AlertRail",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(14, 92),
		Size = UDim2.fromOffset(306, 252),
		ZIndex = 35,
		Parent = screenGui,
	})

	local function makeAlertCard(index)
		local card = makeOverlayPanel(alertRail, {
			Position = UDim2.fromOffset(0, (index - 1) * 84),
			Size = UDim2.fromOffset(306, 74),
			ZIndex = 35,
		}, 16, NativeUi.Theme.Border, 0.18)

		return {
			frame = card,
			level = NativeUi.makeLabel(card, "INFO", {
				Font = Enum.Font.Code,
				TextColor3 = NativeUi.Theme.TextMuted,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromOffset(14, 10),
				Size = UDim2.new(1, -28, 0, 14),
				ZIndex = 36,
			}),
			title = NativeUi.makeLabel(card, "Ready", {
				Font = Enum.Font.GothamBold,
				TextSize = 13,
				Position = UDim2.fromOffset(14, 27),
				Size = UDim2.new(1, -28, 0, 18),
				ZIndex = 36,
			}),
			detail = NativeUi.makeLabel(card, "Suite initialized", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextSize = 12,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				Position = UDim2.fromOffset(14, 47),
				Size = UDim2.new(1, -28, 0, 20),
				ZIndex = 36,
			}),
		}
	end

	refs.alertCards = {
		makeAlertCard(1),
		makeAlertCard(2),
		makeAlertCard(3),
	}
end

local function createSpyWorkspace(spyWorkspace, refs)
	refs.spySelectorPanel = NativeUi.makePanel(spyWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(300, 100),
	})
	SuiteComponents.stylePanel(refs.spySelectorPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local spySelectorTitle = makeSectionTitle(refs.spySelectorPanel, "Member Selection")
	spySelectorTitle.Position = UDim2.fromOffset(12, 12)

	NativeUi.makeLabel(refs.spySelectorPanel, "Pick one target to focus recon. ESP stays broad; Spy stays narrow.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -24, 0, 34),
	})

	refs.spyClearButton = NativeUi.makeButton(refs.spySelectorPanel, "Clear Focus", {
		Position = UDim2.fromOffset(12, 76),
		Size = UDim2.fromOffset(104, 28),
		TextSize = 12,
	})

	refs.spyMemberScroll, refs.spyMemberContent = NativeUi.makeScrollList(refs.spySelectorPanel, {
		Position = UDim2.fromOffset(12, 114),
		Size = UDim2.new(1, -24, 1, -126),
		Padding = 6,
		ContentPadding = 8,
		BackgroundColor3 = NativeUi.Theme.Surface,
	})
	SuiteComponents.decorateScroll(refs.spyMemberScroll, SuiteTheme, SuiteTheme.Variants.Control)

	refs.spyReconPanel = NativeUi.makePanel(spyWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(316, 0),
		Size = UDim2.fromOffset(520, 100),
	})
	SuiteComponents.stylePanel(refs.spyReconPanel, SuiteTheme, {
		background = SuiteTheme.Colors.Panel,
		transparency = 0,
		radius = SuiteTheme.Radius.CardLarge,
		stroke = SuiteTheme.Colors.Stroke,
		strokeTransparency = SuiteTheme.Transparency.StrokeStrong,
		gradient = true,
	})

	NativeUi.makeLabel(refs.spyReconPanel, "Spy Intel", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(16, 18),
		Size = UDim2.new(1, -32, 0, 24),
	})

	NativeUi.makeLabel(refs.spyReconPanel, "Focused target intelligence. One read, low clutter.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 43),
		Size = UDim2.new(1, -32, 0, 16),
	})

	refs.spyThreatPill = NativeUi.makeLabel(refs.spyReconPanel, "IDLE", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -116, 0, 22),
		Size = UDim2.fromOffset(92, 16),
	})

	refs.spyFigure = NativeUi.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundColor3 = NativeUi.Theme.Surface,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0, 96),
		Size = UDim2.fromOffset(96, 132),
		Parent = refs.spyReconPanel,
	})
	NativeUi.corner(refs.spyFigure, 44)
	NativeUi.stroke(refs.spyFigure, NativeUi.Theme.Border, 1, 0.18)
	SuiteComponents.stylePanel(refs.spyFigure, SuiteTheme, {
		background = SuiteTheme.Colors.Surface,
		transparency = 0,
		radius = 44,
		stroke = SuiteTheme.Colors.Stroke,
		strokeTransparency = SuiteTheme.Transparency.Stroke,
		gradient = true,
	})

	refs.spyTargetNameLabel = NativeUi.makeLabel(refs.spyReconPanel, "No focus target", {
		Font = Enum.Font.GothamBold,
		TextSize = 20,
		Position = UDim2.fromOffset(16, 260),
		Size = UDim2.new(1, -32, 0, 26),
	})

	refs.spyTargetDetailLabel = NativeUi.makeLabel(refs.spyReconPanel, "Select a member from the left panel.", {
		TextColor3 = NativeUi.Theme.TextDim,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 288),
		Size = UDim2.new(1, -32, 0, 18),
	})

	refs.spyMetricDistanceLabel = NativeUi.makeLabel(refs.spyReconPanel, "Distance: -", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 328),
		Size = UDim2.new(0.5, -24, 0, 18),
	})

	refs.spyMetricTeamLabel = NativeUi.makeLabel(refs.spyReconPanel, "Team: -", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.new(0.5, 8, 0, 328),
		Size = UDim2.new(0.5, -24, 0, 18),
	})

	refs.spyMetricHealthLabel = NativeUi.makeLabel(refs.spyReconPanel, "Health: -", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 352),
		Size = UDim2.new(0.5, -24, 0, 18),
	})

	refs.spyMetricStateLabel = NativeUi.makeLabel(refs.spyReconPanel, "State: waiting", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.new(0.5, 8, 0, 352),
		Size = UDim2.new(0.5, -24, 0, 18),
	})

	refs.spySupportPanel = NativeUi.makePanel(spyWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(852, 0),
		Size = UDim2.fromOffset(260, 100),
	})
	SuiteComponents.stylePanel(refs.spySupportPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local spySituationTitle = makeSectionTitle(refs.spySupportPanel, "Situation")
	spySituationTitle.Position = UDim2.fromOffset(12, 12)

	refs.spySituationSummary = makeBodyLabel(refs.spySupportPanel, "No focus target selected. Pin a player to promote them into the intelligence capsule and alert rail.", {
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local spyActionsTitle = makeSectionTitle(refs.spySupportPanel, "Quick Actions")
	spyActionsTitle.Position = UDim2.fromOffset(12, 122)

	refs.spyPinButton = NativeUi.makeButton(refs.spySupportPanel, "Pin Target", {
		Position = UDim2.fromOffset(12, 154),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	refs.spyHighlightButton = NativeUi.makeButton(refs.spySupportPanel, "Toggle Highlight", {
		Position = UDim2.fromOffset(12, 192),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})
end

local function createRemoteWorkspace(remoteWorkspace, refs)
	refs.remoteListPanel = NativeUi.makePanel(remoteWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(320, 100),
	})
	SuiteComponents.stylePanel(refs.remoteListPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local listTitle = makeSectionTitle(refs.remoteListPanel, UI_ICON.remote .. " Remotes")
	listTitle.Position = UDim2.fromOffset(12, 12)

	refs.remoteCountLabel = NativeUi.makeLabel(refs.remoteListPanel, "Scan ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		Position = UDim2.fromOffset(12, 36),
		Size = UDim2.new(1, -24, 0, 16),
	})

	refs.remoteSearchBox = NativeUi.makeTextBox(refs.remoteListPanel, "", {
		PlaceholderText = "Filter remotes",
		Position = UDim2.fromOffset(12, 62),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	refs.remoteListScroll, refs.remoteListContent = NativeUi.makeScrollList(refs.remoteListPanel, {
		Position = UDim2.fromOffset(12, 104),
		Size = UDim2.new(1, -24, 1, -116),
		Padding = 5,
		ContentPadding = 8,
		BackgroundColor3 = NativeUi.Theme.Surface,
	})
	SuiteComponents.decorateScroll(refs.remoteListScroll, SuiteTheme, SuiteTheme.Variants.Control)

	refs.remoteLogPanel = NativeUi.makePanel(remoteWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(336, 0),
		Size = UDim2.fromOffset(520, 100),
	})
	SuiteComponents.stylePanel(refs.remoteLogPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local logTitle = makeSectionTitle(refs.remoteLogPanel, UI_ICON.watch .. " Remote Inspector")
	logTitle.Position = UDim2.fromOffset(12, 12)

	refs.remoteWatcherToggle = makeToggleRow(refs.remoteLogPanel, 38, "Remote Watcher", "Capture client calls and server events.")
	refs.remoteWatcherToggle.row.Size = UDim2.fromOffset(210, 34)

	refs.scanRemotesButton = NativeUi.makeButton(refs.remoteLogPanel, UI_ICON.refresh .. " Scan", {
		Position = UDim2.new(1, -206, 0, 36),
		Size = UDim2.fromOffset(92, 30),
		TextSize = 12,
	})

	refs.clearRemoteLogButton = NativeUi.makeButton(refs.remoteLogPanel, UI_ICON.clear .. " Clear", {
		Position = UDim2.new(1, -106, 0, 36),
		Size = UDim2.fromOffset(94, 30),
		TextSize = 12,
	})

	refs.remoteLogStatusLabel = NativeUi.makeLabel(refs.remoteLogPanel, "Select a remote to inspect class, path and payloads.", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 78),
		Size = UDim2.new(1, -24, 0, 18),
	})

	refs.remoteInspectorTitleLabel = NativeUi.makeLabel(refs.remoteLogPanel, "No remote selected", {
		Font = Enum.Font.GothamBold,
		TextColor3 = NativeUi.Theme.Text,
		TextSize = 14,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(12, 104),
		Size = UDim2.new(1, -24, 0, 24),
	})

	refs.remoteInspectorMetaLabel = NativeUi.makeLabel(refs.remoteLogPanel, "Class: -    Calls: 0    Last: -", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(12, 130),
		Size = UDim2.new(1, -24, 0, 36),
	})

	refs.remoteLogHost = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 174),
		Size = UDim2.new(1, -24, 1, -186),
		Parent = refs.remoteLogPanel,
	})
	refs.remoteLogScroll, refs.remoteLogLabel, refs.syncRemoteLogCanvas = makeOutputViewer(refs.remoteLogHost)
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

	createOverlayLayers(screenGui, refs)

	local main = NativeUi.makePanel(screenGui, {
		Name = "Main",
		BackgroundColor3 = NativeUi.Theme.Background,
		BackgroundTransparency = 1,
		Position = UDim2.new(0.5, -680, 0.5, -325),
		Size = UDim2.fromOffset(1360, 650),
		ClipsDescendants = true,
	})
	if main:FindFirstChildOfClass("UIStroke") ~= nil then
		main:FindFirstChildOfClass("UIStroke").Transparency = 1
	end

	local shadow = NativeUi.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = Color3.fromRGB(0, 0, 0),
		BackgroundTransparency = 0.78,
		BorderSizePixel = 0,
		Position = UDim2.new(0.5, 0, 0.5, 6),
		Size = UDim2.new(1, 18, 1, 18),
		ZIndex = -1,
		Parent = main,
	})
	NativeUi.corner(shadow, 14)
	shadow.Visible = false

	local navWidth = 184
	local contentX = 204
	local shellY = 16
	local shellPadding = 12
	local shellHeaderHeight = 72
	local workspaceTopInset = shellPadding + shellHeaderHeight + 12
	local navButtonPalette = {
		Base = NativeUi.Theme.Panel,
		Hover = NativeUi.Theme.Surface,
		Pressed = NativeUi.Theme.SurfaceActive,
		Selected = NativeUi.Theme.SurfaceActive,
		Disabled = Color3.fromRGB(17, 20, 26),
		Text = NativeUi.Theme.TextMuted,
		SelectedText = NativeUi.Theme.Text,
		DisabledText = NativeUi.Theme.TextDim,
	}

	local navRail = NativeUi.makePanel(main, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		BackgroundTransparency = 0,
		Position = UDim2.fromOffset(0, shellY),
		Size = UDim2.fromOffset(navWidth, 618),
		CornerRadius = 18,
	})
	SuiteComponents.stylePanel(navRail, SuiteTheme, SuiteTheme.Variants.Sidebar)

	local topBar = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Background,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(contentX, shellY),
		Size = UDim2.new(1, -(contentX + 12), 0, 40),
		Parent = main,
	})

	NativeUi.makeLabel(navRail, "Dart", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(16, 18),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local mainTabButton = NativeUi.makeButton(navRail, "  " .. UI_ICON.main .. " Main", {
		Position = UDim2.fromOffset(12, 70),
		Size = UDim2.new(1, -24, 0, 32),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = navButtonPalette,
	})

	local espTabButton = NativeUi.makeButton(navRail, "  " .. UI_ICON.esp .. " ESP", {
		Position = UDim2.fromOffset(12, 108),
		Size = UDim2.new(1, -24, 0, 32),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = navButtonPalette,
	})

	local spyTabButton = NativeUi.makeButton(navRail, "  " .. UI_ICON.spy .. " Spy", {
		Position = UDim2.fromOffset(12, 146),
		Size = UDim2.new(1, -24, 0, 32),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = navButtonPalette,
	})

	local gunsTabButton = NativeUi.makeButton(navRail, "  " .. UI_ICON.guns .. " Guns", {
		Position = UDim2.fromOffset(12, 184),
		Size = UDim2.new(1, -24, 0, 32),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = navButtonPalette,
	})

	local buildTabButton = NativeUi.makeButton(navRail, "  " .. UI_ICON.build .. " Build", {
		Position = UDim2.fromOffset(12, 222),
		Size = UDim2.new(1, -24, 0, 32),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = navButtonPalette,
	})

	local remoteTabButton = NativeUi.makeButton(navRail, "  " .. UI_ICON.remote .. " Remote", {
		Position = UDim2.fromOffset(12, 260),
		Size = UDim2.new(1, -24, 0, 32),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = navButtonPalette,
	})

	local bytecodeTabButton = NativeUi.makeButton(navRail, "  " .. UI_ICON.code .. " Code", {
		Position = UDim2.fromOffset(12, 298),
		Size = UDim2.new(1, -24, 0, 32),
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = navButtonPalette,
	})

	local navSessionCard = NativeUi.makePanel(navRail, {
		BackgroundColor3 = NativeUi.Theme.Surface,
		BackgroundTransparency = 0,
		Position = UDim2.new(0, 12, 1, -96),
		Size = UDim2.new(1, -24, 0, 78),
		CornerRadius = 14,
	})
	SuiteComponents.stylePanel(navSessionCard, SuiteTheme, SuiteTheme.Variants.CardSoft)

	NativeUi.makeLabel(navSessionCard, "Session integrity", {
		Font = Enum.Font.GothamBold,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 10),
		Size = UDim2.new(1, -24, 0, 16),
	})

	NativeUi.makeLabel(navSessionCard, "Hook state        Stable", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		Position = UDim2.fromOffset(12, 34),
		Size = UDim2.new(1, -24, 0, 13),
	})

	NativeUi.makeLabel(navSessionCard, "Suite             v4", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		Position = UDim2.fromOffset(12, 50),
		Size = UDim2.new(1, -24, 0, 13),
	})

	local suiteStatus = NativeUi.makeLabel(topBar, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Right,
		Position = UDim2.new(1, -280, 0, 0),
		Size = UDim2.fromOffset(210, 40),
		Visible = false,
	})

	local minimizeButton = NativeUi.makeButton(topBar, "-", {
		Position = UDim2.new(1, -66, 0, 6),
		Size = UDim2.fromOffset(26, 26),
		TextSize = 14,
		Palette = navButtonPalette,
	})

	local closeButton = NativeUi.makeButton(topBar, "X", {
		Position = UDim2.new(1, -34, 0, 6),
		Size = UDim2.fromOffset(26, 26),
		TextSize = 12,
		Palette = {
			Base = NativeUi.Theme.Panel,
			Hover = Color3.fromRGB(44, 24, 28),
			Pressed = Color3.fromRGB(57, 30, 35),
			Selected = Color3.fromRGB(72, 38, 43),
			Text = NativeUi.Theme.TextMuted,
			SelectedText = NativeUi.Theme.Text,
		},
	})

	local workspaceShell = NativeUi.makePanel(main, {
		Name = "WorkspaceShell",
		BackgroundColor3 = NativeUi.Theme.Shell,
		BackgroundTransparency = 0,
		Position = UDim2.fromOffset(contentX, shellY),
		Size = UDim2.new(1, -(contentX + 12), 1, -32),
		CornerRadius = 20,
	})
	SuiteComponents.stylePanel(workspaceShell, SuiteTheme, SuiteTheme.Variants.Shell)
	workspaceShell.ClipsDescendants = true

	local workspaceHeader = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Panel,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(shellPadding, shellPadding),
		Size = UDim2.new(1, -shellPadding * 2, 0, shellHeaderHeight),
		Parent = workspaceShell,
	})
	SuiteComponents.stylePanel(workspaceHeader, SuiteTheme, {
		background = SuiteTheme.Colors.Panel,
		transparency = 0,
		radius = 24,
		stroke = SuiteTheme.Colors.Stroke,
		strokeTransparency = SuiteTheme.Transparency.Stroke,
		gradient = true,
	})

	local workspaceKickerLabel = NativeUi.makeLabel(workspaceHeader, "CODE", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		Position = UDim2.fromOffset(16, 9),
		Size = UDim2.new(0, 180, 0, 14),
	})

	local workspaceTitleLabel = NativeUi.makeLabel(workspaceHeader, "Script inspection workflow", {
		Font = Enum.Font.GothamBold,
		TextSize = 15,
		Position = UDim2.fromOffset(16, 27),
		Size = UDim2.new(0.45, 0, 0, 20),
	})

	local workspaceSubtitleLabel = NativeUi.makeLabel(workspaceHeader, "Three-pane bytecode, decompile, and control-flow analysis.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 49),
		Size = UDim2.new(0.56, 0, 0, 16),
	})

	local workspaceSearchButton = NativeUi.makeButton(workspaceHeader, "Search scripts, commands or output", {
		Position = UDim2.new(1, -314, 0, 18),
		Size = UDim2.fromOffset(254, 34),
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Left,
		Palette = {
			Base = NativeUi.Theme.Surface,
			Hover = NativeUi.Theme.SurfaceHover,
			Pressed = NativeUi.Theme.SurfaceActive,
			Selected = NativeUi.Theme.SurfaceActive,
			Disabled = NativeUi.Theme.Surface,
			Text = NativeUi.Theme.TextDim,
			SelectedText = NativeUi.Theme.Text,
			DisabledText = NativeUi.Theme.TextDim,
		},
	})

	local workspacePulseButton = NativeUi.makeButton(workspaceHeader, "!", {
		Position = UDim2.new(1, -52, 0, 20),
		Size = UDim2.fromOffset(32, 30),
		TextSize = 12,
		Palette = navButtonPalette,
	})

	local mainWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = workspaceShell,
	})

	local espWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = workspaceShell,
	})

	local spyWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = workspaceShell,
	})

	local bytecodeWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = workspaceShell,
	})

	local gunsWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = workspaceShell,
	})

	local buildWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = workspaceShell,
	})

	local remoteWorkspace = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, 0, 1, 0),
		Parent = workspaceShell,
	})

	local mainScroll, mainContent = NativeUi.makeScrollList(mainWorkspace, {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 1, -24),
		Padding = 10,
		ContentPadding = 0,
		BackgroundColor3 = NativeUi.Theme.Panel,
	})
	SuiteComponents.decorateScroll(mainScroll, SuiteTheme, {
		background = SuiteTheme.Colors.Panel,
		transparency = 0,
		radius = SuiteTheme.Radius.Card,
		strokeTransparency = SuiteTheme.Transparency.StrokeStrong,
	})

	local movementSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 222),
		Parent = mainContent,
	})

	addSectionTitle(movementSection, "Movement")

	local walkSlider = makeSliderRow(movementSection, 40, "Walk Speed")
	local jumpSlider = makeSliderRow(movementSection, 100, "Jump Power")
	local hipSlider = makeSliderRow(movementSection, 160, "Hip Height")

	local automationSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 178),
		Parent = mainContent,
	})

	addSectionTitle(automationSection, "Automation")

	local infiniteJumpToggle = makeToggleRow(automationSection, 40, "Infinite Jump", "Keeps jump requests hot for the local character when enabled.")
	local noClipToggle = makeToggleRow(automationSection, 86, "NoClip", "Suppresses part collisions on the local character during stepped updates.")
	local fullBrightToggle = makeToggleRow(automationSection, 132, "FullBright", "Pins lighting into a bright analysis state and restores it when disabled.")

	local worldSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 104),
		Parent = mainContent,
	})

	addSectionTitle(worldSection, "World")

	local gravitySlider = makeSliderRow(worldSection, 42, "Gravity")

	local sessionSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 114),
		Parent = mainContent,
	})

	addSectionTitle(sessionSection, "Session")

	local mainStatusLabel = NativeUi.makeLabel(sessionSection, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 38),
		Size = UDim2.new(1, -24, 0, 16),
	})

	local refreshStatsButton = NativeUi.makeButton(sessionSection, "Refresh Stats", {
		Position = UDim2.fromOffset(12, 72),
		Size = UDim2.fromOffset(110, 28),
		TextSize = 12,
	})

	local resetCharacterButton = NativeUi.makeButton(sessionSection, "Reset", {
		Position = UDim2.fromOffset(130, 72),
		Size = UDim2.fromOffset(74, 28),
		TextSize = 12,
	})

	local espPlayersPanel = NativeUi.makePanel(espWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(330, 100),
	})
	SuiteComponents.stylePanel(espPlayersPanel, SuiteTheme, SuiteTheme.Variants.Card)

	addSectionTitle(espPlayersPanel, "Players", 12)

	local highlightAllPlayersButton = NativeUi.makeButton(espPlayersPanel, "Highlight All Players", {
		Position = UDim2.fromOffset(12, 40),
		Size = UDim2.fromOffset(150, 28),
		TextSize = 11,
		Palette = {
			Base = NativeUi.Theme.Surface,
			Hover = NativeUi.Theme.SurfaceHover,
			Pressed = NativeUi.Theme.SurfaceActive,
			Selected = Color3.fromRGB(92, 182, 124),
			Disabled = Color3.fromRGB(25, 28, 36),
			Text = NativeUi.Theme.Text,
			SelectedText = Color3.fromRGB(8, 18, 10),
			DisabledText = NativeUi.Theme.TextDim,
		},
	})

	local clearPlayerHighlightsButton = NativeUi.makeButton(espPlayersPanel, "Clear", {
		Position = UDim2.fromOffset(170, 40),
		Size = UDim2.fromOffset(60, 28),
		TextSize = 11,
	})

	local espSelectedPlayersLabel = NativeUi.makeLabel(espPlayersPanel, "Highlighted: 0", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 76),
		Size = UDim2.new(1, -24, 0, 16),
	})

	local espPlayerSearchBox = NativeUi.makeTextBox(espPlayersPanel, "", {
		PlaceholderText = "Filter players",
		Position = UDim2.fromOffset(12, 104),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	local espPlayerScroll, espPlayerContent = NativeUi.makeScrollList(espPlayersPanel, {
		Position = UDim2.fromOffset(12, 142),
		Size = UDim2.new(1, -24, 1, -154),
		Padding = 6,
		ContentPadding = 8,
		BackgroundColor3 = NativeUi.Theme.Surface,
	})
	SuiteComponents.decorateScroll(espPlayerScroll, SuiteTheme, SuiteTheme.Variants.Control)

	local espResourcesPanel = NativeUi.makePanel(espWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(346, 0),
		Size = UDim2.fromOffset(356, 100),
	})
	SuiteComponents.stylePanel(espResourcesPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local espWellsPanel = NativeUi.makePanel(espWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(718, 0),
		Size = UDim2.new(1, -718, 1, 0),
	})
	SuiteComponents.stylePanel(espWellsPanel, SuiteTheme, SuiteTheme.Variants.Card)

	addSectionTitle(espResourcesPanel, "Resources", 12)

	local spawnPointToggle = makeToggleRow(espResourcesPanel, 40, "Spawn Point", "Highlights any instance named Spawn Point in the workspace.")
	local wellPumpToggle = makeToggleRow(espResourcesPanel, 86, "Well Pump", "Highlights any instance named Well Pump in the workspace.")
	local iridiumToggle = makeToggleRow(espResourcesPanel, 132, "Iridium Crystals", "Filters Workspace.Resources by CrystalFullness and highlights crystals at or above the threshold.")
	local iridiumSlider = makeSliderRow(espResourcesPanel, 178, "Minimum Fullness")

	addSectionTitle(espWellsPanel, "Structures", 12)

	local spireWellToggle = makeToggleRow(espWellsPanel, 40, "Spire Well", "Maps to SpireOpenLarge1 in Workspace.Map and only shows entries within the selected distance.")
	local wellToggle = makeToggleRow(espWellsPanel, 86, "Well", "Maps to Top1 in Workspace.Map and only shows entries within the selected distance.")
	local wellDistanceSlider = makeSliderRow(espWellsPanel, 132, "Distance")

	createSpyWorkspace(spyWorkspace, refs)
	createRemoteWorkspace(remoteWorkspace, refs)

	local scriptPanel = NativeUi.makePanel(bytecodeWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(280, 100),
	})
	SuiteComponents.stylePanel(scriptPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local bytecodeSplitter = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundColor3 = NativeUi.Theme.Border,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(288, 0),
		Size = UDim2.fromOffset(6, 100),
		Text = "",
		Parent = bytecodeWorkspace,
	})
	NativeUi.corner(bytecodeSplitter, 999)

	local outputPanel = NativeUi.makePanel(bytecodeWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(302, 0),
		Size = UDim2.fromOffset(500, 100),
	})
	SuiteComponents.stylePanel(outputPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local inspectorSplitter = NativeUi.create("TextButton", {
		Active = true,
		AutoButtonColor = false,
		BackgroundColor3 = NativeUi.Theme.Border,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(810, 0),
		Size = UDim2.fromOffset(6, 100),
		Text = "",
		Parent = bytecodeWorkspace,
	})
	NativeUi.corner(inspectorSplitter, 999)

	local inspectorPanel = NativeUi.makePanel(bytecodeWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(824, 0),
		Size = UDim2.new(1, -824, 1, 0),
	})
	SuiteComponents.stylePanel(inspectorPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local scriptHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 86),
		Parent = scriptPanel,
	})

	addSectionTitle(scriptHeader, "Scripts", 0, 0)

	local scriptCountLabel = NativeUi.makeLabel(scriptHeader, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(0, 22),
		Size = UDim2.new(1, -90, 0, 16),
	})

	local refreshTreeButton = NativeUi.makeButton(scriptHeader, UI_ICON.refresh .. " Refresh", {
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
		BackgroundColor3 = NativeUi.Theme.Surface,
	})
	SuiteComponents.decorateScroll(treeScroll, SuiteTheme, SuiteTheme.Variants.Control)

	local outputHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 0, 82),
		Parent = outputPanel,
	})

	local outputTitle = makeSectionTitle(outputHeader, "Output", Color3.fromRGB(255, 224, 171))
	outputTitle.Position = UDim2.fromOffset(0, 0)
	outputTitle.Size = UDim2.new(1, -218, 0, 20)

	local copyOpcodesButton = NativeUi.makeButton(outputHeader, UI_ICON.copy .. " Opcodes", {
		Position = UDim2.new(1, -210, 0, 0),
		Size = UDim2.fromOffset(100, 24),
		TextSize = 11,
		CornerRadius = 8,
	})

	local copyDecompileButton = NativeUi.makeButton(outputHeader, UI_ICON.copy .. " Decompile", {
		Position = UDim2.new(1, -104, 0, 0),
		Size = UDim2.fromOffset(104, 24),
		TextSize = 11,
		CornerRadius = 8,
	})

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
		BackgroundColor3 = NativeUi.Theme.Panel,
	})
	SuiteComponents.decorateScroll(inspectorScroll, SuiteTheme, {
		background = SuiteTheme.Colors.Panel,
		transparency = 0,
		radius = SuiteTheme.Radius.Card,
		strokeTransparency = 1,
	})

	local intelCard = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 108),
		Parent = inspectorContent,
	})

	local intelTitle = NativeUi.makeLabel(intelCard, "Inspector", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local inspectorStatusLabel = NativeUi.makeLabel(intelCard, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 44),
		Size = UDim2.new(1, -32, 0, 16),
	})

	local inspectorInfoLabel = makeBodyLabel(intelCard, "Script mode uses getscriptbytecode. File mode stays as the offline fallback.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		Position = UDim2.fromOffset(16, 66),
		Size = UDim2.new(1, -32, 0, 0),
	})

	local inputSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 192),
		Parent = inspectorContent,
	})

	addSectionTitle(inputSection, "Input")

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

	local loadButton = NativeUi.makeButton(inputSection, UI_ICON.load .. " Load", {
		Position = UDim2.fromOffset(12, 122),
		Size = UDim2.fromOffset(74, 28),
		TextSize = 12,
	})

	local reloadButton = NativeUi.makeButton(inputSection, UI_ICON.refresh .. " Reload", {
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

	local viewSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 176),
		Parent = inspectorContent,
	})

	addSectionTitle(viewSection, "View")

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

	local flowViewButton = NativeUi.makeButton(viewSection, "Flow", {
		Position = UDim2.fromOffset(254, 42),
		Size = UDim2.fromOffset(64, 28),
		TextSize = 12,
	})

	local rawOpcodesButton = NativeUi.makeButton(viewSection, "Raw Opcodes", {
		Position = UDim2.fromOffset(12, 82),
		Size = UDim2.fromOffset(116, 28),
		TextSize = 12,
	})

	local viewHint = makeBodyLabel(viewSection, "Flow builds CFG/basic blocks. Decompile v2 is still conservative around structured if/loop recovery.", {
		Position = UDim2.fromOffset(12, 116),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local filterSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 126),
		Parent = inspectorContent,
	})

	addSectionTitle(filterSection, "Filter")

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

	local filterHint = NativeUi.makeLabel(filterSection, "Filters visible lines only", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(122, 88),
		Size = UDim2.new(1, -134, 0, 16),
	})

	local summarySection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 128),
		Parent = inspectorContent,
	})

	addSectionTitle(summarySection, "Summary")

	local chunkSummaryLabel = makeBodyLabel(summarySection, "No chunk loaded", {
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local gunsScroll, gunsContent = NativeUi.makeScrollList(gunsWorkspace, {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 1, -24),
		Padding = 10,
		ContentPadding = 0,
		BackgroundColor3 = NativeUi.Theme.Panel,
	})
	SuiteComponents.decorateScroll(gunsScroll, SuiteTheme, {
		background = SuiteTheme.Colors.Panel,
		transparency = 0,
		radius = SuiteTheme.Radius.Card,
		strokeTransparency = SuiteTheme.Transparency.StrokeStrong,
	})

	local buildingScroll, buildingContent = NativeUi.makeScrollList(buildWorkspace, {
		Position = UDim2.fromOffset(12, 12),
		Size = UDim2.new(1, -24, 1, -24),
		Padding = 10,
		ContentPadding = 0,
		BackgroundColor3 = NativeUi.Theme.Panel,
	})
	SuiteComponents.decorateScroll(buildingScroll, SuiteTheme, {
		background = SuiteTheme.Colors.Panel,
		transparency = 0,
		radius = SuiteTheme.Radius.Card,
		strokeTransparency = SuiteTheme.Transparency.StrokeStrong,
	})

	local gunsHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 82),
		Parent = gunsContent,
	})

	local gunsTitle = NativeUi.makeLabel(gunsHeader, "Guns", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local gunsBody = makeBodyLabel(gunsHeader, "Hold Ctrl to lock the cursor onto the target nearest your mouse while the aimbot is enabled.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 42),
		Size = UDim2.new(1, -32, 0, 0),
	})

	local gunCombatSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 134),
		Parent = gunsContent,
	})

	addSectionTitle(gunCombatSection, "Aimbot")

	local aimbotToggle = makeToggleRow(gunCombatSection, 40, "Enable Aimbot", "Moves the cursor onto the target nearest the mouse while Ctrl is pressed.")

	local gunCombatBody = makeBodyLabel(gunCombatSection, "Only active while Ctrl is held. The lock reacquires if the current target drops out of view.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 88),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local gunUtilitySection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 156),
		Parent = gunsContent,
	})

	addSectionTitle(gunUtilitySection, "Target Part")

	local aimNearestButton = NativeUi.makeButton(gunUtilitySection, "Nearest", {
		Position = UDim2.fromOffset(12, 40),
		Size = UDim2.fromOffset(88, 28),
		TextSize = 12,
	})

	local aimHeadButton = NativeUi.makeButton(gunUtilitySection, "Head", {
		Position = UDim2.fromOffset(108, 40),
		Size = UDim2.fromOffset(70, 28),
		TextSize = 12,
	})

	local aimTorsoButton = NativeUi.makeButton(gunUtilitySection, "Torso", {
		Position = UDim2.fromOffset(186, 40),
		Size = UDim2.fromOffset(74, 28),
		TextSize = 12,
	})

	local aimArmsButton = NativeUi.makeButton(gunUtilitySection, "Arms", {
		Position = UDim2.fromOffset(12, 76),
		Size = UDim2.fromOffset(70, 28),
		TextSize = 12,
	})

	local aimLegsButton = NativeUi.makeButton(gunUtilitySection, "Legs", {
		Position = UDim2.fromOffset(90, 76),
		Size = UDim2.fromOffset(70, 28),
		TextSize = 12,
	})

	local aimLimbsButton = NativeUi.makeButton(gunUtilitySection, "Limbs", {
		Position = UDim2.fromOffset(168, 76),
		Size = UDim2.fromOffset(78, 28),
		TextSize = 12,
	})

	local aimStatusLabel = makeBodyLabel(gunUtilitySection, "Aimbot disabled", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 114),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local buildingHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 82),
		Parent = buildingContent,
	})

	local buildingTitle = NativeUi.makeLabel(buildingHeader, "Building", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(16, 14),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local buildingBody = makeBodyLabel(buildingHeader, "Placement, snapping, piece selection, and structure edits get their own column instead of sharing gun controls.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 42),
		Size = UDim2.new(1, -32, 0, 0),
	})

	local buildPlacementSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 128),
		Parent = buildingContent,
	})

	addSectionTitle(buildPlacementSection, "Placement")

	local buildPlacementBody = makeBodyLabel(buildPlacementSection, "This is where grid offsets, preview state, placement remotes, and rotation logic should land.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local buildEditSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 128),
		Parent = buildingContent,
	})

	addSectionTitle(buildEditSection, "Edit")

	local buildEditBody = makeBodyLabel(buildEditSection, "Upgrade, delete, swap-piece, and ownership flows can be isolated here once you walk through the build system.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.new(1, -24, 0, 0),
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
		local shellWidth = width - (contentX + 12)
		local shellHeight = math.max(0, height - shellY * 2)
		local workspaceWidth = math.max(0, shellWidth - shellPadding * 2)
		local workspaceHeight = math.max(0, shellHeight - workspaceTopInset - shellPadding)
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
		navRail.Position = UDim2.fromOffset(0, shellY)
		navRail.Size = UDim2.fromOffset(navWidth, shellHeight)
		topBar.Position = UDim2.fromOffset(contentX, shellY)
		topBar.Size = UDim2.fromOffset(shellWidth, 40)
		workspaceShell.Position = UDim2.fromOffset(contentX, shellY)
		workspaceShell.Size = UDim2.fromOffset(shellWidth, shellHeight)
		workspaceHeader.Position = UDim2.fromOffset(shellPadding, shellPadding)
		workspaceHeader.Size = UDim2.new(1, -shellPadding * 2, 0, shellHeaderHeight)
		workspaceSearchButton.Position = UDim2.new(1, -314, 0, 18)
		workspacePulseButton.Position = UDim2.new(1, -52, 0, 20)

		mainWorkspace.Position = UDim2.fromOffset(shellPadding, workspaceTopInset)
		mainWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		espWorkspace.Position = UDim2.fromOffset(shellPadding, workspaceTopInset)
		espWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		spyWorkspace.Position = UDim2.fromOffset(shellPadding, workspaceTopInset)
		spyWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		bytecodeWorkspace.Position = UDim2.fromOffset(shellPadding, workspaceTopInset)
		bytecodeWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		gunsWorkspace.Position = UDim2.fromOffset(shellPadding, workspaceTopInset)
		gunsWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		buildWorkspace.Position = UDim2.fromOffset(shellPadding, workspaceTopInset)
		buildWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		remoteWorkspace.Position = UDim2.fromOffset(shellPadding, workspaceTopInset)
		remoteWorkspace.Size = UDim2.fromOffset(workspaceWidth, workspaceHeight)
		mainScroll.Size = UDim2.new(1, -24, 1, -24)

		local espResourceWidth = clamp(math.floor((workspaceWidth - state.espPlayersWidth - panelGap * 2) * 0.5), 260, 360)
		state.espPlayersWidth = clamp(state.espPlayersWidth, 280, math.max(300, workspaceWidth - espResourceWidth - 280 - panelGap * 2))
		espResourceWidth = clamp(math.floor((workspaceWidth - state.espPlayersWidth - panelGap * 2) * 0.5), 260, 360)
		local espWellsWidth = workspaceWidth - state.espPlayersWidth - espResourceWidth - panelGap * 2
		if espWellsWidth < 280 then
			espResourceWidth = math.max(240, espResourceWidth - (280 - espWellsWidth))
			espWellsWidth = workspaceWidth - state.espPlayersWidth - espResourceWidth - panelGap * 2
		end
		espPlayersPanel.Size = UDim2.fromOffset(state.espPlayersWidth, workspaceHeight)
		espResourcesPanel.Position = UDim2.fromOffset(state.espPlayersWidth + panelGap, 0)
		espResourcesPanel.Size = UDim2.fromOffset(espResourceWidth, workspaceHeight)
		espWellsPanel.Position = UDim2.fromOffset(state.espPlayersWidth + espResourceWidth + panelGap * 2, 0)
		espWellsPanel.Size = UDim2.fromOffset(espWellsWidth, workspaceHeight)
		espPlayerSearchBox.Size = UDim2.new(1, -24, 0, 30)
		espPlayerScroll.Size = UDim2.new(1, -24, 1, -154)

		local spySelectorWidth = 300
		local spySupportWidth = 260
		local spyReconWidth = workspaceWidth - spySelectorWidth - spySupportWidth - panelGap * 2
		if spyReconWidth < 340 then
			local deficit = 340 - spyReconWidth
			spySupportWidth = math.max(220, spySupportWidth - deficit)
			spyReconWidth = workspaceWidth - spySelectorWidth - spySupportWidth - panelGap * 2
		end

		refs.spySelectorPanel.Size = UDim2.fromOffset(spySelectorWidth, workspaceHeight)
		refs.spyMemberScroll.Size = UDim2.new(1, -24, 1, -126)
		refs.spyReconPanel.Position = UDim2.fromOffset(spySelectorWidth + panelGap, 0)
		refs.spyReconPanel.Size = UDim2.fromOffset(spyReconWidth, workspaceHeight)
		refs.spySupportPanel.Position = UDim2.fromOffset(spySelectorWidth + spyReconWidth + panelGap * 2, 0)
		refs.spySupportPanel.Size = UDim2.fromOffset(spySupportWidth, workspaceHeight)

		local remoteListWidth = 320
		local remoteLogWidth = workspaceWidth - remoteListWidth - panelGap
		refs.remoteListPanel.Size = UDim2.fromOffset(remoteListWidth, workspaceHeight)
		refs.remoteListScroll.Size = UDim2.new(1, -24, 1, -116)
		refs.remoteLogPanel.Position = UDim2.fromOffset(remoteListWidth + panelGap, 0)
		refs.remoteLogPanel.Size = UDim2.fromOffset(remoteLogWidth, workspaceHeight)
		refs.remoteLogHost.Size = UDim2.new(1, -24, 1, -186)
		refs.remoteLogScroll.Size = UDim2.new(1, 0, 1, 0)

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
		refs.syncRemoteLogCanvas()
		inspectorScroll.Size = UDim2.new(1, -24, 1, -24)
		gunsScroll.Size = UDim2.new(1, -24, 1, -24)
		buildingScroll.Size = UDim2.new(1, -24, 1, -24)

		syncOutputCanvas()
	end

	refs.applyLayout = applyLayout

	bindDrag(topBar, main)
	bindDrag(navRail, main)
	bindDrag(workspaceHeader, main)
	bindWindowResize(rightResizeHandle, "right")
	bindWindowResize(leftResizeHandle, "left")
	bindWindowResize(topResizeHandle, "top")
	bindWindowResize(bottomResizeHandle, "bottom")
	bindWindowResize(bottomRightResizeHandle, "bottomright")
	bindVerticalSplitter(bytecodeSplitter, "bytecodeSidebarWidth", 240, function()
		return math.max(280, main.AbsoluteSize.X - (contentX + 12) - state.bytecodeInspectorWidth - 420)
	end)
	bindVerticalSplitter(inspectorSplitter, "bytecodeInspectorWidth", 280, function()
		return math.max(320, main.AbsoluteSize.X - (contentX + 12) - state.bytecodeSidebarWidth - 420)
	end)

	trackConnection(main:GetPropertyChangedSignal("AbsoluteSize"):Connect(applyLayout))
	trackConnection(outputScroll:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncOutputCanvas))
	applyLayout()

	refs.gui = screenGui
	refs.main = main
	refs.workspaceShell = workspaceShell
	refs.workspaceKickerLabel = workspaceKickerLabel
	refs.workspaceTitleLabel = workspaceTitleLabel
	refs.workspaceSubtitleLabel = workspaceSubtitleLabel
	refs.workspaceSearchButton = workspaceSearchButton
	refs.workspacePulseButton = workspacePulseButton
	refs.minimizeButton = minimizeButton
	refs.closeButton = closeButton
	refs.suiteStatus = suiteStatus
	refs.mainTabButton = mainTabButton
	refs.espTabButton = espTabButton
	refs.spyTabButton = spyTabButton
	refs.gunsTabButton = gunsTabButton
	refs.remoteTabButton = remoteTabButton
	refs.bytecodeTabButton = bytecodeTabButton
	refs.buildTabButton = buildTabButton
	refs.bytecodeSplitter = bytecodeSplitter
	refs.inspectorSplitter = inspectorSplitter
	refs.rightResizeHandle = rightResizeHandle
	refs.leftResizeHandle = leftResizeHandle
	refs.topResizeHandle = topResizeHandle
	refs.bottomResizeHandle = bottomResizeHandle
	refs.bottomRightResizeHandle = bottomRightResizeHandle
	refs.mainWorkspace = mainWorkspace
	refs.espWorkspace = espWorkspace
	refs.spyWorkspace = spyWorkspace
	refs.bytecodeWorkspace = bytecodeWorkspace
	refs.gunsWorkspace = gunsWorkspace
	refs.buildWorkspace = buildWorkspace
	refs.remoteWorkspace = remoteWorkspace
	refs.mainStatusLabel = mainStatusLabel
	refs.espSelectedPlayersLabel = espSelectedPlayersLabel
	refs.espPlayerSearchBox = espPlayerSearchBox
	refs.espPlayerContent = espPlayerContent
	refs.highlightAllPlayersButton = highlightAllPlayersButton
	refs.clearPlayerHighlightsButton = clearPlayerHighlightsButton
	refs.spawnPointToggle = spawnPointToggle
	refs.wellPumpToggle = wellPumpToggle
	refs.iridiumToggle = iridiumToggle
	refs.spireWellToggle = spireWellToggle
	refs.wellToggle = wellToggle
	refs.scriptCountLabel = scriptCountLabel
	refs.treeSearchBox = treeSearchBox
	refs.treeContent = treeContent
	refs.refreshTreeButton = refreshTreeButton
	refs.outputSourceLabel = outputSourceLabel
	refs.outputSummaryLabel = outputSummaryLabel
	refs.outputCodeLabel = outputCodeLabel
	refs.copyOpcodesButton = copyOpcodesButton
	refs.copyDecompileButton = copyDecompileButton
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
	refs.flowViewButton = flowViewButton
	refs.rawOpcodesButton = rawOpcodesButton
	refs.filterBox = filterBox
	refs.refreshViewButton = refreshViewButton
	refs.walkSlider = walkSlider
	refs.jumpSlider = jumpSlider
	refs.hipSlider = hipSlider
	refs.gravitySlider = gravitySlider
	refs.iridiumSlider = iridiumSlider
	refs.wellDistanceSlider = wellDistanceSlider
	refs.refreshStatsButton = refreshStatsButton
	refs.resetCharacterButton = resetCharacterButton
	refs.aimbotToggle = aimbotToggle
	refs.aimNearestButton = aimNearestButton
	refs.aimHeadButton = aimHeadButton
	refs.aimTorsoButton = aimTorsoButton
	refs.aimArmsButton = aimArmsButton
	refs.aimLegsButton = aimLegsButton
	refs.aimLimbsButton = aimLimbsButton
	refs.aimStatusLabel = aimStatusLabel
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
	local LuauControlFlow = loadRemoteModule("LuauControlFlow")
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
	local syncControlState
	local updateSuiteOverlays

	local function setSuiteStatus(text, color)
		refs.suiteStatus.Text = text
		refs.suiteStatus.TextColor3 = color or NativeUi.Theme.TextMuted
	end

	local function setStatus(text, color)
		refs.inspectorStatusLabel.Text = text
		refs.inspectorStatusLabel.TextColor3 = color or Color3.fromRGB(241, 232, 214)
		setSuiteStatus(text, color or NativeUi.Theme.TextMuted)
	end

	local function normalizeNotificationLevel(level)
		level = string.lower(tostring(level or "info"))
		if level == "danger" or level == "error" then
			return "critical"
		elseif level == "warn" then
			return "warning"
		elseif level == "ok" then
			return "success"
		elseif level == "critical" or level == "warning" or level == "success" or level == "info" then
			return level
		end

		return "info"
	end

	local function notificationPriority(level)
		if level == "critical" then
			return 50
		elseif level == "warning" then
			return 40
		elseif level == "success" then
			return 30
		elseif level == "info" then
			return 20
		end

		return 10
	end

	local function pruneNotifications()
		local now = os.clock()
		local kept = {}
		for _, item in ipairs(state.notifications) do
			if item.expiresAt == nil or item.expiresAt > now then
				table.insert(kept, item)
			end
		end
		state.notifications = kept
	end

	local function removeNotification(id)
		for index = #state.notifications, 1, -1 do
			if state.notifications[index].id == id then
				table.remove(state.notifications, index)
			end
		end

		if updateSuiteOverlays ~= nil then
			updateSuiteOverlays()
		end
	end

	local function emitNotification(level, title, detail, options)
		options = options or {}
		local normalizedLevel = normalizeNotificationLevel(level)
		local duration = type(options.duration) == "number" and options.duration or tonumber(tostring(options.duration or ""))
		local sticky = options.permanent == true or options.sticky == true or options.pinned == true or options.duration == false
		local expiresAt = nil

		if not sticky then
			duration = duration or 4
			expiresAt = os.clock() + duration
		end

		state.nextNotificationId = state.nextNotificationId + 1
		local notification = {
			id = state.nextNotificationId,
			level = normalizedLevel,
			title = tostring(title or string.upper(normalizedLevel)),
			detail = tostring(detail or ""),
			createdAt = os.clock(),
			expiresAt = expiresAt,
			sticky = sticky,
			priority = tonumber(options.priority) or notificationPriority(normalizedLevel),
		}

		table.insert(state.notifications, notification)
		if expiresAt ~= nil then
			task.delay(duration + 0.05, function()
				if cleaning then
					return
				end
				removeNotification(notification.id)
			end)
		end

		if updateSuiteOverlays ~= nil then
			updateSuiteOverlays()
		end

		return notification.id
	end

	local notificationApi = {
		Emit = emitNotification,
		EmitInfo = function(title, detail, options)
			return emitNotification("info", title, detail, options)
		end,
		EmitSuccess = function(title, detail, options)
			return emitNotification("success", title, detail, options)
		end,
		EmitSucess = function(title, detail, options)
			return emitNotification("success", title, detail, options)
		end,
		EmitWarning = function(title, detail, options)
			return emitNotification("warning", title, detail, options)
		end,
		EmitDanger = function(title, detail, options)
			return emitNotification("critical", title, detail, options)
		end,
		EmitError = function(title, detail, options)
			return emitNotification("critical", title, detail, options)
		end,
		Remove = removeNotification,
		Clear = function()
			state.notifications = {}
			if updateSuiteOverlays ~= nil then
				updateSuiteOverlays()
			end
		end,
	}
	local dartApi = type(scope.Dart) == "table" and scope.Dart or {}
	scope.Dart = dartApi
	dartApi.Notifications = notificationApi
	dartApi.EmitInfo = notificationApi.EmitInfo
	dartApi.EmitSuccess = notificationApi.EmitSuccess
	dartApi.EmitSucess = notificationApi.EmitSucess
	dartApi.EmitWarning = notificationApi.EmitWarning
	dartApi.EmitDanger = notificationApi.EmitDanger
	dartApi.EmitError = notificationApi.EmitError

	trackCleanup(function()
		if scope.Dart == dartApi then
			if dartApi.Notifications == notificationApi then
				dartApi.Notifications = nil
			end
			if dartApi.EmitInfo == notificationApi.EmitInfo then
				dartApi.EmitInfo = nil
			end
			if dartApi.EmitSuccess == notificationApi.EmitSuccess then
				dartApi.EmitSuccess = nil
			end
			if dartApi.EmitSucess == notificationApi.EmitSucess then
				dartApi.EmitSucess = nil
			end
			if dartApi.EmitWarning == notificationApi.EmitWarning then
				dartApi.EmitWarning = nil
			end
			if dartApi.EmitDanger == notificationApi.EmitDanger then
				dartApi.EmitDanger = nil
			end
			if dartApi.EmitError == notificationApi.EmitError then
				dartApi.EmitError = nil
			end
		end
	end)

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

	local function getCurrentCamera()
		return Workspace.CurrentCamera
	end

	local function getPlayerRootPart(player)
		local character = player and player.Character
		if character == nil then
			return nil
		end

		return character:FindFirstChild("HumanoidRootPart")
			or character:FindFirstChild("UpperTorso")
			or character:FindFirstChild("Torso")
			or character.PrimaryPart
	end

	local function getFocusedSpyPlayer()
		if state.selectedPlayerName == "" then
			return nil
		end

		local player = Players:FindFirstChild(state.selectedPlayerName)
		if player == nil or player == Players.LocalPlayer then
			return nil
		end

		return player
	end

	local function getPlayerDistanceText(player)
		local localRoot = getPlayerRootPart(Players.LocalPlayer)
		local targetRoot = getPlayerRootPart(player)
		if localRoot == nil or targetRoot == nil then
			return "-"
		end

		return ("%dm"):format(math.floor((localRoot.Position - targetRoot.Position).Magnitude + 0.5))
	end

	local function getPlayerTeamText(player)
		if player == nil then
			return "-"
		end

		if player.Team ~= nil then
			return player.Team.Name
		end

		return tostring(player.TeamColor)
	end

	local function getPlayerHealthText(player)
		local character = player and player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return "-"
		end

		return ("%d/%d"):format(math.floor(humanoid.Health + 0.5), math.floor(humanoid.MaxHealth + 0.5))
	end

	local function anyEspSignalEnabled()
		if state.highlightAllPlayers then
			return true
		end

		for _, enabled in pairs(state.espObjectToggles) do
			if enabled then
				return true
			end
		end

		for _ in pairs(state.highlightedPlayers) do
			return true
		end

		return false
	end

	local function setOverlayStroke(frame, color, transparency)
		local stroke = frame and frame:FindFirstChildOfClass("UIStroke")
		if stroke ~= nil then
			stroke.Color = color
			stroke.Transparency = transparency or stroke.Transparency
		end
	end

	local function getLevelColor(level)
		if level == "critical" then
			return NativeUi.Theme.Critical
		elseif level == "warning" then
			return NativeUi.Theme.Warning
		elseif level == "success" then
			return NativeUi.Theme.Success
		elseif level == "info" then
			return NativeUi.Theme.Info
		end

		return NativeUi.Theme.TextDim
	end

	local function setHudChip(chip, title, detail, level)
		local color = getLevelColor(level)
		chip.title.Text = title
		chip.detail.Text = detail
		chip.dot.BackgroundColor3 = color
		setOverlayStroke(chip.frame, color, level == "neutral" and 0.32 or 0.08)
	end

	local function buildSuiteTelemetry()
		local focusedPlayer = getFocusedSpyPlayer()
		local activeEsp = anyEspSignalEnabled()
		local signal = {
			title = "Assist",
			detail = "Movement and utility ready",
			badge = "READY",
			level = "success",
			width = 220,
			height = 52,
		}

		if state.activeTab == "esp" then
			signal.title = "Visibility"
			signal.detail = activeEsp and "ESP filters active" or "Fast scan tools idle"
			signal.badge = activeEsp and "WATCH" or "IDLE"
			signal.level = activeEsp and "warning" or "info"
			signal.width = 292
		elseif state.activeTab == "spy" then
			signal.title = focusedPlayer and "Recon" or "Spy"
			signal.detail = focusedPlayer and (focusedPlayer.Name .. " focus") or "Select one target"
			signal.badge = focusedPlayer and "LIVE" or "IDLE"
			signal.level = focusedPlayer and "warning" or "info"
			signal.width = focusedPlayer and 326 or 242
		elseif state.activeTab == "guns" then
			signal.title = "Combat"
			signal.detail = state.aimbotEnabled and "Ctrl lock armed" or "Scoped settings idle"
			signal.badge = state.aimbotEnabled and "ARMED" or "SAFE"
			signal.level = state.aimbotEnabled and "warning" or "info"
			signal.width = 300
		elseif state.activeTab == "build" then
			signal.title = "Build"
			signal.detail = "Placement utilities staged"
			signal.badge = "ROUTE"
			signal.level = "info"
			signal.width = 280
		elseif state.activeTab == "remote" then
			signal.title = "Remote"
			signal.detail = state.remoteWatcherEnabled and "Remote watcher active" or "Remote watcher idle"
			signal.badge = state.remoteWatcherEnabled and "WATCH" or "IDLE"
			signal.level = state.remoteWatcherEnabled and "warning" or "info"
			signal.width = 306
		elseif state.activeTab == "bytecode" then
			signal.title = "Code"
			signal.detail = state.lastResult and "Decompiler output loaded" or "Script inspection ready"
			signal.badge = state.lastResult and "LOADED" or "READY"
			signal.level = state.lastResult and "success" or "info"
			signal.width = 318
		end

		if state.isMinimized then
			signal.title = "Dart"
			signal.detail = "Suite minimized"
			signal.badge = "LIVE"
			signal.level = "info"
			signal.width = 244
		end

		local detailLength = #tostring(signal.detail or "")
		if detailLength > 46 then
			signal.height = 72
			signal.width = math.max(signal.width, 380)
		elseif detailLength > 30 then
			signal.height = 62
			signal.width = math.max(signal.width, 320)
		end

		return signal
	end

	local function buildAlertStack(signal)
		pruneNotifications()
		table.sort(state.notifications, function(left, right)
			local leftSticky = left.expiresAt == nil and 1 or 0
			local rightSticky = right.expiresAt == nil and 1 or 0
			if leftSticky ~= rightSticky then
				return leftSticky > rightSticky
			end
			if left.priority ~= right.priority then
				return left.priority > right.priority
			end
			return left.createdAt > right.createdAt
		end)

		local alerts = {}
		for _, notification in ipairs(state.notifications) do
			table.insert(alerts, notification)
			if #alerts >= 3 then
				return alerts
			end
		end
		if #alerts > 0 then
			return alerts
		end

		return {
			{
				level = signal.level,
				title = signal.title .. " signal",
				detail = signal.detail,
			},
			{
				level = state.aimbotEnabled and "warning" or "info",
				title = state.aimbotEnabled and "Combat armed" or "Combat idle",
				detail = state.aimbotEnabled and "Ctrl lock can acquire targets" or "Aimbot disabled",
			},
			{
				level = anyEspSignalEnabled() and "warning" or "info",
				title = anyEspSignalEnabled() and "ESP active" or "ESP quiet",
				detail = state.highlightAllPlayers and "All players highlighted" or "Selective visibility only",
			},
		}
	end

	local function updateSpyReadout()
		local player = getFocusedSpyPlayer()
		if player == nil then
			refs.spyThreatPill.Text = "IDLE"
			refs.spyThreatPill.TextColor3 = NativeUi.Theme.TextDim
			refs.spyFigure.BackgroundColor3 = NativeUi.Theme.Surface
			refs.spyTargetNameLabel.Text = "No focus target"
			refs.spyTargetDetailLabel.Text = "Select a member from the left panel."
			refs.spyMetricDistanceLabel.Text = "Distance: -"
			refs.spyMetricTeamLabel.Text = "Team: -"
			refs.spyMetricHealthLabel.Text = "Health: -"
			refs.spyMetricStateLabel.Text = "State: waiting"
			refs.spySituationSummary.Text = "No focus target selected. Pin a player to promote them into the intelligence capsule and alert rail."
			NativeUi.setButtonDisabled(refs.spyPinButton, true)
			NativeUi.setButtonDisabled(refs.spyHighlightButton, true)
			return
		end

		local teamColor = player.TeamColor and player.TeamColor.Color or NativeUi.Theme.Warning
		refs.spyThreatPill.Text = "FOCUSED"
		refs.spyThreatPill.TextColor3 = NativeUi.Theme.Warning
		refs.spyFigure.BackgroundColor3 = teamColor
		refs.spyTargetNameLabel.Text = player.DisplayName ~= player.Name and (player.DisplayName .. " @" .. player.Name) or player.Name
		refs.spyTargetDetailLabel.Text = ("%s team read"):format(getPlayerTeamText(player))
		refs.spyMetricDistanceLabel.Text = "Distance: " .. getPlayerDistanceText(player)
		refs.spyMetricTeamLabel.Text = "Team: " .. getPlayerTeamText(player)
		refs.spyMetricHealthLabel.Text = "Health: " .. getPlayerHealthText(player)
		refs.spyMetricStateLabel.Text = player.Character == nil and "State: no character" or "State: visible"
		refs.spySituationSummary.Text = ("%s is pinned for focused recon. Use ESP for broad visibility; keep Spy on one target."):format(player.Name)
		NativeUi.setButtonDisabled(refs.spyPinButton, false)
		NativeUi.setButtonDisabled(refs.spyHighlightButton, false)
	end

	updateSuiteOverlays = function()
		local signal = buildSuiteTelemetry()
		local color = getLevelColor(signal.level)
		local islandHeight = signal.height or 52

		refs.dynamicIslandTitle.Text = signal.title
		refs.dynamicIslandDetail.Text = signal.detail
		refs.dynamicIslandBadge.Text = signal.badge
		refs.dynamicIslandDot.BackgroundColor3 = color
		refs.dynamicIslandDot.Position = UDim2.fromOffset(28, math.floor(islandHeight / 2))
		refs.dynamicIslandDetail.Size = UDim2.new(1, -92, 0, math.max(18, islandHeight - 36))
		refs.dynamicIslandBadge.Position = UDim2.new(1, -68, 0, math.floor((islandHeight - 18) / 2))
		setOverlayStroke(refs.dynamicIsland, color, signal.level == "info" and 0.18 or 0.04)
		SuiteMotion.tween(refs.dynamicIsland, {
			Size = UDim2.fromOffset(signal.width, islandHeight),
		}, {
			duration = 0.18,
			style = "quint",
		})

		local alerts = buildAlertStack(signal)

		for index, card in ipairs(refs.alertCards) do
			local alert = alerts[index]
			card.frame.Visible = alert ~= nil
			if alert ~= nil then
				local alertColor = getLevelColor(alert.level)
				card.level.Text = string.upper(alert.level)
				card.level.TextColor3 = alertColor
				card.title.Text = alert.title
				card.detail.Text = alert.detail
				setOverlayStroke(card.frame, alertColor, alert.level == "info" and 0.26 or 0.08)
			end
		end
	end

	local function shouldSkipAimbotPlayer(player)
		if player == nil or player == Players.LocalPlayer then
			return true
		end

		local localPlayer = Players.LocalPlayer
		if localPlayer ~= nil and localPlayer.Team ~= nil and player.Team ~= nil and player.Team == localPlayer.Team then
			return true
		end

		local character = player.Character
		if character == nil then
			return true
		end

		local humanoid = character:FindFirstChildOfClass("Humanoid")
		return humanoid == nil or humanoid.Health <= 0
	end

	local function appendAimPart(candidates, seen, part)
		if part == nil or not part:IsA("BasePart") or seen[part] then
			return
		end

		seen[part] = true
		table.insert(candidates, part)
	end

	local function getAimCandidatesForCharacter(character, mode)
		local candidates = {}
		local seen = {}

		local function addByNames(names)
			for _, name in ipairs(names) do
				appendAimPart(candidates, seen, character:FindFirstChild(name, true))
			end
		end

		if mode == "head" then
			addByNames({ "Head" })
		elseif mode == "torso" then
			addByNames({ "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart" })
		elseif mode == "arms" then
			addByNames({ "LeftHand", "RightHand", "LeftLowerArm", "RightLowerArm", "LeftUpperArm", "RightUpperArm", "Left Arm", "Right Arm" })
		elseif mode == "legs" then
			addByNames({ "LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg", "LeftUpperLeg", "RightUpperLeg", "Left Leg", "Right Leg" })
		elseif mode == "limbs" then
			addByNames({
				"LeftHand", "RightHand", "LeftLowerArm", "RightLowerArm", "LeftUpperArm", "RightUpperArm", "Left Arm", "Right Arm",
				"LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg", "LeftUpperLeg", "RightUpperLeg", "Left Leg", "Right Leg",
			})
		else
			addByNames({
				"Head", "UpperTorso", "Torso", "LowerTorso", "HumanoidRootPart",
				"LeftHand", "RightHand", "LeftLowerArm", "RightLowerArm", "LeftUpperArm", "RightUpperArm", "Left Arm", "Right Arm",
				"LeftFoot", "RightFoot", "LeftLowerLeg", "RightLowerLeg", "LeftUpperLeg", "RightUpperLeg", "Left Leg", "Right Leg",
			})
		end

		if #candidates == 0 then
			appendAimPart(candidates, seen, character:FindFirstChild("HumanoidRootPart"))
		end
		return candidates
	end

	local function getAimGuiInset()
		local ok, topLeftInset = pcall(function()
			return GuiService:GetGuiInset()
		end)
		if ok and typeof(topLeftInset) == "Vector2" then
			return topLeftInset
		end
		return Vector2.new(0, 0)
	end

	local function getAimWorldPoint(part)
		if part == nil then
			return nil
		end

		return part.Position
	end

	local function getScreenPointForPart(part)
		local camera = getCurrentCamera()
		if camera == nil or part == nil then
			return nil
		end

		local aimPoint = getAimWorldPoint(part)
		if aimPoint == nil then
			return nil
		end

		local screenPoint, onScreen = camera:WorldToViewportPoint(aimPoint)
		if not onScreen or screenPoint.Z <= 0 then
			return nil
		end

		local inset = getAimGuiInset()
		return Vector2.new(screenPoint.X + inset.X, screenPoint.Y + inset.Y)
	end

	local function getBestAimPartForPlayer(player, mode, mousePosition)
		if getCurrentCamera() == nil or player == nil or player.Character == nil then
			return nil, math.huge, nil
		end

		local bestPart
		local bestDistance = math.huge
		local bestScreenPosition

		for _, part in ipairs(getAimCandidatesForCharacter(player.Character, mode)) do
			local screenPosition = getScreenPointForPart(part)
			if screenPosition ~= nil then
				local distance = (screenPosition - mousePosition).Magnitude
				if distance < bestDistance then
					bestDistance = distance
					bestPart = part
					bestScreenPosition = screenPosition
				end
			end
		end

		return bestPart, bestDistance, bestScreenPosition
	end

	local function clearAimbotLock()
		state.aimLockedPlayerName = ""
		state.aimLockedPartName = ""
	end

	local function acquireAimbotTarget()
		local camera = getCurrentCamera()
		if camera == nil then
			clearAimbotLock()
			return nil, nil
		end

		local mousePosition = UserInputService:GetMouseLocation()
		local bestPlayer
		local bestPart
		local bestDistance = math.huge
		local bestScreenPosition

		for _, player in ipairs(Players:GetPlayers()) do
			if not shouldSkipAimbotPlayer(player) then
				local part, distance, screenPosition = getBestAimPartForPlayer(player, state.aimTargetPart, mousePosition)
				if part ~= nil and distance < bestDistance then
					bestDistance = distance
					bestPlayer = player
					bestPart = part
					bestScreenPosition = screenPosition
				end
			end
		end

		if bestPlayer ~= nil and bestPart ~= nil then
			state.aimLockedPlayerName = bestPlayer.Name
			state.aimLockedPartName = bestPart.Name
			return bestPlayer, bestPart, bestScreenPosition
		end

		clearAimbotLock()
		return nil, nil, nil
	end

	local function resolveLockedAimbotTarget()
		if state.aimLockedPlayerName == "" then
			return acquireAimbotTarget()
		end

		local player = Players:FindFirstChild(state.aimLockedPlayerName)
		if shouldSkipAimbotPlayer(player) then
			return acquireAimbotTarget()
		end

		local mousePosition = UserInputService:GetMouseLocation()
		local part, _, screenPosition = getBestAimPartForPlayer(player, state.aimTargetPart, mousePosition)
		if part == nil then
			return acquireAimbotTarget()
		end

		state.aimLockedPartName = part.Name
		return player, part, screenPosition
	end

	local function setAimbotHoldActive(active)
		local nextValue = active == true
		if state.aimHoldActive == nextValue then
			return
		end

		state.aimHoldActive = nextValue
		if nextValue then
			acquireAimbotTarget()
		else
			clearAimbotLock()
		end

		syncControlState()
	end

	local function isAimbotHotkeyDown()
		return UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
	end

	local function roundNumber(value)
		if value >= 0 then
			return math.floor(value + 0.5)
		end

		return math.ceil(value - 0.5)
	end

	local function getMouseMoveFunctions()
		local scope = getGlobalScope()
		return scope.mousemoveabs or scope.mousemoveabsolute, scope.mousemoverel or scope.mousemoverelative
	end

	local function getRelativeMouseMoveFunction()
		local _, moveRel = getMouseMoveFunctions()
		return moveRel
	end

	local function canMoveMouseCursor()
		return type(getRelativeMouseMoveFunction()) == "function"
	end

	local function moveMouseToScreenPosition(screenPosition)
		if screenPosition == nil then
			return false
		end

		local moveRel = getRelativeMouseMoveFunction()
		if type(moveRel) == "function" then
			local mousePosition = UserInputService:GetMouseLocation()
			local delta = screenPosition - mousePosition
			local magnitude = delta.Magnitude

			if magnitude < 1 then
				return true
			end

			if magnitude > MAX_AIM_MOUSE_STEP then
				delta = delta.Unit * MAX_AIM_MOUSE_STEP
			end

			moveRel(
				roundNumber(delta.X),
				roundNumber(delta.Y)
			)
			return true
		end

		return false
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
		NativeUi.setButtonSelected(toggleRow.toggle, enabled)
		if toggleRow.indicator ~= nil then
			NativeUi.tween(toggleRow.indicator, 0.12, {
				BackgroundTransparency = enabled and 0 or 1,
				Size = enabled and UDim2.fromOffset(8, 8) or UDim2.fromOffset(6, 6),
			})
		end
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

	local function setMinimized(minimized)
		if state.isMinimized == minimized then
			return
		end

		if minimized then
			state.restoredSize = Vector2.new(refs.main.AbsoluteSize.X, refs.main.AbsoluteSize.Y)
			refs.main.Size = UDim2.fromOffset(refs.main.AbsoluteSize.X, 70)
		else
			local restoredSize = state.restoredSize or state.windowMinSize
			refs.main.Size = UDim2.fromOffset(restoredSize.X, restoredSize.Y)
		end

		state.isMinimized = minimized
		refs.applyLayout()
	end

	local function collectOutputTextForMode(viewMode)
		if state.lastResult == nil then
			return ""
		end

		if viewMode == "code" then
			return formatCodeView(state.lastResult.chunk, state.showRawOpcodes)
		end

		if viewMode == "decompile" then
			return LuauDecompiler.decompileChunk(state.lastResult.chunk)
		end

		if viewMode == "flow" then
			return LuauControlFlow.formatAnalysis(LuauControlFlow.analyzeChunk(state.lastResult.chunk))
		end

		return formatDataView(state.lastResult.chunk)
	end

	local function collectOutputText()
		local outputText = collectOutputTextForMode(state.viewMode)

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

	local function setOutputLoading(title, detail)
		refs.outputSourceLabel.Text = title or "Loading"
		refs.outputSourceLabel.TextColor3 = NativeUi.Theme.Info
		refs.outputSummaryLabel.Text = detail or "Reading bytecode and preparing output..."
		refs.outputCodeLabel.Text = "Loading...\n\nThe selected script is being decoded. Large scripts can take a moment."
		refs.outputCodeLabel.TextColor3 = NativeUi.Theme.TextMuted
		refs.chunkSummaryLabel.Text = "Loading"
		setStatus(title or "Loading", NativeUi.Theme.Info)
		refs.syncOutputCanvas()
	end

	local function copyOutputMode(viewMode, label)
		if state.lastResult == nil then
			setStatus("Nothing loaded to copy", NativeUi.Theme.Error)
			return
		end

		local ok, outputText = pcall(function()
			return collectOutputTextForMode(viewMode)
		end)

		if not ok then
			setStatus(("Copy failed: %s"):format(tostring(outputText)), NativeUi.Theme.Error)
			return
		end

		if outputText == "" then
			setStatus(("No %s output to copy"):format(label), NativeUi.Theme.Error)
			return
		end

		local copied, copyError = writeClipboard(outputText)
		if copied then
			setStatus(("Copied %s"):format(label), NativeUi.Theme.Success)
		else
			setStatus(tostring(copyError), NativeUi.Theme.Error)
		end
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

		local ok, outputText = pcall(collectOutputText)
		if not ok then
			outputText = ("Decompiler/view error:\n%s"):format(tostring(outputText))
			refs.outputCodeLabel.TextColor3 = NativeUi.Theme.Error
			refs.outputCodeLabel.Text = withLineNumbers(outputText)
			refs.outputSummaryLabel.Text = "The selected view failed. Switch to Code view for raw opcode output."
			refs.chunkSummaryLabel.Text = "View failed"
			setStatus("View error", NativeUi.Theme.Error)
			refs.syncOutputCanvas()
			return
		end

		if outputText == "" then
			outputText = "No lines match the current filter."
			refs.outputCodeLabel.TextColor3 = NativeUi.Theme.TextMuted
		else
			refs.outputCodeLabel.TextColor3 = NativeUi.Theme.Text
		end

		refs.outputCodeLabel.Text = withLineNumbers(outputText)
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

	local renderTreeView
	local scriptBrowserRefreshQueued = false

	local function refreshScriptBrowser(forceNilScan)
		state.scriptBrowserTree = buildScriptBrowserTree(forceNilScan == true)
		state.scriptBrowserError = nil
	end

	local function scheduleScriptBrowserRefresh()
		if scriptBrowserRefreshQueued or cleaning then
			return
		end

		scriptBrowserRefreshQueued = true
		task.delay(0.18, function()
			scriptBrowserRefreshQueued = false
			if cleaning or refs.main == nil or refs.main.Parent == nil then
				return
			end

			refreshScriptBrowser(false)
			if renderTreeView ~= nil then
				renderTreeView()
			end
		end)
	end

	local function handleScriptBrowserAdded(instance)
		if typeof(instance) == "Instance" and isScriptLike(instance) then
			if instance:IsDescendantOf(Workspace) then
				dynamicWorkspaceScripts[instance] = true
			end

			scheduleScriptBrowserRefresh()
		end
	end

	local function handleScriptBrowserRemoving(instance)
		if typeof(instance) == "Instance" and isScriptLike(instance) then
			dynamicWorkspaceScripts[instance] = nil
			scheduleScriptBrowserRefresh()
		end
	end

	local function connectScriptBrowserRoot(root, watchedRoots)
		if typeof(root) ~= "Instance" or watchedRoots[root] then
			return
		end

		for watchedRoot in pairs(watchedRoots) do
			if root:IsDescendantOf(watchedRoot) then
				return
			end
		end

		watchedRoots[root] = true
		trackConnection(root.DescendantAdded:Connect(handleScriptBrowserAdded))
		trackConnection(root.DescendantRemoving:Connect(handleScriptBrowserRemoving))
	end

	local function bindScriptBrowserMutationWatchers()
		local watchedRoots = {}
		for _, root in ipairs(collectScriptBrowserRoots()) do
			connectScriptBrowserRoot(root, watchedRoots)
		end

		trackConnection(Workspace.DescendantAdded:Connect(handleScriptBrowserAdded))
		trackConnection(Workspace.DescendantRemoving:Connect(handleScriptBrowserRemoving))
	end

	local renderRemoteList
	local renderRemoteLog
	local connectRemoteEvent
	local remoteEventConnections = {}
	local remoteHookBridge = scope.__DartRemoteHookBridge
	if type(remoteHookBridge) ~= "table" then
		remoteHookBridge = {}
		scope.__DartRemoteHookBridge = remoteHookBridge
	end

	local function getSelectedRemote()
		if state.selectedRemotePath == nil then
			return nil
		end

		for _, remote in ipairs(state.remoteList) do
			if getRemotePath(remote) == state.selectedRemotePath then
				return remote
			end
		end

		return nil
	end

	local function remoteLogMatches(entry, remotePath, remote)
		return entry ~= nil and (entry.remote == remote or entry.remotePath == remotePath)
	end

	local function getRemoteLogStats(remotePath, remote)
		local count = 0
		local lastEntry = nil
		for _, entry in ipairs(state.remoteLogs) do
			if remoteLogMatches(entry, remotePath, remote) then
				count = count + 1
				lastEntry = lastEntry or entry
			end
		end
		return count, lastEntry
	end

	local function ensureRemoteTracked(remote)
		if not isRemoteLike(remote) then
			return false
		end

		for _, existing in ipairs(state.remoteList) do
			if existing == remote then
				return false
			end
		end

		table.insert(state.remoteList, remote)
		table.sort(state.remoteList, function(left, right)
			return string.lower(getRemotePath(left)) < string.lower(getRemotePath(right))
		end)
		if connectRemoteEvent ~= nil then
			connectRemoteEvent(remote)
		end
		return true
	end

	local function appendRemoteLog(direction, remote, method, args)
		args = args or {}
		local path = getRemotePath(remote)
		local listChanged = ensureRemoteTracked(remote)
		local selectionChanged = false
		if state.selectedRemotePath == nil then
			state.selectedRemotePath = path
			selectionChanged = true
		end

		local entry = {
			remote = remote,
			direction = direction or "?",
			remotePath = path,
			className = typeof(remote) == "Instance" and remote.ClassName or "?",
			method = tostring(method or "?"),
			argCount = getPackedArgCount(args),
			argsText = formatRemoteArgs(args),
			argsLines = formatRemoteArgLines(args),
			timestamp = os.date("%H:%M:%S"),
		}

		table.insert(state.remoteLogs, 1, entry)
		while #state.remoteLogs > 180 do
			table.remove(state.remoteLogs)
		end

		if renderRemoteList ~= nil and (listChanged or selectionChanged) then
			renderRemoteList()
		end
		if renderRemoteLog ~= nil then
			renderRemoteLog()
		end
	end

	local function installDirectRemoteMethodHooks(makeHookClosure)
		if remoteHookBridge.directHooksInstalled then
			return true
		end

		if type(hookfunction) ~= "function" then
			return false
		end

		local installedAny = false
		remoteHookBridge.directHooks = remoteHookBridge.directHooks or {}

		local function hookClassMethod(className, methodName)
			if remoteHookBridge.directHooks[className .. "." .. methodName] ~= nil then
				return true
			end

			local okCreate, sample = pcall(function()
				return Instance.new(className)
			end)
			if not okCreate or sample == nil then
				return false
			end

			local originalMethod = sample[methodName]
			sample:Destroy()
			if type(originalMethod) ~= "function" then
				return false
			end

			local hookedOriginal
			local okHook = pcall(function()
				hookedOriginal = hookfunction(originalMethod, makeHookClosure(function(self, ...)
					local bridge = getGlobalScope().__DartRemoteHookBridge
					if bridge ~= nil and bridge.enabled == true and type(bridge.callback) == "function" and isRemoteLike(self) then
						bridge.callback(self, methodName, packRemoteArgs(...))
					end
					return hookedOriginal(self, ...)
				end))
			end)

			if okHook then
				remoteHookBridge.directHooks[className .. "." .. methodName] = hookedOriginal
				installedAny = true
				return true
			end

			return false
		end

		hookClassMethod("RemoteEvent", "FireServer")
		hookClassMethod("UnreliableRemoteEvent", "FireServer")
		hookClassMethod("RemoteFunction", "InvokeServer")
		remoteHookBridge.directHooksInstalled = installedAny
		return installedAny
	end

	remoteHookBridge.callback = function(remote, method, args)
		if state.remoteWatcherEnabled then
			appendRemoteLog("OUT", remote, method, args)
		end
	end
	remoteHookBridge.enabled = state.remoteWatcherEnabled
	trackCleanup(function()
		if scope.__DartRemoteHookBridge == remoteHookBridge then
			remoteHookBridge.callback = nil
			remoteHookBridge.enabled = false
		end
	end)

	local function scanRemoteList()
		state.remoteList = buildRemoteBrowserList()
		for _, remote in ipairs(state.remoteList) do
			if remoteEventConnections[remote] == nil then
				connectRemoteEvent(remote)
			end
		end
		if renderRemoteList ~= nil then
			renderRemoteList()
		end
	end

	local function installRemoteNamecallWatcher()
		if state.remoteHookInstalled then
			remoteHookBridge.enabled = true
			return true
		end

		if type(getnamecallmethod) ~= "function" then
			state.remoteHookError = "Namecall method API unavailable; server-to-client events can still be observed."
			return false
		end

		local makeHookClosure = type(newcclosure) == "function" and newcclosure or function(fn)
			return fn
		end

		local directHookInstalled = installDirectRemoteMethodHooks(makeHookClosure)

		if type(hookmetamethod) == "function" then
			if remoteHookBridge.namecallInstalled then
				state.remoteHookInstalled = true
				state.remoteHookError = nil
				remoteHookBridge.enabled = true
				return true
			end

			local originalNamecall
			local ok, err = pcall(function()
				originalNamecall = hookmetamethod(game, "__namecall", makeHookClosure(function(self, ...)
					local method = getnamecallmethod()
					local bridge = getGlobalScope().__DartRemoteHookBridge
					if bridge ~= nil and bridge.enabled == true and type(bridge.callback) == "function" and isRemoteLike(self) and (method == "FireServer" or method == "InvokeServer") then
						bridge.callback(self, method, packRemoteArgs(...))
					end
					return originalNamecall(self, ...)
				end))
			end)

			if ok then
				remoteHookBridge.namecallInstalled = true
				remoteHookBridge.originalNamecall = originalNamecall
				remoteHookBridge.enabled = true
				state.remoteHookInstalled = true
				state.remoteHookError = nil
				return true
			end

			state.remoteHookError = "hookmetamethod failed: " .. tostring(err)
		end

		if type(getrawmetatable) ~= "function" or type(setreadonly) ~= "function" then
			if directHookInstalled then
				state.remoteHookInstalled = true
				state.remoteHookError = nil
				remoteHookBridge.enabled = true
				return true
			end
			state.remoteHookError = state.remoteHookError or "Namecall/direct hook APIs unavailable; server-to-client events can still be observed."
			return false
		end

		local metatable = getrawmetatable(game)
		local originalNamecall = metatable.__namecall
		local ok, err = pcall(function()
			setreadonly(metatable, false)
			metatable.__namecall = makeHookClosure(function(self, ...)
				local method = getnamecallmethod()
				if state.remoteWatcherEnabled and isRemoteLike(self) and (method == "FireServer" or method == "InvokeServer") then
					appendRemoteLog("OUT", self, method, packRemoteArgs(...))
				end
				return originalNamecall(self, ...)
			end)
			setreadonly(metatable, true)
		end)

		if not ok then
			state.remoteHookError = "Namecall hook failed: " .. tostring(err)
			pcall(function()
				setreadonly(metatable, true)
			end)
			return false
		end

		state.remoteHookInstalled = true
		state.remoteHookError = nil
		trackCleanup(function()
			pcall(function()
				setreadonly(metatable, false)
				metatable.__namecall = originalNamecall
				setreadonly(metatable, true)
			end)
		end)
		return true
	end

	connectRemoteEvent = function(remote)
		if not remote:IsA("RemoteEvent") and remote.ClassName ~= "UnreliableRemoteEvent" then
			return
		end

		if remoteEventConnections[remote] ~= nil then
			return
		end

		remoteEventConnections[remote] = trackConnection(remote.OnClientEvent:Connect(function(...)
			if state.remoteWatcherEnabled then
				appendRemoteLog("IN", remote, "OnClientEvent", packRemoteArgs(...))
			end
		end))
	end

	local function appendRemoteEntryLines(lines, entry)
		local preview = entry.argsText ~= "" and entry.argsText or "<no args>"
		table.insert(lines, ("[%s] %s  %s"):format(entry.timestamp, entry.direction, entry.method))
		table.insert(lines, ("  Class   : %s"):format(entry.className))
		table.insert(lines, ("  Path    : %s"):format(entry.remotePath))
		table.insert(lines, ("  Args    : %d"):format(entry.argCount))
		table.insert(lines, ("  Payload : %s"):format(preview))
		table.insert(lines, entry.argsLines)
		table.insert(lines, "")
	end

	renderRemoteLog = function()
		local selectedPath = state.selectedRemotePath
		local selectedRemote = getSelectedRemote()
		local status = state.remoteWatcherEnabled and "Watcher active" or "Watcher idle"
		if state.remoteHookError ~= nil then
			status = state.remoteHookError
		end

		if selectedPath == nil then
			local lines = {
				"REMOTE INSPECTOR",
				"",
				"Select a remote from the left to inspect class, path, methods, and payloads.",
				("Watcher: %s"):format(status),
				("Captured entries: %d"):format(#state.remoteLogs),
			}
			if #state.remoteLogs > 0 then
				table.insert(lines, "")
				table.insert(lines, "RECENT TRAFFIC")
				for index = 1, math.min(12, #state.remoteLogs) do
					appendRemoteEntryLines(lines, state.remoteLogs[index])
				end
			end

			refs.remoteLogLabel.Text = withLineNumbers(table.concat(lines, "\n"))
			refs.remoteLogStatusLabel.Text = status
			refs.remoteInspectorTitleLabel.Text = "No remote selected"
			refs.remoteInspectorMetaLabel.Text = ("Class: -    Calls: 0    Captured: %d    Last: -"):format(#state.remoteLogs)
			refs.syncRemoteLogCanvas()
			return
		end

		local count, lastEntry = getRemoteLogStats(selectedPath, selectedRemote)
		local className = selectedRemote and selectedRemote.ClassName or "Missing"
		local lines = {
			"REMOTE",
			("Name: %s"):format(selectedRemote and selectedRemote.Name or "<missing>"),
			("Watcher: %s"):format(status),
			("Class: %s"):format(className),
			("Path: %s"):format(selectedPath),
			("Observed calls: %d"):format(count),
			"",
			"RECENT PAYLOADS",
		}

		if count == 0 then
			table.insert(lines, "No traffic captured for this remote yet.")
		else
			local added = 0
			for _, entry in ipairs(state.remoteLogs) do
				if remoteLogMatches(entry, selectedPath, selectedRemote) then
					added = added + 1
					appendRemoteEntryLines(lines, entry)
					if added >= 40 then
						table.insert(lines, "...older calls hidden")
						break
					end
				end
			end
		end

		refs.remoteLogLabel.Text = withLineNumbers(table.concat(lines, "\n"))
		refs.remoteLogStatusLabel.Text = ("Focused: %s"):format(selectedRemote and selectedRemote.Name or selectedPath)
		refs.remoteInspectorTitleLabel.Text = selectedRemote and selectedRemote.Name or selectedPath
		refs.remoteInspectorMetaLabel.Text = ("Class: %s    Calls: %d    Last: %s\nPath: %s"):format(
			className,
			count,
			lastEntry and (lastEntry.timestamp .. " " .. lastEntry.direction .. " " .. lastEntry.method) or "-",
			selectedPath
		)
		refs.syncRemoteLogCanvas()
	end

	renderRemoteList = function()
		NativeUi.clear(refs.remoteListContent)
		local shown = 0
		local filterText = state.remoteFilterText

		for _, remote in ipairs(state.remoteList) do
			local path = getRemotePath(remote)
			if filterText == "" or containsFilter(path, filterText) or containsFilter(remote.ClassName, filterText) then
				shown = shown + 1
				local button = NativeUi.makeButton(refs.remoteListContent, ("%s %s  [%s]"):format(UI_ICON.remote, path, remote.ClassName), {
					Font = Enum.Font.Code,
					Size = UDim2.new(1, 0, 0, 26),
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
				})
				NativeUi.setButtonSelected(button, state.selectedRemotePath == path)
				button.MouseButton1Click:Connect(function()
					state.selectedRemotePath = path
					renderRemoteList()
					renderRemoteLog()
					syncControlState()
				end)
			end
		end

		refs.remoteCountLabel.Text = ("Remotes: %d visible / %d total"):format(shown, #state.remoteList)
		if shown == 0 then
			NativeUi.makeLabel(refs.remoteListContent, "No remotes match the current filter.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
		end
	end

	local function addRemoteToList(remote)
		if not isRemoteLike(remote) then
			return
		end

		for _, existing in ipairs(state.remoteList) do
			if existing == remote then
				return
			end
		end

		table.insert(state.remoteList, remote)
		table.sort(state.remoteList, function(left, right)
			return string.lower(getRemotePath(left)) < string.lower(getRemotePath(right))
		end)
		connectRemoteEvent(remote)
		renderRemoteList()
	end

	local function bindRemoteMutationWatchers()
		local watchedRoots = {}
		for _, root in ipairs(collectRemoteBrowserRoots()) do
			if typeof(root) == "Instance" and not watchedRoots[root] then
				watchedRoots[root] = true
				trackConnection(root.DescendantAdded:Connect(addRemoteToList))
			end
		end
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
			state.selectedScriptPath = path
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

	local loadRequestId = 0

	local function queueLoadCurrentTarget()
		loadRequestId = loadRequestId + 1
		local requestId = loadRequestId
		local targetText = state.sourceMode == "script" and trimText(state.scriptPath) or trimText(state.filePath)

		setOutputLoading("Loading target", targetText ~= "" and targetText or "No target selected yet.")

		task.delay(0.03, function()
			if cleaning or refs.main == nil or refs.main.Parent == nil or requestId ~= loadRequestId then
				return
			end

			local ok, err = pcall(loadCurrentTarget)
			if not ok and requestId == loadRequestId then
				state.lastResult = nil
				state.lastError = tostring(err)
				renderOutputView()
			end

			if requestId == loadRequestId then
				syncControlState()
				if renderTreeView ~= nil then
					renderTreeView()
				end
			end
		end)
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

	local iridiumSlider = bindSlider(refs.iridiumSlider, 0, 1, state.iridiumMinFullness, 0.05, function(value)
		return string.format("%.2f", value)
	end, function(value)
		state.iridiumMinFullness = value
	end)

	local wellDistanceSlider = bindSlider(refs.wellDistanceSlider, 50, 2000, state.wellDistance, 25, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.wellDistance = value
	end)

	local refreshPlayersList
	local refreshEspPlayersList
	local highlightInstances = {}
	local playerCharacterConnections = {}
	local playerTeamConnections = {}
	local reconcileObjectHighlights
	local distanceRefreshAccumulator = 0
	local lastDistanceRefreshPosition = nil
	local objectRefreshQueued = false
	local espObjectCache = {
		named = {
			spawnPoint = {
				targetName = "Spawn Point",
				rootGetter = function()
					return Workspace
				end,
				carriers = {},
				dirty = true,
			},
			wellPump = {
				targetName = "Well Pump",
				rootGetter = function()
					return Workspace
				end,
				carriers = {},
				dirty = true,
			},
			spireWell = {
				targetName = "SpireOpenLarge1",
				rootGetter = function()
					return Workspace:FindFirstChild("Map")
				end,
				carriers = {},
				dirty = true,
			},
			well = {
				targetName = "Top1",
				rootGetter = function()
					return Workspace:FindFirstChild("Map")
				end,
				carriers = {},
				dirty = true,
			},
		},
		iridium = {
			entries = {},
			dirty = true,
			attributeConnections = {},
		},
	}

	local function getHighlightCarrier(instance)
		if typeof(instance) ~= "Instance" then
			return nil
		end

		if instance:IsA("Model") or instance:IsA("BasePart") then
			return instance
		end

		return instance:FindFirstAncestorWhichIsA("Model") or instance:FindFirstAncestorWhichIsA("BasePart")
	end

	local function getInstancePosition(instance)
		if typeof(instance) ~= "Instance" then
			return nil
		end

		if instance:IsA("BasePart") then
			return instance.Position
		end

		if instance:IsA("Model") then
			if instance.PrimaryPart then
				return instance.PrimaryPart.Position
			end

			local ok, pivot = pcall(function()
				return instance:GetPivot()
			end)

			if ok and pivot then
				return pivot.Position
			end

			local part = instance:FindFirstChildWhichIsA("BasePart", true)
			return part and part.Position or nil
		end

		local carrier = getHighlightCarrier(instance)
		if carrier ~= nil and carrier ~= instance then
			return getInstancePosition(carrier)
		end

		return nil
	end

	local function getLocalRootPosition()
		local character = getLocalCharacter()
		if character == nil then
			return nil
		end

		local rootPart = character:FindFirstChild("HumanoidRootPart")
		if rootPart and rootPart:IsA("BasePart") then
			return rootPart.Position
		end

		return getInstancePosition(character)
	end

	local function getInstanceKey(instance)
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

	local function disconnectConnectionMap(connectionMap)
		for key, connection in pairs(connectionMap) do
			pcall(function()
				connection:Disconnect()
			end)
			connectionMap[key] = nil
		end
	end

	local function anyObjectEspEnabled()
		for _, enabled in pairs(state.espObjectToggles) do
			if enabled then
				return true
			end
		end

		return false
	end

	local function removeHighlight(key)
		local highlight = highlightInstances[key]
		if highlight ~= nil then
			highlightInstances[key] = nil
			pcall(function()
				highlight:Destroy()
			end)
		end
	end

	local function ensureHighlight(key, target, fillColor, outlineColor)
		local carrier = getHighlightCarrier(target)
		if carrier == nil or carrier.Parent == nil then
			removeHighlight(key)
			return
		end

		local highlight = highlightInstances[key]
		if highlight == nil or highlight.Parent ~= carrier then
			removeHighlight(key)
			highlight = Instance.new("Highlight")
			highlight.Name = "DartEspHighlight"
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.FillTransparency = state.highlightFillTransparency
			highlight.OutlineTransparency = 0
			highlight.Parent = carrier
			highlight.Adornee = carrier
			highlightInstances[key] = highlight
		end

		highlight.FillColor = fillColor
		highlight.OutlineColor = outlineColor or fillColor
		highlight.Enabled = true
	end

	local function scheduleObjectReconcile()
		if reconcileObjectHighlights == nil or objectRefreshQueued or cleaning or not anyObjectEspEnabled() then
			return
		end

		objectRefreshQueued = true
		task.defer(function()
			objectRefreshQueued = false
			if cleaning or refs.main == nil or refs.main.Parent == nil then
				return
			end

			reconcileObjectHighlights()
		end)
	end

	local function reconcileDesiredHighlights(prefix, desired)
		for key, spec in pairs(desired) do
			ensureHighlight(key, spec.target, spec.fillColor, spec.outlineColor)
		end

		local toRemove = {}
		for key in pairs(highlightInstances) do
			if string.sub(key, 1, #prefix) == prefix and desired[key] == nil then
				table.insert(toRemove, key)
			end
		end

		for _, key in ipairs(toRemove) do
			removeHighlight(key)
		end
	end

	local function scanNamedTargets(root, targetName)
		local targets = {}
		if typeof(root) ~= "Instance" then
			return targets
		end

		local seen = {}
		for _, descendant in ipairs(root:GetDescendants()) do
			if descendant.Name == targetName then
				local carrier = getHighlightCarrier(descendant)
				if carrier ~= nil and not seen[carrier] then
					seen[carrier] = true
					table.insert(targets, carrier)
				end
			end
		end

		return targets
	end

	local function markNamedTargetDirty(cacheKey, refreshNow)
		local entry = espObjectCache.named[cacheKey]
		if entry == nil then
			return
		end

		entry.dirty = true
		if refreshNow then
			scheduleObjectReconcile()
		end
	end

	local function markIridiumDirty(refreshNow)
		espObjectCache.iridium.dirty = true
		if refreshNow then
			scheduleObjectReconcile()
		end
	end

	local function getNamedTargets(cacheKey)
		local entry = espObjectCache.named[cacheKey]
		if entry == nil then
			return {}
		end

		if entry.dirty then
			entry.carriers = scanNamedTargets(entry.rootGetter(), entry.targetName)
			entry.dirty = false
		end

		return entry.carriers
	end

	local function bindIridiumAttribute(descendant)
		if espObjectCache.iridium.attributeConnections[descendant] ~= nil then
			return
		end

		local ok, signal = pcall(function()
			return descendant:GetAttributeChangedSignal("CrystalFullness")
		end)

		if ok and signal ~= nil then
			espObjectCache.iridium.attributeConnections[descendant] = signal:Connect(function()
				markIridiumDirty(state.espObjectToggles.iridium)
			end)
		end
	end

	local function collectIridiumTargets()
		if espObjectCache.iridium.dirty then
			disconnectConnectionMap(espObjectCache.iridium.attributeConnections)

			local grouped = {}
			local resources = Workspace:FindFirstChild("Resources")
			if resources ~= nil then
				for _, descendant in ipairs(resources:GetDescendants()) do
					local fullness = descendant:GetAttribute("CrystalFullness")
					if type(fullness) == "number" then
						bindIridiumAttribute(descendant)

						local carrier = getHighlightCarrier(descendant)
						if carrier ~= nil then
							local current = grouped[carrier]
							if current == nil or fullness > current.fullness then
								grouped[carrier] = {
									carrier = carrier,
									fullness = fullness,
								}
							end
						end
					end
				end
			end

			local entries = {}
			for _, entry in pairs(grouped) do
				table.insert(entries, entry)
			end

			espObjectCache.iridium.entries = entries
			espObjectCache.iridium.dirty = false
		end

		local targets = {}
		for _, entry in ipairs(espObjectCache.iridium.entries) do
			if entry.carrier.Parent ~= nil and entry.fullness >= state.iridiumMinFullness then
				table.insert(targets, entry.carrier)
			end
		end

		return targets
	end

	local function collectDistanceTargets(cacheKey, maxDistance)
		local targets = {}
		local localPosition = getLocalRootPosition()
		if localPosition == nil then
			return targets
		end

		for _, carrier in ipairs(getNamedTargets(cacheKey)) do
			local position = getInstancePosition(carrier)
			if carrier.Parent ~= nil and position ~= nil and (position - localPosition).Magnitude <= maxDistance then
				table.insert(targets, carrier)
			end
		end

		return targets
	end

	local function getPlayerHighlightColors(player)
		local baseColor = NativeUi.Theme.Accent
		if player.Team ~= nil and player.Team.TeamColor ~= nil then
			baseColor = player.Team.TeamColor.Color
		elseif player.TeamColor ~= nil then
			baseColor = player.TeamColor.Color
		end

		return baseColor:Lerp(Color3.new(1, 1, 1), 0.08), baseColor:Lerp(Color3.new(1, 1, 1), 0.34)
	end

	local function resolveTeamAttributeColor(value)
		if typeof(value) == "BrickColor" then
			return value.Color
		end

		if typeof(value) == "Color3" then
			return value
		end

		if type(value) == "string" and value ~= "" then
			local ok, brickColor = pcall(function()
				return BrickColor.new(value)
			end)
			if ok and brickColor ~= nil then
				return brickColor.Color
			end
		end

		return nil
	end

	local function readInstanceTeamColor(instance)
		if typeof(instance) ~= "Instance" then
			return nil
		end

		return resolveTeamAttributeColor(instance:GetAttribute("Team"))
	end

	local function getStructureHighlightColors(target, defaultFill, defaultOutline)
		local color = readInstanceTeamColor(target)
		local current = target
		while color == nil and typeof(current) == "Instance" and current.Parent ~= nil and current ~= Workspace do
			current = current.Parent
			color = readInstanceTeamColor(current)
		end

		if color == nil and typeof(target) == "Instance" and target:IsA("Model") then
			for _, descendant in ipairs(target:GetDescendants()) do
				color = readInstanceTeamColor(descendant)
				if color ~= nil then
					break
				end
			end
		end

		if color == nil then
			return defaultFill, defaultOutline
		end

		return color:Lerp(Color3.new(1, 1, 1), 0.12), color:Lerp(Color3.new(1, 1, 1), 0.36)
	end

	local function reconcilePlayerHighlights()
		local desired = {}

		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= Players.LocalPlayer then
				local shouldHighlight = state.highlightAllPlayers or state.highlightedPlayers[player.Name] == true
				if shouldHighlight and player.Character ~= nil then
					local fillColor, outlineColor = getPlayerHighlightColors(player)
					desired["player:" .. player.Name] = {
						target = player.Character,
						fillColor = fillColor,
						outlineColor = outlineColor,
					}
				end
			end
		end

		reconcileDesiredHighlights("player:", desired)
	end

	reconcileObjectHighlights = function()
		local desired = {}

		if state.espObjectToggles.spawnPoint then
			for _, target in ipairs(getNamedTargets("spawnPoint")) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(255, 194, 102), Color3.fromRGB(255, 226, 160))
				desired["object:spawn:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		if state.espObjectToggles.wellPump then
			for _, target in ipairs(getNamedTargets("wellPump")) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(255, 140, 96), Color3.fromRGB(255, 190, 160))
				desired["object:pump:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		if state.espObjectToggles.iridium then
			for _, target in ipairs(collectIridiumTargets()) do
				desired["object:iridium:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = Color3.fromRGB(165, 126, 255),
					outlineColor = Color3.fromRGB(214, 197, 255),
				}
			end
		end

		if state.espObjectToggles.spireWell then
			for _, target in ipairs(collectDistanceTargets("spireWell", state.wellDistance)) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(110, 204, 255), Color3.fromRGB(186, 229, 255))
				desired["object:spire:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		if state.espObjectToggles.well then
			for _, target in ipairs(collectDistanceTargets("well", state.wellDistance)) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(126, 220, 255), Color3.fromRGB(190, 234, 255))
				desired["object:well:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		reconcileDesiredHighlights("object:", desired)
	end

	local function clearAllHighlights()
		local toRemove = {}
		for key in pairs(highlightInstances) do
			table.insert(toRemove, key)
		end

		for _, key in ipairs(toRemove) do
			removeHighlight(key)
		end
	end

	local function ensurePlayerCharacterConnection(player)
		if playerCharacterConnections[player] ~= nil then
			return
		end

		playerCharacterConnections[player] = player.CharacterAdded:Connect(function()
			reconcilePlayerHighlights()
			if refreshPlayersList then
				refreshPlayersList()
			end
			if refreshEspPlayersList then
				refreshEspPlayersList()
			end
		end)
	end

	local function ensurePlayerTeamConnection(player)
		if playerTeamConnections[player] ~= nil then
			return
		end

		playerTeamConnections[player] = {
			player:GetPropertyChangedSignal("Team"):Connect(function()
				reconcilePlayerHighlights()
				if refreshPlayersList then
					refreshPlayersList()
				end
				if syncControlState then
					syncControlState()
				end
			end),
			player:GetPropertyChangedSignal("TeamColor"):Connect(function()
				reconcilePlayerHighlights()
				if refreshPlayersList then
					refreshPlayersList()
				end
				if syncControlState then
					syncControlState()
				end
			end),
		}
	end

	refreshPlayersList = function()
		NativeUi.clear(refs.spyMemberContent)

		local players = Players:GetPlayers()
		table.sort(players, function(left, right)
			return string.lower(left.Name) < string.lower(right.Name)
		end)

		local shown = 0
		for _, player in ipairs(players) do
			if player ~= Players.LocalPlayer then
				ensurePlayerCharacterConnection(player)
				ensurePlayerTeamConnection(player)

				shown = shown + 1
				local teamText = getPlayerTeamText(player)
				local label = player.DisplayName ~= player.Name and (player.DisplayName .. " @" .. player.Name) or player.Name
				local button = NativeUi.makeButton(refs.spyMemberContent, label .. "  /  " .. teamText, {
					Size = UDim2.new(1, 0, 0, 32),
					TextSize = 12,
					TextXAlignment = Enum.TextXAlignment.Left,
				})

				NativeUi.setButtonSelected(button, state.selectedPlayerName == player.Name)
				button.MouseButton1Click:Connect(function()
					state.selectedPlayerName = state.selectedPlayerName == player.Name and "" or player.Name
					refreshPlayersList()
					syncControlState()
				end)
			end
		end

		if shown == 0 then
			NativeUi.makeLabel(refs.spyMemberContent, "No other players are currently available.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
		end
	end

	local function countHighlightedPlayers()
		local total = 0
		for _ in pairs(state.highlightedPlayers) do
			total = total + 1
		end

		return total
	end

	refreshEspPlayersList = function()
		NativeUi.clear(refs.espPlayerContent)

		local players = Players:GetPlayers()
		table.sort(players, function(left, right)
			return string.lower(left.Name) < string.lower(right.Name)
		end)

		local shown = 0
		for _, player in ipairs(players) do
			if player ~= Players.LocalPlayer then
				ensurePlayerCharacterConnection(player)
				ensurePlayerTeamConnection(player)

				local searchable = player.Name .. " " .. (player.DisplayName or "")
				if containsFilter(searchable, state.espPlayerFilterText) then
					shown = shown + 1
					local button = NativeUi.makeButton(refs.espPlayerContent, player.DisplayName ~= player.Name and (player.DisplayName .. " @" .. player.Name) or player.Name, {
						Size = UDim2.new(1, 0, 0, 30),
						TextSize = 12,
						TextXAlignment = Enum.TextXAlignment.Left,
					})
					NativeUi.setButtonSelected(button, state.highlightedPlayers[player.Name] == true and not state.highlightAllPlayers)
					NativeUi.setButtonDisabled(button, state.highlightAllPlayers)

					button.MouseButton1Click:Connect(function()
						if state.highlightAllPlayers then
							return
						end

						if state.highlightedPlayers[player.Name] == true then
							state.highlightedPlayers[player.Name] = nil
						else
							state.highlightedPlayers[player.Name] = true
						end

						reconcilePlayerHighlights()
						refreshEspPlayersList()
					end)
				end
			end
		end

		if shown == 0 then
			NativeUi.makeLabel(refs.espPlayerContent, "No players match the current filter.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
		end
	end

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
				queueLoadCurrentTarget()
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
		local bodyVisible = not state.isMinimized
		local workspaceCopy = WORKSPACE_COPY[state.activeTab] or WORKSPACE_COPY.main
		refs.workspaceShell.Visible = bodyVisible
		refs.mainWorkspace.Visible = bodyVisible and state.activeTab == "main"
		refs.espWorkspace.Visible = bodyVisible and state.activeTab == "esp"
		refs.spyWorkspace.Visible = bodyVisible and state.activeTab == "spy"
		refs.gunsWorkspace.Visible = bodyVisible and state.activeTab == "guns"
		refs.bytecodeWorkspace.Visible = bodyVisible and state.activeTab == "bytecode"
		refs.buildWorkspace.Visible = bodyVisible and state.activeTab == "build"
		refs.remoteWorkspace.Visible = bodyVisible and state.activeTab == "remote"
		refs.bytecodeSplitter.Visible = bodyVisible and state.activeTab == "bytecode"
		refs.inspectorSplitter.Visible = bodyVisible and state.activeTab == "bytecode"
		refs.rightResizeHandle.Visible = not state.isMinimized
		refs.leftResizeHandle.Visible = not state.isMinimized
		refs.topResizeHandle.Visible = not state.isMinimized
		refs.bottomResizeHandle.Visible = not state.isMinimized
		refs.bottomRightResizeHandle.Visible = not state.isMinimized

		NativeUi.setButtonSelected(refs.mainTabButton, state.activeTab == "main")
		NativeUi.setButtonSelected(refs.espTabButton, state.activeTab == "esp")
		NativeUi.setButtonSelected(refs.spyTabButton, state.activeTab == "spy")
		NativeUi.setButtonSelected(refs.gunsTabButton, state.activeTab == "guns")
		NativeUi.setButtonSelected(refs.bytecodeTabButton, state.activeTab == "bytecode")
		NativeUi.setButtonSelected(refs.buildTabButton, state.activeTab == "build")
		NativeUi.setButtonSelected(refs.remoteTabButton, state.activeTab == "remote")
		refs.workspaceKickerLabel.Text = workspaceCopy.kicker
		refs.workspaceTitleLabel.Text = workspaceCopy.title
		refs.workspaceSubtitleLabel.Text = workspaceCopy.subtitle
		refs.workspaceSearchButton.Text = "  " .. workspaceCopy.search
		NativeUi.setButtonSelected(refs.scriptModeButton, state.sourceMode == "script")
		NativeUi.setButtonSelected(refs.fileModeButton, state.sourceMode == "file")
		NativeUi.setButtonSelected(refs.binaryButton, state.inputFormat == "binary")
		NativeUi.setButtonSelected(refs.hexButton, state.inputFormat == "hex")
		NativeUi.setButtonSelected(refs.codeViewButton, state.viewMode == "code")
		NativeUi.setButtonSelected(refs.decompileViewButton, state.viewMode == "decompile")
		NativeUi.setButtonSelected(refs.dataViewButton, state.viewMode == "data")
		NativeUi.setButtonSelected(refs.flowViewButton, state.viewMode == "flow")
		NativeUi.setButtonSelected(refs.rawOpcodesButton, state.showRawOpcodes)
		NativeUi.setButtonDisabled(refs.copyOpcodesButton, state.lastResult == nil)
		NativeUi.setButtonDisabled(refs.copyDecompileButton, state.lastResult == nil)

		syncToggleButton(refs.infiniteJumpToggle, state.infiniteJump)
		syncToggleButton(refs.noClipToggle, state.noClip)
		syncToggleButton(refs.fullBrightToggle, state.fullBright)
		syncToggleButton(refs.aimbotToggle, state.aimbotEnabled)
		syncToggleButton(refs.spawnPointToggle, state.espObjectToggles.spawnPoint)
		syncToggleButton(refs.wellPumpToggle, state.espObjectToggles.wellPump)
		syncToggleButton(refs.iridiumToggle, state.espObjectToggles.iridium)
		syncToggleButton(refs.spireWellToggle, state.espObjectToggles.spireWell)
		syncToggleButton(refs.wellToggle, state.espObjectToggles.well)
		syncToggleButton(refs.remoteWatcherToggle, state.remoteWatcherEnabled)
		NativeUi.setButtonSelected(refs.aimNearestButton, state.aimTargetPart == "nearest")
		NativeUi.setButtonSelected(refs.aimHeadButton, state.aimTargetPart == "head")
		NativeUi.setButtonSelected(refs.aimTorsoButton, state.aimTargetPart == "torso")
		NativeUi.setButtonSelected(refs.aimArmsButton, state.aimTargetPart == "arms")
		NativeUi.setButtonSelected(refs.aimLegsButton, state.aimTargetPart == "legs")
		NativeUi.setButtonSelected(refs.aimLimbsButton, state.aimTargetPart == "limbs")
		refs.minimizeButton.Text = state.isMinimized and "+" or "-"
		NativeUi.setButtonSelected(refs.minimizeButton, state.isMinimized)
		NativeUi.setButtonSelected(refs.highlightAllPlayersButton, state.highlightAllPlayers)

		refs.binaryButton.Visible = state.sourceMode == "file"
		refs.hexButton.Visible = state.sourceMode == "file"
		refs.targetBox.PlaceholderText = getActiveTargetPlaceholder()
		refs.targetBox.Text = getActiveTargetText()
		refs.filterBox.Text = state.filterText
		refs.treeSearchBox.Text = state.treeFilterText
		refs.remoteSearchBox.Text = state.remoteFilterText
		refs.espPlayerSearchBox.Text = state.espPlayerFilterText
		refs.activeTargetLabel.Text = ("Active target: %s"):format(getActiveTargetText() ~= "" and getActiveTargetText() or "-")
		refs.espSelectedPlayersLabel.Text = state.highlightAllPlayers
			and "Highlighted: all players"
			or ("Highlighted: %d"):format(countHighlightedPlayers())
		if not state.aimbotEnabled then
			refs.aimStatusLabel.Text = "Aimbot disabled"
		elseif not canMoveMouseCursor() then
			refs.aimStatusLabel.Text = "Relative mouse move API unavailable"
		elseif state.aimHoldActive and state.aimLockedPlayerName ~= "" then
			refs.aimStatusLabel.Text = ("Locked: %s [%s]"):format(state.aimLockedPlayerName, state.aimLockedPartName ~= "" and state.aimLockedPartName or state.aimTargetPart)
		elseif state.aimHoldActive then
			refs.aimStatusLabel.Text = "Holding Ctrl, no target"
		else
			refs.aimStatusLabel.Text = "Hold Ctrl to lock nearest target"
		end
		if state.isMinimized then
			refs.suiteStatus.Text = "Minimized"
			refs.suiteStatus.TextColor3 = NativeUi.Theme.TextMuted
		else
			refs.suiteStatus.Text = refs.inspectorStatusLabel.Text
			refs.suiteStatus.TextColor3 = refs.inspectorStatusLabel.TextColor3
		end

		updateSpyReadout()
		updateSuiteOverlays()
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

	local function toggleAimbot()
		state.aimbotEnabled = not state.aimbotEnabled
		if not state.aimbotEnabled then
			setAimbotHoldActive(false)
		else
			syncControlState()
		end
	end

	local function setAimTargetMode(mode)
		state.aimTargetPart = mode
		clearAimbotLock()
		if state.aimHoldActive then
			acquireAimbotTarget()
		end
		syncControlState()
	end

	local function toggleEspObject(toggleName)
		state.espObjectToggles[toggleName] = not state.espObjectToggles[toggleName]
		if toggleName == "spireWell" or toggleName == "well" then
			distanceRefreshAccumulator = 0
			lastDistanceRefreshPosition = nil
		end
		reconcileObjectHighlights()
		syncControlState()
	end

	local function handleEspDescendantMutation(descendant)
		local name = descendant.Name
		if name == "Spawn Point" then
			markNamedTargetDirty("spawnPoint", state.espObjectToggles.spawnPoint)
		elseif name == "Well Pump" then
			markNamedTargetDirty("wellPump", state.espObjectToggles.wellPump)
		elseif name == "SpireOpenLarge1" or name == "Map" then
			markNamedTargetDirty("spireWell", state.espObjectToggles.spireWell)
		elseif name == "Top1" or name == "Map" then
			markNamedTargetDirty("well", state.espObjectToggles.well)
		end

		if name == "Resources"
			or descendant:FindFirstAncestor("Resources") ~= nil
			or type(descendant:GetAttribute("CrystalFullness")) == "number" then
			markIridiumDirty(state.espObjectToggles.iridium)
		end
	end

	trackCleanup(restoreLighting)
	trackCleanup(function()
		for player, connection in pairs(playerCharacterConnections) do
			pcall(function()
				connection:Disconnect()
			end)
			playerCharacterConnections[player] = nil
		end
		for player, connectionGroup in pairs(playerTeamConnections) do
			for _, connection in pairs(connectionGroup) do
				pcall(function()
					connection:Disconnect()
				end)
			end
			playerTeamConnections[player] = nil
		end
		disconnectConnectionMap(espObjectCache.iridium.attributeConnections)
		clearAllHighlights()
	end)

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

	trackConnection(RunService.RenderStepped:Connect(function()
		local wantsHold = state.aimbotEnabled and canMoveMouseCursor() and UserInputService:GetFocusedTextBox() == nil and isAimbotHotkeyDown()
		if wantsHold ~= state.aimHoldActive then
			setAimbotHoldActive(wantsHold)
		end

		if not state.aimbotEnabled or not wantsHold or not canMoveMouseCursor() then
			return
		end

		local _, targetPart, targetScreenPosition = resolveLockedAimbotTarget()
		if targetPart == nil or targetScreenPosition == nil then
			return
		end

		moveMouseToScreenPosition(targetScreenPosition)
	end))

	trackConnection(RunService.Heartbeat:Connect(function(deltaTime)
		if not (state.espObjectToggles.spireWell or state.espObjectToggles.well) then
			distanceRefreshAccumulator = 0
			lastDistanceRefreshPosition = nil
			return
		end

		distanceRefreshAccumulator = distanceRefreshAccumulator + deltaTime
		if distanceRefreshAccumulator < 0.4 then
			return
		end

		local localPosition = getLocalRootPosition()
		if localPosition == nil then
			distanceRefreshAccumulator = 0
			if lastDistanceRefreshPosition ~= nil then
				lastDistanceRefreshPosition = nil
				reconcileObjectHighlights()
			end
			return
		end

		local movedEnough = lastDistanceRefreshPosition == nil
			or (localPosition - lastDistanceRefreshPosition).Magnitude >= 18
			or distanceRefreshAccumulator >= 1.2
		if not movedEnough then
			return
		end

		distanceRefreshAccumulator = 0
		lastDistanceRefreshPosition = localPosition
		reconcileObjectHighlights()
	end))
	trackConnection(Workspace.DescendantAdded:Connect(handleEspDescendantMutation))
	trackConnection(Workspace.DescendantRemoving:Connect(handleEspDescendantMutation))
	bindScriptBrowserMutationWatchers()
	bindRemoteMutationWatchers()

	trackConnection(Players.PlayerAdded:Connect(refreshPlayersList))
	trackConnection(Players.PlayerAdded:Connect(function(player)
		ensurePlayerCharacterConnection(player)
		ensurePlayerTeamConnection(player)
		refreshEspPlayersList()
		reconcilePlayerHighlights()
	end))
	trackConnection(Players.PlayerRemoving:Connect(function(player)
		if state.selectedPlayerName == player.Name then
			state.selectedPlayerName = Players.LocalPlayer and Players.LocalPlayer.Name or ""
		end

		state.highlightedPlayers[player.Name] = nil
		local connection = playerCharacterConnections[player]
		if connection ~= nil then
			pcall(function()
				connection:Disconnect()
			end)
			playerCharacterConnections[player] = nil
		end
		local connectionGroup = playerTeamConnections[player]
		if connectionGroup ~= nil then
			for _, teamConnection in pairs(connectionGroup) do
				pcall(function()
					teamConnection:Disconnect()
				end)
			end
			playerTeamConnections[player] = nil
		end

		removeHighlight("player:" .. player.Name)
		refreshPlayersList()
		refreshEspPlayersList()
		reconcilePlayerHighlights()
	end))

	trackConnection(refs.closeButton.MouseButton1Click:Connect(runCleanup))
	trackConnection(refs.minimizeButton.MouseButton1Click:Connect(function()
		setMinimized(not state.isMinimized)
		syncControlState()
	end))
	trackConnection(refs.mainTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "main"
		syncControlState()
	end))
	trackConnection(refs.espTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "esp"
		syncControlState()
	end))
	trackConnection(refs.spyTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "spy"
		syncControlState()
	end))
	trackConnection(refs.gunsTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "guns"
		syncControlState()
	end))
	trackConnection(refs.remoteTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "remote"
		syncControlState()
	end))
	trackConnection(refs.bytecodeTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "bytecode"
		syncControlState()
	end))
	trackConnection(refs.buildTabButton.MouseButton1Click:Connect(function()
		state.activeTab = "build"
		syncControlState()
	end))
	trackConnection(refs.refreshTreeButton.MouseButton1Click:Connect(function()
		refreshScriptBrowser(true)
		renderTreeView()
	end))
	trackConnection(refs.loadButton.MouseButton1Click:Connect(function()
		setActiveTargetText(refs.targetBox.Text)
		queueLoadCurrentTarget()
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

		queueLoadCurrentTarget()
		syncControlState()
		renderTreeView()
	end))
	trackConnection(refs.refreshViewButton.MouseButton1Click:Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end))
	trackConnection(refs.copyOpcodesButton.MouseButton1Click:Connect(function()
		copyOutputMode("code", "opcodes")
	end))
	trackConnection(refs.copyDecompileButton.MouseButton1Click:Connect(function()
		copyOutputMode("decompile", "decompile")
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
	trackConnection(refs.flowViewButton.MouseButton1Click:Connect(function()
		state.viewMode = "flow"
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
	trackConnection(refs.remoteSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.remoteFilterText = refs.remoteSearchBox.Text
		renderRemoteList()
	end))
	trackConnection(refs.espPlayerSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.espPlayerFilterText = refs.espPlayerSearchBox.Text
		refreshEspPlayersList()
	end))
	trackConnection(refs.filterBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end))
	trackConnection(refs.highlightAllPlayersButton.MouseButton1Click:Connect(function()
		state.highlightAllPlayers = not state.highlightAllPlayers
		reconcilePlayerHighlights()
		refreshEspPlayersList()
		syncControlState()
	end))
	trackConnection(refs.clearPlayerHighlightsButton.MouseButton1Click:Connect(function()
		state.highlightedPlayers = {}
		state.highlightAllPlayers = false
		reconcilePlayerHighlights()
		refreshEspPlayersList()
		syncControlState()
	end))
	trackConnection(refs.remoteWatcherToggle.toggle.MouseButton1Click:Connect(function()
		state.remoteWatcherEnabled = not state.remoteWatcherEnabled
		remoteHookBridge.enabled = state.remoteWatcherEnabled
		if state.remoteWatcherEnabled then
			installRemoteNamecallWatcher()
			scanRemoteList()
		end
		renderRemoteLog()
		syncControlState()
	end))
	trackConnection(refs.scanRemotesButton.MouseButton1Click:Connect(function()
		scanRemoteList()
		renderRemoteLog()
	end))
	trackConnection(refs.clearRemoteLogButton.MouseButton1Click:Connect(function()
		state.remoteLogs = {}
		renderRemoteLog()
	end))
	trackConnection(refs.spyClearButton.MouseButton1Click:Connect(function()
		state.selectedPlayerName = ""
		refreshPlayersList()
		syncControlState()
	end))
	trackConnection(refs.spyPinButton.MouseButton1Click:Connect(function()
		refreshPlayersList()
		syncControlState()
	end))
	trackConnection(refs.spyHighlightButton.MouseButton1Click:Connect(function()
		local player = getFocusedSpyPlayer()
		if player == nil then
			return
		end

		if state.highlightedPlayers[player.Name] == true then
			state.highlightedPlayers[player.Name] = nil
		else
			state.highlightedPlayers[player.Name] = true
		end

		reconcilePlayerHighlights()
		refreshEspPlayersList()
		refreshPlayersList()
		syncControlState()
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
	trackConnection(refs.aimbotToggle.toggle.MouseButton1Click:Connect(function()
		toggleAimbot()
	end))
	trackConnection(refs.aimNearestButton.MouseButton1Click:Connect(function()
		setAimTargetMode("nearest")
	end))
	trackConnection(refs.aimHeadButton.MouseButton1Click:Connect(function()
		setAimTargetMode("head")
	end))
	trackConnection(refs.aimTorsoButton.MouseButton1Click:Connect(function()
		setAimTargetMode("torso")
	end))
	trackConnection(refs.aimArmsButton.MouseButton1Click:Connect(function()
		setAimTargetMode("arms")
	end))
	trackConnection(refs.aimLegsButton.MouseButton1Click:Connect(function()
		setAimTargetMode("legs")
	end))
	trackConnection(refs.aimLimbsButton.MouseButton1Click:Connect(function()
		setAimTargetMode("limbs")
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
	trackConnection(refs.spawnPointToggle.toggle.MouseButton1Click:Connect(function()
		toggleEspObject("spawnPoint")
	end))
	trackConnection(refs.wellPumpToggle.toggle.MouseButton1Click:Connect(function()
		toggleEspObject("wellPump")
	end))
	trackConnection(refs.iridiumToggle.toggle.MouseButton1Click:Connect(function()
		toggleEspObject("iridium")
	end))
	trackConnection(refs.spireWellToggle.toggle.MouseButton1Click:Connect(function()
		toggleEspObject("spireWell")
	end))
	trackConnection(refs.wellToggle.toggle.MouseButton1Click:Connect(function()
		toggleEspObject("well")
	end))
	trackConnection(refs.iridiumSlider.applyButton.MouseButton1Click:Connect(function()
		state.iridiumMinFullness = iridiumSlider.getValue()
		reconcileObjectHighlights()
		syncControlState()
	end))
	trackConnection(refs.wellDistanceSlider.applyButton.MouseButton1Click:Connect(function()
		state.wellDistance = math.floor(wellDistanceSlider.getValue() + 0.5)
		reconcileObjectHighlights()
		syncControlState()
	end))

	refreshMainFields()
	walkSpeedSlider.setValue(state.walkSpeedValue)
	jumpPowerSlider.setValue(state.jumpPowerValue)
	hipHeightSlider.setValue(state.hipHeightValue)
	gravitySlider.setValue(state.gravityValue)
	iridiumSlider.setValue(state.iridiumMinFullness)
	wellDistanceSlider.setValue(state.wellDistance)
	refreshPlayersList()
	refreshEspPlayersList()
	refreshScriptBrowser(false)
	renderRemoteList()
	renderRemoteLog()
	reconcilePlayerHighlights()
	reconcileObjectHighlights()
	syncControlState()
	renderTreeView()
	renderOutputView()
	setMainStatus("Ready", NativeUi.Theme.TextMuted)
end

return BytecodeViewer
