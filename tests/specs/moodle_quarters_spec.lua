--// Moodle Quarters
--// The mod takes the vanilla moodle panel out of UIManager and draws the stack itself,
--// so these cover the swap, the order the stack is drawn in, and the level art and
--// tint each moodle ends up with.

local MQ = MoodleQuarters

--- Puts a vanilla panel in place and lets the mod take it over, the way OnTick does in
--- a running game.
local function Attach(y)
	local vanilla = Harness.NewMoodlePanel(0, y)
	Harness.Fire("OnTick")
	return MQ.panels[0], vanilla
end

--- Draws frames, clearing between them so only the last one is inspected. Slots slide
--- in from below, so anything about final position needs enough frames to settle.
local function Frames(panel, count)
	for _ = 1, count do
		Harness.ClearDraws()
		panel:render()
	end
end

--- The texture path of every texture draw of the last frame, in the order issued.
local function Paths()
	local paths = {}
	for _, draw in ipairs(Harness.Draws) do
		if draw.Texture ~= nil then table.insert(paths, draw.Texture.Path) end
	end
	return paths
end

local function FindDraw(fragment)
	for _, draw in ipairs(Harness.Draws) do
		if draw.Texture ~= nil and string.find(draw.Texture.Path, fragment, 1, true) then
			return draw
		end
	end
	return nil
end

----------------------------------------------------------------------------------

Test("every moodle in the stack names a type this build still has", function()
	for _, entry in ipairs(MQ.moodles) do
		AssertNotNil(MoodleType[entry.id], "MoodleType." .. entry.id .. " is not in this build")
	end
end)

Test("the panel takes the vanilla one's place in the ui list", function()
	local panel, vanilla = Attach()

	AssertNotNil(panel, "no panel was attached")
	AssertNil(Harness.UIIndex(vanilla), "the vanilla panel is still being drawn")
	AssertEquals(Harness.UIIndex(panel), 1, "the stack must sit behind every window")
end)

Test("a moodle draws its level plate and then its icon", function()
	local panel = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 3)
	Frames(panel, 60)

	local paths = Paths()
	AssertEquals(#paths, 2, "the outline is part of the plate, so a moodle is two draws")
	AssertContains(paths[1], "MoodleQuarters/48/bad_3.png")
	AssertContains(paths[2], "Moodles/48/Status_Hunger.png")
end)

Test("the plate is drawn untinted, so it keeps the colours it was drawn with", function()
	local panel = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 2)
	Frames(panel, 60)

	local plate = FindDraw("bad_2.png")
	AssertNotNil(plate, "the plate was not drawn")
	AssertNil(plate.R, "a colour here would multiply the art rather than show it")
	AssertEquals(plate.Alpha, 1)
end)

Test("a good moodle takes the good plate", function()
	local panel = Attach()
	Harness.SetGoodBadNeutral(MoodleType.FOOD_EATEN, MQ.good)
	Harness.SetMoodle(MoodleType.FOOD_EATEN, 4)
	Frames(panel, 60)

	AssertNotNil(FindDraw("MoodleQuarters/48/good_4.png"), "the good set was not used")
end)

Test("the stack is ordered by moodle type, not by which one appeared first", function()
	local panel = Attach()
	-- PANIC is declared after HUNGRY, so it takes the lower slot however it got there.
	Harness.SetMoodle(MoodleType.PANIC, 1)
	Frames(panel, 60)
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(panel, 60)

	local hunger = FindDraw("Status_Hunger.png")
	local panic = FindDraw("Mood_Panicked.png")
	AssertNotNil(hunger, "hunger was not drawn")
	AssertNotNil(panic, "panic was not drawn")
	AssertEquals(hunger.Y, 0, "hunger is declared first, so it holds the top slot")
	AssertEquals(panic.Y, 48 + MQ.gap, "panic sits one plate and one gap below")
end)

Test("a moodle that clears frees its slot for the one below", function()
	local panel = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Harness.SetMoodle(MoodleType.PANIC, 1)
	Frames(panel, 60)
	Harness.SetMoodle(MoodleType.HUNGRY, 0)
	Frames(panel, 60)

	AssertNil(FindDraw("Status_Hunger.png"), "a cleared moodle must not be drawn")
	AssertEquals(FindDraw("Mood_Panicked.png").Y, 0, "panic moves up into the free slot")
end)

Test("food eaten stays out of the stack until it is high", function()
	local panel = Attach()
	Harness.SetMoodle(MoodleType.FOOD_EATEN, MQ.foodEatenMinLevel - 1)
	Frames(panel, 60)
	AssertEquals(#Paths(), 0, "a low food eaten moodle takes no slot in vanilla either")

	Harness.SetMoodle(MoodleType.FOOD_EATEN, MQ.foodEatenMinLevel)
	Frames(panel, 60)
	AssertNotNil(FindDraw("Status_Hunger.png"), "a high food eaten moodle is drawn")
end)

Test("the plate size follows the moodle size option", function()
	local panel = Attach()
	Harness.MoodleSizeOption = 6
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(panel, 60)

	AssertNotNil(FindDraw("MoodleQuarters/128/bad_1.png"), "the largest option is the 128 set")
	AssertEquals(panel:getWidth(), 128)
end)

Test("the stack sits one plate and ten pixels in from the right edge", function()
	Harness.SetScreenSize(1920, 1080)
	local panel = Attach(140)
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(panel, 1)

	AssertEquals(panel:getX(), 1920 - (48 + MQ.gap), "same place UIManager.resize puts vanilla")
	AssertEquals(panel:getY(), 140, "the vertical position is read off the vanilla panel")
end)

Test("only the occupied column takes mouse events", function()
	local panel = Attach()
	Frames(panel, 1)
	AssertEquals(panel:getHeight(), 0, "an empty stack leaves the screen edge alone")

	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Harness.SetMoodle(MoodleType.PANIC, 1)
	Frames(panel, 1)
	AssertEquals(panel:getHeight(), (48 + MQ.gap) * 2, "two moodles, two slots")
end)

Test("hovering a moodle draws vanilla's name and description beside it", function()
	local panel = Attach(120)
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(panel, 60)

	Harness.SetMouse(1900, 130)
	panel:onMouseMove(0, 0)
	Frames(panel, 1)

	local labels = {}
	for _, draw in ipairs(Harness.Draws) do
		if draw.Kind == "text" then table.insert(labels, draw.Text) end
	end
	AssertEquals(#labels, 2, "vanilla draws a name and a description")
	AssertContains(labels[1], "Name:HUNGRY")
	AssertContains(labels[2], "Desc:HUNGRY")
end)

Test("moving off the stack drops the hover label", function()
	local panel = Attach(120)
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(panel, 60)

	Harness.SetMouse(1900, 130)
	panel:onMouseMove(0, 0)
	panel:onMouseMoveOutside(0, 0)
	Frames(panel, 1)

	for _, draw in ipairs(Harness.Draws) do
		AssertTrue(draw.Kind ~= "text", "no label once the cursor has left")
	end
end)

Test("nothing is drawn while the hud is hidden", function()
	local panel, vanilla = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(panel, 60)
	AssertTrue(#Paths() > 0, "the stack should be drawing to begin with")

	vanilla:setVisible(false)
	Frames(panel, 1)
	AssertEquals(#Paths(), 0, "the stack follows the vanilla panel's visible flag")
end)

Test("vanilla is left alone when the level art is missing", function()
	Harness.MissingTextures = { "MoodleQuarters" }
	local vanilla = Harness.NewMoodlePanel(0)
	Harness.Fire("OnTick")

	AssertNil(MQ.panels[0], "without the level art there is nothing to draw")
	AssertNotNil(Harness.UIIndex(vanilla), "so vanilla keeps the stack")
end)

Test("the stack is handed back when the art for a new size is missing", function()
	local panel, vanilla = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(panel, 1)

	Harness.MissingTextures = { "MoodleQuarters/128" }
	Harness.MoodleSizeOption = 6
	Frames(panel, 1)
	Harness.Fire("OnTick")

	AssertNil(MQ.panels[0], "the panel gave up its slot")
	AssertNotNil(Harness.UIIndex(vanilla), "and put vanilla back in the list")
end)

--- A new game: UIManager.init() empties the element list and builds a fresh moodle
--- panel, which is what the harness does here.
local function NewGame()
	Harness.UI = {}
	return Harness.NewMoodlePanel(0)
end

Test("a new game replaces the panel rather than stacking a second one", function()
	local first = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(first, 60)

	NewGame()
	Harness.Fire("OnTick")
	Harness.Fire("OnTick")

	local second = MQ.panels[0]
	AssertNotNil(second, "the new game got no panel")
	AssertTrue(second ~= first, "the panel from the previous game is still registered")
	AssertNil(Harness.UIIndex(first), "the previous panel is still on the element list")
end)

Test("each moodle reaches the screen once, however many panels have come and gone", function()
	local first = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(first, 60)

	-- Anything that drops a live panel without taking it off the element list leaves it
	-- drawing its own stack, with its own slide, beside the replacement.
	MQ.reset()
	Harness.Fire("OnTick")
	Harness.SetMoodle(MoodleType.HUNGRY, 3)
	for _ = 1, 60 do Harness.RenderUI() end

	local plates = Harness.FindDraws("MoodleQuarters/")
	local icons = Harness.FindDraws("Status_Hunger.png")
	AssertEquals(#plates, 1, "the moodle plate was drawn more than once in a frame")
	AssertEquals(#icons, 1, "the moodle icon was drawn more than once in a frame")
end)

Test("a stale panel draws nothing even while it waits to be taken off the list", function()
	local first = Attach()
	Harness.SetMoodle(MoodleType.HUNGRY, 1)
	Frames(first, 60)

	-- Dropped from the register but not yet from UIManager, which is the window the
	-- second stack used to appear in.
	MQ.panels[0] = nil
	Harness.ClearDraws()
	first:render()

	AssertEquals(#Paths(), 0, "an orphaned panel must not draw")
end)

Test("the vanilla panel is handed back on the way out to the main menu", function()
	local panel, vanilla = Attach()
	AssertNil(Harness.UIIndex(vanilla), "vanilla should have given up its slot")

	Harness.Fire("OnMainMenuEnter")

	AssertNil(MQ.panels[0], "the panel was not detached")
	AssertNil(Harness.UIIndex(panel), "the panel is still on the element list")
	AssertNotNil(Harness.UIIndex(vanilla), "vanilla never got the stack back")
end)
