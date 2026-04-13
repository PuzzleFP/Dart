local bit32 = bit32

local band = bit32.band
local lshift = bit32.lshift
local rshift = bit32.rshift

local OpcodeMap = require(script.Parent:WaitForChild("LuauOpcodeMap"))

local LuauBytecode = {}

LuauBytecode.DEFAULT_OPCODE_DECODE_MULTIPLIER = 1
LuauBytecode.ROBLOX_OPCODE_ENCODE_MULTIPLIER = 227
LuauBytecode.ROBLOX_OPCODE_DECODE_MULTIPLIER = 203

local function signExtend(value, bits)
	local signBit = lshift(1, bits - 1)
	local fullRange = lshift(1, bits)

	if band(value, signBit) ~= 0 then
		return value - fullRange
	end

	return value
end

local function toHex32(value)
	return string.format("0x%08X", band(value, 0xffffffff))
end

local function sanitizeHex(hex)
	local sanitized = hex:gsub("0[xX]", "")
	sanitized = sanitized:gsub("[^%da-fA-F]", "")

	if #sanitized % 2 ~= 0 then
		error("Hex input must contain an even number of digits")
	end

	return sanitized
end

local function bytesFromHex(hex)
	local sanitized = sanitizeHex(hex)
	local bytes = table.create(#sanitized / 2)

	for index = 1, #sanitized, 2 do
		local byteText = sanitized:sub(index, index + 1)
		table.insert(bytes, tonumber(byteText, 16))
	end

	return bytes
end

local function bytesFromBinary(binary)
	local bytes = table.create(#binary)

	for index = 1, #binary do
		bytes[index] = string.byte(binary, index)
	end

	return bytes
end

local function readWordLE(bytes, offset)
	local b0 = bytes[offset]
	local b1 = bytes[offset + 1]
	local b2 = bytes[offset + 2]
	local b3 = bytes[offset + 3]

	if b3 == nil then
		return nil, ("Missing bytes for 32-bit word at byte offset %d"):format(offset - 1)
	end

	local word = b0 + lshift(b1, 8) + lshift(b2, 16) + lshift(b3, 24)
	return band(word, 0xffffffff)
end

local function wordsFromBytes(bytes, options)
	options = options or {}

	local startByte = options.startByte or 1
	local stopByte = options.stopByte or #bytes
	local words = {}
	local errors = {}

	local offset = startByte

	while offset <= stopByte do
		local word, err = readWordLE(bytes, offset)
		if not word then
			table.insert(errors, err)
			break
		end

		table.insert(words, word)
		offset = offset + 4
	end

	return words, errors
end

local function decodeHeaderFields(word, encoding)
	if encoding == "ABC" then
		return {
			A = band(rshift(word, 8), 0xff),
			B = band(rshift(word, 16), 0xff),
			C = band(rshift(word, 24), 0xff),
		}
	end

	if encoding == "AD" then
		return {
			A = band(rshift(word, 8), 0xff),
			D = signExtend(rshift(word, 16), 16),
		}
	end

	if encoding == "E" then
		return {
			E = signExtend(rshift(word, 8), 24),
		}
	end

	error(("Unsupported encoding: %s"):format(tostring(encoding)))
end

local function decodeImportPathBits(bits)
	local pathLength = band(rshift(bits, 30), 0x3)
	local indexes = {
		band(rshift(bits, 20), 0x3ff),
		band(rshift(bits, 10), 0x3ff),
		band(bits, 0x3ff),
	}

	local path = table.create(pathLength)

	for index = 1, pathLength do
		path[index] = indexes[index]
	end

	return {
		pathLength = pathLength,
		path = path,
	}
end

local function decodeAux(definition, aux)
	if aux == nil then
		return nil
	end

	local auxKind = definition.auxKind

	if auxKind == "constantIndex" then
		return {
			raw = aux,
			constantIndex = aux,
		}
	end

	if auxKind == "compareRegister" then
		return {
			raw = aux,
			register = band(aux, 0xff),
		}
	end

	if auxKind == "arraySize" then
		return {
			raw = aux,
			arraySize = aux,
		}
	end

	if auxKind == "tableIndex" then
		return {
			raw = aux,
			tableIndex = aux,
		}
	end

	if auxKind == "forgLoop" then
		return {
			raw = aux,
			variableCount = band(aux, 0xff),
			useIpairsPath = band(aux, 0x80000000) ~= 0,
		}
	end

	if auxKind == "fastcall2" then
		return {
			raw = aux,
			register2 = band(aux, 0xff),
		}
	end

	if auxKind == "fastcall2k" then
		return {
			raw = aux,
			constantIndex = aux,
		}
	end

	if auxKind == "fastcall3" then
		return {
			raw = aux,
			register2 = band(aux, 0xff),
			register3 = band(rshift(aux, 8), 0xff),
		}
	end

	if auxKind == "jumpxEqNil" then
		return {
			raw = aux,
			notFlag = band(rshift(aux, 31), 0x1) == 1,
		}
	end

	if auxKind == "jumpxEqBoolean" then
		return {
			raw = aux,
			value = band(aux, 0x1) == 1,
			notFlag = band(rshift(aux, 31), 0x1) == 1,
		}
	end

	if auxKind == "jumpxEqConstant" then
		return {
			raw = aux,
			constantIndex = band(aux, 0xffffff),
			notFlag = band(rshift(aux, 31), 0x1) == 1,
		}
	end

	if auxKind == "userdataField" then
		return {
			raw = aux,
			constantIndex = band(aux, 0xffff),
			cachedSlot = band(rshift(aux, 16), 0xffff),
		}
	end

	if auxKind == "importPath" then
		local decoded = decodeImportPathBits(aux)
		decoded.raw = aux
		return decoded
	end

	return {
		raw = aux,
	}
end

local function makeUnknownOpcode(opcode)
	return {
		opcode = opcode,
		name = ("UNKNOWN_%d"):format(opcode),
		encoding = "ABC",
		length = 1,
	}
end

local function getOpcodeDecodeMultiplier(options)
	if options and options.opcodeDecodeMultiplier then
		return options.opcodeDecodeMultiplier
	end

	return LuauBytecode.DEFAULT_OPCODE_DECODE_MULTIPLIER
end

local function decodeOpcodeByte(rawOpcode, options)
	local multiplier = getOpcodeDecodeMultiplier(options)
	return band(rawOpcode * multiplier, 0xff)
end

local function decodeInstructionWord(rawWord, options)
	local rawOpcode = band(rawWord, 0xff)
	local opcode = decodeOpcodeByte(rawOpcode, options)
	local decodedWord = band(rawWord, 0xffffff00) + opcode

	return rawOpcode, opcode, decodedWord
end

local function computeJumpTarget(instruction)
	local name = instruction.name
	local fields = instruction.fields
	local pc = instruction.pc

	if instruction.encoding == "AD" and instruction.jumpOffset ~= nil then
		return pc + 1 + instruction.jumpOffset
	end

	if instruction.encoding == "E" and instruction.jumpOffset ~= nil then
		return pc + 1 + instruction.jumpOffset
	end

	if name == "FASTCALL" or name == "FASTCALL1" or name == "FASTCALL2" or name == "FASTCALL2K" or name == "FASTCALL3" then
		return pc + 2 + fields.C
	end

	if name == "LOADB" and fields.C ~= 0 then
		return pc + 1 + fields.C
	end

	return nil
end

local function formatFields(instruction)
	local fields = instruction.fields

	if instruction.encoding == "ABC" then
		return ("A=%d B=%d C=%d"):format(fields.A, fields.B, fields.C)
	end

	if instruction.encoding == "AD" then
		return ("A=%d D=%d"):format(fields.A, fields.D)
	end

	if instruction.encoding == "E" then
		return ("E=%d"):format(fields.E)
	end

	return ""
end

local function formatConstant(constant)
	if constant == nil then
		return "<?>"
	end

	local kind = constant.kind

	if kind == "nil" then
		return "nil"
	end

	if kind == "boolean" then
		return tostring(constant.value)
	end

	if kind == "number" or kind == "integer" then
		return tostring(constant.value)
	end

	if kind == "string" then
		return string.format("%q", constant.value)
	end

	if kind == "import" then
		if constant.pathText then
			return ("import(%s)"):format(constant.pathText)
		end

		return ("import(%s)"):format(toHex32(constant.id))
	end

	if kind == "closure" then
		return ("closure(proto=%d)"):format(constant.protoIndex)
	end

	if kind == "table" then
		return ("table(keys=%d)"):format(#constant.keys)
	end

	if kind == "tableWithConstants" then
		return ("table(keys=%d,const=%d)"):format(#constant.entries, #constant.entries)
	end

	if kind == "vector" then
		return ("vector(%s, %s, %s, %s)"):format(
			tostring(constant.value[1]),
			tostring(constant.value[2]),
			tostring(constant.value[3]),
			tostring(constant.value[4])
		)
	end

	return "<constant>"
end

local function collectConstantReference(instruction)
	local name = instruction.name
	local fields = instruction.fields
	local aux = instruction.decodedAux

	if name == "LOADK" then
		return fields.D
	end

	if name == "LOADKX" and aux then
		return aux.constantIndex
	end

	if name == "GETIMPORT" then
		return fields.D
	end

	if name == "GETGLOBAL" or name == "SETGLOBAL" or name == "GETTABLEKS" or name == "SETTABLEKS" or name == "NAMECALL" then
		if aux then
			return aux.constantIndex
		end
	end

	if name == "JUMPXEQKN" or name == "JUMPXEQKS" then
		if aux then
			return aux.constantIndex
		end
	end

	if name == "ADDK" or name == "SUBK" or name == "MULK" or name == "DIVK" or name == "MODK" or name == "POWK" or name == "ANDK" or name == "ORK" or name == "IDIVK" then
		return fields.C
	end

	if name == "SUBRK" or name == "DIVRK" then
		return fields.B
	end

	if name == "DUPTABLE" or name == "DUPCLOSURE" then
		return fields.D
	end

	if name == "FASTCALL2K" and aux then
		return aux.constantIndex
	end

	return nil
end

local function formatAux(decodedAux)
	if not decodedAux then
		return nil
	end

	local details = {}

	if decodedAux.constantIndex ~= nil then
		table.insert(details, ("K=%d"):format(decodedAux.constantIndex))
	end

	if decodedAux.register ~= nil then
		table.insert(details, ("R=%d"):format(decodedAux.register))
	end

	if decodedAux.register2 ~= nil then
		table.insert(details, ("R2=%d"):format(decodedAux.register2))
	end

	if decodedAux.register3 ~= nil then
		table.insert(details, ("R3=%d"):format(decodedAux.register3))
	end

	if decodedAux.arraySize ~= nil then
		table.insert(details, ("array=%d"):format(decodedAux.arraySize))
	end

	if decodedAux.tableIndex ~= nil then
		table.insert(details, ("index=%d"):format(decodedAux.tableIndex))
	end

	if decodedAux.variableCount ~= nil then
		table.insert(details, ("vars=%d"):format(decodedAux.variableCount))
	end

	if decodedAux.useIpairsPath ~= nil then
		table.insert(details, ("ipairs=%s"):format(tostring(decodedAux.useIpairsPath)))
	end

	if decodedAux.value ~= nil then
		table.insert(details, ("value=%s"):format(tostring(decodedAux.value)))
	end

	if decodedAux.notFlag ~= nil then
		table.insert(details, ("not=%s"):format(tostring(decodedAux.notFlag)))
	end

	if decodedAux.cachedSlot ~= nil then
		table.insert(details, ("slot=%d"):format(decodedAux.cachedSlot))
	end

	if decodedAux.pathLength ~= nil then
		table.insert(details, ("pathLength=%d"):format(decodedAux.pathLength))
	end

	if decodedAux.path ~= nil then
		table.insert(details, ("path=%s"):format(table.concat(decodedAux.path, ",")))
	end

	if #details == 0 then
		table.insert(details, ("raw=%s"):format(toHex32(decodedAux.raw)))
	end

	return table.concat(details, " ")
end

function LuauBytecode.bytesFromHex(hex)
	return bytesFromHex(hex)
end

function LuauBytecode.bytesFromBinary(binary)
	return bytesFromBinary(binary)
end

function LuauBytecode.wordsFromBytes(bytes, options)
	return wordsFromBytes(bytes, options)
end

function LuauBytecode.decodeOpcodeByte(rawOpcode, options)
	return decodeOpcodeByte(rawOpcode, options)
end

function LuauBytecode.decodeWord(rawWord, wordPc, options)
	local rawOpcode, opcode, decodedWord = decodeInstructionWord(rawWord, options)
	local definition = OpcodeMap.byId[opcode] or makeUnknownOpcode(opcode)
	local fields = decodeHeaderFields(decodedWord, definition.encoding)
	local jumpOffset = definition.jumpField and fields[definition.jumpField] or nil

	local instruction = {
		pc = wordPc or 0,
		rawWord = rawWord,
		word = decodedWord,
		rawOpcode = rawOpcode,
		opcode = opcode,
		name = definition.name,
		encoding = definition.encoding,
		length = definition.length,
		fields = fields,
		jumpOffset = jumpOffset,
	}

	instruction.jumpTargetPc = computeJumpTarget(instruction)

	return instruction
end

function LuauBytecode.disassembleWords(words, options)
	options = options or {}

	local instructions = {}
	local errors = {}
	local pc = options.startWordPc or 0
	local index = 1
	local count = 0

	while index <= #words do
		if options.maxInstructions and count >= options.maxInstructions then
			break
		end

		local instruction = LuauBytecode.decodeWord(words[index], pc, options)
		instruction.wordIndex = index

		if instruction.length > 1 then
			local aux = words[index + 1]

			if aux == nil then
				table.insert(errors, ("Missing AUX word for %s at pc %d"):format(instruction.name, pc))
				break
			end

			instruction.aux = aux
			instruction.decodedAux = decodeAux(OpcodeMap.byId[instruction.opcode] or makeUnknownOpcode(instruction.opcode), aux)
		end

		table.insert(instructions, instruction)

		index = index + instruction.length
		pc = pc + instruction.length
		count = count + 1
	end

	return {
		instructions = instructions,
		errors = errors,
		wordCount = pc - (options.startWordPc or 0),
	}
end

function LuauBytecode.disassembleBytes(bytes, options)
	local words, wordErrors = wordsFromBytes(bytes, options)
	local result = LuauBytecode.disassembleWords(words, options)

	for _, err in ipairs(wordErrors) do
		table.insert(result.errors, err)
	end

	return result
end

function LuauBytecode.disassembleHex(hex, options)
	return LuauBytecode.disassembleBytes(bytesFromHex(hex), options)
end

function LuauBytecode.disassembleBinary(binary, options)
	return LuauBytecode.disassembleBytes(bytesFromBinary(binary), options)
end

function LuauBytecode.scoreOpcodeDecodeMultiplier(words, multiplier, options)
	options = options or {}

	local result = LuauBytecode.disassembleWords(words, {
		opcodeDecodeMultiplier = multiplier,
		maxInstructions = options.maxInstructions or 32,
	})

	local score = 0
	local unknownCount = 0

	for _, instruction in ipairs(result.instructions) do
		if instruction.name:sub(1, 8) == "UNKNOWN_" then
			unknownCount = unknownCount + 1
			score = score - 6
		else
			score = score + 3
		end

		if instruction.name == "PREPVARARGS" then
			score = score + 4
		elseif instruction.name == "CALL" or instruction.name == "RETURN" or instruction.name == "GETIMPORT" then
			score = score + 2
		end
	end

	score = score - (#result.errors * 10)

	return {
		score = score,
		unknownCount = unknownCount,
		result = result,
	}
end

function LuauBytecode.formatInstruction(instruction, options)
	options = options or {}

	local parts = {
		("[%04d] %-14s %s"):format(instruction.pc, instruction.name, formatFields(instruction)),
	}

	if instruction.jumpTargetPc ~= nil then
		table.insert(parts, ("-> %d"):format(instruction.jumpTargetPc))
	end

	if instruction.aux ~= nil then
		table.insert(parts, ("AUX=%s"):format(toHex32(instruction.aux)))

		local auxText = formatAux(instruction.decodedAux)
		if auxText then
			table.insert(parts, ("; %s"):format(auxText))
		end
	end

	local constantIndex = collectConstantReference(instruction)
	local constants = options.constants

	if constantIndex ~= nil and constants then
		local constant = constants[constantIndex + 1]
		if constant then
			table.insert(parts, ("; K%d = %s"):format(constantIndex, formatConstant(constant)))
		end
	end

	local showRawOpcode = options.showRawOpcode
	if showRawOpcode == nil then
		showRawOpcode = instruction.rawOpcode ~= instruction.opcode
	end

	if showRawOpcode then
		table.insert(parts, ("; rawOp=0x%02X"):format(instruction.rawOpcode))
	end

	return table.concat(parts, " ")
end

function LuauBytecode.formatListing(result, options)
	options = options or {}

	local lines = table.create(#result.instructions + #result.errors)

	for _, instruction in ipairs(result.instructions) do
		table.insert(lines, LuauBytecode.formatInstruction(instruction, options))
	end

	for _, err in ipairs(result.errors) do
		table.insert(lines, ("[error] %s"):format(err))
	end

	return table.concat(lines, "\n")
end

function LuauBytecode.getOpcodeDefinition(opcode)
	return OpcodeMap.byId[opcode]
end

function LuauBytecode.getOpcodeMap()
	return OpcodeMap
end

function LuauBytecode.formatConstant(constant)
	return formatConstant(constant)
end

return LuauBytecode
