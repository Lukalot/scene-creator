local DrawingBehavior = {
    name = 'Drawing',
    propertyNames = {
        'url',
        'wobble',
    },
    dependencies = {
        'Body',
    },
    handlers = {},
}

registerCoreBehavior(DrawingBehavior)


-- Default

local DEFAULT_URL = 'assets/rectangle.svg'
local DEFAULT_GRAPHICS
if not castle.system.isRemoteServer() then
    DEFAULT_GRAPHICS = tove.newGraphics(love.filesystem.newFileData(DEFAULT_URL):getString(), 1024)
end


-- Wobble

local AMOUNT = 4.2
local NOISE_SCALE = 0.08
local FRAMES = 3
local TWEEN = 1
local SPEED = 8
local POINTS = false

local startTime = love.timer.getTime()

local function wobblePoint(x, y, seed)
    seed = seed * 100
    local dx1 = AMOUNT * (2 * love.math.noise(NOISE_SCALE * x, NOISE_SCALE * y, 1, seed) - 1)
    local dy1 = AMOUNT * (2 * love.math.noise(NOISE_SCALE * x, NOISE_SCALE * y, 10, seed) - 1)
    local dx2 = AMOUNT * AMOUNT * (2 * love.math.noise(NOISE_SCALE * NOISE_SCALE * x, NOISE_SCALE * NOISE_SCALE * y, 100, seed) - 1)
    local dy2 = AMOUNT * AMOUNT * (2 * love.math.noise(NOISE_SCALE * NOISE_SCALE * x, NOISE_SCALE * NOISE_SCALE * y, 1000, seed) - 1)
    return x + dx1 + dx2, y + dy1 + dy2
end

local function wobbleDrawing(drawing)
    local frames = {}
    for f = 1, FRAMES do
        local clone = drawing:clone()
        clone:warp(function(x, y, c)
            local newX, newY = wobblePoint(x, y, f)
            return newX, newY, c
        end)
        table.insert(frames, clone)
    end
    local tween = tove.newTween(frames[1])
    for i = 2, #frames do
        tween = tween:to(frames[i], 1)
    end
    tween = tween:to(frames[1], 1)
    return tove.newFlipbook(TWEEN, tween)
end


-- Loading

local cache = setmetatable({}, { __mode = 'v' })

local function cacheDrawing(url, opts)
    opts = opts or {}
    local async = opts.async
    local wobble = opts.wobble

    local cacheEntry = cache[url]
    if not cacheEntry then
        cacheEntry = {}
        cache[url] = cacheEntry
    end
    local graphics = cacheEntry.graphics
    if not graphics then
        if not cacheEntry.graphicsRequested then
            cacheEntry.graphicsRequested = true
            network.async(function()
                local fileContents = love.filesystem.newFileData(url):getString()
                cacheEntry.graphics = tove.newGraphics(fileContents, 1024)
                cacheEntry.graphics:setDisplay('mesh', 'rigid', 4)
                cacheEntry.graphicsWidth, cacheEntry.graphicsHeight = nil, nil
                if wobble then
                    cacheEntry.flipbook = wobbleDrawing(cacheEntry.graphics)
                end
            end)
        end
    end
    return cacheEntry
end


-- Component management

function DrawingBehavior.handlers:addComponent(component, bp, opts)
    -- NOTE: All of this must be pure w.r.t the arguments since we're directly setting and not sending
    component.properties.url = bp.url or DEFAULT_URL
    if bp.wobble ~= nil then
        component.properties.wobble = bp.wobble
    else
        component.properties.wobble = false
    end
    cacheDrawing(component.properties.url, {
        wobble = component.properties.wobble,
    })
end

function DrawingBehavior.handlers:blueprintComponent(component, bp)
    bp.url = component.properties.url
    bp.wobble = component.properties.wobble
end


-- Draw

function DrawingBehavior.handlers:drawComponent(component)
    -- Body attributes
    local bodyWidth, bodyHeight = self.dependencies.Body:getSize(component.actorId)
    local bodyId, body = self.dependencies.Body:getBody(component.actorId)
    local bodyX, bodyY = body:getPosition()
    local bodyAngle = body:getAngle()

    -- Load graphics
    local cacheEntry = cacheDrawing(component.properties.url, {
        wobble = component.properties.wobble,
    })
    component._cacheEntry = cacheEntry -- Maintain strong reference
    local graphics = cacheEntry.graphics or component._lastGraphics or DEFAULT_GRAPHICS
    component._lastGraphics = graphics

    -- Graphics size
    local graphicsWidth, graphicsHeight = cacheEntry.graphicsWidth, cacheEntry.graphicsHeight
    if not (graphicsWidth and graphicsHeight) then
        local minX, minY, maxX, maxY = graphics:computeAABB('high')
        graphicsWidth, graphicsHeight = maxX - minX, maxY - minY
        cacheEntry.graphicsWidth, cacheEntry.graphicsHeight = graphicsWidth, graphicsHeight
    end

    -- Wobble
    local flipbook
    if component.properties.wobble and cacheEntry.graphics then
        flipbook = cacheEntry.flipbook
        if not flipbook then
            flipbook = wobbleDrawing(graphics)
            cacheEntry.flipbook = flipbook
        end
    end

    -- Push transform
    love.graphics.push()
    love.graphics.translate(bodyX, bodyY)
    love.graphics.rotate(bodyAngle)
    love.graphics.scale(bodyWidth / graphicsWidth, bodyHeight / graphicsHeight)

    -- Draw!
    if flipbook then
        if not component._flipbookPhase then
            component._flipbookPhase = math.random(0, flipbook._duration - 1)
            component._flipbookSign = math.random(2) == 1 and -1 or 1
        end
        flipbook.t = (component._flipbookSign * SPEED * love.timer.getTime() + component._flipbookPhase) % flipbook._duration
        flipbook:draw()
    else
        graphics:draw()
    end

    -- Pop transform
    love.graphics.pop()
end


-- UI

function DrawingBehavior.handlers:uiComponent(component, opts)
    local actorId = component.actorId

    ui.box('preview and picker', { flexDirection = 'row', alignItems = 'flex-start' }, function()
        ui.box('preview', {
            width = '28%',
            aspectRatio = 1,
            margin = 4,
            marginLeft = 8,
            backgroundColor = 'white',
        }, function()
            ui.image(CHECKERBOARD_IMAGE_URL, { flex = 1, margin = 0 })

            if component.properties.url then
                ui.image(component.properties.url, {
                    position = 'absolute',
                    left = 0, top = 0, bottom = 0, right = 0,
                    margin = 0,
                })
            end
        end)

        ui.box('spacer', { width = 8 }, function() end)

        ui.box('library picker', {
            flex = 1,
            alignSelf = 'stretch',
            flexDirection = 'row',
            alignItems = 'flex-start',
            justifyContent = 'flex-start',
        }, function()
            ui.button('choose from library', {
                icon = 'book',
                iconFamily = 'FontAwesome',
                popoverAllowed = true,
                popoverStyle = { width = 300, height = 300 },
                popover = function(closePopover)
                    self.game:uiLibrary({
                        id = 'drawing',
                        filterType = 'drawing',
                        emptyText = 'No assets!',
                        buttons = function(entry)
                            ui.button('use', {
                                flex = 1,
                                icon = 'plus',
                                iconFamily = 'FontAwesome5',
                                onClick = function()
                                    closePopover()

                                    local oldUrl = component.properties.url
                                    local newUrl = entry.drawing.url
                                    self:command('change drawing', {
                                        params = { 'oldUrl', 'newUrl' },
                                    }, function()
                                        self:sendSetProperties(actorId, 'url', newUrl)
                                    end, function()
                                        self:sendSetProperties(actorId, 'url', oldUrl)
                                    end)
                                end,
                            })
                        end,
                    })
                end,
            })
        end)
    end)

    self:uiProperty('toggle', 'wobble', actorId, 'wobble')
end

