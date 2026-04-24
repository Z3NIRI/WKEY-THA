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
        runtime.SnapshotAccumulator += deltaTime
    end)

    self:BroadcastSettings()
end

return EnemyService