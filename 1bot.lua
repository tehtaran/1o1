-- Initializing global variables to store the latest game state and game host process.
gameState = gameState or nil
busy = busy or false -- Prevents the agent from taking multiple actions at once.
logEntries = logEntries or {}

local ANSIColors = {
    red = "\27[31m",
    green = "\27[32m",
    blue = "\27[34m",
    reset = "\27[0m",
    yellow = "\27[33m",
    purple = "\27[35m"
}

local function log(message, text)
    logEntries[message] = logEntries[message] or {}
    table.insert(logEntries[message], text)
end

local function withinRange(x1, y1, x2, y2, distance)
    return (x1 - x2)^2 + (y1 - y2)^2 <= distance^2
end

local function getNearestEnemies(count)
    local me = gameState.Players[ao.id]
    local enemies = {}

    for id, info in pairs(gameState.Players) do
        if id ~= ao.id then
            table.insert(enemies, {
                id = id,
                x = info.x,
                y = info.y,
                energy = info.energy,
                health = info.health
            })
        end
    end

    table.sort(enemies, function(a, b)
        local distA = (me.x - a.x)^2 + (me.y - a.y)^2
        local distB = (me.x - b.x)^2 + (me.y - b.y)^2
        return distA < distB
    end)

    local nearest = {}
    for i = 1, math.min(count, #enemies) do
        table.insert(nearest, enemies[i])
    end

    return nearest
end

local function normalize(vec)
    local len = math.sqrt(vec.x * vec.x + vec.y * vec.y)
    return { x = vec.x / len, y = vec.y / len }
end

local function directionTo(from, to)
    return normalize({ x = to.x - from.x, y = to.y - from.y })
end

local function escapeDirection()
    local me = gameState.Players[ao.id]
    local direction = { x = 0, y = 0 }

    for id, info in pairs(gameState.Players) do
        if id ~= ao.id then
            local avoid = { x = me.x - info.x, y = me.y - info.y }
            direction.x = direction.x + avoid.x
            direction.y = direction.y + avoid.y
        end
    end

    return normalize(direction)
end

local function isInRangeOfAttack(target)
    local me = gameState.Players[ao.id]
    return withinRange(me.x, me.y, target.x, target.y, 1)
end

local function patrol()
    local me = gameState.Players[ao.id]
    local directions = {
        { x = 1, y = 0 },
        { x = -1, y = 0 },
        { x = 0, y = 1 },
        { x = 0, y = -1 }
    }
    local nextDirection = directions[math.random(#directions)]
    return nextDirection
end

local function makeDecision()
    local me = gameState.Players[ao.id]
    local nearestEnemies = getNearestEnemies(3)

    if me.health < 30 then
        print(ANSIColors.red .. "Low health! Evading..." .. ANSIColors.reset)
        local escapeDir = escapeDirection()
        ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = escapeDir })
        busy = false
        return
    end

    for _, enemy in ipairs(nearestEnemies) do
        if enemy.targetPlayer == ao.id then
            print(ANSIColors.purple .. "Under attack! Assessing response..." .. ANSIColors.reset)
            if me.energy > enemy.energy then
                print(ANSIColors.purple .. "Counter-attacking..." .. ANSIColors.reset)
                ao.send({ Target = Game, Action = "PlayerAttack", Player = ao.id, TargetPlayer = enemy.id, AttackEnergy = tostring(me.energy) })
            else
                print(ANSIColors.purple .. "Evading attacker..." .. ANSIColors.reset)
                local evadeDir = escapeDirection()
                ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = evadeDir })
            end
            busy = false
            return
        end
    end

    for _, enemy in ipairs(nearestEnemies) do
        if me.energy > enemy.energy and me.health > enemy.health then
            if isInRangeOfAttack(enemy) then
                print(ANSIColors.green .. "Attacking weaker enemy..." .. ANSIColors.reset)
                ao.send({ Target = Game, Action = "PlayerAttack", Player = ao.id, TargetPlayer = enemy.id, AttackEnergy = tostring(me.energy) })
            else
                print(ANSIColors.blue .. "Moving towards weaker enemy..." .. ANSIColors.reset)
                local approachDir = directionTo(me, enemy)
                ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = approachDir })
            end
            busy = false
            return
        end
    end

    local patrolDir = patrol()
    print(ANSIColors.yellow .. "Patrolling area..." .. ANSIColors.reset)
    ao.send({ Target = Game, Action = "PlayerMove", Player = ao.id, Direction = normalize(patrolDir) })
    busy = false
end

-- Handler to update the game state upon receiving game state information.
Handlers.add(
    "UpdateGameState",
    Handlers.utils.hasMatchingTag("Action", "GameState"),
    function(msg)
        local json = require("json")
        gameState = json.decode(msg.Data)
        ao.send({ Target = ao.id, Action = "StateUpdated" })
    end
)

-- Handler to decide the next best action.
Handlers.add(
    "MakeDecision",
    Handlers.utils.hasMatchingTag("Action", "StateUpdated"),
    function()
        if gameState.GameMode ~= "Playing" then
            print("Game not in progress.")
            busy = false
            return
        end
        print("Making decision.")
        makeDecision()
        ao.send({ Target = ao.id, Action = "Tick" })
    end
)

-- Handler to print game announcements and trigger game state updates.
Handlers.add(
    "AnnounceAndUpdate",
    Handlers.utils.hasMatchingTag("Action", "Announcement"),
    function(msg)
        if msg.Event == "Started-Waiting-Period" then
            ao.send({ Target = ao.id, Action = "AutoPay" })
        elseif (msg.Event == "Tick" or msg.Event == "Started-Game") and not busy then
            busy = true
            ao.send({ Target = Game, Action = "GetGameState" })
        elseif busy then
            print("Action in progress. Skipping update.")
        end
        print(ANSIColors.green .. msg.Event .. ": " .. msg.Data .. ANSIColors.reset)
    end
)

-- Handler to trigger game state updates.
Handlers.add(
    "RequestGameStateOnTick",
    Handlers.utils.hasMatchingTag("Action", "Tick"),
    function()
        if not busy then
            busy = true
            print(ANSIColors.gray .. "Requesting game state..." .. ANSIColors.reset)
            ao.send({ Target = Game, Action = "GetGameState" })
        else
            print("Action in progress. Skipping update.")
        end
    end
)

-- Handler to automate payment confirmation when waiting period starts.
Handlers.add(
    "AutoPay",
    Handlers.utils.hasMatchingTag("Action", "AutoPay"),
    function(msg)
        print("Automating payment confirmation.")
        ao.send({ Target = Game, Action = "Transfer", Recipient = Game, Quantity = "1000" })
    end
)

-- Handler to automatically attack when hit by another player.
Handlers.add(
    "AutoCounterAttack",
    Handlers.utils.hasMatchingTag("Action", "Hit"),
    function(msg)
        if not busy then
            busy = true
            local energy = gameState.Players[ao.id].energy
            if not energy then
                print(ANSIColors.red .. "Energy not readable." .. ANSIColors.reset)
                ao.send({ Target = Game, Action = "AttackFailed", Reason = "Energy not readable." })
            elseif energy == 0 then
                print(ANSIColors.red .. "Insufficient energy." .. ANSIColors.reset)
                ao.send({ Target = Game, Action = "AttackFailed", Reason = "No energy." })
            else
                print(ANSIColors.red .. "Counter-attacking." .. ANSIColors.reset)
                ao.send({ Target = Game, Action = "PlayerAttack", Player = ao.id, AttackEnergy = tostring(energy) })
            end
            busy = false
            ao.send({ Target = ao.id, Action = "Tick" })
        else
            print("Action in progress. Skipping counter-attack.")
        end
    end
)
