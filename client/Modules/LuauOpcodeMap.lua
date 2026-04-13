local function define(name, encoding, options)
	options = options or {}

	return {
		name = name,
		encoding = encoding,
		length = options.length or 1,
		jumpField = options.jumpField,
		auxKind = options.auxKind,
	}
end

local definitions = {
	define("NOP", "ABC"),
	define("BREAK", "ABC"),
	define("LOADNIL", "ABC"),
	define("LOADB", "ABC"),
	define("LOADN", "AD"),
	define("LOADK", "AD"),
	define("MOVE", "ABC"),
	define("GETGLOBAL", "ABC", { length = 2, auxKind = "constantIndex" }),
	define("SETGLOBAL", "ABC", { length = 2, auxKind = "constantIndex" }),
	define("GETUPVAL", "ABC"),
	define("SETUPVAL", "ABC"),
	define("CLOSEUPVALS", "ABC"),
	define("GETIMPORT", "AD", { length = 2, auxKind = "importPath" }),
	define("GETTABLE", "ABC"),
	define("SETTABLE", "ABC"),
	define("GETTABLEKS", "ABC", { length = 2, auxKind = "constantIndex" }),
	define("SETTABLEKS", "ABC", { length = 2, auxKind = "constantIndex" }),
	define("GETTABLEN", "ABC"),
	define("SETTABLEN", "ABC"),
	define("NEWCLOSURE", "AD"),
	define("NAMECALL", "ABC", { length = 2, auxKind = "constantIndex" }),
	define("CALL", "ABC"),
	define("RETURN", "ABC"),
	define("JUMP", "AD", { jumpField = "D" }),
	define("JUMPBACK", "AD", { jumpField = "D" }),
	define("JUMPIF", "AD", { jumpField = "D" }),
	define("JUMPIFNOT", "AD", { jumpField = "D" }),
	define("JUMPIFEQ", "AD", { length = 2, jumpField = "D", auxKind = "compareRegister" }),
	define("JUMPIFLE", "AD", { length = 2, jumpField = "D", auxKind = "compareRegister" }),
	define("JUMPIFLT", "AD", { length = 2, jumpField = "D", auxKind = "compareRegister" }),
	define("JUMPIFNOTEQ", "AD", { length = 2, jumpField = "D", auxKind = "compareRegister" }),
	define("JUMPIFNOTLE", "AD", { length = 2, jumpField = "D", auxKind = "compareRegister" }),
	define("JUMPIFNOTLT", "AD", { length = 2, jumpField = "D", auxKind = "compareRegister" }),
	define("ADD", "ABC"),
	define("SUB", "ABC"),
	define("MUL", "ABC"),
	define("DIV", "ABC"),
	define("MOD", "ABC"),
	define("POW", "ABC"),
	define("ADDK", "ABC"),
	define("SUBK", "ABC"),
	define("MULK", "ABC"),
	define("DIVK", "ABC"),
	define("MODK", "ABC"),
	define("POWK", "ABC"),
	define("AND", "ABC"),
	define("OR", "ABC"),
	define("ANDK", "ABC"),
	define("ORK", "ABC"),
	define("CONCAT", "ABC"),
	define("NOT", "ABC"),
	define("MINUS", "ABC"),
	define("LENGTH", "ABC"),
	define("NEWTABLE", "ABC", { length = 2, auxKind = "arraySize" }),
	define("DUPTABLE", "AD"),
	define("SETLIST", "ABC", { length = 2, auxKind = "tableIndex" }),
	define("FORNPREP", "AD", { jumpField = "D" }),
	define("FORNLOOP", "AD", { jumpField = "D" }),
	define("FORGLOOP", "AD", { length = 2, jumpField = "D", auxKind = "forgLoop" }),
	define("FORGPREP_INEXT", "AD", { jumpField = "D" }),
	define("FASTCALL3", "ABC", { length = 2, jumpField = "C", auxKind = "fastcall3" }),
	define("FORGPREP_NEXT", "AD", { jumpField = "D" }),
	define("NATIVECALL", "ABC"),
	define("GETVARARGS", "ABC"),
	define("DUPCLOSURE", "AD"),
	define("PREPVARARGS", "ABC"),
	define("LOADKX", "ABC", { length = 2, auxKind = "constantIndex" }),
	define("JUMPX", "E", { jumpField = "E" }),
	define("FASTCALL", "ABC", { jumpField = "C" }),
	define("COVERAGE", "E"),
	define("CAPTURE", "ABC"),
	define("SUBRK", "ABC"),
	define("DIVRK", "ABC"),
	define("FASTCALL1", "ABC", { jumpField = "C" }),
	define("FASTCALL2", "ABC", { length = 2, jumpField = "C", auxKind = "fastcall2" }),
	define("FASTCALL2K", "ABC", { length = 2, jumpField = "C", auxKind = "fastcall2k" }),
	define("FORGPREP", "AD", { jumpField = "D" }),
	define("JUMPXEQKNIL", "AD", { length = 2, jumpField = "D", auxKind = "jumpxEqNil" }),
	define("JUMPXEQKB", "AD", { length = 2, jumpField = "D", auxKind = "jumpxEqBoolean" }),
	define("JUMPXEQKN", "AD", { length = 2, jumpField = "D", auxKind = "jumpxEqConstant" }),
	define("JUMPXEQKS", "AD", { length = 2, jumpField = "D", auxKind = "jumpxEqConstant" }),
	define("IDIV", "ABC"),
	define("IDIVK", "ABC"),
	define("GETUDATAKS", "ABC", { length = 2, auxKind = "userdataField" }),
	define("SETUDATAKS", "ABC", { length = 2, auxKind = "userdataField" }),
	define("NAMECALLUDATA", "ABC", { length = 2, auxKind = "userdataField" }),
}

local byId = {}
local byName = {}

for index, definition in ipairs(definitions) do
	local opcode = index - 1
	local copy = {
		opcode = opcode,
		name = definition.name,
		encoding = definition.encoding,
		length = definition.length,
		jumpField = definition.jumpField,
		auxKind = definition.auxKind,
	}

	byId[opcode] = copy
	byName[copy.name] = copy
end

return table.freeze({
	count = #definitions,
	byId = table.freeze(byId),
	byName = table.freeze(byName),
})
