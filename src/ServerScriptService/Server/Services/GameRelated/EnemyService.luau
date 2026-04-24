--[[
     __________ _   _ ___ ____  ___
    |__  /___ /| \ | |_ _|  _ \|_ _|
      / /  |_ \|  \| || || |_) || |
     / /_ ___) | |\  || ||  _ < | |
    /____|____/|_| \_|___|_| \_\___|

    Author: Z3NIRI
    Type: Service
    Description: Runs enemy spawning/AI and optimized custom position replication to clients
    Updated: 24/04/2026
]]

-->   Services   <--
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerService = game:GetService("Players")
local RunService = game:GetService("RunService")

-->   Modules   <--
local Knit = require(ReplicatedStorage.Packages.knit)
local Zone = require(ReplicatedStorage.Modules.GameRelated.Zone)

-->   Variables   <--
local AssetsFolder: Folder = ReplicatedStorage:WaitForChild("Assets")
local CharactersFolder: Folder = AssetsFolder:WaitForChild("Characters")
local EnemyTemplate: Model = CharactersFolder:WaitForChild("Zombie")

local Platform: BasePart = workspace:WaitForChild("Platform")
local ZonePart: BasePart = Platform:WaitForChild("Zone")

-->   Service Definition   <--
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

-->   Local Functions   <--
--[[
    SERVER: Builds a deterministic visual seed for an enemy id

    @param enemyId: number
    @returns number
]]
local function BuildSeed(enemyId: number)
    return bit32.bxor(math.floor(DateTime.now().UnixTimestampMillis % 2147483647), enemyId * 1103515245)
end

--[[
    SERVER: Builds visual customization values for one enemy

    @param enemyId: number
    @returns table
]]
local function BuildVisualData(enemyId: number)
    local visualRng: Random = Random.new(BuildSeed(enemyId))

    return {
        Color = Color3.fromHSV(visualRng:NextNumber(0, 1), visualRng:NextNumber(0.5, 0.95), visualRng:NextNumber(0.65, 1)),
        Material = ({ Enum.Material.SmoothPlastic, Enum.Material.Metal, Enum.Material.Neon, Enum.Material.Slate })[visualRng:NextInteger(1, 4)],
        Scale = visualRng:NextNumber(0.85, 1.3),
    }
end

--[[
    SERVER: Returns a random world-space spawn position on the platform

    @param runtime: table
    @param groundOffset: number
    @returns Vector3
]]
local function GetSpawnPoint(runtime: any, groundOffset: number)
    local platform: BasePart = runtime.Platform
    local halfX: number = platform.Size.X * 0.5
    local halfZ: number = platform.Size.Z * 0.5

    local localX: number = Random.new():NextNumber(-halfX, halfX)
    local localZ: number = Random.new():NextNumber(-halfZ, halfZ)
    local localY: number = (platform.Size.Y * 0.5) + groundOffset

    return platform.CFrame:PointToWorldSpace(Vector3.new(localX, localY, localZ))
end

--[[
    SERVER: Clamps a world position to platform bounds with fixed ground height

    @param runtime: table
    @param worldPosition: Vector3
    @param groundOffset: number
    @returns Vector3
]]
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

--[[
    SERVER: Checks whether a character exists and has a living humanoid

    @param character: Model
    @returns boolean
]]
local function IsAliveCharacter(character: Model)
    if not character then
        return false
    end

    local humanoid: Humanoid = character:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end

--[[
    SERVER: Finds the closest in-zone player to a world position

    @param runtime: table
    @param fromPosition: Vector3
    @returns Player, Vector3
]]
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

--[[
    SERVER: Attempts to damage a target player when in attack range/cooldown

    @param targetPlayer: Player
    @param enemyPosition: Vector3
    @param lastAttackAt: number
    @returns number
]]
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

--[[
    SERVER: Builds spawn payload data for client enemy creation

    @param runtime: table
    @param enemyId: number
    @param enemyData: table
    @returns table
]]
local function BuildEnemyState(runtime: any, enemyId: number, enemyData: any)
    return {
        EnemyId = enemyId,
        SpawnPosition = enemyData.Position,
        VisualData = enemyData.VisualData,
    }
end

--[[
    SERVER: Quantizes a world position to one decimal place for hashing

    @param v: Vector3
    @returns number, number, number
]]
local function QuantizeVector3(v: Vector3)
    return math.floor(v.X * 10 + 0.5), math.floor(v.Y * 10 + 0.5), math.floor(v.Z * 10 + 0.5)
end

--[[
    SERVER: Quantizes a look vector to two decimal places for hashing

    @param v: Vector3
    @returns number, number, number
]]
local function QuantizeLook(v: Vector3)
    return math.floor(v.X * 100 + 0.5), math.floor(v.Y * 100 + 0.5), math.floor(v.Z * 100 + 0.5)
end

--[[
    SERVER: Builds a per-player delta snapshot of nearby enemy transforms

    @param service: table
    @param player: Player
    @returns table
]]
local function BuildPlayerSnapshot(service, player: Player)
    local runtime: any = service.Runtime
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then
        return nil
    end

    local origin = root.Position
    local playerHistory = runtime.LastReplicatedByPlayer[player]
    if not playerHistory then
        playerHistory = {}
        runtime.LastReplicatedByPlayer[player] = playerHistory
    end

    local snapshot: { [number]: any } = table.create(math.max(1, runtime.EnemyCount // 2))

    for enemyId: number, enemyData: any in pairs(runtime.Enemies) do
        local delta = enemyData.Position - origin
        local distSq = delta:Dot(delta)

        if distSq <= 260 * 260 then
            local px, py, pz = QuantizeVector3(enemyData.Position)
            local lx, ly, lz = QuantizeLook(enemyData.Look)
            local hash = string.format("%d|%d|%d|%d|%d|%d", px, py, pz, lx, ly, lz)

            if playerHistory[enemyId] ~= hash then
                playerHistory[enemyId] = hash
                snapshot[#snapshot + 1] = {
                    EnemyId = enemyId,
                    Position = enemyData.Position,
                    Look = enemyData.Look,
                }
            end
        end
    end

    if #snapshot == 0 then
        return nil
    end

    return snapshot
end

--[[
    SERVER: Spawns one enemy and broadcasts spawn payload to clients

    @param service: table
]]
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

    service.Client.EnemySpawned:FireAll(BuildEnemyState(runtime, enemyId, runtime.Enemies[enemyId]))
end

--[[
    SERVER: Updates one enemy AI state and movement for the current frame

    @param service: table
    @param enemyData: table
    @param deltaTime: number
]]
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

-->   Client Functions   <--

--[[
    CLIENT: Returns current enemy system settings and active enemy count

    @param player: Player
    @returns table
]]
function EnemyService.Client:GetSettings(player: Player)
    return {
        SpawnAmount = self.Server.SpawnAmount,
        SpawnInterval = self.Server.SpawnInterval,
        MaxAmount = self.Server.MaxAmount,
        ActiveEnemies = self.Server.Runtime.EnemyCount,
    }
end

--[[
    CLIENT: Returns initial enemy spawn payloads for newly joined clients

    @param player: Player
    @returns table
]]
function EnemyService.Client:GetInitialEnemies(player: Player)
    local runtime: any = self.Server.Runtime
    local initial: { [number]: any } = table.create(runtime.EnemyCount)

    for enemyId: number, enemyData: any in pairs(runtime.Enemies) do
        initial[#initial + 1] = BuildEnemyState(runtime, enemyId, enemyData)
    end

    return initial
end

--[[
    CLIENT: Receives client click forwarding for one enemy id

    @param player: Player
    @param enemyId: number
]]
function EnemyService.Client:EnemyClicked(player: Player, enemyId: number)
    local exists = self.Server.Runtime.Enemies[enemyId] ~= nil
    if exists then
        print(string.format("[SERVER] %s clicked enemy #%d", player.Name, enemyId))
    end
end

--[[
    CLIENT: Requests server to remove all active enemies

    @param player: Player
]]
function EnemyService.Client:KillAllEnemies(player: Player)
    self.Server:KillAllEnemies()
end

--[[
    CLIENT: Requests server-side settings update

    @param player: Player
    @param key: string
    @param value: number
]]
function EnemyService.Client:UpdateSettings(player: Player, key: string, value: number)
    self.Server:UpdateSettings(key, value)
end

-->   Server Functions   <--

--[[
    SERVER: Broadcasts current enemy settings to one player or all players

    @param targetPlayer: Player
]]
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

--[[
    SERVER: Updates enemy spawn settings and enforces max overflow removal

    @param key: string
    @param value: number
]]
function EnemyService:UpdateSettings(key: string, value: number)
    if key == "SpawnAmount" then
        self.SpawnAmount = math.clamp(math.floor(value), 1, 200)
    elseif key == "SpawnInterval" then
        self.SpawnInterval = math.clamp(value, 0.05, 60)
    elseif key == "MaxAmount" then
        self.MaxAmount = math.clamp(math.floor(value), 1, 5000)

        if self.Runtime.EnemyCount > self.MaxAmount then
            local overflow = self.Runtime.EnemyCount - self.MaxAmount
            for enemyId: number in pairs(self.Runtime.Enemies) do
                self.Runtime.Enemies[enemyId] = nil
                self.Runtime.EnemyCount -= 1
                self.Client.EnemyRemoved:FireAll(enemyId)
                overflow -= 1
                if overflow <= 0 then
                    break
                end
            end
        end
    else
        return
    end

    self:BroadcastSettings()
end

--[[
    SERVER: Removes all enemies and clears per-player replication history
]]
function EnemyService:KillAllEnemies()
    for enemyId: number in pairs(self.Runtime.Enemies) do
        self.Runtime.Enemies[enemyId] = nil
        self.Client.EnemyRemoved:FireAll(enemyId)
    end

    self.Runtime.EnemyCount = 0

    for player: Player in pairs(self.Runtime.LastReplicatedByPlayer) do
        self.Runtime.LastReplicatedByPlayer[player] = nil
    end

    self:BroadcastSettings()
end

-->   Knit Lifecycle   <--
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
        runtime.SnapshotAccumulator += deltaTime

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

        if runtime.SnapshotAccumulator >= 0.1 then
            runtime.SnapshotAccumulator = 0

            for _, player in ipairs(PlayerService:GetPlayers()) do
                local snapshot = BuildPlayerSnapshot(self, player)
                if snapshot then
                    self.Client.EnemySnapshot:Fire(player, snapshot)
                end
            end
        end
    end)

    self:BroadcastSettings()
end

-->   Exports   <--
return EnemyService