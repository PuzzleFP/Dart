local bit32 = bit32

local band = bit32.band
local rshift = bit32.rshift

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

local LuauChunk = {}
local nativeReadfile = readfile

local CONSTANT_KIND = {
	[0] = "nil",
	[1] = "boolean",
	[2] = "number",
	[3] = "string",
	[4] = "import",
	[5] = "table",
	[6] = "closure",
	[7] = "vector",
	[8] = "tableWithConstants",
	[9] = "integer",
}

local function toSigned32(value)
	if value >= 0x80000000 then
		return value - 0x100000000
	end

	return value
end

local function decodeFloat32(word)
	local sign = band(word, 0x80000000) ~= 0 and -1 or 1
	local exponent = band(rshift(word, 23), 0xff)
	local fraction = band(word, 0x7fffff)

	if exponent == 0xff then
		if fraction == 0 then
			return sign * math.huge
		end

		return 0 / 0
	end

	if exponent == 0 then
		if fraction == 0 then
			return sign * 0
		end

		return sign * math.ldexp(fraction / (2 ^ 23), -126)
	end

	return sign * math.ldexp(1 + fraction / (2 ^ 23), exponent - 127)
end

local function decodeFloat64(lo, hi)
	local sign = band(hi, 0x80000000) ~= 0 and -1 or 1
	local exponent = band(rshift(hi, 20), 0x7ff)
	local fraction = band(hi, 0xfffff) * (2 ^ 32) + lo

	if exponent == 0x7ff then
		if fraction == 0 then
			return sign * math.huge
		end

		return 0 / 0
	end

	if exponent == 0 then
		if fraction == 0 then
			return sign * 0
		end

		return sign * math.ldexp(fraction / (2 ^ 52), -1022)
	end

	return sign * math.ldexp(1 + fraction / (2 ^ 52), exponent - 1023)
end

local function createReader(bytes)
	return {
		bytes = bytes,
		offset = 1,
	}
end

local function readU8(reader)
	local value = reader.bytes[reader.offset]
	if value == nil then
		error(("Unexpected end of data at byte offset %d"):format(reader.offset - 1))
	end

	reader.offset = reader.offset + 1
	return value
end

local function readU32(reader)
	local bytes = reader.bytes
	local offset = reader.offset

	local b0 = bytes[offset]
	local b1 = bytes[offset + 1]
	local b2 = bytes[offset + 2]
	local b3 = bytes[offset + 3]

	if b3 == nil then
		error(("Unexpected end of data at byte offset %d"):format(offset - 1))
	end

	reader.offset = offset + 4
	return b0 + b1 * 256 + b2 * 65536 + b3 * 16777216
end

local function readI32(reader)
	return toSigned32(readU32(reader))
end

local function readVarInt(reader)
	local result = 0
	local shift = 0

	while true do
		local byte = readU8(reader)
		result = result + band(byte, 0x7f) * (2 ^ shift)

		if band(byte, 0x80) == 0 then
			return result
		end

		shift = shift + 7
	end
end

local function readVarInt64(reader)
	local result = 0
	local shift = 0

	while true do
		local byte = readU8(reader)
		result = result + band(byte, 0x7f) * (2 ^ shift)

		if band(byte, 0x80) == 0 then
			return result
		end

		shift = shift + 7
	end
end

local function readStringBytes(reader, length)
	local chars = table.create(length)

	for index = 1, length do
		chars[index] = string.char(readU8(reader))
	end

	return table.concat(chars)
end

local function readStringRef(reader, strings)
	local id = readVarInt(reader)

	if id == 0 then
		return nil, 0
	end

	return strings[id], id
end

local function readFloat32(reader)
	return decodeFloat32(readU32(reader))
end

local function readFloat64(reader)
	local lo = readU32(reader)
	local hi = readU32(reader)
	return decodeFloat64(lo, hi)
end

local function decodeImportId(id)
	local pathLength = band(rshift(id, 30), 0x3)
	local indices = {
		band(rshift(id, 20), 0x3ff),
		band(rshift(id, 10), 0x3ff),
		band(id, 0x3ff),
	}

	local path = table.create(pathLength)

	for index = 1, pathLength do
		path[index] = indices[index]
	end

	return {
		id = id,
		pathLength = pathLength,
		indices = path,
	}
end

local function resolveImportConstantPaths(constants)
	for _, constant in ipairs(constants) do
		if constant.kind == "import" then
			local names = table.create(#constant.indices)

			for _, index in ipairs(constant.indices) do
				local referenced = constants[index + 1]
				if referenced and referenced.kind == "string" then
					table.insert(names, referenced.value)
				else
					table.insert(names, ("K%d"):format(index))
				end
			end

			constant.pathNames = names
			constant.pathText = table.concat(names, ".")
		end
	end
end

local function constantToExpression(constant)
	if constant == nil then
		return "<?>"
	end

	if constant.kind == "string" then
		return string.format("%q", constant.value)
	end

	if constant.kind == "number" or constant.kind == "integer" then
		return tostring(constant.value)
	end

	if constant.kind == "boolean" then
		return tostring(constant.value)
	end

	if constant.kind == "nil" then
		return "nil"
	end

	if constant.kind == "import" then
		return constant.pathText or ("import(" .. tostring(constant.id) .. ")")
	end

	return LuauBytecode.formatConstant(constant)
end

local function readConstant(reader, strings)
	local kindId = readU8(reader)
	local kind = CONSTANT_KIND[kindId]

	if kind == nil then
		error(("Unsupported constant kind id %d"):format(kindId))
	end

	if kind == "nil" then
		return {
			kind = kind,
			value = nil,
		}
	end

	if kind == "boolean" then
		return {
			kind = kind,
			value = readU8(reader) ~= 0,
		}
	end

	if kind == "number" then
		return {
			kind = kind,
			value = readFloat64(reader),
		}
	end

	if kind == "string" then
		local value, id = readStringRef(reader, strings)
		return {
			kind = kind,
			value = value,
			stringId = id,
		}
	end

	if kind == "import" then
		local decoded = decodeImportId(readU32(reader))
		decoded.kind = kind
		return decoded
	end

	if kind == "table" then
		local keyCount = readVarInt(reader)
		local keys = table.create(keyCount)

		for index = 1, keyCount do
			keys[index] = readVarInt(reader)
		end

		return {
			kind = kind,
			keys = keys,
		}
	end

	if kind == "closure" then
		return {
			kind = kind,
			protoIndex = readVarInt(reader),
		}
	end

	if kind == "vector" then
		return {
			kind = kind,
			value = {
				readFloat32(reader),
				readFloat32(reader),
				readFloat32(reader),
				readFloat32(reader),
			},
		}
	end

	if kind == "tableWithConstants" then
		local keyCount = readVarInt(reader)
		local entries = table.create(keyCount)

		for index = 1, keyCount do
			entries[index] = {
				key = readVarInt(reader),
				constantIndex = readI32(reader),
			}
		end

		return {
			kind = kind,
			entries = entries,
		}
	end

	if kind == "integer" then
		local isNegative = readU8(reader) ~= 0
		local magnitude = readVarInt64(reader)
		local value = isNegative and -magnitude or magnitude

		return {
			kind = kind,
			value = value,
			precise = magnitude <= 2 ^ 53,
		}
	end

	error(("Unhandled constant kind %s"):format(kind))
end

local function detectOpcodeDecodeMultiplier(chunk, options)
	options = options or {}

	if options.opcodeDecodeMultiplier then
		return options.opcodeDecodeMultiplier
	end

	local candidates = options.opcodeDecodeMultipliers or {
		LuauBytecode.DEFAULT_OPCODE_DECODE_MULTIPLIER,
		LuauBytecode.ROBLOX_OPCODE_DECODE_MULTIPLIER,
	}

	local bestMultiplier = candidates[1]
	local bestScore = -math.huge

	for _, multiplier in ipairs(candidates) do
		local score = 0

		for _, proto in ipairs(chunk.protos) do
			local attempt = LuauBytecode.scoreOpcodeDecodeMultiplier(proto.codeWords, multiplier, {
				maxInstructions = 24,
			})

			score = score + attempt.score
		end

		if score > bestScore then
			bestScore = score
			bestMultiplier = multiplier
		end
	end

	return bestMultiplier
end

local function inferProtoBehavior(proto)
	local registers = {}
	local lastCall

	local function getRegister(index)
		return registers[index] or ("R" .. tostring(index))
	end

	local function setRegister(index, value)
		registers[index] = value
	end

	local function getConstant(index)
		return proto.constants[index + 1]
	end

	local function getConstantExpression(index)
		return constantToExpression(getConstant(index))
	end

	for _, instruction in ipairs(proto.disassembly.instructions) do
		local name = instruction.name
		local fields = instruction.fields
		local aux = instruction.decodedAux

		if name == "GETIMPORT" then
			setRegister(fields.A, getConstantExpression(fields.D))
		elseif name == "GETGLOBAL" then
			if aux and aux.constantIndex ~= nil then
				setRegister(fields.A, getConstantExpression(aux.constantIndex))
			end
		elseif name == "MOVE" then
			setRegister(fields.A, getRegister(fields.B))
		elseif name == "LOADK" then
			setRegister(fields.A, getConstantExpression(fields.D))
		elseif name == "LOADKX" then
			if aux and aux.constantIndex ~= nil then
				setRegister(fields.A, getConstantExpression(aux.constantIndex))
			end
		elseif name == "LOADN" then
			setRegister(fields.A, tostring(fields.D))
		elseif name == "LOADNIL" then
			setRegister(fields.A, "nil")
		elseif name == "LOADB" then
			setRegister(fields.A, tostring(fields.B ~= 0))
		elseif name == "GETTABLEKS" then
			local member = aux and aux.constantIndex and getConstant(aux.constantIndex)
			local memberName = member and member.kind == "string" and member.value or ("K" .. tostring(aux and aux.constantIndex or "?"))
			setRegister(fields.A, ("%s.%s"):format(getRegister(fields.B), memberName))
		elseif name == "GETTABLEN" then
			setRegister(fields.A, ("%s[%d]"):format(getRegister(fields.B), fields.C + 1))
		elseif name == "NAMECALL" then
			local member = aux and aux.constantIndex and getConstant(aux.constantIndex)
			local memberName = member and member.kind == "string" and member.value or ("K" .. tostring(aux and aux.constantIndex or "?"))
			local target = getRegister(fields.B)
			setRegister(fields.A, {
				kind = "method",
				target = target,
				method = memberName,
			})
			setRegister(fields.A + 1, target)
		elseif name == "CALL" then
			local callee = registers[fields.A]
			local argCount = fields.B == 0 and nil or (fields.B - 1)
			local args = {}

			if argCount then
				for offset = 1, argCount do
					table.insert(args, getRegister(fields.A + offset))
				end
			else
				local scan = fields.A + 1
				while registers[scan] ~= nil do
					table.insert(args, getRegister(scan))
					scan = scan + 1
				end
			end

			local callExpression

			if type(callee) == "table" and callee.kind == "method" then
				callExpression = ("%s:%s(%s)"):format(callee.target, callee.method, table.concat(args, ", "))
			else
				callExpression = ("%s(%s)"):format(getRegister(fields.A), table.concat(args, ", "))
			end

			setRegister(fields.A, callExpression)
			lastCall = callExpression

			if fields.C == 1 then
				lastCall = callExpression
			end
		end
	end

	return lastCall
end

local function appendKeyValue(lines, label, value)
	table.insert(lines, ("  %-20s %s"):format(label .. ":", tostring(value)))
end

local function appendSection(lines, title)
	if #lines > 0 then
		table.insert(lines, "")
	end

	table.insert(lines, title)
end

function LuauChunk.parseBytes(bytes, options)
	options = options or {}

	local reader = createReader(bytes)
	local chunk = {
		byteCount = #bytes,
		strings = {},
		userdataTypes = {},
		protos = {},
	}

	chunk.version = readU8(reader)

	if chunk.version == 0 then
		chunk.errorMessage = readStringBytes(reader, #bytes - 1)
		return chunk
	end

	chunk.typesVersion = 0
	if chunk.version >= 4 then
		chunk.typesVersion = readU8(reader)
	end

	chunk.stringCount = readVarInt(reader)

	for index = 1, chunk.stringCount do
		local length = readVarInt(reader)
		chunk.strings[index] = readStringBytes(reader, length)
	end

	if chunk.typesVersion == 3 then
		while true do
			local typeIndex = readU8(reader)
			if typeIndex == 0 then
				break
			end

			local name, nameId = readStringRef(reader, chunk.strings)
			table.insert(chunk.userdataTypes, {
				index = typeIndex,
				name = name,
				stringId = nameId,
			})
		end
	end

	chunk.protoCount = readVarInt(reader)

	for protoIndex = 0, chunk.protoCount - 1 do
		local proto = {
			index = protoIndex,
		}

		proto.maxStackSize = readU8(reader)
		proto.numParams = readU8(reader)
		proto.numUpvalues = readU8(reader)
		proto.isVararg = readU8(reader) ~= 0
		proto.flags = 0
		proto.typeInfo = nil

		if chunk.version >= 4 then
			proto.flags = readU8(reader)

			local typeInfoSize = readVarInt(reader)
			if typeInfoSize > 0 then
				proto.typeInfo = readStringBytes(reader, typeInfoSize)
			end
		end

		proto.sizeCode = readVarInt(reader)
		proto.codeWords = table.create(proto.sizeCode)

		for wordIndex = 1, proto.sizeCode do
			proto.codeWords[wordIndex] = readU32(reader)
		end

		proto.sizeConstants = readVarInt(reader)
		proto.constants = table.create(proto.sizeConstants)

		for constantIndex = 1, proto.sizeConstants do
			proto.constants[constantIndex] = readConstant(reader, chunk.strings)
		end

		resolveImportConstantPaths(proto.constants)

		proto.sizeChildren = readVarInt(reader)
		proto.childProtoIndices = table.create(proto.sizeChildren)

		for childIndex = 1, proto.sizeChildren do
			proto.childProtoIndices[childIndex] = readVarInt(reader)
		end

		proto.lineDefined = readVarInt(reader)
		proto.debugName, proto.debugNameId = readStringRef(reader, chunk.strings)

		local hasLineInfo = readU8(reader) ~= 0
		if hasLineInfo then
			proto.lineGapLog2 = readU8(reader)
			proto.lineOffsets = table.create(proto.sizeCode)
			local runningOffset = 0

			for codeIndex = 1, proto.sizeCode do
				runningOffset = runningOffset + readU8(reader)
				proto.lineOffsets[codeIndex] = runningOffset
			end

			local intervalCount = math.floor((proto.sizeCode - 1) / (2 ^ proto.lineGapLog2)) + 1
			proto.absoluteLines = table.create(intervalCount)
			local runningLine = 0

			for intervalIndex = 1, intervalCount do
				runningLine = runningLine + readI32(reader)
				proto.absoluteLines[intervalIndex] = runningLine
			end
		end

		local hasDebugInfo = readU8(reader) ~= 0
		if hasDebugInfo then
			local localCount = readVarInt(reader)
			proto.locals = table.create(localCount)

			for localIndex = 1, localCount do
				local name, nameId = readStringRef(reader, chunk.strings)
				proto.locals[localIndex] = {
					name = name,
					stringId = nameId,
					startPc = readVarInt(reader),
					endPc = readVarInt(reader),
					register = readU8(reader),
				}
			end

			local upvalueCount = readVarInt(reader)
			proto.upvalues = table.create(upvalueCount)

			for upvalueIndex = 1, upvalueCount do
				local name, nameId = readStringRef(reader, chunk.strings)
				proto.upvalues[upvalueIndex] = {
					name = name,
					stringId = nameId,
				}
			end
		end

		table.insert(chunk.protos, proto)
	end

	chunk.mainProtoIndex = readVarInt(reader)
	chunk.bytesRead = reader.offset - 1
	chunk.opcodeDecodeMultiplier = detectOpcodeDecodeMultiplier(chunk, options)

	for _, proto in ipairs(chunk.protos) do
		proto.disassembly = LuauBytecode.disassembleWords(proto.codeWords, {
			opcodeDecodeMultiplier = chunk.opcodeDecodeMultiplier,
		})
		proto.behaviorSummary = inferProtoBehavior(proto)
	end

	return chunk
end

function LuauChunk.parseBinary(binary, options)
	return LuauChunk.parseBytes(LuauBytecode.bytesFromBinary(binary), options)
end

function LuauChunk.parseHex(hex, options)
	return LuauChunk.parseBytes(LuauBytecode.bytesFromHex(hex), options)
end

function LuauChunk.parseFile(path, options)
	options = options or {}

	local readFile = options.readFile or nativeReadfile
	if type(readFile) ~= "function" then
		error("readfile is not available in this environment")
	end

	local input = readFile(path)
	local inputFormat = options.inputFormat or "binary"

	if inputFormat == "hex" then
		return LuauChunk.parseHex(input, options)
	end

	return LuauChunk.parseBinary(input, options)
end

function LuauChunk.inspectFile(path, options)
	local chunk = LuauChunk.parseFile(path, options)
	local output = LuauChunk.formatPrettyChunk(chunk, options)

	if not options or options.printOutput ~= false then
		print(output)
	end

	return output, chunk
end

function LuauChunk.formatChunk(chunk, options)
	options = options or {}

	local lines = {
		("version=%d typesVersion=%d protoCount=%d mainProto=%d opcodeDecodeMultiplier=%d"):format(
			chunk.version,
			chunk.typesVersion or 0,
			chunk.protoCount or 0,
			chunk.mainProtoIndex or 0,
			chunk.opcodeDecodeMultiplier or 1
		),
	}

	for _, proto in ipairs(chunk.protos) do
		table.insert(lines, "")
		table.insert(lines, ("Proto %d"):format(proto.index))
		table.insert(lines, ("  maxStack=%d params=%d upvalues=%d vararg=%s flags=%d"):format(
			proto.maxStackSize,
			proto.numParams,
			proto.numUpvalues,
			tostring(proto.isVararg),
			proto.flags
		))

		if options.includeConstants ~= false then
			table.insert(lines, "  Constants")
			for index, constant in ipairs(proto.constants) do
				table.insert(lines, ("    K%d = %s"):format(index - 1, LuauBytecode.formatConstant(constant)))
			end
		end

		table.insert(lines, "  Code")
		for _, instruction in ipairs(proto.disassembly.instructions) do
			table.insert(lines, "    " .. LuauBytecode.formatInstruction(instruction, {
				constants = proto.constants,
			}))
		end

		for _, err in ipairs(proto.disassembly.errors) do
			table.insert(lines, "    [error] " .. err)
		end
	end

	return table.concat(lines, "\n")
end

function LuauChunk.formatPrettyChunk(chunk, options)
	options = options or {}

	if chunk.errorMessage then
		return "Luau Chunk Error\n  " .. chunk.errorMessage
	end

	local lines = {
		"Luau Chunk",
	}

	appendKeyValue(lines, "Byte Count", chunk.byteCount)
	appendKeyValue(lines, "Version", chunk.version)
	appendKeyValue(lines, "Type Version", chunk.typesVersion or 0)
	appendKeyValue(lines, "Proto Count", chunk.protoCount or 0)
	appendKeyValue(lines, "Main Proto", chunk.mainProtoIndex or 0)
	appendKeyValue(lines, "Strings", chunk.stringCount or 0)
	appendKeyValue(lines, "Opcode Decode", chunk.opcodeDecodeMultiplier or 1)

	if options.includeStrings ~= false then
		appendSection(lines, "String Table")

		for index, value in ipairs(chunk.strings) do
			table.insert(lines, ("  S%-19d %q"):format(index, value))
		end
	end

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
		appendKeyValue(lines, "Flags", proto.flags)
		appendKeyValue(lines, "Code Words", proto.sizeCode)
		appendKeyValue(lines, "Constants", proto.sizeConstants)

		if proto.behaviorSummary then
			appendKeyValue(lines, "Likely Behavior", proto.behaviorSummary)
		end

		if options.includeConstants ~= false then
			table.insert(lines, "  Constant Table")
			for index, constant in ipairs(proto.constants) do
				table.insert(lines, ("    K%-18d %s"):format(index - 1, LuauBytecode.formatConstant(constant)))
			end
		end

		table.insert(lines, "  Disassembly")
		for _, instruction in ipairs(proto.disassembly.instructions) do
			table.insert(lines, "    " .. LuauBytecode.formatInstruction(instruction, {
				constants = proto.constants,
				showRawOpcode = options.showRawOpcode ~= false,
			}))
		end

		for _, err in ipairs(proto.disassembly.errors) do
			table.insert(lines, "    [error] " .. err)
		end
	end

	return table.concat(lines, "\n")
end

return LuauChunk
