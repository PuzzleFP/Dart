local StarterGui = game:GetService("StarterGui")

local Helpers = {}

function Helpers.debugPrint(enabled, message)
	if enabled then
		print(message)
	end
end

function Helpers.getLocalCharacter(localPlayer)
	return localPlayer.Character or localPlayer.CharacterAdded:Wait()
end

function Helpers.safeNotify(title, text)
	pcall(function()
		StarterGui:SetCore("SendNotification", {
			Title = title,
			Text = text,
			Duration = 4,
		})
	end)
end

return Helpers
