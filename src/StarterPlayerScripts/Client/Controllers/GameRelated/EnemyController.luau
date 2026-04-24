--[[
     __________ _   _ ___ ____  ___
    |__  /___ /| \ | |_ _|  _ \|_ _|
      / /  |_ \|  \| || || |_) || |
     / /_ ___) | |\  || ||  _ < | |
    /____|____/|_| \_|___|_| \_\___|

    Author: Z3NIRI
    Type: Controller
    Description: Handles client-side enemy rendering, click forwarding, and settings UI sync
    Updated: 24/04/2026
]]

-->   Services   <--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerService = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

-->   Modules   <--
local Knit = require(ReplicatedStorage.Packages.knit)
local AnimNation = require(ReplicatedStorage.Modules.InterfaceRelated.AnimNation)

-->   Variables   <--
local LocalPlayer: Player = PlayerService.LocalPlayer
local PlayerGui: PlayerGui = LocalPlayer.PlayerGui
local ScreenGui: ScreenGui = PlayerGui:WaitForChild("ScreenGui")

local SpawnAmountBox: TextBox = ScreenGui:WaitForChild("SpawnAmount")
local SpawnIntervalBox: TextBox = ScreenGui:WaitForChild("SpawnInterval")
local MaxAmountBox: TextBox = ScreenGui:WaitForChild("MaxAmount")

local KillAllButton: TextButton = ScreenGui:WaitForChild("KillAll")

local AssetsFolder: Folder = ReplicatedStorage:WaitForChild("Assets")
local CharactersFolder: Folder = AssetsFolder:WaitForChild("Characters")
local EnemyTemplate: Model = CharactersFolder:WaitForChild("Zombie")

-->   Controller Definition   <--
local EnemyController = Knit.CreateController {
    Name = "EnemyController",
}

EnemyController.EnemyService = nil
EnemyController.Template = nil
EnemyController.Enemies = {}
EnemyController.EnemyFolder = nil
EnemyController.LastSettings = nil

-->   Local Functions   <--
--[[
    CLIENT: Ensures a local render folder exists for client-only enemies

    @param self: table
    @returns Folder
]]
local function EnsureEnemyFolder(self)
    if self.EnemyFolder and self.EnemyFolder.Parent then
        return self.EnemyFolder
    end

    local folder: Folder = workspace:FindFirstChild("ClientEnemies")
    if not folder then
        folder = Instance.new("Folder")
        folder.Name = "ClientEnemies"
        folder.Parent = workspace
    end

    self.EnemyFolder = folder
    return folder
end

--[[
    CLIENT: Applies editable part visuals and propagates EnemyId to all parts

    @param enemyModel: Model
    @param visualData: table
]]
local function ApplyEditableParts(enemyModel: Model, visualData: any)
    for _, descendant: Instance in ipairs(enemyModel:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant:SetAttribute("EnemyId", enemyModel:GetAttribute("EnemyId"))
            if CollectionService:HasTag(descendant, "Editable") then
                descendant.Color = visualData.Color
                descendant.Material = visualData.Material
            end
        end
    end
end

--[[
    CLIENT: Plays spawn fade for all model parts

    @param model: Model
]]
local function FadeInModel(model: Model)
    local tweenInfo: TweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

    for _, descendant: Instance in ipairs(model:GetDescendants()) do
        if descendant:IsA("BasePart") then
            local targetTransparency: number = descendant.Transparency
            descendant.Transparency = 1
            AnimNation.tween(descendant, tweenInfo, { Transparency = targetTransparency })
        end
    end
end

--[[
    CLIENT: Creates and tracks a local render model for one enemy

    @param self: table
    @param payload: table
]]
local function CreateEnemyModel(self, payload: any)
    if self.Enemies[payload.EnemyId] then
        return
    end

    local model: Model = self.Template:Clone()
    model.Name = string.format("Enemy_%d", payload.EnemyId)
    model:SetAttribute("EnemyId", payload.EnemyId)

    ApplyEditableParts(model, payload.VisualData)
    model:ScaleTo(payload.VisualData.Scale)

    if not model.PrimaryPart then
        model.PrimaryPart = model:FindFirstChild("HumanoidRootPart") or model:FindFirstChildWhichIsA("BasePart")
    end

    if model.PrimaryPart then
        model:PivotTo(CFrame.new(payload.SpawnPosition))
    end

    model.Parent = EnsureEnemyFolder(self)
    FadeInModel(model)

    self.Enemies[payload.EnemyId] = {
        Model = model,
        Position = payload.SpawnPosition,
        TargetPosition = payload.SpawnPosition,
        Look = Vector3.new(0, 0, -1),
        TargetLook = Vector3.new(0, 0, -1),
    }
end

--[[
    CLIENT: Removes one enemy model from local render state

    @param self: table
    @param enemyId: number
]]
local function RemoveEnemy(self, enemyId: number)
    local enemyData: any = self.Enemies[enemyId]
    if enemyData and enemyData.Model then
        enemyData.Model:Destroy()
    end

    self.Enemies[enemyId] = nil
end

--[[
    CLIENT: Resolves EnemyId from clicked part or its ancestor model

    @param target: Instance
    @returns number
]]
local function GetEnemyIdFromTarget(target: Instance)
    local model = target:FindFirstAncestorOfClass("Model")
    if model then
        local modelEnemyId = model:GetAttribute("EnemyId")
        if typeof(modelEnemyId) == "number" then
            return modelEnemyId
        end
    end

    local partEnemyId = target:GetAttribute("EnemyId")
    if typeof(partEnemyId) == "number" then
        return partEnemyId
    end

    return nil
end

--[[
    CLIENT: Resolves clicked enemy id using a long-range camera raycast

    @param self: table
    @returns number
]]
local function ResolveEnemyIdFromClick(self)
    local camera = workspace.CurrentCamera
    if not camera then
        return nil
    end

    local mousePosition: Vector2 = UserInputService:GetMouseLocation()
    local unitRay: Ray = camera:ViewportPointToRay(mousePosition.X, mousePosition.Y)

    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Include
    raycastParams.FilterDescendantsInstances = { EnsureEnemyFolder(self) }
    raycastParams.IgnoreWater = true

    local raycastResult = workspace:Raycast(unitRay.Origin, unitRay.Direction * 10000, raycastParams)
    if raycastResult then
        local enemyId = GetEnemyIdFromTarget(raycastResult.Instance)
        if typeof(enemyId) == "number" then
            return enemyId
        end
    end

    local mouse = LocalPlayer:GetMouse()
    local target = mouse.Target
    if target then
        return GetEnemyIdFromTarget(target)
    end

    return nil
end

--[[
    CLIENT: Applies server settings to text box placeholders

    @param settings: table
]]
local function SetSettingsPlaceholders(settings: any)
    SpawnAmountBox.PlaceholderText = tostring(settings.SpawnAmount)
    SpawnIntervalBox.PlaceholderText = tostring(settings.SpawnInterval)
    MaxAmountBox.PlaceholderText = tostring(settings.MaxAmount)
end

--[[
    CLIENT: Returns true only when editable setting values actually changed

    @param self: table
    @param settings: table
    @returns boolean
]]
local function ShouldApplySettings(self, settings: any)
    local last = self.LastSettings
    if not last then
        self.LastSettings = {
            SpawnAmount = settings.SpawnAmount,
            SpawnInterval = settings.SpawnInterval,
            MaxAmount = settings.MaxAmount,
        }
        return true
    end

    local changed = (
        last.SpawnAmount ~= settings.SpawnAmount
        or last.SpawnInterval ~= settings.SpawnInterval
        or last.MaxAmount ~= settings.MaxAmount
    )

    if changed then
        last.SpawnAmount = settings.SpawnAmount
        last.SpawnInterval = settings.SpawnInterval
        last.MaxAmount = settings.MaxAmount
    end

    return changed
end

--[[
    CLIENT: Hooks mouse click detection and forwards clicked EnemyId to server

    @param self: table
]]
local function HookInput(self)
    UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
        if gameProcessed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
            return
        end

        local enemyId = ResolveEnemyIdFromClick(self)
        if typeof(enemyId) == "number" then
            print(string.format("[CLIENT] Clicked enemy #%d", enemyId))
            self.EnemyService:EnemyClicked(enemyId)
        end
    end)
end

--[[
    CLIENT: Interpolates enemy movement every render frame

    @param self: table
]]
local function StartRenderLoop(self)
    RunService.RenderStepped:Connect(function()
        for _, enemyData in pairs(self.Enemies) do
            local model = enemyData.Model
            if model and model.Parent and model.PrimaryPart then
                enemyData.Position = enemyData.Position:Lerp(enemyData.TargetPosition, 0.35)
                enemyData.Look = enemyData.Look:Lerp(enemyData.TargetLook, 0.35)

                local look = enemyData.Look.Magnitude > 0 and enemyData.Look.Unit or Vector3.new(0, 0, -1)
                model:PivotTo(CFrame.lookAt(enemyData.Position, enemyData.Position + look))
            end
        end
    end)
end

-->   Knit Lifecycle   <--
function EnemyController:KnitStart()
    self.EnemyService = Knit.GetService("EnemyService")
    self.Template = EnemyTemplate

    HookInput(self)

    self.EnemyService.SettingsUpdated:Connect(function(settings: any)
        if ShouldApplySettings(self, settings) then
            SetSettingsPlaceholders(settings)
        end
    end)

    SpawnAmountBox.FocusLost:Connect(function(enterPressed: boolean)
        if not enterPressed then
            return
        end

        local value = tonumber(SpawnAmountBox.Text)
        if value then
            self.EnemyService:UpdateSettings("SpawnAmount", value)
        end

        SpawnAmountBox.Text = ""
    end)

    SpawnIntervalBox.FocusLost:Connect(function(enterPressed: boolean)
        if not enterPressed then
            return
        end

        local value = tonumber(SpawnIntervalBox.Text)
        if value then
            self.EnemyService:UpdateSettings("SpawnInterval", value)
        end

        SpawnIntervalBox.Text = ""
    end)

    MaxAmountBox.FocusLost:Connect(function(enterPressed: boolean)
        if not enterPressed then
            return
        end

        local value = tonumber(MaxAmountBox.Text)
        if value then
            self.EnemyService:UpdateSettings("MaxAmount", value)
        end

        MaxAmountBox.Text = ""
    end)

    KillAllButton.MouseButton1Click:Connect(function()
        self.EnemyService:KillAllEnemies()
    end)

    local settings = self.EnemyService:GetSettings()
    if settings and ShouldApplySettings(self, settings) then
        SetSettingsPlaceholders(settings)
    end

    local initialEnemies = self.EnemyService:GetInitialEnemies()
    for _, payload in ipairs(initialEnemies) do
        CreateEnemyModel(self, payload)
    end

    self.EnemyService.EnemySpawned:Connect(function(payload: any)
        CreateEnemyModel(self, payload)
    end)

    self.EnemyService.EnemyRemoved:Connect(function(enemyId: number)
        RemoveEnemy(self, enemyId)
    end)

    self.EnemyService.EnemySnapshot:Connect(function(snapshot: { [number]: any })
        for _, entry in ipairs(snapshot) do
            local enemyData: any = self.Enemies[entry.EnemyId]
            if enemyData then
                enemyData.TargetPosition = entry.Position
                enemyData.TargetLook = entry.Look
            end
        end
    end)

    StartRenderLoop(self)
end

-->   Exports   <--
return EnemyController