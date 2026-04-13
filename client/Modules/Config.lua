local Config = {
	GameName = "Dart",
	Debug = true,
	ShowWelcomeNotification = true,
	EnableIrisBytecodeViewer = true,
	IrisModuleName = "Iris",
	DefaultBytecodeFilePath = "C:\\Users\\Marin\\Downloads\\Test.txt",
	DefaultBytecodeInputFormat = "binary",
	ShowRawOpcodes = true,
	ShowStringTableByDefault = false,
	ShowConstantTableByDefault = true,
}

return table.freeze(Config)
