local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- ============================================
-- SETUP REMOTEEVENTS
-- ============================================
local RemoteFolder = ReplicatedStorage:FindFirstChild("GameSettingUp"):FindFirstChild("RunSystemRemotes")
if not RemoteFolder then
	RemoteFolder = Instance.new("Folder")
	RemoteFolder.Name = "RunSystemRemotes"
	RemoteFolder.Parent = ReplicatedStorage:FindFirstChild("GameSettingUp")
end

local DeviceCheckEvent = RemoteFolder:FindFirstChild("DeviceCheck")
if not DeviceCheckEvent then
	DeviceCheckEvent = Instance.new("RemoteEvent")
	DeviceCheckEvent.Name = "DeviceCheck"
	DeviceCheckEvent.Parent = RemoteFolder
end


local ToggleRunSystemEvent = RemoteFolder:FindFirstChild("ToggleRunSystem")
if not ToggleRunSystemEvent then
	ToggleRunSystemEvent = Instance.new("RemoteEvent")
	ToggleRunSystemEvent.Name = "ToggleRunSystem"
	ToggleRunSystemEvent.Parent = RemoteFolder
end


local ToggleRunEvent = RemoteFolder:FindFirstChild("ToggleRun")
if not ToggleRunEvent then
	ToggleRunEvent = Instance.new("RemoteEvent")
	ToggleRunEvent.Name = "ToggleRun"
	ToggleRunEvent.Parent = RemoteFolder
end

local EatFoodEvent = RemoteFolder:FindFirstChild("EatFood")
if not EatFoodEvent then
	EatFoodEvent = Instance.new("RemoteEvent")
	EatFoodEvent.Name = "EatFood"
	EatFoodEvent.Parent = RemoteFolder
end

local ToggleCrouchEvent = RemoteFolder:FindFirstChild("ToggleCrouch")
if not ToggleCrouchEvent then
	ToggleCrouchEvent = Instance.new("RemoteEvent")
	ToggleCrouchEvent.Name = "ToggleCrouch"
	ToggleCrouchEvent.Parent = RemoteFolder
end

local StartSlideEvent = RemoteFolder:FindFirstChild("StartSlide")
if not StartSlideEvent then
	StartSlideEvent = Instance.new("RemoteEvent")
	StartSlideEvent.Name = "StartSlide"
	StartSlideEvent.Parent = RemoteFolder
end

-- ============================================
-- CONFIGURATION - Thêm speed mechanics mới
-- ============================================

local function getMaxSpeed(player)
	local statPlayer = player:FindFirstChild("StatPlayer")
	if not statPlayer then return 30 end

	local runSystem = statPlayer:FindFirstChild("RunSystem")
	if not runSystem then return 30 end

	return runSystem.Speed.Value
end



local Config = {
	NormalSpeed = 12,

	-- Speed mechanics (NEW)
	MaxRunSpeed = 28,            -- Tốc chạy max khi stamina > 10% (cấu hình tay, KHÔNG lấy từ instance player)
	MinRunSpeed = 20,            -- Tốc chạy min khi stamina = 0%
	StaminaLowThreshold = 0.1,   -- 10% stamina - điểm bắt đầu giảm tốc
	BackwardSpeedPenalty = 0.15, -- 15% giảm tốc khi chạy lùi

	-- Stamina
	StaminaDrainRate = 2,
	StaminaRegenRate = 5,
	StaminaRegenWalkRate = 3,
	StaminaRegenIdleBonus = 1.05, -- 5% bonus khi đứng yên
	StaminaRegenCrouchMultiplier = 2, -- NEW: hồi stamina nhanh hơn X lần khi đang crouch (không trượt)

	-- Hunger
	HungerDrainNormal = 0.5,
	HungerDrainExhausted = 1.5,
	HungerWalkPercent = 0.2,   -- 20% so với khi chạy
	HungerIdlePercent = 0.01,  -- 1% so với khi chạy


	-- Fatigue
	FatigueIncrease = 20,
	FatigueDecreasePerHunger = 2,
	FautigueRate = 0.25, --------------------EZ 0,05 Normal 0,25 Hard 0,75 Nightmare 1,5
	fatigueFall = 0.005,
	FautiSec = 30,

	-- Exhausted
	ExhaustedRecoverThreshold = 0.75, -- 30% stamina để hồi từ exhausted

	-- ============================================
	-- CROUCH / SLIDE (NEW)
	-- ============================================
	CrouchHipHeightOffset = -1.5, -- giảm HipHeight bao nhiêu khi crouch (server set để đồng bộ, client tween mượt riêng)
}

-- ============================================
-- PLAYER STATE TRACKING
-- ============================================
local playerRunningState = {}
local lastPosition = {}
local lastMoveDirection = {} -- Track hướng di chuyển
local runSystemLockState = {}
local allowedDevices = {
	PC = true,
	Mobile = true,
	Console = true
}

local lastDevicePing = {}
local firstSpawn = true

-- NEW: Track trạng thái Slide riêng mỗi player (không lưu connection vào ValueObject)
local slideData = {} -- [player.UserId] = { startSpeed = number, startTime = number }
local originalHipHeight = {} -- NEW: [player.UserId] = HipHeight gốc lúc spawn, dùng để tính HipHeight crouch TUYỆT ĐỐI
-- (không cộng/trừ vào humanoid.HipHeight hiện tại, tránh sai số khi client đang tween dở)

-- Track thời gian bắt đầu chạy để validate slide (chống spam slide ngay khi vừa bấm Run)
local runStartTime = {} -- [player.UserId] = os.clock() lúc bắt đầu Run
local MIN_RUN_TIME_FOR_SLIDE = 0.4 -- giây tối thiểu phải chạy mới được slide
local MAX_EXTRA_SLIDE_BONUS = 1.0  -- giây tối đa cộng thêm vào SlideTweenTime từ thời gian chạy
local SLIDE_TIME_PER_RUN_SEC = 0.1 -- mỗi giây chạy cộng thêm 0.1s vào thời gian slide



-- ============================================
-- UTILITY FUNCTIONS
-- ============================================


local function getFatigueMultiplier(fatigueValue, maxFatigue)
	local percent = fatigueValue / maxFatigue
	local level = math.clamp(math.floor(percent * 5), 0, 5)
	local reduction = level * 0.05 -- mỗi level -5%
	return 1 - reduction
end

-- NEW: Lấy nhánh CrouchSystem của player, trả về nil nếu chưa tồn tại
local function getCrouchSystem(player)
	local statPlayer = player:FindFirstChild("StatPlayer")
	if not statPlayer then return nil end
	return statPlayer:FindFirstChild("CrouchSystem")
end

local function lockRunSystem(player, reason)
	local statPlayer = player:FindFirstChild("StatPlayer")
	if not statPlayer then return end

	local runSystem = statPlayer:FindFirstChild("RunSystem")
	if not runSystem then return end

	runSystem.Value = false

	runSystemLockState[player] = {
		locked = true,
		reason = reason,
		timestamp = os.clock()
	}

	print("RunSystem locked for", player.Name, "Reason:", reason)
end


local function protectValue(valueObject)
	valueObject.Changed:Connect(function()
		if not valueObject:GetAttribute("ServerOwned") then
			valueObject.Value = 0
		end
	end)
end


-- Kiểm tra player có đang di chuyển không
local function isPlayerMoving(character)
	if not character or not character.PrimaryPart then return false end

	local rootPart = character.PrimaryPart
	local currentPos = rootPart.Position
	local lastPos = lastPosition[character]

	if not lastPos then
		lastPosition[character] = currentPos
		return false
	end

	local distance = (currentPos - lastPos).Magnitude
	lastPosition[character] = currentPos

	return distance > 0.1
end

-- NEW: Kiểm tra có đang chạy lùi không
local function isMovingBackward(character)
	if not character or not character.PrimaryPart then return false end

	local humanoid = character:FindFirstChild("Humanoid")
	if not humanoid then return false end

	local rootPart = character.PrimaryPart
	local moveDirection = humanoid.MoveDirection

	-- Nếu không di chuyển thì không phải chạy lùi
	if moveDirection.Magnitude < 0.1 then 
		return false 
	end

	-- So sánh hướng di chuyển với hướng nhìn
	local lookVector = rootPart.CFrame.LookVector
	local dotProduct = moveDirection:Dot(lookVector)

	-- Nếu dot product < -0.5 nghĩa là đang di chuyển ngược hướng nhìn
	return dotProduct < -0.5
end

-- NEW: Tính tốc độ chạy dựa trên stamina % và hướng
local function calculateRunSpeed(staminaPercent, isBackward, buffSpeed, fatigueMultiplier, exhausted)
	local speed = Config.MaxRunSpeed

	if staminaPercent > Config.StaminaLowThreshold then
		speed = Config.MaxRunSpeed
	else
		local t = staminaPercent / Config.StaminaLowThreshold
		speed = Config.MinRunSpeed + (Config.MaxRunSpeed - Config.MinRunSpeed) * t
	end

	speed = speed + (buffSpeed or 0)

	if isBackward then
		speed = speed * (1 - Config.BackwardSpeedPenalty)
	end

	-- Giảm theo fatigue
	speed = speed * (fatigueMultiplier or 1)

	-- Nếu exhausted giảm thêm 30%
	if exhausted then
		speed = speed * 0.7
	end

	return math.floor(speed)
end



-- ============================================
-- MAIN STAMINA UPDATE FUNCTION
-- ============================================

local function updateStamina(player)
	local StatPlayer = player:FindFirstChild("StatPlayer")
	if not StatPlayer then return end

	local RunSystem = StatPlayer:FindFirstChild("RunSystem")
	if not RunSystem or not RunSystem:IsA("BoolValue") then return end

	local character = player.Character

	-- Kiểm tra RunSystem có được bật không
	if not RunSystem.Value then
		if character and character:FindFirstChild("Humanoid") then
			character.Humanoid.WalkSpeed = Config.NormalSpeed
		end
		playerRunningState[player.UserId] = false
		return
	end


	if not character or not character:FindFirstChild("Humanoid") then return end

	local humanoid = character.Humanoid

	-- Lấy các values
	local stamina = RunSystem:FindFirstChild("Stamina")
	local maxStamina = RunSystem:FindFirstChild("MaxStamina")
	local buffStamina = maxStamina and maxStamina:FindFirstChild("BuffStamina")
	local fatigueLevel = RunSystem:FindFirstChild("FatigueLevel")
	local maxFatigue = RunSystem:FindFirstChild("MaxFatigue")
	local exhausted = RunSystem:FindFirstChild("Exhausted")
	local infinity = RunSystem:FindFirstChild("Infinity")
	local speed = RunSystem:FindFirstChild("Speed")
	local buffSpeed = RunSystem:FindFirstChild("BuffSpeed")
	local hungryEnabled = RunSystem:FindFirstChild("HungryEnabled")

	if not stamina or not maxStamina or not fatigueLevel or not exhausted or not speed or not hungryEnabled then return end

	local hungryValue = hungryEnabled:FindFirstChild("HungryValue")
	local maxHungry = hungryEnabled:FindFirstChild("MaxHungry")
	local isHungry = hungryEnabled:FindFirstChild("Hungry")

	if not hungryValue or not maxHungry or not isHungry then return end

	local function applyWalkSpeed()
		local fatigueMultiplier = getFatigueMultiplier(
			fatigueLevel.Value,
			maxFatigue.Value
		)

		local finalSpeed = Config.NormalSpeed * fatigueMultiplier

		-- Nếu exhausted thì trừ thêm 30%
		if exhausted.Value then
			finalSpeed = finalSpeed * 0.7
		end

		humanoid.WalkSpeed = finalSpeed
		speed.Value = 0
	end

	-- Tính MaxStamina thực tế (bao gồm buff)
	local actualMaxStamina = maxStamina.Value + (buffStamina and buffStamina.Value or 0)

	-- ============================================
	-- CROUCH SYSTEM - early handling
	-- Khi đang Crouch (và KHÔNG đang Slide): tốc độ cố định = CrouchSpeed + BuffSpeed,
	-- không áp dụng fatigue/exhausted penalty, hồi stamina nhanh hơn, KHÔNG trừ đói.
	-- Slide được xử lý riêng ở loop SlideService phía dưới, ở đây chỉ cần
	-- không can thiệp WalkSpeed nếu đang slide (để tween riêng không bị server đè mỗi frame).
	-- ============================================
	local crouchSystem = StatPlayer:FindFirstChild("CrouchSystem")
	local isCrouching = crouchSystem and crouchSystem:FindFirstChild("IsCrouching")
	local isSliding = crouchSystem and crouchSystem:FindFirstChild("IsSliding")

	if crouchSystem and crouchSystem.Value and isCrouching and isCrouching.Value then
		if not (isSliding and isSliding.Value) then
			-- Đang crouch thật (không trượt): tốc độ cố định, không bị fatigue/exhausted chi phối
			local crouchSpeedObj = crouchSystem:FindFirstChild("CrouchSpeed")
			local crouchBuffSpeed = crouchSpeedObj and crouchSpeedObj:FindFirstChild("BuffSpeed")
			local finalCrouchSpeed = (crouchSpeedObj and crouchSpeedObj.Value or 8) + (crouchBuffSpeed and crouchBuffSpeed.Value or 0)

			humanoid.WalkSpeed = finalCrouchSpeed
			speed.Value = finalCrouchSpeed

			-- Hồi stamina nhanh hơn khi crouch (dùng StaminaRegenRate * multiplier, không cộng idle bonus để tránh chồng buff)
			if not (infinity and infinity.Value) then
				local crouchRegenRate = Config.StaminaRegenRate * Config.StaminaRegenCrouchMultiplier
				stamina.Value = math.min(actualMaxStamina, stamina.Value + crouchRegenRate / 30)
			end

			-- KHÔNG trừ đói khi crouch (theo yêu cầu)
			-- KHÔNG tăng fatigue khi crouch dù đang đói, để crouch là trạng thái "nghỉ"

			-- Vẫn kiểm tra hồi từ Exhausted để không bị kẹt trạng thái exhausted mãi
			if exhausted.Value and stamina.Value >= actualMaxStamina * Config.ExhaustedRecoverThreshold then
				exhausted.Value = false
			end

			return -- dừng ở đây, không chạy tiếp logic Run/Walk/Hunger/Fatigue bên dưới
		end
		-- Nếu đang Slide thì rơi qua logic bên dưới như bình thường (WalkSpeed do SlideService quản lý riêng
		-- thông qua slideData, updateStamina sẽ KHÔNG được gọi cho player này trong lúc slideData còn tồn tại
		-- — xem vòng lặp Heartbeat ở cuối file).
	end


	-- Kiểm tra trạng thái di chuyển
	local isMoving = false
	if character.PrimaryPart then
		-- Kiểm tra velocity
		local velocity = character.PrimaryPart.AssemblyLinearVelocity or character.PrimaryPart.Velocity
		isMoving = velocity.Magnitude > 1

		-- Fallback: kiểm tra position
		if not isMoving then
			isMoving = isPlayerMoving(character)
		end
	end

	local isPlayerRunning = playerRunningState[player.UserId] or false
	local isWalking = isMoving and not isPlayerRunning

	-- Nếu bật Infinity mode thì không trừ stamina
	if infinity and infinity.Value then
		stamina.Value = actualMaxStamina
		speed.Value = Config.MaxRunSpeed + (buffSpeed and buffSpeed.Value or 0)
		return
	end

	-- ============================================
	-- XỬ LÝ STAMINA
	-- ============================================
	if isPlayerRunning and isMoving then
		-- ĐANG CHẠY
		if stamina.Value > 0 then
			-- Còn stamina - drain bình thường
			stamina.Value = math.max(0, stamina.Value - Config.StaminaDrainRate / 30)

			-- NEW: Tính speed động dựa trên stamina %
			local staminaPercent = stamina.Value / actualMaxStamina
			local isBackward = isMovingBackward(character)
			local fatigueMultiplier = getFatigueMultiplier(
				fatigueLevel.Value,
				maxFatigue.Value
			)

			local runSpeed = calculateRunSpeed(
				staminaPercent,
				isBackward,
				buffSpeed and buffSpeed.Value,
				fatigueMultiplier,
				exhausted.Value
			)


			-- Cập nhật speed
			humanoid.WalkSpeed = runSpeed
			speed.Value = runSpeed

			-- Trừ đói nếu HungryEnabled được bật
			-- ============================================
			-- GIẢM ĐÓI THEO TRẠNG THÁI
			-- ============================================

			if hungryEnabled.Value then
				local baseDrain = Config.HungerDrainNormal / 30

				if isPlayerRunning then
					-- 🏃 Chạy: 100%
					hungryValue.Value = math.max(0, hungryValue.Value - baseDrain)
				end
			end

		else
			-- HẾT STAMINA - trạng thái Exhausted
			if not exhausted.Value then
				exhausted.Value = true
				fatigueLevel.Value = math.min(100, fatigueLevel.Value + Config.FatigueIncrease)
			end

			-- Tự động tắt chạy
			applyWalkSpeed()

			playerRunningState[player.UserId] = false

			-- Trừ đói nhiều hơn khi exhausted
			if hungryEnabled.Value then
				hungryValue.Value = math.max(0, hungryValue.Value - Config.HungerDrainExhausted / 30)
			end
		end
	elseif isWalking then
		-- ĐANG ĐI BỘ - hồi stamina ít
		local regenRate = Config.StaminaRegenWalkRate

		if hungryValue.Value <= 0 then
			regenRate = regenRate * 0.1 -- giảm 90%
		end

		stamina.Value = math.min(
			actualMaxStamina,
			stamina.Value + regenRate / 30
		)

		-- Reset speed về bình thường
		if humanoid.WalkSpeed ~= Config.NormalSpeed then
			applyWalkSpeed()

		end
	else
		local regenRate = Config.StaminaRegenRate * Config.StaminaRegenIdleBonus

		if hungryValue.Value <= 0 then
			regenRate = regenRate * 0.1 -- giảm 90%
		end

		stamina.Value = math.min(
			actualMaxStamina,
			stamina.Value + regenRate / 30
		)


		-- Reset speed
		if humanoid.WalkSpeed ~= Config.NormalSpeed then
			applyWalkSpeed()

		end
	end

	-- ============================================
	-- KIỂM TRA HỒI TỪ EXHAUSTED
	-- ============================================
	if exhausted.Value and stamina.Value >= actualMaxStamina * Config.ExhaustedRecoverThreshold then
		exhausted.Value = false
	end

	-- ============================================
	-- CẬP NHẬT TRẠNG THÁI ĐÓI
	-- ============================================
	-- ============================================
	-- CẬP NHẬT TRẠNG THÁI ĐÓI + FATIGUE
	-- ============================================
	if hungryEnabled.Value then
		isHungry.Value = hungryValue.Value <= 0

		if isHungry.Value then
			-- Khi đói: fatigue tăng
			fatigueLevel.Value = math.min(
				maxFatigue.Value,
				fatigueLevel.Value + (Config.FautigueRate  / Config.FautiSec)
			)
		else
			-- Nếu không đói: fatigue giảm chậm
			fatigueLevel.Value = math.max(
				0,
				fatigueLevel.Value - (Config.fatigueFall / 30)
			)
		end
	end


	if fatigueLevel.Value >= maxFatigue.Value and humanoid.Health > 0 then
		humanoid.Health = 0
	end



end

-- ============================================
-- TOGGLE RUN EVENT - Fixed với shift key tracking
-- ============================================
ToggleRunEvent.OnServerEvent:Connect(function(player, isRunning)
	local StatPlayer = player:FindFirstChild("StatPlayer")
	if not StatPlayer then return end

	local RunSystem = StatPlayer:FindFirstChild("RunSystem")
	if not RunSystem or not RunSystem.Value then return end

	-- NEW: Không cho bật chạy nếu đang Crouch (server validate, chống client tự fire event)
	local crouchSystem = StatPlayer:FindFirstChild("CrouchSystem")
	if crouchSystem and crouchSystem:FindFirstChild("IsCrouching") and crouchSystem.IsCrouching.Value then
		isRunning = false
	end

	local character = player.Character
	if not character or not character:FindFirstChild("Humanoid") then return end

	local humanoid = character.Humanoid
	local stamina = RunSystem:FindFirstChild("Stamina")
	local maxStamina = RunSystem:FindFirstChild("MaxStamina")
	local buffStamina = maxStamina and maxStamina:FindFirstChild("BuffStamina")
	local exhausted = RunSystem:FindFirstChild("Exhausted")
	local speed = RunSystem:FindFirstChild("Speed")
	local buffSpeed = RunSystem:FindFirstChild("BuffSpeed")
	local infinity = RunSystem:FindFirstChild("Infinity")
	local fatigueLevel = RunSystem:FindFirstChild("FatigueLevel")
	local maxFatigue = RunSystem:FindFirstChild("MaxFatigue")



	if not stamina or not maxStamina or not exhausted or not speed then return end

	-- Tính max stamina thực tế
	local actualMaxStamina = maxStamina.Value + (buffStamina and buffStamina.Value or 0)

	-- Kiểm tra có thể chạy không
	local canRun = (infinity and infinity.Value) or (stamina.Value > 0 and not exhausted.Value)

	if isRunning and canRun then
		-- BẬT CHẠY
		playerRunningState[player.UserId] = true
		if not runStartTime[player.UserId] then
			runStartTime[player.UserId] = os.clock() -- ghi nhận lúc bắt đầu chạy
		end

		-- Tính speed ban đầu (có thể thay đổi trong updateStamina)
		local staminaPercent = stamina.Value / actualMaxStamina
		local isBackward = isMovingBackward(character)
		local fatigueMultiplier = getFatigueMultiplier(
			fatigueLevel.Value,
			maxFatigue.Value
		)

		local runSpeed = calculateRunSpeed(
			staminaPercent,
			isBackward,
			buffSpeed and buffSpeed.Value,
			fatigueMultiplier,
			exhausted.Value
		)


		humanoid.WalkSpeed = runSpeed
		speed.Value = runSpeed
	else
		-- TẮT CHẠY
		playerRunningState[player.UserId] = false
		runStartTime[player.UserId] = nil -- reset thời gian chạy
		humanoid.WalkSpeed = Config.NormalSpeed
		speed.Value = 0
	end
end)

-- ============================================
-- TOGGLE CROUCH EVENT - client báo bắt đầu/kết thúc crouch
-- Server chỉ xác nhận trạng thái + set HipHeight đồng bộ,
-- KHÔNG set WalkSpeed ở đây (để updateStamina loop xử lý mỗi frame,
-- tránh 2 nơi cùng ghi đè WalkSpeed gây giật).
-- ============================================
ToggleCrouchEvent.OnServerEvent:Connect(function(player, wantCrouch)
	local StatPlayer = player:FindFirstChild("StatPlayer")
	if not StatPlayer then return end

	local crouchSystem = StatPlayer:FindFirstChild("CrouchSystem")
	if not crouchSystem or not crouchSystem.Value then return end -- hệ thống Crouch đang bị tắt

	local isCrouching = crouchSystem:FindFirstChild("IsCrouching")
	local isSliding = crouchSystem:FindFirstChild("IsSliding")
	if not isCrouching then return end

	local character = player.Character
	if not character or not character:FindFirstChild("Humanoid") then return end
	local humanoid = character.Humanoid

	-- Lấy HipHeight gốc tuyệt đối (fallback = giá trị hiện tại nếu vì lý do gì chưa lưu được)
	local baseHipHeight = originalHipHeight[player.UserId] or humanoid.HipHeight

	if wantCrouch then
		isCrouching.Value = true
		humanoid.HipHeight = math.max(baseHipHeight + Config.CrouchHipHeightOffset, 0)
	else
		-- Không cho đứng lên giữa lúc đang Slide (slide tự kết thúc rồi mới đứng lên)
		if isSliding and isSliding.Value then return end

		isCrouching.Value = false
		humanoid.HipHeight = baseHipHeight
	end
end)

-- ============================================
-- START SLIDE EVENT - client báo đang chạy mà bấm Crouch
-- Server xác thực: phải đang thực sự Run (playerRunningState) mới cho slide,
-- tránh client giả lập slide để lướt nhanh khi không đủ điều kiện.
-- ============================================
StartSlideEvent.OnServerEvent:Connect(function(player)
	local StatPlayer = player:FindFirstChild("StatPlayer")
	if not StatPlayer then return end

	local crouchSystem = StatPlayer:FindFirstChild("CrouchSystem")
	if not crouchSystem or not crouchSystem.Value then return end

	local isCrouching = crouchSystem:FindFirstChild("IsCrouching")
	local isSliding = crouchSystem:FindFirstChild("IsSliding")
	local slideTimeLeft = crouchSystem:FindFirstChild("SlideTimeLeft")
	local slideTweenTime = crouchSystem:FindFirstChild("SlideTweenTime")
	local slideMultiplier = crouchSystem:FindFirstChild("SlideSpeedMultiplier")
	if not isCrouching or not isSliding or not slideTimeLeft or not slideTweenTime or not slideMultiplier then return end

	-- Chỉ cho Slide nếu player THỰC SỰ đang chạy (server-side state, không tin client)
	-- Nếu reject: vẫn set isCrouching để client đồng bộ, tránh isSliding kẹt ở client
	if not playerRunningState[player.UserId] then
		if not isCrouching.Value then
			isCrouching.Value = true
			local character2 = player.Character
			if character2 and character2:FindFirstChild("Humanoid") then
				local baseHipHeight2 = originalHipHeight[player.UserId] or character2.Humanoid.HipHeight
				character2.Humanoid.HipHeight = math.max(baseHipHeight2 + Config.CrouchHipHeightOffset, 0)
				local crouchSpeedObj2 = crouchSystem:FindFirstChild("CrouchSpeed")
				local crouchBuffSpeed2 = crouchSpeedObj2 and crouchSpeedObj2:FindFirstChild("BuffSpeed")
				local finalCrouchSpeed2 = (crouchSpeedObj2 and crouchSpeedObj2.Value or 8) + (crouchBuffSpeed2 and crouchBuffSpeed2.Value or 0)
				character2.Humanoid.WalkSpeed = finalCrouchSpeed2
			end
		end
		return
	end
	if isSliding.Value then return end -- đang slide rồi thì bỏ qua

	-- Validate thời gian chạy tối thiểu (chống spam: bấm Run rồi bấm Slide ngay)
	local startTime = runStartTime[player.UserId]
	local runDuration = startTime and (os.clock() - startTime) or 0
	if runDuration < MIN_RUN_TIME_FOR_SLIDE then
		-- Chưa đủ đà -> chỉ ngồi bình thường, không slide
		ToggleCrouchEvent:FireClient(player, true) -- không có event này, xử lý qua isCrouching trực tiếp
		isCrouching.Value = true
		local character2 = player.Character
		if character2 and character2:FindFirstChild("Humanoid") then
			local baseHipHeight2 = originalHipHeight[player.UserId] or character2.Humanoid.HipHeight
			character2.Humanoid.HipHeight = math.max(baseHipHeight2 + Config.CrouchHipHeightOffset, 0)
			local crouchSpeedObj2 = crouchSystem:FindFirstChild("CrouchSpeed")
			local crouchBuffSpeed2 = crouchSpeedObj2 and crouchSpeedObj2:FindFirstChild("BuffSpeed")
			local finalCrouchSpeed2 = (crouchSpeedObj2 and crouchSpeedObj2.Value or 8) + (crouchBuffSpeed2 and crouchBuffSpeed2.Value or 0)
			character2.Humanoid.WalkSpeed = finalCrouchSpeed2
		end
		playerRunningState[player.UserId] = false
		runStartTime[player.UserId] = nil
		return
	end

	local character = player.Character
	if not character or not character:FindFirstChild("Humanoid") then return end
	local humanoid = character.Humanoid

	-- Tốc độ slide = tốc độ chạy hiện tại x1.9 (thay vì dùng SlideSpeedMultiplier cố định)
	local currentRunSpeed = humanoid.WalkSpeed
	local boostedSpeed = currentRunSpeed * 1.9

	-- Thời gian slide = SlideTweenTime cơ bản + 0.1 * giây đã chạy (tối đa cộng thêm MAX_EXTRA_SLIDE_BONUS)
	local extraSlideTime = math.min(runDuration * SLIDE_TIME_PER_RUN_SEC, MAX_EXTRA_SLIDE_BONUS)
	local finalSlideDuration = slideTweenTime.Value + extraSlideTime

	-- Lấy HipHeight gốc tuyệt đối (fallback = giá trị hiện tại nếu vì lý do gì chưa lưu được)
	local baseHipHeight = originalHipHeight[player.UserId] or humanoid.HipHeight

	-- Chuyển sang trạng thái Crouch + Sliding
	playerRunningState[player.UserId] = false -- ngừng tính là "Run" nữa, slide có luồng tốc độ riêng
	runStartTime[player.UserId] = nil -- reset thời gian chạy sau khi slide
	isCrouching.Value = true
	isSliding.Value = true
	slideTimeLeft.Value = finalSlideDuration
	humanoid.HipHeight = math.max(baseHipHeight + Config.CrouchHipHeightOffset, 0)
	humanoid.WalkSpeed = boostedSpeed

	slideData[player.UserId] = {
		startSpeed = boostedSpeed,
		duration = finalSlideDuration,
		elapsed = 0,
	}
end)

-- ============================================
-- EAT FOOD EVENT
-- ============================================
EatFoodEvent.OnServerEvent:Connect(function(player, foodValue)
	local StatPlayer = player:FindFirstChild("StatPlayer")
	if not StatPlayer then return end

	local RunSystem = StatPlayer:FindFirstChild("RunSystem")
	if not RunSystem then return end

	local hungryEnabled = RunSystem:FindFirstChild("HungryEnabled")
	if not hungryEnabled or not hungryEnabled.Value then return end

	local hungryValue = hungryEnabled:FindFirstChild("HungryValue")
	local maxHungry = hungryEnabled:FindFirstChild("MaxHungry")
	local fatigueLevel = RunSystem:FindFirstChild("FatigueLevel")

	if not hungryValue or not maxHungry or not fatigueLevel then return end

	local oldHungry = hungryValue.Value
	hungryValue.Value = math.min(maxHungry.Value, hungryValue.Value + foodValue)

	-- Giảm độ mệt dựa trên lượng đói tăng
	local hungerGained = hungryValue.Value - oldHungry
	if hungerGained > 0 then
		fatigueLevel.Value = math.max(0, fatigueLevel.Value - (hungerGained * Config.FatigueDecreasePerHunger / foodValue))
	end
end)

-- ============================================
-- CLEANUP EVENTS
-- ============================================

-- Cleanup khi player rời
game.Players.PlayerRemoving:Connect(function(player)
	playerRunningState[player.UserId] = nil
	lastMoveDirection[player.UserId] = nil
	slideData[player.UserId] = nil
	originalHipHeight[player.UserId] = nil
	runStartTime[player.UserId] = nil
	if player.Character then
		lastPosition[player.Character] = nil
	end
end)

-- Cleanup khi character respawn
game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		playerRunningState[player.UserId] = false
		lastPosition[character] = nil
		lastMoveDirection[player.UserId] = nil
		slideData[player.UserId] = nil
		runStartTime[player.UserId] = nil

		-- Reset speed khi spawn
		local humanoid = character:WaitForChild("Humanoid")
		humanoid.WalkSpeed = Config.NormalSpeed

		-- NEW: Lưu HipHeight gốc ngay lúc spawn, làm chuẩn TUYỆT ĐỐI cho mọi lần tính crouch sau này
		originalHipHeight[player.UserId] = humanoid.HipHeight

		-- NEW: Reset CrouchSystem khi respawn (HipHeight đã reset tự nhiên theo rig mới)
		local crouchSystem = player:WaitForChild("StatPlayer"):WaitForChild("CrouchSystem")
		local isCrouching = crouchSystem:FindFirstChild("IsCrouching")
		local isSliding = crouchSystem:FindFirstChild("IsSliding")
		local slideTimeLeft = crouchSystem:FindFirstChild("SlideTimeLeft")
		if isCrouching then isCrouching.Value = false end
		if isSliding then isSliding.Value = false end
		if slideTimeLeft then slideTimeLeft.Value = 0 end

		local runSystem = player:WaitForChild("StatPlayer"):WaitForChild("RunSystem")
		local hungryEnabled = runSystem:WaitForChild("HungryEnabled")

		local hungryValue = hungryEnabled:FindFirstChild("HungryValue")
		local maxHungry = hungryEnabled:FindFirstChild("MaxHungry")
		local fatigueLevel = runSystem:FindFirstChild("FatigueLevel")
		local maxFatigue = runSystem:FindFirstChild("MaxFatigue")

		if not firstSpawn then
			if hungryValue and maxHungry then
				hungryValue.Value = maxHungry.Value * 0.65
			end

			-- FIX BUG 2: trước đây FatigueLevel không được reset khi respawn, nên nếu
			-- player chết vì fatigue đầy thì respawn xong vẫn fatigue full -> chết lặp lại ngay.
			-- Giờ mỗi lần respawn giảm 25% TỔNG fatigue (tính theo MaxFatigue), không reset hẳn về 0.
			if fatigueLevel and maxFatigue then
				fatigueLevel.Value = math.max(0, fatigueLevel.Value - maxFatigue.Value * 0.25)
			end
		end

		firstSpawn = false


		-- Cleanup khi character bị xóa
		character.AncestryChanged:Connect(function(_, parent)
			if not parent then
				lastPosition[character] = nil
			end
		end)
	end)
end)

-- ============================================
-- TOGGLE ENTIRE RUN SYSTEM (NEW)
-- ============================================
ToggleRunSystemEvent.OnServerEvent:Connect(function(player, state)

	local statPlayer = player:FindFirstChild("StatPlayer")
	if not statPlayer then return end

	local runSystem = statPlayer:FindFirstChild("RunSystem")
	if not runSystem then return end

	-- ❗ Nếu đang bị lock thì không cho bật lại
	local lockData = runSystemLockState[player]
	if lockData and lockData.locked then
		return
	end

	runSystem.Value = state
end)

DeviceCheckEvent.OnServerEvent:Connect(function(player, device)
	lastDevicePing[player] = os.clock()

	local statPlayer = player:FindFirstChild("StatPlayer")
	if statPlayer then
		local runSystem = statPlayer:FindFirstChild("RunSystem")
		if runSystem then
			runSystem.CurrentDevice.Value = device
		end
	end
end)




-- ============================================
-- SLIDE UPDATE FUNCTION
-- Giảm dần WalkSpeed từ (runSpeed * SlideSpeedMultiplier) về (CrouchSpeed + BuffSpeed)
-- trong khoảng SlideTweenTime giây. Hướng di chuyển KHÔNG bị khoá (đổi hướng tự do),
-- vì Humanoid tự xử lý hướng theo input, ở đây ta chỉ chỉnh WalkSpeed.
-- ============================================
local function updateSlide(player, dt)
	local data = slideData[player.UserId]
	if not data then return end

	local StatPlayer = player:FindFirstChild("StatPlayer")
	local character = player.Character
	if not StatPlayer or not character or not character:FindFirstChild("Humanoid") then
		slideData[player.UserId] = nil
		return
	end

	local crouchSystem = StatPlayer:FindFirstChild("CrouchSystem")
	if not crouchSystem then
		slideData[player.UserId] = nil
		return
	end

	local isSliding = crouchSystem:FindFirstChild("IsSliding")
	local slideTimeLeft = crouchSystem:FindFirstChild("SlideTimeLeft")
	local crouchSpeedObj = crouchSystem:FindFirstChild("CrouchSpeed")
	local crouchBuffSpeed = crouchSpeedObj and crouchSpeedObj:FindFirstChild("BuffSpeed")

	if not isSliding or not slideTimeLeft or not crouchSpeedObj then
		slideData[player.UserId] = nil
		return
	end

	local humanoid = character.Humanoid
	local targetSpeed = crouchSpeedObj.Value + (crouchBuffSpeed and crouchBuffSpeed.Value or 0)

	data.elapsed = data.elapsed + dt
	local t = math.clamp(data.elapsed / data.duration, 0, 1)

	-- Easing nhẹ (quadratic out) để giảm tốc tự nhiên hơn linear
	local easedT = 1 - (1 - t) * (1 - t)
	humanoid.WalkSpeed = data.startSpeed + (targetSpeed - data.startSpeed) * easedT

	slideTimeLeft.Value = math.max(0, data.duration - data.elapsed)

	if t >= 1 then
		-- Kết thúc slide: chuyển hẳn về trạng thái Crouch bình thường
		isSliding.Value = false
		humanoid.WalkSpeed = targetSpeed
		slideData[player.UserId] = nil
	end
end

-- ============================================
-- UPDATE LOOP
-- ============================================
local lastHeartbeatTime = os.clock()
RunService.Heartbeat:Connect(function()
	local now = os.clock()
	local dt = now - lastHeartbeatTime
	lastHeartbeatTime = now

	for _, player in pairs(game.Players:GetPlayers()) do
		if player.Character then
			if slideData[player.UserId] then
				updateSlide(player, dt)
			else
				updateStamina(player)
			end
		end
	end
end)

task.spawn(function()
	while true do
		task.wait(60) -- mỗi 2 phút check 1 lần

		for player, lastPing in pairs(lastDevicePing) do
			if os.clock() - lastPing > 300 then -- quá 5 phút không ping
				--lockRunSystem(player, "Device timeout") -- vẫn còn lỗi nên tắt
			end
		end
	end
end)




print("✅ Stamina System đã khởi động!")
print("⚡ Speed Mechanics:")
print("   - Max Speed: " .. Config.MaxRunSpeed)
print("   - Min Speed: " .. Config.MinRunSpeed)
print("   - Low Stamina Threshold: " .. (Config.StaminaLowThreshold * 100) .. "%")
print("   - Backward Penalty: " .. (Config.BackwardSpeedPenalty * 100) .. "%")
