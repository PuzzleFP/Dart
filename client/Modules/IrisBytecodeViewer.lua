local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local TextService = game:GetService("TextService")
local Workspace = game:GetService("Workspace")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local StarterGui = game:GetService("StarterGui")

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
local RemoteSpyEngine = loadRemoteModule("RemoteSpyEngine")

if type(SuiteTheme.applyToNativeUi) == "function" then
	SuiteTheme.applyToNativeUi(NativeUi)
end

local BytecodeViewer = {}

local started = false
local GUI_NAME = "EclipsisControlGui"
local SESSION_KEY = "__DartViewerCleanup"
local MAX_AIM_MOUSE_STEP = 120
local FREE_CAMERA_ACTION_NAME = "DartFreeCameraInputSink"
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

local function getCharacterRootPart(character)
	if character == nil then
		return nil
	end

	return character:FindFirstChild("HumanoidRootPart")
		or character:FindFirstChild("UpperTorso")
		or character:FindFirstChild("Torso")
		or character.PrimaryPart
end

local function getCharacterCameraSubject(character)
	if character == nil then
		return nil
	end

	return character:FindFirstChildOfClass("Humanoid") or getCharacterRootPart(character)
end

local LOCAL_CHARACTER_ANIMATIONS = {
	R6 = {
		idle = "180435571",
		walk = "180426354",
	},
	R15 = {
		idle = "507766666",
		walk = "507777826",
	},
}

local LOCAL_CHARACTER_ANIMATION_CONTROLLERS = setmetatable({}, { __mode = "k" })
local CHARACTER_NO_COLLISION_FOLDER_NAME = "__DartNoCollision"

local function getCharacterBaseParts(character)
	local parts = {}
	if typeof(character) ~= "Instance" then
		return parts
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end

	return parts
end

local function countCharacterBaseParts(character)
	if typeof(character) ~= "Instance" then
		return 0
	end

	local count = 0
	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("BasePart") then
			count = count + 1
		end
	end

	return count
end

local function clearCharacterNoCollisionLinks(character)
	if typeof(character) ~= "Instance" then
		return
	end

	local folder = character:FindFirstChild(CHARACTER_NO_COLLISION_FOLDER_NAME)
	if folder ~= nil then
		folder:Destroy()
	end
end

local function preventCharacterPairCollision(primaryCharacter, otherCharacter)
	if typeof(primaryCharacter) ~= "Instance" or typeof(otherCharacter) ~= "Instance" then
		return
	end

	clearCharacterNoCollisionLinks(primaryCharacter)

	local primaryParts = getCharacterBaseParts(primaryCharacter)
	local otherParts = getCharacterBaseParts(otherCharacter)
	if #primaryParts == 0 or #otherParts == 0 then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = CHARACTER_NO_COLLISION_FOLDER_NAME
	folder.Parent = primaryCharacter

	for _, primaryPart in ipairs(primaryParts) do
		for _, otherPart in ipairs(otherParts) do
			if primaryPart ~= otherPart then
				local constraint = Instance.new("NoCollisionConstraint")
				constraint.Part0 = primaryPart
				constraint.Part1 = otherPart
				constraint.Parent = folder
			end
		end
	end
end

local function getCharacterCollisionSignature(primaryCharacter, otherCharacter)
	return ("%s:%d|%s:%d"):format(
		tostring(primaryCharacter),
		countCharacterBaseParts(primaryCharacter),
		tostring(otherCharacter),
		countCharacterBaseParts(otherCharacter)
	)
end

local function findCharacterAnimateScript(character)
	if typeof(character) ~= "Instance" then
		return nil
	end

	local direct = character:FindFirstChild("Animate")
	if direct ~= nil and direct:IsA("LocalScript") then
		return direct
	end

	for _, descendant in ipairs(character:GetDescendants()) do
		if descendant:IsA("LocalScript") and descendant.Name == "Animate" then
			return descendant
		end
	end

	return nil
end

local function getRigAnimationSet(humanoid)
	if humanoid ~= nil and humanoid.RigType == Enum.HumanoidRigType.R6 then
		return LOCAL_CHARACTER_ANIMATIONS.R6
	end

	return LOCAL_CHARACTER_ANIMATIONS.R15
end

local function ensureCharacterAnimator(humanoid)
	if humanoid == nil then
		return nil
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	return animator
end

local function loadLocalCharacterTrack(animator, animationId, priority)
	if animator == nil or animationId == nil then
		return nil
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = "rbxassetid://" .. tostring(animationId)

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	animation:Destroy()

	if not ok or track == nil then
		return nil
	end

	pcall(function()
		track.Priority = priority
		track.Looped = true
	end)

	return track
end

local function stopLocalCharacterAnimationController(controller)
	if type(controller) ~= "table" or type(controller.tracks) ~= "table" then
		return
	end

	for _, track in pairs(controller.tracks) do
		pcall(function()
			track:Stop(0.1)
			track:Destroy()
		end)
	end
end

local function clearLocalCharacterAnimation(character)
	local controller = LOCAL_CHARACTER_ANIMATION_CONTROLLERS[character]
	if controller ~= nil then
		stopLocalCharacterAnimationController(controller)
		LOCAL_CHARACTER_ANIMATION_CONTROLLERS[character] = nil
	end
end

local function prepareLocalCharacterAnimation(character)
	if typeof(character) ~= "Instance" then
		return
	end

	clearLocalCharacterAnimation(character)

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return
	end

	local animateScript = findCharacterAnimateScript(character)
	if animateScript ~= nil then
		pcall(function()
			animateScript.Enabled = true
		end)
		pcall(function()
			animateScript.Disabled = false
		end)
	end

	local animator = ensureCharacterAnimator(humanoid)
	if animator == nil then
		return
	end

	local animationSet = getRigAnimationSet(humanoid)
	local tracks = {
		idle = loadLocalCharacterTrack(animator, animationSet.idle, Enum.AnimationPriority.Idle),
		walk = loadLocalCharacterTrack(animator, animationSet.walk, Enum.AnimationPriority.Movement),
	}

	LOCAL_CHARACTER_ANIMATION_CONTROLLERS[character] = {
		humanoid = humanoid,
		animator = animator,
		defaultAnimate = animateScript,
		manualAfter = os.clock() + 0.75,
		active = nil,
		tracks = tracks,
	}
end

local function defaultAnimateIsRunning(controller)
	if controller.defaultAnimate == nil or os.clock() < controller.manualAfter then
		return controller.defaultAnimate ~= nil
	end

	local ok, tracks = pcall(function()
		return controller.animator:GetPlayingAnimationTracks()
	end)
	if ok and type(tracks) == "table" and #tracks > 0 then
		return true
	end

	controller.defaultAnimate = nil
	return false
end

local function updateLocalCharacterAnimation(character, moveVector)
	local controller = LOCAL_CHARACTER_ANIMATION_CONTROLLERS[character]
	if controller == nil then
		return
	end

	if typeof(character) ~= "Instance" or character.Parent == nil or controller.humanoid.Parent == nil then
		clearLocalCharacterAnimation(character)
		return
	end

	if defaultAnimateIsRunning(controller) then
		return
	end

	local moving = typeof(moveVector) == "Vector3" and moveVector.Magnitude > 0.05
	local desiredName = moving and "walk" or "idle"
	local desiredTrack = controller.tracks[desiredName]
	if desiredTrack == nil then
		return
	end

	if controller.active ~= desiredName then
		for name, track in pairs(controller.tracks) do
			if name ~= desiredName and track ~= nil then
				pcall(function()
					track:Stop(0.12)
				end)
			end
		end

		pcall(function()
			desiredTrack:Play(0.12)
		end)
		controller.active = desiredName
	end

	if moving then
		local speedScale = math.max(0.75, math.min(2.25, controller.humanoid.WalkSpeed / 16))
		pcall(function()
			desiredTrack:AdjustSpeed(speedScale)
		end)
	else
		pcall(function()
			desiredTrack:AdjustSpeed(1)
		end)
	end
end

local function resolveAntiFallDisableKeyCode(config)
	local configured = type(config) == "table" and config.AntiFallDisableKeyCode or nil
	if type(configured) == "string" then
		local ok, keyCode = pcall(function()
			return Enum.KeyCode[configured]
		end)
		if ok and keyCode ~= nil then
			return keyCode
		end
	elseif typeof(configured) == "EnumItem" then
		return configured
	end

	local ok, keyCode = pcall(function()
		return Enum.KeyCode.Backquote
	end)
	return ok and keyCode or nil
end

local function getPlayerRootPart(player)
	return getCharacterRootPart(player and player.Character or nil)
end

local function getPlayerPosition(player)
	local character = player and player.Character or nil
	if character == nil then
		return nil
	end

	local root = getCharacterRootPart(character)
	if root ~= nil then
		return root.Position
	end

	return getInstancePosition(character)
end

local function getLocalThreatPosition()
	local position = getPlayerPosition(Players.LocalPlayer)
	if position ~= nil then
		return position
	end

	local camera = getCurrentCamera()
	return camera and camera.CFrame.Position or nil
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

local function getStructuresRoot()
	return Workspace:FindFirstChild("Structures")
end

local function resolveStructureRoot(instance)
	local structuresRoot = getStructuresRoot()
	if typeof(instance) ~= "Instance" or structuresRoot == nil then
		return nil
	end

	if instance.Parent == structuresRoot then
		return instance
	end

	local current = instance
	while current ~= nil and current.Parent ~= nil and current.Parent ~= structuresRoot do
		current = current.Parent
	end

	if current ~= nil and current.Parent == structuresRoot then
		return current
	end

	return nil
end

local function colorDistance(left, right)
	return math.abs(left.R - right.R) + math.abs(left.G - right.G) + math.abs(left.B - right.B)
end

local function getLocalTeamColor()
	local localPlayer = Players.LocalPlayer
	if localPlayer == nil then
		return nil
	end

	if localPlayer.Team ~= nil and localPlayer.Team.TeamColor ~= nil then
		return localPlayer.Team.TeamColor.Color
	elseif localPlayer.TeamColor ~= nil then
		return localPlayer.TeamColor.Color
	end

	return nil
end

local function getStructureTeamText(structure)
	local teamValue = structure:GetAttribute("Team")
	local teamIndex = structure:GetAttribute("TeamIndex")
	local teamText = nil

	if typeof(teamValue) == "BrickColor" then
		teamText = teamValue.Name
	elseif type(teamValue) == "string" and teamValue ~= "" then
		teamText = teamValue
	elseif typeof(teamValue) == "Color3" then
		teamText = "team color"
	end

	if teamText == nil or teamText == "" then
		teamText = type(teamIndex) == "number" and ("Team %d"):format(teamIndex) or "unknown team"
	elseif type(teamIndex) == "number" then
		teamText = ("%s / Team %d"):format(teamText, teamIndex)
	end

	return teamText
end

local function getStructureTeamColor(structure)
	local current = structure
	while typeof(current) == "Instance" and current ~= nil and current ~= Workspace do
		local color = readInstanceTeamColor(current)
		if color ~= nil then
			return color
		end
		current = current.Parent
	end

	return nil
end

local function isEnemyStructure(structure)
	local teamColor = getStructureTeamColor(structure)
	local localColor = getLocalTeamColor()
	if teamColor == nil or localColor == nil then
		return false
	end

	return colorDistance(teamColor, localColor) > 0.03
end

local function classifyIntelligenceStructure(structure)
	if typeof(structure) ~= "Instance" then
		return nil
	end

	local normalized = string.lower(structure.Name):gsub("[%p%s_]+", "")
	if string.find(normalized, "ssim", 1, true) ~= nil then
		return "S.S.I.M", "warning"
	elseif string.find(normalized, "arsenal", 1, true) ~= nil then
		return "Arsenal", "warning"
	elseif string.find(normalized, "artillery", 1, true) ~= nil then
		return "Artillery", "info"
	elseif string.find(normalized, "bore", 1, true) ~= nil then
		return "Bore", "info"
	end

	return nil
end

local function getStructureBuilderText(structure)
	local builder = structure:GetAttribute("Builder")
	if type(builder) == "string" and trimText(builder) ~= "" then
		return builder
	end

	return "Unknown builder"
end

local function formatProductionValue(value)
	if typeof(value) == "Instance" then
		return value.Name
	elseif typeof(value) == "BrickColor" then
		return value.Name
	elseif typeof(value) == "Color3" then
		return "color value"
	end

	local text = trimText(tostring(value or ""))
	if text == "" or text == "nil" then
		return nil
	end

	return text
end

local PRODUCTION_ATTRIBUTES = {
	"Producing",
	"Production",
	"CurrentProduction",
	"CurrentRecipe",
	"Recipe",
	"Item",
	"Product",
	"Output",
}

local MACRO_STRUCTURE_KINDS = { "Arsenal", "S.S.I.M", "Artillery", "Bore" }

local function readStructureProduction(structure)
	for _, attributeName in ipairs(PRODUCTION_ATTRIBUTES) do
		local value = formatProductionValue(structure:GetAttribute(attributeName))
		if value ~= nil then
			return value
		end
	end

	return nil
end

local function readProductionCarrierValue(instance)
	if typeof(instance) ~= "Instance" then
		return nil
	end

	local normalized = string.lower(instance.Name):gsub("[%p%s_]+", "")
	if string.find(normalized, "production", 1, true) == nil
		and string.find(normalized, "producing", 1, true) == nil
		and string.find(normalized, "recipe", 1, true) == nil
		and string.find(normalized, "product", 1, true) == nil
		and string.find(normalized, "output", 1, true) == nil then
		return nil
	end

	if instance:IsA("ValueBase") then
		local ok, value = pcall(function()
			return instance.Value
		end)
		if ok then
			return formatProductionValue(value)
		end
	end

	return formatProductionValue(instance:GetAttribute("Value") or instance:GetAttribute("Item") or instance:GetAttribute("Product"))
end

local function getMacroKey(text)
	return string.lower(tostring(text or "")):gsub("[%p%s_]+", "")
end

local function normalizeMacroArgs(value, context)
	if type(value) == "function" then
		local generated = value(context)
		if type(generated) == "table" then
			return generated
		end
		return { generated }
	elseif type(value) == "table" then
		return value
	end

	return { context.weaponName, context.structure }
end

local function runMacroRemote(spec, context)
	local remote = spec.Remote or spec.remote
	if typeof(remote) ~= "Instance" then
		local path = spec.Path or spec.path
		if type(path) ~= "string" or trimText(path) == "" then
			return false, "Macro remote path missing"
		end
		remote = resolveInstanceByPath(path)
	end

	local method = spec.Method or spec.method
	if method == nil or method == "" then
		method = remote:IsA("RemoteFunction") and "InvokeServer" or "FireServer"
	end
	if method ~= "FireServer" and method ~= "InvokeServer" then
		return false, "Macro remote method must be FireServer or InvokeServer"
	end

	local args = normalizeMacroArgs(spec.Args or spec.args, context)
	local unpackArgs = table.unpack or unpack
	if method == "InvokeServer" then
		return true, remote:InvokeServer(unpackArgs(args))
	end

	remote:FireServer(unpackArgs(args))
	return true, "Remote fired"
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
		and (
			instance:IsA("RemoteEvent")
			or instance:IsA("RemoteFunction")
			or instance:IsA("BindableEvent")
			or instance:IsA("BindableFunction")
			or instance.ClassName == "UnreliableRemoteEvent"
		)
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
	local count = select("#", ...)
	local packed = {
		n = count,
	}
	for index = 1, count do
		packed[index] = select(index, ...)
	end
	return packed
end

local function packRemoteArgsAfterFirst(...)
	local count = select("#", ...)
	local packed = {
		n = math.max(count - 1, 0),
	}
	for index = 2, count do
		packed[index - 1] = select(index, ...)
	end
	return packed
end

local function normalizeRemoteMethod(method)
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

local function formatInstanceExpression(instance)
	if typeof(instance) ~= "Instance" then
		return "nil"
	end

	local names = {}
	local current = instance
	while current ~= nil and current ~= game do
		table.insert(names, 1, current.Name)
		current = current.Parent
	end

	if #names == 0 then
		return "game"
	end

	local rootName = table.remove(names, 1)
	local expression = ("game:GetService(%q)"):format(rootName)
	for _, name in ipairs(names) do
		expression = expression .. (":WaitForChild(%q)"):format(name)
	end

	return expression
end

local function formatRemoteReplay(call)
	if call == nil then
		return "-- No remote call selected."
	end

	local method = tostring(call.Method or "FireServer")
	if method == "OnClientEvent" or method == "Event" then
		return "-- Inbound/local signal captures cannot be replayed from the client with this method."
	end

	local args = call.Args or {}
	local parts = {}
	for index = 1, getPackedArgCount(args) do
		table.insert(parts, formatRemoteValue(args[index], 0))
	end

	return table.concat({
		"-- Generated by Dart RemoteSpy",
		("-- Remote: %s"):format(tostring(call.Path or "?")),
		("local remote = %s"):format(formatInstanceExpression(call.Remote)),
		("remote:%s(%s)"):format(method, table.concat(parts, ", ")),
	}, "\n")
end

local function formatRemoteCallPayload(call)
	if call == nil then
		return "No call selected.\n\nSelect a remote on the left, then select a captured call in the middle column."
	end

	local lines = {
		("CALL #%s"):format(tostring(call.Id or "?")),
		("Remote    : %s"):format(tostring(call.Path or "?")),
		("Class     : %s"):format(tostring(call.ClassName or "?")),
		("Direction : %s"):format(tostring(call.Direction or "?")),
		("Method    : %s"):format(tostring(call.Method or "?")),
		("Hook      : %s"):format(tostring(call.Hook or "?")),
		("Time      : %s"):format(tostring(call.Timestamp or "?")),
		("Script    : %s"):format(tostring(call.Script or "<unavailable>")),
		("Args      : %d"):format(getPackedArgCount(call.Args)),
		"",
		"ARGS",
		formatRemoteArgLines(call.Args or {}),
		"",
		"REPLAY",
		formatRemoteReplay(call),
	}

	return table.concat(lines, "\n")
end

local function formatRemoteDiagnostics(diagnostics)
	diagnostics = diagnostics or {}
	local methods = {}
	for name, enabled in pairs(diagnostics.methods or {}) do
		if enabled then
			table.insert(methods, name)
		end
	end
	table.sort(methods)

	local last = diagnostics.lastCapture
	local lastText = "none"
	if last ~= nil then
		lastText = ("#%s %s args=%s via %s"):format(
			tostring(last.id or "?"),
			tostring(last.method or "?"),
			tostring(last.argCount or 0),
			tostring(last.hook or "?")
		)
	end

	local lines = {
		("executor: %s %s"):format(tostring(diagnostics.executorName or "unknown"), tostring(diagnostics.executorVersion or "")),
		("hooks: meta=%s direct=%s namecallApi=%s cclosure=%s checkcaller=%s"):format(
			diagnostics.hookmetamethod and "yes" or "no",
			diagnostics.hookfunction and "yes" or "no",
			diagnostics.getnamecallmethod and "yes" or "no",
			diagnostics.newcclosure and "yes" or "no",
			diagnostics.checkcaller and "yes" or "no"
		),
		("inspect: callingScript=%s debugInfo=%s instances=%s nilInstances=%s"):format(
			diagnostics.getcallingscript and "yes" or "no",
			diagnostics.debug_getinfo and "yes" or "no",
			diagnostics.getinstances and "yes" or "no",
			diagnostics.getnilinstances and "yes" or "no"
		),
		("installed: %s"):format(#methods > 0 and table.concat(methods, ", ") or "none"),
		("last: %s"):format(lastText),
	}

	if diagnostics.directError ~= nil then
		table.insert(lines, "direct error: " .. tostring(diagnostics.directError))
	end
	if diagnostics.namecallError ~= nil then
		table.insert(lines, "namecall error: " .. tostring(diagnostics.namecallError))
	end
	if diagnostics.lastScanError ~= nil then
		table.insert(lines, "scan error: " .. tostring(diagnostics.lastScanError))
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
		remoteLogSerial = 0,
		remoteCallCounts = {},
		remoteRecords = {},
		remoteRecordOrder = {},
		remoteList = {},
		selectedRemotePath = nil,
		selectedRemoteKey = nil,
		selectedRemoteCallId = nil,
		remoteWatcherEnabled = false,
		remoteHookInstalled = false,
		remoteHookError = nil,
		remoteHookMethods = {},
		lastRemoteCaptureKey = nil,
		lastRemoteCaptureAt = 0,
		remoteDedupeWindow = tonumber(config.RemoteDedupeWindow) or 0,
		notifications = {},
		nextNotificationId = 0,
		intelligenceThreat = nil,
		intelligenceThreatRange = tonumber(config.IntelligenceThreatRange) or 350,
		intelligenceThreatKey = nil,
		macroEnabled = false,
		macroTargetKind = "Arsenal",
		macroWeaponName = "Rifle",
		macroRange = 24,
		macroCooldown = 1.5,
		macroLastFireAt = 0,
		macroLastNotifyAt = 0,
		macroLastTargetKey = "",
		macroStatus = "Macro idle",
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
		noFallDamage = false,
		antiFall = false,
		antiFallDrop = tonumber(config.AntiFallDrop) or 8,
		antiFallBacktrack = tonumber(config.AntiFallBacktrack) or 0.35,
		antiFallCooldown = tonumber(config.AntiFallCooldown) or 0.45,
		noOceanDamage = false,
		phantomStepEnabled = false,
		phantomCharacter = nil,
		phantomRealCharacter = nil,
		phantomRadius = tonumber(config.PhantomStepRadius) or 5,
		phantomSpeed = tonumber(config.PhantomStepSpeed) or 28,
		phantomCollisionSignature = nil,
		phantomCollisionRefreshAt = 0,
		localProtectionHookInstalled = false,
		localProtectionHookError = nil,
		aimbotEnabled = false,
		aimHoldActive = false,
		aimTargetPart = "nearest",
		aimLockedPlayerName = "",
		aimLockedPartName = "",
		autoFireEnabled = false,
		autoFireRange = 120,
		autoFireCooldown = 0.22,
		autoFireLastAt = 0,
		autoFireLastNotifyAt = 0,
		autoFireStatus = "Auto-fire idle",
		ghostCharacterEnabled = false,
		ghostCharacter = nil,
		ghostCharacters = {},
		selectedGhostIndex = 0,
		ghostCharacterSerial = 0,
		ghostFlyEnabled = false,
		ghostFlySpeed = 48,
		realCharacterBeforeGhost = nil,
		backpackCoreGuiSnapshot = nil,
		freeCameraEnabled = false,
		freeCameraSnapshot = nil,
		freeCameraCFrame = nil,
		freeCameraYaw = 0,
		freeCameraPitch = 0,
		freeCameraSpeed = 40,
		freeCameraFastSpeed = 86,
		cameraPerspectives = {},
		selectedCameraPerspectiveIndex = 0,
		cameraPerspectiveSerial = 0,
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

	refs.dynamicIslandDetail = NativeUi.makeLabel(dynamicIsland, "", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		Position = UDim2.fromOffset(48, 28),
		Size = UDim2.new(1, -92, 0, 14),
		TextWrapped = true,
		Visible = false,
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
		AnchorPoint = Vector2.new(0, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(14, 92),
		Size = UDim2.fromOffset(306, 252),
		ZIndex = 35,
		Parent = screenGui,
	})
	refs.alertRail = alertRail

	local function makeAlertCard(index)
		local card = makeOverlayPanel(alertRail, {
			Position = UDim2.fromOffset(0, (index - 1) * 84),
			Size = UDim2.fromOffset(306, 74),
			Visible = false,
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
			timerTrack = NativeUi.create("Frame", {
				BackgroundColor3 = NativeUi.Theme.Surface,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				Position = UDim2.new(0, 14, 1, -6),
				Size = UDim2.new(1, -28, 0, 2),
				ZIndex = 37,
				Parent = card,
			}),
		}
	end

	refs.alertCards = {
		makeAlertCard(1),
		makeAlertCard(2),
		makeAlertCard(3),
	}

	for _, card in ipairs(refs.alertCards) do
		NativeUi.corner(card.timerTrack, 999)
		card.timerFill = NativeUi.create("Frame", {
			BackgroundColor3 = NativeUi.Theme.Info,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 1, 0),
			ZIndex = 38,
			Parent = card.timerTrack,
		})
		NativeUi.corner(card.timerFill, 999)
	end
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
		Visible = false,
	})

	refs.spyClearButton = NativeUi.makeButton(refs.spySelectorPanel, "Clear Focus", {
		Position = UDim2.fromOffset(12, 40),
		Size = UDim2.fromOffset(104, 28),
		TextSize = 12,
	})

	refs.spyMemberScroll, refs.spyMemberContent = NativeUi.makeScrollList(refs.spySelectorPanel, {
		Position = UDim2.fromOffset(12, 80),
		Size = UDim2.new(1, -24, 1, -92),
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
		Visible = false,
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

	refs.spyOperatorScroll, refs.spyOperatorContent = NativeUi.makeScrollList(refs.spySupportPanel, {
		Position = UDim2.fromOffset(12, 242),
		Size = UDim2.new(1, -24, 1, -254),
		Padding = 10,
		ContentPadding = 0,
		BackgroundColor3 = NativeUi.Theme.Panel,
		ScrollBarThickness = 3,
	})
	SuiteComponents.decorateScroll(refs.spyOperatorScroll, SuiteTheme, {
		background = SuiteTheme.Colors.Panel,
		transparency = 0,
		radius = SuiteTheme.Radius.Card,
		strokeTransparency = 1,
	})

	local localCharacterSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 352),
		Parent = refs.spyOperatorContent,
	})

	addSectionTitle(localCharacterSection, "Local Character", 0)

	refs.spyGhostToggle = makeToggleRow(localCharacterSection, 28, "Spawn Local Character", "Swap control into the selected client-only body.")
	refs.spyGhostFlyToggle = makeToggleRow(localCharacterSection, 74, "Fly Local Character", "Moves the selected local body through the camera basis.")
	refs.ghostFlySpeedSlider = makeSliderRow(localCharacterSection, 122, "Fly Speed")

	refs.ghostStatusLabel = NativeUi.makeLabel(localCharacterSection, "No local characters created", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 182),
		Size = UDim2.new(1, -24, 0, 18),
	})

	refs.ghostNameBox = NativeUi.makeTextBox(localCharacterSection, "", {
		PlaceholderText = "Local character name",
		Position = UDim2.fromOffset(12, 206),
		Size = UDim2.new(1, -24, 0, 28),
		TextSize = 12,
	})

	refs.ghostNewButton = NativeUi.makeButton(localCharacterSection, "New", {
		Position = UDim2.fromOffset(12, 244),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})
	refs.ghostDestroyButton = NativeUi.makeButton(localCharacterSection, "Destroy", {
		Position = UDim2.new(0.5, 4, 0, 244),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})
	refs.ghostPrevButton = NativeUi.makeButton(localCharacterSection, "Prev", {
		Position = UDim2.fromOffset(12, 282),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})
	refs.ghostNextButton = NativeUi.makeButton(localCharacterSection, "Next", {
		Position = UDim2.new(0.5, 4, 0, 282),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})

	local freeCameraSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 386),
		Parent = refs.spyOperatorContent,
	})

	addSectionTitle(freeCameraSection, "Free Camera", 0)

	refs.spyFreeCameraToggle = makeToggleRow(freeCameraSection, 28, "Free Camera", "WASD fly, Q/E vertical, Shift fast.")
	refs.freeCameraSpeedSlider = makeSliderRow(freeCameraSection, 76, "Normal Speed")
	refs.freeCameraFastSpeedSlider = makeSliderRow(freeCameraSection, 136, "Shift Speed")

	refs.cameraPerspectiveStatusLabel = NativeUi.makeLabel(freeCameraSection, "No saved camera perspectives", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 198),
		Size = UDim2.new(1, -24, 0, 18),
	})

	refs.cameraPerspectiveNameBox = NativeUi.makeTextBox(freeCameraSection, "", {
		PlaceholderText = "Perspective name",
		Position = UDim2.fromOffset(12, 222),
		Size = UDim2.new(1, -24, 0, 28),
		TextSize = 12,
	})

	refs.cameraSaveButton = NativeUi.makeButton(freeCameraSection, "Save", {
		Position = UDim2.fromOffset(12, 260),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})
	refs.cameraRenameButton = NativeUi.makeButton(freeCameraSection, "Rename", {
		Position = UDim2.new(0.5, 4, 0, 260),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})
	refs.cameraPrevButton = NativeUi.makeButton(freeCameraSection, "Prev", {
		Position = UDim2.fromOffset(12, 298),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})
	refs.cameraNextButton = NativeUi.makeButton(freeCameraSection, "Next", {
		Position = UDim2.new(0.5, 4, 0, 298),
		Size = UDim2.new(0.5, -16, 0, 28),
		TextSize = 12,
	})
	refs.cameraDestroyButton = NativeUi.makeButton(freeCameraSection, "Destroy", {
		Position = UDim2.fromOffset(12, 336),
		Size = UDim2.new(1, -24, 0, 28),
		TextSize = 12,
	})
end

local function createRemoteWorkspace(remoteWorkspace, refs)
	refs.remoteLogPanel = NativeUi.makePanel(remoteWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(640, 100),
	})
	SuiteComponents.stylePanel(refs.remoteLogPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local callsTitle = makeSectionTitle(refs.remoteLogPanel, UI_ICON.watch .. " Calls")
	callsTitle.Position = UDim2.fromOffset(12, 12)

	refs.remoteInspectorTitleLabel = NativeUi.makeLabel(refs.remoteLogPanel, "No remote selected", {
		Font = Enum.Font.GothamBold,
		TextColor3 = NativeUi.Theme.Text,
		TextSize = 14,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(12, 40),
		Size = UDim2.new(1, -336, 0, 24),
	})

	refs.remoteInspectorMetaLabel = NativeUi.makeLabel(refs.remoteLogPanel, "Class: -    Calls: 0    Last: -", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(12, 66),
		Size = UDim2.new(1, -336, 0, 38),
	})

	refs.remoteWatcherToggle = makeToggleRow(refs.remoteLogPanel, 30, "Capture", "Log remote calls.")
	refs.remoteWatcherToggle.row.Size = UDim2.fromOffset(150, 34)
	refs.remoteWatcherToggle.row.Position = UDim2.new(1, -468, 0, 30)

	refs.scanRemotesButton = NativeUi.makeButton(refs.remoteLogPanel, UI_ICON.refresh .. " Scan", {
		Position = UDim2.new(1, -310, 0, 32),
		Size = UDim2.fromOffset(92, 30),
		TextSize = 12,
	})

	refs.copyRemotePayloadButton = NativeUi.makeButton(refs.remoteLogPanel, UI_ICON.copy .. " Payload", {
		Position = UDim2.new(1, -210, 0, 32),
		Size = UDim2.fromOffset(102, 30),
		TextSize = 12,
	})

	refs.copyRemoteReplayButton = NativeUi.makeButton(refs.remoteLogPanel, UI_ICON.copy .. " Replay", {
		Position = UDim2.new(1, -100, 0, 32),
		Size = UDim2.fromOffset(88, 30),
		TextSize = 12,
	})

	refs.remoteDiagnosticsLabel = NativeUi.makeLabel(refs.remoteLogPanel, "Diagnostics loading.", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		Position = UDim2.fromOffset(12, 108),
		Size = UDim2.new(1, -24, 0, 56),
	})

	refs.remoteLogStatusLabel = NativeUi.makeLabel(refs.remoteLogPanel, "Status: Remote Spy", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 168),
		Size = UDim2.new(1, -24, 0, 18),
	})

	refs.remoteCallsScroll, refs.remoteCallsContent = NativeUi.makeScrollList(refs.remoteLogPanel, {
		Position = UDim2.fromOffset(12, 194),
		Size = UDim2.new(1, -24, 1, -206),
		Padding = 5,
		ContentPadding = 8,
		BackgroundColor3 = NativeUi.Theme.Surface,
	})
	SuiteComponents.decorateScroll(refs.remoteCallsScroll, SuiteTheme, SuiteTheme.Variants.Control)

	refs.remoteListPanel = NativeUi.makePanel(remoteWorkspace, {
		BackgroundColor3 = NativeUi.Theme.Panel,
		Position = UDim2.fromOffset(656, 0),
		Size = UDim2.fromOffset(280, 100),
	})
	SuiteComponents.stylePanel(refs.remoteListPanel, SuiteTheme, SuiteTheme.Variants.Card)

	local listTitle = makeSectionTitle(refs.remoteListPanel, UI_ICON.remote .. " Fired Remotes")
	listTitle.Position = UDim2.fromOffset(12, 12)

	refs.remoteCountLabel = NativeUi.makeLabel(refs.remoteListPanel, "Idle", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 11,
		Position = UDim2.fromOffset(12, 42),
		Size = UDim2.new(1, -24, 0, 16),
	})

	refs.remoteSearchBox = NativeUi.makeTextBox(refs.remoteListPanel, "", {
		PlaceholderText = "Filter explorer ..",
		Position = UDim2.fromOffset(12, 68),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	refs.clearRemoteLogButton = NativeUi.makeButton(refs.remoteListPanel, UI_ICON.clear .. " Clear", {
		Position = UDim2.fromOffset(12, 108),
		Size = UDim2.new(1, -24, 0, 30),
		TextSize = 12,
	})

	refs.remoteListScroll, refs.remoteListContent = NativeUi.makeScrollList(refs.remoteListPanel, {
		Position = UDim2.fromOffset(12, 150),
		Size = UDim2.new(1, -24, 1, -162),
		Padding = 5,
		ContentPadding = 8,
		BackgroundColor3 = NativeUi.Theme.Surface,
	})
	SuiteComponents.decorateScroll(refs.remoteListScroll, SuiteTheme, SuiteTheme.Variants.Control)

	refs.remoteLogHost = NativeUi.create("Frame", {
		Visible = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.fromOffset(1, 1),
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
	local shellHeaderHeight = 48
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
		Visible = false,
	})

	local workspaceTitleLabel = NativeUi.makeLabel(workspaceHeader, "Script inspection workflow", {
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Position = UDim2.fromOffset(16, 13),
		Size = UDim2.new(1, -32, 0, 22),
	})

	local workspaceSubtitleLabel = NativeUi.makeLabel(workspaceHeader, "Three-pane bytecode, decompile, and control-flow analysis.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 49),
		Size = UDim2.new(0.56, 0, 0, 16),
		Visible = false,
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
		Visible = false,
	})

	local workspacePulseButton = NativeUi.makeButton(workspaceHeader, "!", {
		Position = UDim2.new(1, -52, 0, 20),
		Size = UDim2.fromOffset(32, 30),
		TextSize = 12,
		Palette = navButtonPalette,
		Visible = false,
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

	local mainColumns = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 470),
		Parent = mainContent,
	})
	NativeUi.list(mainColumns, 16, Enum.FillDirection.Horizontal)

	local mainSliderColumn = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Size = UDim2.new(0.5, -8, 1, 0),
		Parent = mainColumns,
	})
	NativeUi.list(mainSliderColumn, 10, Enum.FillDirection.Vertical)

	local mainToggleColumn = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Size = UDim2.new(0.5, -8, 1, 0),
		Parent = mainColumns,
	})
	NativeUi.list(mainToggleColumn, 10, Enum.FillDirection.Vertical)

	local movementSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 222),
		Parent = mainSliderColumn,
	})

	addSectionTitle(movementSection, "Movement")

	local walkSlider = makeSliderRow(movementSection, 40, "Walk Speed")
	local jumpSlider = makeSliderRow(movementSection, 100, "Jump Power")
	local hipSlider = makeSliderRow(movementSection, 160, "Hip Height")

	local automationSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 270),
		Parent = mainToggleColumn,
	})

	addSectionTitle(automationSection, "Automation")

	local infiniteJumpToggle = makeToggleRow(automationSection, 40, "Infinite Jump", "Keeps jump requests hot for the local character when enabled.")
	local noClipToggle = makeToggleRow(automationSection, 86, "NoClip", "Suppresses part collisions on the local character during stepped updates.")
	local fullBrightToggle = makeToggleRow(automationSection, 132, "FullBright", "Pins lighting into a bright analysis state and restores it when disabled.")
	local noFallDamageToggle = makeToggleRow(automationSection, 178, "No Fall Damage", "Spoofs local fall-state checks and blocks local fall damage writes when available.")
	local antiFallToggle = makeToggleRow(automationSection, 224, "Anti Fall", "Snaps back to a recent grounded step if you drop off an edge.")
	local noOceanDamageToggle = makeToggleRow(automationSection, 270, "No Ocean Damage", "Spoofs local swim/ocean checks and blocks local ocean damage writes when available.")
	local phantomStepToggle = makeToggleRow(automationSection, 316, "Phantom Step", "Control a local fake body while the real body jitters around it.")
	automationSection.Size = UDim2.new(1, 0, 0, 362)

	local worldSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 104),
		Parent = mainSliderColumn,
	})

	addSectionTitle(worldSection, "World")

	local gravitySlider = makeSliderRow(worldSection, 42, "Gravity")

	local sessionSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 114),
		Parent = mainSliderColumn,
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
		Size = UDim2.new(1, -24, 0, 58),
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
		Position = UDim2.fromOffset(0, 42),
		Size = UDim2.new(1, 0, 0, 0),
	})

	local outputViewerHost = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(12, 76),
		Size = UDim2.new(1, -24, 1, -88),
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
		Size = UDim2.new(1, 0, 0, 68),
		Parent = inspectorContent,
	})

	local intelTitle = NativeUi.makeLabel(intelCard, "Inspector", {
		Font = Enum.Font.GothamBold,
		TextSize = 16,
		Position = UDim2.fromOffset(16, 10),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local inspectorStatusLabel = NativeUi.makeLabel(intelCard, "Ready", {
		Font = Enum.Font.Code,
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 38),
		Size = UDim2.new(1, -32, 0, 16),
	})

	local inspectorInfoLabel = makeBodyLabel(intelCard, "Script mode uses getscriptbytecode. File mode stays as the offline fallback.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		Position = UDim2.fromOffset(16, 66),
		Size = UDim2.new(1, -32, 0, 0),
		Visible = false,
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
		Visible = false,
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
		Visible = false,
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
		Size = UDim2.new(1, 0, 0, 48),
		Parent = gunsContent,
	})

	local gunsTitle = NativeUi.makeLabel(gunsHeader, "Guns", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local gunsBody = makeBodyLabel(gunsHeader, "Hold Ctrl to lock the cursor onto the target nearest your mouse while the aimbot is enabled.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 42),
		Size = UDim2.new(1, -32, 0, 0),
		Visible = false,
	})

	local gunCombatSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 88),
		Parent = gunsContent,
	})

	addSectionTitle(gunCombatSection, "Aimbot")

	local aimbotToggle = makeToggleRow(gunCombatSection, 40, "Enable Aimbot", "Moves the cursor onto the target nearest the mouse while Ctrl is pressed.")

	local gunCombatBody = makeBodyLabel(gunCombatSection, "Only active while Ctrl is held. The lock reacquires if the current target drops out of view.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 88),
		Size = UDim2.new(1, -24, 0, 0),
		Visible = false,
	})

	do
		local autoFireSection = NativeUi.create("Frame", {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 168),
			Parent = gunsContent,
		})

		addSectionTitle(autoFireSection, "Auto Fire")
		refs.autoFireToggle = makeToggleRow(autoFireSection, 40, "Enable Auto Fire", "Finds an enemy in range and calls your configured fire handler.")
		refs.autoFireRangeSlider = makeSliderRow(autoFireSection, 88, "Range")
		refs.autoFireStatusLabel = NativeUi.makeLabel(autoFireSection, "Auto-fire idle", {
			Font = Enum.Font.Code,
			TextColor3 = NativeUi.Theme.TextMuted,
			TextSize = 12,
			Position = UDim2.fromOffset(12, 150),
			Size = UDim2.new(1, -24, 0, 16),
		})
	end

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
		Size = UDim2.new(1, 0, 0, 48),
		Parent = buildingContent,
	})

	local buildingTitle = NativeUi.makeLabel(buildingHeader, "Building", {
		Font = Enum.Font.GothamBold,
		TextSize = 18,
		Position = UDim2.fromOffset(16, 12),
		Size = UDim2.new(1, -32, 0, 24),
	})

	local buildingBody = makeBodyLabel(buildingHeader, "Placement, snapping, piece selection, and structure edits get their own column instead of sharing gun controls.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(16, 42),
		Size = UDim2.new(1, -32, 0, 0),
		Visible = false,
	})

	local buildPlacementSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 78),
		Parent = buildingContent,
	})

	addSectionTitle(buildPlacementSection, "Placement")

	local buildPlacementBody = makeBodyLabel(buildPlacementSection, "Waiting for the build system map.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 38),
		Size = UDim2.new(1, -24, 0, 0),
	})

	local buildEditSection = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 78),
		Parent = buildingContent,
	})

	addSectionTitle(buildEditSection, "Edit")

	local buildEditBody = makeBodyLabel(buildEditSection, "Waiting for the edit flow map.", {
		TextColor3 = NativeUi.Theme.TextMuted,
		TextSize = 12,
		Position = UDim2.fromOffset(12, 38),
		Size = UDim2.new(1, -24, 0, 0),
	})

	do
		local buildMacroSection = NativeUi.create("Frame", {
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Size = UDim2.new(1, 0, 0, 220),
			Parent = buildingContent,
		})

		addSectionTitle(buildMacroSection, "Structure Macros")

		refs.structureMacroToggle = makeToggleRow(buildMacroSection, 40, "Enable Macro", "Highlights the selected structure type and runs the configured action when you enter range.")
		refs.structureMacroTargetButton = NativeUi.makeButton(buildMacroSection, "Target: Arsenal", {
			Position = UDim2.fromOffset(12, 88),
			Size = UDim2.fromOffset(140, 30),
			TextSize = 12,
		})
		refs.structureMacroWeaponBox = NativeUi.makeTextBox(buildMacroSection, "", {
			PlaceholderText = "Weapon name",
			Position = UDim2.new(0, 164, 0, 88),
			Size = UDim2.new(1, -176, 0, 30),
			TextSize = 12,
		})
		refs.structureMacroRangeSlider = makeSliderRow(buildMacroSection, 128, "Trigger Range")
		refs.structureMacroStatusLabel = NativeUi.makeLabel(buildMacroSection, "Macro idle", {
			Font = Enum.Font.Code,
			TextColor3 = NativeUi.Theme.TextMuted,
			TextSize = 12,
			Position = UDim2.fromOffset(12, 194),
			Size = UDim2.new(1, -24, 0, 16),
		})
	end

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
		workspaceSearchButton.Position = UDim2.new(1, -314, 0, 9)
		workspacePulseButton.Position = UDim2.new(1, -52, 0, 10)

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

		local spySelectorWidth = workspaceWidth < 980 and 260 or 300
		local spySupportWidth = workspaceWidth < 980 and 280 or 360
		local spyReconWidth = workspaceWidth - spySelectorWidth - spySupportWidth - panelGap * 2
		if spyReconWidth < 340 then
			local deficit = 340 - spyReconWidth
			spySupportWidth = math.max(260, spySupportWidth - deficit)
			spyReconWidth = workspaceWidth - spySelectorWidth - spySupportWidth - panelGap * 2
		end

		refs.spySelectorPanel.Size = UDim2.fromOffset(spySelectorWidth, workspaceHeight)
		refs.spyMemberScroll.Size = UDim2.new(1, -24, 1, -92)
		refs.spyReconPanel.Position = UDim2.fromOffset(spySelectorWidth + panelGap, 0)
		refs.spyReconPanel.Size = UDim2.fromOffset(spyReconWidth, workspaceHeight)
		refs.spySupportPanel.Position = UDim2.fromOffset(spySelectorWidth + spyReconWidth + panelGap * 2, 0)
		refs.spySupportPanel.Size = UDim2.fromOffset(spySupportWidth, workspaceHeight)
		refs.spyOperatorScroll.Size = UDim2.new(1, -24, 1, -254)

		local remoteListWidth = workspaceWidth < 980 and 250 or 300
		local remoteCallsWidth = workspaceWidth - remoteListWidth - panelGap
		refs.remoteListPanel.Size = UDim2.fromOffset(remoteListWidth, workspaceHeight)
		refs.remoteListPanel.Position = UDim2.fromOffset(remoteCallsWidth + panelGap, 0)
		refs.remoteListScroll.Size = UDim2.new(1, -24, 1, -162)
		refs.remoteLogPanel.Position = UDim2.fromOffset(0, 0)
		refs.remoteLogPanel.Size = UDim2.fromOffset(remoteCallsWidth, workspaceHeight)
		refs.remoteInspectorTitleLabel.Size = UDim2.new(1, -336, 0, 24)
		refs.remoteInspectorMetaLabel.Size = UDim2.new(1, -336, 0, 38)
		refs.remoteDiagnosticsLabel.Size = UDim2.new(1, -24, 0, 56)
		refs.remoteLogStatusLabel.Size = UDim2.new(1, -24, 0, 18)
		refs.remoteCallsScroll.Size = UDim2.new(1, -24, 1, -206)
		refs.remoteLogHost.Size = UDim2.fromOffset(1, 1)
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
		outputViewerHost.Size = UDim2.new(1, -24, 1, -88)
		outputScroll.Size = UDim2.new(1, 0, 1, 0)
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
	refs.noFallDamageToggle = noFallDamageToggle
	refs.antiFallToggle = antiFallToggle
	refs.noOceanDamageToggle = noOceanDamageToggle
	refs.phantomStepToggle = phantomStepToggle
	refs.inspectorInfoLabel = inspectorInfoLabel

	return refs
end

function BytecodeViewer.start(config)
	if started then
		return
	end

	started = true
	config = type(config) == "table" and config or {}

	local state = makeState(config)
	local refs = createGui(state)
	local LuauDecompiler = loadRemoteModule("LuauDecompiler")
	local LuauControlFlow = loadRemoteModule("LuauControlFlow")
	state.antiFallDisableKeyCode = resolveAntiFallDisableKeyCode(config)
	local scope = getGlobalScope()
	local cleanupTasks = {}
	local cleaning = false
	refs.remoteSpy = RemoteSpyEngine.new({
		MaxGlobalLogs = 320,
		MaxLogsPerRemote = 160,
	})

	local function trackConnection(connection)
		table.insert(cleanupTasks, connection)
		return connection
	end

	local function trackCleanup(fn)
		table.insert(cleanupTasks, fn)
		return fn
	end

	trackCleanup(function()
		refs.remoteSpy:Destroy()
	end)

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
			color = options.color,
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
	dartApi.MacroHandlers = type(dartApi.MacroHandlers) == "table" and dartApi.MacroHandlers or {}
	dartApi.MacroRemotes = type(dartApi.MacroRemotes) == "table" and dartApi.MacroRemotes or {}
	dartApi.Macros = type(dartApi.Macros) == "table" and dartApi.Macros or {}
	dartApi.AutoFireHandlers = type(dartApi.AutoFireHandlers) == "table" and dartApi.AutoFireHandlers or {}
	dartApi.AutoFireRemotes = type(dartApi.AutoFireRemotes) == "table" and dartApi.AutoFireRemotes or {}

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

	local function setCameraSubjectToCharacter(character)
		if state.freeCameraEnabled then
			return
		end

		local camera = getCurrentCamera()
		local subject = getCharacterCameraSubject(character)
		if camera == nil or subject == nil then
			return
		end

		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = subject
	end

	local function setBackpackHiddenForGhost(hidden)
		if hidden then
			if state.backpackCoreGuiSnapshot == nil then
				local ok, enabled = pcall(function()
					return StarterGui:GetCoreGuiEnabled(Enum.CoreGuiType.Backpack)
				end)
				state.backpackCoreGuiSnapshot = ok and enabled or true
			end
			pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			return
		end

		if state.backpackCoreGuiSnapshot ~= nil then
			local shouldEnable = state.backpackCoreGuiSnapshot == true
			pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, shouldEnable)
			end)
			state.backpackCoreGuiSnapshot = nil
		end
	end

	local function stripGhostExecutables(character)
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("Tool") then
				descendant:Destroy()
			elseif descendant:IsA("LocalScript") and descendant.Name == "Animate" then
				pcall(function()
					descendant.Enabled = true
				end)
				pcall(function()
					descendant.Disabled = false
				end)
			elseif descendant:IsA("Script") or descendant:IsA("LocalScript") or descendant:IsA("ModuleScript") then
				descendant:Destroy()
			elseif descendant:IsA("BasePart") then
				descendant.Anchored = false
			end
		end
	end

	local function ensureGhostHumanoidRootPart(character)
		if character == nil then
			return nil
		end

		local root = character:FindFirstChild("HumanoidRootPart")
		if root ~= nil and root:IsA("BasePart") then
			character.PrimaryPart = root
			return root
		end

		local anchor = getCharacterRootPart(character)
		root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.Transparency = 1
		root.CanCollide = false
		root.CanTouch = false
		root.CanQuery = false
		root.Massless = true
		root.CFrame = anchor and anchor.CFrame or CFrame.new(0, 8, 0)
		root.Parent = character

		if anchor ~= nil and anchor:IsA("BasePart") then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = anchor
			weld.Parent = root
		end

		character.PrimaryPart = root
		return root
	end

	local function createFallbackGhostCharacter(characterName)
		local model = Instance.new("Model")
		model.Name = characterName or "DartLocalCharacter"

		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.Transparency = 0.45
		root.Color = NativeUi.Theme.Success
		root.Material = Enum.Material.SmoothPlastic
		root.CanCollide = true
		root.Parent = model

		local torso = Instance.new("Part")
		torso.Name = "Torso"
		torso.Size = Vector3.new(2, 2, 1)
		torso.Transparency = 0.18
		torso.Color = NativeUi.Theme.Success
		torso.Material = Enum.Material.SmoothPlastic
		torso.CanCollide = false
		torso.CFrame = root.CFrame
		torso.Parent = model

		local torsoWeld = Instance.new("WeldConstraint")
		torsoWeld.Part0 = root
		torsoWeld.Part1 = torso
		torsoWeld.Parent = torso

		local head = Instance.new("Part")
		head.Name = "Head"
		head.Shape = Enum.PartType.Ball
		head.Size = Vector3.new(1.3, 1.3, 1.3)
		head.Transparency = 0.12
		head.Color = NativeUi.Theme.Text
		head.Material = Enum.Material.SmoothPlastic
		head.CanCollide = false
		head.CFrame = root.CFrame * CFrame.new(0, 1.65, 0)
		head.Parent = model

		local headWeld = Instance.new("WeldConstraint")
		headWeld.Part0 = root
		headWeld.Part1 = head
		headWeld.Parent = head

		local humanoid = Instance.new("Humanoid")
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.WalkSpeed = 16
		humanoid.JumpPower = 50
		humanoid.Parent = model

		model.PrimaryPart = root
		return model
	end

	local function createGhostCharacter(characterName)
		local sourceCharacter = state.realCharacterBeforeGhost
		if sourceCharacter == nil or sourceCharacter.Parent == nil or sourceCharacter == state.ghostCharacter then
			sourceCharacter = getLocalCharacter()
		end
		if sourceCharacter == state.ghostCharacter then
			sourceCharacter = nil
		end

		local ghost = nil
		if sourceCharacter ~= nil and sourceCharacter ~= state.ghostCharacter then
			local previousArchivable = sourceCharacter.Archivable
			sourceCharacter.Archivable = true
			local ok, clone = pcall(function()
				return sourceCharacter:Clone()
			end)
			sourceCharacter.Archivable = previousArchivable
			if ok and clone ~= nil then
				ghost = clone
			end
		end

		if ghost == nil then
			ghost = createFallbackGhostCharacter(characterName)
		end

		ghost.Name = characterName or "DartLocalCharacter"
		stripGhostExecutables(ghost)
		ensureGhostHumanoidRootPart(ghost)

		local sourceRoot = getCharacterRootPart(sourceCharacter)
		local spawnCFrame
		if sourceRoot ~= nil then
			spawnCFrame = sourceRoot.CFrame
		else
			local camera = getCurrentCamera()
			spawnCFrame = camera and (camera.CFrame + camera.CFrame.LookVector * 6) or CFrame.new(0, 8, 0)
		end

		ghost:PivotTo(spawnCFrame)
		ghost.Parent = Workspace

		local humanoid = ghost:FindFirstChildOfClass("Humanoid")
		local sourceHumanoid = sourceCharacter and sourceCharacter:FindFirstChildOfClass("Humanoid") or nil
		if humanoid ~= nil and sourceHumanoid ~= nil then
			humanoid.WalkSpeed = sourceHumanoid.WalkSpeed
			humanoid.JumpPower = sourceHumanoid.JumpPower
			humanoid.UseJumpPower = sourceHumanoid.UseJumpPower
		end

		prepareLocalCharacterAnimation(ghost)
		return ghost
	end

	local function pruneGhostCharacters()
		for index = #state.ghostCharacters, 1, -1 do
			local slot = state.ghostCharacters[index]
			if type(slot) ~= "table" or typeof(slot.character) ~= "Instance" or slot.character.Parent == nil then
				table.remove(state.ghostCharacters, index)
				if state.selectedGhostIndex >= index then
					state.selectedGhostIndex = state.selectedGhostIndex - 1
				end
			end
		end

		if #state.ghostCharacters == 0 then
			state.selectedGhostIndex = 0
			state.ghostCharacter = nil
			return
		end

		state.selectedGhostIndex = clamp(state.selectedGhostIndex, 1, #state.ghostCharacters)
		state.ghostCharacter = state.ghostCharacters[state.selectedGhostIndex].character
	end

	local function getSelectedGhostSlot()
		pruneGhostCharacters()
		if state.selectedGhostIndex <= 0 then
			return nil
		end

		return state.ghostCharacters[state.selectedGhostIndex]
	end

	local function makeGhostCharacterName(requestedName)
		local trimmed = trimText(requestedName or "")
		if trimmed ~= "" then
			return trimmed
		end

		state.ghostCharacterSerial = state.ghostCharacterSerial + 1
		return ("Local Character %d"):format(state.ghostCharacterSerial)
	end

	local function createGhostSlot(requestedName)
		local displayName = makeGhostCharacterName(requestedName)
		local ghost = createGhostCharacter(displayName)
		local slot = {
			name = displayName,
			character = ghost,
			createdAt = os.clock(),
		}

		table.insert(state.ghostCharacters, slot)
		state.selectedGhostIndex = #state.ghostCharacters
		state.ghostCharacter = ghost
		return slot
	end

	local function ensureGhostCharacter()
		local slot = getSelectedGhostSlot()
		if slot == nil then
			slot = createGhostSlot()
		end

		state.ghostCharacter = slot.character
		return slot.character
	end

	local function restoreRealCharacter()
		local player = Players.LocalPlayer
		local realCharacter = state.realCharacterBeforeGhost
		if player == nil or realCharacter == nil or realCharacter.Parent == nil then
			return false
		end

		local ok = pcall(function()
			player.Character = realCharacter
		end)
		if not ok then
			return false
		end
		setBackpackHiddenForGhost(false)
		setCameraSubjectToCharacter(realCharacter)
		return true
	end

	local function switchToGhostSlot(slot)
		if slot == nil or typeof(slot.character) ~= "Instance" or slot.character.Parent == nil then
			return false
		end

		state.ghostCharacter = slot.character
		prepareLocalCharacterAnimation(slot.character)
		if state.realCharacterBeforeGhost ~= nil then
			preventCharacterPairCollision(slot.character, state.realCharacterBeforeGhost)
		end
		if Players.LocalPlayer ~= nil then
			local ok = pcall(function()
				Players.LocalPlayer.Character = slot.character
			end)
			if not ok then
				return false
			end
		end
		setBackpackHiddenForGhost(true)
		setCameraSubjectToCharacter(slot.character)
		return true
	end

	local function selectGhostOffset(offset)
		pruneGhostCharacters()
		local count = #state.ghostCharacters
		if count == 0 then
			return nil
		end

		state.selectedGhostIndex = ((state.selectedGhostIndex - 1 + offset) % count) + 1
		local slot = state.ghostCharacters[state.selectedGhostIndex]
		state.ghostCharacter = slot.character
		if state.ghostCharacterEnabled then
			switchToGhostSlot(slot)
		end
		return slot
	end

	local function setGhostFlyEnabled(enabled)
		state.ghostFlyEnabled = enabled == true
		local ghost = state.ghostCharacter
		local humanoid = ghost and ghost:FindFirstChildOfClass("Humanoid") or nil
		if humanoid ~= nil and not state.ghostFlyEnabled then
			humanoid.PlatformStand = false
		end
	end

	local function setGhostCharacterEnabled(enabled)
		enabled = enabled == true
		if enabled == state.ghostCharacterEnabled then
			return
		end

		if enabled then
			local currentCharacter = getLocalCharacter()
			if currentCharacter ~= nil and currentCharacter ~= state.ghostCharacter then
				state.realCharacterBeforeGhost = currentCharacter
			end

			local ghost = ensureGhostCharacter()
			if ghost == nil then
				emitNotification("critical", "Local character failed", "Could not create a client-only character.", { duration = 3 })
				return
			end

			state.ghostCharacterEnabled = true
			if not switchToGhostSlot(getSelectedGhostSlot() or { character = ghost }) then
				state.ghostCharacterEnabled = false
				emitNotification("critical", "Local character failed", "Could not swap control to the local character.", { duration = 3 })
				return
			end
			emitNotification("success", "Local character", "Swapped to a client-only operator body.", { duration = 2.5 })
			return
		end

		state.ghostCharacterEnabled = false
		setGhostFlyEnabled(false)
		local restored = restoreRealCharacter()
		if state.ghostCharacter ~= nil then
			if state.freeCameraSnapshot ~= nil and typeof(state.freeCameraSnapshot.subject) == "Instance" and state.freeCameraSnapshot.subject:IsDescendantOf(state.ghostCharacter) then
				state.freeCameraSnapshot.subject = getCharacterCameraSubject(state.realCharacterBeforeGhost)
			end
		end

		if restored then
			emitNotification("info", "Local character", "Restored real character control. Local bodies remain available.", { duration = 2.5 })
		else
			setBackpackHiddenForGhost(false)
			emitNotification("warning", "Local character", "No real character was available to restore.", { duration = 3 })
		end
	end

	local function createNewGhostCharacterFromInput()
		local name = refs.ghostNameBox and refs.ghostNameBox.Text or ""
		local selectedSlot = getSelectedGhostSlot()
		if selectedSlot ~= nil and trimText(name) == selectedSlot.name then
			name = ""
		end
		local slot = createGhostSlot(name)
		if state.ghostCharacterEnabled then
			switchToGhostSlot(slot)
		end
		emitNotification("success", "Local character", ("Created %s."):format(slot.name), { duration = 2.5 })
		return slot
	end

	local function destroySelectedGhostCharacter()
		local slot = getSelectedGhostSlot()
		if slot == nil then
			return
		end

		local destroyedCurrent = slot.character == state.ghostCharacter
		local character = slot.character
		table.remove(state.ghostCharacters, state.selectedGhostIndex)
		if typeof(character) == "Instance" then
			clearLocalCharacterAnimation(character)
			clearCharacterNoCollisionLinks(character)
			character:Destroy()
		end

		if #state.ghostCharacters == 0 then
			state.selectedGhostIndex = 0
			state.ghostCharacter = nil
			if state.ghostCharacterEnabled then
				setGhostCharacterEnabled(false)
			end
			emitNotification("info", "Local character", "Destroyed the last local character.", { duration = 2.5 })
			return
		end

		state.selectedGhostIndex = clamp(state.selectedGhostIndex, 1, #state.ghostCharacters)
		local nextSlot = state.ghostCharacters[state.selectedGhostIndex]
		state.ghostCharacter = nextSlot.character
		if state.ghostCharacterEnabled and destroyedCurrent then
			switchToGhostSlot(nextSlot)
		end
		emitNotification("info", "Local character", ("Destroyed %s."):format(slot.name), { duration = 2.5 })
	end

	local function destroyAllGhostCharacters()
		for _, slot in ipairs(state.ghostCharacters) do
			if type(slot) == "table" and typeof(slot.character) == "Instance" then
				clearLocalCharacterAnimation(slot.character)
				clearCharacterNoCollisionLinks(slot.character)
				slot.character:Destroy()
			end
		end
		state.ghostCharacters = {}
		state.selectedGhostIndex = 0
		state.ghostCharacter = nil
	end

	local function bindFreeCameraInputSink()
		ContextActionService:BindActionAtPriority(
			FREE_CAMERA_ACTION_NAME,
			function()
				return Enum.ContextActionResult.Sink
			end,
			false,
			3000,
			Enum.KeyCode.W,
			Enum.KeyCode.A,
			Enum.KeyCode.S,
			Enum.KeyCode.D,
			Enum.KeyCode.Q,
			Enum.KeyCode.E,
			Enum.KeyCode.Space
		)
	end

	local function unbindFreeCameraInputSink()
		ContextActionService:UnbindAction(FREE_CAMERA_ACTION_NAME)
	end

	local function setFreeCameraEnabled(enabled)
		enabled = enabled == true
		if enabled == state.freeCameraEnabled then
			return
		end

		local camera = getCurrentCamera()
		if camera == nil then
			emitNotification("critical", "Free camera failed", "Workspace.CurrentCamera is not available.", { duration = 3 })
			return
		end

		if enabled then
			state.freeCameraSnapshot = {
				type = camera.CameraType,
				subject = camera.CameraSubject,
				cframe = camera.CFrame,
				fieldOfView = camera.FieldOfView,
				mouseBehavior = UserInputService.MouseBehavior,
				mouseIconEnabled = UserInputService.MouseIconEnabled,
			}

			local pitch, yaw = camera.CFrame:ToOrientation()
			state.freeCameraPitch = pitch
			state.freeCameraYaw = yaw
			state.freeCameraCFrame = camera.CFrame
			state.freeCameraEnabled = true
			camera.CameraType = Enum.CameraType.Scriptable
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			UserInputService.MouseIconEnabled = false
			bindFreeCameraInputSink()
			emitNotification("success", "Free camera", "WASD fly, Q/E vertical, Shift fast, Ctrl slow.", { duration = 3 })
			return
		end

		state.freeCameraEnabled = false
		unbindFreeCameraInputSink()

		local snapshot = state.freeCameraSnapshot
		state.freeCameraSnapshot = nil
		state.freeCameraCFrame = nil

		if snapshot ~= nil then
			camera.CameraType = snapshot.type or Enum.CameraType.Custom
			camera.CFrame = snapshot.cframe or camera.CFrame
			camera.FieldOfView = snapshot.fieldOfView or camera.FieldOfView

			local subject = snapshot.subject
			if typeof(subject) ~= "Instance" or subject.Parent == nil then
				local fallbackCharacter = state.ghostCharacterEnabled and state.ghostCharacter or state.realCharacterBeforeGhost or getLocalCharacter()
				subject = getCharacterCameraSubject(fallbackCharacter)
			end
			if subject ~= nil then
				camera.CameraSubject = subject
			end

			UserInputService.MouseBehavior = snapshot.mouseBehavior or Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = snapshot.mouseIconEnabled ~= false
		else
			camera.CameraType = Enum.CameraType.Custom
			setCameraSubjectToCharacter(state.ghostCharacterEnabled and state.ghostCharacter or getLocalCharacter())
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			UserInputService.MouseIconEnabled = true
		end

		emitNotification("info", "Free camera", "Camera restored.", { duration = 2.5 })
	end

	local function setFreeCameraCFrame(cframe)
		if typeof(cframe) ~= "CFrame" then
			return
		end

		local pitch, yaw = cframe:ToOrientation()
		state.freeCameraPitch = pitch
		state.freeCameraYaw = yaw
		state.freeCameraCFrame = cframe

		local camera = getCurrentCamera()
		if camera ~= nil and state.freeCameraEnabled then
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = cframe
		end
	end

	local function getSelectedCameraPerspective()
		if #state.cameraPerspectives == 0 then
			state.selectedCameraPerspectiveIndex = 0
			return nil
		end

		state.selectedCameraPerspectiveIndex = clamp(state.selectedCameraPerspectiveIndex, 1, #state.cameraPerspectives)
		return state.cameraPerspectives[state.selectedCameraPerspectiveIndex]
	end

	local function makeCameraPerspectiveName(requestedName)
		local trimmed = trimText(requestedName or "")
		if trimmed ~= "" then
			return trimmed
		end

		state.cameraPerspectiveSerial = state.cameraPerspectiveSerial + 1
		return ("Perspective %d"):format(state.cameraPerspectiveSerial)
	end

	local function saveCameraPerspective()
		local camera = getCurrentCamera()
		if camera == nil then
			return
		end

		local requestedName = refs.cameraPerspectiveNameBox and refs.cameraPerspectiveNameBox.Text or ""
		local selectedPerspective = getSelectedCameraPerspective()
		if selectedPerspective ~= nil and trimText(requestedName) == selectedPerspective.name then
			requestedName = ""
		end

		local perspective = {
			name = makeCameraPerspectiveName(requestedName),
			cframe = state.freeCameraCFrame or camera.CFrame,
			fieldOfView = camera.FieldOfView,
			createdAt = os.clock(),
		}

		table.insert(state.cameraPerspectives, perspective)
		state.selectedCameraPerspectiveIndex = #state.cameraPerspectives
		emitNotification("success", "Camera perspective", ("Saved %s."):format(perspective.name), { duration = 2.5 })
	end

	local function applyCameraPerspective(index)
		if #state.cameraPerspectives == 0 then
			return
		end

		state.selectedCameraPerspectiveIndex = clamp(index, 1, #state.cameraPerspectives)
		local perspective = getSelectedCameraPerspective()
		if perspective == nil then
			return
		end

		if not state.freeCameraEnabled then
			setFreeCameraEnabled(true)
		end

		local camera = getCurrentCamera()
		if camera ~= nil and type(perspective.fieldOfView) == "number" then
			camera.FieldOfView = perspective.fieldOfView
		end
		setFreeCameraCFrame(perspective.cframe)
		emitNotification("info", "Camera perspective", ("Loaded %s."):format(perspective.name), { duration = 2 })
	end

	local function selectCameraPerspectiveOffset(offset)
		if #state.cameraPerspectives == 0 then
			return
		end

		local nextIndex = ((state.selectedCameraPerspectiveIndex - 1 + offset) % #state.cameraPerspectives) + 1
		applyCameraPerspective(nextIndex)
	end

	local function renameSelectedCameraPerspective()
		local perspective = getSelectedCameraPerspective()
		if perspective == nil then
			return
		end

		local name = trimText(refs.cameraPerspectiveNameBox and refs.cameraPerspectiveNameBox.Text or "")
		if name == "" then
			return
		end

		perspective.name = name
		emitNotification("info", "Camera perspective", ("Renamed to %s."):format(name), { duration = 2 })
	end

	local function destroySelectedCameraPerspective()
		local perspective = getSelectedCameraPerspective()
		if perspective == nil then
			return
		end

		local name = perspective.name
		table.remove(state.cameraPerspectives, state.selectedCameraPerspectiveIndex)
		if #state.cameraPerspectives == 0 then
			state.selectedCameraPerspectiveIndex = 0
		else
			state.selectedCameraPerspectiveIndex = clamp(state.selectedCameraPerspectiveIndex, 1, #state.cameraPerspectives)
		end
		emitNotification("info", "Camera perspective", ("Destroyed %s."):format(name), { duration = 2 })
	end

	local function getFlatCameraVectors(cameraCFrame)
		local look = Vector3.new(cameraCFrame.LookVector.X, 0, cameraCFrame.LookVector.Z)
		local right = Vector3.new(cameraCFrame.RightVector.X, 0, cameraCFrame.RightVector.Z)
		if look.Magnitude < 0.01 then
			look = Vector3.new(0, 0, -1)
		else
			look = look.Unit
		end
		if right.Magnitude < 0.01 then
			right = Vector3.new(1, 0, 0)
		else
			right = right.Unit
		end

		return look, right
	end

	local function getOperatorMoveVector(flatOnly)
		local camera = getCurrentCamera()
		local basis = camera and camera.CFrame or CFrame.new()
		local look = basis.LookVector
		local right = basis.RightVector
		local up = Vector3.new(0, 1, 0)
		if flatOnly then
			look, right = getFlatCameraVectors(basis)
		end

		local move = Vector3.zero
		if UserInputService:IsKeyDown(Enum.KeyCode.W) then
			move = move + look
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.S) then
			move = move - look
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.D) then
			move = move + right
		end
		if UserInputService:IsKeyDown(Enum.KeyCode.A) then
			move = move - right
		end
		if not flatOnly then
			if UserInputService:IsKeyDown(Enum.KeyCode.E) or UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				move = move + up
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
				move = move - up
			end
		end

		if move.Magnitude > 1 then
			return move.Unit
		end

		return move
	end

	local function updateGhostFly(deltaTime)
		local ghost = state.ghostCharacter
		if ghost == nil or ghost.Parent == nil then
			return
		end

		local root = getCharacterRootPart(ghost)
		local humanoid = ghost:FindFirstChildOfClass("Humanoid")
		if root == nil or humanoid == nil then
			return
		end

		humanoid.PlatformStand = true
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero

		local move = getOperatorMoveVector(false)
		local speed = state.ghostFlySpeed
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
			speed = speed * 1.8
		end

		local nextPosition = root.Position + move * speed * deltaTime
		local camera = getCurrentCamera()
		local look = camera and camera.CFrame.LookVector or root.CFrame.LookVector
		if look.Magnitude < 0.01 then
			look = Vector3.new(0, 0, -1)
		end
		ghost:PivotTo(CFrame.lookAt(nextPosition, nextPosition + look.Unit))
		updateLocalCharacterAnimation(ghost, Vector3.zero)
	end

	local function updateGhostMovement(deltaTime)
		if not state.ghostCharacterEnabled or state.freeCameraEnabled or UserInputService:GetFocusedTextBox() ~= nil then
			return
		end

		local ghost = state.ghostCharacter
		if ghost == nil or ghost.Parent == nil then
			return
		end

		local humanoid = ghost:FindFirstChildOfClass("Humanoid")
		if humanoid == nil then
			return
		end

		if state.ghostFlyEnabled then
			updateGhostFly(deltaTime)
			return
		end

		humanoid.PlatformStand = false
		local move = getOperatorMoveVector(true)
		humanoid:Move(move, false)
		updateLocalCharacterAnimation(ghost, move)
		if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
			humanoid.Jump = true
		end
	end

	refs.destroyPhantomCharacter = function()
		if state.phantomCharacter ~= nil then
			clearLocalCharacterAnimation(state.phantomCharacter)
			clearCharacterNoCollisionLinks(state.phantomCharacter)
			pcall(function()
				state.phantomCharacter:Destroy()
			end)
		end
		state.phantomCharacter = nil
		state.phantomCollisionSignature = nil
		state.phantomCollisionRefreshAt = 0
	end

	refs.setPhantomStepEnabled = function(enabled)
		enabled = enabled == true
		if enabled == state.phantomStepEnabled then
			return
		end

		local player = Players.LocalPlayer
		if player == nil then
			emitNotification("critical", "Phantom Step", "LocalPlayer is unavailable.", { duration = 3 })
			return
		end

		if enabled then
			local realCharacter = getLocalCharacter()
			local realRoot = getCharacterRootPart(realCharacter)
			if realCharacter == nil or realRoot == nil then
				emitNotification("critical", "Phantom Step", "Real character root was not found.", { duration = 3 })
				return
			end

			state.phantomRealCharacter = realCharacter
			local fakeCharacter = createGhostCharacter("Phantom Step")
			if fakeCharacter == nil then
				state.phantomRealCharacter = nil
				emitNotification("critical", "Phantom Step", "Could not create the fake local body.", { duration = 3 })
				return
			end

			state.phantomCharacter = fakeCharacter
			prepareLocalCharacterAnimation(fakeCharacter)
			preventCharacterPairCollision(fakeCharacter, realCharacter)
			state.phantomCollisionSignature = getCharacterCollisionSignature(fakeCharacter, realCharacter)
			state.phantomCollisionRefreshAt = os.clock() + 1
			local ok = pcall(function()
				player.Character = fakeCharacter
			end)
			if not ok then
				refs.destroyPhantomCharacter()
				state.phantomRealCharacter = nil
				emitNotification("critical", "Phantom Step", "Could not swap control to the fake body.", { duration = 3 })
				return
			end

			setCameraSubjectToCharacter(fakeCharacter)
			state.phantomStepEnabled = true
			setMainStatus("Phantom Step enabled", NativeUi.Theme.Success)
			emitNotification("success", "Phantom Step", "Fake body active. Real body remains visible for testing.", { duration = 2.5 })
			return
		end

		state.phantomStepEnabled = false
		local fakeCharacter = state.phantomCharacter
		local fakeRoot = getCharacterRootPart(fakeCharacter)
		local realCharacter = state.phantomRealCharacter
		if realCharacter ~= nil and realCharacter.Parent ~= nil then
			if fakeRoot ~= nil then
				pcall(function()
					realCharacter:PivotTo(fakeRoot.CFrame)
				end)
			end
			pcall(function()
				player.Character = realCharacter
			end)
			setCameraSubjectToCharacter(realCharacter)
		end

		refs.destroyPhantomCharacter()
		state.phantomRealCharacter = nil
		setMainStatus("Phantom Step disabled", NativeUi.Theme.TextMuted)
	end

	refs.updatePhantomStep = function(deltaTime)
		if not state.phantomStepEnabled then
			return
		end

		local fakeCharacter = state.phantomCharacter
		local realCharacter = state.phantomRealCharacter
		if fakeCharacter == nil or fakeCharacter.Parent == nil or realCharacter == nil or realCharacter.Parent == nil then
			refs.setPhantomStepEnabled(false)
			return
		end

		if not state.freeCameraEnabled and UserInputService:GetFocusedTextBox() == nil then
			local humanoid = fakeCharacter:FindFirstChildOfClass("Humanoid")
			if humanoid ~= nil then
				humanoid.PlatformStand = false
				local move = getOperatorMoveVector(true)
				humanoid:Move(move, false)
				updateLocalCharacterAnimation(fakeCharacter, move)
				if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
					humanoid.Jump = true
				end
			end
		end

		local fakeRoot = getCharacterRootPart(fakeCharacter)
		local realRoot = getCharacterRootPart(realCharacter)
		if fakeRoot == nil or realRoot == nil then
			return
		end

		local now = os.clock()
		if now >= state.phantomCollisionRefreshAt then
			local signature = getCharacterCollisionSignature(fakeCharacter, realCharacter)
			if signature ~= state.phantomCollisionSignature then
				preventCharacterPairCollision(fakeCharacter, realCharacter)
				state.phantomCollisionSignature = signature
			end
			state.phantomCollisionRefreshAt = now + 1
		end

		local t = now * state.phantomSpeed
		local radius = state.phantomRadius
		local offset = Vector3.new(
			math.cos(t * 1.11) * radius,
			math.sin(t * 1.73) * math.min(1.25, radius * 0.25),
			math.sin(t * 0.97) * radius
		)
		local targetPosition = fakeRoot.Position + offset
		local look = fakeRoot.CFrame.LookVector
		if look.Magnitude < 0.01 then
			look = Vector3.new(0, 0, -1)
		end

		pcall(function()
			realRoot.AssemblyLinearVelocity = Vector3.zero
			realRoot.AssemblyAngularVelocity = Vector3.zero
			realCharacter:PivotTo(CFrame.lookAt(targetPosition, targetPosition + look.Unit))
		end)
	end

	local function updateFreeCamera(deltaTime)
		if not state.freeCameraEnabled then
			return
		end

		local camera = getCurrentCamera()
		if camera == nil then
			return
		end

		local mouseDelta = UserInputService:GetMouseDelta()
		state.freeCameraYaw = state.freeCameraYaw - mouseDelta.X * 0.0024
		state.freeCameraPitch = clamp(state.freeCameraPitch - mouseDelta.Y * 0.0024, -1.45, 1.45)

		local rotation = CFrame.fromOrientation(state.freeCameraPitch, state.freeCameraYaw, 0)
		local move = Vector3.zero
		if UserInputService:GetFocusedTextBox() == nil then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then
				move = move + Vector3.new(0, 0, -1)
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then
				move = move + Vector3.new(0, 0, 1)
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then
				move = move + Vector3.new(1, 0, 0)
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then
				move = move + Vector3.new(-1, 0, 0)
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.E) or UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				move = move + Vector3.new(0, 1, 0)
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.Q) then
				move = move + Vector3.new(0, -1, 0)
			end
		end

		if move.Magnitude > 1 then
			move = move.Unit
		end

		local speed = state.freeCameraSpeed
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
			speed = state.freeCameraFastSpeed
		elseif UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.RightControl) then
			speed = math.max(6, state.freeCameraSpeed * 0.4)
		end

		local currentCFrame = state.freeCameraCFrame or camera.CFrame
		local nextPosition = currentCFrame.Position + rotation:VectorToWorldSpace(move) * speed * deltaTime
		state.freeCameraCFrame = CFrame.new(nextPosition) * rotation
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = state.freeCameraCFrame
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

	local intelligencePlayerConnections = {}
	local intelligencePlayerWeapons = {}
	local intelligenceKnownStructures = setmetatable({}, { __mode = "k" })
	local intelligenceStructureConnections = setmetatable({}, { __mode = "k" })
	local intelligenceNotificationTimes = {}
	local intelligenceFirstStructureSeen = {}
	local intelligenceHeartbeatAccumulator = 0

	local function getPlayerTeamColor(player)
		if player == nil then
			return NativeUi.Theme.Warning
		end

		if player.Team ~= nil and player.Team.TeamColor ~= nil then
			return player.Team.TeamColor.Color
		elseif player.TeamColor ~= nil then
			return player.TeamColor.Color
		end

		return nil
	end

	local function getPlayerTeamColorText(player)
		if player == nil then
			return "unknown"
		end

		if player.TeamColor ~= nil then
			return player.TeamColor.Name
		end

		return "unknown"
	end

	local function isEnemyPlayer(player)
		local localPlayer = Players.LocalPlayer
		if player == nil or player == localPlayer then
			return false
		end

		local localTeamIndex = localPlayer and localPlayer:GetAttribute("TeamIndex") or nil
		local playerTeamIndex = player:GetAttribute("TeamIndex")
		if localTeamIndex ~= nil and playerTeamIndex ~= nil then
			return localTeamIndex ~= playerTeamIndex
		end

		if localPlayer ~= nil and localPlayer.Team ~= nil and player.Team ~= nil then
			return player.Team ~= localPlayer.Team
		end

		if localPlayer ~= nil and localPlayer.Neutral ~= true and player.Neutral ~= true and localPlayer.TeamColor ~= nil and player.TeamColor ~= nil then
			return player.TeamColor ~= localPlayer.TeamColor
		end

		local localTeamAttr = localPlayer and localPlayer:GetAttribute("Team") or nil
		local playerTeamAttr = player:GetAttribute("Team")
		if localTeamAttr ~= nil and playerTeamAttr ~= nil then
			return tostring(localTeamAttr) ~= tostring(playerTeamAttr)
		end

		return true
	end

	local function disconnectConnectionList(connectionList)
		for _, connection in ipairs(connectionList or {}) do
			pcall(function()
				connection:Disconnect()
			end)
		end
	end

	local function emitIntelligenceNotification(key, cooldown, level, title, detail, color, options)
		local now = os.clock()
		local last = intelligenceNotificationTimes[key]
		if last ~= nil and now - last < cooldown then
			return nil
		end

		intelligenceNotificationTimes[key] = now
		options = options or {}
		options.color = color or options.color
		options.duration = options.duration or 5
		options.priority = options.priority or notificationPriority(level)
		return emitNotification(level, title, detail, options)
	end

	local function isWeaponTool(instance)
		return typeof(instance) == "Instance" and instance:IsA("Tool") and instance:GetAttribute("DartIgnoreIntelligence") ~= true
	end

	local function getWeaponName(tool)
		if not isWeaponTool(tool) then
			return nil
		end

		local displayName = tool:GetAttribute("WeaponName")
			or tool:GetAttribute("DisplayName")
			or tool:GetAttribute("ItemName")
			or tool:GetAttribute("Name")
			or tool.Name

		displayName = trimText(tostring(displayName or ""))
		if displayName == "" then
			return "weapon"
		end

		return displayName
	end

	local function getPlayerWeaponInventory(player)
		local inventory = intelligencePlayerWeapons[player]
		if inventory == nil then
			inventory = {}
			intelligencePlayerWeapons[player] = inventory
		end

		return inventory
	end

	local function getPlayerWeaponContainers(player)
		local containers = {}
		if player == nil then
			return containers
		end

		if player.Character ~= nil then
			table.insert(containers, player.Character)
		end

		local backpack = player:FindFirstChildOfClass("Backpack") or player:FindFirstChild("Backpack")
		if backpack ~= nil then
			table.insert(containers, backpack)
		end

		return containers
	end

	local function playerHasWeaponNamed(player, weaponName)
		for _, container in ipairs(getPlayerWeaponContainers(player)) do
			for _, child in ipairs(container:GetChildren()) do
				if getWeaponName(child) == weaponName then
					return true
				end
			end
		end

		return false
	end

	local function rememberPlayerWeapon(player, tool, silent)
		if not isWeaponTool(tool) then
			return
		end

		local weaponName = getWeaponName(tool)
		local inventory = getPlayerWeaponInventory(player)
		local alreadyKnown = inventory[weaponName] == true
		inventory[weaponName] = true
		inventory.lastWeapon = weaponName

		if silent or alreadyKnown or not isEnemyPlayer(player) then
			return
		end

		local teamText = getPlayerTeamText(player)
		local teamColorText = getPlayerTeamColorText(player)
		emitIntelligenceNotification(
			("weapon:%s:%s"):format(player.UserId, weaponName),
			5,
			"warning",
			("Weapon Collected by %s (%s)"):format(teamText, teamColorText),
			("%s has collected a %s."):format(player.Name, weaponName),
			getPlayerTeamColor(player),
			{ priority = 44, duration = 5 }
		)
	end

	local function forgetPlayerWeaponIfGone(player, weaponName)
		task.defer(function()
			local inventory = intelligencePlayerWeapons[player]
			if inventory == nil or playerHasWeaponNamed(player, weaponName) then
				return
			end

			inventory[weaponName] = nil
			if inventory.lastWeapon == weaponName then
				inventory.lastWeapon = nil
			end
		end)
	end

	local function getKnownPlayerWeapon(player)
		local character = player and player.Character or nil
		if character ~= nil then
			for _, child in ipairs(character:GetChildren()) do
				local weaponName = getWeaponName(child)
				if weaponName ~= nil then
					return weaponName
				end
			end
		end

		local inventory = intelligencePlayerWeapons[player]
		if inventory == nil then
			return nil
		end

		if inventory.lastWeapon ~= nil and inventory[inventory.lastWeapon] == true then
			return inventory.lastWeapon
		end

		for weaponName, owned in pairs(inventory) do
			if owned == true and weaponName ~= "lastWeapon" then
				return weaponName
			end
		end

		return nil
	end

	local function bindIntelligenceContainer(player, container, silent)
		if typeof(container) ~= "Instance" then
			return
		end

		local connectionList = intelligencePlayerConnections[player]
		if connectionList == nil then
			connectionList = {}
			intelligencePlayerConnections[player] = connectionList
		end

		for _, child in ipairs(container:GetChildren()) do
			rememberPlayerWeapon(player, child, silent)
		end

		table.insert(connectionList, container.ChildAdded:Connect(function(child)
			rememberPlayerWeapon(player, child, false)
			if updateSuiteOverlays ~= nil then
				updateSuiteOverlays()
			end
		end))
		table.insert(connectionList, container.ChildRemoved:Connect(function(child)
			local weaponName = getWeaponName(child)
			if weaponName ~= nil then
				forgetPlayerWeaponIfGone(player, weaponName)
			end
		end))
	end

	local function unbindIntelligencePlayer(player)
		disconnectConnectionList(intelligencePlayerConnections[player])
		intelligencePlayerConnections[player] = nil
		intelligencePlayerWeapons[player] = nil
	end

	local function bindIntelligencePlayer(player)
		if player == nil or intelligencePlayerConnections[player] ~= nil then
			return
		end

		local connectionList = {}
		intelligencePlayerConnections[player] = connectionList

		bindIntelligenceContainer(player, player:FindFirstChildOfClass("Backpack") or player:FindFirstChild("Backpack"), true)
		bindIntelligenceContainer(player, player.Character, true)

		table.insert(connectionList, player.ChildAdded:Connect(function(child)
			if child:IsA("Backpack") then
				bindIntelligenceContainer(player, child, false)
			end
		end))
		table.insert(connectionList, player.CharacterAdded:Connect(function(character)
			bindIntelligenceContainer(player, character, true)
		end))
	end

	local function updateIntelligenceThreat()
		local localPosition = getLocalThreatPosition()
		if localPosition == nil then
			state.intelligenceThreat = nil
			return
		end

		local nearestThreat = nil
		for _, player in ipairs(Players:GetPlayers()) do
			if isEnemyPlayer(player) then
				local weaponName = getKnownPlayerWeapon(player)
				local targetPosition = getPlayerPosition(player)
				if targetPosition ~= nil then
					local distance = (targetPosition - localPosition).Magnitude
					if distance <= state.intelligenceThreatRange and (nearestThreat == nil or distance < nearestThreat.distance) then
						nearestThreat = {
							player = player,
							playerName = player.Name,
							playerUserId = player.UserId,
							weaponName = weaponName,
							weaponKnown = weaponName ~= nil,
							distance = distance,
							teamText = getPlayerTeamText(player),
							teamColor = getPlayerTeamColor(player),
						}
					end
				end
			end
		end

		state.intelligenceThreat = nearestThreat
		if nearestThreat ~= nil then
			local distance = math.floor(nearestThreat.distance + 0.5)
			local isCritical = distance <= 60
			local proximityBand = isCritical and "critical" or "near"
			local weaponText = nearestThreat.weaponKnown and (" with " .. nearestThreat.weaponName) or ""
			local detail = ("%s is %dm away%s."):format(nearestThreat.playerName, distance, weaponText)
			emitIntelligenceNotification(
				("proximity:%s:%s"):format(tostring(nearestThreat.playerUserId or nearestThreat.playerName), proximityBand),
				isCritical and 10 or 22,
				isCritical and "critical" or "warning",
				isCritical and "Enemy very close" or "Enemy nearby",
				detail,
				nearestThreat.teamColor,
				{ priority = isCritical and 48 or 36, duration = isCritical and 4.5 or 4 }
			)
		end
	end

	refs.getIntelligenceThreatSignal = function()
		local threat = state.intelligenceThreat
		if threat == nil then
			return nil
		end

		local distance = math.floor(threat.distance + 0.5)
		local detail = threat.weaponKnown
			and ("%s with %s - %s"):format(threat.playerName, threat.weaponName, threat.teamText)
			or ("%s - %s"):format(threat.playerName, threat.teamText)
		return {
			title = "Enemy Close",
			detail = detail,
			badge = ("%dm"):format(distance),
			level = distance <= 60 and "critical" or "warning",
			color = threat.teamColor,
			width = 430,
			height = 62,
		}
	end

	local localProtectionBridge = scope.__DartLocalProtectionBridge
	if type(localProtectionBridge) ~= "table" then
		localProtectionBridge = {}
		scope.__DartLocalProtectionBridge = localProtectionBridge
	end

	local function readDebugSource(level)
		local debugLibrary = debug
		if type(debugLibrary) ~= "table" then
			return nil
		end

		if type(debugLibrary.info) == "function" then
			local ok, source = pcall(debugLibrary.info, level, "s")
			if ok and type(source) == "string" then
				return source
			end
		end

		if type(debugLibrary.getinfo) == "function" then
			local ok, info = pcall(debugLibrary.getinfo, level, "S")
			if ok and type(info) == "table" then
				return info.source or info.short_src
			end
		end

		return nil
	end

	local function callerMatchesProtectionSource(kind)
		local terms = kind == "ocean"
			and { "ocean", "oceandamage", "ocean damage", "waterdamage", "water damage" }
			or { "fall", "falldamage", "fall damage", "falldamagescript", "fall_damage" }
		local sawUsefulSource = false

		for level = 3, 12 do
			local source = readDebugSource(level)
			if type(source) == "string" and source ~= "" and source ~= "[C]" then
				local normalized = string.lower(source)
				local isBridgeSource = string.find(normalized, "irisbytecodeviewer", 1, true) ~= nil
					or string.find(normalized, "coregui", 1, true) ~= nil
					or string.find(normalized, "loadstring", 1, true) ~= nil
				for _, term in ipairs(terms) do
					if string.find(normalized, term, 1, true) ~= nil then
						return true, true
					end
				end
				sawUsefulSource = sawUsefulSource or not isBridgeSource
			end
		end

		return false, sawUsefulSource
	end

	local function shouldUseProtectionForCaller(kind)
		local matched, sawUsefulSource = callerMatchesProtectionSource(kind)
		if matched then
			return true
		end

		-- If the executor does not expose script source info, fall back to a local-humanoid-only guard.
		return not sawUsefulSource
	end

	local function isProtectedLocalHumanoid(humanoid)
		return humanoid ~= nil and humanoid == getLocalHumanoid()
	end

	local function spoofProtectedHumanoidState(humanoid, humanoidState)
		if not isProtectedLocalHumanoid(humanoid) then
			return humanoidState
		end

		if state.noFallDamage and humanoidState == Enum.HumanoidStateType.Landed and shouldUseProtectionForCaller("fall") then
			return Enum.HumanoidStateType.Running
		end

		if state.noOceanDamage and humanoidState == Enum.HumanoidStateType.Swimming and shouldUseProtectionForCaller("ocean") then
			return Enum.HumanoidStateType.Running
		end

		return humanoidState
	end

	local function shouldBlockProtectedHealthWrite(humanoid, value)
		if not isProtectedLocalHumanoid(humanoid) or type(value) ~= "number" then
			return false
		end

		local ok, currentHealth = pcall(function()
			return humanoid.Health
		end)
		if not ok or type(currentHealth) ~= "number" or value >= currentHealth then
			return false
		end

		if state.noFallDamage and shouldUseProtectionForCaller("fall") then
			return true
		end

		if state.noOceanDamage and shouldUseProtectionForCaller("ocean") then
			return true
		end

		return false
	end

	local function wrapProtectedStateSignal(humanoid, signal)
		if not isProtectedLocalHumanoid(humanoid) or signal == nil then
			return signal
		end

		local proxy = {}

		local function wrapCallback(callback)
			return function(oldState, newState, ...)
				return callback(
					spoofProtectedHumanoidState(humanoid, oldState),
					spoofProtectedHumanoidState(humanoid, newState),
					...
				)
			end
		end

		function proxy:Connect(callback)
			return signal:Connect(wrapCallback(callback))
		end

		function proxy:connect(callback)
			return self:Connect(callback)
		end

		function proxy:Once(callback)
			if type(signal.Once) == "function" then
				return signal:Once(wrapCallback(callback))
			end

			local connection
			connection = signal:Connect(function(...)
				if connection ~= nil then
					connection:Disconnect()
				end
				return wrapCallback(callback)(...)
			end)
			return connection
		end

		function proxy:Wait()
			local oldState, newState = signal:Wait()
			return spoofProtectedHumanoidState(humanoid, oldState), spoofProtectedHumanoidState(humanoid, newState)
		end

		return proxy
	end

	local function syncLocalProtectionBridge()
		localProtectionBridge.enabled = state.noFallDamage or state.noOceanDamage
		localProtectionBridge.spoofState = spoofProtectedHumanoidState
		localProtectionBridge.shouldBlockHealthWrite = shouldBlockProtectedHealthWrite
		localProtectionBridge.wrapStateSignal = wrapProtectedStateSignal
	end

	local function installLocalProtectionHooks()
		syncLocalProtectionBridge()
		if localProtectionBridge.installed then
			state.localProtectionHookInstalled = true
			state.localProtectionHookError = nil
			return true, "Local protection hooks armed"
		end

		if type(hookmetamethod) ~= "function" then
			state.localProtectionHookError = "hookmetamethod unavailable for local protection hooks"
			return false, state.localProtectionHookError
		end

		local makeHookClosure = type(newcclosure) == "function" and newcclosure or function(fn)
			return fn
		end
		local installedAny = false

		if type(getnamecallmethod) == "function" then
			local originalNamecall
			local ok = pcall(function()
				originalNamecall = hookmetamethod(game, "__namecall", makeHookClosure(function(self, ...)
					local method = getnamecallmethod()
					local result = originalNamecall(self, ...)
					if method == "GetState" then
						local bridge = getGlobalScope().__DartLocalProtectionBridge
						if bridge ~= nil and bridge.enabled == true and type(bridge.spoofState) == "function" then
							return bridge.spoofState(self, result)
						end
					end
					return result
				end))
			end)
			if ok then
				localProtectionBridge.namecallOriginal = originalNamecall
				localProtectionBridge.namecallInstalled = true
				installedAny = true
			end
		end

		local originalIndex
		local okIndex = pcall(function()
			originalIndex = hookmetamethod(game, "__index", makeHookClosure(function(self, key)
				local originalValue = originalIndex(self, key)
				if key == "GetState" and type(originalValue) == "function" then
					return function(target, ...)
						local humanoid = target or self
						local result = originalValue(humanoid, ...)
						local bridge = getGlobalScope().__DartLocalProtectionBridge
						if bridge ~= nil and bridge.enabled == true and type(bridge.spoofState) == "function" then
							return bridge.spoofState(humanoid, result)
						end
						return result
					end
				elseif key == "StateChanged" then
					local bridge = getGlobalScope().__DartLocalProtectionBridge
					if bridge ~= nil and bridge.enabled == true and type(bridge.wrapStateSignal) == "function" then
						return bridge.wrapStateSignal(self, originalValue)
					end
				end
				return originalValue
			end))
		end)
		if okIndex then
			localProtectionBridge.indexOriginal = originalIndex
			localProtectionBridge.indexInstalled = true
			installedAny = true
		end

		local originalNewIndex
		local okNewIndex = pcall(function()
			originalNewIndex = hookmetamethod(game, "__newindex", makeHookClosure(function(self, key, value)
				if key == "Health" then
					local bridge = getGlobalScope().__DartLocalProtectionBridge
					if bridge ~= nil and bridge.enabled == true and type(bridge.shouldBlockHealthWrite) == "function" and bridge.shouldBlockHealthWrite(self, value) then
						return
					end
				end
				return originalNewIndex(self, key, value)
			end))
		end)
		if okNewIndex then
			localProtectionBridge.newIndexOriginal = originalNewIndex
			localProtectionBridge.newIndexInstalled = true
			installedAny = true
		end

		localProtectionBridge.installed = installedAny
		state.localProtectionHookInstalled = installedAny
		if not installedAny then
			state.localProtectionHookError = "Local protection hook install failed"
			return false, state.localProtectionHookError
		end

		state.localProtectionHookError = nil
		return true, "Local protection hooks armed"
	end

	syncLocalProtectionBridge()
	state.localProtectionHookInstalled = localProtectionBridge.installed == true

	trackCleanup(function()
		if scope.__DartLocalProtectionBridge == localProtectionBridge then
			localProtectionBridge.enabled = false
			localProtectionBridge.spoofState = nil
			localProtectionBridge.shouldBlockHealthWrite = nil
			localProtectionBridge.wrapStateSignal = nil
		end
	end)

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
		local signal = {
			title = "Dart",
			detail = "",
			badge = "READY",
			level = "success",
			width = 184,
			height = 44,
		}

		if state.isMinimized then
			signal.title = "Dart"
			signal.detail = "Suite minimized"
			signal.badge = "LIVE"
			signal.level = "info"
			signal.width = 244
		end

		local threatSignal = refs.getIntelligenceThreatSignal and refs.getIntelligenceThreatSignal() or nil
		if threatSignal ~= nil then
			signal = threatSignal
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

		return alerts
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

	refs.setAlertCardTextTransparency = function(card, transparency)
		card.level.TextTransparency = transparency
		card.title.TextTransparency = transparency
		card.detail.TextTransparency = transparency
	end

	refs.tweenAlertCardText = function(card, transparency)
		SuiteMotion.tween(card.level, {
			TextTransparency = transparency,
		}, {
			duration = 0.16,
			style = "quad",
		})
		SuiteMotion.tween(card.title, {
			TextTransparency = transparency,
		}, {
			duration = 0.16,
			style = "quad",
		})
		SuiteMotion.tween(card.detail, {
			TextTransparency = transparency,
		}, {
			duration = 0.16,
			style = "quad",
		})
	end

	refs.updateAlertTimer = function(card, alert, alertColor)
		if alert.expiresAt == nil or alert.createdAt == nil then
			card.timerAlertId = nil
			card.timerTrack.Visible = false
			return
		end

		local now = os.clock()
		local total = math.max(0.05, alert.expiresAt - alert.createdAt)
		local remaining = clamp(alert.expiresAt - now, 0, total)
		local progress = total > 0 and remaining / total or 0

		card.timerTrack.Visible = true
		card.timerFill.BackgroundColor3 = alertColor
		card.timerTrack.BackgroundTransparency = 0.35
		card.timerFill.BackgroundTransparency = 0
		if card.timerAlertId ~= alert.id then
			card.timerAlertId = alert.id
			card.timerFill.Size = UDim2.new(progress, 0, 1, 0)
			SuiteMotion.tween(card.timerFill, {
				Size = UDim2.new(0, 0, 1, 0),
			}, {
				duration = remaining,
				style = "linear",
			})
		end
	end

	refs.showAlertCard = function(card, index, alert, alertColor)
		local rowY = (index - 1) * 84
		local isNewAlert = card.currentAlertId ~= alert.id
		card.currentAlertId = alert.id
		card.frame.Visible = true

		if isNewAlert then
			card.frame.Position = UDim2.fromOffset(-34, rowY)
			card.frame.BackgroundTransparency = 1
			card.timerTrack.BackgroundTransparency = 1
			card.timerFill.BackgroundTransparency = 1
			refs.setAlertCardTextTransparency(card, 1)
			card.currentRowY = rowY
			SuiteMotion.tween(card.frame, {
				BackgroundTransparency = 0,
				Position = UDim2.fromOffset(0, rowY),
			}, {
				duration = 0.22,
				style = "quint",
			})
			refs.tweenAlertCardText(card, 0)
		elseif card.currentRowY ~= rowY then
			card.currentRowY = rowY
			SuiteMotion.tween(card.frame, {
				Position = UDim2.fromOffset(0, rowY),
			}, {
				duration = 0.18,
				style = "quad",
			})
		end

		refs.updateAlertTimer(card, alert, alertColor)
	end

	refs.hideAlertCard = function(card, index)
		if card.currentAlertId == nil then
			card.frame.Visible = false
			return
		end

		local rowY = (index - 1) * 84
		card.currentAlertId = nil
		card.currentRowY = nil
		card.timerAlertId = nil
		SuiteMotion.tween(card.frame, {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(-34, rowY),
		}, {
			duration = 0.18,
			style = "quad",
		})
		refs.tweenAlertCardText(card, 1)
		SuiteMotion.tween(card.timerTrack, {
			BackgroundTransparency = 1,
		}, {
			duration = 0.16,
			style = "quad",
		})
		SuiteMotion.tween(card.timerFill, {
			BackgroundTransparency = 1,
		}, {
			duration = 0.16,
			style = "quad",
		})
		task.delay(0.2, function()
			if not cleaning and card.currentAlertId == nil then
				card.frame.Visible = false
				card.timerTrack.Visible = false
			end
		end)
	end

	updateSuiteOverlays = function()
		local signal = buildSuiteTelemetry()
		local color = signal.color or getLevelColor(signal.level)
		local islandHeight = signal.height or 52
		local colorKey = ("%0.3f:%0.3f:%0.3f"):format(color.R, color.G, color.B)
		local islandKey = table.concat({
			tostring(signal.title),
			tostring(signal.detail),
			tostring(signal.level),
			tostring(signal.width),
			tostring(islandHeight),
			colorKey,
		}, "\0")

		if refs.lastIslandBadge ~= signal.badge then
			refs.lastIslandBadge = signal.badge
			refs.dynamicIslandBadge.Text = signal.badge
		end

		if refs.lastIslandKey ~= islandKey then
			local sizeChanged = refs.lastIslandWidth ~= signal.width or refs.lastIslandHeight ~= islandHeight
			refs.lastIslandKey = islandKey
			refs.lastIslandWidth = signal.width
			refs.lastIslandHeight = islandHeight

			refs.dynamicIslandTitle.Text = signal.title
			refs.dynamicIslandDetail.Text = signal.detail
			refs.dynamicIslandDetail.Visible = tostring(signal.detail or "") ~= ""
			refs.dynamicIslandTitle.Position = refs.dynamicIslandDetail.Visible and UDim2.fromOffset(48, 10) or UDim2.fromOffset(48, 13)
			refs.dynamicIslandDot.BackgroundColor3 = color
			refs.dynamicIslandDot.Position = UDim2.fromOffset(28, math.floor(islandHeight / 2))
			refs.dynamicIslandDetail.Size = UDim2.new(1, -92, 0, math.max(18, islandHeight - 36))
			refs.dynamicIslandBadge.Position = UDim2.new(1, -68, 0, math.floor((islandHeight - 18) / 2))
			setOverlayStroke(refs.dynamicIsland, color, signal.level == "info" and 0.18 or 0.04)
			if sizeChanged then
				SuiteMotion.tween(refs.dynamicIsland, {
					Size = UDim2.fromOffset(signal.width, islandHeight),
				}, {
					duration = 0.18,
					style = "quint",
				})
			else
				refs.dynamicIsland.Size = UDim2.fromOffset(signal.width, islandHeight)
			end
		end

		local alerts = buildAlertStack(signal)
		if refs.alertRailPositioned ~= true then
			refs.alertRailPositioned = true
			refs.alertRail.Position = UDim2.fromOffset(14, 92)
		end

		for index, card in ipairs(refs.alertCards) do
			local alert = alerts[index]
			if alert ~= nil then
				local alertColor = alert.color or getLevelColor(alert.level)
				card.level.Text = string.upper(alert.level)
				card.level.TextColor3 = alertColor
				card.title.Text = alert.title
				card.detail.Text = alert.detail
				setOverlayStroke(card.frame, alertColor, alert.level == "info" and 0.26 or 0.08)
				refs.showAlertCard(card, index, alert, alertColor)
			else
				refs.hideAlertCard(card, index)
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

	local function setAutoFireStatus(text, color)
		state.autoFireStatus = tostring(text or "Auto-fire idle")
		if refs.autoFireStatusLabel ~= nil then
			refs.autoFireStatusLabel.Text = state.autoFireStatus
			refs.autoFireStatusLabel.TextColor3 = color or NativeUi.Theme.TextMuted
		end
	end

	local function getAutoFireTargetPart(character)
		local candidates = getAimCandidatesForCharacter(character, state.aimTargetPart)
		return candidates[1]
	end

	local function getNearestAutoFireTarget()
		local localRoot = getPlayerRootPart(Players.LocalPlayer)
		if localRoot == nil then
			return nil, nil, nil
		end

		local bestPlayer = nil
		local bestPart = nil
		local bestDistance = math.huge
		for _, player in ipairs(Players:GetPlayers()) do
			if not shouldSkipAimbotPlayer(player) then
				local root = getPlayerRootPart(player)
				local targetPart = getAutoFireTargetPart(player.Character)
				if root ~= nil and targetPart ~= nil then
					local distance = (root.Position - localRoot.Position).Magnitude
					if distance <= state.autoFireRange and distance < bestDistance then
						bestPlayer = player
						bestPart = targetPart
						bestDistance = distance
					end
				end
			end
		end

		return bestPlayer, bestPart, bestDistance
	end

	local function getAutoFireKey(text)
		return string.lower(tostring(text or "")):gsub("[%p%s_]+", "")
	end

	local function getAutoFireHandler(weaponName)
		local key = getAutoFireKey(weaponName)
		local handlerTables = {
			config.AutoFireHandlers,
			dartApi.AutoFireHandlers,
		}

		for _, handlerTable in ipairs(handlerTables) do
			if type(handlerTable) == "table" then
				local handler = handlerTable[weaponName] or handlerTable[key] or handlerTable.default
				if type(handler) == "function" then
					return handler
				end
			end
		end

		if type(config.AutoFireHandler) == "function" then
			return config.AutoFireHandler
		elseif type(dartApi.AutoFireHandler) == "function" then
			return dartApi.AutoFireHandler
		elseif type(dartApi.FireGun) == "function" then
			return dartApi.FireGun
		end

		return nil
	end

	local function getAutoFireRemoteSpec(weaponName)
		local key = getAutoFireKey(weaponName)
		local specTables = {
			config.AutoFireRemotes,
			dartApi.AutoFireRemotes,
		}

		for _, specTable in ipairs(specTables) do
			if type(specTable) == "table" then
				local spec = specTable[weaponName] or specTable[key] or specTable.default
				if type(spec) == "table" then
					return spec
				end
			end
		end

		if type(config.AutoFireRemote) == "table" then
			return config.AutoFireRemote
		elseif type(dartApi.AutoFireRemote) == "table" then
			return dartApi.AutoFireRemote
		end

		return nil
	end

	local function normalizeAutoFireArgs(value, context)
		if type(value) == "function" then
			local generated = value(context)
			if type(generated) == "table" then
				return generated
			end
			return { generated }
		elseif type(value) == "table" then
			return value
		end

		return { context.targetPart, context.targetPosition, context.player }
	end

	local function runAutoFireRemote(spec, context)
		local remote = spec.Remote or spec.remote
		if typeof(remote) ~= "Instance" then
			local path = spec.Path or spec.path
			if type(path) ~= "string" or trimText(path) == "" then
				return false, "Auto-fire remote path missing"
			end
			remote = resolveInstanceByPath(path)
		end

		local method = spec.Method or spec.method
		if method == nil or method == "" then
			method = remote:IsA("RemoteFunction") and "InvokeServer" or "FireServer"
		end
		if method ~= "FireServer" and method ~= "InvokeServer" then
			return false, "Auto-fire remote method must be FireServer or InvokeServer"
		end

		local args = normalizeAutoFireArgs(spec.Args or spec.args, context)
		local unpackArgs = table.unpack or unpack
		if method == "InvokeServer" then
			return true, remote:InvokeServer(unpackArgs(args))
		end

		remote:FireServer(unpackArgs(args))
		return true, "Remote fired"
	end

	local function updateAutoFire()
		if not state.autoFireEnabled then
			return
		end

		local player, targetPart, distance = getNearestAutoFireTarget()
		if player == nil or targetPart == nil then
			setAutoFireStatus("No enemy in range")
			return
		end

		local now = os.clock()
		if now - state.autoFireLastAt < state.autoFireCooldown then
			return
		end
		state.autoFireLastAt = now

		local weaponName = getKnownPlayerWeapon(Players.LocalPlayer) or "weapon"
		local context = {
			player = player,
			character = player.Character,
			targetPart = targetPart,
			targetPosition = targetPart.Position,
			distance = distance,
			weaponName = weaponName,
			localPlayer = Players.LocalPlayer,
			team = getPlayerTeamText(player),
			state = state,
		}

		local handler = getAutoFireHandler(weaponName)
		local ok, result
		if handler ~= nil then
			local handlerResults = { pcall(handler, context) }
			ok = handlerResults[1] and handlerResults[2] ~= false
			result = handlerResults[3] or handlerResults[2]
		else
			local spec = getAutoFireRemoteSpec(weaponName)
			if spec ~= nil then
				local remoteResults = { pcall(runAutoFireRemote, spec, context) }
				ok = remoteResults[1] and remoteResults[2] == true
				result = remoteResults[3] or remoteResults[2]
			else
				ok = false
				result = "No auto-fire handler configured"
			end
		end

		if ok then
			setAutoFireStatus(
				("Fired at %s [%s] %dm"):format(player.Name, targetPart.Name, math.floor(distance + 0.5)),
				NativeUi.Theme.Success
			)
		else
			setAutoFireStatus(tostring(result), NativeUi.Theme.Warning)
			if now - state.autoFireLastNotifyAt > 8 then
				state.autoFireLastNotifyAt = now
				emitNotification("warning", "Auto-fire handler missing", tostring(result), { duration = 4 })
			end
		end
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
			noFallDamage = "toggleNoFallDamage",
			antiFall = "toggleAntiFall",
			noOceanDamage = "toggleNoOceanDamage",
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

		if enabled and (toggleName == "noFallDamage" or toggleName == "noOceanDamage") then
			local ok, result = installLocalProtectionHooks()
			if not ok then
				return false, result
			end
		end

		state[toggleName] = enabled
		if toggleName == "noFallDamage" or toggleName == "noOceanDamage" then
			syncLocalProtectionBridge()
		end
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

	refs.getRemoteRecord = function(remote, create)
		if not isRemoteLike(remote) then
			return nil
		end

		local remoteKey = getRemoteKey(remote)
		local record = state.remoteRecords[remoteKey]
		if record == nil and create then
			record = {
				remote = remote,
				remoteKey = remoteKey,
				path = getRemotePath(remote),
				name = remote.Name,
				className = remote.ClassName,
				calls = 0,
				logs = {},
			}
			state.remoteRecords[remoteKey] = record
			table.insert(state.remoteRecordOrder, record)
		elseif record ~= nil then
			record.remote = remote
			record.path = getRemotePath(remote)
			record.name = remote.Name
			record.className = remote.ClassName
		end
		return record
	end

	refs.getSelectedRemoteRecord = function()
		if state.selectedRemoteKey ~= nil then
			local record = state.remoteRecords[state.selectedRemoteKey]
			if record ~= nil then
				return record
			end
		end

		if state.selectedRemotePath ~= nil then
			for _, record in ipairs(state.remoteRecordOrder) do
				if record.path == state.selectedRemotePath then
					return record
				end
			end
		end

		return nil
	end

	local function getSelectedRemote()
		local record = refs.getSelectedRemoteRecord()
		if record ~= nil then
			return record.remote
		end

		if state.selectedRemotePath == nil and state.selectedRemoteKey == nil then
			return nil
		end

		for _, remote in ipairs(state.remoteList) do
			if getRemoteKey(remote) == state.selectedRemoteKey or getRemotePath(remote) == state.selectedRemotePath then
				return remote
			end
		end

		return nil
	end

	local function remoteLogMatches(entry, remotePath, remote)
		if entry == nil then
			return false
		end
		if remote ~= nil and (entry.remote == remote or entry.remoteKey == getRemoteKey(remote)) then
			return true
		end
		if remotePath ~= nil and entry.remotePath == remotePath then
			return true
		end
		return remote ~= nil and entry.remoteName == remote.Name and entry.className == remote.ClassName
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

	refs.getRemoteCallCount = function(remote)
		local record = refs.getRemoteRecord(remote, false)
		if record ~= nil then
			return record.calls
		end

		if remote == nil then
			return 0
		end

		local remoteKey = getRemoteKey(remote)
		local count = 0
		for callKey, callCount in pairs(state.remoteCallCounts) do
			if string.sub(callKey, 1, #remoteKey + 1) == remoteKey .. "\0" then
				count = count + callCount
			end
		end
		return count
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
		refs.getRemoteRecord(remote, true)
		table.sort(state.remoteList, function(left, right)
			return string.lower(getRemotePath(left)) < string.lower(getRemotePath(right))
		end)
		if connectRemoteEvent ~= nil then
			connectRemoteEvent(remote)
		end
		return true
	end

	local function markRemoteHookMethod(name, installed)
		if installed then
			state.remoteHookMethods[name] = true
		end
	end

	local function getRemoteHookSummary()
		local hooks = {}
		for name in pairs(state.remoteHookMethods) do
			table.insert(hooks, name)
		end
		table.sort(hooks)
		if #hooks == 0 then
			return "none"
		end
		return table.concat(hooks, ", ")
	end

	local function getWatchedRemoteMethod(remote, key)
		key = normalizeRemoteMethod(key)
		if type(key) ~= "string" or not isRemoteLike(remote) then
			return nil
		end
		if key == "FireServer" and (remote:IsA("RemoteEvent") or remote.ClassName == "UnreliableRemoteEvent") then
			return key
		end
		if key == "InvokeServer" and remote:IsA("RemoteFunction") then
			return key
		end
		if key == "Fire" and remote:IsA("BindableEvent") then
			return key
		end
		if key == "Invoke" and remote:IsA("BindableFunction") then
			return key
		end
		return nil
	end

	local function shouldSkipRemoteDuplicate(direction, path, method, argsText)
		if state.remoteDedupeWindow <= 0 then
			return false
		end

		local now = os.clock()
		local key = table.concat({ tostring(direction), path, tostring(method), argsText }, "\0")
		if state.lastRemoteCaptureKey == key and now - state.lastRemoteCaptureAt < state.remoteDedupeWindow then
			return true
		end
		state.lastRemoteCaptureKey = key
		state.lastRemoteCaptureAt = now
		return false
	end

	refs.scheduleRemoteLogRender = function()
		if refs.remoteLogRenderQueued or cleaning then
			return
		end

		refs.remoteLogRenderQueued = true
		task.delay(0.08, function()
			refs.remoteLogRenderQueued = false
			if cleaning or refs.main == nil or refs.main.Parent == nil then
				return
			end
			if renderRemoteLog ~= nil then
				renderRemoteLog()
			end
		end)
	end

	refs.scheduleRemoteListRender = function()
		if refs.remoteListRenderQueued or cleaning then
			return
		end

		refs.remoteListRenderQueued = true
		task.delay(0.15, function()
			refs.remoteListRenderQueued = false
			if cleaning or refs.main == nil or refs.main.Parent == nil then
				return
			end
			if renderRemoteList ~= nil then
				renderRemoteList()
			end
		end)
	end

	local function appendRemoteLog(direction, remote, method, args, hookName)
		args = args or {}
		local path = getRemotePath(remote)
		local remoteKey = getRemoteKey(remote)
		local record = refs.getRemoteRecord(remote, true)
		local listChanged = ensureRemoteTracked(remote)
		local selectionChanged = false
		if state.selectedRemotePath == nil then
			state.selectedRemotePath = path
			state.selectedRemoteKey = remoteKey
			selectionChanged = true
		end
		local argsText = formatRemoteArgs(args)
		if shouldSkipRemoteDuplicate(direction, path, method, argsText) then
			return
		end

		state.remoteLogSerial = state.remoteLogSerial + 1
		local callKey = table.concat({ remoteKey, tostring(direction), tostring(method) }, "\0")
		local remoteCallCount = (state.remoteCallCounts[callKey] or 0) + 1
		state.remoteCallCounts[callKey] = remoteCallCount
		if record ~= nil then
			record.calls = record.calls + 1
			remoteCallCount = record.calls
		end

		local entry = {
			id = state.remoteLogSerial,
			remoteCallCount = remoteCallCount,
			remote = remote,
			direction = direction or "?",
			remotePath = path,
			remoteKey = remoteKey,
			remoteName = typeof(remote) == "Instance" and remote.Name or tostring(remote),
			className = typeof(remote) == "Instance" and remote.ClassName or "?",
			method = tostring(method or "?"),
			argCount = getPackedArgCount(args),
			argsText = argsText,
			argsLines = formatRemoteArgLines(args),
			hookName = hookName or "?",
			timestamp = os.date("%H:%M:%S"),
		}

		table.insert(state.remoteLogs, 1, entry)
		if record ~= nil then
			table.insert(record.logs, 1, entry)
			while #record.logs > 120 do
				table.remove(record.logs)
			end
		end
		while #state.remoteLogs > 180 do
			table.remove(state.remoteLogs)
		end

		if renderRemoteList ~= nil then
			if listChanged or selectionChanged then
				renderRemoteList()
			else
				refs.scheduleRemoteListRender()
			end
		end
		if renderRemoteLog ~= nil then
			refs.scheduleRemoteLogRender()
		end
	end

	local function installDirectRemoteMethodHooks(makeHookClosure)
		if remoteHookBridge.directHooksInstalled then
			markRemoteHookMethod("direct", true)
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
				hookedOriginal = hookfunction(originalMethod, makeHookClosure(function(...)
					local self = ...
					local bridge = getGlobalScope().__DartRemoteHookBridge
					if bridge ~= nil and bridge.enabled == true and type(bridge.callback) == "function" and isRemoteLike(self) then
						bridge.callback(self, methodName, packRemoteArgsAfterFirst(...), "direct")
					end
					return hookedOriginal(...)
				end))
			end)

			if okHook then
				remoteHookBridge.directHooks[className .. "." .. methodName] = hookedOriginal
				installedAny = true
				markRemoteHookMethod("direct", true)
				return true
			end

			return false
		end

		hookClassMethod("RemoteEvent", "FireServer")
		hookClassMethod("UnreliableRemoteEvent", "FireServer")
		hookClassMethod("RemoteFunction", "InvokeServer")
		hookClassMethod("BindableEvent", "Fire")
		hookClassMethod("BindableFunction", "Invoke")
		remoteHookBridge.directHooksInstalled = installedAny
		return installedAny
	end

	local function makeRemoteMethodWrapper(remote, methodName, originalMethod, hookName)
		return function(self, ...)
			local target = isRemoteLike(self) and self or remote
			local args = isRemoteLike(self) and packRemoteArgs(...) or packRemoteArgs(self, ...)
			local bridge = getGlobalScope().__DartRemoteHookBridge
			if bridge ~= nil and bridge.enabled == true and type(bridge.callback) == "function" and isRemoteLike(target) then
				bridge.callback(target, methodName, args, hookName)
			end
			return originalMethod(self, ...)
		end
	end

	local function getCachedRemoteMethodWrapper(remote, methodName, originalMethod, hookName, makeHookClosure)
		remoteHookBridge.indexWrappers = remoteHookBridge.indexWrappers or setmetatable({}, { __mode = "k" })
		local byRemote = remoteHookBridge.indexWrappers[remote]
		if byRemote == nil then
			byRemote = {}
			remoteHookBridge.indexWrappers[remote] = byRemote
		end
		local cached = byRemote[methodName]
		if cached ~= nil then
			return cached
		end
		cached = makeHookClosure(makeRemoteMethodWrapper(remote, methodName, originalMethod, hookName))
		byRemote[methodName] = cached
		return cached
	end

	local function getRawIndexValue(originalIndex, self, key)
		if type(originalIndex) == "function" then
			return originalIndex(self, key)
		elseif type(originalIndex) == "table" then
			return originalIndex[key]
		end
		return nil
	end

	local function installIndexHookTarget(target, label, makeHookClosure)
		remoteHookBridge.indexHooks = remoteHookBridge.indexHooks or {}
		if remoteHookBridge.indexHooks[label] ~= nil then
			markRemoteHookMethod("index:" .. label, true)
			return true
		end

		if type(hookmetamethod) ~= "function" or target == nil then
			return false
		end

		local originalIndex
		local ok = pcall(function()
			originalIndex = hookmetamethod(target, "__index", makeHookClosure(function(self, key)
				local methodName = getWatchedRemoteMethod(self, key)
				local originalValue = originalIndex(self, key)
				if methodName ~= nil and type(originalValue) == "function" then
					return getCachedRemoteMethodWrapper(self, methodName, originalValue, "index:" .. label, makeHookClosure)
				end
				return originalValue
			end))
		end)

		if ok then
			remoteHookBridge.indexHooks[label] = originalIndex
			markRemoteHookMethod("index:" .. label, true)
			return true
		end

		return false
	end

	local function createHookSample(className)
		remoteHookBridge.samples = remoteHookBridge.samples or {}
		local existing = remoteHookBridge.samples[className]
		if typeof(existing) == "Instance" then
			return existing
		end

		local ok, sample = pcall(function()
			return Instance.new(className)
		end)
		if ok then
			sample.Name = "DartRemoteHookSample_" .. className
			remoteHookBridge.samples[className] = sample
			return sample
		end
		return nil
	end

	local function installIndexRemoteMethodHook(makeHookClosure)
		if remoteHookBridge.indexInstalled then
			markRemoteHookMethod("index", true)
			return true
		end

		local installedAny = installIndexHookTarget(game, "game", makeHookClosure)
		local remoteEventSample = createHookSample("RemoteEvent")
		local unreliableSample = createHookSample("UnreliableRemoteEvent")
		local remoteFunctionSample = createHookSample("RemoteFunction")
		local bindableEventSample = createHookSample("BindableEvent")
		local bindableFunctionSample = createHookSample("BindableFunction")

		installedAny = installIndexHookTarget(remoteEventSample, "RemoteEvent", makeHookClosure) or installedAny
		installedAny = installIndexHookTarget(unreliableSample, "UnreliableRemoteEvent", makeHookClosure) or installedAny
		installedAny = installIndexHookTarget(remoteFunctionSample, "RemoteFunction", makeHookClosure) or installedAny
		installedAny = installIndexHookTarget(bindableEventSample, "BindableEvent", makeHookClosure) or installedAny
		installedAny = installIndexHookTarget(bindableFunctionSample, "BindableFunction", makeHookClosure) or installedAny

		remoteHookBridge.indexInstalled = installedAny
		if installedAny then
			markRemoteHookMethod("index", true)
		end
		return installedAny
	end

	local function installRawIndexRemoteMethodHook(metatable, makeHookClosure)
		if remoteHookBridge.rawIndexInstalled then
			markRemoteHookMethod("raw-index", true)
			return true
		end

		if type(metatable) ~= "table" then
			return false
		end

		local originalIndex = metatable.__index
		metatable.__index = makeHookClosure(function(self, key)
			local methodName = getWatchedRemoteMethod(self, key)
			local originalValue = getRawIndexValue(originalIndex, self, key)
			if methodName ~= nil and type(originalValue) == "function" then
				return getCachedRemoteMethodWrapper(self, methodName, originalValue, "raw-index", makeHookClosure)
			end
			return originalValue
		end)

		remoteHookBridge.rawIndexInstalled = true
		remoteHookBridge.originalRawIndex = originalIndex
		markRemoteHookMethod("raw-index", true)
		return true
	end

	local function installNamecallHookTarget(target, label, makeHookClosure)
		remoteHookBridge.namecallHooks = remoteHookBridge.namecallHooks or {}
		if remoteHookBridge.namecallHooks[label] ~= nil then
			markRemoteHookMethod("namecall:" .. label, true)
			return true
		end

		if type(hookmetamethod) ~= "function" or target == nil then
			return false
		end

		local originalNamecall
		local ok = pcall(function()
			originalNamecall = hookmetamethod(target, "__namecall", makeHookClosure(function(self, ...)
				local method = normalizeRemoteMethod(getnamecallmethod())
				local bridge = getGlobalScope().__DartRemoteHookBridge
				if bridge ~= nil and bridge.enabled == true and type(bridge.callback) == "function" and getWatchedRemoteMethod(self, method) ~= nil then
					bridge.callback(self, method, packRemoteArgs(...), "namecall:" .. label)
				end
				return originalNamecall(self, ...)
			end))
		end)

		if ok then
			remoteHookBridge.namecallHooks[label] = originalNamecall
			markRemoteHookMethod("namecall:" .. label, true)
			return true
		end

		return false
	end

	remoteHookBridge.callback = function(remote, method, args, hookName)
		if state.remoteWatcherEnabled then
			appendRemoteLog("OUT", remote, method, args, hookName or "bridge")
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
			refs.getRemoteRecord(remote, true)
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

		local makeHookClosure = type(newcclosure) == "function" and newcclosure or function(fn)
			return fn
		end

		local directHookInstalled = installDirectRemoteMethodHooks(makeHookClosure)
		local indexHookInstalled = installIndexRemoteMethodHook(makeHookClosure)
		if type(getnamecallmethod) ~= "function" then
			if directHookInstalled or indexHookInstalled then
				state.remoteHookInstalled = true
				state.remoteHookError = nil
				remoteHookBridge.enabled = true
				return true
			end
			state.remoteHookError = "Namecall method API unavailable; direct hooks also unavailable."
			return false
		end

		if type(hookmetamethod) == "function" then
			if remoteHookBridge.namecallInstalled then
				state.remoteHookInstalled = true
				state.remoteHookError = nil
				remoteHookBridge.enabled = true
				markRemoteHookMethod("namecall", true)
				return true
			end

			local namecallInstalled = installNamecallHookTarget(game, "game", makeHookClosure)
			local remoteEventSample = createHookSample("RemoteEvent")
			local unreliableSample = createHookSample("UnreliableRemoteEvent")
			local remoteFunctionSample = createHookSample("RemoteFunction")
			local bindableEventSample = createHookSample("BindableEvent")
			local bindableFunctionSample = createHookSample("BindableFunction")

			namecallInstalled = installNamecallHookTarget(remoteEventSample, "RemoteEvent", makeHookClosure) or namecallInstalled
			namecallInstalled = installNamecallHookTarget(unreliableSample, "UnreliableRemoteEvent", makeHookClosure) or namecallInstalled
			namecallInstalled = installNamecallHookTarget(remoteFunctionSample, "RemoteFunction", makeHookClosure) or namecallInstalled
			namecallInstalled = installNamecallHookTarget(bindableEventSample, "BindableEvent", makeHookClosure) or namecallInstalled
			namecallInstalled = installNamecallHookTarget(bindableFunctionSample, "BindableFunction", makeHookClosure) or namecallInstalled

			if namecallInstalled then
				remoteHookBridge.namecallInstalled = true
				remoteHookBridge.enabled = true
				state.remoteHookInstalled = true
				state.remoteHookError = nil
				markRemoteHookMethod("namecall", true)
				return true
			end

			state.remoteHookError = "hookmetamethod namecall hooks failed."
		end

		if type(getrawmetatable) ~= "function" or type(setreadonly) ~= "function" then
			if directHookInstalled or indexHookInstalled then
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
		local rawIndexInstalled = false
		local ok, err = pcall(function()
			setreadonly(metatable, false)
			if not indexHookInstalled then
				rawIndexInstalled = installRawIndexRemoteMethodHook(metatable, makeHookClosure)
			end
			metatable.__namecall = makeHookClosure(function(self, ...)
				local method = normalizeRemoteMethod(getnamecallmethod())
				if state.remoteWatcherEnabled and getWatchedRemoteMethod(self, method) ~= nil then
					appendRemoteLog("OUT", self, method, packRemoteArgs(...), "raw-namecall")
				end
				return originalNamecall(self, ...)
			end)
			setreadonly(metatable, true)
		end)

		if not ok then
			if directHookInstalled or indexHookInstalled or rawIndexInstalled then
				state.remoteHookInstalled = true
				state.remoteHookError = nil
				remoteHookBridge.enabled = true
				pcall(function()
					setreadonly(metatable, true)
				end)
				return true
			end
			state.remoteHookError = "Namecall hook failed: " .. tostring(err)
			pcall(function()
				setreadonly(metatable, true)
			end)
			return false
		end

		state.remoteHookInstalled = true
		state.remoteHookError = nil
		markRemoteHookMethod("raw-namecall", true)
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
		if not remote:IsA("RemoteEvent") and remote.ClassName ~= "UnreliableRemoteEvent" and not remote:IsA("BindableEvent") then
			return
		end

		if remoteEventConnections[remote] ~= nil then
			return
		end

		local signal = remote:IsA("BindableEvent") and remote.Event or remote.OnClientEvent
		local method = remote:IsA("BindableEvent") and "Event" or "OnClientEvent"
		local direction = remote:IsA("BindableEvent") and "LOCAL" or "IN"
		remoteEventConnections[remote] = trackConnection(signal:Connect(function(...)
			if state.remoteWatcherEnabled then
				appendRemoteLog(direction, remote, method, packRemoteArgs(...))
			end
		end))
	end

	local function appendRemoteEntryLines(lines, entry)
		local preview = entry.argsText ~= "" and entry.argsText or "<no args>"
		table.insert(lines, ("#%d [%s] %s  %s  call:%d"):format(
			entry.id or 0,
			entry.timestamp,
			entry.direction,
			entry.method,
			entry.remoteCallCount or 0
		))
		table.insert(lines, ("  Class   : %s"):format(entry.className))
		table.insert(lines, ("  Path    : %s"):format(entry.remotePath))
		table.insert(lines, ("  Args    : %d"):format(entry.argCount))
		table.insert(lines, ("  Hook    : %s"):format(entry.hookName or "?"))
		table.insert(lines, ("  Payload : %s"):format(preview))
		table.insert(lines, entry.argsLines)
		table.insert(lines, "")
	end

	renderRemoteLog = function()
		local diagnostics = refs.remoteSpy:GetDiagnostics()
		local record = state.selectedRemoteKey ~= nil and refs.remoteSpy:GetRecord(state.selectedRemoteKey) or nil
		local call = record ~= nil and refs.remoteSpy:GetCall(record, state.selectedRemoteCallId) or nil
		refs.remoteDiagnosticsLabel.Text = formatRemoteDiagnostics(diagnostics)
		NativeUi.clear(refs.remoteCallsContent)

		if record == nil then
			refs.remoteLogStatusLabel.Text = state.remoteWatcherEnabled and "Capture active" or "Capture idle"
			refs.remoteInspectorTitleLabel.Text = "No remote selected"
			refs.remoteInspectorMetaLabel.Text = ("Known: %d    Captured: %d"):format(#refs.remoteSpy.records, #refs.remoteSpy.logs)
			NativeUi.setButtonDisabled(refs.copyRemotePayloadButton, true)
			NativeUi.setButtonDisabled(refs.copyRemoteReplayButton, true)
			return
		end

		if call ~= nil then
			state.selectedRemoteCallId = call.Id
		end

		refs.remoteLogStatusLabel.Text = call ~= nil
			and ("Selected #%d    %s %s    %d args"):format(call.Id, call.Direction, call.Method, call.ArgCount or 0)
			or (state.remoteWatcherEnabled and "Capture active" or "Capture idle")
		refs.remoteInspectorTitleLabel.Text = record.Name
		refs.remoteInspectorMetaLabel.Text = ("Class: %s    Calls: %d\nPath: %s"):format(record.ClassName, record.Calls, record.Path)

		if #record.Logs == 0 then
			NativeUi.makeLabel(refs.remoteCallsContent, "No calls captured for this remote yet.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
		else
			for _, item in ipairs(record.Logs) do
				local button = NativeUi.makeButton(refs.remoteCallsContent, ("%d  %s  %s  %s  args:%d\n%s"):format(
					item.Id,
					item.Timestamp,
					item.Direction,
					item.Method,
					item.ArgCount or 0,
					formatRemoteArgLines(item.Args or {})
				), {
					Font = Enum.Font.Code,
					Size = UDim2.new(1, 0, 0, math.max(58, 34 + (item.ArgCount or 0) * 18)),
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextWrapped = true,
				})
				NativeUi.setButtonSelected(button, call ~= nil and item.Id == call.Id)
				button.MouseButton1Click:Connect(function()
					state.selectedRemoteCallId = item.Id
					renderRemoteLog()
				end)
			end
		end

		NativeUi.setButtonDisabled(refs.copyRemotePayloadButton, call == nil)
		NativeUi.setButtonDisabled(refs.copyRemoteReplayButton, call == nil)
	end

	renderRemoteList = function()
		NativeUi.clear(refs.remoteListContent)
		local records = refs.remoteSpy:GetRecords(state.remoteFilterText)

		for index = #records, 1, -1 do
			if records[index].Calls <= 0 then
				table.remove(records, index)
			end
		end

		if #records == 0 then
			if #refs.remoteSpy.logs == 0 then
				state.selectedRemoteKey = nil
				state.selectedRemotePath = nil
				state.selectedRemoteCallId = nil
			end
			NativeUi.makeLabel(refs.remoteListContent, #refs.remoteSpy.logs == 0 and "No fired remotes captured yet." or "No fired remotes match the current filter.", {
				TextColor3 = NativeUi.Theme.TextMuted,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.new(1, 0, 0, 0),
			})
		else
			for _, record in ipairs(records) do
				local button = NativeUi.makeButton(refs.remoteListContent, ("%s %s  [%s]  %d calls"):format(
					UI_ICON.remote,
					record.Name,
					record.ClassName,
					record.Calls
				), {
					Font = Enum.Font.Code,
					Size = UDim2.new(1, 0, 0, 28),
					TextSize = 11,
					TextXAlignment = Enum.TextXAlignment.Left,
				})
				NativeUi.setButtonSelected(button, state.selectedRemoteKey == record.Key)
				button.MouseButton1Click:Connect(function()
					state.selectedRemotePath = record.Path
					state.selectedRemoteKey = record.Key
					state.selectedRemoteCallId = record.Logs[1] and record.Logs[1].Id or nil
					renderRemoteList()
					renderRemoteLog()
					syncControlState()
				end)
			end
		end

		refs.remoteCountLabel.Text = ("Fired: %d / Known: %d / Captured: %d"):format(#records, #refs.remoteSpy.records, #refs.remoteSpy.logs)
	end

	refs.remoteSpy:SetCaptureCallback(function(record, call)
		if state.selectedRemoteKey == nil then
			state.selectedRemoteKey = record.Key
			state.selectedRemotePath = record.Path
			state.selectedRemoteCallId = call.Id
		elseif state.selectedRemoteKey == record.Key and state.selectedRemoteCallId == nil then
			state.selectedRemoteCallId = call.Id
		end

		refs.scheduleRemoteListRender()
		refs.scheduleRemoteLogRender()
	end)

	refs.remoteSpy:SetRecordsChangedCallback(function()
		refs.scheduleRemoteListRender()
		refs.scheduleRemoteLogRender()
	end)

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
		refs.getRemoteRecord(remote, true)
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

	refs.walkSpeedController = bindSlider(refs.walkSlider, 0, 200, state.walkSpeedValue, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.walkSpeedValue = value
	end)

	refs.jumpPowerController = bindSlider(refs.jumpSlider, 0, 250, state.jumpPowerValue, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.jumpPowerValue = value
	end)

	refs.hipHeightController = bindSlider(refs.hipSlider, -5, 25, state.hipHeightValue, 0.5, function(value)
		return string.format("%.1f", value)
	end, function(value)
		state.hipHeightValue = value
	end)

	refs.gravityController = bindSlider(refs.gravitySlider, 0, 400, state.gravityValue, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.gravityValue = value
	end)

	refs.ghostFlySpeedController = bindSlider(refs.ghostFlySpeedSlider, 8, 180, state.ghostFlySpeed, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.ghostFlySpeed = value
	end)

	refs.freeCameraSpeedController = bindSlider(refs.freeCameraSpeedSlider, 8, 220, state.freeCameraSpeed, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.freeCameraSpeed = value
	end)

	refs.freeCameraFastSpeedController = bindSlider(refs.freeCameraFastSpeedSlider, 16, 360, state.freeCameraFastSpeed, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.freeCameraFastSpeed = value
	end)

	refs.autoFireRangeController = bindSlider(refs.autoFireRangeSlider, 20, 500, state.autoFireRange, 5, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.autoFireRange = value
	end)

	refs.iridiumController = bindSlider(refs.iridiumSlider, 0, 1, state.iridiumMinFullness, 0.05, function(value)
		return string.format("%.2f", value)
	end, function(value)
		state.iridiumMinFullness = value
	end)

	refs.wellDistanceController = bindSlider(refs.wellDistanceSlider, 50, 2000, state.wellDistance, 25, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.wellDistance = value
	end)

	refs.structureMacroRangeController = bindSlider(refs.structureMacroRangeSlider, 6, 120, state.macroRange, 1, function(value)
		return tostring(math.floor(value + 0.5))
	end, function(value)
		state.macroRange = value
	end)

	local runtime = {
		highlightInstances = {},
		playerCharacterConnections = {},
		playerTeamConnections = {},
		refreshPlayersList = nil,
		refreshEspPlayersList = nil,
		reconcileObjectHighlights = nil,
		distanceRefreshAccumulator = 0,
		lastDistanceRefreshPosition = nil,
		objectRefreshQueued = false,
		autoFireHeartbeatAccumulator = 0,
		macroHeartbeatAccumulator = 0,
		noClipCharacter = nil,
		noClipParts = {},
		noClipRefreshAccumulator = 0,
		antiFallCharacter = nil,
		antiFallSamples = {},
		antiFallLastSampleAt = 0,
		antiFallLastSnapAt = 0,
	}
	runtime.antiFallRaycastParams = RaycastParams.new()
	runtime.antiFallRaycastParams.FilterType = Enum.RaycastFilterType.Exclude
	runtime.antiFallRaycastParams.IgnoreWater = true

	function runtime.resetAntiFall()
		runtime.antiFallCharacter = nil
		runtime.antiFallSamples = {}
		runtime.antiFallLastSampleAt = 0
	end

	function runtime.hasAntiFallGround(character, root, humanoid)
		if humanoid ~= nil and humanoid.FloorMaterial ~= Enum.Material.Air then
			return true
		end

		if root == nil then
			return false
		end

		runtime.antiFallRaycastParams.FilterDescendantsInstances = { character }
		return Workspace:Raycast(root.Position, Vector3.new(0, -7, 0), runtime.antiFallRaycastParams) ~= nil
	end

	function runtime.pushAntiFallSample(root, now)
		if root == nil then
			return
		end

		if now - runtime.antiFallLastSampleAt < 0.08 then
			return
		end

		runtime.antiFallLastSampleAt = now
		table.insert(runtime.antiFallSamples, {
			t = now,
			cframe = root.CFrame,
			position = root.Position,
		})

		for index = #runtime.antiFallSamples, 1, -1 do
			if now - runtime.antiFallSamples[index].t > 1.6 then
				table.remove(runtime.antiFallSamples, index)
			end
		end
	end

	function runtime.getAntiFallRestoreSample(now)
		local fallback = runtime.antiFallSamples[#runtime.antiFallSamples]
		for index = #runtime.antiFallSamples, 1, -1 do
			local sample = runtime.antiFallSamples[index]
			local age = now - sample.t
			if age >= state.antiFallBacktrack and age <= 1.6 then
				return sample
			end
		end

		return fallback
	end

	function runtime.snapAntiFallCharacter(character, sample)
		if character == nil or sample == nil then
			return
		end

		local restoreCFrame = sample.cframe + Vector3.new(0, 2, 0)
		pcall(function()
			character:PivotTo(restoreCFrame)
		end)

		for _, part in ipairs(getCharacterBaseParts(character)) do
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
		end
	end

	function runtime.updateAntiFall(deltaTime)
		if not state.antiFall then
			if runtime.antiFallCharacter ~= nil or #runtime.antiFallSamples > 0 then
				runtime.resetAntiFall()
			end
			return
		end

		local character = getLocalCharacter()
		local humanoid = character and character:FindFirstChildOfClass("Humanoid") or nil
		local root = getCharacterRootPart(character)
		if character == nil or humanoid == nil or root == nil or humanoid.Health <= 0 then
			runtime.resetAntiFall()
			return
		end

		if runtime.antiFallCharacter ~= character then
			runtime.resetAntiFall()
			runtime.antiFallCharacter = character
		end

		local humanoidState = humanoid:GetState()
		if humanoidState == Enum.HumanoidStateType.Dead
			or humanoidState == Enum.HumanoidStateType.Seated
			or humanoidState == Enum.HumanoidStateType.Swimming
			or humanoidState == Enum.HumanoidStateType.Climbing
		then
			return
		end

		local now = os.clock()
		local hasGround = runtime.hasAntiFallGround(character, root, humanoid)
		if hasGround and root.AssemblyLinearVelocity.Y > -10 then
			runtime.pushAntiFallSample(root, now)
			return
		end

		local sample = runtime.getAntiFallRestoreSample(now)
		if sample == nil then
			return
		end

		local drop = sample.position.Y - root.Position.Y
		if drop < state.antiFallDrop or now - runtime.antiFallLastSnapAt < state.antiFallCooldown then
			return
		end

		runtime.antiFallLastSnapAt = now
		runtime.snapAntiFallCharacter(character, sample)
		runtime.antiFallSamples = {}
		runtime.pushAntiFallSample(root, now)
		setMainStatus("Anti Fall restored position", NativeUi.Theme.Success)
	end
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

	function runtime.anyObjectEspEnabled()
		for _, enabled in pairs(state.espObjectToggles) do
			if enabled then
				return true
			end
		end

		return false
	end

	function runtime.removeHighlight(key)
		local highlight = runtime.highlightInstances[key]
		if highlight ~= nil then
			runtime.highlightInstances[key] = nil
			pcall(function()
				highlight:Destroy()
			end)
		end
	end

	function runtime.ensureHighlight(key, target, fillColor, outlineColor)
		local carrier = getHighlightCarrier(target)
		if carrier == nil or carrier.Parent == nil then
			runtime.removeHighlight(key)
			return
		end

		local highlight = runtime.highlightInstances[key]
		if highlight == nil or highlight.Parent ~= carrier then
			runtime.removeHighlight(key)
			highlight = Instance.new("Highlight")
			highlight.Name = "DartEspHighlight"
			highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			highlight.FillTransparency = state.highlightFillTransparency
			highlight.OutlineTransparency = 0
			highlight.Parent = carrier
			highlight.Adornee = carrier
			runtime.highlightInstances[key] = highlight
		end

		highlight.FillColor = fillColor
		highlight.OutlineColor = outlineColor or fillColor
		highlight.Enabled = true
	end

	function runtime.scheduleObjectReconcile()
		if runtime.reconcileObjectHighlights == nil or runtime.objectRefreshQueued or cleaning or not runtime.anyObjectEspEnabled() then
			return
		end

		runtime.objectRefreshQueued = true
		task.defer(function()
			runtime.objectRefreshQueued = false
			if cleaning or refs.main == nil or refs.main.Parent == nil then
				return
			end

			runtime.reconcileObjectHighlights()
		end)
	end

	function runtime.reconcileDesiredHighlights(prefix, desired)
		for key, spec in pairs(desired) do
			runtime.ensureHighlight(key, spec.target, spec.fillColor, spec.outlineColor)
		end

		local toRemove = {}
		for key in pairs(runtime.highlightInstances) do
			if string.sub(key, 1, #prefix) == prefix and desired[key] == nil then
				table.insert(toRemove, key)
			end
		end

		for _, key in ipairs(toRemove) do
			runtime.removeHighlight(key)
		end
	end

	function runtime.markNamedTargetDirty(cacheKey, refreshNow)
		local entry = espObjectCache.named[cacheKey]
		if entry == nil then
			return
		end

		entry.dirty = true
		if refreshNow then
			runtime.scheduleObjectReconcile()
		end
	end

	function runtime.markIridiumDirty(refreshNow)
		espObjectCache.iridium.dirty = true
		if refreshNow then
			runtime.scheduleObjectReconcile()
		end
	end

	function runtime.getNamedTargets(cacheKey)
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

	function runtime.bindIridiumAttribute(descendant)
		if espObjectCache.iridium.attributeConnections[descendant] ~= nil then
			return
		end

		local ok, signal = pcall(function()
			return descendant:GetAttributeChangedSignal("CrystalFullness")
		end)

		if ok and signal ~= nil then
			espObjectCache.iridium.attributeConnections[descendant] = signal:Connect(function()
				runtime.markIridiumDirty(state.espObjectToggles.iridium)
			end)
		end
	end

	function runtime.collectIridiumTargets()
		if espObjectCache.iridium.dirty then
			disconnectConnectionMap(espObjectCache.iridium.attributeConnections)

			local grouped = {}
			local resources = Workspace:FindFirstChild("Resources")
			if resources ~= nil then
				for _, descendant in ipairs(resources:GetDescendants()) do
					local fullness = descendant:GetAttribute("CrystalFullness")
					if type(fullness) == "number" then
						runtime.bindIridiumAttribute(descendant)

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

	function runtime.collectDistanceTargets(cacheKey, maxDistance)
		local targets = {}
		local localPosition = getLocalRootPosition()
		if localPosition == nil then
			return targets
		end

		for _, carrier in ipairs(runtime.getNamedTargets(cacheKey)) do
			local position = getInstancePosition(carrier)
			if carrier.Parent ~= nil and position ~= nil and (position - localPosition).Magnitude <= maxDistance then
				table.insert(targets, carrier)
			end
		end

		return targets
	end

	local function emitStructureProductionNotification(structure, structureKind, productName)
		if productName == nil or not isEnemyStructure(structure) then
			return
		end

		local teamText = getStructureTeamText(structure)
		local teamColor = getStructureTeamColor(structure) or NativeUi.Theme.Warning
		emitIntelligenceNotification(
			("production:%s:%s:%s"):format(getInstanceKey(structure), structureKind, productName),
			5,
			"info",
			("%s production update"):format(structureKind),
			("%s is producing %s for %s."):format(structureKind, productName, teamText),
			teamColor,
			{ priority = 32, duration = 5 }
		)
	end

	local function bindStructureProductionIntelligence(structure, structureKind)
		if intelligenceStructureConnections[structure] ~= nil then
			return
		end

		local connectionList = {}
		intelligenceStructureConnections[structure] = connectionList

		local function refreshProduction()
			emitStructureProductionNotification(structure, structureKind, readStructureProduction(structure))
		end

		for _, attributeName in ipairs(PRODUCTION_ATTRIBUTES) do
			table.insert(connectionList, structure:GetAttributeChangedSignal(attributeName):Connect(refreshProduction))
		end

		table.insert(connectionList, structure.DescendantAdded:Connect(function(descendant)
			emitStructureProductionNotification(structure, structureKind, readProductionCarrierValue(descendant))
			if descendant:IsA("ValueBase") then
				table.insert(connectionList, descendant:GetPropertyChangedSignal("Value"):Connect(function()
					emitStructureProductionNotification(structure, structureKind, readProductionCarrierValue(descendant))
				end))
			end
		end))

		refreshProduction()
	end

	local function handleIntelligenceStructure(structure)
		structure = resolveStructureRoot(structure)
		if structure == nil or intelligenceKnownStructures[structure] == true then
			return
		end

		local structureKind, structureLevel = classifyIntelligenceStructure(structure)
		if structureKind == nil then
			return
		end

		intelligenceKnownStructures[structure] = true
		bindStructureProductionIntelligence(structure, structureKind)
		if not isEnemyStructure(structure) then
			return
		end

		local teamText = getStructureTeamText(structure)
		local teamIndex = structure:GetAttribute("TeamIndex")
		local firstKey = ("%s:%s"):format(structureKind, tostring(teamIndex or teamText))
		local isFirst = intelligenceFirstStructureSeen[firstKey] ~= true
		intelligenceFirstStructureSeen[firstKey] = true

		emitIntelligenceNotification(
			("structure:%s"):format(getInstanceKey(structure)),
			structureLevel == "info" and 20 or 60,
			structureLevel or "warning",
			(structureLevel == "info")
				and ("Enemy %s built"):format(structureKind)
				or (isFirst and ("First enemy %s built"):format(structureKind) or ("Enemy %s built"):format(structureKind)),
			("%s built %s for %s."):format(getStructureBuilderText(structure), structureKind, teamText),
			getStructureTeamColor(structure) or NativeUi.Theme.Warning,
			{ priority = structureLevel == "info" and 24 or (isFirst and 46 or 38), duration = 6 }
		)
	end

	local function scanIntelligenceStructures()
		local structuresRoot = getStructuresRoot()
		if structuresRoot == nil then
			return
		end

		for _, structure in ipairs(structuresRoot:GetChildren()) do
			handleIntelligenceStructure(structure)
		end
	end

	local watchedStructuresRoot = nil
	local structuresRootConnections = {}

	local function unbindStructuresRootWatcher()
		disconnectConnectionList(structuresRootConnections)
		structuresRootConnections = {}
		watchedStructuresRoot = nil
	end

	local function bindStructuresRootWatcher()
		local structuresRoot = getStructuresRoot()
		if structuresRoot == watchedStructuresRoot then
			return
		end

		unbindStructuresRootWatcher()
		if structuresRoot == nil then
			return
		end

		watchedStructuresRoot = structuresRoot
		table.insert(structuresRootConnections, structuresRoot.ChildAdded:Connect(function(structure)
			handleIntelligenceStructure(structure)
			if state.macroEnabled and runtime.reconcileObjectHighlights ~= nil then
				runtime.reconcileObjectHighlights()
			end
		end))
		table.insert(structuresRootConnections, structuresRoot.ChildRemoved:Connect(function(structure)
			intelligenceKnownStructures[structure] = nil
			disconnectConnectionList(intelligenceStructureConnections[structure])
			intelligenceStructureConnections[structure] = nil
			if state.macroEnabled and runtime.reconcileObjectHighlights ~= nil then
				runtime.reconcileObjectHighlights()
			end
		end))
		scanIntelligenceStructures()
	end

	function runtime.getNearestMacroStructure()
		local structuresRoot = getStructuresRoot()
		local localPosition = getLocalRootPosition()
		if structuresRoot == nil then
			return nil, nil, "structures"
		end
		if localPosition == nil then
			return nil, nil, "root"
		end

		local targetKey = getMacroKey(state.macroTargetKind)
		local bestStructure = nil
		local bestDistance = math.huge
		for _, structure in ipairs(structuresRoot:GetChildren()) do
			local structureKind = classifyIntelligenceStructure(structure)
			if structureKind ~= nil and getMacroKey(structureKind) == targetKey then
				local position = getInstancePosition(structure)
				if position ~= nil then
					local distance = (position - localPosition).Magnitude
					if distance < bestDistance then
						bestStructure = structure
						bestDistance = distance
					end
				end
			end
		end

		return bestStructure, bestDistance, nil
	end

	function runtime.setMacroStatus(text, color)
		state.macroStatus = tostring(text or "Macro idle")
		if refs.structureMacroStatusLabel ~= nil then
			refs.structureMacroStatusLabel.Text = state.macroStatus
			refs.structureMacroStatusLabel.TextColor3 = color or NativeUi.Theme.TextMuted
		end
	end

	function runtime.getMacroHandler(kind)
		local key = getMacroKey(kind)
		local handlerTables = {
			config.MacroHandlers,
			dartApi.MacroHandlers,
			dartApi.Macros,
		}

		for _, handlerTable in ipairs(handlerTables) do
			if type(handlerTable) == "table" then
				local handler = handlerTable[kind] or handlerTable[key]
				if type(handler) == "function" then
					return handler
				end
			end
		end

		if key == "arsenal" and type(dartApi.FireArsenalBuild) == "function" then
			return dartApi.FireArsenalBuild
		end

		return nil
	end

	function runtime.getMacroRemoteSpec(kind)
		local key = getMacroKey(kind)
		local specTables = {
			config.MacroRemotes,
			dartApi.MacroRemotes,
		}

		for _, specTable in ipairs(specTables) do
			if type(specTable) == "table" then
				local spec = specTable[kind] or specTable[key]
				if type(spec) == "table" then
					return spec
				end
			end
		end

		return nil
	end

	function runtime.runStructureMacro(structure, distance)
		local now = os.clock()
		if now - state.macroLastFireAt < state.macroCooldown then
			return
		end
		state.macroLastFireAt = now

		local context = {
			structure = structure,
			structureKind = state.macroTargetKind,
			weaponName = trimText(state.macroWeaponName),
			distance = distance,
			localPlayer = Players.LocalPlayer,
			state = state,
		}

		if context.structureKind == "Arsenal" and context.weaponName == "" then
			runtime.setMacroStatus("Enter a weapon name for Arsenal macro", NativeUi.Theme.Warning)
			return
		end

		local handler = runtime.getMacroHandler(context.structureKind)
		local ok, result
		if handler ~= nil then
			local handlerResults = { pcall(handler, context) }
			ok = handlerResults[1] and handlerResults[2] ~= false
			result = handlerResults[3] or handlerResults[2]
		else
			local spec = runtime.getMacroRemoteSpec(context.structureKind)
			if spec ~= nil then
				local remoteResults = { pcall(runMacroRemote, spec, context) }
				ok = remoteResults[1] and remoteResults[2] == true
				result = remoteResults[3] or remoteResults[2]
			else
				ok = false
				result = ("No macro handler configured for %s"):format(context.structureKind)
			end
		end

		if ok then
			runtime.setMacroStatus(
				("%s macro fired at %dm"):format(context.structureKind, math.floor(distance + 0.5)),
				NativeUi.Theme.Success
			)
		else
			runtime.setMacroStatus(tostring(result), NativeUi.Theme.Warning)
			if now - state.macroLastNotifyAt > 8 then
				state.macroLastNotifyAt = now
				emitNotification("warning", "Macro handler missing", tostring(result), { duration = 4 })
			end
		end
	end

	function runtime.updateStructureMacro()
		if not state.macroEnabled then
			return
		end

		local target, distance, missingReason = runtime.getNearestMacroStructure()
		local targetKey = target and getInstanceKey(target) or ""
		if targetKey ~= state.macroLastTargetKey then
			state.macroLastTargetKey = targetKey
			if runtime.reconcileObjectHighlights ~= nil then
				runtime.reconcileObjectHighlights()
			end
		end

		if target == nil then
			if missingReason == "root" then
				runtime.setMacroStatus("Waiting for local character root")
				return
			end

			runtime.setMacroStatus(("No %s structure found"):format(state.macroTargetKind))
			return
		end

		if distance == nil then
			runtime.setMacroStatus("Waiting for local character root")
			return
		end

		if distance > state.macroRange then
			runtime.setMacroStatus(("%s %dm away"):format(state.macroTargetKind, math.floor(distance + 0.5)))
			return
		end

		runtime.runStructureMacro(target, distance)
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

		runtime.reconcileDesiredHighlights("player:", desired)
	end

	runtime.reconcileObjectHighlights = function()
		local desired = {}

		if state.espObjectToggles.spawnPoint then
			for _, target in ipairs(runtime.getNamedTargets("spawnPoint")) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(255, 194, 102), Color3.fromRGB(255, 226, 160))
				desired["object:spawn:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		if state.espObjectToggles.wellPump then
			for _, target in ipairs(runtime.getNamedTargets("wellPump")) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(255, 140, 96), Color3.fromRGB(255, 190, 160))
				desired["object:pump:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		if state.espObjectToggles.iridium then
			for _, target in ipairs(runtime.collectIridiumTargets()) do
				desired["object:iridium:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = Color3.fromRGB(165, 126, 255),
					outlineColor = Color3.fromRGB(214, 197, 255),
				}
			end
		end

		if state.espObjectToggles.spireWell then
			for _, target in ipairs(runtime.collectDistanceTargets("spireWell", state.wellDistance)) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(110, 204, 255), Color3.fromRGB(186, 229, 255))
				desired["object:spire:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		if state.espObjectToggles.well then
			for _, target in ipairs(runtime.collectDistanceTargets("well", state.wellDistance)) do
				local fillColor, outlineColor = getStructureHighlightColors(target, Color3.fromRGB(126, 220, 255), Color3.fromRGB(190, 234, 255))
				desired["object:well:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		if state.macroEnabled then
			local target = runtime.getNearestMacroStructure()
			if target ~= nil then
				local fillColor, outlineColor = getStructureHighlightColors(target, NativeUi.Theme.Success, NativeUi.Theme.Success:Lerp(Color3.new(1, 1, 1), 0.3))
				desired["object:macro:" .. getInstanceKey(target)] = {
					target = target,
					fillColor = fillColor,
					outlineColor = outlineColor,
				}
			end
		end

		runtime.reconcileDesiredHighlights("object:", desired)
	end

	function runtime.clearAllHighlights()
		local toRemove = {}
		for key in pairs(runtime.highlightInstances) do
			table.insert(toRemove, key)
		end

		for _, key in ipairs(toRemove) do
			runtime.removeHighlight(key)
		end
	end

	function runtime.ensurePlayerCharacterConnection(player)
		if runtime.playerCharacterConnections[player] ~= nil then
			return
		end

		runtime.playerCharacterConnections[player] = player.CharacterAdded:Connect(function()
			reconcilePlayerHighlights()
			if runtime.refreshPlayersList then
				runtime.refreshPlayersList()
			end
			if runtime.refreshEspPlayersList then
				runtime.refreshEspPlayersList()
			end
		end)
	end

	function runtime.ensurePlayerTeamConnection(player)
		if runtime.playerTeamConnections[player] ~= nil then
			return
		end

		runtime.playerTeamConnections[player] = {
			player:GetPropertyChangedSignal("Team"):Connect(function()
				reconcilePlayerHighlights()
				if runtime.refreshPlayersList then
					runtime.refreshPlayersList()
				end
				if syncControlState then
					syncControlState()
				end
			end),
			player:GetPropertyChangedSignal("TeamColor"):Connect(function()
				reconcilePlayerHighlights()
				if runtime.refreshPlayersList then
					runtime.refreshPlayersList()
				end
				if syncControlState then
					syncControlState()
				end
			end),
		}
	end

	runtime.refreshPlayersList = function()
		NativeUi.clear(refs.spyMemberContent)

		local players = Players:GetPlayers()
		table.sort(players, function(left, right)
			return string.lower(left.Name) < string.lower(right.Name)
		end)

		local shown = 0
		for _, player in ipairs(players) do
			if player ~= Players.LocalPlayer then
				runtime.ensurePlayerCharacterConnection(player)
				runtime.ensurePlayerTeamConnection(player)

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
					runtime.refreshPlayersList()
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

	runtime.refreshEspPlayersList = function()
		NativeUi.clear(refs.espPlayerContent)

		local players = Players:GetPlayers()
		table.sort(players, function(left, right)
			return string.lower(left.Name) < string.lower(right.Name)
		end)

		local shown = 0
		for _, player in ipairs(players) do
			if player ~= Players.LocalPlayer then
				runtime.ensurePlayerCharacterConnection(player)
				runtime.ensurePlayerTeamConnection(player)

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
						runtime.refreshEspPlayersList()
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

	local function syncOperatorControls()
		pruneGhostCharacters()
		local ghostCount = #state.ghostCharacters
		local selectedGhost = getSelectedGhostSlot()
		if selectedGhost == nil then
			refs.ghostStatusLabel.Text = "No local characters created"
		else
			refs.ghostStatusLabel.Text = ("%d/%d  %s%s"):format(
				state.selectedGhostIndex,
				ghostCount,
				selectedGhost.name,
				state.ghostCharacterEnabled and "  [controlling]" or ""
			)
			if not refs.ghostNameBox:IsFocused() then
				refs.ghostNameBox.Text = selectedGhost.name
			end
		end

		NativeUi.setButtonDisabled(refs.ghostPrevButton, ghostCount < 2)
		NativeUi.setButtonDisabled(refs.ghostNextButton, ghostCount < 2)
		NativeUi.setButtonDisabled(refs.ghostDestroyButton, ghostCount == 0)

		local perspectiveCount = #state.cameraPerspectives
		local perspective = getSelectedCameraPerspective()
		if perspective == nil then
			refs.cameraPerspectiveStatusLabel.Text = "No saved camera perspectives"
		else
			refs.cameraPerspectiveStatusLabel.Text = ("%d/%d  %s"):format(state.selectedCameraPerspectiveIndex, perspectiveCount, perspective.name)
			if not refs.cameraPerspectiveNameBox:IsFocused() then
				refs.cameraPerspectiveNameBox.Text = perspective.name
			end
		end

		NativeUi.setButtonDisabled(refs.cameraPrevButton, perspectiveCount < 2)
		NativeUi.setButtonDisabled(refs.cameraNextButton, perspectiveCount < 2)
		NativeUi.setButtonDisabled(refs.cameraRenameButton, perspectiveCount == 0)
		NativeUi.setButtonDisabled(refs.cameraDestroyButton, perspectiveCount == 0)
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
		syncToggleButton(refs.noFallDamageToggle, state.noFallDamage)
		syncToggleButton(refs.antiFallToggle, state.antiFall)
		syncToggleButton(refs.noOceanDamageToggle, state.noOceanDamage)
		syncToggleButton(refs.phantomStepToggle, state.phantomStepEnabled)
		syncToggleButton(refs.aimbotToggle, state.aimbotEnabled)
		syncToggleButton(refs.autoFireToggle, state.autoFireEnabled)
		syncToggleButton(refs.spawnPointToggle, state.espObjectToggles.spawnPoint)
		syncToggleButton(refs.wellPumpToggle, state.espObjectToggles.wellPump)
		syncToggleButton(refs.iridiumToggle, state.espObjectToggles.iridium)
		syncToggleButton(refs.spireWellToggle, state.espObjectToggles.spireWell)
		syncToggleButton(refs.wellToggle, state.espObjectToggles.well)
		syncToggleButton(refs.remoteWatcherToggle, state.remoteWatcherEnabled)
		syncToggleButton(refs.spyGhostToggle, state.ghostCharacterEnabled)
		syncToggleButton(refs.spyGhostFlyToggle, state.ghostFlyEnabled)
		syncToggleButton(refs.spyFreeCameraToggle, state.freeCameraEnabled)
		syncToggleButton(refs.structureMacroToggle, state.macroEnabled)
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
		refs.structureMacroTargetButton.Text = "Target: " .. state.macroTargetKind
		if not refs.structureMacroWeaponBox:IsFocused() then
			refs.structureMacroWeaponBox.Text = state.macroWeaponName
		end
		refs.structureMacroStatusLabel.Text = state.macroStatus
		refs.autoFireStatusLabel.Text = state.autoFireStatus
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
		syncOperatorControls()
		updateSuiteOverlays()
	end

	function runtime.applyNumericAction(actionName, value, label)
		local ok, result = runMainAction(actionName, value)
		if ok then
			setMainStatus(tostring(result or (label .. " updated")), NativeUi.Theme.Success)
			refreshMainFields()
			refs.walkSpeedController.setValue(state.walkSpeedValue)
			refs.jumpPowerController.setValue(state.jumpPowerValue)
			refs.hipHeightController.setValue(state.hipHeightValue)
			refs.gravityController.setValue(state.gravityValue)
			return
		end

		setMainStatus(tostring(result), NativeUi.Theme.Error)
	end

	function runtime.toggleFeature(toggleName)
		local nextValue = not state[toggleName]
		local ok, result = setToggleState(toggleName, nextValue)
		if ok then
			if toggleName == "antiFall" then
				runtime.resetAntiFall()
			end
			setMainStatus(tostring(result), NativeUi.Theme.Success)
		else
			setMainStatus(tostring(result), NativeUi.Theme.Error)
		end

		syncControlState()
	end

	function runtime.toggleAimbot()
		state.aimbotEnabled = not state.aimbotEnabled
		if not state.aimbotEnabled then
			setAimbotHoldActive(false)
		else
			syncControlState()
		end
	end

	function runtime.setAimTargetMode(mode)
		state.aimTargetPart = mode
		clearAimbotLock()
		if state.aimHoldActive then
			acquireAimbotTarget()
		end
		syncControlState()
	end

	function runtime.toggleEspObject(toggleName)
		state.espObjectToggles[toggleName] = not state.espObjectToggles[toggleName]
		if toggleName == "spireWell" or toggleName == "well" then
			runtime.distanceRefreshAccumulator = 0
			runtime.lastDistanceRefreshPosition = nil
		end
		runtime.reconcileObjectHighlights()
		syncControlState()
	end

	function runtime.handleEspDescendantMutation(descendant)
		local name = descendant.Name
		if name == "Spawn Point" then
			runtime.markNamedTargetDirty("spawnPoint", state.espObjectToggles.spawnPoint)
		elseif name == "Well Pump" then
			runtime.markNamedTargetDirty("wellPump", state.espObjectToggles.wellPump)
		elseif name == "SpireOpenLarge1" or name == "Map" then
			runtime.markNamedTargetDirty("spireWell", state.espObjectToggles.spireWell)
		elseif name == "Top1" or name == "Map" then
			runtime.markNamedTargetDirty("well", state.espObjectToggles.well)
		end

		if name == "Resources"
			or descendant:FindFirstAncestor("Resources") ~= nil
			or type(descendant:GetAttribute("CrystalFullness")) == "number" then
			runtime.markIridiumDirty(state.espObjectToggles.iridium)
		end
	end

	function runtime.finishStartup()
		refreshMainFields()
		refs.walkSpeedController.setValue(state.walkSpeedValue)
		refs.jumpPowerController.setValue(state.jumpPowerValue)
		refs.hipHeightController.setValue(state.hipHeightValue)
		refs.gravityController.setValue(state.gravityValue)
		refs.ghostFlySpeedController.setValue(state.ghostFlySpeed)
		refs.freeCameraSpeedController.setValue(state.freeCameraSpeed)
		refs.freeCameraFastSpeedController.setValue(state.freeCameraFastSpeed)
		refs.autoFireRangeController.setValue(state.autoFireRange)
		refs.iridiumController.setValue(state.iridiumMinFullness)
		refs.wellDistanceController.setValue(state.wellDistance)
		refs.structureMacroRangeController.setValue(state.macroRange)
		for _, player in ipairs(Players:GetPlayers()) do
			bindIntelligencePlayer(player)
		end
		bindStructuresRootWatcher()
		updateIntelligenceThreat()
		runtime.refreshPlayersList()
		runtime.refreshEspPlayersList()
		refreshScriptBrowser(false)
		refs.remoteSpy:Scan()
		refs.remoteSpy:BindMutationWatchers()
		renderRemoteList()
		renderRemoteLog()
		reconcilePlayerHighlights()
		runtime.reconcileObjectHighlights()
		syncControlState()
		renderTreeView()
		renderOutputView()
		setMainStatus("Ready", NativeUi.Theme.TextMuted)
	end

	trackCleanup(function()
		if state.phantomStepEnabled then
			refs.setPhantomStepEnabled(false)
		else
			refs.destroyPhantomCharacter()
		end
		if state.freeCameraEnabled then
			setFreeCameraEnabled(false)
		else
			unbindFreeCameraInputSink()
		end
		if state.ghostCharacterEnabled then
			setGhostCharacterEnabled(false)
		else
			setBackpackHiddenForGhost(false)
		end
		destroyAllGhostCharacters()
	end)
	trackCleanup(restoreLighting)
	trackCleanup(function()
		unbindStructuresRootWatcher()
		for player in pairs(intelligencePlayerConnections) do
			unbindIntelligencePlayer(player)
		end
		for structure, connectionList in pairs(intelligenceStructureConnections) do
			disconnectConnectionList(connectionList)
			intelligenceStructureConnections[structure] = nil
		end
		for player, connection in pairs(runtime.playerCharacterConnections) do
			pcall(function()
				connection:Disconnect()
			end)
			runtime.playerCharacterConnections[player] = nil
		end
		for player, connectionGroup in pairs(runtime.playerTeamConnections) do
			for _, connection in pairs(connectionGroup) do
				pcall(function()
					connection:Disconnect()
				end)
			end
			runtime.playerTeamConnections[player] = nil
		end
		disconnectConnectionMap(espObjectCache.iridium.attributeConnections)
		runtime.clearAllHighlights()
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

	trackConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed or UserInputService:GetFocusedTextBox() ~= nil then
			return
		end

		if state.antiFallDisableKeyCode == nil or input.KeyCode ~= state.antiFallDisableKeyCode or not state.antiFall then
			return
		end

		runtime.toggleFeature("antiFall")
		runtime.resetAntiFall()
		setMainStatus("Anti Fall disabled by keybind", NativeUi.Theme.Warning)
	end))

	trackConnection(RunService.Stepped:Connect(function(_, deltaTime)
		runtime.updateAntiFall(deltaTime)

		if not state.noClip then
			if runtime.noClipCharacter ~= nil or #runtime.noClipParts > 0 then
				runtime.noClipCharacter = nil
				runtime.noClipParts = {}
				runtime.noClipRefreshAccumulator = 0
			end
			return
		end

		local character = getLocalCharacter()
		if character == nil then
			return
		end

		runtime.noClipRefreshAccumulator = runtime.noClipRefreshAccumulator + (deltaTime or 0)
		if runtime.noClipCharacter ~= character or runtime.noClipRefreshAccumulator >= 0.5 then
			runtime.noClipCharacter = character
			runtime.noClipRefreshAccumulator = 0
			runtime.noClipParts = {}
			for _, descendant in ipairs(character:GetDescendants()) do
				if descendant:IsA("BasePart") then
					table.insert(runtime.noClipParts, descendant)
				end
			end
		end

		for index = #runtime.noClipParts, 1, -1 do
			local part = runtime.noClipParts[index]
			if part == nil or part.Parent == nil then
				table.remove(runtime.noClipParts, index)
			elseif part.CanCollide then
				part.CanCollide = false
			end
		end
	end))

	trackConnection(RunService.RenderStepped:Connect(function(deltaTime)
		updateFreeCamera(deltaTime)
		updateGhostMovement(deltaTime)
		refs.updatePhantomStep(deltaTime)
		if state.freeCameraEnabled then
			return
		end

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
		intelligenceHeartbeatAccumulator = intelligenceHeartbeatAccumulator + deltaTime
		runtime.autoFireHeartbeatAccumulator = runtime.autoFireHeartbeatAccumulator + deltaTime
		runtime.macroHeartbeatAccumulator = runtime.macroHeartbeatAccumulator + deltaTime
		if runtime.autoFireHeartbeatAccumulator >= 0.12 then
			runtime.autoFireHeartbeatAccumulator = 0
			updateAutoFire()
		end

		if runtime.macroHeartbeatAccumulator >= 0.25 then
			runtime.macroHeartbeatAccumulator = 0
			runtime.updateStructureMacro()
		end

		if intelligenceHeartbeatAccumulator < 0.35 then
			return
		end

		intelligenceHeartbeatAccumulator = 0
		updateIntelligenceThreat()
		local threat = state.intelligenceThreat
		local nextKey = threat
			and ("%s:%s:%d"):format(threat.playerName, tostring(threat.weaponName or "unknown"), math.floor(threat.distance + 0.5))
			or ""
		local changed = nextKey ~= state.intelligenceThreatKey
		state.intelligenceThreatKey = nextKey
		if changed then
			updateSuiteOverlays()
		end
	end))

	trackConnection(RunService.Heartbeat:Connect(function(deltaTime)
		if not (state.espObjectToggles.spireWell or state.espObjectToggles.well) then
			runtime.distanceRefreshAccumulator = 0
			runtime.lastDistanceRefreshPosition = nil
			return
		end

		runtime.distanceRefreshAccumulator = runtime.distanceRefreshAccumulator + deltaTime
		if runtime.distanceRefreshAccumulator < 0.4 then
			return
		end

		local localPosition = getLocalRootPosition()
		if localPosition == nil then
			runtime.distanceRefreshAccumulator = 0
			if runtime.lastDistanceRefreshPosition ~= nil then
				runtime.lastDistanceRefreshPosition = nil
				runtime.reconcileObjectHighlights()
			end
			return
		end

		local movedEnough = runtime.lastDistanceRefreshPosition == nil
			or (localPosition - runtime.lastDistanceRefreshPosition).Magnitude >= 18
			or runtime.distanceRefreshAccumulator >= 1.2
		if not movedEnough then
			return
		end

		runtime.distanceRefreshAccumulator = 0
		runtime.lastDistanceRefreshPosition = localPosition
		runtime.reconcileObjectHighlights()
	end))
	trackConnection(Workspace.DescendantAdded:Connect(function(descendant)
		runtime.handleEspDescendantMutation(descendant)
		if descendant.Name == "Structures" and descendant.Parent == Workspace then
			task.defer(bindStructuresRootWatcher)
		end
	end))
	trackConnection(Workspace.DescendantRemoving:Connect(runtime.handleEspDescendantMutation))
	bindScriptBrowserMutationWatchers()

	if Players.LocalPlayer ~= nil then
		trackConnection(Players.LocalPlayer.CharacterAdded:Connect(function(character)
			if character == state.phantomCharacter then
				return
			end
			if state.phantomStepEnabled then
				state.phantomRealCharacter = character
				return
			end
			if character == state.ghostCharacter then
				return
			end

			state.realCharacterBeforeGhost = character
			if state.ghostCharacterEnabled and state.ghostCharacter ~= nil and state.ghostCharacter.Parent ~= nil then
				task.defer(function()
					if not state.ghostCharacterEnabled or state.ghostCharacter == nil or state.ghostCharacter.Parent == nil then
						return
					end

					pcall(function()
						Players.LocalPlayer.Character = state.ghostCharacter
					end)
					setCameraSubjectToCharacter(state.ghostCharacter)
				end)
			elseif not state.freeCameraEnabled then
				setCameraSubjectToCharacter(character)
			end
		end))
	end

	trackConnection(Players.PlayerAdded:Connect(runtime.refreshPlayersList))
	trackConnection(Players.PlayerAdded:Connect(function(player)
		bindIntelligencePlayer(player)
		runtime.ensurePlayerCharacterConnection(player)
		runtime.ensurePlayerTeamConnection(player)
		runtime.refreshEspPlayersList()
		reconcilePlayerHighlights()
	end))
	trackConnection(Players.PlayerRemoving:Connect(function(player)
		if state.selectedPlayerName == player.Name then
			state.selectedPlayerName = Players.LocalPlayer and Players.LocalPlayer.Name or ""
		end

		state.highlightedPlayers[player.Name] = nil
		unbindIntelligencePlayer(player)
		local connection = runtime.playerCharacterConnections[player]
		if connection ~= nil then
			pcall(function()
				connection:Disconnect()
			end)
			runtime.playerCharacterConnections[player] = nil
		end
		local connectionGroup = runtime.playerTeamConnections[player]
		if connectionGroup ~= nil then
			for _, teamConnection in pairs(connectionGroup) do
				pcall(function()
					teamConnection:Disconnect()
				end)
			end
			runtime.playerTeamConnections[player] = nil
		end

		runtime.removeHighlight("player:" .. player.Name)
		runtime.refreshPlayersList()
		runtime.refreshEspPlayersList()
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
		runtime.refreshEspPlayersList()
	end))
	trackConnection(refs.filterBox:GetPropertyChangedSignal("Text"):Connect(function()
		state.filterText = refs.filterBox.Text
		renderOutputView()
	end))
	trackConnection(refs.highlightAllPlayersButton.MouseButton1Click:Connect(function()
		state.highlightAllPlayers = not state.highlightAllPlayers
		reconcilePlayerHighlights()
		runtime.refreshEspPlayersList()
		syncControlState()
	end))
	trackConnection(refs.clearPlayerHighlightsButton.MouseButton1Click:Connect(function()
		state.highlightedPlayers = {}
		state.highlightAllPlayers = false
		reconcilePlayerHighlights()
		runtime.refreshEspPlayersList()
		syncControlState()
	end))
	trackConnection(refs.remoteWatcherToggle.toggle.MouseButton1Click:Connect(function()
		state.remoteWatcherEnabled = not state.remoteWatcherEnabled
		refs.remoteSpy:SetEnabled(state.remoteWatcherEnabled)
		renderRemoteList()
		renderRemoteLog()
		syncControlState()
	end))
	trackConnection(refs.scanRemotesButton.MouseButton1Click:Connect(function()
		refs.remoteSpy:Scan()
		renderRemoteList()
		renderRemoteLog()
	end))
	trackConnection(refs.clearRemoteLogButton.MouseButton1Click:Connect(function()
		refs.remoteSpy:ClearLogs()
		state.selectedRemoteCallId = nil
		renderRemoteList()
		renderRemoteLog()
	end))
	trackConnection(refs.copyRemotePayloadButton.MouseButton1Click:Connect(function()
		local record = state.selectedRemoteKey ~= nil and refs.remoteSpy:GetRecord(state.selectedRemoteKey) or nil
		local call = record ~= nil and refs.remoteSpy:GetCall(record, state.selectedRemoteCallId) or nil
		if call == nil then
			setSuiteStatus("No remote payload selected", NativeUi.Theme.Error)
			return
		end

		local copied, copyError = writeClipboard(formatRemoteCallPayload(call))
		setSuiteStatus(copied and "Copied remote payload" or tostring(copyError), copied and NativeUi.Theme.Success or NativeUi.Theme.Error)
	end))
	trackConnection(refs.copyRemoteReplayButton.MouseButton1Click:Connect(function()
		local record = state.selectedRemoteKey ~= nil and refs.remoteSpy:GetRecord(state.selectedRemoteKey) or nil
		local call = record ~= nil and refs.remoteSpy:GetCall(record, state.selectedRemoteCallId) or nil
		if call == nil then
			setSuiteStatus("No remote call selected", NativeUi.Theme.Error)
			return
		end

		local copied, copyError = writeClipboard(formatRemoteReplay(call))
		setSuiteStatus(copied and "Copied remote replay" or tostring(copyError), copied and NativeUi.Theme.Success or NativeUi.Theme.Error)
	end))
	trackConnection(refs.spyClearButton.MouseButton1Click:Connect(function()
		state.selectedPlayerName = ""
		runtime.refreshPlayersList()
		syncControlState()
	end))
	trackConnection(refs.spyPinButton.MouseButton1Click:Connect(function()
		runtime.refreshPlayersList()
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
		runtime.refreshEspPlayersList()
		runtime.refreshPlayersList()
		syncControlState()
	end))
	trackConnection(refs.spyGhostToggle.toggle.MouseButton1Click:Connect(function()
		setGhostCharacterEnabled(not state.ghostCharacterEnabled)
		syncControlState()
	end))
	trackConnection(refs.spyGhostFlyToggle.toggle.MouseButton1Click:Connect(function()
		if not state.ghostCharacterEnabled then
			setGhostCharacterEnabled(true)
		end
		setGhostFlyEnabled(not state.ghostFlyEnabled)
		syncControlState()
	end))
	trackConnection(refs.ghostNewButton.MouseButton1Click:Connect(function()
		createNewGhostCharacterFromInput()
		syncControlState()
	end))
	trackConnection(refs.ghostPrevButton.MouseButton1Click:Connect(function()
		selectGhostOffset(-1)
		syncControlState()
	end))
	trackConnection(refs.ghostNextButton.MouseButton1Click:Connect(function()
		selectGhostOffset(1)
		syncControlState()
	end))
	trackConnection(refs.ghostDestroyButton.MouseButton1Click:Connect(function()
		destroySelectedGhostCharacter()
		syncControlState()
	end))
	trackConnection(refs.spyFreeCameraToggle.toggle.MouseButton1Click:Connect(function()
		setFreeCameraEnabled(not state.freeCameraEnabled)
		syncControlState()
	end))
	trackConnection(refs.cameraSaveButton.MouseButton1Click:Connect(function()
		saveCameraPerspective()
		syncControlState()
	end))
	trackConnection(refs.cameraPrevButton.MouseButton1Click:Connect(function()
		selectCameraPerspectiveOffset(-1)
		syncControlState()
	end))
	trackConnection(refs.cameraNextButton.MouseButton1Click:Connect(function()
		selectCameraPerspectiveOffset(1)
		syncControlState()
	end))
	trackConnection(refs.cameraRenameButton.MouseButton1Click:Connect(function()
		renameSelectedCameraPerspective()
		syncControlState()
	end))
	trackConnection(refs.cameraDestroyButton.MouseButton1Click:Connect(function()
		destroySelectedCameraPerspective()
		syncControlState()
	end))
	trackConnection(refs.walkSlider.applyButton.MouseButton1Click:Connect(function()
		runtime.applyNumericAction("setWalkSpeed", math.floor(refs.walkSpeedController.getValue() + 0.5), "WalkSpeed")
	end))
	trackConnection(refs.jumpSlider.applyButton.MouseButton1Click:Connect(function()
		runtime.applyNumericAction("setJumpPower", math.floor(refs.jumpPowerController.getValue() + 0.5), "JumpPower")
	end))
	trackConnection(refs.hipSlider.applyButton.MouseButton1Click:Connect(function()
		runtime.applyNumericAction("setHipHeight", refs.hipHeightController.getValue(), "HipHeight")
	end))
	trackConnection(refs.gravitySlider.applyButton.MouseButton1Click:Connect(function()
		runtime.applyNumericAction("setGravity", math.floor(refs.gravityController.getValue() + 0.5), "Gravity")
	end))
	trackConnection(refs.refreshStatsButton.MouseButton1Click:Connect(function()
		refreshMainFields()
		refs.walkSpeedController.setValue(state.walkSpeedValue)
		refs.jumpPowerController.setValue(state.jumpPowerValue)
		refs.hipHeightController.setValue(state.hipHeightValue)
		refs.gravityController.setValue(state.gravityValue)
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
	trackConnection(refs.structureMacroToggle.toggle.MouseButton1Click:Connect(function()
		state.macroEnabled = not state.macroEnabled
		if state.macroEnabled then
			bindStructuresRootWatcher()
			runtime.updateStructureMacro()
		else
			state.macroLastTargetKey = ""
			runtime.setMacroStatus("Macro idle")
		end
		runtime.reconcileObjectHighlights()
		syncControlState()
	end))
	trackConnection(refs.structureMacroTargetButton.MouseButton1Click:Connect(function()
		local currentIndex = 1
		for index, kind in ipairs(MACRO_STRUCTURE_KINDS) do
			if kind == state.macroTargetKind then
				currentIndex = index
				break
			end
		end
		state.macroTargetKind = MACRO_STRUCTURE_KINDS[(currentIndex % #MACRO_STRUCTURE_KINDS) + 1]
		state.macroLastTargetKey = ""
		runtime.setMacroStatus(("Targeting %s"):format(state.macroTargetKind))
		runtime.reconcileObjectHighlights()
		syncControlState()
	end))
	trackConnection(refs.structureMacroWeaponBox.FocusLost:Connect(function()
		state.macroWeaponName = trimText(refs.structureMacroWeaponBox.Text)
		syncControlState()
	end))
	trackConnection(refs.structureMacroRangeSlider.applyButton.MouseButton1Click:Connect(function()
		state.macroRange = math.floor(refs.structureMacroRangeController.getValue() + 0.5)
		runtime.setMacroStatus(("Range set to %dm"):format(state.macroRange), NativeUi.Theme.Success)
		runtime.updateStructureMacro()
		syncControlState()
	end))
	trackConnection(refs.aimbotToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleAimbot()
	end))
	trackConnection(refs.autoFireToggle.toggle.MouseButton1Click:Connect(function()
		state.autoFireEnabled = not state.autoFireEnabled
		if state.autoFireEnabled then
			updateAutoFire()
		else
			setAutoFireStatus("Auto-fire idle")
		end
		syncControlState()
	end))
	trackConnection(refs.autoFireRangeSlider.applyButton.MouseButton1Click:Connect(function()
		state.autoFireRange = math.floor(refs.autoFireRangeController.getValue() + 0.5)
		setAutoFireStatus(("Range set to %dm"):format(state.autoFireRange), NativeUi.Theme.Success)
		updateAutoFire()
		syncControlState()
	end))
	trackConnection(refs.aimNearestButton.MouseButton1Click:Connect(function()
		runtime.setAimTargetMode("nearest")
	end))
	trackConnection(refs.aimHeadButton.MouseButton1Click:Connect(function()
		runtime.setAimTargetMode("head")
	end))
	trackConnection(refs.aimTorsoButton.MouseButton1Click:Connect(function()
		runtime.setAimTargetMode("torso")
	end))
	trackConnection(refs.aimArmsButton.MouseButton1Click:Connect(function()
		runtime.setAimTargetMode("arms")
	end))
	trackConnection(refs.aimLegsButton.MouseButton1Click:Connect(function()
		runtime.setAimTargetMode("legs")
	end))
	trackConnection(refs.aimLimbsButton.MouseButton1Click:Connect(function()
		runtime.setAimTargetMode("limbs")
	end))
	trackConnection(refs.infiniteJumpToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleFeature("infiniteJump")
	end))
	trackConnection(refs.noClipToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleFeature("noClip")
	end))
	trackConnection(refs.fullBrightToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleFeature("fullBright")
	end))
	trackConnection(refs.noFallDamageToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleFeature("noFallDamage")
	end))
	trackConnection(refs.antiFallToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleFeature("antiFall")
	end))
	trackConnection(refs.noOceanDamageToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleFeature("noOceanDamage")
	end))
	trackConnection(refs.phantomStepToggle.toggle.MouseButton1Click:Connect(function()
		refs.setPhantomStepEnabled(not state.phantomStepEnabled)
		syncControlState()
	end))
	trackConnection(refs.spawnPointToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleEspObject("spawnPoint")
	end))
	trackConnection(refs.wellPumpToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleEspObject("wellPump")
	end))
	trackConnection(refs.iridiumToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleEspObject("iridium")
	end))
	trackConnection(refs.spireWellToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleEspObject("spireWell")
	end))
	trackConnection(refs.wellToggle.toggle.MouseButton1Click:Connect(function()
		runtime.toggleEspObject("well")
	end))
	trackConnection(refs.iridiumSlider.applyButton.MouseButton1Click:Connect(function()
		state.iridiumMinFullness = refs.iridiumController.getValue()
		runtime.reconcileObjectHighlights()
		syncControlState()
	end))
	trackConnection(refs.wellDistanceSlider.applyButton.MouseButton1Click:Connect(function()
		state.wellDistance = math.floor(refs.wellDistanceController.getValue() + 0.5)
		runtime.reconcileObjectHighlights()
		syncControlState()
	end))

	runtime.finishStartup()
end

return BytecodeViewer
