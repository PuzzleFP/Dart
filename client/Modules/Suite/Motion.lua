local TweenService = game:GetService("TweenService")

local Motion = {}

local activeTweens = setmetatable({}, { __mode = "k" })

local function easingStyle(name)
	if name == "back" then
		return Enum.EasingStyle.Back
	elseif name == "quad" then
		return Enum.EasingStyle.Quad
	elseif name == "sine" then
		return Enum.EasingStyle.Sine
	elseif name == "linear" then
		return Enum.EasingStyle.Linear
	end

	return Enum.EasingStyle.Quint
end

function Motion.tween(instance, goal, options)
	if not instance or type(goal) ~= "table" then
		return nil
	end

	options = options or {}

	local previous = activeTweens[instance]
	if previous then
		previous:Cancel()
	end

	local tween = TweenService:Create(
		instance,
		TweenInfo.new(
			options.duration or 0.18,
			easingStyle(options.style),
			options.direction or Enum.EasingDirection.Out
		),
		goal
	)

	activeTweens[instance] = tween
	tween.Completed:Connect(function()
		if activeTweens[instance] == tween then
			activeTweens[instance] = nil
		end
	end)
	tween:Play()

	return tween
end

function Motion.press(instance)
	return Motion.tween(instance, {
		BackgroundTransparency = math.max(0, (instance.BackgroundTransparency or 0) - 0.08),
	}, {
		duration = 0.10,
		style = "quad",
	})
end

function Motion.release(instance, transparency)
	return Motion.tween(instance, {
		BackgroundTransparency = transparency or instance.BackgroundTransparency,
	}, {
		duration = 0.16,
		style = "quad",
	})
end

return Motion
