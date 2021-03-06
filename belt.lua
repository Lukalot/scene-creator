-- Constants

local OS = love.system.getOS()

local BELT_HEIGHT = 200

local ELEM_SIZE = 170
local ELEM_GAP = 20

local DECEL_X = 2200

local SNAP_THRESHOLD_VX = 200

local SHOW_HIDE_VY = 1200

local ENABLE_HAPTICS = true

local TOP_BELT = true -- Whether to draw belt at the top of the card

-- Start / stop

function Common:startBelt()
    self.beltDirty = true

    -- Each elem holds `entryId` + non-persistent info like renderable image, x position etc. 
    self.beltElems = {} 

    self.beltCursorX = 0
    self.beltCursorVX = 0

    self.beltVisible = false

    self.beltTop = nil -- Initialized on first update
    self.beltBottom = nil

    self.beltTargetIndex = nil -- Target element to scroll to if not `nil`
    
    self.beltEntryId = nil -- Entry id of currently highlighted belt element

    self.beltLastVibrated = love.timer.getTime()

    self.beltHighlightCanvas = nil -- Set up lazily
    self.beltHighlightCanvas2 = nil

    -- Renders grey if the pixel is fully transparent, and white otherwise.
    -- Used with a multiply blend mode to darken the screen.
    self.beltHighlightShader = love.graphics.newShader([[
        vec4 effect(vec4 color, Image texture, vec2 texCoords, vec2 screenCoords) {
            color = Texel(texture, texCoords);
            if (color.a == 0.0) {
                color = vec4(0.35, 0.35, 0.35, 1.0);
            } else {
                color = vec4(1.0, 1.0, 1.0, 1.0);
            }
            return color;
        }
    ]])

    -- Renders grey around edges, black otherwise
    self.beltOutlineShader = love.graphics.newShader([[
        vec4 effect(vec4 color, Image texture, vec2 texCoords, vec2 screenCoords) {
            vec4 c = Texel(texture, texCoords);
            if (c.a == 0.0) {
                float l = Texel(texture, vec2(texCoords.x - 1.0 / love_ScreenSize.x, texCoords.y)).a - c.a;
                float r = Texel(texture, vec2(texCoords.x + 1.0 / love_ScreenSize.x, texCoords.y)).a - c.a;
                float u = Texel(texture, vec2(texCoords.x, texCoords.y - 1.0 / love_ScreenSize.y)).a - c.a;
                float d = Texel(texture, vec2(texCoords.x, texCoords.y + 1.0 / love_ScreenSize.y)).a - c.a;
                float m = max(max(abs(l), abs(r)), max(abs(u), abs(d)));
                return vec4(m, m, m, 1.0);
            } else {
                return vec4(0.0, 0.0, 0.0, 1.0);
            }
        }
    ]])
    self.beltOutlineThickeningShader = love.graphics.newShader([[
        vec4 effect(vec4 color, Image texture, vec2 texCoords, vec2 screenCoords) {
            float c = Texel(texture, texCoords).r;
            float l = Texel(texture, vec2(texCoords.x - 1.0 / love_ScreenSize.x, texCoords.y)).r;
            float r = Texel(texture, vec2(texCoords.x + 1.0 / love_ScreenSize.x, texCoords.y)).r;
            float u = Texel(texture, vec2(texCoords.x, texCoords.y - 1.0 / love_ScreenSize.y)).r;
            float d = Texel(texture, vec2(texCoords.x, texCoords.y + 1.0 / love_ScreenSize.y)).r;
            float m = max(c, max(max(l, r), max(u, d)));
            return vec4(m, m, m, 1.0);
        }
    ]])

    -- Below from https://github.com/vrld/moonshine/blob/d39271e0c000e2fedbc2e3ad286b78b5a5146065/boxblur.lua#L20
    self.beltOutlineBlurShader = love.graphics.newShader([[
        #define RADIUS 1.0
        extern vec2 direction;
        vec4 effect(vec4 color, Image texture, vec2 tc, vec2 _) {
            vec4 c = vec4(0.0);
            for (float i = -RADIUS; i <= RADIUS; i += 1.0)
            {
                c += Texel(texture, tc + i * direction);
            }
            return c / (2.0 * RADIUS + 1.0) * color;
        }
    ]])
end

-- Show / hide

jsEvents.listen(
    "SHOW_BELT",
    function()
        local self = currentInstance()
        if self then
            --self.beltVisible = true
        end
    end
)

jsEvents.listen(
    "HIDE_BELT",
    function()
        local self = currentInstance()
        if self then
            self.beltVisible = false
        end
    end
)

jsEvents.listen(
    "TOGGLE_BELT",
    function()
        local self = currentInstance()
        if self then
            self.beltVisible = not self.beltVisible
        end
    end
)

-- Focus

function Common:focusEntryInBelt(entryId, opts)
    opts = opts or {}
    self:syncBelt() -- Often called right after a change, so let's sync
    for i, elem in ipairs(self.beltElems) do
        if elem.entryId == entryId then
            self.beltTargetIndex = i
            self.beltEntryId = entryId
            if not opts.noShow then
                --self.beltVisible = true
            end
            break
        end
    end
end

-- Update

function Common:updateBeltElemImage(elem, entry)
    -- Create renderable texture from saved preview data in blueprint
    local decoded = love.data.decode("data", "base64", entry.base64Png)
    local imgData = love.image.newImageData(decoded)
    elem.image = love.graphics.newImage(imgData)
    elem.base64Png = entry.base64Png
end

function Common:markBeltDirty()
    -- Mark belt as needing synchronization
    self.beltDirty = true
end

function Common:syncBelt()
    -- Synchronize belt data with library entries

    if not self.beltDirty then
        return
    end

    -- Update images that changed
    for _, elem in ipairs(self.beltElems) do
        local entry = self.library[elem.entryId]
        -- Lua interns strings so hopefully the comparison is quick when equal
        if entry and entry.base64Png ~= elem.base64Png then 
            self:updateBeltElemImage(elem, entry)
        end
    end

    -- Add new elements to belt
    local currElemIds = {}
    for _, elem in ipairs(self.beltElems) do
        currElemIds[elem.entryId] = true
    end
    for entryId, entry in pairs(self.library) do
        if not currElemIds[entryId] then
            local newElem = {}
            newElem.entryId = entry.entryId
            if entry.base64Png then
                self:updateBeltElemImage(newElem, entry)
            end
            table.insert(self.beltElems, newElem)
        end
    end

    -- Sort belt
    table.sort(self.beltElems, function(a, b)
        local entryA = self.library[a.entryId]
        local entryB = self.library[b.entryId]
        if entryA.beltOrder ~= entryB.beltOrder then
            return (entryA.beltOrder or 0) < (entryB.beltOrder or 0)
        end
        return entryA.title < entryB.title
    end)

    -- Calculate positions
    for i, elem in ipairs(self.beltElems) do
        elem.x = (ELEM_SIZE + ELEM_GAP) * (i - 1)
    end

    self.beltDirty = false
end

function Common:updateBelt(dt)
    -- Make belt snap quicker. Resorted to making time faster after tuning the
    -- other constants for spring damping + deceleration...
    local origDt = dt
    dt = 1.6 * dt 

    -- Stay in sync
    self:syncBelt()

    if next(self.selectedActorIds) then
        -- For now we'll dismiss belt when something is selected. Should make it so
        -- the inspector and the belt never try to be visible at the same time.
        self.beltVisible = false

        -- Focus the blueprint of some selected actor so that we'll be on it
        -- if the user opens the belt again
        local needToFocus = true
        for actorId in pairs(self.selectedActorIds) do
            local actor = self.actors[actorId]
            if actor and actor.parentEntryId == self.beltEntryId then
                -- `next(...)` below may not consistently give us the same
                -- item, so prevent trashing
                needToFocus = false
            end
        end
        if needToFocus then
            local actorId = next(self.selectedActorIds)
            local actor = self.actors[actorId]
            local entry = actor and actor.parentEntryId and self.library[actor.parentEntryId]
            if entry and not entry.isCore then
                self:focusEntryInBelt(entry.entryId, { noShow = true })
            end
        end
    end

    local currTime = love.timer.getTime()
    local windowWidth, windowHeight = love.graphics.getDimensions()

    local prevBeltCursorX = self.beltCursorX
    local prevBeltCursorVX = self.beltCursorVX

    -- Animate belt show / hide
    if not TOP_BELT then
        if not self.beltTop then
            self.beltTop = windowHeight -- Initialization
        end
        if self.beltVisible == false and self.beltTop < windowHeight then
            self.beltTop = self.beltTop + SHOW_HIDE_VY * origDt
            if self.beltTop > windowHeight then
                self.beltTop = windowHeight
            end
        end
        if self.beltVisible == true and self.beltTop > windowHeight - BELT_HEIGHT then
            self.beltTop = self.beltTop - SHOW_HIDE_VY * origDt
            if self.beltTop < windowHeight - BELT_HEIGHT then
                self.beltTop = windowHeight - BELT_HEIGHT
            end
        end
        self.beltBottom = self.beltTop + BELT_HEIGHT
    else
        if not self.beltBottom then
            self.beltBottom = 0 -- Initialization
        end
        if self.beltVisible == false and self.beltBottom > 0 then
            self.beltBottom = self.beltBottom - SHOW_HIDE_VY * origDt
            if self.beltBottom < 0 then
                self.beltBottom = 0
            end
        end
        if self.beltVisible == true and self.beltBottom < BELT_HEIGHT then
            self.beltBottom = self.beltBottom + SHOW_HIDE_VY * origDt
            if self.beltBottom > BELT_HEIGHT then
                self.beltBottom = BELT_HEIGHT
            end
        end
        self.beltTop = self.beltBottom - BELT_HEIGHT
    end

    -- Skip all this logic when hidden and animations are done
    local hidden
    if TOP_BELT then
        hidden = self.beltBottom <= 0
    else
        hidden = self.beltTop >= windowHeight
    end
    if hidden and self.beltCursorVX == 0 then
        -- Scroll to target immediately so we're there and don't do an
        -- animation when opening belt again
        -- TODO(nikki): Shares logic with "Scroll to target" below, refactor out?
        local targetElem = self.beltElems[self.beltTargetIndex]
        if targetElem ~= nil then
            self.beltEntryId = targetElem.entryId
            self.targetElem = nil
            self.beltCursorX = targetElem.x
            self.beltCursorVX = 0
        else
            self.beltTargetIndex = nil
        end

        return
    end

    local skipApplyVel = false

    local dragScrolling = false
    if self.numTouches == 1 and self.maxNumTouches == 1 then -- Single touch
        local touchId, touch = next(self.touches)

        local inside
        if TOP_BELT then
            inside = touch.screenY < self.beltBottom
        else
            inside = touch.screenY > self.beltTop
        end
        if inside then -- Touch on belt
            touch.beltUsed = true -- Grab / scale-rotate steal even if `touch.used`
            touch.used = true

            local touchBeltX = touch.screenX - 0.5 * windowWidth + self.beltCursorX
            local touchBeltIndex = math.floor(touchBeltX / (ELEM_SIZE + ELEM_GAP) + 0.5) + 1

            -- Cancel existing target on press, track new target on tap
            if touch.pressed then
                self.beltTargetIndex = nil
            end
            if touch.released and not touch.movedNear and currTime - touch.pressTime < 0.2 then
                self.beltTargetIndex = touchBeltIndex
            end

            -- Track which element the touch begins on
            if touch.pressed then
                local placeElem = self.beltElems[touchBeltIndex]
                if placeElem then
                    touch.beltIndex = touchBeltIndex
                    placeElem.placeRelX = placeElem.x - touchBeltX
                    placeElem.placeRelY = self.beltTop + 0.5 * BELT_HEIGHT - touch.screenY
                end
            end

            -- Start placing if the touch began on an element and it's a long-ish vertical drag
            if touch.beltIndex and not touch.beltPlacing then
                local totalDX = touch.screenX - touch.initialScreenX
                local totalDY = touch.screenY - touch.initialScreenY
                local totalDLen2 = totalDX * totalDX + totalDY * totalDY
                local long = totalDLen2 > (0.25 * ELEM_SIZE) * (0.25 * ELEM_SIZE)
                local dir
                if TOP_BELT then
                    dir = totalDY > 0
                else
                    dir = totalDY < 0
                end
                local vertical = dir and math.abs(totalDY) > 1.2 * math.abs(totalDX)
                if long and vertical then
                    touch.beltPlacing = true
                end
            end

            -- This is a drag scroll if not placing
            if not touch.beltPlacing then
                self.beltCursorX = self.beltCursorX - touch.screenDX
                skipApplyVel = true
                dragScrolling = true

                -- Keep track of last 3 touch velocities and use max, to smooth things out
                if not touch.beltVelocities then
                    touch.beltVelocities = {}
                end
                table.insert(touch.beltVelocities, -touch.screenDX / dt)
                while #touch.beltVelocities > 3 do
                    table.remove(touch.beltVelocities, 1)
                end
                local maxVel = 0
                for _, vel in ipairs(touch.beltVelocities) do
                    if math.abs(vel) > math.abs(maxVel) then
                        maxVel = vel
                    end
                end
                self.beltCursorVX = maxVel
            end
        end

        -- Placing
        if touch.beltPlacing and touch.beltIndex then
            -- Slow down scroll real quick if we're placing
            self.beltCursorVX = 0.2 * self.beltCursorVX

            -- Update place position
            local placeElem = self.beltElems[touch.beltIndex]
            placeElem.placeX = touch.screenX + placeElem.placeRelX
            placeElem.placeY = touch.screenY + placeElem.placeRelY

            -- Touch dragged far enough into scene? Place actor!
            local inScene
            if TOP_BELT then
                inScene = touch.screenY > self.beltBottom + 0.1 * BELT_HEIGHT 
            else
                inScene = touch.screenY < self.beltTop - 0.1 * BELT_HEIGHT 
            end
            if inScene then
                touch.beltUsed = false
                touch.beltPlacing = nil
                touch.beltIndex = nil
                placeElem.placeX, placeElem.placeY = nil, nil
                placeElem.placeRelX, placeElem.placeRelY = nil, nil
                self:_addBlueprintToScene(placeElem.entryId, touch.x, touch.y)
                self.beltVisible = false
            end
        end
    else
        -- Clear placings
        for _, elem in ipairs(self.beltElems) do
            elem.placeX, elem.placeY = nil, nil
            elem.placeRelX, elem.placeRelY = nil, nil
        end
    end

    -- Scroll to target, also manage current entry id
    -- TODO(nikki): Shares logic with "Scroll to target immedately" above, refactor out?
    local targetMode = false
    local targetElem = self.beltElems[self.beltTargetIndex]
    if targetElem ~= nil then
        self.beltEntryId = targetElem.entryId
        if math.abs(targetElem.x - self.beltCursorX) <= 3 then
            -- Reached target
            self.targetElem = nil
            self.beltCursorX = targetElem.x
            self.beltCursorVX = 0
        else
            -- Rubber band toward target
            self.beltCursorX = 0.4 * targetElem.x + 0.6 * self.beltCursorX
        end
        targetMode = true
    else
        self.beltTargetIndex = nil -- Invalid target index

        -- Set entry id based on cursor position
        local cursorIndex = math.floor(self.beltCursorX / (ELEM_SIZE + ELEM_GAP) + 0.5) + 1
        if cursorIndex < 1 then
            cursorIndex = 1
        end
        if cursorIndex > #self.beltElems then
            cursorIndex = self.beltElems
        end
        local cursorElem = self.beltElems[cursorIndex]
        if cursorElem then
            self.beltEntryId = cursorElem.entryId
        end
    end

    if not targetMode then
        local rubberBandMode = false
        -- Strong rubber band on ends
        if not dragScrolling then
            if self.beltCursorX < 0 then
                self.beltCursorVX = 0.5 * self.beltCursorVX
                self.beltCursorX = 0.85 * self.beltCursorX
                rubberBandMode = true
            end
            local maxX = self.beltElems[#self.beltElems].x
            if self.beltCursorX > maxX then
                self.beltCursorVX = 0.5 * self.beltCursorVX
                self.beltCursorX = 0.85 * self.beltCursorX + 0.15 * maxX
                rubberBandMode = true
            end
        end

        -- Snap cursor to nearest elem
        local skipDecelerate = false
        if not rubberBandMode and not dragScrolling then
            if math.abs(self.beltCursorVX) <= SNAP_THRESHOLD_VX then
                local projX = self.beltCursorX

                -- Apply spring force toward nearest elem
                local i = math.floor(projX / (ELEM_SIZE + ELEM_GAP) + 0.5)
                local iX = i * (ELEM_SIZE + ELEM_GAP)
                if math.abs(self.beltCursorVX) > 0.7 * SNAP_THRESHOLD_VX then
                    -- Don't "pull back" if we really want to go forward
                    if iX < projX and self.beltCursorVX > 0 then
                        iX = math.max(projX, iX + 0.8 * (ELEM_SIZE + ELEM_GAP))
                    end
                    if iX > projX and self.beltCursorVX < 0 then
                        iX = math.min(projX, iX - 0.8 * (ELEM_SIZE + ELEM_GAP))
                    end
                end
                local accel = 0.7 * SNAP_THRESHOLD_VX * (iX - projX)
                local newVX = self.beltCursorVX + accel * dt
                self.beltCursorVX = 0.85 * newVX + 0.15 * self.beltCursorVX

                -- Explonential damping
                --self.beltCursorVX = 0.92 * self.beltCursorVX
            end
        end

        -- Velocity application
        if not skipApplyVel then
            self.beltCursorX = self.beltCursorX + self.beltCursorVX * dt
        end

        -- Deceleration -- stopping at proper zero if we get there
        if not skipDecelerate and self.beltCursorVX ~= 0 then
            if self.beltCursorVX > 0 then
                self.beltCursorVX = self.beltCursorVX - DECEL_X * dt
                if self.beltCursorVX < 0 then
                    self.beltCursorVX = 0
                end
            elseif self.beltCursorVX < 0 then
                self.beltCursorVX = self.beltCursorVX + DECEL_X * dt
                if self.beltCursorVX > 0 then
                    self.beltCursorVX = 0
                end
            end
        end

        -- Smoothing out various velocity artifacts
        if self.beltCursorVX ~= 0 then
            self.beltCursorVX = 0.8 * self.beltCursorVX + 0.2 * prevBeltCursorVX
        end
    end

    -- Vibrate when we go across elements
    if ENABLE_HAPTICS and currTime - self.beltLastVibrated > 0.03 then
        local offset
        if self.beltCursorX < prevBeltCursorX then
            offset = 0.5 + 0.32
        end
        if self.beltCursorX > prevBeltCursorX then
            offset = 0.5 - 0.32
        end
        if offset then
            local currIndex = math.floor(self.beltCursorX / (ELEM_SIZE + ELEM_GAP) + offset)
            currIndex = math.max(-1, math.min(currIndex, #self.beltElems))
            local prevIndex = math.floor(prevBeltCursorX / (ELEM_SIZE + ELEM_GAP) + offset)
            prevIndex = math.max(-1, math.min(prevIndex, #self.beltElems))
            if currIndex ~= prevIndex then
                if OS == 'iOS' then
                    love.system.vibrate(0.71) -- Tuned for our iOS vibration patch
                else
                    love.system.vibrate(0.04)
                end
                self.beltLastVibrated = currTime
            end
        end
    end
end

-- Draw

local titleFont = love.graphics.newFont(32)

function Common:drawBelt()
    local windowWidth, windowHeight = love.graphics.getDimensions()

    -- Highlighting
    if self.beltVisible then
        -- Set up and render to highlight canvas
        if not self.beltHighlightCanvas then
            self.beltHighlightCanvas = love.graphics.newCanvas()
        end
        if not self.beltHighlightCanvas2 then
            self.beltHighlightCanvas2 = love.graphics.newCanvas()
        end
        self.beltHighlightCanvas:renderTo(function()
            love.graphics.push("all")
            love.graphics.clear(0, 0, 0, 0)

            love.graphics.origin()
            love.graphics.applyTransform(self.viewTransform)

            local drawBehaviors = self.behaviorsByHandler["drawComponent"] or {}
            self:forEachActorByDrawOrder(function(actor)
                -- Render actor if it uses the currently highlighted blueprint
                if actor and actor.parentEntryId and actor.parentEntryId == self.beltEntryId then
                    local entry = self.library[actor.parentEntryId]
                    if not entry.isCore then
                        for behaviorId, behavior in pairs(drawBehaviors) do
                            local component = actor.components[behaviorId]
                            if component then
                                behavior:callHandler("drawComponent", component)
                            end
                        end
                    end
                end
            end)

            love.graphics.pop()
        end)

        -- Render highlight canvas to screen
        love.graphics.push("all") -- Transparent overlay (to make obscured actors visible)
        love.graphics.setColor(1, 1, 1, 0.7)
        love.graphics.draw(self.beltHighlightCanvas)
        love.graphics.pop()
        love.graphics.push("all") -- Darken other actors
        love.graphics.setBlendMode("multiply", "premultiplied")
        love.graphics.setShader(self.beltHighlightShader)
        love.graphics.draw(self.beltHighlightCanvas)
        love.graphics.pop()

        -- Glow
        self.beltHighlightCanvas2:renderTo(function()
            -- Gray outside edges
            love.graphics.push("all")
            love.graphics.setShader(self.beltOutlineShader)
            love.graphics.draw(self.beltHighlightCanvas)
            love.graphics.pop()
        end)
        self.beltHighlightCanvas:renderTo(function()
            -- Spread the gray further
            love.graphics.push("all")
            love.graphics.setShader(self.beltOutlineThickeningShader)
            love.graphics.draw(self.beltHighlightCanvas2)
            love.graphics.pop()
        end)
        self.beltHighlightCanvas2:renderTo(function()
            -- Blur horizontally
            love.graphics.push("all")
            self.beltOutlineBlurShader:send("direction", { 1 / love.graphics.getWidth(), 0 })
            love.graphics.setShader(self.beltOutlineBlurShader)
            love.graphics.draw(self.beltHighlightCanvas)
            love.graphics.pop()
        end)
        self.beltHighlightCanvas:renderTo(function()
            -- Blur vertically
            love.graphics.push("all")
            self.beltOutlineBlurShader:send("direction", { 0, 1 / love.graphics.getHeight() })
            love.graphics.setShader(self.beltOutlineBlurShader)
            love.graphics.draw(self.beltHighlightCanvas2)
            love.graphics.pop()
        end)
        love.graphics.push("all")
        love.graphics.setBlendMode("add") -- Glow
        love.graphics.draw(self.beltHighlightCanvas)
        love.graphics.pop()
    end

    -- Skip drawing UI when fully hidden
    if TOP_BELT then
        if self.beltBottom <= 0 then
            return
        end
    else
        if self.beltTop >= windowHeight then
            return
        end
    end

    love.graphics.push("all")

    -- Background
    love.graphics.setColor(0, 0, 0, 0.4)
    love.graphics.rectangle("fill",
        0, self.beltTop,
        windowWidth, BELT_HEIGHT)

    local elemsY = self.beltTop + 0.5 * BELT_HEIGHT

    -- Elements
    love.graphics.setColor(1, 1, 1)
    local function drawElem(elem)
        if elem.image then
            local imgW, imgH = elem.image:getDimensions()
            local scale = math.min(ELEM_SIZE / imgW, ELEM_SIZE / imgH)

            local x = 0.5 * windowWidth + elem.x - self.beltCursorX
            local y = elemsY

            if elem.placeX and elem.placeY then
                -- Use placing coordinates if we're placing
                x, y = elem.placeX, elem.placeY
            end

            love.graphics.draw(elem.image,
                x, y,
                0, scale, scale, 0.5 * imgW, 0.5 * imgH)
        end
    end
    local placeElem -- If we have a placing elem, draw it on top of others
    for i, elem in ipairs(self.beltElems) do
        if elem.placeX and elem.placeY then
            placeElem = elem
        else
            drawElem(elem)
        end
    end
    if placeElem then
        drawElem(placeElem)
    end

    -- Highlight box
    love.graphics.setColor(0, 1, 0)
    love.graphics.setLineWidth(3 * love.graphics.getDPIScale())
    local boxSize = 1.05 * ELEM_SIZE
    love.graphics.rectangle("line",
        0.5 * windowWidth - 0.5 * boxSize, elemsY - 0.5 * boxSize,
        boxSize, boxSize)

    -- Title for current element
    love.graphics.setColor(1, 1, 1)
    local currEntry = self.library[self.beltEntryId]
    if currEntry and currEntry.title then
        local w = titleFont:getWidth(currEntry.title)
        local h = titleFont:getHeight()
        love.graphics.print(currEntry.title, titleFont,
            0.5 * windowWidth - 0.5 * w,
            TOP_BELT and (self.beltBottom + 0.2 * h) or (self.beltTop - 1.2 * h))
    end

    -- Touch overlay
    love.graphics.setColor(1, 0, 1, 0.5)
    for _, touch in pairs(self.touches) do
        love.graphics.circle('fill', touch.screenX, touch.screenY, ELEM_SIZE * 0.2)
    end

    love.graphics.pop()
end
