local GrabTool = {
    name = 'Grab',
    propertyNames = {
    },
    dependencies = {
        'Body',
    },
    handlers = {},
    tool = {
        icon = 'move',
        iconFamily = 'Feather',
        needsPerformingOff = true,
    },
}

registerCoreBehavior(GrabTool)


local HANDLE_TOUCH_RADIUS = 18
local HANDLE_DRAW_RADIUS = 10


-- Behavior management

function GrabTool.handlers:addBehavior(opts)
    self._gridEnabled = false
    self._gridSize, self._gridSize = UNIT, UNIT

    self._rotateIncrementEnabled = false
    self._rotateIncrementDegrees = 45
end


-- Methods

function GrabTool:getHandles()
    if self.game.performing then
        return {}
    end

    local handleTouchRadius = HANDLE_TOUCH_RADIUS * self.game:getPixelScale()
    local handleDrawRadius = HANDLE_DRAW_RADIUS * self.game:getPixelScale()

    local handles = {}

    -- Single selection?
    local singleActorId
    for actorId, component in pairs(self.components) do
        if self.game.clientId == component.clientId then
            if singleActorId then
                singleActorId = nil
                break
            end
            singleActorId = actorId
        end
    end
    if singleActorId then
        -- Figure out shape type and dimensions
        local shapeType
        local width, height = self.dependencies.Body:getRectangleSize(singleActorId)
        if width and height then
            shapeType = 'rectangle'
        else
            width, height = self.dependencies.Body:getSize(singleActorId)
            local bodyId, body = self.dependencies.Body:getBody(singleActorId)
            local fixture = body:getFixtures()[1]
            if fixture then
                local shape = fixture:getShape()
                shapeType = shape:getType()
            end
        end
        if not shapeType then
            return {}
        end

        -- Resizing
        local bodyId, body = self.dependencies.Body:getBody(singleActorId)
        for i = -1, 1, 1 do
            for j = -1, 1, 1 do
                local x, y = body:getWorldPoint(i * 0.5 * width, j * 0.5 * height)
                local handle = {
                    x = x,
                    y = y,
                    singleActorId = singleActorId,
                    width = width,
                    height = height,
                    shapeType = shapeType,
                    touchRadius = handleTouchRadius,
                }
                if shapeType == 'rectangle' and i ~= 0 and j ~= 0 then -- Corner
                    handle.handleType = 'corner'
                    table.insert(handles, handle)
                elseif i ~= 0 and j == 0 then -- Width edge
                    handle.handleType = 'width'
                    table.insert(handles, handle)
                elseif i == 0 and j ~= 0 then -- Height edge
                    handle.handleType = 'height'
                    table.insert(handles, handle)
                end
            end
        end

        -- Rotation
        local centerX, centerY = body:getWorldPoint(0, 0)
        local x, y = body:getWorldPoint(0, -0.5 * height - 6 * handleDrawRadius)
        local endX, endY = body:getWorldPoint(0, -0.5 * height) 
        table.insert(handles, {
            x = x,
            y = y,
            handleType = 'rotate',
            touchRadius = 1.5 * handleTouchRadius, -- Make rotate handles a bit easier to touch
            pivotX = centerX,
            pivotY = centerY,
            endX = endX,
            endY = endY,
        })
        return handles
    else -- Multiple selections
        -- TODO(nikki): Multiple selections
    end

    return handles
end

function GrabTool:moveRotate(moveX, moveY, rotation, pivotX, pivotY)
    -- Move and rotate multiple actors around a pivot. `rotation` may be `nil` to skip.

    local physics = self.dependencies.Body:getPhysics()
    local touchData = self:getTouchData()

    local cosRotation, sinRotation 
    if rotation then
        cosRotation, sinRotation = math.cos(rotation), math.sin(rotation)
    end

    for actorId, component in pairs(self.components) do
        if self.game.clientId == component.clientId then
            local bodyId, body = self.dependencies.Body:getBody(actorId)

            local x, y
            local angle

            -- We use these `.save` values to override stale incoming updates to the body
            -- from other hosts that had not yet received the `setPerforming` message
            if component.save then
                x, y = component.save.x, component.save.y
                angle = component.save.angle
            else
                x, y = body:getPosition()
                angle = body:getAngle()
            end

            local newX, newY, newAngle
            if rotation then
                local lX, lY = x - pivotX, y - pivotY
                lX = cosRotation * lX - sinRotation * lY
                lY = sinRotation * lX + cosRotation * lY
                if self._gridEnabled then
                    lX = util.quantize(lX, self._gridSize, x - pivotX)
                    lY = util.quantize(lY, self._gridSize, y - pivotY)
                end
                newX, newY = pivotX + moveX + lX, pivotY + moveY + lY
                newAngle = angle + rotation
            else
                newX, newY = x + moveX, y + moveY
                newAngle = angle
            end

            -- When not performing we need to actually send the sync messages. We also send a
            -- reliable message on gesture end to make sure the final state is reflected.
            local sendOpts = {
                reliable = touchData.allTouchesReleased,
                channel = touchData.allTouchesReleased and physics.reliableChannel or nil,
            }
            physics:setPosition(sendOpts, bodyId, newX, newY)
            physics:setAngle(sendOpts, bodyId, newAngle)

            -- Write back to `.save`, or clear it out if the gesture ended
            if touchData.allTouchesReleased then
                component.save = nil
            else
                component.save = {}
                component.save.x, component.save.y = newX, newY
                component.save.angle = newAngle
            end
        end
    end
end


-- Update

function GrabTool.handlers:preUpdate(dt)
    if not self:isActive() then
        return
    end

    -- Check for handle touches and steal them
    local touchData = self:getTouchData()
    if touchData.numTouches == 1 then
        local touchId, touch = next(touchData.touches)
        if touch.pressed then
            for _, handle in ipairs(self:getHandles()) do
                local distX, distY = handle.x - touch.x, handle.y - touch.y
                if distX * distX + distY * distY <= handle.touchRadius * handle.touchRadius then
                    touch.grabHandle = handle
                    touch.used = true
                    break
                end
            end
        end
    end
end

function GrabTool.handlers:update(dt)
    if not self:isActive() then
        return
    end

    local touchData = self:getTouchData()

    -- Continuing a handle gesture?
    if touchData.numTouches == 1 then
        local touchId, touch = next(touchData.touches)
        if touch.grabHandle then
            local handle = touch.grabHandle

            if handle.singleActorId then -- Single actor?
                local actorId = handle.singleActorId
                local bodyId, body = self.dependencies.Body:getBody(actorId)

                local lx, ly = body:getLocalPoint(touch.x, touch.y)

                if handle.shapeType == 'rectangle' then
                    local desiredWidth, desiredHeight = 2 * math.abs(lx), 2 * math.abs(ly)
                    if self._gridEnabled then
                        desiredWidth = util.quantize(desiredWidth, self._gridSize)
                        desiredHeight = util.quantize(desiredHeight, self._gridSize)
                    end
                    desiredWidth = math.max(MIN_BODY_SIZE, math.min(desiredWidth, MAX_BODY_SIZE))
                    desiredHeight = math.max(MIN_BODY_SIZE, math.min(desiredHeight, MAX_BODY_SIZE))
                    if handle.handleType == 'corner' then
                        local s = math.max(desiredWidth / handle.width, desiredHeight / handle.height)
                        self.dependencies.Body:setRectangleShape(actorId, s * handle.width, s * handle.height)
                    elseif handle.handleType == 'width' then
                        self.dependencies.Body:setRectangleShape(actorId, desiredWidth, handle.height)
                    elseif handle.handleType == 'height' then
                        self.dependencies.Body:setRectangleShape(actorId, handle.width, desiredHeight)
                    end
                elseif handle.shapeType == 'circle' then
                    local desiredRadius = math.sqrt(lx * lx + ly * ly)
                    if self._gridEnabled then
                        desiredRadius = util.quantize(desiredRadius, 0.5 * self._gridSize)
                    end
                    desiredRadius = math.max(0.5 * MIN_BODY_SIZE, math.min(desiredRadius, 0.5 * MAX_BODY_SIZE))
                    local physics = self.dependencies.Body:getPhysics()
                    self.dependencies.Body:setShape(actorId, physics:newCircleShape(desiredRadius))
                end
            end

            if handle.handleType == 'rotate' then
                local angle = math.atan2(touch.y - handle.pivotY, touch.x - handle.pivotX)
                local prevAngle = math.atan2(touch.y - touch.dy - handle.pivotY, touch.x - touch.dx - handle.pivotX)
                if self._rotateIncrementEnabled then
                    local increment = self._rotateIncrementDegrees * math.pi / 180
                    local initialAngle = math.atan2(touch.initialX - handle.pivotY, touch.initialY - handle.pivotX)
                    angle = util.quantize(angle, increment, initialAngle)
                    prevAngle = util.quantize(prevAngle, increment, initialAngle)
                end
                rotation = angle - prevAngle
                self:moveRotate(0, 0, rotation, handle.pivotX, handle.pivotY)
            end

            return -- We processed a handle, skip other gestures
        end
    end

    -- No handle gestures, check for other gestures
    if touchData.numTouches == 1 or touchData.numTouches == 2 then
        local moveX, moveY = 0, 0
        local rotation
        local centerX, centerY

        if touchData.numTouches == 1 then -- 1-finger move
            local touchId, touch = next(touchData.touches)
            if self._gridEnabled then
                local touchPrevX, touchPrevY = touch.x - touch.dx, touch.y - touch.dy

                local qTouchPrevX = util.quantize(touchPrevX, self._gridSize, touch.initialX)
                local qTouchPrevY = util.quantize(touchPrevY, self._gridSize, touch.initialY)

                local qTouchX = util.quantize(touch.x, self._gridSize, touch.initialX)
                local qTouchY = util.quantize(touch.y, self._gridSize, touch.initialY)

                moveX, moveY = qTouchX - qTouchPrevX, qTouchY - qTouchPrevY
            else
                moveX, moveY = touch.dx, touch.dy
            end
        elseif touchData.numTouches == 2 then -- 2-finger move and rotate
            local touchId1, touch1 = next(touchData.touches)
            local touchId2, touch2 = next(touchData.touches, touchId1)

            local touch1PrevX, touch1PrevY = touch1.x - touch1.dx, touch1.y - touch1.dy
            local touch2PrevX, touch2PrevY = touch2.x - touch2.dx, touch2.y - touch2.dy

            centerX, centerY = 0.5 * (touch1.x + touch2.x), 0.5 * (touch1.y + touch2.y)
            local centerPrevX, centerPrevY = 0.5 * (touch1PrevX + touch2PrevX), 0.5 * (touch1PrevY + touch2PrevY)

            if self._gridEnabled then
                local centerInitialX = 0.5 * (touch1.initialX + touch2.initialX)
                local centerInitialY = 0.5 * (touch1.initialY + touch2.initialY)

                centerPrevX = util.quantize(centerPrevX, self._gridSize, centerInitialX)
                centerPrevY = util.quantize(centerPrevY, self._gridSize, centerInitialY)

                centerX = util.quantize(centerX, self._gridSize, centerInitialX)
                centerY = util.quantize(centerY, self._gridSize, centerInitialY)
            end

            moveX, moveY = centerX - centerPrevX, centerY - centerPrevY

            local angle = math.atan2(touch2.y - touch1.y, touch2.x - touch1.x)
            local prevAngle = math.atan2(touch2PrevY - touch1PrevY, touch2PrevX - touch1PrevX)
            if self._rotateIncrementEnabled then
                local increment = self._rotateIncrementDegrees * math.pi / 180
                local initialAngle = math.atan2(
                    touch2.initialY - touch1.initialY, touch2.initialX - touch1.initialX)
                angle = util.quantize(angle, increment, initialAngle)
                prevAngle = util.quantize(prevAngle, increment, initialAngle)
            end
            rotation = angle - prevAngle
        end

        self:moveRotate(moveX, moveY, rotation, centerX, centerY)
    end
end


-- Draw

local gridShader
if love.graphics then
    gridShader = love.graphics.newShader([[
        uniform float gridSize;
        uniform float dotRadius;
        vec4 effect(vec4 color, Image tex, vec2 texCoords, vec2 screenCoords)
        {
            vec2 f = mod(screenCoords + dotRadius, gridSize);
            float l = length(f - dotRadius);
            float s = 1.0 - smoothstep(dotRadius - 1.0, dotRadius + 1.0, l);
            return vec4(color.rgb, s * color.a);
        }
    ]], [[
        vec4 position(mat4 transformProjection, vec4 vertexPosition)
        {
            return transformProjection * vertexPosition;
        }
    ]])
end

function GrabTool.handlers:drawOverlay(dt)
    if not self:isActive() then
        return
    end

    if self._gridEnabled and self._gridSize > 0 then
        love.graphics.push('all')

        local dpiScale = love.graphics.getDPIScale()
        gridShader:send('gridSize', dpiScale * self._gridSize * self.game:getViewScale())
        gridShader:send('dotRadius', dpiScale * 2)
        love.graphics.setShader(gridShader)

        local windowWidth, windowHeight = love.graphics.getDimensions()
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.origin()
        love.graphics.rectangle('fill', 0, 0, windowWidth, windowHeight)

        love.graphics.pop()
    end

    local handleDrawRadius = HANDLE_DRAW_RADIUS * self.game:getPixelScale()
    for _, handle in ipairs(self:getHandles()) do
        love.graphics.circle('fill', handle.x, handle.y, handleDrawRadius)
        if handle.endX and handle.endY then
            love.graphics.line(handle.x, handle.y, handle.endX, handle.endY)
        end
    end
end


-- UI

function GrabTool.handlers:uiSettings(closeSettings)
    -- Grid
    ui.box('grid box', { flexDirection = 'row' }, function()
        self._gridEnabled = ui.toggle('grid off', 'grid on', self._gridEnabled)
        if self._gridEnabled then
            ui.box('grid size box', {
                marginLeft = 16,
                flex = 1,
            }, function()
                self._gridSize = ui.numberInput('grid size', self._gridSize, { min = 0, step = 50 })
            end)
        end
    end)

    -- Rotate increment
    ui.box('rotate increment box', { flexDirection = 'row' }, function()
        self._rotateIncrementEnabled = ui.toggle(
            'rotate snap off', 'rotate snap on', self._rotateIncrementEnabled)
        if self._rotateIncrementEnabled then
            ui.box('rotate increment value box', {
                marginLeft = 16,
                flex = 1,
            }, function()
                self._rotateIncrementDegrees = ui.numberInput(
                    'increment (degrees)', self._rotateIncrementDegrees, { min = 0, step = 5 })
            end)
        end
    end)
end

