--!strict
--[[
	WeaponService — builds weapons, and resolves what a weapon currently is.

	Two jobs.

	1. GEOMETRY. Weapons are assembled from the part specs in WeaponConfig.Models
	   and welded to the wielder's hand. Quarrel builds twice, mirrored, because it
	   is two blades.

	2. RESOLUTION. The weapon the combat system uses is not the one in the config.
	   It is that config with mastery modifiers and the equipped Temper folded in.
	   Doing that fold once per equip -- rather than per swing -- keeps the hot
	   path free of lookups, and keeps every "does this Temper apply here?"
	   question in one function instead of scattered through combat code.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("HollowVerge")
local WeaponConfig = require(Shared.Config.WeaponConfig)
local MasteryConfig = require(Shared.Config.MasteryConfig)
local GameConfig = require(Shared.Config.GameConfig)
local PartFactory = require(Shared.Util.PartFactory)
local TableUtil = require(Shared.Util.TableUtil)

local WeaponService = {}

local registry: any = nil

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

local function buildWeaponModel(spec: any, mirrored: boolean): Model
	local model = Instance.new("Model")
	model.Name = "WeaponModel"

	local root: BasePart? = nil
	for index, partSpec in spec.parts do
		local offset = partSpec.offset
		if mirrored then
			-- Mirror across X so the offhand blade is a reflection, not a copy.
			local position = offset.Position
			offset = CFrame.new(-position.X, position.Y, position.Z) * (offset - position)
		end

		local part
		if partSpec.wedge then
			part = PartFactory.Wedge({
				Name = partSpec.name,
				Size = partSpec.size,
				Color = partSpec.color,
				Material = partSpec.material,
				CanCollide = false,
				Anchored = false,
			})
		else
			part = PartFactory.Part({
				Name = partSpec.name,
				Size = partSpec.size,
				Color = partSpec.color,
				Material = partSpec.material,
				Reflectance = partSpec.reflectance,
				CanCollide = false,
				CanQuery = false,
				Anchored = false,
			})
		end
		part.Massless = true
		part.CollisionGroup = GameConfig.Collision.Hitbox
		part:SetAttribute("LocalOffset", offset)
		part.Parent = model

		if index == 1 then
			root = part
		end
	end

	model.PrimaryPart = root
	return model
end

--[[
	Welds a weapon to a character's hand. Positions every part relative to the
	grip first, then welds, so the weld captures the intended pose rather than
	whatever the parts happened to be at.
]]
local function attachWeapon(character: Model, model: Model, gripPart: BasePart, gripOffset: CFrame)
	local base = gripPart.CFrame * gripOffset

	for _, part in model:GetChildren() do
		if part:IsA("BasePart") then
			local localOffset = part:GetAttribute("LocalOffset") :: CFrame
			part.CFrame = base * localOffset
		end
	end

	for _, part in model:GetChildren() do
		if part:IsA("BasePart") then
			PartFactory.Weld(gripPart, part, part)
		end
	end

	model.Parent = character
end

--- Finds the part a weapon should hang from, across our rigs and player rigs.
local function findGrip(character: Model, leftHand: boolean): BasePart?
	local names = if leftHand
		then { "LeftHand", "LeftArm", "Left Arm" }
		else { "RightHand", "RightArm", "Right Arm" }
	for _, name in names do
		local part = character:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Trails
--------------------------------------------------------------------------------

--- Adds a swing trail to the blade. Disabled by default; CombatService enables it
--- only while a hitbox is open, which is what makes a trail read as "this is the
--- dangerous part" rather than as decoration.
local function addTrail(model: Model, spec: any, color: Color3): Trail?
	if not spec.trail or not model.PrimaryPart then
		return nil
	end

	local blade: BasePart? = nil
	for _, part in model:GetChildren() do
		if part:IsA("BasePart") and (part.Name == "Blade" or part.Name == "BladeMain" or part.Name == "Head") then
			blade = part
			break
		end
	end
	blade = blade or model.PrimaryPart

	-- The trail runs along the blade's own length. Deriving it from the part
	-- rather than from the config keeps it correct for any weapon shape, and for
	-- the mirrored offhand copy where config-space offsets would be flipped.
	local length = (blade :: BasePart).Size.Y
	local from = PartFactory.Attachment(blade :: BasePart, CFrame.new(0, -length * 0.5, 0), "TrailFrom")
	local to = PartFactory.Attachment(blade :: BasePart, CFrame.new(0, length * 0.5, 0), "TrailTo")

	local trail = Instance.new("Trail")
	trail.Attachment0 = from
	trail.Attachment1 = to
	trail.Color = ColorSequence.new(color)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.Lifetime = 0.22
	trail.MinLength = 0.1
	trail.LightEmission = 0.6
	trail.FaceCamera = true
	trail.Enabled = false
	trail.Parent = blade

	return trail
end

--------------------------------------------------------------------------------
-- Resolution
--------------------------------------------------------------------------------

--[[
	Folds mastery and Temper modifiers into a copy of the weapon definition.

	Everything here is deliberately explicit rather than a generic key-merge: a
	Temper that says `heavyDamage = 1.15` has to know it means "multiply the heavy
	swing's damage", and writing that out is clearer than inventing a path syntax
	to express it in the config.
]]
function WeaponService.Resolve(weaponId: string, masteryLevel: number, temperId: string?): any
	local base = WeaponConfig.GetOrDefault(weaponId)
	local weapon = TableUtil.DeepCopy(base)

	local mastery = MasteryConfig.ResolveModifiers(weaponId, masteryLevel)
	local temper = nil
	if temperId and temperId ~= "" then
		for _, candidate in base.tempers do
			if candidate.id == temperId then
				temper = candidate.modifiers
				break
			end
		end
	end

	local function scaleSwingDamage(swing: any, scale: number)
		if swing then
			swing.damage *= scale
		end
	end

	local function eachSwing(fn: (any, string) -> ())
		for index, swing in weapon.lightCombo do
			fn(swing, "light" .. index)
		end
		fn(weapon.heavy, "heavy")
		if weapon.ability and weapon.ability.swing then
			fn(weapon.ability.swing, "ability")
		end
		if weapon.ultimate and weapon.ultimate.swing then
			fn(weapon.ultimate.swing, "ultimate")
		end
	end

	-- Mastery.
	if mastery.damageScale then
		eachSwing(function(swing)
			scaleSwingDamage(swing, mastery.damageScale)
		end)
	end
	if mastery.poiseScale then
		eachSwing(function(swing)
			swing.poise *= mastery.poiseScale
		end)
	end
	if mastery.rangeScale then
		eachSwing(function(swing)
			swing.hitbox.range *= mastery.rangeScale
		end)
	end
	if mastery.cancelScale then
		weapon.cancelScale = (weapon.cancelScale or 1) * mastery.cancelScale
	end

	-- Tempers.
	if temper then
		if temper.damageScale then
			eachSwing(function(swing)
				scaleSwingDamage(swing, temper.damageScale)
			end)
		end
		if temper.heavyDamage then
			scaleSwingDamage(weapon.heavy, temper.heavyDamage)
		end
		if temper.cancelScale then
			weapon.cancelScale = (weapon.cancelScale or 1) * temper.cancelScale
		end
		if temper.comboLength then
			for index = #weapon.lightCombo, temper.comboLength + 1, -1 do
				weapon.lightCombo[index] = nil
			end
		end
		if temper.moveSpeedScale then
			weapon.stats.moveSpeedMultiplier *= temper.moveSpeedScale
		end
		if temper.thrustRangeScale then
			eachSwing(function(swing)
				if swing.tags and table.find(swing.tags, "IsThrust") then
					swing.hitbox.range *= temper.thrustRangeScale
				end
			end)
		end
		if temper.sweepAngleScale then
			eachSwing(function(swing)
				if swing.hitbox.angle then
					swing.hitbox.angle *= temper.sweepAngleScale
				end
			end)
		end
		if temper.superArmorAll then
			eachSwing(function(swing)
				swing.superArmorFrom = 0
			end)
		end
		if temper.heavyStaminaScale then
			weapon.heavyStaminaScale = temper.heavyStaminaScale
		end
		-- Behavioural flags the combat system reads directly.
		weapon.temperFlags = temper
	end

	-- Mastery may extend the light chain. The extra swing reuses the chain's last
	-- entry with different tags, so a new combo step costs no new animation data.
	if mastery.extraSwing == "launcher" then
		local extra = TableUtil.DeepCopy(weapon.heavy)
		extra.damage *= 0.7
		extra.launch = 30
		extra.tags = { "IsFinal", "IsLauncher" }
		table.insert(weapon.lightCombo, extra)
	elseif mastery.extraSwing == "airPair" then
		local last = weapon.lightCombo[#weapon.lightCombo]
		for _ = 1, 2 do
			local extra = TableUtil.DeepCopy(last)
			extra.damage *= 1.1
			extra.tags = { "IsAir" }
			table.insert(weapon.lightCombo, extra)
		end
	end

	weapon.masteryModifiers = mastery
	weapon.masteryLevel = masteryLevel
	weapon.equippedTemper = temperId or ""
	return weapon
end

--------------------------------------------------------------------------------
-- Equipping
--------------------------------------------------------------------------------

local equipped: { [Model]: { model: Model, offhand: Model?, trail: Trail?, weaponId: string } } = {}

function WeaponService.Equip(character: Model, weaponId: string, accentColor: Color3?): boolean
	WeaponService.Unequip(character)

	local definition = WeaponConfig.Get(weaponId)
	if not definition then
		return false
	end

	local grip = findGrip(character, false)
	if not grip then
		return false
	end

	local model = buildWeaponModel(definition.model, false)
	attachWeapon(character, model, grip, definition.model.gripOffset)
	local trail = addTrail(model, definition.model, accentColor or Color3.fromRGB(220, 235, 255))

	local offhand: Model? = nil
	if definition.model.mirrored then
		local leftGrip = findGrip(character, true)
		if leftGrip then
			offhand = buildWeaponModel(definition.model, true)
			attachWeapon(character, offhand :: Model, leftGrip, definition.model.gripOffset)
		end
	end

	equipped[character] = { model = model, offhand = offhand, trail = trail, weaponId = weaponId }

	character:SetAttribute("WeaponId", weaponId)
	return true
end

function WeaponService.Unequip(character: Model)
	local current = equipped[character]
	if not current then
		return
	end
	current.model:Destroy()
	if current.offhand then
		current.offhand:Destroy()
	end
	equipped[character] = nil
	character:SetAttribute("WeaponId", nil)
end

--- Toggled by CombatService for the exact duration a hitbox is open.
function WeaponService.SetTrailEnabled(character: Model, enabled: boolean)
	local current = equipped[character]
	if current and current.trail then
		current.trail.Enabled = enabled
	end
end

function WeaponService.GetEquippedId(character: Model): string?
	local current = equipped[character]
	return current and current.weaponId or nil
end

--------------------------------------------------------------------------------
-- Enemy weapons
--
-- Enemies carry visible weapons because a silhouette holding something reads as
-- dangerous, and because you should be able to tell what an enemy's reach is by
-- looking at it. These are simpler than player weapons: one shape, no trail.
--------------------------------------------------------------------------------

local ENEMY_WEAPONS: { [string]: any } = {
	Marchman = { name = "Falchion", size = Vector3.new(0.24, 3.2, 0.1), color = Color3.fromRGB(140, 148, 160), material = Enum.Material.Metal },
	Cutter = { name = "Knife", size = Vector3.new(0.16, 1.6, 0.08), color = Color3.fromRGB(200, 206, 218), material = Enum.Material.Metal },
	Bulwark = { name = "Shield", size = Vector3.new(2.6, 3.4, 0.4), color = Color3.fromRGB(70, 84, 92), material = Enum.Material.Metal, leftHand = true },
	Fletcher = { name = "Bow", size = Vector3.new(0.18, 3.6, 0.5), color = Color3.fromRGB(72, 58, 46), material = Enum.Material.Wood },
	Drudge = { name = "Maul", size = Vector3.new(1.4, 4.4, 1.4), color = Color3.fromRGB(58, 62, 70), material = Enum.Material.Slate },
	Vesper = nil,
	Censer = { name = "Censer", size = Vector3.new(0.9, 0.9, 0.9), color = Color3.fromRGB(255, 122, 48), material = Enum.Material.Neon },
	Tallier = { name = "Greatsword", size = Vector3.new(0.32, 5.0, 0.14), color = Color3.fromRGB(210, 190, 150), material = Enum.Material.Metal },
}

function WeaponService.EquipEnemyWeapon(character: Model, enemyId: string, scale: number)
	local spec = ENEMY_WEAPONS[enemyId]
	if not spec then
		return
	end

	local grip = findGrip(character, spec.leftHand == true)
	if not grip then
		return
	end

	local part = PartFactory.Part({
		Name = spec.name,
		Size = spec.size * scale,
		Color = spec.color,
		Material = spec.material,
		Anchored = false,
		CanCollide = false,
		CanQuery = false,
	})
	part.Massless = true
	part.CollisionGroup = GameConfig.Collision.Hitbox
	part.CFrame = grip.CFrame * CFrame.new(0, -1 * scale, 0) * CFrame.Angles(math.rad(-90), 0, 0)
		* CFrame.new(0, spec.size.Y * 0.4 * scale, 0)
	part.Parent = character
	PartFactory.Weld(grip, part, part)
end

--------------------------------------------------------------------------------

function WeaponService.Init(services: any)
	registry = services
end

return WeaponService
