--[[
     __________ _   _ ___ ____  ___
    |__  /___ /| \ | |_ _|  _ \|_ _|
      / /  |_ \|  \| || || |_) || |
     / /_ ___) | |\  || ||  _ < | |
    /____|____/|_| \_|___|_| \_\___|

    Author: Z3NIRI
]]

-->   Services   <--
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-->   Modules   <--
local Knit = require(ReplicatedStorage.Packages.knit)

-->   Variables   <--
local Controllers: Folder = script:WaitForChild("Controllers")
local StartTime: number = os.clock()

Knit.GroupID = 000000000

-->   Module Definition   <--
Knit.AddControllersDeep(Controllers)

-->   Knit Lifecycle   <--
Knit.Start():andThen(function()
    local LoadTime: number = (os.clock() - StartTime) * 1000
    print(string.format("[SERVER] Knit successfully loaded its controllers in %d ms.", LoadTime))
end):catch(warn)