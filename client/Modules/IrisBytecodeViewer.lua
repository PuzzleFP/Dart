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

local IrisBytecodeViewer = {}

local started = false

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

local function safeParseFile(path, inputFormat, showRawOpcode)
	local ok, chunk = pcall(function()
		return LuauChunk.parseFile(path, {
			inputFormat = inputFormat,
		})
	end)

	if not ok then
		return nil, chunk
	end

	local prettyOutput = LuauChunk.formatPrettyChunk(chunk, {
		showRawOpcode = showRawOpcode,
	})

	return {
		chunk = chunk,
		prettyOutput = prettyOutput,
		prettyLines = splitLines(prettyOutput),
	}, nil
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
	local lastLoadedPath = nil

	local function loadCurrentPath()
		local path = filePath.value
		if path == nil or path == "" then
			lastResult = nil
			lastLoadedPath = nil
			lastError = "No file path provided"
			return
		end

		local result, err = safeParseFile(path, inputFormat.value, showRawOpcodes.value)
		lastResult = result
		lastLoadedPath = path
		lastError = err
	end

	if filePath.value ~= "" then
		loadCurrentPath()
	end

	Iris:Connect(function()
		Iris.Window({ "Luau Bytecode Viewer" }, {
			size = windowSize,
			position = windowPosition,
		})
		do
			Iris.Text({ "Inspect a Luau bytecode file and show decoded opcodes, constants, and inferred behavior." })

			Iris.PushConfig({ ContentWidth = UDim.new(1, -160) })
			Iris.InputText({ "Bytecode File Path" }, { text = filePath })
			Iris.PopConfig()

			Iris.SameLine()
			do
				if Iris.Button({ "Load File" }).clicked() then
					loadCurrentPath()
				end

				if Iris.Button({ "Reload" }).clicked() and lastLoadedPath ~= nil then
					filePath:set(lastLoadedPath)
					loadCurrentPath()
				end
			end
			Iris.End()

			Iris.SameLine()
			do
				Iris.RadioButton({ "Binary", "binary" }, { index = inputFormat })
				Iris.RadioButton({ "Hex", "hex" }, { index = inputFormat })
			end
			Iris.End()

			Iris.PushConfig({ ContentWidth = UDim.new(1, -160) })
			Iris.InputText({ "Filter" }, { text = filterText })
			Iris.PopConfig()

			Iris.SameLine()
			do
				Iris.Checkbox({ "Show Strings" }, { isChecked = showStrings })
				Iris.Checkbox({ "Show Constants" }, { isChecked = showConstants })
				Iris.Checkbox({ "Show Raw Opcodes" }, { isChecked = showRawOpcodes })
				if Iris.Button({ "Reformat" }).clicked() and lastLoadedPath ~= nil then
					loadCurrentPath()
				end
			end
			Iris.End()

			Iris.Separator()

			if lastError then
				Iris.TextColored({ "Load Error: " .. tostring(lastError), Color3.fromRGB(255, 110, 110) })
			elseif lastResult == nil then
				Iris.Text({ "No bytecode file loaded yet." })
			else
				Iris.TextColored({ "Loaded: " .. tostring(lastLoadedPath), Color3.fromRGB(140, 210, 255) })

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
