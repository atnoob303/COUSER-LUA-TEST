game.Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		-- FIX BUG 1: StatPlayer chỉ tạo 1 lần duy nhất khi player join.
		-- Trước đây mỗi lần respawn (CharacterAdded) đều Instance.new() folder mới
		-- mà không xoá folder cũ -> StatPlayer rác tích tụ vô hạn vì
		-- FindFirstChild/WaitForChild luôn trả về cái cũ nhất.
		-- Việc reset stat theo từng lần respawn đã được CouserRunSever.lua xử lý riêng.
		if player:FindFirstChild("StatPlayer") then return end

		local StatPlayer = Instance.new("Folder")
		StatPlayer.Name = "StatPlayer"
		StatPlayer.Parent = player
		local RunSystem = Instance.new("BoolValue")
		RunSystem.Name = "RunSystem"
		RunSystem.Value = true
		RunSystem.Parent = StatPlayer
		local IsRunning = Instance.new("BoolValue")
		IsRunning.Name = "IsRunning"
		IsRunning.Value = false
		IsRunning.Parent = RunSystem
		local Maxstamina = Instance.new("NumberValue")
		Maxstamina.Name = "MaxStamina"
		Maxstamina.Value = 100
		Maxstamina.Parent = RunSystem
		local fatiguelevel = Instance.new("NumberValue")
		fatiguelevel.Name = "FatigueLevel"
		fatiguelevel.Value = 0
		fatiguelevel.Parent = RunSystem
		local MaxFatigue = Instance.new("NumberValue")
		MaxFatigue.Name = "MaxFatigue"
		MaxFatigue.Value = 100
		MaxFatigue.Parent = RunSystem
		local stamina = Instance.new("NumberValue")
		stamina.Name = "Stamina"
		stamina.Value = Maxstamina.Value
		stamina.Parent = RunSystem
		local Buffstamina = Instance.new("NumberValue")
		Buffstamina.Name = "BuffStamina"
		Buffstamina.Value = 0
		Buffstamina.Parent = Maxstamina
		local Buffspeed = Instance.new("NumberValue")
		Buffspeed.Name = "BuffSpeed"
		Buffspeed.Value = 0
		Buffspeed.Parent = RunSystem
		local CurrentDevice = Instance.new("StringValue")
		CurrentDevice.Name = "CurrentDevice"
		CurrentDevice.Value = "None"
		CurrentDevice.Parent = RunSystem
		local RunButton = Instance.new("StringValue")
		RunButton.Name = "RunButton"
		RunButton.Value = "LeftShift"
		RunButton.Parent = RunSystem
		local Exhausted = Instance.new("BoolValue")
		Exhausted.Name = "Exhausted"
		Exhausted.Parent = RunSystem
		local Infinity = Instance.new("BoolValue")
		Infinity.Name = "Infinity"
		Infinity.Parent = RunSystem
		local Speed = Instance.new("NumberValue")
		Speed.Name = "Speed"
		Speed.Value = 30
		Speed.Parent = RunSystem
		local HungryEnabled = Instance.new("BoolValue")
		HungryEnabled.Name = "HungryEnabled"
		HungryEnabled.Value = true
		HungryEnabled.Parent = RunSystem
		local MaxHungry = Instance.new("NumberValue")
		MaxHungry.Name = "MaxHungry"
		MaxHungry.Value = 50
		MaxHungry.Parent = HungryEnabled
		local HungryValue = Instance.new("NumberValue")
		HungryValue.Name = "HungryValue"
		HungryValue.Value = MaxHungry.Value
		HungryValue.Parent = HungryEnabled
		local IsHungry = Instance.new("BoolValue")
		IsHungry.Name = "Hungry"
		IsHungry.Parent = HungryEnabled

		-- ============================================
		-- CROUCH SYSTEM
		-- ============================================
		local CrouchSystem = Instance.new("BoolValue")
		CrouchSystem.Name = "CrouchSystem"
		CrouchSystem.Value = true -- bật/tắt toàn bộ hệ thống ngồi, client dựa vào đây để biết có cho ngồi hay không
		CrouchSystem.Parent = StatPlayer

		local IsCrouching = Instance.new("BoolValue")
		IsCrouching.Name = "IsCrouching"
		IsCrouching.Value = false -- đang ngồi hay không
		IsCrouching.Parent = CrouchSystem

		local CrouchButton = Instance.new("StringValue")
		CrouchButton.Name = "CrouchButton"
		CrouchButton.Value = "LeftControl" -- phím dùng để ngồi, đổi được như RunButton
		CrouchButton.Parent = CrouchSystem

		local CrouchSpeed = Instance.new("NumberValue")
		CrouchSpeed.Name = "CrouchSpeed"
		CrouchSpeed.Value = 8 -- tốc độ đi khi ngồi
		CrouchSpeed.Parent = CrouchSystem

		local CrouchBuffSpeed = Instance.new("NumberValue")
		CrouchBuffSpeed.Name = "BuffSpeed"
		CrouchBuffSpeed.Value = 0 -- buff cộng thêm cho CrouchSpeed, giống BuffStamina con của MaxStamina
		CrouchBuffSpeed.Parent = CrouchSpeed

		-- ===== SLIDE (trượt khi đang chạy mà bấm ngồi) =====
		local IsSliding = Instance.new("BoolValue")
		IsSliding.Name = "IsSliding"
		IsSliding.Value = false -- đang trượt hay không
		IsSliding.Parent = CrouchSystem

		local SlideSpeedMultiplier = Instance.new("NumberValue")
		SlideSpeedMultiplier.Name = "SlideSpeedMultiplier"
		SlideSpeedMultiplier.Value = 1.4 -- x1.4 tốc độ chạy hiện tại ngay khi vừa trượt
		SlideSpeedMultiplier.Parent = CrouchSystem

		local SlideTweenTime = Instance.new("NumberValue")
		SlideTweenTime.Name = "SlideTweenTime"
		SlideTweenTime.Value = 0.6 -- số giây để tween tốc độ từ lúc trượt (x1.4) giảm dần về CrouchSpeed
		SlideTweenTime.Parent = CrouchSystem

		local SlideTimeLeft = Instance.new("NumberValue")
		SlideTimeLeft.Name = "SlideTimeLeft"
		SlideTimeLeft.Value = 0 -- thời gian trượt còn lại, server/client dựa vào đây để biết khi nào trượt kết thúc
		SlideTimeLeft.Parent = CrouchSystem

		Buffspeed:SetAttribute("ServerOwned", true)
		Buffstamina:SetAttribute("ServerOwned", true)
		Infinity:SetAttribute("ServerOwned", true)
		CrouchBuffSpeed:SetAttribute("ServerOwned", true)
		IsSliding:SetAttribute("ServerOwned", true)
		SlideTimeLeft:SetAttribute("ServerOwned", true)
	end)
end)
