local Theme = {}

Theme.Colors = {
	Background = Color3.fromRGB(4, 4, 5),
	Shell = Color3.fromRGB(9, 9, 10),
	ShellRaised = Color3.fromRGB(13, 13, 15),
	Panel = Color3.fromRGB(15, 15, 16),
	PanelRaised = Color3.fromRGB(21, 21, 23),
	Surface = Color3.fromRGB(26, 26, 28),
	SurfaceHover = Color3.fromRGB(34, 34, 37),
	SurfaceActive = Color3.fromRGB(43, 43, 47),
	Stroke = Color3.fromRGB(255, 255, 255),
	NativeStroke = Color3.fromRGB(42, 42, 45),
	StrokeSoft = Color3.fromRGB(92, 92, 96),
	Text = Color3.fromRGB(242, 242, 244),
	TextMuted = Color3.fromRGB(194, 194, 199),
	TextDim = Color3.fromRGB(142, 142, 150),
	TextFaint = Color3.fromRGB(100, 100, 108),
	Success = Color3.fromRGB(51, 175, 120),
	Info = Color3.fromRGB(142, 157, 182),
	Warning = Color3.fromRGB(224, 184, 48),
	Critical = Color3.fromRGB(221, 78, 92),
	Code = Color3.fromRGB(3, 3, 3),
}

Theme.Radius = {
	Shell = 24,
	Sidebar = 22,
	Card = 12,
	CardLarge = 16,
	Control = 12,
	Pill = 999,
	Island = 24,
}

Theme.Transparency = {
	Shell = 0,
	Sidebar = 0,
	Card = 0,
	CardSoft = 0,
	Control = 0,
	Code = 0,
	Stroke = 0.88,
	StrokeStrong = 0.80,
	StrokeSoft = 0.92,
}

Theme.Font = {
	Title = Enum.Font.GothamBold,
	Body = Enum.Font.GothamMedium,
	Mono = Enum.Font.Code,
}

Theme.TextSize = {
	Kicker = 11,
	Body = 13,
	Small = 12,
	Title = 18,
	Section = 14,
	Mono = 13,
}

Theme.Variants = {
	Shell = {
		background = Theme.Colors.Shell,
		transparency = Theme.Transparency.Shell,
		radius = Theme.Radius.Shell,
		stroke = Theme.Colors.Stroke,
		strokeTransparency = Theme.Transparency.Stroke,
		gradient = true,
	},
	Sidebar = {
		background = Theme.Colors.Shell,
		transparency = Theme.Transparency.Sidebar,
		radius = Theme.Radius.Sidebar,
		stroke = Theme.Colors.Stroke,
		strokeTransparency = Theme.Transparency.Stroke,
		gradient = true,
	},
	Card = {
		background = Theme.Colors.Panel,
		transparency = Theme.Transparency.Card,
		radius = Theme.Radius.Card,
		stroke = Theme.Colors.Stroke,
		strokeTransparency = Theme.Transparency.StrokeStrong,
		gradient = true,
	},
	CardSoft = {
		background = Theme.Colors.Panel,
		transparency = Theme.Transparency.CardSoft,
		radius = Theme.Radius.Card,
		stroke = Theme.Colors.Stroke,
		strokeTransparency = Theme.Transparency.Stroke,
		gradient = true,
	},
	Code = {
		background = Theme.Colors.Code,
		transparency = Theme.Transparency.Code,
		radius = Theme.Radius.Card,
		stroke = Theme.Colors.Stroke,
		strokeTransparency = Theme.Transparency.StrokeStrong,
		gradient = false,
	},
	Island = {
		background = Theme.Colors.ShellRaised,
		transparency = 0,
		radius = Theme.Radius.Island,
		stroke = Theme.Colors.Stroke,
		strokeTransparency = Theme.Transparency.StrokeStrong,
		gradient = true,
	},
	Control = {
		background = Theme.Colors.Surface,
		transparency = Theme.Transparency.Control,
		radius = Theme.Radius.Control,
		stroke = Theme.Colors.Stroke,
		strokeTransparency = Theme.Transparency.Stroke,
		gradient = false,
	},
}

function Theme.applyToNativeUi(NativeUi)
	if type(NativeUi) ~= "table" or type(NativeUi.Theme) ~= "table" then
		return
	end

	local colors = Theme.Colors
	local target = NativeUi.Theme

	target.Background = colors.Background
	target.Shell = colors.Shell
	target.Panel = colors.Panel
	target.Surface = colors.Surface
	target.SurfaceHover = colors.SurfaceHover
	target.SurfaceActive = colors.SurfaceActive
	target.Overlay = colors.ShellRaised
	target.Border = colors.NativeStroke
	target.Accent = colors.SurfaceActive
	target.AccentSoft = colors.Surface
	target.Text = colors.Text
	target.TextMuted = colors.TextMuted
	target.TextDim = colors.TextDim
	target.Success = colors.Success
	target.Info = colors.Info
	target.Warning = colors.Warning
	target.Critical = colors.Critical
	target.Error = colors.Critical
end

return Theme
