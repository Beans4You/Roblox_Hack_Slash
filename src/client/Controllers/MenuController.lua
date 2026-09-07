--!strict
--[[
	MenuController — every screen that is not the HUD.

	One overlay, one screen at a time, one signal telling everybody else whether
	input is currently being eaten. Screens are built on demand and torn down when
	closed rather than kept hidden: the hub menus are large, they are opened rarely,
	and rebuilding one takes a few milliseconds nobody will ever notice.

	WHAT LIVES HERE
	  Grace offer      the three-card shrine choice
	  Synergy          the announcement when two Graces fuse
	  Dialogue         NPC lines, boss lines, and event choices
	  Expedition       weapon / region / heat, at the gate
	  Smith, Mystic, Keeper, Wardrobe, Mastery, Settings
	  Run summary      the screen you see when a run ends

	THE GRACE OFFER IS THE MOST IMPORTANT SCREEN IN THE GAME
	It is the moment a run becomes a build. So it gets the whole screen, the cards
	are large, the rarity is unmissable, and the Faded who is offering says
	something. A reroll is one button and costs nothing to look at.

	THE RUN SUMMARY LEADS WITH GAINS
	The brief asks for death to read as progression. So the summary opens on what
	you keep -- Sable, mastery, unlocks -- and puts how far you got underneath. The
	word "DIED" does not appear on it.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local GuiService = game:GetService("GuiService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local GameConfig = require(Shared.Config.GameConfig)
local Lore = require(Shared.Config.Lore)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local RelicConfig = require(Shared.Config.RelicConfig)
local CosmeticConfig = require(Shared.Config.CosmeticConfig)
local MasteryConfig = require(Shared.Config.MasteryConfig)
local Signal = require(Shared.Util.Signal)
local Net = require(Shared.Net.Net)

local MenuController = {}

MenuController.MenuVisibilityChanged = Signal.new()

local registry: any = nil
local player = Players.LocalPlayer
local UiKit: any

local overlay: Frame
local currentScreen: GuiObject? = nil
local currentScreenName: string? = nil
local profile: any = nil
local dialogueState: any = nil

--------------------------------------------------------------------------------
-- Screen plumbing
--------------------------------------------------------------------------------

local function closeScreen()
	if currentScreen then
		local closing = currentScreen
		UiKit.FadeSubtree(closing, false, 0.14)
		task.delay(0.16, function()
			closing:Destroy()
		end)
	end
	currentScreen = nil
	currentScreenName = nil
	overlay.Visible = false
	MenuController.MenuVisibilityChanged:Fire(false)
	registry.AudioController.PlayLocal("UiClose")
end

local function openScreen(name: string, builder: (Frame) -> GuiObject)
	if currentScreen then
		currentScreen:Destroy()
	end

	overlay.Visible = true
	currentScreenName = name
	currentScreen = builder(overlay)
	if currentScreen then
		UiKit.FadeSubtree(currentScreen, true, 0.18)
	end

	MenuController.MenuVisibilityChanged:Fire(true)
	registry.AudioController.PlayLocal("UiOpen")
end

function MenuController.IsBlockingInput(): boolean
	return currentScreen ~= nil
end

function MenuController.Close()
	closeScreen()
end

--------------------------------------------------------------------------------
-- Shared pieces
--------------------------------------------------------------------------------

local function panel(parent: Instance, size: UDim2, title: string?): (Frame, Frame)
	local root = UiKit.Panel({
		Size = size,
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = UiKit.Colors.Panel,
		BackgroundTransparency = 0.02,
		Padding = 22,
		CornerRadius = 12,
		Parent = parent,
	})

	local body = UiKit.Frame({
		Size = if title then UDim2.new(1, 0, 1, -52) else UDim2.fromScale(1, 1),
		Position = if title then UDim2.fromOffset(0, 52) else UDim2.fromOffset(0, 0),
		BackgroundTransparency = 1,
		Parent = root,
	})

	if title then
		UiKit.Heading(title, {
			Size = UDim2.new(1, 0, 0, 30),
			TextSize = 26,
			Parent = root,
		})
		UiKit.Frame({
			Size = UDim2.new(1, 0, 0, 1),
			Position = UDim2.fromOffset(0, 40),
			BackgroundColor3 = UiKit.Colors.Stroke,
			Parent = root,
		})
	end

	return root, body
end

local function closeButton(parent: Instance, onClose: (() -> ())?)
	local button = UiKit.Button({
		Size = UDim2.fromOffset(34, 34),
		Position = UDim2.new(1, -6, 0, -6),
		AnchorPoint = Vector2.new(1, 0),
		Text = "×",
		TextSize = 22,
		Parent = parent,
	})
	button.Activated:Connect(function()
		if onClose then
			onClose()
		else
			closeScreen()
		end
	end)
	return button
end

local function scrollingBody(parent: Instance): ScrollingFrame
	local scroller = Instance.new("ScrollingFrame")
	scroller.Size = UDim2.fromScale(1, 1)
	scroller.BackgroundTransparency = 1
	scroller.BorderSizePixel = 0
	scroller.ScrollBarThickness = 4
	scroller.ScrollBarImageColor3 = UiKit.Colors.Stroke
	scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroller.CanvasSize = UDim2.new()
	scroller.Parent = parent
	UiKit.VList(scroller, 8)
	return scroller
end

--------------------------------------------------------------------------------
-- Grace offer
--------------------------------------------------------------------------------

local function buildBoonOffer(payload: any)
	openScreen("BoonOffer", function(parent)
		local root = UiKit.Frame({
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = UiKit.Colors.Void,
			BackgroundTransparency = 0.35,
			Parent = parent,
		})

		UiKit.Heading(payload.fadedName or "A GRACE IS OFFERED", {
			Size = UDim2.new(1, 0, 0, 34),
			Position = UDim2.new(0, 0, 0.16, 0),
			TextSize = 28,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextColor3 = UiKit.Colors.Accent,
			Parent = root,
		})

		if payload.greeting then
			UiKit.Label({
				Size = UDim2.new(1, 0, 0, 22),
				Position = UDim2.new(0, 0, 0.16, 36),
				Text = "<i>" .. payload.greeting .. "</i>",
				TextSize = 15,
				TextColor3 = UiKit.Colors.TextDim,
				TextXAlignment = Enum.TextXAlignment.Center,
				Parent = root,
			})
		end

		local row = UiKit.Frame({
			Size = UDim2.new(0, 300 * #payload.offers + 20 * (#payload.offers - 1), 0, 380),
			Position = UDim2.fromScale(0.5, 0.52),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Parent = root,
		})
		UiKit.HList(row, 20)

		for index, offer in payload.offers do
			local card = UiKit.Panel({
				Size = UDim2.fromOffset(300, 380),
				BackgroundColor3 = UiKit.Colors.Panel,
				StrokeColor = offer.color,
				Padding = 18,
				LayoutOrder = index,
				Parent = row,
			})

			-- The rarity stripe is the first thing the eye lands on, deliberately.
			UiKit.Frame({
				Size = UDim2.new(1, 0, 0, 5),
				BackgroundColor3 = offer.color,
				Parent = card,
			})

			UiKit.Label({
				Size = UDim2.new(1, 0, 0, 16),
				Position = UDim2.fromOffset(0, 14),
				Text = string.upper(offer.rarity),
				TextSize = 12,
				TextColor3 = offer.color,
				Font = UiKit.Fonts.Heading,
				Parent = card,
			})

			UiKit.Heading(offer.name, {
				Size = UDim2.new(1, 0, 0, 30),
				Position = UDim2.fromOffset(0, 34),
				TextSize = 22,
				Parent = card,
			})

			UiKit.Label({
				Size = UDim2.new(1, 0, 0, 18),
				Position = UDim2.fromOffset(0, 64),
				Text = offer.fadedName or "",
				TextSize = 12,
				TextColor3 = offer.elementColor or UiKit.Colors.TextDim,
				Parent = card,
			})

			UiKit.Label({
				Size = UDim2.new(1, 0, 0, 150),
				Position = UDim2.fromOffset(0, 92),
				Text = offer.description,
				TextSize = 15,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Top,
				Parent = card,
			})

			UiKit.Label({
				Size = UDim2.new(1, 0, 0, 16),
				Position = UDim2.fromOffset(0, 252),
				Text = "TRIGGER · " .. string.upper(offer.trigger or ""),
				TextSize = 11,
				TextColor3 = UiKit.Colors.TextFaint,
				Parent = card,
			})

			local take = UiKit.Button({
				Size = UDim2.new(1, 0, 0, 42),
				Position = UDim2.new(0, 0, 1, -42),
				Text = "TAKE",
				BackgroundColor3 = UiKit.Colors.PanelRaised,
				StrokeColor = offer.color,
				Parent = card,
			})
			take.Activated:Connect(function()
				Net.FireServer("BoonChoose", { index = index })
				registry.AudioController.PlayLocal("BoonTake")
				closeScreen()
			end)

			if offer.rarity == "Legendary" then
				UiKit.Pop(card, 0.2)
				registry.AudioController.PlayLocal("BoonLegendary")
			end
		end

		if (payload.rerolls or 0) > 0 then
			local reroll = UiKit.Button({
				Size = UDim2.fromOffset(200, 40),
				Position = UDim2.fromScale(0.5, 0.84),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Text = ("REROLL (%d)"):format(payload.rerolls),
				Parent = root,
			})
			reroll.Activated:Connect(function()
				Net.FireServer("BoonChoose", { reroll = true })
				registry.AudioController.PlayLocal("UiSelect")
				closeScreen()
			end)
		end

		registry.AudioController.PlayLocal("BoonOffer")
		return root
	end)
end

--------------------------------------------------------------------------------
-- Synergy announcement
--------------------------------------------------------------------------------

local function announceSynergy(payload: any)
	-- Deliberately not a blocking screen: a synergy fires mid-fight and stopping
	-- the game to tell you about it would get you killed.
	local banner = UiKit.Panel({
		Size = UDim2.fromOffset(520, 96),
		Position = UDim2.new(0.5, 0, 0.28, 0),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = UiKit.Colors.PanelRaised,
		StrokeColor = payload.color or UiKit.Colors.Accent,
		Padding = 16,
		ZIndex = 40,
		Parent = registry.HudController.ScreenGui(),
	})

	UiKit.Label({
		Size = UDim2.new(1, 0, 0, 14),
		Text = "GRACES FUSE",
		TextSize = 12,
		TextColor3 = payload.color,
		Font = UiKit.Fonts.Heading,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 41,
		Parent = banner,
	})
	UiKit.Heading(payload.name, {
		Size = UDim2.new(1, 0, 0, 30),
		Position = UDim2.fromOffset(0, 18),
		TextSize = 26,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = payload.color,
		ZIndex = 41,
		Parent = banner,
	})
	UiKit.Label({
		Size = UDim2.new(1, 0, 0, 34),
		Position = UDim2.fromOffset(0, 50),
		Text = payload.description,
		TextSize = 13,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 41,
		Parent = banner,
	})

	UiKit.Pop(banner, 0.25)
	registry.AudioController.PlayLocal("SynergyFound")
	registry.CameraController.Shake(0.6)

	task.delay(4, function()
		UiKit.FadeSubtree(banner, false, 0.4)
		task.delay(0.5, function()
			banner:Destroy()
		end)
	end)
end

--------------------------------------------------------------------------------
-- Dialogue
--------------------------------------------------------------------------------

local function buildDialogue(payload: any)
	dialogueState = { payload = payload, index = 1 }

	openScreen("Dialogue", function(parent)
		local root = UiKit.Frame({
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Parent = parent,
		})

		local box = UiKit.Panel({
			Size = UDim2.fromOffset(760, 190),
			Position = UDim2.new(0.5, 0, 1, -60),
			AnchorPoint = Vector2.new(0.5, 1),
			BackgroundColor3 = UiKit.Colors.Panel,
			StrokeColor = if payload.style == "Boss" then UiKit.Colors.Danger else UiKit.Colors.Stroke,
			Padding = 20,
			Parent = root,
		})

		UiKit.Heading(payload.npcName or "", {
			Size = UDim2.new(1, 0, 0, 24),
			TextSize = 19,
			TextColor3 = if payload.style == "Boss" then UiKit.Colors.Danger else UiKit.Colors.Accent,
			Parent = box,
		})

		local text = UiKit.Label({
			Size = UDim2.new(1, 0, 0, 84),
			Position = UDim2.fromOffset(0, 32),
			Text = "",
			TextSize = 17,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = box,
		})

		local hint = UiKit.Label({
			Size = UDim2.new(1, 0, 0, 16),
			Position = UDim2.new(0, 0, 1, -16),
			Text = "",
			TextSize = 12,
			TextColor3 = UiKit.Colors.TextFaint,
			TextXAlignment = Enum.TextXAlignment.Right,
			Parent = box,
		})

		local choiceRow = UiKit.Frame({
			Size = UDim2.new(1, 0, 0, 40),
			Position = UDim2.new(0, 0, 1, -46),
			BackgroundTransparency = 1,
			Visible = false,
			Parent = box,
		})
		UiKit.HList(choiceRow, 10)

		local advance: TextButton

		local function showChoices()
			text.Size = UDim2.new(1, 0, 0, 60)
			choiceRow.Visible = true
			advance.Visible = false
			hint.Text = ""

			for index, label in payload.choices do
				local button = UiKit.Button({
					Size = UDim2.fromOffset(220, 36),
					Text = label,
					TextSize = 14,
					LayoutOrder = index,
					Parent = choiceRow,
				})
				button.Activated:Connect(function()
					Net.FireServer("ChooseDoor", { choiceIndex = index })
					registry.AudioController.PlayLocal("UiSelect")
					closeScreen()
				end)
			end
		end

		local function render()
			local lines = payload.lines or {}
			local line = lines[dialogueState.index]
			if line then
				text.Text = line
				hint.Text = ("%d / %d   ·   CLICK TO CONTINUE"):format(dialogueState.index, #lines)
				registry.AudioController.PlayLocal("DialogueBeat")
				return
			end

			-- Out of lines: either a choice, a menu, or we are done.
			if payload.choices and #payload.choices > 0 then
				showChoices()
				return
			end
			if payload.opens then
				local opener = MenuController.Openers[payload.opens]
				if opener then
					opener(payload.payload)
					return
				end
			end
			closeScreen()
		end

		advance = UiKit.Button({
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Text = "",
			Parent = root,
		})
		advance.Activated:Connect(function()
			dialogueState.index += 1
			render()
		end)

		if #(payload.lines or {}) == 0 then
			-- A pure menu open, with no lines in front of it.
			task.defer(render)
		else
			render()
		end

		return root
	end)
end

--------------------------------------------------------------------------------
-- Expedition
--------------------------------------------------------------------------------

local selectedWeapon = "Vigil"
local selectedRegion = "SunkenMarch"
local selectedHeat = 0

local function buildExpedition(payload: any)
	openScreen("Expedition", function(parent)
		local root, body = panel(parent, UDim2.fromOffset(900, 600), "DESCEND")
		closeButton(root)

		local weaponColumn = UiKit.Frame({
			Size = UDim2.new(0.5, -10, 1, -70),
			BackgroundTransparency = 1,
			Parent = body,
		})
		UiKit.Label({
			Size = UDim2.new(1, 0, 0, 20),
			Text = "WEAPON",
			TextSize = 13,
			TextColor3 = UiKit.Colors.TextDim,
			Font = UiKit.Fonts.Heading,
			Parent = weaponColumn,
		})
		local weaponList = scrollingBody(UiKit.Frame({
			Size = UDim2.new(1, 0, 1, -26),
			Position = UDim2.fromOffset(0, 26),
			BackgroundTransparency = 1,
			Parent = weaponColumn,
		}))

		local detail = UiKit.Panel({
			Size = UDim2.new(0.5, -10, 1, -70),
			Position = UDim2.new(0.5, 10, 0, 0),
			BackgroundColor3 = UiKit.Colors.PanelRaised,
			Padding = 16,
			Parent = body,
		})

		local detailTitle = UiKit.Heading("", { Size = UDim2.new(1, 0, 0, 28), TextSize = 22, Parent = detail })
		local detailSub = UiKit.Label({
			Size = UDim2.new(1, 0, 0, 18),
			Position = UDim2.fromOffset(0, 28),
			Text = "",
			TextSize = 13,
			TextColor3 = UiKit.Colors.TextDim,
			Parent = detail,
		})
		local detailBody = UiKit.Label({
			Size = UDim2.new(1, 0, 0, 240),
			Position = UDim2.fromOffset(0, 54),
			Text = "",
			TextSize = 14,
			TextWrapped = true,
			TextYAlignment = Enum.TextYAlignment.Top,
			Parent = detail,
		})

		local function showWeapon(weapon: any)
			selectedWeapon = weapon.id
			detailTitle.Text = weapon.name
			detailSub.Text = weapon.subtitle

			local lines = { weapon.playstyle, "" }
			table.insert(lines, "<b>STRENGTHS</b>")
			for _, entry in weapon.strengths do
				table.insert(lines, "· " .. entry)
			end
			table.insert(lines, "")
			table.insert(lines, "<b>WEAKNESSES</b>")
			for _, entry in weapon.weaknesses do
				table.insert(lines, "· " .. entry)
			end
			table.insert(lines, "")
			local _, into, span = MasteryConfig.LevelForExperience(weapon.experience or 0)
			table.insert(lines, ("MASTERY %d  ·  %d / %d"):format(weapon.level or 1, into, span))
			detailBody.Text = table.concat(lines, "\n")
		end

		for index, weapon in payload.weapons do
			local button = UiKit.Button({
				Size = UDim2.new(1, -8, 0, 54),
				Text = "",
				LayoutOrder = index,
				BackgroundColor3 = if weapon.unlocked then UiKit.Colors.PanelRaised else UiKit.Colors.Panel,
				Parent = weaponList,
			})
			UiKit.Label({
				Size = UDim2.new(1, -16, 0, 20),
				Position = UDim2.fromOffset(12, 8),
				Text = weapon.name,
				TextSize = 17,
				Font = UiKit.Fonts.Heading,
				TextColor3 = if weapon.unlocked then UiKit.Colors.Text else UiKit.Colors.TextFaint,
				Parent = button,
			})
			UiKit.Label({
				Size = UDim2.new(1, -16, 0, 16),
				Position = UDim2.fromOffset(12, 28),
				Text = if weapon.unlocked
					then ("MASTERY %d"):format(weapon.level)
					else ("LOCKED · %d SABLE"):format(weapon.cost),
				TextSize = 12,
				TextColor3 = UiKit.Colors.TextDim,
				Parent = button,
			})

			button.Activated:Connect(function()
				if weapon.unlocked then
					showWeapon(weapon)
					registry.AudioController.PlayLocal("UiSelect")
				else
					local ok, reason = Net.Function("HubAction"):InvokeServer("UnlockWeapon", { weaponId = weapon.id })
					if not ok then
						detailBody.Text = "<font color='#ff6666'>" .. tostring(reason) .. "</font>"
					else
						closeScreen()
					end
				end
			end)

			if index == 1 then
				showWeapon(weapon)
			end
		end

		-- Region and heat sit along the bottom: they are chosen once and rarely
		-- changed, so they get less real estate than the weapon.
		local footer = UiKit.Frame({
			Size = UDim2.new(1, 0, 0, 56),
			Position = UDim2.new(0, 0, 1, -56),
			BackgroundTransparency = 1,
			Parent = body,
		})
		UiKit.HList(footer, 10)

		for index, region in payload.regions do
			local button = UiKit.Button({
				Size = UDim2.fromOffset(180, 44),
				Text = region.name,
				TextSize = 13,
				LayoutOrder = index,
				StrokeColor = if region.id == selectedRegion then UiKit.Colors.Accent else UiKit.Colors.Stroke,
				Parent = footer,
			})
			button.Activated:Connect(function()
				selectedRegion = region.id
				for _, sibling in footer:GetChildren() do
					if sibling:IsA("TextButton") then
						local stroke = sibling:FindFirstChildOfClass("UIStroke")
						if stroke then
							stroke.Color = UiKit.Colors.Stroke
						end
					end
				end
				local stroke = button:FindFirstChildOfClass("UIStroke")
				if stroke then
					stroke.Color = UiKit.Colors.Accent
				end
				registry.AudioController.PlayLocal("UiSelect")
			end)
			if index == 1 then
				selectedRegion = region.id
			end
		end

		-- Heat. Optional difficulty that multiplies rewards; the only route to some
		-- cosmetics. A stepper rather than a slider because the interesting
		-- decision is one notch at a time, not a value you drag to.
		local heatPanel = UiKit.Frame({
			Size = UDim2.fromOffset(150, 44),
			BackgroundTransparency = 1,
			LayoutOrder = 90,
			Parent = footer,
		})
		local heatLabel = UiKit.Label({
			Size = UDim2.new(1, -70, 1, 0),
			Position = UDim2.fromOffset(0, 0),
			Text = "",
			TextSize = 13,
			Font = UiKit.Fonts.Heading,
			Parent = heatPanel,
		})

		local function refreshHeat()
			local multiplier = 1 + selectedHeat * GameConfig.Run.RewardPerHeat
			heatLabel.Text = ("HEAT %d\n<font color='#8a8a8a'>×%.2f rewards</font>")
				:format(selectedHeat, multiplier)
			heatLabel.TextColor3 = if selectedHeat > 0 then UiKit.Colors.Danger else UiKit.Colors.TextDim
		end

		local function heatButton(text: string, delta: number, x: number)
			local button = UiKit.Button({
				Size = UDim2.fromOffset(30, 30),
				Position = UDim2.new(1, x, 0.5, 0),
				AnchorPoint = Vector2.new(1, 0.5),
				Text = text,
				TextSize = 18,
				Parent = heatPanel,
			})
			button.Activated:Connect(function()
				selectedHeat = math.clamp(selectedHeat + delta, 0, payload.maxHeat or GameConfig.Run.MaxHeat)
				refreshHeat()
				registry.AudioController.PlayLocal("UiSelect")
			end)
		end

		heatButton("−", -1, -34)
		heatButton("+", 1, 0)
		refreshHeat()

		local descend = UiKit.Button({
			Size = UDim2.fromOffset(200, 44),
			Text = "DESCEND",
			TextSize = 17,
			BackgroundColor3 = UiKit.Colors.PanelRaised,
			StrokeColor = UiKit.Colors.Accent,
			LayoutOrder = 99,
			Parent = footer,
		})
		descend.Activated:Connect(function()
			local ok, reason = Net.Function("RunRequest"):InvokeServer("Start", selectedWeapon, selectedRegion, selectedHeat)
			if ok then
				closeScreen()
			else
				detailBody.Text = "<font color='#ff6666'>" .. tostring(reason) .. "</font>"
			end
		end)

		return root
	end)
end

--------------------------------------------------------------------------------
-- Hub menus
--------------------------------------------------------------------------------

local function buildSmith()
	openScreen("Smith", function(parent)
		local root, body = panel(parent, UDim2.fromOffset(760, 560), "DURN HALVIC")
		closeButton(root)

		local list = scrollingBody(body)

		for _, weaponId in WeaponConfig.Order do
			local definition = WeaponConfig.Get(weaponId)
			local owned = profile and profile.weapons[weaponId]
			if not definition or not owned then
				continue
			end

			local card = UiKit.Panel({
				Size = UDim2.new(1, -8, 0, 40 + #definition.tempers * 62),
				BackgroundColor3 = UiKit.Colors.PanelRaised,
				Padding = 12,
				Parent = list,
			})

			UiKit.Heading(definition.displayName, {
				Size = UDim2.new(1, 0, 0, 24),
				TextSize = 19,
				TextColor3 = if owned.unlocked then UiKit.Colors.Text else UiKit.Colors.TextFaint,
				Parent = card,
			})

			for index, temper in definition.tempers do
				local row = UiKit.Panel({
					Size = UDim2.new(1, 0, 0, 56),
					Position = UDim2.fromOffset(0, 28 + (index - 1) * 62),
					BackgroundColor3 = UiKit.Colors.Panel,
					Padding = 10,
					Parent = card,
				})

				local isOwned = owned.tempers[temper.id] == true
				local isEquipped = owned.equippedTemper == temper.id
				local canBuy = owned.level >= temper.requiresMastery

				UiKit.Label({
					Size = UDim2.new(1, -140, 0, 18),
					Text = temper.name,
					TextSize = 15,
					Font = UiKit.Fonts.Heading,
					TextColor3 = if isOwned then UiKit.Colors.Text else UiKit.Colors.TextDim,
					Parent = row,
				})
				UiKit.Label({
					Size = UDim2.new(1, -140, 0, 18),
					Position = UDim2.fromOffset(0, 18),
					Text = temper.description,
					TextSize = 12,
					TextColor3 = UiKit.Colors.TextFaint,
					TextWrapped = true,
					Parent = row,
				})

				local action = UiKit.Button({
					Size = UDim2.fromOffset(120, 32),
					Position = UDim2.new(1, 0, 0.5, 0),
					AnchorPoint = Vector2.new(1, 0.5),
					Text = if isEquipped
						then "EQUIPPED"
						elseif isOwned then "EQUIP"
						elseif not canBuy then ("MASTERY %d"):format(temper.requiresMastery)
						else ("%d SABLE"):format(temper.cost),
					TextSize = 12,
					StrokeColor = if isEquipped then UiKit.Colors.Accent else UiKit.Colors.Stroke,
					Parent = row,
				})
				action.Activated:Connect(function()
					if isEquipped then
						Net.Function("HubAction"):InvokeServer("EquipTemper", { weaponId = weaponId, temperId = "" })
					elseif isOwned then
						Net.Function("HubAction"):InvokeServer("EquipTemper", { weaponId = weaponId, temperId = temper.id })
					elseif canBuy then
						Net.Function("HubAction"):InvokeServer("BuyTemper", { weaponId = weaponId, temperId = temper.id })
					else
						return
					end
					registry.AudioController.PlayLocal("UiSelect")
					task.wait(0.1)
					buildSmith()
				end)
			end
		end

		return root
	end)
end

local function buildRelics()
	openScreen("Relics", function(parent)
		local root, body = panel(parent, UDim2.fromOffset(780, 580), "THE SMALL THINGS")
		closeButton(root)

		local list = scrollingBody(body)

		for setId, set in RelicConfig.Sets do
			local have, total = RelicConfig.SetProgress(setId, profile and profile.relics.owned or {})

			UiKit.Label({
				Size = UDim2.new(1, -8, 0, 26),
				Text = ("%s   <font color='#8a8a8a'>%d / %d</font>"):format(set.name, have, total),
				TextSize = 16,
				Font = UiKit.Fonts.Heading,
				TextColor3 = if have == total then UiKit.Colors.Accent else UiKit.Colors.Text,
				Parent = list,
			})

			for _, relic in RelicConfig.InSet(setId) do
				local owned = profile and profile.relics.owned[relic.id]
				local equipped = profile and profile.relics.equipped[relic.id]

				local row = UiKit.Panel({
					Size = UDim2.new(1, -8, 0, 66),
					BackgroundColor3 = UiKit.Colors.PanelRaised,
					StrokeColor = if equipped then UiKit.Colors.Accent else UiKit.Colors.Stroke,
					Padding = 10,
					Parent = list,
				})

				UiKit.Label({
					Size = UDim2.new(1, -120, 0, 18),
					Text = if owned then relic.name else "???",
					TextSize = 15,
					Font = UiKit.Fonts.Heading,
					TextColor3 = if owned then UiKit.Colors.Text else UiKit.Colors.TextFaint,
					Parent = row,
				})
				UiKit.Label({
					Size = UDim2.new(1, -120, 0, 30),
					Position = UDim2.fromOffset(0, 18),
					-- Locked Keepsakes show how to get them, not what they do. Knowing
					-- the hint is the interesting half.
					Text = if owned then relic.description else relic.source,
					TextSize = 12,
					TextColor3 = UiKit.Colors.TextDim,
					TextWrapped = true,
					Parent = row,
				})

				if owned then
					local button = UiKit.Button({
						Size = UDim2.fromOffset(100, 30),
						Position = UDim2.new(1, 0, 0.5, 0),
						AnchorPoint = Vector2.new(1, 0.5),
						Text = if equipped then "REMOVE" else "EQUIP",
						TextSize = 12,
						Parent = row,
					})
					button.Activated:Connect(function()
						Net.Function("HubAction"):InvokeServer("EquipRelic", {
							relicId = relic.id,
							equip = not equipped,
						})
						registry.AudioController.PlayLocal("UiSelect")
						task.wait(0.1)
						buildRelics()
					end)
				end
			end
		end

		return root
	end)
end

local function buildWardrobe()
	openScreen("Wardrobe", function(parent)
		local root, body = panel(parent, UDim2.fromOffset(780, 580), "WARDROBE")
		closeButton(root)

		local list = scrollingBody(body)

		for slot, slotInfo in CosmeticConfig.Slots do
			local options = CosmeticConfig.BySlot(slot)
			local ownedOptions = {}
			for _, cosmetic in options do
				if profile and profile.cosmetics.owned[cosmetic.id] then
					table.insert(ownedOptions, cosmetic)
				end
			end
			if #ownedOptions == 0 then
				continue
			end

			UiKit.Label({
				Size = UDim2.new(1, -8, 0, 22),
				Text = slotInfo.label,
				TextSize = 13,
				Font = UiKit.Fonts.Heading,
				TextColor3 = UiKit.Colors.TextDim,
				Parent = list,
			})

			local row = UiKit.Frame({
				Size = UDim2.new(1, -8, 0, 40),
				BackgroundTransparency = 1,
				Parent = list,
			})
			UiKit.HList(row, 8)

			local equippedId = profile and profile.cosmetics.equipped[slot] or ""

			local none = UiKit.Button({
				Size = UDim2.fromOffset(90, 34),
				Text = "NONE",
				TextSize = 12,
				StrokeColor = if equippedId == "" then UiKit.Colors.Accent else UiKit.Colors.Stroke,
				Parent = row,
			})
			none.Activated:Connect(function()
				Net.Function("HubAction"):InvokeServer("EquipCosmetic", { slot = slot, cosmeticId = "" })
				task.wait(0.1)
				buildWardrobe()
			end)

			for _, cosmetic in ownedOptions do
				local button = UiKit.Button({
					Size = UDim2.fromOffset(170, 34),
					Text = cosmetic.name,
					TextSize = 12,
					StrokeColor = if equippedId == cosmetic.id then UiKit.Colors.Accent else UiKit.Colors.Stroke,
					Parent = row,
				})
				button.Activated:Connect(function()
					Net.Function("HubAction"):InvokeServer("EquipCosmetic", { slot = slot, cosmeticId = cosmetic.id })
					registry.AudioController.PlayLocal("UiSelect")
					task.wait(0.1)
					buildWardrobe()
				end)
			end
		end

		return root
	end)
end

local function buildMastery()
	openScreen("Mastery", function(parent)
		local root, body = panel(parent, UDim2.fromOffset(800, 580), "MASTERY")
		closeButton(root)

		local list = scrollingBody(body)

		for _, weaponId in WeaponConfig.Order do
			local definition = WeaponConfig.Get(weaponId)
			local owned = profile and profile.weapons[weaponId]
			if not definition or not owned or not owned.unlocked then
				continue
			end

			local rewards = MasteryConfig.RewardsFor(weaponId)
			local card = UiKit.Panel({
				Size = UDim2.new(1, -8, 0, 60 + #rewards * 26),
				BackgroundColor3 = UiKit.Colors.PanelRaised,
				Padding = 12,
				Parent = list,
			})

			local level, into, span = MasteryConfig.LevelForExperience(owned.experience)
			UiKit.Heading(("%s  ·  %d"):format(definition.displayName, level), {
				Size = UDim2.new(1, 0, 0, 24),
				TextSize = 19,
				Parent = card,
			})

			local bar = UiKit.Bar({
				Size = UDim2.new(1, 0, 0, 10),
				Position = UDim2.fromOffset(0, 28),
				Color = UiKit.Colors.Accent,
				GhostColor = Color3.fromRGB(80, 62, 34),
				Parent = card,
			})
			bar:SetValue(into, span)

			for index, reward in rewards do
				local unlocked = level >= reward.level
				UiKit.Label({
					Size = UDim2.new(1, 0, 0, 24),
					Position = UDim2.fromOffset(0, 46 + (index - 1) * 26),
					Text = ("<b>%d</b>   %s   <font color='#8a8a8a'>%s</font>"):format(
						reward.level,
						reward.name,
						reward.description
					),
					TextSize = 12,
					TextColor3 = if unlocked then UiKit.Colors.Text else UiKit.Colors.TextFaint,
					Parent = card,
				})
			end
		end

		return root
	end)
end

local function buildSettings()
	openScreen("Settings", function(parent)
		local root, body = panel(parent, UDim2.fromOffset(520, 480), "SETTINGS")
		closeButton(root)

		local list = scrollingBody(body)
		local pending = {}

		local function slider(label: string, key: string, value: number, minimum: number, maximum: number)
			local row = UiKit.Frame({
				Size = UDim2.new(1, -8, 0, 52),
				BackgroundTransparency = 1,
				Parent = list,
			})
			local caption = UiKit.Label({
				Size = UDim2.new(1, 0, 0, 20),
				Text = ("%s  ·  %.2f"):format(label, value),
				TextSize = 14,
				Parent = row,
			})

			local track = UiKit.Frame({
				Size = UDim2.new(1, 0, 0, 12),
				Position = UDim2.fromOffset(0, 26),
				BackgroundColor3 = UiKit.Colors.Void,
				Parent = row,
			})
			local fill = UiKit.Frame({
				Size = UDim2.fromScale((value - minimum) / (maximum - minimum), 1),
				BackgroundColor3 = UiKit.Colors.Accent,
				Parent = track,
			})

			local button = UiKit.Button({
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Text = "",
				Parent = track,
			})
			-- Click-anywhere-on-the-track. Drag would be nicer; this is one line and
			-- works identically on touch and gamepad-with-cursor.
			button.Activated:Connect(function()
				local mouse = player:GetMouse()
				local fraction = math.clamp((mouse.X - track.AbsolutePosition.X) / track.AbsoluteSize.X, 0, 1)
				local newValue = minimum + fraction * (maximum - minimum)
				fill.Size = UDim2.fromScale(fraction, 1)
				caption.Text = ("%s  ·  %.2f"):format(label, newValue)
				pending[key] = newValue
				Net.FireServer("SettingsSync", { [key] = newValue })
			end)
		end

		local function toggle(label: string, key: string, value: boolean)
			local button = UiKit.Button({
				Size = UDim2.new(1, -8, 0, 40),
				Text = ("%s  ·  %s"):format(label, if value then "ON" else "OFF"),
				TextSize = 14,
				Parent = list,
			})
			local state = value
			button.Activated:Connect(function()
				state = not state
				button.Text = ("%s  ·  %s"):format(label, if state then "ON" else "OFF")
				Net.FireServer("SettingsSync", { [key] = state })
			end)
		end

		local settings = (profile and profile.settings) or {}
		slider("CAMERA SHAKE", "cameraShake", settings.cameraShake or 1, 0, 2)
		slider("HUD SCALE", "hudScale", settings.hudScale or 1, 0.7, 1.4)
		slider("MASTER VOLUME", "masterVolume", settings.masterVolume or 1, 0, 1)
		slider("MUSIC VOLUME", "musicVolume", settings.musicVolume or 0.5, 0, 1)
		slider("SFX VOLUME", "sfxVolume", settings.sfxVolume or 0.85, 0, 1)
		toggle("SCREEN FLASH", "screenFlash", settings.screenFlash ~= false)
		toggle("DAMAGE NUMBERS", "damageNumbers", settings.damageNumbers ~= false)

		return root
	end)
end

--------------------------------------------------------------------------------
-- Run summary
--------------------------------------------------------------------------------

local function buildSummary(summary: any)
	openScreen("Summary", function(parent)
		local root = UiKit.Frame({
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = UiKit.Colors.Void,
			BackgroundTransparency = 0.15,
			Parent = parent,
		})

		local card = UiKit.Panel({
			Size = UDim2.fromOffset(700, 560),
			Position = UDim2.fromScale(0.5, 0.5),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundColor3 = UiKit.Colors.Panel,
			Padding = 24,
			Parent = root,
		})

		-- The title never says "you died". It says the run is over and what it left.
		UiKit.Heading(if summary.outcome == "Victory" then "THE WARDEN FALLS" else "RUN COMPLETE", {
			Size = UDim2.new(1, 0, 0, 34),
			TextSize = 30,
			TextColor3 = if summary.outcome == "Victory" then UiKit.Colors.Accent else UiKit.Colors.Text,
			Parent = card,
		})

		UiKit.Label({
			Size = UDim2.new(1, 0, 0, 20),
			Position = UDim2.fromOffset(0, 34),
			Text = ("%s  ·  %s  ·  %d rooms"):format(
				summary.region or "",
				string.upper(summary.weaponId or ""),
				summary.roomsCleared or 0
			),
			TextSize = 13,
			TextColor3 = UiKit.Colors.TextDim,
			Parent = card,
		})

		-- Kept, first and largest.
		local kept = UiKit.Panel({
			Size = UDim2.new(1, 0, 0, 130),
			Position = UDim2.fromOffset(0, 64),
			BackgroundColor3 = UiKit.Colors.PanelRaised,
			StrokeColor = UiKit.Colors.Accent,
			Padding = 14,
			Parent = card,
		})
		UiKit.Label({
			Size = UDim2.new(1, 0, 0, 16),
			Text = "YOU KEEP",
			TextSize = 12,
			TextColor3 = UiKit.Colors.Accent,
			Font = UiKit.Fonts.Heading,
			Parent = kept,
		})
		UiKit.Heading(("%d SABLE"):format(summary.sableEarned or 0), {
			Size = UDim2.new(1, 0, 0, 34),
			Position = UDim2.fromOffset(0, 20),
			TextSize = 28,
			TextColor3 = UiKit.Colors.Accent,
			Parent = kept,
		})

		local mastery = summary.masteryGained
		if mastery then
			local text = ("%s MASTERY  ·  +%d"):format(string.upper(summary.weaponId or ""), mastery.gained or 0)
			if mastery.levelAfter and mastery.levelAfter > (mastery.levelBefore or 0) then
				text ..= ("   <font color='#ffba4a'>LEVEL %d</font>"):format(mastery.levelAfter)
			end
			UiKit.Label({
				Size = UDim2.new(1, 0, 0, 20),
				Position = UDim2.fromOffset(0, 58),
				Text = text,
				TextSize = 14,
				Parent = kept,
			})
			for index, reward in mastery.rewards or {} do
				UiKit.Label({
					Size = UDim2.new(1, 0, 0, 16),
					Position = UDim2.fromOffset(0, 78 + (index - 1) * 16),
					Text = "· " .. reward.name .. " — " .. reward.description,
					TextSize = 11,
					TextColor3 = UiKit.Colors.TextDim,
					Parent = kept,
				})
			end
		end

		-- Everything else, smaller.
		local stats = {
			{ "ENEMIES", summary.enemiesKilled or 0 },
			{ "ELITES", summary.elitesKilled or 0 },
			{ "DAMAGE DEALT", summary.damageDealt or 0 },
			{ "DAMAGE TAKEN", summary.damageTaken or 0 },
			{ "PERFECT PARRIES", summary.perfectParries or 0 },
			{ "FLAWLESS ROOMS", summary.flawlessRooms or 0 },
			{ "MOTES", summary.motesEarned or 0 },
			{ "HEAT", summary.heat or 0 },
		}

		for index, entry in stats do
			local column = (index - 1) % 2
			local rowIndex = (index - 1) // 2
			UiKit.Label({
				Size = UDim2.new(0.5, -8, 0, 20),
				Position = UDim2.new(column * 0.5, 0, 0, 208 + rowIndex * 22),
				Text = ("%s   <font color='#ecece6'>%d</font>"):format(entry[1], entry[2]),
				TextSize = 13,
				TextColor3 = UiKit.Colors.TextDim,
				Parent = card,
			})
		end

		local boons = summary.boons or {}
		if #boons > 0 then
			UiKit.Label({
				Size = UDim2.new(1, 0, 0, 18),
				Position = UDim2.fromOffset(0, 320),
				Text = "GRACES HELD",
				TextSize = 12,
				TextColor3 = UiKit.Colors.TextDim,
				Font = UiKit.Fonts.Heading,
				Parent = card,
			})
			for index, boon in boons do
				if index > 8 then
					break
				end
				UiKit.Label({
					Size = UDim2.new(0.5, -8, 0, 18),
					Position = UDim2.new(((index - 1) % 2) * 0.5, 0, 0, 340 + ((index - 1) // 2) * 18),
					Text = boon.name,
					TextSize = 12,
					TextColor3 = boon.color,
					Parent = card,
				})
			end
		end

		local again = UiKit.Button({
			Size = UDim2.new(1, 0, 0, 46),
			Position = UDim2.new(0, 0, 1, -46),
			Text = "RETURN TO EMBERHOLD",
			TextSize = 16,
			StrokeColor = UiKit.Colors.Accent,
			Parent = card,
		})
		again.Activated:Connect(closeScreen)

		registry.AudioController.PlayLocal("RunSummary")
		return root
	end)
end

--------------------------------------------------------------------------------
-- Pause menu
--------------------------------------------------------------------------------

local function buildPause()
	openScreen("Pause", function(parent)
		local root, body = panel(parent, UDim2.fromOffset(360, 400), Lore.GameName)
		closeButton(root)

		local list = scrollingBody(body)

		local entries = {
			{ "RESUME", closeScreen },
			{ "MASTERY", buildMastery },
			{ "KEEPSAKES", buildRelics },
			{ "WARDROBE", buildWardrobe },
			{ "SETTINGS", buildSettings },
		}

		if registry.HudController.IsRunActive() then
			table.insert(entries, { "ABANDON RUN", function()
				Net.Function("RunRequest"):InvokeServer("Abandon")
				closeScreen()
			end })
		end

		for index, entry in entries do
			local button = UiKit.Button({
				Size = UDim2.new(1, -8, 0, 44),
				Text = entry[1],
				TextSize = 15,
				LayoutOrder = index,
				Parent = list,
			})
			button.Activated:Connect(entry[2])
		end

		return root
	end)
end

function MenuController.ToggleMenu()
	if currentScreen then
		-- Grace offers and summaries are not dismissible with Escape; they are
		-- decisions the run is waiting on.
		if currentScreenName == "BoonOffer" or currentScreenName == "Summary" then
			return
		end
		closeScreen()
		return
	end
	buildPause()
end

--------------------------------------------------------------------------------
-- Openers, addressed by name from server dialogue payloads.
--------------------------------------------------------------------------------

MenuController.Openers = {
	Expedition = buildExpedition,
	Smith = buildSmith,
	Mystic = buildRelics,
	Relics = buildRelics,
	Wardrobe = buildWardrobe,
	Mastery = buildMastery,
	Settings = buildSettings,
	PermanentUpgrades = buildRelics,
	RegionSelect = buildExpedition,
	HeatSelect = buildExpedition,
}

--------------------------------------------------------------------------------

function MenuController.Init(services: any)
	registry = services
	UiKit = services.UiKit
end

function MenuController.Start()
	local screenGui = registry.HudController.ScreenGui()

	overlay = UiKit.Frame({
		Name = "MenuOverlay",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
		ZIndex = 60,
		Parent = screenGui,
	})

	GuiService.AutoSelectGuiEnabled = true

	Net.OnClientEvent("ProfileSync", function(payload)
		if type(payload) == "table" then
			profile = payload
		end
	end)

	Net.OnClientEvent("BoonOffer", function(payload)
		if type(payload) == "table" and payload.offers then
			buildBoonOffer(payload)
		end
	end)

	Net.OnClientEvent("SynergyFound", function(payload)
		if type(payload) == "table" then
			announceSynergy(payload)
		end
	end)

	Net.OnClientEvent("Dialogue", function(payload)
		if type(payload) == "table" then
			buildDialogue(payload)
		end
	end)

	Net.OnClientEvent("RunSummary", function(payload)
		if type(payload) == "table" then
			buildSummary(payload)
		end
	end)
end

return MenuController
