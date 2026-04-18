# Luau Decompiler Design

The decompiler should be driven by Luau's real bytecode/compiler source, not by guessed opcode behavior from samples.

## Source Of Truth

- `Common/include/Luau/Bytecode.h`: opcode order, instruction encodings, bytecode versions, AUX layouts, capture types, and jump semantics.
- `Compiler/src/Compiler.cpp`: compiler emission patterns, especially closure creation and `CAPTURE` emission.
- `Compiler/src/BytecodeBuilder.cpp`: official disassembly formatting and validation assumptions.
- `VM/src/lvmexecute.cpp`: runtime behavior for opcodes and pseudo-opcodes.

## Pipeline

1. Decode bytecode using the official opcode order and operand layouts.
2. Build low IR from decoded instructions and preserve register/upvalue/capture metadata.
3. Build a control-flow graph from jumps, returns, and loop opcodes.
4. Convert low IR plus CFG into medium IR with basic expressions, closure bindings, and table construction.
5. Lift medium IR into high IR with structured `if`, `while`, `for`, function, and method forms.
6. Emit readable Luau from high IR.

## Current CFG Recovery

The first structuring pass is intentionally conservative:

- Forward conditional jumps are recovered as `if ... then` regions when the target lands after the fallthrough body.
- Forward conditional jumps followed by a terminal forward `JUMP` are recovered as `if ... then ... else ... end`.
- A conditional loop guard whose body ends with `JUMPBACK` / `JUMPX` to the guard is recovered as `while ... do`.
- Any shape that does not match these patterns is kept as opcode/pc comments until a later high-IR pass can prove it safe.

## Current Name Recovery

The name recovery pass uses bytecode/debug metadata plus conservative heuristics:

- Proto debug names are used as function-name fallbacks when there is no better assignment target.
- Local debug ranges are used for parameter and local variable names when their register range covers the current PC.
- Upvalue debug names are used for `GETUPVAL`, `SETUPVAL`, and closure capture aliases.
- `game:GetService("Players")` style assignments become local aliases such as `Players`.
- `require(...:WaitForChild("ModuleName"))` assignments become local aliases such as `ModuleName`.
- Returned metatable-style module tables are detected from `table.__index = table`.
- If bytecode has no local name for the returned module table, a module alias is inferred from repeated PascalCase string prefixes such as `DynamicThumbstickAction` and `DynamicThumbstickFrame`.
- Top-level closure assignments to that table are emitted as named functions. Methods with an implicit first `self` parameter are emitted with `:` syntax.

## Regression Loop

For every reference pair:

1. Save the original source, bytecode/opcode view, and current decompile output.
2. Identify one mismatch category, such as closure captures, table constructors, calls, methods, or control flow.
3. Verify the correct behavior against Luau source.
4. Patch the relevant decompiler stage.
5. Re-run the same sample and keep the change only if it improves the functional match without breaking simpler samples.

The goal is functional equivalence first. Exact variable names and formatting are secondary unless debug info provides them.
