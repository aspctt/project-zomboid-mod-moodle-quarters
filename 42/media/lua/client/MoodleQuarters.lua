--- Moodle Quarters, build 42.
---
--- Build 41 shipped this mod as a texture pack: the moodle background existed as
--- eight textures, Moodle_Bkg_Good_1..4 and Moodle_Bkg_Bad_1..4, and replacing them
--- was enough to square off one more quarter of the plate per moodle level.
---
--- Build 42 draws the stack from zombie.ui.MoodleTextureSet, which loads exactly one
--- background and one border per size and tints it towards the player's highlight
--- colour by level instead. A texture pack can no longer say anything about a level, so
--- the plates ship as their own textures and this script draws the stack.
---
--- The plates are the build 41 art, scaled up and drawn untinted. Their shape, their
--- hard one pixel outline and their colours are the mod, so none of the three is handed
--- to the engine to recompute.
---
--- Vanilla keeps its slot state in a HashMap<MoodleType, MoodleUIData> and MoodleType
--- has no hashCode, so its slot order is whatever the identity hashes happen to be
--- that session. Drawing level art over the vanilla stack would land on the wrong
--- moodle, which is why the panel is replaced outright rather than decorated: the
--- vanilla panel is taken out of UIManager's element list and one of these panels
--- takes its place, in a fixed order.

require "ISUI/ISUIElement"

MoodleQuarters = MoodleQuarters or {}
local MQ = MoodleQuarters

--- The six sets in MoodlesUI.textureSizes.
MQ.sizes = { 32, 48, 64, 80, 96, 128 }

--- MoodlesUI.DefaultMoodleDistY: the gap between plates, added to the plate size.
MQ.gap = 10

--- Moodles.GoodBadNeutral() answers 1 for FOOD_EATEN and 2 for everything else, so good
--- and bad are the only two plate sets the game can ask for.
MQ.good = 1
MQ.bad = 2

MQ.maxLevel = 4

--- FOOD_EATEN only takes a slot from HighMoodleLevel up, as MoodlesUI.update() has it.
MQ.foodEatenMinLevel = 3

--- The slot slide and the level-change wobble, all from MoodlesUI, per 33.3ms frame.
MQ.tickMs = 33.3
MQ.slideRate = 0.15
MQ.slideSnap = 0.8
MQ.spawnOffset = 500
MQ.wobbleRate = 0.4
MQ.wobbleWidth = 15.6
MQ.wobbleDecay = 0.04
MQ.wobbleFloor = 0.01

--- Every MoodleType with the icon MoodleTextureSet loads for it, in the order
--- MoodleType declares them. The stack is drawn in this order, so unlike vanilla it
--- does not shuffle between sessions.
MQ.moodles = {
    { id = "ENDURANCE",     icon = "Status_DifficultyBreathing" },
    { id = "TIRED",         icon = "Mood_Sleepy" },
    { id = "HUNGRY",        icon = "Status_Hunger" },
    { id = "PANIC",         icon = "Mood_Panicked" },
    { id = "SICK",          icon = "Mood_Nauseous" },
    { id = "BORED",         icon = "Mood_Bored" },
    { id = "UNHAPPY",       icon = "Mood_Sad" },
    { id = "BLEEDING",      icon = "Status_Bleeding" },
    { id = "WET",           icon = "Status_Wet" },
    { id = "HAS_A_COLD",    icon = "Mood_Ill" },
    { id = "ANGRY",         icon = "Mood_Angry" },
    { id = "STRESS",        icon = "Mood_Stressed" },
    { id = "THIRST",        icon = "Status_Thirst" },
    { id = "INJURED",       icon = "Status_InjuredMinor" },
    { id = "PAIN",          icon = "Mood_Pained" },
    { id = "HEAVY_LOAD",    icon = "Status_HeavyLoad" },
    { id = "DRUNK",         icon = "Mood_Drunk" },
    { id = "DEAD",          icon = "Mood_Dead" },
    { id = "ZOMBIE",        icon = "Mood_Zombified" },
    { id = "HYPERTHERMIA",  icon = "Status_TemperatureHot" },
    { id = "HYPOTHERMIA",   icon = "Status_TemperatureLow" },
    { id = "WINDCHILL",     icon = "Status_Windchill" },
    { id = "CANT_SPRINT",   icon = "Status_MovementRestricted" },
    { id = "UNCOMFORTABLE", icon = "Mood_Discomfort" },
    { id = "NOXIOUS_SMELL", icon = "Mood_NoxiousSmell" },
    { id = "FOOD_EATEN",    icon = "Status_Hunger" },
}

----------------------------------------------------------------------------------
-- Textures
----------------------------------------------------------------------------------

local textureCache = {}

--- A missing texture is not an error in this engine, getTexture just returns nil, so
--- the miss is cached as false to keep the lookup off the hot path.
local function lookup(path)
    local texture = textureCache[path]
    if texture == nil then
        texture = getTexture(path) or false
        textureCache[path] = texture
    end
    if texture == false then return nil end
    return texture
end

--- The plate carries its own outline and its own colours, so it is drawn as it is.
function MQ.plate(size, goodBadNeutral, level)
    local kind = "bad"
    if goodBadNeutral == MQ.good then kind = "good" end
    return lookup(string.format("media/ui/MoodleQuarters/%d/%s_%d.png", size, kind, level))
end

--- The moodle symbols themselves stay vanilla, straight out of the game's own art.
function MQ.icon(size, name)
    return lookup(string.format("media/ui/Moodles/%d/%s.png", size, name))
end

--- MoodlesUI.getTextureSizeForOption(): the moodle size option indexes the six sets,
--- and its last entry means "follow the font size" instead.
function MQ.textureSize()
    local core = getCore()
    local option = core:getOptionMoodleSize() - 1
    if option >= 0 and option < #MQ.sizes then return MQ.sizes[option + 1] end
    if option == #MQ.sizes then
        local font = core:getOptionFontSizeReal() - 1
        if font >= 0 and font < #MQ.sizes then return MQ.sizes[font + 1] end
    end
    return MQ.sizes[1]
end

----------------------------------------------------------------------------------
-- The panel
----------------------------------------------------------------------------------

MoodleQuartersUI = ISUIElement:derive("MoodleQuartersUI")

function MoodleQuartersUI:new(playerNum, vanilla)
    local o = ISUIElement:new(0, 0, 0, 0)
    setmetatable(o, self)
    self.__index = self

    o.playerNum = playerNum
    o.vanilla = vanilla
    o.size = MQ.textureSize()
    o.usedSlots = 0
    o.wobbleStep = 0
    o.mouseOverSlot = nil
    -- This panel is positioned from the vanilla one, so it must not be nudged back
    -- on screen on the way there.
    o.keepOnScreen = false

    o.slots = {}
    for i = 1, #MQ.moodles do
        o.slots[i] = { level = 0, goodBadNeutral = 0, pos = 0, desired = 0, wobble = 0, shown = false }
    end

    return o
end

--- UIManager.resize() puts the stack a plate plus ten pixels in from the right edge,
--- against half the screen for the left column of a split screen. Only the vertical
--- position is read back off the vanilla panel, because that is the one part the
--- engine keeps up to date for a panel it is no longer drawing.
function MoodleQuartersUI:updateGeometry()
    local core = getCore()
    local size = MQ.textureSize()
    self.size = size

    local right = core:getScreenWidth()
    if (self.playerNum == 0 and getNumActivePlayers() > 1) or self.playerNum == 2 then
        right = math.floor(right / 2)
    end

    self:setX(right - (MQ.gap + size))
    self:setY(self.vanilla:getY())
    self:setWidth(size)
end

--- MoodlesUI.update(), rewritten over a fixed order. Slots slide towards the place
--- their index earns them, a moodle that has just appeared slides in from below, and
--- a moodle whose level changed wobbles sideways until the wobble decays away.
function MoodleQuartersUI:updateSlots(moodles, tick)
    local step = self.size + MQ.gap
    local slot = 0

    for i = 1, #MQ.moodles do
        local entry = MQ.moodles[i]
        local state = self.slots[i]
        local moodleType = MoodleType[entry.id]
        local level = 0
        if moodleType ~= nil then level = moodles:getMoodleLevel(moodleType) end
        if entry.id == "FOOD_EATEN" and level < MQ.foodEatenMinLevel then level = 0 end

        if level > 0 then
            if level > MQ.maxLevel then level = MQ.maxLevel end
            if state.level ~= level then
                state.level = level
                state.wobble = 1
            end
            state.goodBadNeutral = moodles:getGoodBadNeutral(moodleType)
            state.desired = step * slot
            if not state.shown then
                state.shown = true
                state.pos = state.desired + MQ.spawnOffset
                state.wobble = 0
            end
            slot = slot + 1
        else
            state.shown = false
            state.level = 0
            state.wobble = 0
        end
    end

    self.usedSlots = slot

    local slide = math.min(MQ.slideRate * tick, 1)
    local decay = math.min(MQ.wobbleDecay * tick, 1)
    for i = 1, #self.slots do
        local state = self.slots[i]
        if math.abs(state.pos - state.desired) > MQ.slideSnap then
            state.pos = state.pos + (state.desired - state.pos) * slide
        else
            state.pos = state.desired
        end
        state.wobble = state.wobble - state.wobble * decay
        if state.wobble < MQ.wobbleFloor then state.wobble = 0 end
    end

    -- Only the occupied column takes mouse events, so an empty stack leaves the
    -- right hand side of the screen alone.
    self:setHeight(slot * step)
end

--- The hover label vanilla draws to the left of the plate, same strings, same place.
function MoodleQuartersUI:renderTooltip(moodles, moodleType, slotY)
    local title = moodles:getMoodleDisplayString(moodleType)
    local description = moodles:getMoodleDescriptionString(moodleType)
    if title == nil and description == nil then return end

    local text = getTextManager()
    local width = math.max(text:MeasureStringX(UIFont.Small, title or ""),
                           text:MeasureStringX(UIFont.Small, description or ""))
    local lineHeight = text:getFontHeight(UIFont.Small)
    local boxHeight = (2 + lineHeight) * 2

    local y = slotY + 1
    if self.size > boxHeight then y = y + math.floor((self.size - boxHeight) / 2) end

    self:drawRect(-10 - width - 6, y - 2, width + 12, boxHeight, 0.6, 0, 0, 0)
    self:drawTextRight(title, -10, y, 1, 1, 1, 1)
    self:drawTextRight(description, -10, y + lineHeight, 0.8, 0.8, 0.8, 1)
end

function MoodleQuartersUI:render()
    -- A panel that is no longer the registered one for its player has been replaced and
    -- is waiting to be taken off UIManager's list. It must not draw in the meantime, or
    -- there are two stacks on screen animating independently of each other.
    if MQ.panels[self.playerNum] ~= self then return end

    -- UIManager.resize() clears the vanilla panel's visible flag while the HUD is
    -- hidden and for split screen slots nobody is playing, so follow it.
    if self.vanilla == nil or not self.vanilla:isVisible() then return end

    local player = getSpecificPlayer(self.playerNum)
    if player == nil then return end
    local moodles = player:getMoodles()
    if moodles == nil then return end

    self:updateGeometry()

    -- Without the level art there is nothing this panel can do that vanilla does not
    -- do better, so hand the stack back rather than draw a column of holes.
    if MQ.plate(self.size, MQ.bad, 1) == nil or MQ.plate(self.size, MQ.good, 1) == nil then
        MQ.requestDetach(self.playerNum)
        return
    end

    local tick = UIManager.getMillisSinceLastRender() / MQ.tickMs
    self:updateSlots(moodles, tick)

    self.wobbleStep = (self.wobbleStep + MQ.wobbleRate * tick) % (math.pi * 2)
    local wobble = math.sin(self.wobbleStep) * MQ.wobbleWidth

    local slot = 0
    for i = 1, #MQ.moodles do
        local state = self.slots[i]
        if state.shown then
            local x = math.floor(wobble * state.wobble)
            local y = math.floor(state.pos)

            local plate = MQ.plate(self.size, state.goodBadNeutral, state.level)
            local icon = MQ.icon(self.size, MQ.moodles[i].icon)
            if plate ~= nil then self:drawTexture(plate, x, y, 1) end
            if icon ~= nil then self:drawTexture(icon, x, y, 1) end

            if self.mouseOverSlot == slot then
                self:renderTooltip(moodles, MoodleType[MQ.moodles[i].id], y)
            end
            slot = slot + 1
        end
    end
end

function MoodleQuartersUI:onMouseMove(dx, dy)
    local slot = math.floor((getMouseY() - self:getY()) / (self.size + MQ.gap))
    if slot < 0 or slot >= self.usedSlots then slot = nil end
    self.mouseOverSlot = slot
end

function MoodleQuartersUI:onMouseMoveOutside(dx, dy)
    self.mouseOverSlot = nil
end

----------------------------------------------------------------------------------
-- Swapping the panels
----------------------------------------------------------------------------------

MQ.panels = {}

--- Take the vanilla panel out of UIManager's element list and add one of ours where
--- it sat. backMost keeps the stack underneath every window, which is where the
--- vanilla panel, added during UIManager.init(), draws from.
function MQ.attach(playerNum)
    if MQ.panels[playerNum] ~= nil then return end

    local vanilla = UIManager.getMoodleUI(playerNum)
    if vanilla == nil then return end
    if MQ.plate(MQ.textureSize(), MQ.bad, 1) == nil then return end

    local panel = MoodleQuartersUI:new(playerNum, vanilla)
    panel:initialise()
    panel:instantiate()
    panel:addToUIManager()
    panel:backMost()

    UIManager.RemoveElement(vanilla)
    MQ.panels[playerNum] = panel
end

function MQ.detach(playerNum)
    local panel = MQ.panels[playerNum]
    if panel == nil then return end

    MQ.panels[playerNum] = nil
    panel:removeFromUIManager()

    -- Only give the stack back to the panel it was taken from. A panel detached because
    -- a new game replaced it belongs to a character that no longer exists, and putting
    -- it back would draw the previous session's stack.
    if panel.vanilla ~= nil and UIManager.getMoodleUI(playerNum) == panel.vanilla then
        UIManager.AddUI(panel.vanilla)
        panel.vanilla:backMost()
    end
end

--- Detaching edits the list UIManager is walking, so it waits for the next tick.
function MQ.requestDetach(playerNum)
    local panel = MQ.panels[playerNum]
    if panel ~= nil then panel.detachRequested = true end
end

--- Staleness is decided by asking UIManager rather than by listening for a new game.
--- UIManager.init() empties its element list and builds fresh moodle panels every time
--- one starts, and a panel still holding the old one is last session's: it has to be
--- taken off the element list, not merely forgotten. Forgetting it left it drawing a
--- second stack next to the new one, with its own slide animation, which showed up as
--- two of each moodle sliding apart whenever the stack moved.
function MQ.update()
    for playerNum = 0, 3 do
        local panel = MQ.panels[playerNum]
        if panel ~= nil then
            if panel.detachRequested or UIManager.getMoodleUI(playerNum) ~= panel.vanilla then
                MQ.detach(playerNum)
            end
        elseif getSpecificPlayer(playerNum) ~= nil then
            MQ.attach(playerNum)
        end
    end
end

function MQ.reset()
    for playerNum = 0, 3 do MQ.detach(playerNum) end
end

Events.OnMainMenuEnter.Add(MQ.reset)
Events.OnCreatePlayer.Add(MQ.update)
Events.OnTick.Add(MQ.update)
