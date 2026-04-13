local modulesFolder = script:WaitForChild("Modules")
local Config = require(modulesFolder:WaitForChild("Config"))
local ClientApp = require(modulesFolder:WaitForChild("ClientApp"))

local ok, err = pcall(function()
	ClientApp.start(Config)
end)

if not ok then
	warn(("[Client] %s failed to start: %s"):format(Config.GameName, err))
end
