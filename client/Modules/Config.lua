local Config = {
	GameName = "Eclipsis",
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
	DefaultTab = "main",
	DefaultBytecodeSourceMode = "script",
	DefaultBytecodeViewMode = "code",
	DefaultScriptPath = "",
	DefaultBytecodeFilePath = "C:\\Users\\Marin\\Downloads\\Test.txt",
	DefaultBytecodeInputFormat = "binary",
	ShowRawOpcodes = true,
	ActionHandlers = {},
}

return table.freeze(Config)
