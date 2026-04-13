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
		return string.format("%q", constant.value)
	end

	if constant.kind == "import" then
		return constant.pathText or ("import(%d)"):format(constant.id or -1)
	end

	return LuauBytecode.formatConstant(constant)
end

local function getConstant(proto, index)
	if index == nil then
		return nil
	end

	return proto.constants[index + 1]
end

local function getRegister(registers, index)
	local value = registers[index]
	if value == nil then
		return ("r%d"):format(index)
	end

	return value
end

local function buildCallExpression(callee, args)
	if type(callee) == "table" and callee.kind == "method" then
		local normalizedArgs = {}
		for index, value in ipairs(args) do
			normalizedArgs[index] = value
		end

		if normalizedArgs[1] == callee.target then
			table.remove(normalizedArgs, 1)
		end

		return ("%s:%s(%s)"):format(callee.target, callee.method, table.concat(normalizedArgs, ", "))
	end

	return ("%s(%s)"):format(tostring(callee), table.concat(args, ", "))
end

local function collectCallArgs(registers, baseRegister, fieldB)
	local args = {}

	if fieldB == 0 then
		local scan = baseRegister + 1
		while registers[scan] ~= nil do
			table.insert(args, getRegister(registers, scan))
			scan = scan + 1
		end
		return args
	end

	for offset = 1, fieldB - 1 do
		table.insert(args, getRegister(registers, baseRegister + offset))
	end

	return args
end

local function collectReturnValues(registers, baseRegister, fieldB)
	if fieldB == 1 then
		return {}
	end

	if fieldB == 0 then
		return { "..." }
	end

	local values = {}
	for offset = 0, fieldB - 2 do
		table.insert(values, getRegister(registers, baseRegister + offset))
	end

	return values
end

function LuauDecompiler.decompileProto(proto, options)
	options = options or {}

	local registers = {}
	local statements = {}

	local function emit(statement)
		if statement ~= nil and statement ~= "" then
			table.insert(statements, statement)
		end
	end

	local function setRegister(index, value)
		registers[index] = value
	end

	for _, instruction in ipairs(proto.disassembly.instructions) do
		local name = instruction.name
		local fields = instruction.fields
		local aux = instruction.decodedAux

		if name == "GETIMPORT" then
			setRegister(fields.A, constantToExpression(getConstant(proto, fields.D)))
		elseif name == "GETGLOBAL" then
			setRegister(fields.A, constantToExpression(getConstant(proto, aux and aux.constantIndex)))
		elseif name == "MOVE" then
			setRegister(fields.A, getRegister(registers, fields.B))
		elseif name == "LOADK" then
			setRegister(fields.A, constantToExpression(getConstant(proto, fields.D)))
		elseif name == "LOADKX" then
			setRegister(fields.A, constantToExpression(getConstant(proto, aux and aux.constantIndex)))
		elseif name == "LOADN" then
			setRegister(fields.A, tostring(fields.D))
		elseif name == "LOADNIL" then
			setRegister(fields.A, "nil")
		elseif name == "LOADB" then
			setRegister(fields.A, tostring(fields.B ~= 0))
		elseif name == "GETTABLEKS" then
			local member = getConstant(proto, aux and aux.constantIndex)
			local memberName = member and member.kind == "string" and member.value or ("k%d"):format(aux and aux.constantIndex or -1)
			setRegister(fields.A, ("%s.%s"):format(getRegister(registers, fields.B), memberName))
		elseif name == "GETTABLEN" then
			setRegister(fields.A, ("%s[%d]"):format(getRegister(registers, fields.B), fields.C + 1))
		elseif name == "NAMECALL" then
			local member = getConstant(proto, aux and aux.constantIndex)
			local memberName = member and member.kind == "string" and member.value or ("k%d"):format(aux and aux.constantIndex or -1)
			local target = getRegister(registers, fields.B)
			setRegister(fields.A, {
				kind = "method",
				target = target,
				method = memberName,
			})
			setRegister(fields.A + 1, target)
		elseif name == "SETGLOBAL" then
			local globalName = constantToExpression(getConstant(proto, aux and aux.constantIndex))
			emit(("%s = %s"):format(globalName, getRegister(registers, fields.A)))
		elseif name == "SETTABLEKS" then
			local member = getConstant(proto, aux and aux.constantIndex)
			local memberName = member and member.kind == "string" and member.value or ("k%d"):format(aux and aux.constantIndex or -1)
			emit(("%s.%s = %s"):format(
				getRegister(registers, fields.B),
				memberName,
				getRegister(registers, fields.A)
			))
		elseif name == "CALL" then
			local callee = getRegister(registers, fields.A)
			local args = collectCallArgs(registers, fields.A, fields.B)
			local callExpression = buildCallExpression(callee, args)

			if fields.C == 1 then
				emit(callExpression)
			else
				setRegister(fields.A, callExpression)
				if fields.C == 0 then
					emit(callExpression)
				end
			end
		elseif name == "RETURN" then
			local values = collectReturnValues(registers, fields.A, fields.B)
			if #values == 0 then
				emit("return")
			else
				emit("return " .. table.concat(values, ", "))
			end
		end
	end

	if #statements == 0 then
		if proto.behaviorSummary then
			statements = {
				"-- best effort",
				proto.behaviorSummary,
			}
		else
			statements = {
				"-- v1 decompiler could not reconstruct this proto yet",
			}
		end
	end

	local lines = {
		("function proto_%d(%s)"):format(proto.index, proto.isVararg and "..." or ""),
	}

	for _, statement in ipairs(statements) do
		table.insert(lines, "    " .. statement)
	end

	table.insert(lines, "end")
	return table.concat(lines, "\n")
end

function LuauDecompiler.decompileChunk(chunk, options)
	options = options or {}

	local lines = {
		"-- LuauDecompiler v1",
	}

	for _, proto in ipairs(chunk.protos) do
		table.insert(lines, "")
		table.insert(lines, LuauDecompiler.decompileProto(proto, options))
	end

	return table.concat(lines, "\n")
end

return LuauDecompiler
