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
local NativeUi = loadRemoteModule("NativeUi")

local BytecodeViewer = {}

local started = false
local GUI_NAME = "DartBytecodeViewer"

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

local function makeState(config)
	return {
		sourceMode = config.DefaultBytecodeSourceMode or "script",
		scriptPath = trimText(config.DefaultScriptPath or ""),
		filePath = trimText(config.DefaultBytecodeFilePath or ""),
		inputFormat = config.DefaultBytecodeInputFormat or "binary",
		filterText = "",
		showStrings = config.ShowStringTableByDefault == true,
		showConstants = config.ShowConstantTableByDefault ~= false,
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
		Position = UDim2.new(0.5, -560, 0.5, -360),
		Size = UDim2.fromOffset(1120, 720),
	})

	local topBar = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Panel,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 38),
		Parent = main,
	})
	NativeUi.corner(topBar, 10)

	NativeUi.makeLabel(topBar, "Dart Bytecode Viewer", {
		Font = Enum.Font.GothamBlack,
		TextSize = 16,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -70, 1, 0),
	})

	local closeButton = NativeUi.makeButton(topBar, "X", {
		Position = UDim2.new(1, -34, 0, 5),
		Size = UDim2.fromOffset(28, 28),
	})

	local leftPanel = NativeUi.makePanel(main, {
		Position = UDim2.fromOffset(12, 50),
		Size = UDim2.new(0, 330, 1, -62),
	})

	local rightPanel = NativeUi.makePanel(main, {
		Position = UDim2.new(0, 354, 0, 50),
		Size = UDim2.new(1, -366, 1, -62),
	})

	local leftHeader = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 28),
		Parent = leftPanel,
	})

	makeSectionTitle(leftHeader, "Client Scripts")

	local refreshTreeButton = NativeUi.makeButton(leftHeader, "Refresh", {
		Position = UDim2.new(1, -86, 0, 0),
		Size = UDim2.fromOffset(86, 28),
	})

	local treeScroll, treeContent = NativeUi.makeScrollList(leftPanel, {
		Position = UDim2.fromOffset(10, 48),
		Size = UDim2.new(1, -20, 1, -58),
		Padding = 4,
		ContentPadding = 8,
	})

	local controlsPanel = NativeUi.makePanel(rightPanel, {
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 0, 220),
		BackgroundColor3 = NativeUi.Theme.PanelAlt,
	})

	local controlsContent = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(10, 10),
		Size = UDim2.new(1, -20, 1, -20),
		Parent = controlsPanel,
	})

	NativeUi.list(controlsContent, 8, Enum.FillDirection.Vertical)

	makeSectionTitle(controlsContent, "Controls")

	local modeRow = NativeUi.makeRow(controlsContent, 28)
	local modeLabel = NativeUi.makeLabel(modeRow, "Source", {
		Size = UDim2.fromOffset(60, 28),
	})
	modeLabel.Position = UDim2.fromOffset(0, 0)

	local scriptModeButton = NativeUi.makeButton(modeRow, "Script", {
		Position = UDim2.fromOffset(72, 0),
		Size = UDim2.fromOffset(84, 28),
	})

	local fileModeButton = NativeUi.makeButton(modeRow, "File", {
		Position = UDim2.fromOffset(164, 0),
		Size = UDim2.fromOffset(72, 28),
	})

	local scriptRow = NativeUi.makeRow(controlsContent, 32)
	local scriptPathBox = NativeUi.makeTextBox(scriptRow, state.scriptPath, {
		PlaceholderText = "Players.LocalPlayer.PlayerScripts.YourLocalScript",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -196, 0, 32),
	})

	local loadScriptButton = NativeUi.makeButton(scriptRow, "Load Script", {
		Position = UDim2.new(1, -188, 0, 2),
		Size = UDim2.fromOffset(92, 28),
	})

	local reloadScriptButton = NativeUi.makeButton(scriptRow, "Reload", {
		Position = UDim2.new(1, -88, 0, 2),
		Size = UDim2.fromOffset(88, 28),
	})

	local fileRow = NativeUi.makeRow(controlsContent, 32)
	local filePathBox = NativeUi.makeTextBox(fileRow, state.filePath, {
		PlaceholderText = "C:\\Users\\Marin\\Downloads\\Test.txt",
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -176, 0, 32),
	})

	local loadFileButton = NativeUi.makeButton(fileRow, "Load File", {
		Position = UDim2.new(1, -168, 0, 2),
		Size = UDim2.fromOffset(80, 28),
	})

	local reloadFileButton = NativeUi.makeButton(fileRow, "Reload", {
		Position = UDim2.new(1, -80, 0, 2),
		Size = UDim2.fromOffset(80, 28),
	})

	local encodingRow = NativeUi.makeRow(controlsContent, 28)
	local encodingLabel = NativeUi.makeLabel(encodingRow, "Format", {
		Size = UDim2.fromOffset(60, 28),
	})
	encodingLabel.Position = UDim2.fromOffset(0, 0)

	local binaryButton = NativeUi.makeButton(encodingRow, "Binary", {
		Position = UDim2.fromOffset(72, 0),
		Size = UDim2.fromOffset(84, 28),
	})

	local hexButton = NativeUi.makeButton(encodingRow, "Hex", {
		Position = UDim2.fromOffset(164, 0),
		Size = UDim2.fromOffset(68, 28),
	})

	local filterRow = NativeUi.makeRow(controlsContent, 32)
	local filterBox = NativeUi.makeTextBox(filterRow, "", {
		PlaceholderText = "Filter output text",
		Size = UDim2.new(1, 0, 0, 32),
	})

	local optionsRow = NativeUi.makeRow(controlsContent, 28)
	local rawOpcodesButton = NativeUi.makeButton(optionsRow, "Raw Opcodes", {
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(104, 28),
	})

	local stringsButton = NativeUi.makeButton(optionsRow, "Strings", {
		Position = UDim2.fromOffset(112, 0),
		Size = UDim2.fromOffset(78, 28),
	})

	local constantsButton = NativeUi.makeButton(optionsRow, "Constants", {
		Position = UDim2.fromOffset(198, 0),
		Size = UDim2.fromOffset(88, 28),
	})

	local loadCurrentButton = NativeUi.makeButton(optionsRow, "Load Current", {
		Position = UDim2.new(1, -204, 0, 0),
		Size = UDim2.fromOffset(96, 28),
	})

	local refreshViewButton = NativeUi.makeButton(optionsRow, "Refresh View", {
		Position = UDim2.new(1, -100, 0, 0),
		Size = UDim2.fromOffset(100, 28),
	})

	local statusLabel = NativeUi.makeLabel(controlsContent, "Ready", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 13,
		Size = UDim2.new(1, 0, 0, 22),
	})

	local outputScroll, outputContent = NativeUi.makeScrollList(rightPanel, {
		Position = UDim2.fromOffset(10, 240),
		Size = UDim2.new(1, -20, 1, -250),
		Padding = 4,
		ContentPadding = 10,
	})

	NativeUi.makeDraggable(topBar, main)

	refs.gui = screenGui
	refs.main = main
	refs.treeContent = treeContent
	refs.outputContent = outputContent
	refs.scriptModeButton = scriptModeButton
	refs.fileModeButton = fileModeButton
	refs.scriptRow = scriptRow
	refs.fileRow = fileRow
	refs.encodingRow = encodingRow
	refs.binaryButton = binaryButton
	refs.hexButton = hexButton
	refs.rawOpcodesButton = rawOpcodesButton
	refs.stringsButton = stringsButton
	refs.constantsButton = constantsButton
	refs.scriptPathBox = scriptPathBox
	refs.filePathBox = filePathBox
	refs.filterBox = filterBox
	refs.statusLabel = statusLabel

	closeButton.MouseButton1Click:Connect(function()
		started = false
		screenGui:Destroy()
	end)

	refs.refreshTreeButton = refreshTreeButton
	refs.loadScriptButton = loadScriptButton
	refs.reloadScriptButton = reloadScriptButton
	refs.loadFileButton = loadFileButton
	refs.reloadFileButton = reloadFileButton
	refs.loadCurrentButton = loadCurrentButton
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

	local function setStatus(text, color)
		refs.statusLabel.Text = text
		refs.statusLabel.TextColor3 = color or NativeUi.Theme.TextMuted
	end

	local function collectOutputLines()
		if state.lastResult == nil then
			return {}
		end

		local prettyText = LuauChunk.formatPrettyChunk(state.lastResult.chunk, {
			includeStrings = state.showStrings,
			includeConstants = state.showConstants,
			showRawOpcode = state.showRawOpcodes,
		})

		local filtered = {}
		for _, line in ipairs(splitLines(prettyText)) do
			if containsFilter(line, state.filterText) then
				table.insert(filtered, line)
			end
		end

		return filtered
	end

	local function syncControlState()
		refs.scriptPathBox.Text = state.scriptPath
		refs.filePathBox.Text = state.filePath
		refs.filterBox.Text = state.filterText

		refs.scriptRow.Visible = state.sourceMode == "script"
		refs.fileRow.Visible = state.sourceMode == "file"
		refs.encodingRow.Visible = state.sourceMode == "file"

		NativeUi.setButtonSelected(refs.scriptModeButton, state.sourceMode == "script")
		NativeUi.setButtonSelected(refs.fileModeButton, state.sourceMode == "file")
		NativeUi.setButtonSelected(refs.binaryButton, state.inputFormat == "binary")
		NativeUi.setButtonSelected(refs.hexButton, state.inputFormat == "hex")
		NativeUi.setButtonSelected(refs.rawOpcodesButton, state.showRawOpcodes)
		NativeUi.setButtonSelected(refs.stringsButton, state.showStrings)
		NativeUi.setButtonSelected(refs.constantsButton, state.showConstants)
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

		for _, line in ipairs(lines) do
			if line == "" then
				NativeUi.makeRow(refs.outputContent, 6)
			elseif not string.find(line, "^%s") then
				NativeUi.makeLabel(refs.outputContent, line, {
					Font = Enum.Font.GothamBold,
					TextColor3 = NativeUi.Theme.Text,
					TextSize = 14,
					Size = UDim2.new(1, 0, 0, 20),
				})
			else
				NativeUi.makeCodeLabel(refs.outputContent, line, {
					TextColor3 = NativeUi.Theme.Text,
				})
			end
		end
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
				NativeUi.clear(refs.treeContent)
				for _, rootNode in ipairs(state.scriptBrowserTree) do
					renderTreeNode(rootNode)
				end
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
				state.sourceMode = "script"
				state.scriptPath = node.path
				syncControlState()
				loadScriptTarget()
				NativeUi.clear(refs.treeContent)
				for _, rootNode in ipairs(state.scriptBrowserTree) do
					renderTreeNode(rootNode)
				end
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

	local function renderTreeView()
		NativeUi.clear(refs.treeContent)

		if state.scriptBrowserError ~= nil then
			NativeUi.makeCodeLabel(refs.treeContent, tostring(state.scriptBrowserError), {
				TextColor3 = NativeUi.Theme.Error,
			})
			return
		end

		if #state.scriptBrowserTree == 0 then
			NativeUi.makeLabel(refs.treeContent, "No scripts discovered in the current client view.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
				TextYAlignment = Enum.TextYAlignment.Top,
			})
			return
		end

		for _, rootNode in ipairs(state.scriptBrowserTree) do
			renderTreeNode(rootNode)
		end
	end

	refs.refreshTreeButton.MouseButton1Click:Connect(function()
		refreshScriptBrowser()
		renderTreeView()
	end)

	refs.loadScriptButton.MouseButton1Click:Connect(function()
		state.scriptPath = refs.scriptPathBox.Text
		loadScriptTarget()
		renderTreeView()
	end)

	refs.reloadScriptButton.MouseButton1Click:Connect(function()
		state.scriptPath = refs.scriptPathBox.Text
		loadScriptTarget()
		renderTreeView()
	end)

	refs.loadFileButton.MouseButton1Click:Connect(function()
		state.filePath = refs.filePathBox.Text
		loadFileTarget()
	end)

	refs.reloadFileButton.MouseButton1Click:Connect(function()
		state.filePath = refs.filePathBox.Text
		loadFileTarget()
	end)

	refs.loadCurrentButton.MouseButton1Click:Connect(function()
		state.scriptPath = refs.scriptPathBox.Text
		state.filePath = refs.filePathBox.Text
		loadCurrentTarget()
		renderTreeView()
	end)

	refs.refreshViewButton.MouseButton1Click:Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
		renderTreeView()
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

	refs.stringsButton.MouseButton1Click:Connect(function()
		state.showStrings = not state.showStrings
		syncControlState()
		renderOutputView()
	end)

	refs.constantsButton.MouseButton1Click:Connect(function()
		state.showConstants = not state.showConstants
		syncControlState()
		renderOutputView()
	end)

	refs.scriptPathBox.FocusLost:Connect(function()
		state.scriptPath = refs.scriptPathBox.Text
	end)

	refs.filePathBox.FocusLost:Connect(function()
		state.filePath = refs.filePathBox.Text
	end)

	refs.filterBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end)

	refreshScriptBrowser()
	syncControlState()
	renderTreeView()

	if state.sourceMode == "script" and state.scriptPath ~= "" then
		loadScriptTarget()
		renderTreeView()
	elseif state.sourceMode == "file" and state.filePath ~= "" then
		loadFileTarget()
	end

	renderOutputView()
end

return BytecodeViewer
