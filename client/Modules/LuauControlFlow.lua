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

local LuauBytecode = loadRemoteModule("LuauBytecode")

local LuauControlFlow = {}

local CONDITIONAL_JUMPS = {
	JUMPIF = true,
	JUMPIFNOT = true,
	JUMPIFEQ = true,
	JUMPIFLE = true,
	JUMPIFLT = true,
	JUMPIFNOTEQ = true,
	JUMPIFNOTLE = true,
	JUMPIFNOTLT = true,
	JUMPXEQKNIL = true,
	JUMPXEQKB = true,
	JUMPXEQKN = true,
	JUMPXEQKS = true,
}

local UNCONDITIONAL_JUMPS = {
	JUMP = true,
	JUMPBACK = true,
	JUMPX = true,
}

local RETURNS = {
	RETURN = true,
}

local LOOP_OPS = {
	FORNPREP = true,
	FORNLOOP = true,
	FORGPREP = true,
	FORGPREP_INEXT = true,
	FORGPREP_NEXT = true,
	FORGLOOP = true,
}

local function sortedKeys(map)
	local keys = {}
	for key in pairs(map) do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function makeSet(values)
	local set = {}
	for _, value in ipairs(values) do
		set[value] = true
	end
	return set
end

local function cloneSet(set)
	local copy = {}
	for key, value in pairs(set) do
		if value then
			copy[key] = true
		end
	end
	return copy
end

local function setsEqual(left, right)
	for key, value in pairs(left) do
		if value and not right[key] then
			return false
		end
	end

	for key, value in pairs(right) do
		if value and not left[key] then
			return false
		end
	end

	return true
end

local function intersectSets(left, right)
	local result = {}
	for key, value in pairs(left) do
		if value and right[key] then
			result[key] = true
		end
	end
	return result
end

local function instructionEndPc(instruction)
	return instruction.pc + (instruction.length or 1)
end

local function isKnownInstructionPc(pcToInstruction, pc)
	return pcToInstruction[pc] ~= nil
end

local function addLeader(leaders, pcToInstruction, pc)
	if pc ~= nil and isKnownInstructionPc(pcToInstruction, pc) then
		leaders[pc] = true
	end
end

local function classifyTerminator(instruction)
	local name = instruction.name

	if RETURNS[name] then
		return "return"
	end

	if UNCONDITIONAL_JUMPS[name] then
		return "jump"
	end

	if CONDITIONAL_JUMPS[name] then
		return "branch"
	end

	if LOOP_OPS[name] then
		return "loop"
	end

	if name == "LOADB" and instruction.jumpTargetPc ~= nil then
		return "skip"
	end

	return "fallthrough"
end

local function addEdge(block, toId, kind)
	if toId == nil then
		return
	end

	table.insert(block.successors, {
		to = toId,
		kind = kind,
	})
end

local function findBlockByPc(blockByStartPc, pc)
	if pc == nil then
		return nil
	end

	local block = blockByStartPc[pc]
	return block and block.id or nil
end

local function computeDominators(blocks)
	if #blocks == 0 then
		return
	end

	local allIds = {}
	for _, block in ipairs(blocks) do
		table.insert(allIds, block.id)
	end

	local allSet = makeSet(allIds)
	for index, block in ipairs(blocks) do
		if index == 1 then
			block.dominators = { [block.id] = true }
		else
			block.dominators = cloneSet(allSet)
		end
	end

	local changed = true
	while changed do
		changed = false

		for index = 2, #blocks do
			local block = blocks[index]
			local nextDominators

			if #block.predecessors == 0 then
				nextDominators = {}
			else
				for predIndex, predecessorId in ipairs(block.predecessors) do
					local predecessor = blocks[predecessorId]
					if predIndex == 1 then
						nextDominators = cloneSet(predecessor.dominators)
					else
						nextDominators = intersectSets(nextDominators, predecessor.dominators)
					end
				end
			end

			nextDominators[block.id] = true

			if not setsEqual(block.dominators, nextDominators) then
				block.dominators = nextDominators
				changed = true
			end
		end
	end
end

local function markLoopEdges(blocks)
	for _, block in ipairs(blocks) do
		for _, edge in ipairs(block.successors) do
			local target = blocks[edge.to]
			if target ~= nil and block.dominators ~= nil and block.dominators[target.id] then
				edge.kind = edge.kind == "fallthrough" and "loop" or (edge.kind .. "+loop")
				block.isLoopLatch = true
				target.isLoopHeader = true
			end
		end
	end
end

local function buildLowIr(block)
	local low = {}
	for _, instruction in ipairs(block.instructions) do
		table.insert(low, {
			pc = instruction.pc,
			opcode = instruction.name,
			text = LuauBytecode.formatInstruction(instruction, {
				showRawOpcode = instruction.rawOpcode ~= instruction.opcode,
			}),
		})
	end
	return low
end

local function buildMediumIr(block)
	local medium = {}

	for _, instruction in ipairs(block.instructions) do
		local name = instruction.name
		local target = instruction.jumpTargetPc

		if RETURNS[name] then
			table.insert(medium, {
				kind = "return",
				pc = instruction.pc,
			})
		elseif CONDITIONAL_JUMPS[name] then
			table.insert(medium, {
				kind = "branch",
				pc = instruction.pc,
				targetPc = target,
			})
		elseif UNCONDITIONAL_JUMPS[name] then
			table.insert(medium, {
				kind = "jump",
				pc = instruction.pc,
				targetPc = target,
			})
		elseif LOOP_OPS[name] then
			table.insert(medium, {
				kind = "loop-control",
				pc = instruction.pc,
				opcode = name,
				targetPc = target,
			})
		end
	end

	return medium
end

local function buildHighIr(proto, blocks)
	local children = {}

	for _, block in ipairs(blocks) do
		local successorNodes = {}
		for _, edge in ipairs(block.successors) do
			table.insert(successorNodes, {
				kind = "edge",
				to = edge.to,
				label = edge.kind,
			})
		end

		table.insert(children, {
			kind = "block",
			id = block.id,
			startPc = block.startPc,
			endPc = block.endPc,
			terminator = block.terminator,
			isLoopHeader = block.isLoopHeader == true,
			isLoopLatch = block.isLoopLatch == true,
			children = successorNodes,
		})
	end

	return {
		kind = "proto",
		protoIndex = proto.index,
		children = children,
	}
end

local function buildBlocks(proto)
	local instructions = proto.disassembly and proto.disassembly.instructions or {}
	local pcToInstruction = {}
	for _, instruction in ipairs(instructions) do
		pcToInstruction[instruction.pc] = instruction
	end

	if #instructions == 0 then
		return {}, {}
	end

	local leaders = {
		[instructions[1].pc] = true,
	}

	for _, instruction in ipairs(instructions) do
		local nextPc = instructionEndPc(instruction)
		local targetPc = instruction.jumpTargetPc

		if targetPc ~= nil then
			addLeader(leaders, pcToInstruction, targetPc)
			addLeader(leaders, pcToInstruction, nextPc)
		end

		if RETURNS[instruction.name] or UNCONDITIONAL_JUMPS[instruction.name] then
			addLeader(leaders, pcToInstruction, nextPc)
		end
	end

	local leaderPcs = sortedKeys(leaders)
	local blockByStartPc = {}
	local blocks = {}

	for index, startPc in ipairs(leaderPcs) do
		local stopPc = leaderPcs[index + 1]
		local block = {
			id = index,
			startPc = startPc,
			endPc = startPc,
			instructions = {},
			predecessors = {},
			successors = {},
		}

		local pc = startPc
		while pc ~= nil and (stopPc == nil or pc < stopPc) do
			local instruction = pcToInstruction[pc]
			if instruction == nil then
				break
			end

			table.insert(block.instructions, instruction)
			block.endPc = instruction.pc
			pc = instructionEndPc(instruction)
		end

		block.lowIr = buildLowIr(block)
		block.mediumIr = buildMediumIr(block)

		table.insert(blocks, block)
		blockByStartPc[startPc] = block
	end

	return blocks, blockByStartPc
end

function LuauControlFlow.analyzeProto(proto)
	local blocks, blockByStartPc = buildBlocks(proto)

	for index, block in ipairs(blocks) do
		local lastInstruction = block.instructions[#block.instructions]
		if lastInstruction ~= nil then
			local terminator = classifyTerminator(lastInstruction)
			block.terminator = terminator

			local nextBlock = blocks[index + 1]
			local nextId = nextBlock and nextBlock.id or nil
			local targetId = findBlockByPc(blockByStartPc, lastInstruction.jumpTargetPc)

			if terminator == "return" then
				block.isExit = true
			elseif terminator == "jump" then
				addEdge(block, targetId, "jump")
			elseif terminator == "branch" or terminator == "skip" then
				addEdge(block, targetId, "true")
				addEdge(block, nextId, "false")
			elseif terminator == "loop" then
				addEdge(block, targetId, "loop")
				addEdge(block, nextId, "fallthrough")
			else
				addEdge(block, nextId, "fallthrough")
			end
		end
	end

	for _, block in ipairs(blocks) do
		for _, edge in ipairs(block.successors) do
			local target = blocks[edge.to]
			if target ~= nil then
				table.insert(target.predecessors, block.id)
			end
		end
	end

	computeDominators(blocks)
	markLoopEdges(blocks)

	return {
		protoIndex = proto.index,
		blockCount = #blocks,
		blocks = blocks,
		highIr = buildHighIr(proto, blocks),
	}
end

function LuauControlFlow.analyzeChunk(chunk)
	local protos = {}

	for _, proto in ipairs(chunk.protos or {}) do
		table.insert(protos, LuauControlFlow.analyzeProto(proto))
	end

	return {
		version = chunk.version,
		mainProtoIndex = chunk.mainProtoIndex,
		protos = protos,
	}
end

local function formatIdList(values)
	if values == nil or #values == 0 then
		return "-"
	end

	local parts = {}
	for _, value in ipairs(values) do
		table.insert(parts, tostring(value))
	end
	return table.concat(parts, ", ")
end

local function formatSetIds(set)
	if set == nil then
		return "-"
	end

	local ids = {}
	for id in pairs(set) do
		table.insert(ids, id)
	end
	table.sort(ids)
	return formatIdList(ids)
end

function LuauControlFlow.formatAnalysis(analysis, options)
	options = options or {}

	local lines = {
		"Control Flow View",
		("mainProto=%s protoCount=%d"):format(tostring(analysis.mainProtoIndex), #analysis.protos),
		"",
		"IR layers:",
		"  low    = decoded opcode stream grouped into basic blocks",
		"  medium = block terminators, branches, loop-control, returns",
		"  high   = future structured regions for if/while/for reconstruction",
	}

	for _, proto in ipairs(analysis.protos) do
		table.insert(lines, "")
		table.insert(lines, ("Proto %s: %d blocks"):format(tostring(proto.protoIndex), proto.blockCount))
		table.insert(lines, "  high-ir tree:")
		if proto.highIr and proto.highIr.children then
			for _, node in ipairs(proto.highIr.children) do
				local flags = {}
				if node.isLoopHeader then
					table.insert(flags, "loop-header")
				end
				if node.isLoopLatch then
					table.insert(flags, "loop-latch")
				end
				table.insert(lines, ("    B%d [%d..%d] %s %s"):format(
					node.id,
					node.startPc,
					node.endPc,
					node.terminator or "?",
					#flags > 0 and table.concat(flags, ",") or ""
				))
				for _, edge in ipairs(node.children or {}) do
					table.insert(lines, ("      %s -> B%d"):format(edge.label, edge.to))
				end
			end
		end

		for _, block in ipairs(proto.blocks) do
			table.insert(lines, ("  Block B%d pc=%d..%d term=%s%s%s"):format(
				block.id,
				block.startPc,
				block.endPc,
				block.terminator or "?",
				block.isLoopHeader and " loop-header" or "",
				block.isLoopLatch and " loop-latch" or ""
			))
			table.insert(lines, ("    preds: %s"):format(formatIdList(block.predecessors)))
			table.insert(lines, ("    doms : %s"):format(formatSetIds(block.dominators)))

			if #block.successors == 0 then
				table.insert(lines, "    succs: -")
			else
				local parts = {}
				for _, edge in ipairs(block.successors) do
					table.insert(parts, ("%s -> B%d"):format(edge.kind, edge.to))
				end
				table.insert(lines, "    succs: " .. table.concat(parts, ", "))
			end

			if options.showInstructions ~= false then
				for _, low in ipairs(block.lowIr) do
					table.insert(lines, "      " .. low.text)
				end
			end
		end
	end

	return table.concat(lines, "\n")
end

return LuauControlFlow
