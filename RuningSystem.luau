local player = game.Players.LocalPlayer
local character = player.Character or player.CharacterAdded:Wait()
local humanoid = character:WaitForChild("Humanoid", 10)
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CameraShake = require(script:WaitForChild("CameraShakeRun"))
CameraShake:Initialize(workspace.CurrentCamera, character)

local StatPlayer = player:WaitForChild("StatPlayer", 10)
if not StatPlayer then warn("⚠️ Không tìm thấy StatPlayer!") return end

local RunSystem = StatPlayer:WaitForChild("RunSystem", 10)
if not RunSystem then warn("⚠️ Không tìm thấy RunSystem!") return end

local CrouchSystem = StatPlayer:WaitForChild("CrouchSystem", 10)
if not CrouchSystem then warn("⚠️ Không tìm thấy CrouchSystem!") return end

-- ============================================
-- CONSTANTS - Định nghĩa các hằng số
-- ============================================
local STAMINA_HIGH_THRESHOLD = 0.6
local STAMINA_WARNING_THRESHOLD = 0.2
local STAMINA_LOW_THRESHOLD = 0.1
local STAMINA_CRITICAL_THRESHOLD = 0.05

local HUNGER_WARNING_THRESHOLD = 0.6
local HUNGER_LOW_THRESHOLD = 0.3

local UPDATE_INTERVAL = 0.033 -- ~30 FPS thay vì 60 FPS
local COLOR_UPDATE_THRESHOLD = 0.01

-- Speed constants
local NORMAL_RUN_SPEED = 16
local MAX_RUN_SPEED = 100
local MIN_RUN_SPEED = 20
local BACKWARD_SPEED_PENALTY = 0.15 -- 15% penalty khi chạy lùi
local runningState = false

-- ============================================
-- CROUCH SYSTEM - Lấy ValueObject từ CrouchSystem (server-driven)
-- ============================================
local CrouchSystemEnabled = CrouchSystem -- BoolValue gốc, true/false để biết hệ thống ngồi có được bật không
local IsCrouchingValue = CrouchSystem:WaitForChild("IsCrouching", 10)
local CrouchButtonValue = CrouchSystem:WaitForChild("CrouchButton", 10)
local CrouchSpeedValue = CrouchSystem:WaitForChild("CrouchSpeed", 10)
local CrouchBuffSpeedValue = CrouchSpeedValue:WaitForChild("BuffSpeed", 10)
local IsSlidingValue = CrouchSystem:WaitForChild("IsSliding", 10)
local SlideSpeedMultiplierValue = CrouchSystem:WaitForChild("SlideSpeedMultiplier", 10)
local SlideTweenTimeValue = CrouchSystem:WaitForChild("SlideTweenTime", 10)
local SlideTimeLeftValue = CrouchSystem:WaitForChild("SlideTimeLeft", 10)

local CROUCH_HIP_HEIGHT_OFFSET = -1.5 -- Giảm HipHeight bao nhiêu khi crouch (tùy chỉnh theo rig, chỉ dùng cho tween mượt phía client - server đã set giá trị thật)
local CROUCH_TWEEN_TIME = 0.15 -- Thời gian tween chuyển HipHeight cho mượt

-- Camera offset khi crouch: RenderStepped lerp CameraOffset.Y xuống cùng body, không bị tách
local CROUCH_CAM_OFFSET_Y = -1.2  -- studs camera dịch xuống khi ngồi (chỉnh theo cảm giác)
local currentCamOffsetY   = 0     -- giá trị đang lerp hiện tại
local targetCamOffsetY    = 0     -- đích đến (0 = đứng, CROUCH_CAM_OFFSET_Y = ngồi)
local CAM_LERP_SPEED      = 10    -- tốc độ lerp (frame-rate independent, nhân dt)

-- Tốc độ crouch lấy ĐỘNG từ server (CrouchSpeed + BuffSpeed), luôn cập nhật theo giá trị mới nhất
local function getCrouchWalkSpeed()
	return CrouchSpeedValue.Value + (CrouchBuffSpeedValue and CrouchBuffSpeedValue.Value or 0)
end

-- Phím dùng để crouch. Giữ bảng cứng làm fallback, đồng thời luôn cộng thêm
-- phím CrouchButton.Value lấy từ server (cho phép đổi phím qua Stat mà không cần sửa script này)
local CROUCH_KEYS = {
	[Enum.KeyCode.LeftControl] = true,
	[Enum.KeyCode.RightControl] = true,
	[Enum.KeyCode.C] = true,
	[Enum.KeyCode.Space] = true,
}
local spaceReservedForOtherSystem = false -- đổi thành true khi Space được gán việc khác

-- NEW: Thêm CrouchButton.Value (StringValue, ví dụ "LeftControl") vào bảng CROUCH_KEYS động
local function syncCrouchButtonKey()
	local keyName = CrouchButtonValue.Value
	local keyCode = keyName and Enum.KeyCode[keyName]
	if keyCode then
		CROUCH_KEYS[keyCode] = true
	end
end
syncCrouchButtonKey()
CrouchButtonValue.Changed:Connect(syncCrouchButtonKey)

local IsRunning = RunSystem:WaitForChild("IsRunning", 10)

local RemoteFolder = game.ReplicatedStorage:FindFirstChild("GameSettingUp"):WaitForChild("RunSystemRemotes")
local ToggleRunEvent = RemoteFolder:WaitForChild("ToggleRun")
local ToggleCrouchEvent = RemoteFolder:WaitForChild("ToggleCrouch")
local StartSlideEvent = RemoteFolder:WaitForChild("StartSlide")


local animate = character:FindFirstChild("Animate")
if animate then
	animate.Disabled = true
end

local Animations = {
	Idle = "rbxassetid://132976491477475",
	Walk = "rbxassetid://137525931066936",
	Run1 = "rbxassetid://127141523108050",
	Run2 = "rbxassetid://77422242797905",
	Run3 = "rbxassetid://106436421066722",
	WalkExhaust = "rbxassetid://137525931066936", ------------------
	Jump = "rbxassetid://126042426494917",
	Fall = "rbxassetid://126042426494917", -----------------...------
	CrouchIdle = "rbxassetid://114458643957621", -- TODO: điền AnimationId crouch đứng yên
	CrouchWalk = "rbxassetid://111700207896375", -- TODO: điền AnimationId crouch di chuyển
	Slide = "rbxassetid://85891833309857", -- TODO: điền AnimationId trượt (slide), fallback về CrouchWalk nếu chưa có
}

-- looped = true  : animation lặp vô tận (đi, chạy, idle...)
-- looped = false : animation chỉ phát 1 lần rồi giữ frame cuối (slide, jump, fall...)
local function loadAnimation(id, looped)
	if not id or id == "" then return nil end

	local anim = Instance.new("Animation")
	anim.AnimationId = id

	local track = humanoid:LoadAnimation(anim)
	track.Priority = Enum.AnimationPriority.Movement
	track.Looped = (looped ~= false) -- mặc định loop, truyền false để phát 1 lần

	return track
end

local Tracks = {
	Idle        = loadAnimation(Animations.Idle,        true),
	Walk        = loadAnimation(Animations.Walk,        true),
	Run1        = loadAnimation(Animations.Run1,        true),
	Run2        = loadAnimation(Animations.Run2,        true),
	Run3        = loadAnimation(Animations.Run3,        true),
	WalkExhaust = loadAnimation(Animations.WalkExhaust, true),
	Jump        = loadAnimation(Animations.Jump,        false), -- phát 1 lần, giữ frame cuối
	Fall        = loadAnimation(Animations.Fall,        false), -- phát 1 lần, giữ frame cuối
	CrouchIdle  = loadAnimation(Animations.CrouchIdle,  true),  -- loop giữ tư thế ngồi
	CrouchWalk  = loadAnimation(Animations.CrouchWalk,  true),  -- loop đi khi ngồi
	Slide       = loadAnimation(Animations.Slide,       false), -- phát 1 lần rồi giữ
}

local currentTrack = nil

local function playTrack(track)
	if not track then return end
	if currentTrack == track then
		-- Cùng track: nếu không loop và đang play -> giữ nguyên (không restart)
		-- nếu loop -> cũng đang chạy rồi, không cần làm gì
		return
	end

	-- Fade out track cũ — KHÔNG destroy/clear, chỉ stop nhẹ
	if currentTrack and currentTrack.IsPlaying then
		currentTrack:Stop(0.15)
	end

	currentTrack = track

	if not track.Looped then
		-- Chỉ phát nếu chưa chạy hoặc đã kết thúc; giữ frame cuối nếu đang giữa chừng
		if not track.IsPlaying then
			track:Play(0.1)
		end
	else
		track:Play(0.15)
	end
end

-- ============================================
-- CLEANUP HELPERS - khai báo trước để Crouch System dùng được
-- ============================================
local Connections = {}
local ActiveTweens = {}

local function addConnection(connection)
	table.insert(Connections, connection)
	return connection
end

local function createTween(instance, tweenInfo, properties)
	local tween = TweenService:Create(instance, tweenInfo, properties)
	table.insert(ActiveTweens, tween)
	return tween
end

-- ============================================
-- CROUCH SYSTEM
-- ============================================
local PhysicsService = game:GetService("PhysicsService")

local wasRunning = false

local function isShiftHeld()
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

local isCrouching = false
local originalHipHeight = humanoid.HipHeight
local originalWalkSpeed = humanoid.WalkSpeed

-- Tạo CollisionGroup (an toàn nếu đã tồn tại từ trước, Roblox sẽ throw warning chứ không lỗi)
local function ensureCollisionGroup(name)
	local ok = pcall(function()
		PhysicsService:RegisterCollisionGroup(name)
	end)
	return ok
end

ensureCollisionGroup("NoCollideArms")
ensureCollisionGroup("NoCollideHead")
ensureCollisionGroup("NoCollideUpper") -- R6: bao gồm Head + Torso phần trên khi ngồi

pcall(function()
	PhysicsService:CollisionGroupSetCollidable("NoCollideArms",  "Default", false)
	PhysicsService:CollisionGroupSetCollidable("NoCollideHead",  "Default", false)
	PhysicsService:CollisionGroupSetCollidable("NoCollideUpper", "Default", false)
end)

-- Gom các part Head / Arm theo cả R15 và R6
local function getHeadParts()
	local parts = {}
	-- R6: Head là part riêng, nhưng va chạm thực tế của phần trên body ở R6
	-- chủ yếu đến từ Head và Upper Torso (không có part riêng)
	-- → thêm cả HumanoidRootPart để tắt va chạm phần thân trên khi ngồi
	local head = character:FindFirstChild("Head")
	if head then table.insert(parts, head) end
	return parts
end

-- Parts "phần trên" của R6 cần NoCollide khi crouch để không vướng trần/tường phía trên
local function getUpperBodyParts()
	local parts = {}
	-- R6: Head + Upper Torso (trong R6 Torso là 1 part lớn, lấy cả Head)
	local head   = character:FindFirstChild("Head")
	local torso  = character:FindFirstChild("Torso") -- R6
	local uTorso = character:FindFirstChild("UpperTorso") -- R15
	if head   then table.insert(parts, head)   end
	if torso  then table.insert(parts, torso)  end
	if uTorso then table.insert(parts, uTorso) end
	return parts
end

local function getArmParts()
	local parts = {}
	local names = {
		"Left Arm", "Right Arm", -- R6
		"LeftUpperArm", "LeftLowerArm", "LeftHand", -- R15
		"RightUpperArm", "RightLowerArm", "RightHand", -- R15
	}
	for _, n in ipairs(names) do
		local part = character:FindFirstChild(n)
		if part then table.insert(parts, part) end
	end
	return parts
end

local headParts = getHeadParts()
local armParts = getArmParts()

local function setPartsCollisionGroup(parts, groupName)
	for _, part in ipairs(parts) do
		if part:IsA("BasePart") then
			part.CollisionGroup = groupName
		end
	end
end

-- Cập nhật CollisionGroup theo bảng đã thống nhất:
-- Đứng/Đi/Chạy (không crouch): Arms NoCollide, Head Default
-- Crouch (không di chuyển): Head NoCollide, Arms Default
-- Crouch + di chuyển: cả Head và Arms NoCollide
local function updateCollisionGroups()
	local moving = humanoid.MoveDirection.Magnitude > 0.1

	if isCrouching then
		setPartsCollisionGroup(headParts, "NoCollideHead")
		if moving then
			setPartsCollisionGroup(armParts, "NoCollideArms")
		else
			setPartsCollisionGroup(armParts, "Default")
		end
	else
		setPartsCollisionGroup(headParts, "Default")
		setPartsCollisionGroup(armParts, "NoCollideArms")
	end
end

local isSliding = false

local function setCrouchState(crouching)
	if isCrouching == crouching then return end

	if crouching then
		-- NEW: Nếu đang thực sự chạy (Run) -> kích hoạt SLIDE thay vì crouch thẳng
		if wasRunning then
			isCrouching = true
			isSliding = true
			targetCamOffsetY = CROUCH_CAM_OFFSET_Y  -- camera đi xuống cùng body
			StartSlideEvent:FireServer()

			-- Local dự đoán nhanh HipHeight cho mượt (server cũng set lại giá trị thật ngay khi nhận event)
			local targetHipHeight = originalHipHeight + CROUCH_HIP_HEIGHT_OFFSET
			local hipTween = createTween(humanoid, TweenInfo.new(CROUCH_TWEEN_TIME, Enum.EasingStyle.Quad), {
				HipHeight = math.max(targetHipHeight, 0)
			})
			hipTween:Play()

			-- KHÔNG tự set WalkSpeed ở đây: server quyết định tốc độ trượt (x1.9 -> giảm dần) qua updateSlide loop,
			-- WalkSpeed sẽ được client nhận tự động vì Humanoid.WalkSpeed replicate từ server.

			wasRunning = false
			runningState = false
			if IsRunning then IsRunning.Value = false end
		else
			-- Crouch bình thường (không đang chạy)
			isCrouching = true
			targetCamOffsetY = CROUCH_CAM_OFFSET_Y  -- camera đi xuống cùng body
			ToggleCrouchEvent:FireServer(true)

			local targetHipHeight = originalHipHeight + CROUCH_HIP_HEIGHT_OFFSET
			local hipTween = createTween(humanoid, TweenInfo.new(CROUCH_TWEEN_TIME, Enum.EasingStyle.Quad), {
				HipHeight = math.max(targetHipHeight, 0)
			})
			hipTween:Play()

			humanoid.WalkSpeed = getCrouchWalkSpeed()
		end
	else
		-- Không cho đứng lên giữa lúc đang Slide; chờ server tự kết thúc slide rồi mới cho đứng
		if isSliding or IsSlidingValue.Value then
			return
		end

		-- CEILING CHECK: Raycast phía trên head, nếu có vật cản thì KHÔNG cho đứng dậy
		-- Tránh xuyên tường/trần khi buông phím ngồi
		local rootPart2 = character:FindFirstChild("HumanoidRootPart")
		if rootPart2 then
			local standUpHeight = originalHipHeight - humanoid.HipHeight + 0.5 -- khoảng cần thêm để đứng thẳng
			local ceilParams = RaycastParams.new()
			ceilParams.FilterType = Enum.RaycastFilterType.Exclude
			ceilParams.FilterDescendantsInstances = { character }
			local ceilOrigin = rootPart2.Position
			local ceilResult = workspace:Raycast(ceilOrigin, Vector3.new(0, standUpHeight + 0.8, 0), ceilParams)
			if ceilResult then
				-- Có trần/vật cản bên trên → không đứng dậy, giữ nguyên trạng thái ngồi
				return
			end
		end

		isCrouching = false
		targetCamOffsetY = 0  -- camera tween trở về vị trí bình thường
		ToggleCrouchEvent:FireServer(false)

		-- Hết crouch
		local hipTween = createTween(humanoid, TweenInfo.new(CROUCH_TWEEN_TIME, Enum.EasingStyle.Quad), {
			HipHeight = originalHipHeight
		})
		hipTween:Play()

		humanoid.WalkSpeed = originalWalkSpeed -- baseline đi bộ; nếu Shift vẫn giữ, server override ngay dưới

		if isShiftHeld() and humanoid.MoveDirection.Magnitude > 0.1 then
			-- Shift vẫn đang giữ VÀ đang thực sự di chuyển từ lúc crouch tới giờ
			-- -> bắn Run ngay, bỏ qua khoảng đi bộ, để server tự set/tween tốc độ chạy đúng chuẩn
			ToggleRunEvent:FireServer(true)
			wasRunning = true
			runningState = true
			if IsRunning then IsRunning.Value = true end
		end
	end

	-- Tắt nhảy khi đang crouch (đúng yêu cầu: giữ Space để cúi thì không nhảy)
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, not crouching)

	updateCollisionGroups()
end

-- NEW: Đồng bộ isSliding local theo server, để khi server tự tắt IsSliding (slide kết thúc tự nhiên)
-- thì client cập nhật lại trạng thái đúng (vẫn coi là đang Crouch, không phải Slide nữa)
IsSlidingValue.Changed:Connect(function(value)
	isSliding = value
	if not value and isCrouching then
		-- Slide vừa kết thúc, WalkSpeed đã được server set = CrouchSpeed, không cần làm gì thêm ở client
		updateCollisionGroups()
	end
end)

-- NEW: Đồng bộ isCrouching local nếu server tự đổi (ví dụ lock CrouchSystem từ admin)
IsCrouchingValue.Changed:Connect(function(value)
	if isCrouching ~= value then
		isCrouching = value
		updateCollisionGroups()
	end
end)

-- Khởi tạo CollisionGroup ngay từ đầu (Arms NoCollide kể cả khi chưa crouch lần nào)
updateCollisionGroups()

-- ============================================
-- CROUCH RESPAWN HANDLING
-- Script này nằm trong StarterGui nên KHÔNG tự re-run khi respawn.
-- Chỉ refresh phần dữ liệu mà Crouch System cần, không động tới
-- animate/stamina/CameraShake (các hệ thống đó nằm ngoài phạm vi này).
-- ============================================
addConnection(player.CharacterAdded:Connect(function(newCharacter)
	character = newCharacter
	humanoid = newCharacter:WaitForChild("Humanoid", 10)
	if not humanoid then return end

	-- Reset trạng thái crouch cho lần spawn mới
	isCrouching = false
	isSliding = false
	originalHipHeight = humanoid.HipHeight
	originalWalkSpeed = humanoid.WalkSpeed

	headParts = getHeadParts()
	armParts = getArmParts()

	-- Set CollisionGroup mặc định (không crouch) cho character mới
	updateCollisionGroups()
end))

local function isCrouchKeyHeld()
	for keyCode in pairs(CROUCH_KEYS) do
		local isSpaceButReserved = (keyCode == Enum.KeyCode.Space and spaceReservedForOtherSystem)
		if not isSpaceButReserved and UserInputService:IsKeyDown(keyCode) then
			return true
		end
	end
	return false
end

local function updateAnimation()
	if not humanoid then return end

	local moveDirection = humanoid.MoveDirection.Magnitude
	local staminaPercent = RunSystem.FatigueLevel.Value / RunSystem.MaxFatigue.Value
	local isRunning = runningState
	local isExhausted = RunSystem.Exhausted.Value

	-- Slide (ưu tiên cao nhất trong nhóm crouch, vì đây là trạng thái chuyển tiếp ngắn)
	if isCrouching and isSliding then
		playTrack(Tracks.Slide or Tracks.CrouchWalk or Tracks.Walk)
		return
	end

	-- Crouch (ưu tiên trước Jump/Fall vì lúc crouch không nhảy được)
	if isCrouching then
		if moveDirection < 0.1 then
			playTrack(Tracks.CrouchIdle or Tracks.Idle)
		else
			playTrack(Tracks.CrouchWalk or Tracks.Walk)
		end
		return
	end

	-- Jump
	if humanoid:GetState() == Enum.HumanoidStateType.Jumping then
		playTrack(Tracks.Jump)
		return
	end

	-- Fall
	if humanoid:GetState() == Enum.HumanoidStateType.Freefall then
		playTrack(Tracks.Fall)
		return
	end

	-- Không di chuyển
	if moveDirection < 0.1 then
		playTrack(Tracks.Idle)
		return
	end

	-- Exhaust walk
	if isExhausted then
		playTrack(Tracks.WalkExhaust or Tracks.Walk)
		return
	end

	-- Running
	if isRunning then
		if staminaPercent > 0.75 then
			playTrack(Tracks.Run2 or Tracks.Run1 or Tracks.Run3)
		elseif staminaPercent > 0.5 then
			playTrack(Tracks.Run1 or Tracks.Run3)
		else
			playTrack(Tracks.Run3)
		end
	else
		playTrack(Tracks.Walk)
	end
end

RunService.RenderStepped:Connect(function()
	updateAnimation()
end)



-- ============================================
-- CLEANUP SYSTEM - cleanup() dùng Connections/ActiveTweens
-- (đã khai báo ở phía trên, trước phần Crouch System)
-- ============================================
local function cleanup()
	-- Disconnect all connections
	for _, conn in ipairs(Connections) do
		if conn and conn.Connected then
			conn:Disconnect()
		end
	end
	Connections = {}

	-- Stop all tweens
	for _, tween in ipairs(ActiveTweens) do
		if tween then
			tween:Cancel()
		end
	end
	ActiveTweens = {}
end

-- Cleanup khi script bị destroy
script.AncestryChanged:Connect(function()
	if not script:IsDescendantOf(game) then
		cleanup()
	end
end)

-- ============================================
-- LOCAL CÁC FRAME CỦA BẠN
-- ============================================
local container = script.Parent.RunSystemGui

-- STAMINA
local staminaLabel = container:WaitForChild("staminaLabel")
local staminaBarFrame = container:WaitForChild("Staminabar"):WaitForChild("Camstaminagroup")
local staminaBar = staminaBarFrame.Stamina

local staminaUIFrame = staminaBar:FindFirstChild("UIFrame")
if not staminaUIFrame then 
	warn("⚠️ UIFrame không tồn tại trong staminaBar")
	return 
end
local staminaGradient = staminaUIFrame:WaitForChild("UIGradient", 5)
if not staminaGradient then
	warn("⚠️ UIGradient không tồn tại trong Stamina")
	return
end

-- HUNGER
local hungerLabel = container:WaitForChild("HungryBar").Hungrylabel
local hungerBarFrame = container:WaitForChild("HungryBar"):WaitForChild("CamHungrygroup")
local hungerBar = hungerBarFrame.Hungry
local hungerBg = container:WaitForChild("HungryBar")

local hungerUIFrame = hungerBar:FindFirstChild("UIFrame")
if not hungerUIFrame then 
	warn("⚠️ UIFrame không tồn tại trong hungerBar")
	return 
end
local hungerGradient = hungerUIFrame:WaitForChild("UIGradient", 5)
if not hungerGradient then
	warn("⚠️ UIGradient không tồn tại trong Hunger")
	return
end

-- Store original hunger color
local originalHungerColor = hungerBar.BackgroundColor3

-- FATIGUE
local fatigueLabel = container:WaitForChild("fatigueBar").fatiguelevel
local fatigueBar = container:WaitForChild("fatigueBar"):WaitForChild("Camfatiguegroup").fatigue

-- ============================================
-- HÀM CẬP NHẬT THANH BAR
-- ============================================
local function updateBar(bar, currentValue, maxValue)
	local percent = math.clamp(currentValue / maxValue, 0, 1)
	local tween = createTween(bar, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
		Size = UDim2.new(percent, 0, 1, 0)
	})
	tween:Play()
end

-- ============================================
-- STAMINA - SHINY TWEEN
-- ============================================
local staminaShinyActive = false
local staminaShinyLoop = nil

local function startStaminaShiny(fast)
	if staminaShinyActive and not fast then return end
	staminaShinyActive = true
	staminaGradient.Parent.Visible = true

	local speed = fast and 0.4 or 1.2

	local function loopTween()
		if not staminaShinyActive then
			staminaGradient.Parent.Visible = false
			staminaGradient.Offset = Vector2.new(-1, -1)
			return
		end

		staminaGradient.Offset = Vector2.new(-1, -1)
		local tween = createTween(staminaGradient, TweenInfo.new(speed, Enum.EasingStyle.Linear), {
			Offset = Vector2.new(1, 1)
		})
		tween:Play()

		local conn
		conn = tween.Completed:Connect(function()
			if conn then conn:Disconnect() end
			if staminaShinyActive then
				task.wait(0.05)
				loopTween()
			else
				staminaGradient.Parent.Visible = false
				staminaGradient.Offset = Vector2.new(-1, -1)
			end
		end)
		addConnection(conn)
	end

	loopTween()
end

local function stopStaminaShiny()
	staminaGradient.Parent.Visible = false
	staminaShinyActive = false
end

-- ============================================
-- STAMINA - EXHAUSTED NHẤP NHÁY
-- ============================================
local exhaustBlinkActive = false

local function startExhaustBlink()
	if exhaustBlinkActive then return end
	exhaustBlinkActive = true

	local function blinkLoop()
		if not exhaustBlinkActive then
			staminaBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			return
		end

		local t1 = createTween(staminaBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
			BackgroundColor3 = Color3.fromRGB(180, 0, 0)
		})
		t1:Play()

		local conn1
		conn1 = t1.Completed:Connect(function()
			if conn1 then conn1:Disconnect() end
			if not exhaustBlinkActive then
				staminaBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
				return
			end

			local t2 = createTween(staminaBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
				BackgroundColor3 = Color3.fromRGB(20, 0, 0)
			})
			t2:Play()

			local conn2
			conn2 = t2.Completed:Connect(function()
				if conn2 then conn2:Disconnect() end
				task.wait(0.05)
				blinkLoop()
			end)
			addConnection(conn2)
		end)
		addConnection(conn1)
	end

	blinkLoop()
end

local function stopExhaustBlink()
	exhaustBlinkActive = false
	-- Reset về màu bình thường
	staminaBar.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
end

-- ============================================
-- STAMINA - MÀU THEO PHẦN TRĂM (FIXED)
-- ============================================
local lastStaminaPercent = 1
local lastStaminaColor = Color3.fromRGB(255, 255, 255)

local function updateStaminaColor(percent)
	if exhaustBlinkActive then return end

	local targetColor
	if percent > STAMINA_HIGH_THRESHOLD then
		targetColor = Color3.fromRGB(255, 255, 255)
	elseif percent > STAMINA_WARNING_THRESHOLD then
		local t = (STAMINA_HIGH_THRESHOLD - percent) / (STAMINA_HIGH_THRESHOLD - STAMINA_WARNING_THRESHOLD)
		targetColor = Color3.fromRGB(255, 255, 255):Lerp(Color3.fromRGB(255, 120, 0), t)
	else
		local t = (STAMINA_WARNING_THRESHOLD - percent) / STAMINA_WARNING_THRESHOLD
		targetColor = Color3.fromRGB(255, 120, 0):Lerp(Color3.fromRGB(200, 0, 0), t)
	end

	-- Luôn tween màu về target color (FIX: màu không tween lại)
	local colorDistance = (targetColor.R - lastStaminaColor.R)^2 + 
		(targetColor.G - lastStaminaColor.G)^2 + 
		(targetColor.B - lastStaminaColor.B)^2

	if colorDistance > 0.001 then
		local tween = createTween(staminaBar, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
			BackgroundColor3 = targetColor
		})
		tween:Play()
		lastStaminaColor = targetColor
	end

	lastStaminaPercent = percent
end

-- ============================================
-- HUNGER - SHINY TWEEN
-- ============================================
local hungerShinyActive = false

local function startHungerShiny()
	if hungerShinyActive then return end
	hungerShinyActive = true
	hungerGradient.Parent.Visible = true

	local function loopTween()
		if not hungerShinyActive then
			hungerGradient.Parent.Visible = false
			hungerGradient.Offset = Vector2.new(-1, -1)
			return
		end

		hungerGradient.Offset = Vector2.new(-1, -1)
		local tween = createTween(hungerGradient, TweenInfo.new(1.5, Enum.EasingStyle.Linear), {
			Offset = Vector2.new(1, 1)
		})
		tween:Play()

		local conn
		conn = tween.Completed:Connect(function()
			if conn then conn:Disconnect() end
			if hungerShinyActive then
				task.wait(0.05)
				loopTween()
			else
				hungerGradient.Parent.Visible = false
				hungerGradient.Offset = Vector2.new(-1, -1)
			end
		end)
		addConnection(conn)
	end

	loopTween()
end

local function stopHungerShiny()
	hungerShinyActive = false
	hungerGradient.Parent.Visible = false
end

-- ============================================
-- HUNGER - MÀU THEO PHẦN TRĂM (FIXED)
-- ============================================
local lastHungerPercent = 1
local lastHungerColor = originalHungerColor

local function updateHungerColor(percent)
	local targetColor
	local shouldShiny = false

	if percent > HUNGER_WARNING_THRESHOLD then
		-- Trở về màu gốc
		targetColor = originalHungerColor
		shouldShiny = false
	elseif percent > HUNGER_LOW_THRESHOLD then
		-- Lerp sang nâu
		local t = (HUNGER_WARNING_THRESHOLD - percent) / (HUNGER_WARNING_THRESHOLD - HUNGER_LOW_THRESHOLD)
		targetColor = originalHungerColor:Lerp(Color3.fromRGB(101, 67, 33), t)
		shouldShiny = true
	else
		-- Lerp nâu sang đen xanh rêu đậm
		local t = (HUNGER_LOW_THRESHOLD - percent) / HUNGER_LOW_THRESHOLD
		targetColor = Color3.fromRGB(101, 67, 33):Lerp(Color3.fromRGB(20, 40, 10), t)
		shouldShiny = true
	end

	-- Quản lý shiny effect
	if shouldShiny then
		startHungerShiny()
	else
		stopHungerShiny()
	end

	-- Luôn tween màu về target color (FIX: màu không tween lại)
	local colorDistance = (targetColor.R - lastHungerColor.R)^2 + 
		(targetColor.G - lastHungerColor.G)^2 + 
		(targetColor.B - lastHungerColor.B)^2

	if colorDistance > 0.001 then
		local tween = createTween(hungerBar, TweenInfo.new(0.5, Enum.EasingStyle.Quad), {
			BackgroundColor3 = targetColor
		})
		tween:Play()
		lastHungerColor = targetColor
	end

	lastHungerPercent = percent
end

-- ============================================
-- FATIGUE LEVEL SYSTEM - IMPROVED WITH TRANSPARENCY
-- ============================================
local levelFrame = container:WaitForChild("fatigueBar").Level

local baseColors = {
	Color3.fromRGB(255, 203, 73),
	Color3.fromRGB(255, 160, 76),
	Color3.fromRGB(255, 88, 55),
	Color3.fromRGB(255, 0, 0),
	Color3.fromRGB(177, 0, 0),
}

local basePercentColors = {
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(255, 210, 147),
	Color3.fromRGB(255, 195, 180),
	Color3.fromRGB(255, 150, 150),
	Color3.fromRGB(255, 100, 100),
}

local function getGradientColor(colors, index, total)
	if total <= 1 then return colors[1] end

	local t = (index - 1) / (total - 1)
	local pos = t * (#colors - 1) + 1
	local lower = math.floor(pos)
	local upper = math.min(lower + 1, #colors)

	if lower == upper then return colors[lower] end

	return colors[lower]:Lerp(colors[upper], pos - lower)
end

-- Lấy và sắp xếp buttons
local levelButtons = {}
for _, child in ipairs(levelFrame:GetChildren()) do
	if child:IsA("TextButton") or child:IsA("Frame") or child:IsA("ImageButton") then
		table.insert(levelButtons, child)
	end
end

table.sort(levelButtons, function(a, b)
	local numA = tonumber(a.Name:match("%d+")) or 0
	local numB = tonumber(b.Name:match("%d+")) or 0
	return numA < numB
end)

local levelCount = #levelButtons
local percentPerLevel = 1 / levelCount

local levelColors = {}
local percentColors = {}
for i = 1, levelCount do
	levelColors[i] = getGradientColor(baseColors, i, levelCount)
	percentColors[i] = getGradientColor(basePercentColors, i, levelCount)
end

local lastButtonTransparencies = {}
local lastButtonColors = {}
for i = 1, levelCount do
	lastButtonTransparencies[i] = 1
	lastButtonColors[i] = Color3.new(0, 0, 0)
end

-- ============================================
-- FATIGUE LEVELS UPDATE - FIXED TRANSPARENCY
-- ============================================
local function updateFatigueLevels(fatiguePercent)
	local displayPercent = math.floor(fatiguePercent * 100)

	for i, button in ipairs(levelButtons) do
		-- % bắt đầu và kết thúc của level này
		local levelStart = (i - 1) * percentPerLevel
		local levelEnd = i * percentPerLevel

		-- Tính % fill trong level này (0 -> 1)
		-- FIX: Chia theo level, transparency theo % luôn
		local fillAmount = math.clamp(
			(fatiguePercent - levelStart) / percentPerLevel,
			0, 1
		)

		-- NEW: Transparency tuyến tính theo fillAmount
		-- fillAmount = 0 -> transparency = 1 (ẩn)
		-- fillAmount = 1 -> transparency = 0 (hiện đầy)
		local targetTransparency = 1 - fillAmount

		-- Màu động dựa trên fill amount
		local levelColor = levelColors[i]
		local targetColor

		if fillAmount < 0.3 then
			-- Màu tối khi chưa đầy
			targetColor = levelColor:Lerp(Color3.fromRGB(50, 50, 50), 0.7)
		elseif fillAmount < 0.7 then
			-- Transition sang màu sáng
			local t = (fillAmount - 0.3) / 0.4
			local darkColor = levelColor:Lerp(Color3.fromRGB(50, 50, 50), 0.7)
			targetColor = darkColor:Lerp(levelColor, t)
		else
			-- Màu đầy sáng rực
			local t = (fillAmount - 0.7) / 0.3
			targetColor = levelColor:Lerp(levelColor:Lerp(Color3.fromRGB(255, 255, 255), 0.2), t)
		end

		-- Tween transparency
		if math.abs(targetTransparency - lastButtonTransparencies[i]) > 0.02 then
			local tween = createTween(button, TweenInfo.new(0.4, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
				BackgroundTransparency = targetTransparency
			})
			tween:Play()
			lastButtonTransparencies[i] = targetTransparency
		end

		-- Tween màu
		local colorDiff = (targetColor.R - lastButtonColors[i].R)^2 + 
			(targetColor.G - lastButtonColors[i].G)^2 + 
			(targetColor.B - lastButtonColors[i].B)^2

		if colorDiff > 0.001 then
			local tween = createTween(button, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
				BackgroundColor3 = targetColor
			})
			tween:Play()
			lastButtonColors[i] = targetColor
		end

		-- Text với RichText
		local textLabel = button:FindFirstChildWhichIsA("TextLabel")
		if textLabel then
			local percentColor = percentColors[i]
			textLabel.RichText = true
			textLabel.Text = string.format(
				'<font color="rgb(%d,%d,%d)">Level %d</font> <font color="rgb(%d,%d,%d)">(%02d%%)</font>',
				math.floor(levelColor.R * 255),
				math.floor(levelColor.G * 255),
				math.floor(levelColor.B * 255),
				i,
				math.floor(percentColor.R * 255),
				math.floor(percentColor.G * 255),
				math.floor(percentColor.B * 255),
				displayPercent
			)
		end

		-- OldFrame - chỉ hiện khi level đầy (fillAmount >= 0.98)
		local oldFrame = button:FindFirstChild("OldFrame")
		if oldFrame then
			if fillAmount >= 0.98 then
				if not oldFrame.Visible then
					oldFrame.Visible = true
					oldFrame.BackgroundTransparency = 1

					local pulseTween = createTween(oldFrame, 
						TweenInfo.new(0.6, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), 
						{BackgroundTransparency = 0.2}
					)
					pulseTween:Play()

					local originalSize = oldFrame.Size
					oldFrame.Size = UDim2.new(0.8, 0, 0.8, 0)
					local scaleTween = createTween(oldFrame, 
						TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), 
						{Size = originalSize}
					)
					scaleTween:Play()
				end
			else
				if oldFrame.Visible then
					local fadeTween = createTween(oldFrame, 
						TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In), 
						{BackgroundTransparency = 1}
					)
					fadeTween:Play()
					task.delay(0.3, function()
						if fillAmount < 0.98 then
							oldFrame.Visible = false
						end
					end)
				end
			end
		end
	end
end

-- ============================================
-- SPEED CALCULATION - NEW SYSTEM
-- ============================================
local function calculateRunSpeed(stamina, maxStamina, isBackward)
	local staminaPercent = stamina / maxStamina
	local speed = MAX_RUN_SPEED

	-- Nếu stamina > 10%: chạy bình thường
	if staminaPercent > STAMINA_LOW_THRESHOLD then
		speed = MAX_RUN_SPEED
	else
		-- Stamina <= 10%: giảm dần từ 100 -> 20
		-- Tính tỷ lệ giảm: 0% stamina = min speed, 10% stamina = max speed
		local t = staminaPercent / STAMINA_LOW_THRESHOLD -- 0 -> 1
		speed = MIN_RUN_SPEED + (MAX_RUN_SPEED - MIN_RUN_SPEED) * t
	end

	-- Áp dụng penalty khi chạy lùi
	if isBackward then
		speed = speed * (1 - BACKWARD_SPEED_PENALTY)
	end

	return math.floor(speed)
end

-- ============================================
-- TRẠNG THÁI
-- ============================================
local wasExhausted = false
local lastUpdateTime = 0
local lastFatigueValue = 0
local lastHungerValue = 0
local lastStaminaValue = 0

-- ============================================
-- CROUCH UPDATE LOOP - chạy riêng, không phụ thuộc UI throttle
-- ============================================
addConnection(RunService.RenderStepped:Connect(function()
	-- NEW: Nếu hệ thống Crouch đang bị tắt (CrouchSystem.Value == false), không cho ngồi
	-- và nếu đang ngồi từ trước mà hệ thống bị tắt giữa chừng, ép đứng lên ngay
	if not CrouchSystemEnabled.Value then
		if isCrouching then
			setCrouchState(false)
		end
		return
	end

	local shouldCrouch = isCrouchKeyHeld()
	setCrouchState(shouldCrouch)

	-- Khi đang crouch, trạng thái di chuyển có thể đổi giữa các frame
	-- (đứng yên <-> đi) nên cần update lại CollisionGroup theo MoveDirection
	if isCrouching then
		updateCollisionGroups()
	end
end))


-- ============================================
-- UPDATE LOOP - OPTIMIZED
-- ============================================
addConnection(RunService.RenderStepped:Connect(function()
	-- Throttle updates
	local now = tick()
	if now - lastUpdateTime < UPDATE_INTERVAL then return end
	lastUpdateTime = now

	if not RunSystem.Value then
		container.Visible = false
		return
	end
	container.Visible = true

	local stamina = RunSystem:FindFirstChild("Stamina")
	local maxStamina = RunSystem:FindFirstChild("MaxStamina")
	local buffStamina = maxStamina and maxStamina:FindFirstChild("BuffStamina")
	local exhausted = RunSystem:FindFirstChild("Exhausted")
	local speed = RunSystem:FindFirstChild("Speed")
	local fatigueLevel = RunSystem:FindFirstChild("FatigueLevel")
	local maxFatigue = RunSystem:FindFirstChild("MaxFatigue")
	local hungryEnabled = RunSystem:FindFirstChild("HungryEnabled")

	-- ============================================
	-- STAMINA
	-- ============================================
	if stamina and maxStamina then
		local actualMaxStamina = maxStamina.Value + (buffStamina and buffStamina.Value or 0)
		local staminaPercent = stamina.Value / actualMaxStamina

		-- FIX: Kiểm tra shift key thật sự + phải đang thực sự di chuyển (không chỉ giữ Shift đứng im) + không cho chạy khi đang crouch
		local isRunning = isShiftHeld()
			and stamina
			and maxStamina
			and stamina.Value > 0
			and not (exhausted and exhausted.Value)
			and not isCrouching
			and humanoid.MoveDirection.Magnitude > 0.1

		if isRunning ~= wasRunning then
			ToggleRunEvent:FireServer(isRunning)
			wasRunning = isRunning
			runningState = isRunning
			if IsRunning then IsRunning.Value = isRunning end
		end




		local isExhausted = exhausted and exhausted.Value

		-- Chỉ update bar khi có thay đổi
		if math.abs(stamina.Value - lastStaminaValue) > 0.5 then
			updateBar(staminaBar, stamina.Value, actualMaxStamina)
			lastStaminaValue = stamina.Value
		end

		-- Xử lý exhausted
		if isExhausted then
			if not wasExhausted then
				stopExhaustBlink()
				startExhaustBlink()
				startStaminaShiny(true)
				wasExhausted = true
			end
		else
			if wasExhausted then
				stopExhaustBlink()
				wasExhausted = false
				if IsRunning then IsRunning.Value = false end
			end

			-- Xử lý đang chạy
			if isRunning then
				if not wasRunning then
					startStaminaShiny(false)
					wasRunning = true
				end
			else
				if wasRunning then
					stopStaminaShiny()
					wasRunning = false
				end
				-- FIX: Luôn update màu khi không chạy
				updateStaminaColor(staminaPercent)
			end
		end

		-- Text
		staminaLabel.RichText = true
		staminaLabel.Text = string.format("Stamina: %d/%d", math.floor(stamina.Value), actualMaxStamina)
		if isExhausted then
			staminaLabel.Text = staminaLabel.Text .. ' <font color="rgb(180,0,0)">[EXHAUSTED]</font>'
		end
	end

	-- ============================================
	-- WATER SPEED PENALTY
	-- Apply sau khi server đã set speed, trừ thêm 1 nếu đang trong nước
	-- ============================================
	if isInWater and humanoid then
		humanoid.WalkSpeed = math.max(humanoid.WalkSpeed - 1, 0)
	end

	-- ============================================
	-- HUNGER
	-- ============================================
	if hungryEnabled and hungryEnabled.Value then
		hungerBg.Visible = true

		local hungryValue = hungryEnabled:FindFirstChild("HungryValue")
		local maxHungry = hungryEnabled:FindFirstChild("MaxHungry")
		local isHungry = hungryEnabled:FindFirstChild("Hungry")

		if hungryValue and maxHungry then
			local hungerPercent = hungryValue.Value / maxHungry.Value

			-- Chỉ update khi có thay đổi
			if math.abs(hungryValue.Value - lastHungerValue) > 0.5 then
				updateBar(hungerBar, hungryValue.Value, maxHungry.Value)
				lastHungerValue = hungryValue.Value
			end

			-- FIX: Luôn update màu để tween về đúng
			updateHungerColor(hungerPercent)

			hungerLabel.RichText = true
			hungerLabel.Text = string.format("Hunger: %d/%d", math.floor(hungryValue.Value), maxHungry.Value)
			if isHungry and isHungry.Value then
				hungerLabel.Text = hungerLabel.Text .. ' <font color="rgb(180,0,0)">[HUNGRY]</font>'
			end
		end
	else
		hungerBg.Visible = false
		stopHungerShiny()
	end

	-- ============================================
	-- FATIGUE
	-- ============================================
	if fatigueLevel and maxFatigue then
		local fatiguePercent = math.clamp(fatigueLevel.Value / maxFatigue.Value, 0, 1)

		-- Chỉ update khi có thay đổi đáng kể
		if math.abs(fatigueLevel.Value - lastFatigueValue) > 0.5 then
			updateBar(fatigueBar, fatigueLevel.Value, maxFatigue.Value)
			updateFatigueLevels(fatiguePercent)
			lastFatigueValue = fatigueLevel.Value
		end

		local currentLevelIndex = math.min(math.ceil(fatiguePercent / percentPerLevel), levelCount)
		if currentLevelIndex == 0 then currentLevelIndex = 1 end

		local totalPercentDisplay = math.floor(fatiguePercent * 100)
		local currentLevelColor = levelColors[currentLevelIndex]
		local currentPercentColor = percentColors[currentLevelIndex]

		fatigueLabel.RichText = true
		fatigueLabel.Text = string.format(
			'LEVEL <font color="rgb(%d,%d,%d)">%d</font> ( <font color="rgb(%d,%d,%d)">%02d</font>%% )',
			math.floor(currentLevelColor.R * 255),
			math.floor(currentLevelColor.G * 255),
			math.floor(currentLevelColor.B * 255),
			currentLevelIndex,
			math.floor(currentPercentColor.R * 255),
			math.floor(currentPercentColor.G * 255),
			math.floor(currentPercentColor.B * 255),
			totalPercentDisplay
		)
	end
end))

-- ============================================
-- WATER WALK - Raycast detect terrain water
-- Dùng raycast thay FloorMaterial vì nước có thể
-- là gợn sóng phủ trên nền, chân không chạm nước
-- ============================================
local rootPart = character:WaitForChild("HumanoidRootPart", 10)
local isInWater = false
local waterRayParams = RaycastParams.new()
waterRayParams.FilterType = Enum.RaycastFilterType.Exclude
waterRayParams.FilterDescendantsInstances = { character }

local WATER_RAY_DIST = 3.5 -- studs xuống dưới, đủ để catch nước nông
local WATER_CHECK_INTERVAL = 0.1 -- check 10 lần/giây, không cần mỗi frame
local lastWaterCheck = 0

addConnection(RunService.Heartbeat:Connect(function()
	local now = tick()
	if now - lastWaterCheck < WATER_CHECK_INTERVAL then return end
	lastWaterCheck = now

	if not rootPart then return end

	local origin = rootPart.Position
	local result = workspace:Raycast(origin, Vector3.new(0, -WATER_RAY_DIST, 0), waterRayParams)

	local touchingWater = result ~= nil and result.Material == Enum.Material.Water

	if touchingWater and not isInWater then
		isInWater = true
		CameraShake.WaterWalk:Start()
	elseif not touchingWater and isInWater then
		isInWater = false
		CameraShake.WaterWalk:Stop()
	end
end))
