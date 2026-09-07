--!strict
--[[
	UiKit — the visual language, as constructors.

	Every panel, bar, button and label in the game is built from these, so the UI
	is consistent by construction rather than by discipline. Changing the corner
	radius or the body font is a one-line edit here.

	THE RULES THIS ENCODES
	  - Dark, low-saturation ground; colour is reserved for meaning. A coloured
	    element is telling you something (rarity, element, danger), never
	    decorating.
	  - Text has a stroke or a backing. HUD text sits over gameplay and has to stay
	    readable against a white shockwave and a black floor in the same second.
	  - Nothing in the HUD is centred on the screen except things that demand
	    attention. The middle of the screen belongs to the fight.
	  - Every interactive element has a hover state and a keyboard/gamepad focus
	    state. Console players exist.
]]

local TweenService = game:GetService("TweenService")

local UiKit = {}

--------------------------------------------------------------------------------
-- Palette
--------------------------------------------------------------------------------

UiKit.Colors = {
	-- Ground.
	Void = Color3.fromRGB(10, 10, 13),
	Panel = Color3.fromRGB(20, 20, 25),
	PanelRaised = Color3.fromRGB(30, 30, 37),
	Stroke = Color3.fromRGB(58, 58, 70),
	StrokeBright = Color3.fromRGB(96, 96, 112),

	-- Text.
	Text = Color3.fromRGB(236, 234, 230),
	TextDim = Color3.fromRGB(158, 156, 152),
	TextFaint = Color3.fromRGB(104, 102, 100),

	-- Meaning.
	Health = Color3.fromRGB(214, 62, 84),
	HealthLost = Color3.fromRGB(112, 34, 46),
	Stamina = Color3.fromRGB(196, 248, 226),
	Ultimate = Color3.fromRGB(255, 200, 110),
	Ability = Color3.fromRGB(126, 205, 255),
	Danger = Color3.fromRGB(255, 82, 68),
	Good = Color3.fromRGB(120, 255, 170),
	Accent = Color3.fromRGB(255, 186, 74),
}

UiKit.Fonts = {
	Display = Enum.Font.GothamBlack,
	Heading = Enum.Font.GothamBold,
	Body = Enum.Font.Gotham,
	Mono = Enum.Font.Code,
}

local QUICK = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SMOOTH = TweenInfo.new(0.28, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)

UiKit.Tween = { Quick = QUICK, Smooth = SMOOTH }

--------------------------------------------------------------------------------
-- Primitives
--------------------------------------------------------------------------------

local function applyCommon(instance: GuiObject, props: any)
	for key, value in props do
		if key ~= "Parent" and key ~= "Children" then
			(instance :: any)[key] = value
		end
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
end

function UiKit.Frame(props: any): Frame
	local frame = Instance.new("Frame")
	frame.BackgroundColor3 = UiKit.Colors.Panel
	frame.BorderSizePixel = 0
	applyCommon(frame, props)
	return frame
end

--- A panel: rounded, stroked, with padding. The default container for everything.
function UiKit.Panel(props: any): Frame
	local frame = UiKit.Frame(props)
	frame.BackgroundColor3 = props.BackgroundColor3 or UiKit.Colors.Panel
	frame.BackgroundTransparency = props.BackgroundTransparency or 0.08

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, props.CornerRadius or 8)
	corner.Parent = frame

	local stroke = Instance.new("UIStroke")
	stroke.Color = props.StrokeColor or UiKit.Colors.Stroke
	stroke.Thickness = 1
	stroke.Transparency = 0.2
	stroke.Parent = frame

	if props.Padding then
		local padding = Instance.new("UIPadding")
		local amount = UDim.new(0, props.Padding)
		padding.PaddingTop = amount
		padding.PaddingBottom = amount
		padding.PaddingLeft = amount
		padding.PaddingRight = amount
		padding.Parent = frame
	end

	return frame
end

function UiKit.Label(props: any): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = props.Font or UiKit.Fonts.Body
	label.TextColor3 = props.TextColor3 or UiKit.Colors.Text
	label.TextSize = props.TextSize or 16
	label.TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Left
	label.TextYAlignment = props.TextYAlignment or Enum.TextYAlignment.Center
	label.RichText = true
	-- HUD text sits over gameplay; a stroke keeps it readable on any background.
	label.TextStrokeTransparency = props.TextStrokeTransparency or 0.6
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	applyCommon(label, props)
	return label
end

function UiKit.Heading(text: string, props: any): TextLabel
	local merged = props or {}
	merged.Text = text
	merged.Font = UiKit.Fonts.Display
	merged.TextSize = merged.TextSize or 24
	return UiKit.Label(merged)
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

export type Bar = {
	root: Frame,
	fill: Frame,
	ghost: Frame,
	label: TextLabel?,
	SetValue: (Bar, number, number) -> (),
}

--[[
	A resource bar with a lag layer.

	The `ghost` sits behind the fill and catches up slowly. On health it shows how
	much you just lost, which is the difference between "I am at 40%" and "I just
	took a huge hit". It is a small thing and it does more for combat readability
	than any number on the screen.
]]
function UiKit.Bar(props: any): Bar
	local root = UiKit.Frame({
		Size = props.Size,
		Position = props.Position,
		AnchorPoint = props.AnchorPoint,
		BackgroundColor3 = UiKit.Colors.Void,
		BackgroundTransparency = 0.25,
		Parent = props.Parent,
	})

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, props.CornerRadius or 4)
	corner.Parent = root

	local stroke = Instance.new("UIStroke")
	stroke.Color = UiKit.Colors.Stroke
	stroke.Thickness = 1
	stroke.Transparency = 0.4
	stroke.Parent = root

	local ghost = UiKit.Frame({
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = props.GhostColor or UiKit.Colors.HealthLost,
		Parent = root,
	})
	local ghostCorner = corner:Clone()
	ghostCorner.Parent = ghost

	local fill = UiKit.Frame({
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = props.Color or UiKit.Colors.Health,
		Parent = root,
	})
	local fillCorner = corner:Clone()
	fillCorner.Parent = fill

	local label: TextLabel? = nil
	if props.ShowText then
		label = UiKit.Label({
			Size = UDim2.fromScale(1, 1),
			Text = "",
			TextSize = props.TextSize or 13,
			Font = UiKit.Fonts.Heading,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextStrokeTransparency = 0.3,
			Parent = root,
		})
	end

	local bar: any = { root = root, fill = fill, ghost = ghost, label = label }
	local ghostTween: Tween? = nil

	function bar:SetValue(current: number, maximum: number)
		local fraction = math.clamp(if maximum > 0 then current / maximum else 0, 0, 1)
		fill.Size = UDim2.fromScale(fraction, 1)

		if ghostTween then
			ghostTween:Cancel()
		end
		-- The ghost only lags on the way down. Gaining resource should read
		-- instantly; losing it should be visible for a moment.
		if ghost.Size.X.Scale < fraction then
			ghost.Size = UDim2.fromScale(fraction, 1)
		else
			ghostTween = TweenService:Create(
				ghost,
				TweenInfo.new(0.45, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
				{ Size = UDim2.fromScale(fraction, 1) }
			)
			ghostTween:Play()
		end

		if label then
			label.Text = ("%d / %d"):format(math.ceil(current), math.ceil(maximum))
		end
	end

	return bar
end

--------------------------------------------------------------------------------
-- Buttons
--------------------------------------------------------------------------------

function UiKit.Button(props: any): TextButton
	local button = Instance.new("TextButton")
	button.BackgroundColor3 = props.BackgroundColor3 or UiKit.Colors.PanelRaised
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Font = props.Font or UiKit.Fonts.Heading
	button.TextColor3 = props.TextColor3 or UiKit.Colors.Text
	button.TextSize = props.TextSize or 16
	button.Text = props.Text or ""
	applyCommon(button, props)

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, props.CornerRadius or 6)
	corner.Parent = button

	local stroke = Instance.new("UIStroke")
	stroke.Color = props.StrokeColor or UiKit.Colors.Stroke
	stroke.Thickness = 1
	stroke.Transparency = 0.15
	stroke.Parent = button

	local baseColor = button.BackgroundColor3
	local hoverColor = props.HoverColor or baseColor:Lerp(Color3.new(1, 1, 1), 0.12)

	button.MouseEnter:Connect(function()
		TweenService:Create(button, QUICK, { BackgroundColor3 = hoverColor }):Play()
		TweenService:Create(stroke, QUICK, { Color = UiKit.Colors.StrokeBright }):Play()
	end)
	button.MouseLeave:Connect(function()
		TweenService:Create(button, QUICK, { BackgroundColor3 = baseColor }):Play()
		TweenService:Create(stroke, QUICK, { Color = props.StrokeColor or UiKit.Colors.Stroke }):Play()
	end)
	-- Gamepad and keyboard focus get the same treatment as the mouse.
	button.SelectionGained:Connect(function()
		TweenService:Create(button, QUICK, { BackgroundColor3 = hoverColor }):Play()
		TweenService:Create(stroke, QUICK, { Color = UiKit.Colors.Accent, Thickness = 2 }):Play()
	end)
	button.SelectionLost:Connect(function()
		TweenService:Create(button, QUICK, { BackgroundColor3 = baseColor }):Play()
		TweenService:Create(stroke, QUICK, { Color = props.StrokeColor or UiKit.Colors.Stroke, Thickness = 1 }):Play()
	end)

	return button
end

--------------------------------------------------------------------------------
-- Layout helpers
--------------------------------------------------------------------------------

function UiKit.VList(parent: Instance, padding: number?, alignment: Enum.HorizontalAlignment?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding or 8)
	layout.HorizontalAlignment = alignment or Enum.HorizontalAlignment.Left
	layout.Parent = parent
	return layout
end

function UiKit.HList(parent: Instance, padding: number?, alignment: Enum.VerticalAlignment?): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, padding or 8)
	layout.VerticalAlignment = alignment or Enum.VerticalAlignment.Center
	layout.Parent = parent
	return layout
end

--------------------------------------------------------------------------------
-- Motion
--------------------------------------------------------------------------------

--- Fades a whole subtree in or out. Used for every panel transition, so nothing
--- in the game ever pops into existence.
function UiKit.FadeSubtree(root: GuiObject, visible: boolean, duration: number?)
	local info = TweenInfo.new(duration or 0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	local function fade(instance: Instance, baseTransparency: number?)
		if instance:IsA("Frame") or instance:IsA("TextButton") or instance:IsA("ImageLabel") then
			local target = if visible then (baseTransparency or 0) else 1
			TweenService:Create(instance, info, { BackgroundTransparency = target }):Play()
		end
		if instance:IsA("TextLabel") or instance:IsA("TextButton") then
			TweenService:Create(instance, info, { TextTransparency = if visible then 0 else 1 }):Play()
		end
		if instance:IsA("UIStroke") then
			TweenService:Create(instance, info, { Transparency = if visible then 0.2 else 1 }):Play()
		end
	end

	fade(root)
	for _, descendant in root:GetDescendants() do
		fade(descendant)
	end
end

--- Attention pop: a quick scale punch. Used for a Legendary Grace, a level-up,
--- a synergy. Deliberately rare; if everything pops, nothing does.
function UiKit.Pop(element: GuiObject, magnitude: number?)
	local scale = element:FindFirstChildOfClass("UIScale")
	if not scale then
		scale = Instance.new("UIScale")
		scale.Parent = element
	end
	scale.Scale = 1 + (magnitude or 0.12)
	TweenService:Create(scale, TweenInfo.new(0.32, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
end

function UiKit.Init() end

return UiKit
