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

local LuauDecompiler = {}

local BINARY_OPERATORS = {
	ADD = "+",
	SUB = "-",
	MUL = "*",
	DIV = "/",
	MOD = "%",
	POW = "^",
	IDIV = "//",
	AND = "and",
	OR = "or",
}

local BINARY_K_OPERATORS = {
	ADDK = "+",
	SUBK = "-",
	MULK = "*",
	DIVK = "/",
	MODK = "%",
	POWK = "^",
	IDIVK = "//",
	ANDK = "and",
	ORK = "or",
}

local RK_OPERATORS = {
	SUBRK = "-",
	DIVRK = "/",
}

local COMPARE_OPERATORS = {
	JUMPIFEQ = "==",
	JUMPIFNOTEQ = "~=",
	JUMPIFLE = "<=",
	JUMPIFNOTLE = ">",
	JUMPIFLT = "<",
	JUMPIFNOTLT = ">=",
}

local INVERSE_OPERATORS = {
	["=="] = "~=",
	["~="] = "==",
	["<="] = ">",
	[">"] = "<=",
	["<"] = ">=",
	[">="] = "<",
}

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

local CAPTURE_TYPES = {
	[0] = "VAL",
	[1] = "REF",
	[2] = "UPVAL",
}

local DEFAULT_MAX_STRUCTURED_DEPTH = 48
local DEFAULT_MAX_EXPRESSION_DEPTH = 48

local LUA_KEYWORDS = {
	["and"] = true,
	["break"] = true,
	["continue"] = true,
	["do"] = true,
	["else"] = true,
	["elseif"] = true,
	["end"] = true,
	["false"] = true,
	["for"] = true,
	["function"] = true,
	["if"] = true,
	["in"] = true,
	["local"] = true,
	["nil"] = true,
	["not"] = true,
	["or"] = true,
	["repeat"] = true,
	["return"] = true,
	["then"] = true,
	["true"] = true,
	["until"] = true,
	["while"] = true,
}

local function isIdentifier(text)
	return type(text) == "string" and text:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil and not LUA_KEYWORDS[text]
end

local function sanitizeIdentifier(text, fallback)
	text = tostring(text or "")
	text = text:gsub("[^A-Za-z0-9_]", "")

	if text:match("^[0-9]") then
		text = "_" .. text
	end

	if not isIdentifier(text) then
		return fallback
	end

	return text
end

local function getUsefulDebugName(proto)
	local name = proto and proto.debugName
	if type(name) ~= "string" or name == "" or name == "<anonymous>" then
		return nil
	end

	return sanitizeIdentifier(name, nil)
end

local function getProtoFunctionName(proto)
	return getUsefulDebugName(proto) or ("proto_%d"):format(proto.index or 0)
end

local function quoteString(text)
	return string.format("%q", tostring(text))
end

local function constantToExpression(constant)
	if constant == nil then
		return "nil"
	end

	if constant.kind == "nil" then
		return "nil"
	end

	if constant.kind == "boolean" then
		return tostring(constant.value)
	end

	if constant.kind == "number" or constant.kind == "integer" then
		return tostring(constant.value)
	end

	if constant.kind == "string" then
		return quoteString(constant.value)
	end

	if constant.kind == "import" then
		return constant.pathText or ("import(%d)"):format(constant.id or -1)
	end

	if constant.kind == "closure" then
		return ("proto_%d"):format(constant.protoIndex or -1)
	end

	if constant.kind == "vector" then
		local value = constant.value or {}
		return ("Vector3.new(%s, %s, %s)"):format(
			tostring(value[1] or 0),
			tostring(value[2] or 0),
			tostring(value[3] or 0)
		)
	end

	if constant.kind == "table" or constant.kind == "tableWithConstants" then
		return "{}"
	end

	return LuauBytecode.formatConstant(constant)
end

local function getConstant(proto, index)
	if index == nil then
		return nil
	end

	return proto.constants[index + 1]
end

local function getConstantName(proto, index)
	local constant = getConstant(proto, index)
	if constant and constant.kind == "string" then
		return constant.value
	end

	return ("k%d"):format(index or -1)
end

local function getUpvalueName(context, index)
	local aliases = context.options and context.options.upvalueAliases
	if aliases and aliases[index] ~= nil then
		return aliases[index]
	end

	local upvalue = context.proto.upvalues and context.proto.upvalues[index + 1]
	return upvalue and upvalue.name or ("upvalue_%d"):format(index)
end

local function memberAccess(base, key)
	if isIdentifier(key) then
		return ("%s.%s"):format(base, key)
	end

	return ("%s[%s]"):format(base, quoteString(key))
end

local function getLocalNameAtPc(proto, register, pc)
	local locals = proto.locals
	if type(locals) ~= "table" then
		return nil
	end

	for _, localInfo in ipairs(locals) do
		if localInfo.register == register and isIdentifier(localInfo.name) then
			local startPc = localInfo.startPc or 0
			local endPc = localInfo.endPc or math.huge
			if pc >= startPc and pc < endPc then
				return localInfo.name
			end
		end
	end

	return nil
end

local function instructionEndPc(instruction)
	return instruction.pc + (instruction.length or 1)
end

local function makeContext(proto, options)
	local context = {
		proto = proto,
		options = options or {},
		registers = {},
		declaredLocals = {},
		statements = {},
		unsupported = {},
		closureAssignments = {},
		usedAliases = {},
		pendingClosure = nil,
		openResult = nil,
		structuredDepth = 0,
		activeStructuredRanges = {},
	}

	for _, alias in pairs(context.options.registerAliases or {}) do
		context.usedAliases[alias] = true
	end

	return context
end

local function emit(context, statement)
	if statement ~= nil and statement ~= "" then
		table.insert(context.statements, statement)
	end
end

local renderExpression

local function makeTextValue(text, options)
	options = options or {}
	return {
		kind = "text",
		text = tostring(text),
		pure = options.pure ~= false,
		multret = options.multret == true,
	}
end

local function expressionText(value)
	if type(value) == "table" and value.text then
		return value.text
	end

	if type(value) == "table" and value.kind == "method" then
		return ("%s.%s"):format(value.target or "<?>", value.method or "<?>")
	end

	if type(value) == "table" and value.kind == "table" then
		return value.name or renderExpression(value, 0)
	end

	if type(value) == "table" and value.kind == "closure" then
		return ("proto_%d"):format(value.protoIndex or -1)
	end

	return tostring(value)
end

local function rawRegisterName(index)
	return ("r%d"):format(index)
end

local function getRegisterAlias(context, index)
	local aliases = context.options and context.options.registerAliases
	if aliases and aliases[index] ~= nil then
		return aliases[index]
	end

	return nil
end

local function getRegister(context, index)
	local value = context.registers[index]
	if value == nil then
		return getRegisterAlias(context, index) or rawRegisterName(index)
	end

	return expressionText(value)
end

local function getRegisterValue(context, index)
	local value = context.registers[index]
	if value == nil then
		return makeTextValue(getRegisterAlias(context, index) or rawRegisterName(index))
	end

	return value
end

local function getWritableRegister(context, index, pc)
	local alias = getRegisterAlias(context, index)
	if alias ~= nil then
		return alias, false
	end

	local localName = getLocalNameAtPc(context.proto, index, pc)
	if localName ~= nil then
		return localName, true
	end

	return rawRegisterName(index), false
end

local function setRegister(context, index, value, options)
	options = options or {}

	if context.openResult ~= nil and index >= context.openResult.base then
		context.openResult = nil
	end

	if type(value) == "table" then
		context.registers[index] = value
	else
		context.registers[index] = makeTextValue(value, options)
	end
end

local function replaceRegisterName(text, rawName, alias)
	local pattern = "%f[%w_]" .. rawName .. "%f[^%w_]"
	return (text:gsub(pattern, alias))
end

local function applyRegisterAlias(context, index, alias, options)
	options = options or {}

	alias = sanitizeIdentifier(alias, nil)
	if alias == nil then
		return nil
	end

	local rawName = rawRegisterName(index)
	if rawName == alias then
		return alias
	end

	for statementIndex, statement in ipairs(context.statements) do
		local replaced = replaceRegisterName(statement, rawName, alias)
		if options.localizeAssignment and not context.declaredLocals[alias] and replaced:match("^" .. alias .. "%s*=") then
			replaced = "local " .. replaced
			context.declaredLocals[alias] = true
		end

		context.statements[statementIndex] = replaced
	end

	context.registers[index] = makeTextValue(alias)
	context.usedAliases[alias] = true
	return alias
end

local function inferAliasFromExpression(expression)
	local serviceName = expression:match('^game:GetService%("([A-Za-z_][A-Za-z0-9_]*)"%)$')
	if serviceName ~= nil then
		return sanitizeIdentifier(serviceName, nil)
	end

	local requiredName = expression:match('^require%(.+:WaitForChild%("([A-Za-z_][A-Za-z0-9_]*)"%)%)$')
	if requiredName ~= nil then
		return sanitizeIdentifier(requiredName, nil)
	end

	return nil
end

local function assignRegister(context, index, expression, pc)
	local target, isLocal = getWritableRegister(context, index, pc)
	local renderedExpression = renderExpression(expression, 0)
	local inferredAlias

	if not isLocal and context.options.inferAliases ~= false then
		inferredAlias = inferAliasFromExpression(renderedExpression)
		if inferredAlias ~= nil and not context.usedAliases[inferredAlias] then
			target = inferredAlias
			isLocal = true
		end
	end

	setRegister(context, index, target)

	if isLocal and not context.declaredLocals[target] then
		context.declaredLocals[target] = true
		context.usedAliases[target] = true
		emit(context, ("local %s = %s"):format(target, renderedExpression))
		return
	end

	emit(context, ("%s = %s"):format(target, renderedExpression))
end

local function buildCallExpression(callee, args)
	if type(callee) == "table" and callee.kind == "method" then
		local normalizedArgs = {}
		for index, value in ipairs(args) do
			normalizedArgs[index] = renderExpression(value, 0)
		end

		if normalizedArgs[1] == callee.target then
			table.remove(normalizedArgs, 1)
		end

		return ("%s:%s(%s)"):format(callee.target, callee.method, table.concat(normalizedArgs, ", "))
	end

	local renderedArgs = {}
	for index, value in ipairs(args) do
		renderedArgs[index] = renderExpression(value, 0)
	end

	return ("%s(%s)"):format(expressionText(callee), table.concat(renderedArgs, ", "))
end

local function collectCallArgs(context, baseRegister, fieldB)
	local args = {}

	if fieldB == 0 then
		local openResult = context.openResult
		if openResult ~= nil and openResult.base >= baseRegister + 1 then
			for register = baseRegister + 1, openResult.base - 1 do
				table.insert(args, getRegisterValue(context, register))
			end

			table.insert(args, openResult.value)
		end

		return args
	end

	for offset = 1, fieldB - 1 do
		table.insert(args, getRegisterValue(context, baseRegister + offset))
	end

	return args
end

local function collectReturnValues(context, baseRegister, fieldB)
	if fieldB == 1 then
		return {}
	end

	if fieldB == 0 then
		local openResult = context.openResult
		if openResult ~= nil and openResult.base >= baseRegister then
			local values = {}
			for register = baseRegister, openResult.base - 1 do
				table.insert(values, getRegisterValue(context, register))
			end

			table.insert(values, openResult.value)
			return values
		end

		return { makeTextValue("...") }
	end

	local values = {}
	for offset = 0, fieldB - 2 do
		table.insert(values, getRegisterValue(context, baseRegister + offset))
	end

	return values
end

local function resolveChildProtoIndex(proto, childIndex)
	local children = proto.childProtoIndices
	if type(children) == "table" and children[childIndex + 1] ~= nil then
		return children[childIndex + 1]
	end

	return childIndex
end

local function makeClosureValue(protoIndex)
	return {
		kind = "closure",
		protoIndex = protoIndex,
		captures = {},
	}
end

local function cloneCaptures(captures)
	local result = {}
	for index, capture in ipairs(captures or {}) do
		result[index] = {
			type = capture.type,
			source = capture.source,
		}
	end
	return result
end

local function keyExpressionFromConstant(constant)
	if constant and constant.kind == "string" then
		if isIdentifier(constant.value) then
			return constant.value
		end

		return ("[%s]"):format(quoteString(constant.value))
	end

	return ("[%s]"):format(constantToExpression(constant))
end

local function makeTableNode()
	return {
		kind = "table",
		entries = {},
		entryMap = {},
	}
end

local function setTableEntry(node, keyText, value, options)
	options = options or {}

	local entry = node.entryMap[keyText]
	if entry == nil then
		entry = {
			keyText = keyText,
			value = value,
			array = options.array == true,
		}
		node.entryMap[keyText] = entry
		table.insert(node.entries, entry)
		return
	end

	entry.value = value
	entry.array = options.array == true
end

local function tableNodeFromConstant(proto, constant)
	local node = makeTableNode()

	if constant == nil then
		return node
	end

	if constant.kind == "tableWithConstants" then
		for _, entry in ipairs(constant.entries or {}) do
			local key = getConstant(proto, entry.key)
			local value = getConstant(proto, entry.constantIndex)
			setTableEntry(node, keyExpressionFromConstant(key), makeTextValue(constantToExpression(value)))
		end
	end

	return node
end

local function renderTableNode(node, indent, seen, depth)
	if node.name ~= nil then
		return node.name
	end

	seen = seen or {}
	depth = depth or 0

	if seen[node] then
		return "{ --[[ recursive table ]] }"
	end

	if depth > DEFAULT_MAX_EXPRESSION_DEPTH then
		return "{ --[[ expression depth limit ]] }"
	end

	if #node.entries == 0 then
		return "{}"
	end

	seen[node] = true

	local currentIndent = string.rep("\t", indent or 0)
	local childIndent = string.rep("\t", (indent or 0) + 1)
	local lines = {
		"{",
	}

	for _, entry in ipairs(node.entries) do
		local renderedValue = renderExpression(entry.value, (indent or 0) + 1, seen, depth + 1)
		if entry.array then
			table.insert(lines, ("%s%s,"):format(childIndent, renderedValue))
		else
			table.insert(lines, ("%s%s = %s,"):format(childIndent, entry.keyText, renderedValue))
		end
	end

	table.insert(lines, currentIndent .. "}")
	seen[node] = nil
	return table.concat(lines, "\n")
end

renderExpression = function(value, indent, seen, depth)
	if type(value) == "table" and value.kind == "table" then
		return renderTableNode(value, indent or 0, seen, depth or 0)
	end

	return expressionText(value)
end

local function materializeRegister(context, index, pc)
	local value = context.registers[index]
	if type(value) ~= "table" or value.kind ~= "table" then
		return getRegister(context, index)
	end

	if value.name ~= nil then
		return value.name
	end

	local target, isLocal = getWritableRegister(context, index, pc)
	local renderedTable = renderTableNode(value, 0)
	value.name = target

	if isLocal and not context.declaredLocals[target] then
		context.declaredLocals[target] = true
		emit(context, ("local %s = %s"):format(target, renderedTable))
	else
		emit(context, ("%s = %s"):format(target, renderedTable))
	end

	setRegister(context, index, target)
	return target
end

local function materializeValueRegister(context, index, pc)
	local value = context.registers[index]
	local rendered = renderExpression(value or makeTextValue(getRegister(context, index)), 0)
	local target = getWritableRegister(context, index, pc)

	if rendered == target then
		return target
	end

	if not context.declaredLocals[target] and target:match("^r%d+$") then
		context.declaredLocals[target] = true
		emit(context, ("local %s = %s"):format(target, rendered))
	else
		emit(context, ("%s = %s"):format(target, rendered))
	end

	setRegister(context, index, target)
	return target
end

local function preserveRegistersHoldingExpression(context, expression, sourceRegister, pc)
	for register, value in pairs(context.registers) do
		if register ~= sourceRegister and renderExpression(value, 0) == expression then
			materializeValueRegister(context, register, pc)
		end
	end
end

local function emitUnsupported(context, instruction)
	local name = instruction.name
	context.unsupported[name] = true

	if context.options.showUnsupported ~= false then
		local target = instruction.jumpTargetPc and (" -> pc " .. tostring(instruction.jumpTargetPc)) or ""
		emit(context, ("--[[ %04d %s%s ]]"):format(instruction.pc, name, target))
	end
end

local function emitJump(context, instruction)
	local name = instruction.name
	local fields = instruction.fields
	local aux = instruction.decodedAux
	local target = instruction.jumpTargetPc

	if name == "JUMP" or name == "JUMPBACK" or name == "JUMPX" then
		emit(context, ("-- goto pc %s"):format(tostring(target or "?")))
		return
	end

	if name == "JUMPIF" then
		emit(context, ("-- if %s then goto pc %s"):format(getRegister(context, fields.A), tostring(target or "?")))
		return
	end

	if name == "JUMPIFNOT" then
		emit(context, ("-- if not %s then goto pc %s"):format(getRegister(context, fields.A), tostring(target or "?")))
		return
	end

	local operator = COMPARE_OPERATORS[name]
	if operator ~= nil then
		emit(context, ("-- if %s %s %s then goto pc %s"):format(
			getRegister(context, fields.A),
			operator,
			getRegister(context, aux and aux.register or -1),
			tostring(target or "?")
		))
		return
	end

	if name == "JUMPXEQKNIL" then
		local operatorText = aux and aux.notFlag and "~=" or "=="
		emit(context, ("-- if %s %s nil then goto pc %s"):format(getRegister(context, fields.A), operatorText, tostring(target or "?")))
		return
	end

	if name == "JUMPXEQKB" then
		local operatorText = aux and aux.notFlag and "~=" or "=="
		emit(context, ("-- if %s %s %s then goto pc %s"):format(getRegister(context, fields.A), operatorText, tostring(aux and aux.value), tostring(target or "?")))
		return
	end

	if name == "JUMPXEQKN" or name == "JUMPXEQKS" then
		local operatorText = aux and aux.notFlag and "~=" or "=="
		emit(context, ("-- if %s %s %s then goto pc %s"):format(
			getRegister(context, fields.A),
			operatorText,
			constantToExpression(getConstant(context.proto, aux and aux.constantIndex)),
			tostring(target or "?")
		))
		return
	end

	emitUnsupported(context, instruction)
end

local function inverseOperator(operator)
	return INVERSE_OPERATORS[operator] or operator
end

local function negateExpression(expression)
	expression = tostring(expression)
	if expression:match("^[A-Za-z_][A-Za-z0-9_%.:%[%]\"']*$") then
		return "not " .. expression
	end

	return "not (" .. expression .. ")"
end

local function conditionForJump(context, instruction, invert)
	local name = instruction.name
	local fields = instruction.fields
	local aux = instruction.decodedAux
	local operator = COMPARE_OPERATORS[name]

	if name == "JUMPIF" then
		local expression = getRegister(context, fields.A)
		return invert and negateExpression(expression) or expression
	end

	if name == "JUMPIFNOT" then
		local expression = getRegister(context, fields.A)
		return invert and expression or negateExpression(expression)
	end

	if operator ~= nil then
		if invert then
			operator = inverseOperator(operator)
		end

		return ("%s %s %s"):format(
			getRegister(context, fields.A),
			operator,
			getRegister(context, aux and aux.register or -1)
		)
	end

	if name == "JUMPXEQKNIL" then
		local operatorText = aux and aux.notFlag and "~=" or "=="
		if invert then
			operatorText = inverseOperator(operatorText)
		end

		return ("%s %s nil"):format(getRegister(context, fields.A), operatorText)
	end

	if name == "JUMPXEQKB" then
		local operatorText = aux and aux.notFlag and "~=" or "=="
		if invert then
			operatorText = inverseOperator(operatorText)
		end

		return ("%s %s %s"):format(getRegister(context, fields.A), operatorText, tostring(aux and aux.value))
	end

	if name == "JUMPXEQKN" or name == "JUMPXEQKS" then
		local operatorText = aux and aux.notFlag and "~=" or "=="
		if invert then
			operatorText = inverseOperator(operatorText)
		end

		return ("%s %s %s"):format(
			getRegister(context, fields.A),
			operatorText,
			constantToExpression(getConstant(context.proto, aux and aux.constantIndex))
		)
	end

	local fallback = ("pc_%d_condition"):format(instruction.pc or 0)
	return invert and negateExpression(fallback) or fallback
end

local function indexInstructions(instructions)
	local pcToIndex = {}
	for index, instruction in ipairs(instructions) do
		pcToIndex[instruction.pc] = index
	end
	return pcToIndex
end

local function findInstructionBeforePc(instructions, pcToIndex, pc, lowerIndex)
	local index = pcToIndex[pc]
	if index == nil then
		return nil, nil
	end

	for candidateIndex = index - 1, lowerIndex or 1, -1 do
		local candidate = instructions[candidateIndex]
		if candidate ~= nil then
			return candidate, candidateIndex
		end
	end

	return nil, nil
end

local function indexAtOrAfterPc(instructions, pcToIndex, pc)
	local direct = pcToIndex[pc]
	if direct ~= nil then
		return direct
	end

	for index, instruction in ipairs(instructions) do
		if instruction.pc >= pc then
			return index
		end
	end

	return #instructions + 1
end

local function canStructureTarget(instruction, endPc)
	local targetPc = instruction.jumpTargetPc
	return targetPc ~= nil and targetPc > instructionEndPc(instruction) and targetPc <= endPc
end

local function tryEmitBooleanCoercion(context, instructions, pcToIndex, index)
	local instruction = instructions[index]
	if instruction == nil or instruction.name ~= "JUMPIFNOT" or instruction.jumpTargetPc == nil then
		return nil
	end

	local loadTrue = instructions[index + 1]
	local jumpOverFalse = instructions[index + 2]
	local falseIndex = pcToIndex[instruction.jumpTargetPc]
	local loadFalse = falseIndex and instructions[falseIndex] or nil

	if not (
		loadTrue
		and jumpOverFalse
		and loadFalse
		and loadTrue.name == "LOADB"
		and loadTrue.fields.B == 1
		and (jumpOverFalse.name == "JUMP" or jumpOverFalse.name == "JUMPX")
		and jumpOverFalse.jumpTargetPc ~= nil
		and loadFalse.name == "LOADB"
		and loadFalse.fields.B == 0
		and loadFalse.fields.A == loadTrue.fields.A
	) then
		return nil
	end

	local afterIndex = indexAtOrAfterPc(instructions, pcToIndex, jumpOverFalse.jumpTargetPc)
	local afterInstruction = instructions[afterIndex]
	local targetRegister = loadTrue.fields.A
	local nextIndex = afterIndex

	if afterInstruction and afterInstruction.name == "MOVE" and afterInstruction.fields.B == loadTrue.fields.A then
		targetRegister = afterInstruction.fields.A
		nextIndex = afterIndex + 1
	end

	local target = getWritableRegister(context, targetRegister, instruction.pc)
	local expression = ("%s and true or false"):format(getRegister(context, instruction.fields.A))

	emit(context, ("%s = %s"):format(target, expression))
	setRegister(context, loadTrue.fields.A, target)
	setRegister(context, targetRegister, target)

	return nextIndex
end

local function appendIndentedLines(lines, statements, indent)
	local prefix = string.rep("    ", indent or 0)

	if statements == nil or #statements == 0 then
		table.insert(lines, prefix .. "-- empty")
		return
	end

	for _, statement in ipairs(statements) do
		for line in tostring(statement):gmatch("([^\n]*)\n?") do
			if line == "" and statement:sub(-1) ~= "\n" then
				break
			end

			table.insert(lines, prefix .. line)
		end
	end
end

local function makeIfStatement(condition, thenStatements, elseStatements)
	local lines = {
		("if %s then"):format(condition),
	}

	appendIndentedLines(lines, thenStatements, 1)

	if elseStatements ~= nil then
		table.insert(lines, "else")
		appendIndentedLines(lines, elseStatements, 1)
	end

	table.insert(lines, "end")
	return table.concat(lines, "\n")
end

local function makeWhileStatement(condition, bodyStatements)
	local lines = {
		("while %s do"):format(condition),
	}

	appendIndentedLines(lines, bodyStatements, 1)
	table.insert(lines, "end")
	return table.concat(lines, "\n")
end

local function handleInstruction(context, instruction)
	local proto = context.proto
	local name = instruction.name
	local fields = instruction.fields
	local aux = instruction.decodedAux

	if name ~= "CAPTURE" and name ~= "NEWCLOSURE" and name ~= "DUPCLOSURE" then
		context.pendingClosure = nil
	end

	if name == "NOP" or name == "BREAK" or name == "COVERAGE" or name == "PREPVARARGS" or name == "CLOSEUPVALS" then
		return
	end

	if name == "GETIMPORT" then
		setRegister(context, fields.A, constantToExpression(getConstant(proto, fields.D)))
	elseif name == "GETGLOBAL" then
		setRegister(context, fields.A, constantToExpression(getConstant(proto, aux and aux.constantIndex)))
	elseif name == "GETUPVAL" then
		setRegister(context, fields.A, getUpvalueName(context, fields.B))
	elseif name == "MOVE" then
		setRegister(context, fields.A, getRegisterValue(context, fields.B))
	elseif name == "LOADK" then
		setRegister(context, fields.A, constantToExpression(getConstant(proto, fields.D)))
	elseif name == "LOADKX" then
		setRegister(context, fields.A, constantToExpression(getConstant(proto, aux and aux.constantIndex)))
	elseif name == "LOADN" then
		setRegister(context, fields.A, tostring(fields.D))
	elseif name == "LOADNIL" then
		setRegister(context, fields.A, "nil")
	elseif name == "LOADB" then
		setRegister(context, fields.A, tostring(fields.B ~= 0))
	elseif name == "GETTABLEKS" or name == "GETUDATAKS" then
		local baseText = type(context.registers[fields.B]) == "table" and context.registers[fields.B].kind == "table"
			and materializeRegister(context, fields.B, instruction.pc)
			or getRegister(context, fields.B)
		setRegister(context, fields.A, memberAccess(baseText, getConstantName(proto, aux and aux.constantIndex)))
	elseif name == "GETTABLEN" then
		local baseText = type(context.registers[fields.B]) == "table" and context.registers[fields.B].kind == "table"
			and materializeRegister(context, fields.B, instruction.pc)
			or getRegister(context, fields.B)
		setRegister(context, fields.A, ("%s[%d]"):format(baseText, fields.C + 1))
	elseif name == "GETTABLE" then
		local baseText = type(context.registers[fields.B]) == "table" and context.registers[fields.B].kind == "table"
			and materializeRegister(context, fields.B, instruction.pc)
			or getRegister(context, fields.B)
		setRegister(context, fields.A, ("%s[%s]"):format(baseText, getRegister(context, fields.C)))
	elseif name == "NAMECALL" or name == "NAMECALLUDATA" then
		local target = type(context.registers[fields.B]) == "table" and context.registers[fields.B].kind == "table"
			and materializeRegister(context, fields.B, instruction.pc)
			or getRegister(context, fields.B)
		context.registers[fields.A] = {
			kind = "method",
			target = target,
			method = getConstantName(proto, aux and aux.constantIndex),
		}
		setRegister(context, fields.A + 1, target)
	elseif name == "SETGLOBAL" then
		emit(context, ("%s = %s"):format(
			constantToExpression(getConstant(proto, aux and aux.constantIndex)),
			renderExpression(getRegisterValue(context, fields.A), 0)
		))
	elseif name == "SETUPVAL" then
		emit(context, ("%s = %s"):format(getUpvalueName(context, fields.B), renderExpression(getRegisterValue(context, fields.A), 0)))
	elseif name == "SETTABLEKS" or name == "SETUDATAKS" then
		local baseValue = context.registers[fields.B]
		local sourceValue = getRegisterValue(context, fields.A)
		local keyName = getConstantName(proto, aux and aux.constantIndex)
		if type(baseValue) == "table" and baseValue.kind == "table" then
			setTableEntry(baseValue, keyExpressionFromConstant(getConstant(proto, aux and aux.constantIndex)), sourceValue)
		elseif keyName == "__index" and fields.A == fields.B and context.options.inferModuleTableAliases ~= false then
			local alias = applyRegisterAlias(context, fields.B, context.options.moduleAlias or "ModuleTable", {
				localizeAssignment = true,
			}) or getRegister(context, fields.B)
			emit(context, ("%s.__index = %s"):format(alias, alias))
		elseif context.options.captureClosureAssignments and type(sourceValue) == "table" and sourceValue.kind == "closure" then
			table.insert(context.closureAssignments, {
				target = memberAccess(getRegister(context, fields.B), keyName),
				protoIndex = sourceValue.protoIndex,
				captures = cloneCaptures(sourceValue.captures),
			})
		else
			local targetExpression = memberAccess(getRegister(context, fields.B), keyName)
			preserveRegistersHoldingExpression(context, targetExpression, fields.A, instruction.pc)
			emit(context, ("%s = %s"):format(
				targetExpression,
				renderExpression(sourceValue, 0)
			))
		end
	elseif name == "SETTABLEN" then
		local baseValue = context.registers[fields.B]
		if type(baseValue) == "table" and baseValue.kind == "table" then
			setTableEntry(baseValue, tostring(fields.C + 1), getRegisterValue(context, fields.A), { array = true })
		else
			local targetExpression = ("%s[%d]"):format(getRegister(context, fields.B), fields.C + 1)
			preserveRegistersHoldingExpression(context, targetExpression, fields.A, instruction.pc)
			emit(context, ("%s = %s"):format(targetExpression, renderExpression(getRegisterValue(context, fields.A), 0)))
		end
	elseif name == "SETTABLE" then
		local baseValue = context.registers[fields.B]
		if type(baseValue) == "table" and baseValue.kind == "table" then
			setTableEntry(baseValue, ("[%s]"):format(getRegister(context, fields.C)), getRegisterValue(context, fields.A))
		else
			local targetExpression = ("%s[%s]"):format(getRegister(context, fields.B), getRegister(context, fields.C))
			preserveRegistersHoldingExpression(context, targetExpression, fields.A, instruction.pc)
			emit(context, ("%s = %s"):format(targetExpression, renderExpression(getRegisterValue(context, fields.A), 0)))
		end
	elseif name == "NEWTABLE" then
		setRegister(context, fields.A, makeTableNode())
	elseif name == "DUPTABLE" then
		setRegister(context, fields.A, tableNodeFromConstant(proto, getConstant(proto, fields.D)))
	elseif name == "SETLIST" then
		local baseValue = context.registers[fields.A]
		if type(baseValue) == "table" and baseValue.kind == "table" then
			local startIndex = aux and aux.tableIndex or 1
			if fields.C == 0 and context.openResult ~= nil and context.openResult.base == fields.B then
				setTableEntry(baseValue, tostring(startIndex), context.openResult.value, { array = true })
			else
				for offset = 0, math.max(0, fields.C - 1) do
					setTableEntry(baseValue, tostring(startIndex + offset), getRegisterValue(context, fields.B + offset), { array = true })
				end
			end
			context.openResult = nil
		else
			emit(context, ("-- table insert list into %s starting at %s"):format(getRegister(context, fields.A), tostring(aux and aux.tableIndex or "?")))
			context.openResult = nil
		end
	elseif name == "NEWCLOSURE" then
		local closure = makeClosureValue(resolveChildProtoIndex(proto, fields.D))
		setRegister(context, fields.A, closure)
		context.pendingClosure = closure
	elseif name == "DUPCLOSURE" then
		local constant = getConstant(proto, fields.D)
		local protoIndex = constant and constant.protoIndex or fields.D
		local closure = makeClosureValue(protoIndex)
		setRegister(context, fields.A, closure)
		context.pendingClosure = closure
	elseif name == "GETVARARGS" then
		local value = makeTextValue("...", { multret = fields.B == 0 })
		setRegister(context, fields.A, value)
		if fields.B == 0 then
			context.openResult = {
				base = fields.A,
				value = value,
			}
		end
	elseif BINARY_OPERATORS[name] ~= nil then
		setRegister(context, fields.A, ("(%s %s %s)"):format(getRegister(context, fields.B), BINARY_OPERATORS[name], getRegister(context, fields.C)))
	elseif BINARY_K_OPERATORS[name] ~= nil then
		setRegister(context, fields.A, ("(%s %s %s)"):format(getRegister(context, fields.B), BINARY_K_OPERATORS[name], constantToExpression(getConstant(proto, fields.C))))
	elseif RK_OPERATORS[name] ~= nil then
		setRegister(context, fields.A, ("(%s %s %s)"):format(constantToExpression(getConstant(proto, fields.B)), RK_OPERATORS[name], getRegister(context, fields.C)))
	elseif name == "CONCAT" then
		local values = {}
		for register = fields.B, fields.C do
			table.insert(values, getRegister(context, register))
		end
		setRegister(context, fields.A, ("(%s)"):format(table.concat(values, " .. ")))
	elseif name == "NOT" then
		setRegister(context, fields.A, ("not %s"):format(getRegister(context, fields.B)))
	elseif name == "MINUS" then
		setRegister(context, fields.A, ("-%s"):format(getRegister(context, fields.B)))
	elseif name == "LENGTH" then
		setRegister(context, fields.A, ("#%s"):format(getRegister(context, fields.B)))
	elseif name == "CALL" then
		local callee = context.registers[fields.A] or getRegister(context, fields.A)
		local args = collectCallArgs(context, fields.A, fields.B)
		local callExpression = buildCallExpression(callee, args)

		if fields.C == 1 then
			context.openResult = nil
			emit(context, callExpression)
		elseif fields.C == 0 then
			local value = makeTextValue(callExpression, { multret = true })
			setRegister(context, fields.A, value)
			context.openResult = {
				base = fields.A,
				value = value,
			}
		elseif fields.C == 2 then
			context.openResult = nil
			assignRegister(context, fields.A, callExpression, instruction.pc)
		else
			context.openResult = nil
			local targets = {}
			for offset = 0, fields.C - 2 do
				local target = getWritableRegister(context, fields.A + offset, instruction.pc)
				table.insert(targets, target)
				setRegister(context, fields.A + offset, target)
			end
			emit(context, ("%s = %s"):format(table.concat(targets, ", "), callExpression))
		end
	elseif name == "RETURN" then
		local values = collectReturnValues(context, fields.A, fields.B)
		if #values == 0 then
			emit(context, "return")
		else
			local renderedValues = {}
			for index, value in ipairs(values) do
				renderedValues[index] = renderExpression(value, 0)
			end
			emit(context, "return " .. table.concat(renderedValues, ", "))
		end
	elseif name:sub(1, 4) == "JUMP" then
		emitJump(context, instruction)
	elseif name == "FORNPREP" or name == "FORNLOOP" or name == "FORGPREP" or name == "FORGPREP_INEXT" or name == "FORGPREP_NEXT" or name == "FORGLOOP" then
		emit(context, ("--[[ %s loop control -> pc %s ]]"):format(name, tostring(instruction.jumpTargetPc or "?")))
	elseif name:sub(1, 8) == "FASTCALL" or name == "NATIVECALL" then
		emit(context, ("--[[ %s intrinsic call hint ]]"):format(name))
	elseif name == "CAPTURE" then
		local captureType = CAPTURE_TYPES[fields.A] or tostring(fields.A)
		local captureText

		if fields.A == 2 then
			captureText = getUpvalueName(context, fields.B)
		else
			captureText = materializeRegister(context, fields.B, instruction.pc)
		end

		if context.pendingClosure ~= nil then
			table.insert(context.pendingClosure.captures, {
				type = captureType,
				source = captureText,
			})
		end

		if context.options.showCaptureComments then
			emit(context, ("--[[ capture %s %s ]]"):format(captureType, captureText))
		end
	else
		emitUnsupported(context, instruction)
	end
end

local decompileStructuredRange

local function cloneMap(map)
	local copy = {}
	for key, value in pairs(map or {}) do
		copy[key] = value
	end
	return copy
end

local function emitWithStatementSink(context, sink, callback)
	local previousStatements = context.statements
	context.statements = sink

	local ok, result = pcall(callback)
	context.statements = previousStatements

	if not ok then
		error(result, 0)
	end

	return result
end

local function structuredRangeKey(startPc, endPc)
	return tostring(startPc or "?") .. ":" .. tostring(endPc or "?")
end

local function enterStructuredRange(context, startPc, endPc)
	if startPc == nil or endPc == nil or startPc >= endPc then
		return false, "empty"
	end

	local maxDepth = context.options.maxStructuredDepth or DEFAULT_MAX_STRUCTURED_DEPTH
	if (context.structuredDepth or 0) >= maxDepth then
		return false, "depth"
	end

	local key = structuredRangeKey(startPc, endPc)
	context.activeStructuredRanges = context.activeStructuredRanges or {}
	if context.activeStructuredRanges[key] then
		return false, "recursive"
	end

	context.structuredDepth = (context.structuredDepth or 0) + 1
	context.activeStructuredRanges[key] = true
	return true, key
end

local function leaveStructuredRange(context, key)
	if key ~= nil and context.activeStructuredRanges ~= nil then
		context.activeStructuredRanges[key] = nil
	end

	context.structuredDepth = math.max(0, (context.structuredDepth or 1) - 1)
end

local function decompileChildRange(context, instructions, pcToIndex, startPc, endPc)
	if startPc == nil or endPc == nil or startPc >= endPc then
		return {}
	end

	local statements = {}
	local registers = cloneMap(context.registers)
	local declaredLocals = cloneMap(context.declaredLocals)
	local pendingClosure = context.pendingClosure
	local openResult = context.openResult
	local structuredDepth = context.structuredDepth
	local activeStructuredRanges = cloneMap(context.activeStructuredRanges)

	local ok, result = pcall(emitWithStatementSink, context, statements, function()
		decompileStructuredRange(context, instructions, pcToIndex, startPc, endPc)
	end)

	context.registers = registers
	context.declaredLocals = declaredLocals
	context.pendingClosure = pendingClosure
	context.openResult = openResult
	context.structuredDepth = structuredDepth
	context.activeStructuredRanges = activeStructuredRanges

	if not ok then
		return {
			("--[[ structured child range failed: %s ]]"):format(tostring(result)),
		}
	end

	return statements
end

local function tryEmitStructuredConditional(context, instructions, pcToIndex, index, endPc)
	local instruction = instructions[index]
	if instruction == nil or not CONDITIONAL_JUMPS[instruction.name] or not canStructureTarget(instruction, endPc) then
		return nil
	end

	local booleanCoercionNext = tryEmitBooleanCoercion(context, instructions, pcToIndex, index)
	if booleanCoercionNext ~= nil then
		return booleanCoercionNext
	end

	local nextPc = instructionEndPc(instruction)
	local targetPc = instruction.jumpTargetPc
	local lastBeforeTarget = findInstructionBeforePc(instructions, pcToIndex, targetPc, index + 1)

	if lastBeforeTarget ~= nil and (lastBeforeTarget.name == "JUMPBACK" or lastBeforeTarget.name == "JUMPX") and lastBeforeTarget.jumpTargetPc == instruction.pc then
		local condition = conditionForJump(context, instruction, true)
		local body = decompileChildRange(context, instructions, pcToIndex, nextPc, lastBeforeTarget.pc)
		emit(context, makeWhileStatement(condition, body))
		return indexAtOrAfterPc(instructions, pcToIndex, targetPc)
	end

	if lastBeforeTarget ~= nil and UNCONDITIONAL_JUMPS[lastBeforeTarget.name] and lastBeforeTarget.jumpTargetPc ~= nil and lastBeforeTarget.jumpTargetPc > targetPc and lastBeforeTarget.jumpTargetPc <= endPc then
		local condition = conditionForJump(context, instruction, true)
		local thenBody = decompileChildRange(context, instructions, pcToIndex, nextPc, lastBeforeTarget.pc)
		local elseBody = decompileChildRange(context, instructions, pcToIndex, targetPc, lastBeforeTarget.jumpTargetPc)
		emit(context, makeIfStatement(condition, thenBody, elseBody))
		return indexAtOrAfterPc(instructions, pcToIndex, lastBeforeTarget.jumpTargetPc)
	end

	local condition = conditionForJump(context, instruction, true)
	local body = decompileChildRange(context, instructions, pcToIndex, nextPc, targetPc)
	emit(context, makeIfStatement(condition, body))
	return indexAtOrAfterPc(instructions, pcToIndex, targetPc)
end

decompileStructuredRange = function(context, instructions, pcToIndex, startPc, endPc)
	local entered, keyOrReason = enterStructuredRange(context, startPc, endPc)
	if not entered then
		if keyOrReason ~= "empty" then
			emit(context, ("--[[ structured control flow omitted: %s limit ]]"):format(tostring(keyOrReason)))
		end
		return
	end

	local index = pcToIndex[startPc]
	if index == nil then
		leaveStructuredRange(context, keyOrReason)
		return
	end

	while index <= #instructions do
		local instruction = instructions[index]
		if instruction == nil or instruction.pc >= endPc then
			break
		end

		local nextIndex = tryEmitStructuredConditional(context, instructions, pcToIndex, index, endPc)
		if nextIndex ~= nil and nextIndex > index then
			index = nextIndex
		else
			handleInstruction(context, instruction)
			index = index + 1
		end
	end

	leaveStructuredRange(context, keyOrReason)
end

local function decompileStructuredProto(context)
	local instructions = context.proto.disassembly and context.proto.disassembly.instructions or {}
	if #instructions == 0 then
		return false
	end

	local pcToIndex = indexInstructions(instructions)
	local startPc = instructions[1].pc
	local lastInstruction = instructions[#instructions]
	local endPc = instructionEndPc(lastInstruction)

	decompileStructuredRange(context, instructions, pcToIndex, startPc, endPc)
	return true
end

local function getParameterName(proto, register)
	return getLocalNameAtPc(proto, register, 0) or ("arg%d"):format(register + 1)
end

local function buildParameterList(proto, options)
	options = options or {}

	local params = {}
	local count = proto.numParams or proto.params or 0
	local startIndex = options.dropFirstParam and 1 or 0

	for index = startIndex, count - 1 do
		table.insert(params, getParameterName(proto, index))
	end

	if proto.isVararg then
		table.insert(params, "...")
	end

	return table.concat(params, ", ")
end

local function withParameterRegisterAliases(proto, options)
	options = options or {}

	local nextOptions = {}
	for key, value in pairs(options) do
		nextOptions[key] = value
	end

	local aliases = cloneMap(nextOptions.registerAliases)
	local count = proto.numParams or proto.params or 0

	if nextOptions.dropFirstParam then
		aliases[0] = aliases[0] or "self"
	end

	for register = 0, count - 1 do
		if aliases[register] == nil then
			aliases[register] = getParameterName(proto, register)
		end
	end

	nextOptions.registerAliases = aliases
	return nextOptions
end

local function summarizeUnsupported(context)
	local names = {}
	for name in pairs(context.unsupported) do
		table.insert(names, name)
	end
	table.sort(names)

	if #names == 0 then
		return nil
	end

	return "-- unsupported opcodes: " .. table.concat(names, ", ")
end

local function copyStatements(statements)
	local copy = table.create(#statements)
	for index, statement in ipairs(statements) do
		copy[index] = statement
	end

	return copy
end

local function trimTrailingSyntheticReturn(statements)
	while #statements > 0 and statements[#statements] == "return" do
		table.remove(statements)
	end
end

local function appendStatementLines(lines, statements, indent)
	local prefix = string.rep("    ", indent or 0)

	for _, statement in ipairs(statements) do
		for line in tostring(statement):gmatch("([^\n]*)\n?") do
			if line == "" and statement:sub(-1) ~= "\n" then
				break
			end

			table.insert(lines, prefix .. line)
		end
	end
end

local function buildRenderableStatements(context, options)
	local statements = copyStatements(context.statements)
	if options.trimSyntheticReturn ~= false then
		trimTrailingSyntheticReturn(statements)
	end

	if #statements == 0 then
		statements = { "-- no executable statements" }
	end

	return statements
end

local function appendTopLevelContext(lines, context, options)
	local unsupportedSummary = summarizeUnsupported(context)
	if unsupportedSummary ~= nil then
		table.insert(lines, unsupportedSummary)
	end

	appendStatementLines(lines, buildRenderableStatements(context, options), 0)
end

local function isFunctionDeclarationTarget(target)
	if type(target) ~= "string" then
		return false
	end

	local first = true
	for part in target:gmatch("[^.]+") do
		if not isIdentifier(part) then
			return false
		end

		first = false
	end

	return first == false
end

local function buildUpvalueAliases(captures)
	local aliases = {}
	for index, capture in ipairs(captures or {}) do
		aliases[index - 1] = capture.source
	end
	return aliases
end

local function addModuleAliasCandidate(candidates, text)
	text = tostring(text or "")

	local suffixes = {
		"Action",
		"Frame",
		"Gui",
		"GUI",
		"Controller",
		"Button",
		"Container",
		"Handler",
		"Manager",
	}

	for _, suffix in ipairs(suffixes) do
		local candidate = text:match("^([A-Z][A-Za-z0-9_]+)" .. suffix .. "$")
		candidate = sanitizeIdentifier(candidate, nil)
		if candidate ~= nil and #candidate >= 3 then
			candidates[candidate] = (candidates[candidate] or 0) + 1
		end
	end
end

local function inferModuleAliasFromChunk(chunk)
	local candidates = {}

	for _, value in ipairs(chunk.strings or {}) do
		addModuleAliasCandidate(candidates, value)
	end

	for _, proto in ipairs(chunk.protos or {}) do
		for _, constant in ipairs(proto.constants or {}) do
			if constant.kind == "string" then
				addModuleAliasCandidate(candidates, constant.value)
			end
		end
	end

	local bestAlias
	local bestScore = 0
	for alias, count in pairs(candidates) do
		local score = (count * 1000) + #alias
		if count >= 2 and score > bestScore then
			bestAlias = alias
			bestScore = score
		end
	end

	return bestAlias
end

local function buildFunctionDeclarationTarget(target, proto)
	local receiver, method = tostring(target or ""):match("^(.+)%.([A-Za-z_][A-Za-z0-9_]*)$")
	local debugName = getUsefulDebugName(proto)

	if receiver ~= nil and method ~= "new" and (proto.numParams or 0) > 0 then
		if debugName ~= nil and (method:match("^k%d+$") or method:match("^proto_%d+$")) then
			method = debugName
		end

		return ("%s:%s"):format(receiver, method), true
	end

	if receiver ~= nil and debugName ~= nil and (method:match("^k%d+$") or method:match("^proto_%d+$")) then
		return ("%s.%s"):format(receiver, debugName), false
	end

	return target, false
end

local function analyzeProto(proto, options)
	options = options or {}

	local context = makeContext(proto, options)

	if proto.disassembly and proto.disassembly.instructions then
		local structuredOk = false
		if options.structuredControlFlow ~= false then
			local ok, result = pcall(decompileStructuredProto, context)
			structuredOk = ok and result == true
			if not ok then
				context = makeContext(proto, options)
				emit(context, ("--[[ structured decompile failed; linear fallback: %s ]]"):format(tostring(result)))
			end
		end

		if not structuredOk then
			for _, instruction in ipairs(proto.disassembly.instructions) do
				handleInstruction(context, instruction)
			end
		end
	end

	if #context.statements == 0 then
		if proto.behaviorSummary then
			context.statements = {
				"-- best effort",
				proto.behaviorSummary,
			}
		else
			context.statements = {
				"-- decompiler could not reconstruct this proto yet",
			}
		end
	end

	return context
end

function LuauDecompiler.analyzeProto(proto, options)
	return analyzeProto(proto, options)
end

function LuauDecompiler.decompileProto(proto, options)
	options = withParameterRegisterAliases(proto, options or {})

	local context = analyzeProto(proto, options)

	if options.asTopLevel then
		local lines = {}
		appendTopLevelContext(lines, context, options)
		return table.concat(lines, "\n")
	end

	local lines = {
		("function %s(%s)"):format(options.functionName or getProtoFunctionName(proto), buildParameterList(proto, options)),
	}

	local unsupportedSummary = summarizeUnsupported(context)
	if unsupportedSummary ~= nil then
		table.insert(lines, "    " .. unsupportedSummary)
	end

	appendStatementLines(lines, buildRenderableStatements(context, options), 1)

	table.insert(lines, "end")
	return table.concat(lines, "\n")
end

function LuauDecompiler.decompileChunk(chunk, options)
	options = options or {}

	local lines = {
		"-- LuauDecompiler v2",
		"-- best-effort output; simple control flow is structured, complex flow remains pc comments",
	}

	local protos = chunk.protos or {}
	local mainProtoIndex = chunk.mainProtoIndex
	local assignedClosureProtos = {}
	local moduleAlias = options.moduleAlias or inferModuleAliasFromChunk(chunk)

	if options.topLevelMain ~= false and mainProtoIndex ~= nil then
		local mainProto = protos[mainProtoIndex + 1]
		if mainProto ~= nil then
			local mainContext = analyzeProto(mainProto, {
				asTopLevel = true,
				captureClosureAssignments = options.inlineAssignedClosures ~= false,
				moduleAlias = moduleAlias,
				showUnsupported = options.showUnsupported,
				trimSyntheticReturn = options.trimSyntheticReturn,
				upvalueAliases = options.upvalueAliases,
			})

			table.insert(lines, "")
			table.insert(lines, "-- Main")
			local mainLines = {}
			local unsupportedSummary = summarizeUnsupported(mainContext)
			if unsupportedSummary ~= nil then
				table.insert(mainLines, unsupportedSummary)
			end

			local mainStatements = buildRenderableStatements(mainContext, {
				trimSyntheticReturn = options.trimSyntheticReturn,
			})
			local trailingReturn = nil
			if #mainStatements > 0 and tostring(mainStatements[#mainStatements]):match("^return") then
				trailingReturn = table.remove(mainStatements)
			end

			appendStatementLines(mainLines, mainStatements, 0)

			if options.inlineAssignedClosures ~= false then
				for _, assignment in ipairs(mainContext.closureAssignments) do
					local childProto = assignment.protoIndex ~= nil and protos[assignment.protoIndex + 1] or nil
					if childProto ~= nil and isFunctionDeclarationTarget(assignment.target) then
						assignedClosureProtos[assignment.protoIndex] = true
						local functionName, dropFirstParam = buildFunctionDeclarationTarget(assignment.target, childProto)
						local registerAliases = dropFirstParam and { [0] = "self" } or nil

						table.insert(mainLines, "")
						table.insert(mainLines, LuauDecompiler.decompileProto(childProto, {
							dropFirstParam = dropFirstParam,
							functionName = functionName,
							registerAliases = registerAliases,
							upvalueAliases = buildUpvalueAliases(assignment.captures),
							showUnsupported = options.showUnsupported,
							trimSyntheticReturn = options.trimSyntheticReturn,
						}))
					end
				end
			end

			if trailingReturn ~= nil then
				table.insert(mainLines, "")
				appendStatementLines(mainLines, { trailingReturn }, 0)
			end

			table.insert(lines, table.concat(mainLines, "\n"))
		end
	end

	local helperHeaderAdded = false
	for _, proto in ipairs(protos) do
		if not assignedClosureProtos[proto.index] and not (options.topLevelMain ~= false and mainProtoIndex ~= nil and proto.index == mainProtoIndex) then
			if not helperHeaderAdded then
				table.insert(lines, "")
				table.insert(lines, "-- Protos")
				helperHeaderAdded = true
			end

			table.insert(lines, "")
			table.insert(lines, LuauDecompiler.decompileProto(proto, options))
		end
	end

	if options.topLevelMain == false then
		lines = {
			"-- LuauDecompiler v2",
			"-- best-effort output; simple control flow is structured, complex flow remains pc comments",
		}

		for _, proto in ipairs(protos) do
			table.insert(lines, "")
			table.insert(lines, LuauDecompiler.decompileProto(proto, options))
		end
	end

	if #protos == 0 then
		table.insert(lines, "")
		table.insert(lines, "-- no protos decoded")
	end

	return table.concat(lines, "\n")
end

return LuauDecompiler
