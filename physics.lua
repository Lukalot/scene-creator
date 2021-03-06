local Physics = {}

-- A `sync` is a serialization of frequently-varying object state (such as a body's position or velocity)

local function readBodySync(body)
    local x, y = body:getPosition()
    local vx, vy = body:getLinearVelocity()
    local a = body:getAngle()
    local va = body:getAngularVelocity()
    return x, y, vx, vy, a, va
end

local function writeBodySync(body, x, y, vx, vy, a, va)
    body:setPosition(x, y)
    body:setLinearVelocity(vx, vy)
    body:setAngle(a)
    body:setAngularVelocity(va)
end

local function writeInterpolatedBodySync(body, interpolatedTick, history, currentTick)
    -- Is there an exact entry?
    if history[interpolatedTick] then
        writeBodySync(body, unpack(history[interpolatedTick]))
        return true
    end

    -- Find closest ticks before and after the one we want to interpolate to
    local beforeTick, afterTick
    for i in pairs(history) do
        if i < interpolatedTick and (not beforeTick or i > beforeTick) then
            beforeTick = i
        end
        if i >= interpolatedTick and (not afterTick or i < afterTick) then
            afterTick = i
        end
    end
    if beforeTick and afterTick then
        local f = (interpolatedTick - beforeTick) / (afterTick - beforeTick)
        local beforeSync, afterSync = history[beforeTick], history[afterTick]
        local interpolatedSync = {}
        for i = 1, #beforeSync do
            interpolatedSync[i] = beforeSync[i] + f * (afterSync[i] - beforeSync[i])
        end
        writeBodySync(body, unpack(interpolatedSync))
        return true
    end
    if beforeTick then
        afterTick = currentTick
        local f = (interpolatedTick - beforeTick) / (afterTick - beforeTick)
        local beforeSync, afterSync = history[beforeTick], {readBodySync(body)}
        local interpolatedSync = {}
        for i = 1, #beforeSync do
            interpolatedSync[i] = beforeSync[i] + f * (afterSync[i] - beforeSync[i])
        end
        writeBodySync(body, unpack(interpolatedSync))
        return true
    end
    return false
end

-- Each physics method has three parts: a message kind definition, a message receiver, and a message send wrapper
function Physics:_defineMethod(methodName, opts)
    local kind = self.kindPrefix .. methodName

    -- Receiver
    self.game.receivers[kind] =
        assert(opts.receiver, "_defineMethod: need to define a receiver for `" .. methodName .. "`")

    -- Sender -- default sender just forwards parameters
    self[methodName] = (opts.sender and opts.sender(kind)) or function(_, ...)
            self.game:send({kind = kind}, ...)
        end
end

-- All `love.physics.new<X>` as `Physics:new<X>`, returns object id
local CONSTRUCTOR_NAMES = {
    "newBody",
    "newChainShape",
    "newCircleShape",
    "newDistanceJoint",
    "newEdgeShape",
    "newFixture",
    "newFrictionJoint",
    "newGearJoint",
    "newMotorJoint",
    "newMouseJoint",
    "newPolygonShape",
    "newPrismaticJoint",
    "newPulleyJoint",
    "newRectangleShape",
    "newRevoluteJoint",
    "newRopeJoint",
    "newWeldJoint",
    "newWheelJoint",
    "newWorld"
}

-- All `:<foo>` as `Physics:<foo>` with object id as first param
local RELIABLE_METHOD_NAMES = {
    "setActive",
    "setAngle",
    "setAngularDamping",
    "setAngularOffset",
    "setAngularVelocity",
    "setAwake",
    "setBullet",
    "setCategory",
    "setContactFilter",
    "setCorrectionFactor",
    "setDampingRatio",
    "setDensity",
    "setEnabled",
    "setFilterData",
    "setFixedRotation",
    "setFrequency",
    "setFriction",
    "setGravity",
    "setGravityScale",
    "setGroupIndex",
    "setInertia",
    "setLength",
    "setLimits",
    "setLimitsEnabled",
    "setLinearDamping",
    "setLinearOffset",
    "setLinearVelocity",
    "setLowerLimit",
    "setMask",
    "setMass",
    "setMassData",
    "setMaxForce",
    "setMaxLength",
    "setMaxMotorForce",
    "setMaxMotorTorque",
    "setMaxTorque",
    "setMotorEnabled",
    "setMotorSpeed",
    "setNextVertex",
    "setPoint",
    "setPosition",
    "setPreviousVertex",
    "setRadius",
    "setRatio",
    "setRestitution",
    "setSensor",
    "setSleepingAllowed",
    "setSpringDampingRatio",
    "setSpringFrequency",
    "setTangentSpeed",
    "setTarget",
    "setType",
    "setUpperLimit",
    "setX",
    "setY",
    "setUserData",
    "resetMassData"
}

function Physics.new(opts)
    local self = setmetatable({}, {__index = Physics})

    self.historyPool = {}

    -- Options

    self.game = assert(opts.game, "Physics.new: need `opts.game`")
    local game = self.game -- Keep an upvalue for closures to use

    self.updateRate = opts.updateRate or 144
    self.historySize = opts.historySize or (self.updateRate * 0.5)
    self.defaultInterpolationDelay = opts.defaultInterpolationDelay or 0.08
    self.softOwnershipSetDelay = opts.softOwnershipSetDelay or 0.8

    self.kindPrefix = opts.kindPrefix or "physics_"

    -- Object data tables

    self.idToObject = {}

    self.idToWorld = {}

    self.objectDatas = {}

    self.ownerIdToObjects = {}
    setmetatable(
        self.ownerIdToObjects,
        {
            __index = function(t, k)
                local v = {}
                t[k] = v
                return v
            end
        }
    )

    -- Other state

    self.lastNetworkIssueTime = nil

    -- Generated constructors

    for _, methodName in ipairs(CONSTRUCTOR_NAMES) do
        self:_defineMethod(
            methodName,
            {
                receiver = function(_, time, id, ...)
                    (function(...)
                        if self.idToObject[id] then
                            error(methodName .. ": object with this id " .. id .. " already exists")
                        end
                        local obj
                        local succeeded, err =
                            pcall(
                            function(...)
                                obj = love.physics[methodName](...)
                            end,
                            ...
                        )
                        if succeeded then
                            self.idToObject[id] = obj
                            local objectData = {id = id}
                            if methodName == "newBody" then
                                objectData.ownerId = nil
                                objectData.lastSetOwnerTickCount = nil
                                objectData.interpolationDelay = nil
                                objectData.clientSyncHistory = {}
                                if self.game.server then
                                    objectData.history = {}
                                end
                            end
                            if methodName == "newWorld" then
                                self.idToWorld[id] = obj
                                objectData.updateTimeRemaining = 0
                                objectData.tickCount = 0
                                objectData.nextRewindFrom = nil
                                obj:setCallbacks(self._beginContact, self._endContact, self._preSolve, self._postSolve)
                                if self.game.client then
                                    objectData.lastServerSyncTime = nil
                                end
                            end
                            self.objectDatas[obj] = objectData
                        else
                            error(methodName .. ": " .. err)
                        end
                    end)(self:_resolveIds(...))
                end,
                sender = function(kind)
                    return function(_, ...)
                        local id = game:generateId()
                        game:send({kind = kind}, id, ...)
                        return id
                    end
                end
            }
        )
    end

    -- Generated reliable methods

    for _, methodName in ipairs(RELIABLE_METHOD_NAMES) do
        self:_defineMethod(
            methodName,
            {
                receiver = function(_, time, id, ...)
                    (function(...)
                        local obj = self.idToObject[id]
                        if not obj then
                            error(methodName .. ": no / bad `id` given as first parameter")
                        end
                        local succeeded, err =
                            pcall(
                            function(...)
                                obj[methodName](obj, ...)
                            end,
                            ...
                        )
                        if not succeeded then
                            error(methodName .. ": " .. err)
                        end
                    end)(self:_resolveIds(...))
                end,
                sender = function(kind)
                    return function(_, maybeOpts, ...)
                        if type(maybeOpts) == "table" then
                            game:send(setmetatable({kind = kind}, {__index = maybeOpts}), ...)
                        else
                            game:send({kind = kind}, maybeOpts, ...)
                        end
                    end
                end
            }
        )
    end

    -- Object destruction

    self:_defineMethod(
        "destroyObject",
        {
            receiver = function(_, time, id)
                local obj = self.idToObject[id]
                if not obj then
                    error("destroyObject: no / bad `id`")
                end

                local function clearMapEntries(id, obj)
                    self.objectDatas[obj] = nil
                    self.idToWorld[id] = nil
                    self.idToObject[id] = nil
                end

                -- Visit associated objects
                if obj:typeOf("Body") then
                    for _, fixture in pairs(obj:getFixtures()) do
                        local fixtureData = self.objectDatas[fixture]
                        if fixtureData then
                            clearMapEntries(fixtureData.id, fixture)
                        end
                    end
                    for _, joint in pairs(obj:getJoints()) do
                        local jointData = self.objectDatas[joint]
                        if jointData then
                            handleId(jointData.id, joint)
                        end
                    end
                end

                -- Visit this object
                local objectData = self.objectDatas[obj]
                if objectData.ownerId then
                    self.ownerIdToObjects[objectData.ownerId][obj] = nil
                end
                local history = objectData.history
                if history then -- Return history entries to pool
                    for _, entry in pairs(history) do
                        table.insert(self.historyPool, entry)
                    end
                end
                clearMapEntries(id, obj)

                -- Call actual object destructor (calls destructors for associated objects automatically)
                if obj.destroy then
                    obj:destroy()
                else
                    obj:release()
                end
            end
        }
    )

    -- Object ownership

    self:_defineMethod(
        "setOwner",
        {
            receiver = function(_, time, tickCount, id, newOwnerId, strongOwned, interpolationDelay)
                local obj = self.idToObject[id]
                if not obj then
                    error("setOwner: no / bad `id`")
                end

                local objectData = self.objectDatas[obj]

                if newOwnerId == nil then -- Removing owner
                    if objectData.ownerId == nil then
                        return
                    else
                        self.ownerIdToObjects[objectData.ownerId][obj] = nil
                        objectData.ownerId = nil
                    end

                    objectData.lastSetOwnerTickCount = nil
                else -- Setting owner
                    if objectData.ownerId ~= nil then -- Already owned by someone?
                        if objectData.ownerId == newOwnerId then
                            return -- Already owned by this client, nothing to do
                        else
                            self.ownerIdToObjects[objectData.ownerId][obj] = nil
                            objectData.ownerId = nil
                        end
                    end

                    self.ownerIdToObjects[newOwnerId][obj] = true
                    objectData.ownerId = newOwnerId
                    objectData.interpolationDelay = interpolationDelay
                    objectData.lastSetOwnerTickCount = tickCount
                end

                if strongOwned then
                    objectData.strongOwned = true
                else
                    objectData.strongOwned = nil
                end
            end,
            sender = function(kind)
                return function(_, id, ...)
                    local obj = self.idToObject[id]
                    game:send({kind = kind}, obj and self.objectDatas[obj:getWorld()].tickCount or 0, id, ...)
                end
            end
        }
    )

    -- Collision callbacks

    function self._beginContact(fixture1, fixture2, contact, ...)
        if self.onContact then
            self.onContact("begin", fixture1, fixture2, contact, ...)
        end
    end

    function self._endContact(fixture1, fixture2, contact, ...)
        if self.onContact then
            self.onContact("end", fixture1, fixture2, contact, ...)
        end
    end

    function self._preSolve(fixture1, fixture2, contact, ...)
        if self.onSolve then
            self.onSolve("pre", fixture1, fixture2, contact, ...)
        end
    end

    function self._postSolve(fixture1, fixture2, contact, ...)
        if self.game.client then -- Spread ownerships from strong -> weak
            if fixture1:isSensor() or fixture2:isSensor() then
                return
            end

            local body1 = fixture1:getBody()
            local body2 = fixture2:getBody()

            if body1:getType() == "static" or body2:getType() == "static" then
                return
            end

            local worldData = self.objectDatas[body1:getWorld()]

            local d1 = self.objectDatas[body1]
            local d2 = self.objectDatas[body2]

            if d1 and d2 then
                local function check(d1, d2)
                    if d1.ownerId ~= nil and not d2.strongOwned then
                        if d2.ownerId ~= d1.ownerId then
                            -- Enough time since last owner setting?
                            if
                                not d2.lastSetOwnerTickCount or
                                    worldData.tickCount - d2.lastSetOwnerTickCount >=
                                        self.softOwnershipSetDelay * self.updateRate
                             then
                                -- Strong owner or more recently set?
                                if
                                    d1.strongOwned or not d2.lastSetOwnerTickCount or
                                        (d1.lastSetOwnerTickCount and
                                            d1.lastSetOwnerTickCount > d2.lastSetOwnerTickCount)
                                 then
                                    self:setOwner(d2.id, d1.ownerId, false, d1.interpolationDelay)
                                end
                            end
                        end
                    end
                end
                check(d1, d2)
                check(d2, d1)
            end
        end

        if self.onSolve then
            self.onSolve("post", fixture1, fixture2, contact, ...)
        end
    end

    return self
end

function Physics:_resolveIds(firstArg, ...)
    local firstResult = self.idToObject[firstArg] or firstArg
    if select("#", ...) == 0 then
        return firstResult
    end
    return firstResult, self:_resolveIds(...)
end

function Physics:objectForId(id)
    return self.idToObject[id]
end

function Physics:idForObject(obj)
    local objectData = self.objectDatas[obj]
    if objectData then
        return objectData.id
    end
    return nil
end

function Physics:getWorld()
    local resultId, resultWorld
    for id, world in pairs(self.idToWorld) do
        if resultId then
            error("getWorld: there are multiple worlds -- you will need to keep track of their ids yourself")
        end
        resultId, resultWorld = id, world
    end
    return resultId, resultWorld
end

function Physics:_tickWorld(world, worldData)
    world:update(1 / self.updateRate)
    worldData.tickCount = worldData.tickCount + 1

    -- Interpolate objects owned by others
    for ownerId, objs in pairs(self.ownerIdToObjects) do
        if ownerId ~= self.game.clientId then
            for obj in pairs(objs) do
                local objectData = self.objectDatas[obj]
                local clientSyncHistory = objectData.clientSyncHistory
                if next(clientSyncHistory) ~= nil then
                    -- Clear out old history
                    for i in pairs(clientSyncHistory) do
                        if i <= worldData.tickCount - self.historySize then
                            clientSyncHistory[i] = nil
                        end
                    end

                    -- Interpolate
                    local interpolationDelay = objectData.interpolationDelay or self.defaultInterpolationDelay
                    if not objectData.strongOwned then
                        interpolationDelay = 0.8 * interpolationDelay
                    end
                    local interpolatedTick = math.floor(worldData.tickCount - interpolationDelay * self.updateRate)
                    writeInterpolatedBodySync(obj, interpolatedTick, clientSyncHistory, worldData.tickCount)
                end
            end
        end
    end

    -- Server keeps full history
    if self.game.server then
        for _, body in ipairs(world:getBodies()) do
            local objectData = self.objectDatas[body]
            if objectData then
                local history = objectData.history

                -- Clear old history, returning to pool
                if history[worldData.tickCount - self.historySize] then
                    table.insert(self.historyPool, history[worldData.tickCount - self.historySize])
                    history[worldData.tickCount - self.historySize] = nil
                end

                -- Write to history if not static or sleeping
                if body:isAwake() and body:getType() ~= "static" then
                    local pooled = table.remove(self.historyPool)
                    if pooled then
                        pooled[1], pooled[2], pooled[3], pooled[4], pooled[5], pooled[6] = readBodySync(body)
                        history[worldData.tickCount] = pooled
                    else
                        history[worldData.tickCount] = {readBodySync(body)}
                    end
                end
            end
        end
    end
end

function Physics:updateWorld(worldId, dt)
    local world = assert(self.idToObject[worldId], "updateWorld: no world with this id")
    local worldData = self.objectDatas[world]

    -- If server, perform any outstanding rewinds we need to do
    local restore = {}
    if self.game.server and worldData.nextRewindFrom then
        -- Rewind
        for _, body in ipairs(world:getBodies()) do
            if body:getType() ~= "static" then
                local objectData = self.objectDatas[body]
                if objectData then
                    local history = objectData.history
                    local clientSyncHistory = objectData.clientSyncHistory

                    -- Interpolate from client syncs, or use full history if no client sync interpolation worked
                    if
                        not writeInterpolatedBodySync(
                            body,
                            worldData.nextRewindFrom,
                            clientSyncHistory,
                            worldData.tickCount
                        )
                     then
                        if history[worldData.nextRewindFrom] then
                            writeBodySync(body, unpack(history[worldData.nextRewindFrom]))
                        else
                            -- Couldn't rewind, restore to this state later
                            restore[body] = {readBodySync(body)}
                        end
                    end
                end
            end
        end

        -- Play back
        local latestTickCount = worldData.tickCount
        worldData.tickCount = worldData.nextRewindFrom
        while worldData.tickCount < latestTickCount do
            self:_tickWorld(world, worldData)
        end
        worldData.nextRewindFrom = nil
    end

    -- Catch up world to current time
    worldData.updateTimeRemaining = worldData.updateTimeRemaining + dt
    local worldTicks, maxWorldTicks = 0, 60
    while worldData.updateTimeRemaining >= 1 / self.updateRate
       and worldTicks < maxWorldTicks -- don't block on excessive updates
    do
        self:_tickWorld(world, worldData)
        worldData.updateTimeRemaining = worldData.updateTimeRemaining - 1 / self.updateRate
        worldTicks = worldTicks + 1
        if worldTicks >= maxWorldTicks then
           worldData.updateTimeRemaining = 0
        end
    end

    -- Restore bodies that weren't actually rewound
    for body, restoreSync in pairs(restore) do
        writeBodySync(body, unpack(restoreSync))
    end

    return true
end

function Physics:getOwner(idOrObject)
    local objectData = self.objectDatas[idOrObject] or self.objectDatas[self.idToObject[idOrObject]]
    if objectData then
        return objectData.ownerId, objectData.strongOwned
    end
end

function Physics:networkIssueDetected()
    return self.lastNetworkIssueTime and love.timer.getTime() - self.lastNetworkIssueTime < 1.5
end

return Physics
