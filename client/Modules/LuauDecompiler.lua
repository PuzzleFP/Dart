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

local LUA_KEYWORDS = {
	["and"] = true,
	["break"] = true,
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
		if localInfo.register == register and localInfo.name and localInfo.name ~= "" then
			local startPc = localInfo.startPc or 0
			local endPc = localInfo.endPc or math.huge
			if pc >= startPc and pc < endPc then
				return localInfo.name
			end
		end
	end

	return nil
end

local function makeContext(proto, options)
	return {
		proto = proto,
		options = options or {},
		registers = {},
		declaredLocals = {},
		statements = {},
		unsupported = {},
		openResult = nil,
	}
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

	return tostring(value)
end

local function rawRegisterName(index)
	return ("r%d"):format(index)
end

local function getRegister(context, index)
	local value = context.registers[index]
	if value == nil then
		return rawRegisterName(index)
	end

	return expressionText(value)
end

local function getRegisterValue(context, index)
	local value = context.registers[index]
	if value == nil then
		return makeTextValue(rawRegisterName(index))
	end

	return value
end

local function getWritableRegister(context, index, pc)
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

local function assignRegister(context, index, expression, pc)
	local target, isLocal = getWritableRegister(context, index, pc)
	setRegister(context, index, target)
	local renderedExpression = renderExpression(expression, 0)

	if isLocal and not context.declaredLocals[target] then
		context.declaredLocals[target] = true
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

local function getClosureExpression(protoIndex)
	if protoIndex == nil then
		return "function(...) --[[ unknown proto ]] end"
	end

	return ("proto_%d"):format(protoIndex)
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

local function renderTableNode(node, indent)
	if node.name ~= nil then
		return node.name
	end

	if #node.entries == 0 then
		return "{}"
	end

	local currentIndent = string.rep("\t", indent or 0)
	local childIndent = string.rep("\t", (indent or 0) + 1)
	local lines = {
		"{",
	}

	for _, entry in ipairs(node.entries) do
		local renderedValue = renderExpression(entry.value, (indent or 0) + 1)
		if entry.array then
			table.insert(lines, ("%s%s,"):format(childIndent, renderedValue))
		else
			table.insert(lines, ("%s%s = %s,"):format(childIndent, entry.keyText, renderedValue))
		end
	end

	table.insert(lines, currentIndent .. "}")
	return table.concat(lines, "\n")
end

renderExpression = function(value, indent)
	if type(value) == "table" and value.kind == "table" then
		return renderTableNode(value, indent or 0)
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

local function handleInstruction(context, instruction)
	local proto = context.proto
	local name = instruction.name
	local fields = instruction.fields
	local aux = instruction.decodedAux

	if name == "NOP" or name == "BREAK" or name == "COVERAGE" or name == "PREPVARARGS" or name == "CLOSEUPVALS" then
		return
	end

	if name == "GETIMPORT" then
		setRegister(context, fields.A, constantToExpression(getConstant(proto, fields.D)))
	elseif name == "GETGLOBAL" then
		setRegister(context, fields.A, constantToExpression(getConstant(proto, aux and aux.constantIndex)))
	elseif name == "GETUPVAL" then
		local upvalue = proto.upvalues and proto.upvalues[fields.B + 1]
		setRegister(context, fields.A, upvalue and upvalue.name or ("upvalue_%d"):format(fields.B))
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
		local upvalue = proto.upvalues and proto.upvalues[fields.B + 1]
		emit(context, ("%s = %s"):format(upvalue and upvalue.name or ("upvalue_%d"):format(fields.B), renderExpression(getRegisterValue(context, fields.A), 0)))
	elseif name == "SETTABLEKS" or name == "SETUDATAKS" then
		local baseValue = context.registers[fields.B]
		if type(baseValue) == "table" and baseValue.kind == "table" then
			setTableEntry(baseValue, keyExpressionFromConstant(getConstant(proto, aux and aux.constantIndex)), getRegisterValue(context, fields.A))
		else
			emit(context, ("%s = %s"):format(
				memberAccess(getRegister(context, fields.B), getConstantName(proto, aux and aux.constantIndex)),
				renderExpression(getRegisterValue(context, fields.A), 0)
			))
		end
	elseif name == "SETTABLEN" then
		local baseValue = context.registers[fields.B]
		if type(baseValue) == "table" and baseValue.kind == "table" then
			setTableEntry(baseValue, tostring(fields.C + 1), getRegisterValue(context, fields.A), { array = true })
		else
			emit(context, ("%s[%d] = %s"):format(getRegister(context, fields.B), fields.C + 1, renderExpression(getRegisterValue(context, fields.A), 0)))
		end
	elseif name == "SETTABLE" then
		local baseValue = context.registers[fields.B]
		if type(baseValue) == "table" and baseValue.kind == "table" then
			setTableEntry(baseValue, ("[%s]"):format(getRegister(context, fields.C)), getRegisterValue(context, fields.A))
		else
			emit(context, ("%s[%s] = %s"):format(getRegister(context, fields.B), getRegister(context, fields.C), renderExpression(getRegisterValue(context, fields.A), 0)))
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
		setRegister(context, fields.A, getClosureExpression(fields.D))
	elseif name == "DUPCLOSURE" then
		local constant = getConstant(proto, fields.D)
		local protoIndex = constant and constant.protoIndex or fields.D
		setRegister(context, fields.A, getClosureExpression(protoIndex))
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
		local captureText = materializeRegister(context, fields.C, instruction.pc)
		emit(context, ("--[[ capture %s %s ]]"):format(tostring(fields.B), captureText))
	else
		emitUnsupported(context, instruction)
	end
end

local function buildParameterList(proto)
	local params = {}
	local count = proto.numParams or proto.params or 0

	for index = 0, count - 1 do
		local name = getLocalNameAtPc(proto, index, 0) or ("arg%d"):format(index + 1)
		table.insert(params, name)
	end

	if proto.isVararg then
		table.insert(params, "...")
	end

	return table.concat(params, ", ")
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

function LuauDecompiler.decompileProto(proto, options)
	options = options or {}

	local context = makeContext(proto, options)

	if proto.disassembly and proto.disassembly.instructions then
		for _, instruction in ipairs(proto.disassembly.instructions) do
			handleInstruction(context, instruction)
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

	local statements = copyStatements(context.statements)
	if options.trimSyntheticReturn ~= false then
		trimTrailingSyntheticReturn(statements)
	end

	if #statements == 0 then
		statements = { "-- no executable statements" }
	end

	if options.asTopLevel then
		local lines = {}
		local unsupportedSummary = summarizeUnsupported(context)
		if unsupportedSummary ~= nil then
			table.insert(lines, unsupportedSummary)
		end

		appendStatementLines(lines, statements, 0)
		return table.concat(lines, "\n")
	end

	local lines = {
		("function proto_%d(%s)"):format(proto.index or 0, buildParameterList(proto)),
	}

	local unsupportedSummary = summarizeUnsupported(context)
	if unsupportedSummary ~= nil then
		table.insert(lines, "    " .. unsupportedSummary)
	end

	appendStatementLines(lines, statements, 1)

	table.insert(lines, "end")
	return table.concat(lines, "\n")
end

function LuauDecompiler.decompileChunk(chunk, options)
	options = options or {}

	local lines = {
		"-- LuauDecompiler v2",
		"-- best-effort output; complex control flow is emitted as pc comments",
	}

	local protos = chunk.protos or {}
	local mainProtoIndex = chunk.mainProtoIndex

	if options.topLevelMain ~= false and mainProtoIndex ~= nil then
		local mainProto = protos[mainProtoIndex + 1]
		if mainProto ~= nil then
			table.insert(lines, "")
			table.insert(lines, "-- Main")
			table.insert(lines, LuauDecompiler.decompileProto(mainProto, {
				asTopLevel = true,
				showUnsupported = options.showUnsupported,
				trimSyntheticReturn = options.trimSyntheticReturn,
			}))
		end
	end

	local helperHeaderAdded = false
	for _, proto in ipairs(protos) do
		if not (options.topLevelMain ~= false and mainProtoIndex ~= nil and proto.index == mainProtoIndex) then
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
			"-- best-effort output; complex control flow is emitted as pc comments",
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
