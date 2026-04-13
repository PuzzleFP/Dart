local LuauChunk = require(script.Parent:WaitForChild("LuauChunk"))

local LuauFileRunner = {}

function LuauFileRunner.run(path, options)
	local output, chunk = LuauChunk.inspectFile(path, options)
	return output, chunk
end

function LuauFileRunner.read(path, options)
	local chunk = LuauChunk.parseFile(path, options)
	return LuauChunk.formatPrettyChunk(chunk, options), chunk
end

return LuauFileRunner
