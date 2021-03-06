local SlingBehavior =
    defineCoreBehavior {
    name = "Sling",
    displayName = "Slingshot",
    dependencies = {
        "Moving",
        "Body"
    },
    allowsDisableWithoutRemoval = true,
    propertySpecs = {
       speed = {
          method = 'numberInput',
          label = 'Speed',
          props = { min = 0, max = 10, step = 0.5 },
          rules = {
             set = true,
             get = true,
          },
       },
    },
}

local MAX_DRAG_LENGTH = 3 * UNIT

local DRAW_MULTIPLIER = 0.8

local CIRCLE_RADIUS = 18 * UNIT
local TRIANGLE_LENGTH = 25 * UNIT
local TRIANGLE_WIDTH = 10 * UNIT

-- Component management

function SlingBehavior.handlers:addComponent(component, bp, opts)
    component.properties.speed = bp.speed or 3.5
end

function SlingBehavior.handlers:blueprintComponent(component, bp)
    bp.speed = component.properties.speed
end

function SlingBehavior.getters:isInteractive(component)
   return not component.disabled
end

-- Perform

function SlingBehavior.handlers:postPerform(dt)
    -- Do this in `postPerform` to allow other behaviors to steal the touch

    -- Client-only
    if not self.game.clientId then
        return
    end

    -- Make sure we have some actors
    if not self:hasAnyEnabledComponent() then
        return
    end

    local physics = self.dependencies.Body:getPhysics()

    local touchData = self:getTouchData()
    if touchData.maxNumTouches == 1 then
        local touchId, touch = next(touchData.touches)
        local cameraX, cameraY = self.game:getCameraPosition()
        if not touch.used and touch.movedNear then
           touch.usedBy = touch.usedBy or {}
           if not touch.usedBy.sling then
              touch.usedBy.sling = true -- mark the touch without `used` so we detect player interaction
              self._initialX, self._initialY = touch.initialX - cameraX, touch.initialY - cameraY
           end
        end
        if touchData.allTouchesReleased then
            if not touch.used and touch.movedNear then
                -- sling is measured in scene space, but invariant to camera position
                local touchX, touchY = touch.x - cameraX, touch.y - cameraY
                local dragX, dragY = self._initialX - touchX, self._initialY - touchY
                local dragLen = math.sqrt(dragX * dragX + dragY * dragY)
                if dragLen > MAX_DRAG_LENGTH then
                    dragX, dragY = dragX * MAX_DRAG_LENGTH / dragLen, dragY * MAX_DRAG_LENGTH / dragLen
                    dragLen = MAX_DRAG_LENGTH
                end

                for actorId, component in pairs(self.components) do
                    if not component.disabled then
                        -- Own the body, then just set velocity locally and the physics system will sync it
                        local bodyId, body = self.dependencies.Body:getBody(actorId)
                        if physics:getOwner(bodyId) ~= self.game.clientId then
                            physics:setOwner(bodyId, self.game.clientId, true, 0)
                        end
                        body:setLinearVelocity(component.properties.speed * dragX, component.properties.speed * dragY)
                        self:fireTrigger("sling", actorId)
                    end
                end
            end
        end
    end
end

SlingBehavior.triggers.sling = {
   description = "When this is slung",
   category = "controls",
}

-- Draw

function SlingBehavior.handlers:drawOverlay()
    if not self.game.performing then
        return
    end

    -- Make sure we have some actors
    if not self:hasAnyEnabledComponent() then
        return
    end

    -- Look for a single-finger drag
    local touchData = self:getTouchData()
    if touchData.maxNumTouches == 1 then
        local touchId, touch = next(touchData.touches)
        if not touch.used and touch.movedNear then
            local cameraX, cameraY = self.game:getCameraPosition()
            local touchX, touchY = touch.x - cameraX, touch.y - cameraY
            local dragX, dragY = self._initialX - touchX, self._initialY - touchY
            local dragLen = math.sqrt(dragX * dragX + dragY * dragY)
            if dragLen > 0 then
                if dragLen > MAX_DRAG_LENGTH then
                    dragX, dragY = dragX * MAX_DRAG_LENGTH / dragLen, dragY * MAX_DRAG_LENGTH / dragLen
                    dragLen = MAX_DRAG_LENGTH
                end

                love.graphics.push()
                love.graphics.translate(cameraX, cameraY)

                love.graphics.setColor(1, 1, 1, 0.8)
                love.graphics.setLineWidth(1.25 * self.game:getPixelScale())

                local circleRadius = CIRCLE_RADIUS * self.game:getPixelScale()
                local triangleLength = TRIANGLE_LENGTH * self.game:getPixelScale()
                local triangleWidth = TRIANGLE_WIDTH * self.game:getPixelScale()

                -- Circle with solid outline and transparent fill
                love.graphics.circle("line", self._initialX, self._initialY, circleRadius)
                love.graphics.setColor(1, 1, 1, 0.3)
                love.graphics.circle("fill", self._initialX, self._initialY, circleRadius)
                love.graphics.setColor(1, 1, 1, 0.8)

                -- Line and triangle
                local endX, endY = self._initialX + DRAW_MULTIPLIER * dragX, self._initialY + DRAW_MULTIPLIER * dragY
                love.graphics.line(
                    self._initialX,
                    self._initialY,
                    endX - triangleLength * dragX / dragLen,
                    endY - triangleLength * dragY / dragLen
                )
                love.graphics.polygon(
                    "fill",
                    endX,
                    endY,
                    endX - triangleLength * dragX / dragLen - triangleWidth * dragY / dragLen,
                    endY - triangleLength * dragY / dragLen + triangleWidth * dragX / dragLen,
                    endX - triangleLength * dragX / dragLen + triangleWidth * dragY / dragLen,
                    endY - triangleLength * dragY / dragLen - triangleWidth * dragX / dragLen
                )
                love.graphics.pop()
            end
        end
    end
end
