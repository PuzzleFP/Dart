local Config = {
	GameName = "Dart",
	Debug = true,
	ShowWelcomeNotification = true,
	EnableBytecodeViewer = true,
	RemoteRepoOwner = "PuzzleFP",
	RemoteRepoName = "Dart",
	RemoteRepoRef = "main",
	RemoteModulesPath = "client/Modules",
	RemoteRawBaseUrl = "https://raw.githubusercontent.com/PuzzleFP/Dart/main/",
	RemoteModulesBaseUrl = "https://raw.githubusercontent.com/PuzzleFP/Dart/main/client/Modules/",
	RemoteMainUrl = "https://raw.githubusercontent.com/PuzzleFP/Dart/main/client/main.lua",
	DefaultBytecodeSourceMode = "script",
	DefaultScriptPath = "",
	DefaultBytecodeFilePath = "C:\\Users\\Marin\\Downloads\\Test.txt",
	DefaultBytecodeInputFormat = "binary",
	ShowRawOpcodes = true,
	ShowStringTableByDefault = false,
	ShowConstantTableByDefault = true,
}

return table.freeze(Config)
