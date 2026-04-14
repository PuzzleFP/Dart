local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local NativeUi = {}

NativeUi.Theme = {
	Background = Color3.fromRGB(11, 12, 15),
	Panel = Color3.fromRGB(17, 19, 22),
	PanelAlt = Color3.fromRGB(21, 23, 27),
	Surface = Color3.fromRGB(26, 29, 33),
	SurfaceHover = Color3.fromRGB(31, 34, 39),
	SurfaceActive = Color3.fromRGB(37, 41, 47),
	Accent = Color3.fromRGB(110, 177, 135),
	AccentHover = Color3.fromRGB(124, 191, 148),
	AccentActive = Color3.fromRGB(95, 158, 117),
	Text = Color3.fromRGB(237, 240, 244),
	TextMuted = Color3.fromRGB(171, 177, 186),
	TextDim = Color3.fromRGB(113, 120, 129),
	Border = Color3.fromRGB(40, 44, 50),
	Success = Color3.fromRGB(132, 203, 156),
	Error = Color3.fromRGB(223, 101, 101),
	Shadow = Color3.fromRGB(2, 3, 6),
}

local buttonRefreshers = setmetatable({}, { __mode = "k" })
local buttonTweens = setmetatable({}, { __mode = "k" })
local activeTweens = setmetatable({}, { __mode = "k" })

function NativeUi.create(className, properties)
	local instance = Instance.new(className)

	for key, value in pairs(properties or {}) do
		if key ~= "Parent" then
			instance[key] = value
		end
	end

	instance.Parent = properties and properties.Parent or nil
	return instance
end

function NativeUi.corner(parent, radius)
	return NativeUi.create("UICorner", {
		CornerRadius = UDim.new(0, radius or 8),
		Parent = parent,
	})
end

function NativeUi.stroke(parent, color, thickness, transparency)
	return NativeUi.create("UIStroke", {
		Color = color or NativeUi.Theme.Border,
		Thickness = thickness or 1,
		Transparency = transparency or 0,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Parent = parent,
	})
end

function NativeUi.padding(parent, x, y)
	return NativeUi.create("UIPadding", {
		PaddingLeft = UDim.new(0, x or 0),
		PaddingRight = UDim.new(0, x or 0),
		PaddingTop = UDim.new(0, y or x or 0),
		PaddingBottom = UDim.new(0, y or x or 0),
		Parent = parent,
	})
end

function NativeUi.list(parent, padding, fillDirection)
	return NativeUi.create("UIListLayout", {
		SortOrder = Enum.SortOrder.LayoutOrder,
		Padding = UDim.new(0, padding or 0),
		FillDirection = fillDirection or Enum.FillDirection.Vertical,
		Parent = parent,
	})
end

function NativeUi.clear(parent)
	for _, child in ipairs(parent:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

function NativeUi.makePanel(parent, properties)
	local panel = NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Panel,
		BorderSizePixel = 0,
		Parent = parent,
	})

	for key, value in pairs(properties or {}) do
		if key ~= "CornerRadius" then
			panel[key] = value
		end
	end

	NativeUi.corner(panel, properties and properties.CornerRadius or 10)
	NativeUi.stroke(panel, NativeUi.Theme.Border, 1, 0.2)
	return panel
end

function NativeUi.makeLabel(parent, text, properties)
	local label = NativeUi.create("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = Enum.Font.Gotham,
		Text = text or "",
		TextColor3 = NativeUi.Theme.Text,
		TextSize = 14,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, 20),
		Parent = parent,
	})

	for key, value in pairs(properties or {}) do
		label[key] = value
	end

	return label
end

function NativeUi.makeCodeLabel(parent, text, properties)
	local label = NativeUi.makeLabel(parent, text, {
		Font = Enum.Font.Code,
		TextSize = 13,
		TextColor3 = NativeUi.Theme.Text,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
	})

	for key, value in pairs(properties or {}) do
		label[key] = value
	end

	return label
end

local function defaultButtonPalette()
	return {
		Base = NativeUi.Theme.Surface,
		Hover = NativeUi.Theme.SurfaceHover,
		Pressed = NativeUi.Theme.SurfaceActive,
		Selected = NativeUi.Theme.SurfaceActive,
		Disabled = Color3.fromRGB(17, 20, 26),
		Text = NativeUi.Theme.Text,
		SelectedText = NativeUi.Theme.Text,
		DisabledText = NativeUi.Theme.TextDim,
	}
end

function NativeUi.tween(instance, duration, properties)
	if instance == nil or properties == nil then
		return nil
	end

	local existingTween = activeTweens[instance]
	if existingTween ~= nil then
		existingTween:Cancel()
	end

	local tween = TweenService:Create(instance, TweenInfo.new(duration or 0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), properties)
	activeTweens[instance] = tween
	tween:Play()
	return tween
end

local function refreshButtonVisual(button)
	local palette = buttonRefreshers[button]
	if palette == nil then
		return
	end

	local backgroundColor
	local textColor

	if button:GetAttribute("Pressed") then
		backgroundColor = palette.Pressed
		textColor = palette.Text
	elseif button:GetAttribute("Disabled") then
		backgroundColor = palette.Disabled or NativeUi.Theme.PanelAlt
		textColor = palette.DisabledText or NativeUi.Theme.TextDim
	elseif button:GetAttribute("Selected") then
		backgroundColor = palette.Selected
		textColor = palette.SelectedText
	elseif button:GetAttribute("Hovered") then
		backgroundColor = palette.Hover
		textColor = palette.Text
	else
		backgroundColor = palette.Base
		textColor = palette.Text
	end

	if button.BackgroundColor3 == backgroundColor and button.TextColor3 == textColor then
		return
	end

	local existingTween = buttonTweens[button]
	if existingTween ~= nil then
		existingTween:Cancel()
	end

	local tween = TweenService:Create(button, TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundColor3 = backgroundColor,
		TextColor3 = textColor,
	})
	buttonTweens[button] = tween
	tween:Play()
end

function NativeUi.bindButtonStyle(button, palette)
	local resolved = palette or defaultButtonPalette()
	button.AutoButtonColor = false
	button:SetAttribute("Hovered", false)
	button:SetAttribute("Pressed", false)
	button:SetAttribute("Selected", false)
	button:SetAttribute("Disabled", false)
	buttonRefreshers[button] = resolved

	button.MouseEnter:Connect(function()
		button:SetAttribute("Hovered", true)
		refreshButtonVisual(button)
	end)

	button.MouseLeave:Connect(function()
		button:SetAttribute("Hovered", false)
		button:SetAttribute("Pressed", false)
		refreshButtonVisual(button)
	end)

	button.MouseButton1Down:Connect(function()
		button:SetAttribute("Pressed", true)
		refreshButtonVisual(button)
	end)

	button.MouseButton1Up:Connect(function()
		button:SetAttribute("Pressed", false)
		refreshButtonVisual(button)
	end)

	refreshButtonVisual(button)
end

function NativeUi.setButtonSelected(button, selected)
	button:SetAttribute("Selected", selected == true)
	refreshButtonVisual(button)
end

function NativeUi.setButtonDisabled(button, disabled)
	button:SetAttribute("Disabled", disabled == true)
	button.Active = disabled ~= true
	refreshButtonVisual(button)
end

function NativeUi.makeButton(parent, text, properties)
	local button = NativeUi.create("TextButton", {
		BackgroundColor3 = NativeUi.Theme.Surface,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamSemibold,
		Text = text or "Button",
		TextColor3 = NativeUi.Theme.Text,
		TextSize = 13,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(0, 84, 0, 28),
		Parent = parent,
	})

	for key, value in pairs(properties or {}) do
		if key ~= "CornerRadius" and key ~= "Palette" then
			button[key] = value
		end
	end

	NativeUi.corner(button, properties and properties.CornerRadius or 10)
	NativeUi.stroke(button, NativeUi.Theme.Border, 1, 0.18)
	NativeUi.bindButtonStyle(button, properties and properties.Palette or nil)
	return button
end

function NativeUi.makeTextBox(parent, text, properties)
	local box = NativeUi.create("TextBox", {
		BackgroundColor3 = NativeUi.Theme.Surface,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		Font = Enum.Font.Code,
		PlaceholderColor3 = NativeUi.Theme.TextDim,
		Text = text or "",
		TextColor3 = NativeUi.Theme.Text,
		TextSize = 13,
		TextWrapped = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		Size = UDim2.new(1, 0, 0, 30),
		Parent = parent,
	})

	for key, value in pairs(properties or {}) do
		if key ~= "CornerRadius" then
			box[key] = value
		end
	end

	NativeUi.corner(box, properties and properties.CornerRadius or 10)
	NativeUi.stroke(box, NativeUi.Theme.Border, 1, 0.18)
	NativeUi.padding(box, 10, 8)
	return box
end

function NativeUi.makeDivider(parent)
	return NativeUi.create("Frame", {
		BackgroundColor3 = NativeUi.Theme.Border,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 1),
		Parent = parent,
	})
end

function NativeUi.makeRow(parent, height, properties)
	local row = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, height or 30),
		Parent = parent,
	})

	for key, value in pairs(properties or {}) do
		row[key] = value
	end

	return row
end

function NativeUi.makeScrollList(parent, properties)
	properties = properties or {}

	local scroll = NativeUi.create("ScrollingFrame", {
		Active = true,
		AutomaticCanvasSize = Enum.AutomaticSize.None,
		BackgroundColor3 = properties.BackgroundColor3 or NativeUi.Theme.PanelAlt,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromOffset(0, 0),
		ScrollBarImageColor3 = NativeUi.Theme.TextDim,
		ScrollBarThickness = properties.ScrollBarThickness or 6,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Size = properties.Size or UDim2.new(1, 0, 1, 0),
		TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
		BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png",
		Parent = parent,
	})

	for key, value in pairs(properties) do
		if key ~= "Padding" and key ~= "ContentPadding" and key ~= "ScrollBarThickness" and key ~= "CornerRadius" then
			scroll[key] = value
		end
	end

	NativeUi.corner(scroll, properties.CornerRadius or 10)
	NativeUi.stroke(scroll, NativeUi.Theme.Border, 1, 0.18)

	local content = NativeUi.create("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(0, 0),
		Size = UDim2.new(1, -8, 0, 0),
		Parent = scroll,
	})

	local contentPadding = properties.ContentPadding or 8
	NativeUi.padding(content, contentPadding, contentPadding)
	local layout = NativeUi.list(content, properties.Padding or 6, Enum.FillDirection.Vertical)

	local function updateCanvas()
		local height = layout.AbsoluteContentSize.Y + contentPadding * 2
		content.Size = UDim2.new(1, -8, 0, height)
		scroll.CanvasSize = UDim2.fromOffset(0, height)
	end

	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvas)
	updateCanvas()

	return scroll, content, layout
end

function NativeUi.makeDraggable(dragHandle, target)
	local dragging = false
	local dragStart
	local targetStart

	local function update(input)
		local delta = input.Position - dragStart
		target.Position = UDim2.new(
			targetStart.X.Scale,
			targetStart.X.Offset + delta.X,
			targetStart.Y.Scale,
			targetStart.Y.Offset + delta.Y
		)
	end

	dragHandle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		dragging = true
		dragStart = input.Position
		targetStart = target.Position

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				dragging = false
			end
		end)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		update(input)
	end)
end

function NativeUi.makeResizable(resizeHandle, target, options)
	options = options or {}

	local resizing = false
	local dragStart
	local sizeStart
	local minSize = options.MinSize or Vector2.new(720, 480)
	local maxSize = options.MaxSize

	local function clampSize(size)
		local width = math.max(minSize.X, size.X)
		local height = math.max(minSize.Y, size.Y)

		if maxSize ~= nil then
			width = math.min(width, maxSize.X)
			height = math.min(height, maxSize.Y)
		end

		return Vector2.new(width, height)
	end

	local function update(input)
		local delta = input.Position - dragStart
		local nextSize = clampSize(Vector2.new(
			sizeStart.X + delta.X,
			sizeStart.Y + delta.Y
		))

		target.Size = UDim2.new(
			target.Size.X.Scale,
			nextSize.X,
			target.Size.Y.Scale,
			nextSize.Y
		)
	end

	resizeHandle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		resizing = true
		dragStart = input.Position
		sizeStart = Vector2.new(target.AbsoluteSize.X, target.AbsoluteSize.Y)

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				resizing = false
			end
		end)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not resizing then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		update(input)
	end)
end

function NativeUi.bindResizeHandle(handle, target, options)
	options = options or {}

	local edge = options.Edge or "right"
	local resizing = false
	local dragStart
	local sizeStart
	local positionStart
	local minSize = options.MinSize or Vector2.new(720, 480)
	local maxSize = options.MaxSize

	local function clamp(width, height)
		local clampedWidth = math.max(minSize.X, width)
		local clampedHeight = math.max(minSize.Y, height)

		if maxSize ~= nil then
			clampedWidth = math.min(clampedWidth, maxSize.X)
			clampedHeight = math.min(clampedHeight, maxSize.Y)
		end

		return clampedWidth, clampedHeight
	end

	local function update(input)
		local delta = input.Position - dragStart
		local width = sizeStart.X
		local height = sizeStart.Y
		local posX = positionStart.X.Offset
		local posY = positionStart.Y.Offset

		if string.find(string.lower(edge), "right", 1, true) ~= nil then
			width = width + delta.X
		end

		if string.find(string.lower(edge), "left", 1, true) ~= nil then
			width = width - delta.X
		end

		if string.find(string.lower(edge), "bottom", 1, true) ~= nil then
			height = height + delta.Y
		end

		if string.find(string.lower(edge), "top", 1, true) ~= nil then
			height = height - delta.Y
		end

		local clampedWidth, clampedHeight = clamp(width, height)
		local widthDelta = sizeStart.X - clampedWidth
		local heightDelta = sizeStart.Y - clampedHeight

		if string.find(string.lower(edge), "left", 1, true) ~= nil then
			posX = positionStart.X.Offset + widthDelta
		end

		if string.find(string.lower(edge), "top", 1, true) ~= nil then
			posY = positionStart.Y.Offset + heightDelta
		end

		target.Position = UDim2.new(
			positionStart.X.Scale,
			posX,
			positionStart.Y.Scale,
			posY
		)
		target.Size = UDim2.new(
			target.Size.X.Scale,
			clampedWidth,
			target.Size.Y.Scale,
			clampedHeight
		)
	end

	handle.InputBegan:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1 and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		resizing = true
		dragStart = input.Position
		sizeStart = Vector2.new(target.AbsoluteSize.X, target.AbsoluteSize.Y)
		positionStart = target.Position

		input.Changed:Connect(function()
			if input.UserInputState == Enum.UserInputState.End then
				resizing = false
			end
		end)
	end)

	UserInputService.InputChanged:Connect(function(input)
		if not resizing then
			return
		end

		if input.UserInputType ~= Enum.UserInputType.MouseMovement and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		update(input)
	end)
end

return NativeUi
