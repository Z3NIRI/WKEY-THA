local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerService = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Knit = require(ReplicatedStorage.Packages.knit)
local AnimNation = require(ReplicatedStorage.Modules.InterfaceRelated.AnimNation)

local LocalPlayer: Player = PlayerService.LocalPlayer
local AssetsFolder: Folder = ReplicatedStorage:WaitForChild("Assets")
local CharactersFolder: Folder = AssetsFolder:WaitForChild("Characters")
local EnemyTemplate: Model = CharactersFolder:WaitForChild("Zombie")

local EnemyController = Knit.CreateController {
    Name = "EnemyController",
}

EnemyController.EnemyService = nil
EnemyController.Template = nil
EnemyController.Enemies = {}
EnemyController.EnemyFolder = nil

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

local function RemoveEnemy(self, enemyId: number)
    local enemyData: any = self.Enemies[enemyId]
    if enemyData and enemyData.Model then
        enemyData.Model:Destroy()
    end

    self.Enemies[enemyId] = nil
end

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

local function HookInput(self)
    UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
        if gameProcessed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
            return
        end

        local enemyId = ResolveEnemyIdFromClick(self)
        if typeof(enemyId) == "number" then
            self.EnemyService:EnemyClicked(enemyId)
        end
    end)
end

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

function EnemyController:KnitStart()
    self.EnemyService = Knit.GetService("EnemyService")
    self.Template = EnemyTemplate

    HookInput(self)

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

return EnemyController