local Components = {}

local function getOrCreate(parent, className, name)
	for _, child in ipairs(parent:GetChildren()) do
		if child.ClassName == className and (not name or child.Name == name) then
			return child
		end
	end

	local child = Instance.new(className)
	if name then
		child.Name = name
	end
	child.Parent = parent
	return child
end

local function applyProps(instance, props)
	if type(props) ~= "table" then
		return instance
	end

	for key, value in pairs(props) do
		if key ~= "Parent" and key ~= "Children" then
			instance[key] = value
		end
	end

	if props.Parent then
		instance.Parent = props.Parent
	end

	return instance
end

function Components.create(className, props)
	local instance = Instance.new(className)
	return applyProps(instance, props)
end

function Components.corner(instance, radius)
	local corner = instance:FindFirstChildOfClass("UICorner") or getOrCreate(instance, "UICorner", "SuiteCorner")
	corner.CornerRadius = UDim.new(0, radius or 18)
	return corner
end

function Components.stroke(instance, color, thickness, transparency)
	local stroke = instance:FindFirstChildOfClass("UIStroke") or getOrCreate(instance, "UIStroke", "SuiteStroke")
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = color
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency == nil and 0.9 or transparency
	return stroke
end

function Components.padding(instance, left, top, right, bottom)
	local padding = getOrCreate(instance, "UIPadding", "SuitePadding")
	padding.PaddingLeft = UDim.new(0, left or 0)
	padding.PaddingTop = UDim.new(0, top or left or 0)
	padding.PaddingRight = UDim.new(0, right or left or 0)
	padding.PaddingBottom = UDim.new(0, bottom or top or left or 0)
	return padding
end

function Components.list(instance, direction, padding)
	local layout = getOrCreate(instance, "UIListLayout", "SuiteList")
	layout.FillDirection = direction or Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding or 8)
	return layout
end

function Components.gradient(instance, theme, enabled)
	local gradient = getOrCreate(instance, "UIGradient", "SuiteGradient")
	gradient.Enabled = enabled ~= false
	gradient.Rotation = 90
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, theme.Colors.PanelRaised),
		ColorSequenceKeypoint.new(1, theme.Colors.Background),
	})
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.12),
		NumberSequenceKeypoint.new(1, 0.35),
	})
	return gradient
end

function Components.stylePanel(instance, theme, options)
	options = options or {}

	instance.BackgroundColor3 = options.background or theme.Colors.Panel
	instance.BackgroundTransparency = options.transparency == nil and theme.Transparency.Card or options.transparency
	instance.BorderSizePixel = 0

	Components.corner(instance, options.radius or theme.Radius.Card)
	Components.stroke(
		instance,
		options.stroke or theme.Colors.Stroke,
		options.strokeThickness or 1,
		options.strokeTransparency == nil and theme.Transparency.Stroke or options.strokeTransparency
	)

	if options.gradient == true then
		Components.gradient(instance, theme, true)
	elseif options.gradient == false then
		local existing = instance:FindFirstChild("SuiteGradient")
		if existing then
			existing.Enabled = false
		end
	end

	return instance
end

function Components.card(parent, theme, props)
	props = props or {}
	local card = Components.create("Frame", {
		Name = props.Name or "SuiteCard",
		BackgroundColor3 = theme.Colors.Panel,
		BorderSizePixel = 0,
		Position = props.Position or UDim2.fromOffset(0, 0),
		Size = props.Size or UDim2.fromOffset(120, 120),
		Parent = parent,
	})

	Components.stylePanel(card, theme, props.variant or theme.Variants.Card)

	if props.padding then
		Components.padding(card, props.padding, props.padding, props.padding, props.padding)
	end

	return card
end

function Components.label(parent, theme, text, props)
	props = props or {}

	return Components.create("TextLabel", {
		Name = props.Name or "SuiteLabel",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = props.Position or UDim2.fromOffset(0, 0),
		Size = props.Size or UDim2.fromOffset(160, 22),
		Font = props.Font or theme.Font.Body,
		Text = text or "",
		TextSize = props.TextSize or theme.TextSize.Body,
		TextColor3 = props.TextColor3 or theme.Colors.Text,
		TextTransparency = props.TextTransparency or 0,
		TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left,
		TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center,
		TextWrapped = props.TextWrapped == true,
		Parent = parent,
	})
end

function Components.pill(parent, theme, text, props)
	props = props or {}

	local pill = Components.create("TextLabel", {
		Name = props.Name or "SuitePill",
		BackgroundColor3 = props.BackgroundColor3 or theme.Colors.Surface,
		BackgroundTransparency = props.BackgroundTransparency == nil and 0.08 or props.BackgroundTransparency,
		BorderSizePixel = 0,
		Position = props.Position or UDim2.fromOffset(0, 0),
		Size = props.Size or UDim2.fromOffset(72, 28),
		Font = props.Font or theme.Font.Body,
		Text = text or "",
		TextSize = props.TextSize or theme.TextSize.Small,
		TextColor3 = props.TextColor3 or theme.Colors.TextMuted,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Parent = parent,
	})

	Components.corner(pill, theme.Radius.Pill)
	Components.stroke(pill, theme.Colors.Stroke, 1, theme.Transparency.Stroke)

	return pill
end

function Components.styleButton(button, theme, selected)
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.BackgroundColor3 = selected and theme.Colors.SurfaceActive or theme.Colors.Surface
	button.BackgroundTransparency = selected and 0.02 or 0.16
	button.TextColor3 = selected and theme.Colors.Text or theme.Colors.TextMuted
	Components.corner(button, theme.Radius.Control)
	Components.stroke(button, theme.Colors.Stroke, 1, selected and 0.84 or 0.92)
	return button
end

function Components.decorateScroll(scroll, theme, options)
	options = options or {}
	scroll.BackgroundColor3 = options.background or theme.Colors.Background
	scroll.BackgroundTransparency = options.transparency == nil and 0.08 or options.transparency
	scroll.BorderSizePixel = 0
	scroll.ScrollBarImageColor3 = theme.Colors.TextFaint
	Components.corner(scroll, options.radius or theme.Radius.Control)
	Components.stroke(scroll, theme.Colors.Stroke, 1, options.strokeTransparency or theme.Transparency.Stroke)
	return scroll
end

return Components
