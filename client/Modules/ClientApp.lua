local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Helpers = require(script.Parent:WaitForChild("Helpers"))
local IrisBytecodeViewer = require(script.Parent:WaitForChild("IrisBytecodeViewer"))

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
