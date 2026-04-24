local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerService = game:GetService("Players")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.knit)
local Zone = require(ReplicatedStorage.Modules.GameRelated.Zone)

local AssetsFolder: Folder = ReplicatedStorage:WaitForChild("Assets")
local CharactersFolder: Folder = AssetsFolder:WaitForChild("Characters")
local EnemyTemplate: Model = CharactersFolder:WaitForChild("Zombie")

local Platform: BasePart = workspace:WaitForChild("Platform")
local ZonePart: BasePart = Platform:WaitForChild("Zone")

local EnemyService = Knit.CreateService {
    Name = "EnemyService",
    Client = {
        EnemySpawned = Knit.CreateSignal(),
        EnemyRemoved = Knit.CreateSignal(),
        EnemySnapshot = Knit.CreateSignal(),
        SettingsUpdated = Knit.CreateSignal(),
    }
}

EnemyService.SpawnAmount = 1
EnemyService.SpawnInterval = 1
EnemyService.MaxAmount = 20
EnemyService.Runtime = {
    Platform = nil,
    ZonePart = nil,
    ZoneObject = nil,
    BaseHalfHeight = 2,
    SpawnAccumulator = 0,
    SnapshotAccumulator = 0,
    NextEnemyId = 0,
    EnemyCount = 0,
    PlayersInside = {},
    Enemies = {},
    LastReplicatedByPlayer = {},
}

local function BuildSeed(enemyId: number)
    return bit32.bxor(math.floor(DateTime.now().UnixTimestampMillis % 2147483647), enemyId * 1103515245)
end

local function BuildVisualData(enemyId: number)
    local visualRng: Random = Random.new(BuildSeed(enemyId))
    return {
        Color = Color3.fromHSV(visualRng:NextNumber(0, 1), visualRng:NextNumber(0.5, 0.95), visualRng:NextNumber(0.65, 1)),
        Material = ({ Enum.Material.SmoothPlastic, Enum.Material.Metal, Enum.Material.Neon, Enum.Material.Slate })[visualRng:NextInteger(1, 4)],
        Scale = visualRng:NextNumber(0.85, 1.3),
    }
end

local function GetSpawnPoint(runtime: any, groundOffset: number)
    local platform: BasePart = runtime.Platform
    local halfX: number = platform.Size.X * 0.5
    local halfZ: number = platform.Size.Z * 0.5

    local localX: number = Random.new():NextNumber(-halfX, halfX)
    local localZ: number = Random.new():NextNumber(-halfZ, halfZ)
    local localY: number = (platform.Size.Y * 0.5) + groundOffset

    return platform.CFrame:PointToWorldSpace(Vector3.new(localX, localY, localZ))
end

local function ClampToPlatform(runtime: any, worldPosition: Vector3, groundOffset: number)
    local platform: BasePart = runtime.Platform
    local halfX: number = platform.Size.X * 0.5
    local halfZ: number = platform.Size.Z * 0.5

    local localPos: Vector3 = platform.CFrame:PointToObjectSpace(worldPosition)
    localPos = Vector3.new(
        math.clamp(localPos.X, -halfX, halfX),
        (platform.Size.Y * 0.5) + groundOffset,
        math.clamp(localPos.Z, -halfZ, halfZ)
    )

    return platform.CFrame:PointToWorldSpace(localPos)
end

local function IsAliveCharacter(character: Model)
    if not character then
        return false
    end

    local humanoid: Humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

local function GetClosestPlayerInZone(runtime: any, fromPosition: Vector3)
    local bestPlayer: Player = nil
    local bestPosition: Vector3 = nil
    local bestDistance: number = math.huge

    for player: Player in pairs(runtime.PlayersInside) do
        local character: Model = player.Character
        if IsAliveCharacter(character) then
            local root: BasePart = character:FindFirstChild("HumanoidRootPart")
            if root then
                local distance: number = (root.Position - fromPosition).Magnitude
                if distance < bestDistance then
                    bestDistance = distance
                    bestPlayer = player
                    bestPosition = root.Position
                end
            end
        end
    end

    return bestPlayer, bestPosition
end

local function TryDamage(targetPlayer: Player, enemyPosition: Vector3, lastAttackAt: number)
    local character: Model = targetPlayer.Character
    if not character then
        return lastAttackAt
    end

    local humanoid: Humanoid = character:FindFirstChildOfClass("Humanoid")
    local root: BasePart = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then
        return lastAttackAt
    end

    local distance: number = (root.Position - enemyPosition).Magnitude
    local now: number = os.clock()

    if distance <= 4.5 and (now - lastAttackAt) >= 1 then
        humanoid:TakeDamage(8)
        return now
    end

    return lastAttackAt
end

local function BuildEnemyState(enemyId: number, enemyData: any)
    return {
        EnemyId = enemyId,
        SpawnPosition = enemyData.Position,
        VisualData = enemyData.VisualData,
    }
end

local function SpawnEnemy(service)
    local runtime: any = service.Runtime
    if runtime.EnemyCount >= service.MaxAmount then
        return
    end

    runtime.NextEnemyId += 1
    local enemyId: number = runtime.NextEnemyId
    local visualData = BuildVisualData(enemyId)
    local groundOffset: number = math.max(1.25, runtime.BaseHalfHeight * visualData.Scale)
    local spawnPosition: Vector3 = GetSpawnPoint(runtime, groundOffset)

    runtime.Enemies[enemyId] = {
        Position = spawnPosition,
        Look = Vector3.new(0, 0, -1),
        Target = GetSpawnPoint(runtime, groundOffset),
        State = "Patrol",
        RetargetAt = os.clock() + 2,
        LastAttackAt = 0,
        GroundOffset = groundOffset,
        VisualData = visualData,
    }

    runtime.EnemyCount += 1
    service.Client.EnemySpawned:FireAll(BuildEnemyState(enemyId, runtime.Enemies[enemyId]))
end

local function StepEnemy(service, enemyData: any, deltaTime: number)
    local runtime: any = service.Runtime
    local closestPlayer: Player, closestPosition: Vector3 = GetClosestPlayerInZone(runtime, enemyData.Position)

    if closestPlayer and closestPosition then
        enemyData.State = "Chase"
        enemyData.Target = closestPosition
        enemyData.LastAttackAt = TryDamage(closestPlayer, enemyData.Position, enemyData.LastAttackAt)
    else
        enemyData.State = "Patrol"
        if os.clock() >= enemyData.RetargetAt then
            enemyData.Target = GetSpawnPoint(runtime, enemyData.GroundOffset)
            enemyData.RetargetAt = os.clock() + 2
        end
    end

    local speed: number = if enemyData.State == "Chase" then 9 else 5
    local safeTarget: Vector3 = ClampToPlatform(runtime, enemyData.Target, enemyData.GroundOffset)
    local flatDelta: Vector3 = Vector3.new(safeTarget.X - enemyData.Position.X, 0, safeTarget.Z - enemyData.Position.Z)
    local distance: number = flatDelta.Magnitude

    if distance > 0.02 then
        local direction: Vector3 = flatDelta.Unit
        local step: number = math.min(distance, speed * deltaTime)
        enemyData.Position = ClampToPlatform(runtime, enemyData.Position + (direction * step), enemyData.GroundOffset)
        enemyData.Look = direction
    end
end

function EnemyService:BroadcastSettings(targetPlayer)
    local payload = {
        SpawnAmount = self.SpawnAmount,
        SpawnInterval = self.SpawnInterval,
        MaxAmount = self.MaxAmount,
        ActiveEnemies = self.Runtime.EnemyCount,
    }

    if targetPlayer then
        self.Client.SettingsUpdated:Fire(targetPlayer, payload)
    else
        self.Client.SettingsUpdated:FireAll(payload)
    end
end

function EnemyService:KnitStart()
    local runtime: any = self.Runtime

    runtime.Platform = Platform
    runtime.ZonePart = ZonePart
    runtime.ZoneObject = Zone.new(runtime.ZonePart)
    runtime.BaseHalfHeight = math.max(1, EnemyTemplate:GetExtentsSize().Y * 0.5)

    runtime.ZoneObject.playerEntered:Connect(function(player: Player)
        runtime.PlayersInside[player] = true
    end)

    runtime.ZoneObject.playerExited:Connect(function(player: Player)
        runtime.PlayersInside[player] = nil
    end)

    PlayerService.PlayerRemoving:Connect(function(player: Player)
        runtime.PlayersInside[player] = nil
        runtime.LastReplicatedByPlayer[player] = nil
    end)

    PlayerService.PlayerAdded:Connect(function(player: Player)
        self:BroadcastSettings(player)
    end)

    RunService.Heartbeat:Connect(function(deltaTime: number)
        runtime.SpawnAccumulator += deltaTime

        while runtime.SpawnAccumulator >= self.SpawnInterval do
            runtime.SpawnAccumulator -= self.SpawnInterval
            for _ = 1, self.SpawnAmount do
                if runtime.EnemyCount >= self.MaxAmount then
                    break
                end
                SpawnEnemy(self)
            end
        end

        for _, enemyData: any in pairs(runtime.Enemies) do
            StepEnemy(self, enemyData, deltaTime)
        end
    end)

    self:BroadcastSettings()
end

return EnemyService