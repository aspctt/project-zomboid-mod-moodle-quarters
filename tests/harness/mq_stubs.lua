--// Moodle Quarters stubs
--// Extends pz_stubs.lua with the slice of the game this mod replaces: the panel base
--// class it derives from, the parts of UIManager that own the moodle panels, and the
--// moodle strings the hover label reads. Everything else comes from the shared stubs.

--// Moodles
-- The shared stub answers getMoodleLevel only. Plate colour and hover label need the
-- rest of the surface MoodlesUI.render() reads.
Harness.GoodBadNeutral = {}
Harness.DefaultGoodBadNeutral = 2

function Harness.SetGoodBadNeutral(Type, Value)
	if Type == nil then error("SetGoodBadNeutral called with a nil MoodleType") end
	Harness.GoodBadNeutral[Type] = Value
end

local function ExtendMoodles(Moodles)
	function Moodles:getGoodBadNeutral(Type)
		if Type == nil then
			error("getGoodBadNeutral was given a nil MoodleType. The constant does not exist in this build.")
		end
		return Harness.GoodBadNeutral[Type] or Harness.DefaultGoodBadNeutral
	end

	function Moodles:getMoodleDisplayString(Type) return "Name:" .. tostring(Type) end
	function Moodles:getMoodleDescriptionString(Type) return "Desc:" .. tostring(Type) end

	return Moodles
end

ExtendMoodles(Harness.Player:getMoodles())

--// Textures
-- A path the install does not have comes back nil rather than raising, which is what
-- makes the mod hand the stack back to vanilla instead of drawing a column of holes.
Harness.MissingTextures = {}

local InstalledTexture = getTexture

function getTexture(Path)
	for _, Fragment in ipairs(Harness.MissingTextures) do
		if string.find(Path, Fragment, 1, true) then return nil end
	end
	return InstalledTexture(Path)
end

--// Core
-- getOptionMoodleSize is one based over the six texture sets, and its seventh value
-- means "follow the font size" instead.
Harness.MoodleSizeOption = 2
Harness.FontSizeOption = 1
Harness.GoodColour = { 0, 1, 0 }
Harness.BadColour = { 1, 0, 0 }

local function NewColour(Channels)
	local Colour = {}
	function Colour:getR() return Channels[1] end
	function Colour:getG() return Channels[2] end
	function Colour:getB() return Channels[3] end
	return Colour
end

local Core = getCore()

function Core:getOptionMoodleSize() return Harness.MoodleSizeOption end
function Core:getOptionFontSizeReal() return Harness.FontSizeOption end
function Core:getGoodHighlitedColor() return NewColour(Harness.GoodColour) end
function Core:getBadHighlitedColor() return NewColour(Harness.BadColour) end

--// UIManager
-- UI holds the elements in draw order, back to front, the same as the real list.
Harness.UI = {}
Harness.MoodlePanels = {}
Harness.FrameMs = 33.3
Harness.ActivePlayers = 1

function getNumActivePlayers() return Harness.ActivePlayers end

function UIManager.getMoodleUI(PlayerNum) return Harness.MoodlePanels[PlayerNum] end
function UIManager.getMillisSinceLastRender() return Harness.FrameMs end

function UIManager.AddUI(Element)
	table.insert(Harness.UI, Element)
end

function UIManager.RemoveElement(Element)
	for Index, Existing in ipairs(Harness.UI) do
		if Existing == Element then
			table.remove(Harness.UI, Index)
			return
		end
	end
end

function Harness.UIIndex(Element)
	for Index, Existing in ipairs(Harness.UI) do
		if Existing == Element then return Index end
	end
	return nil
end

--- The vanilla MoodlesUI panel, as far as this mod is concerned: a position kept up to
--- date by UIManager.resize() and a visible flag that follows the HUD.
function Harness.NewMoodlePanel(PlayerNum, Y)
	local Panel = {}
	Panel.Class = "MoodlesUI"
	Panel.Y = Y or 120
	Panel.Visible = true

	function Panel:getY() return self.Y end
	function Panel:isVisible() return self.Visible end
	function Panel:setVisible(Value) self.Visible = Value end
	function Panel:backMost() Harness.MoveBackMost(self) end

	Harness.MoodlePanels[PlayerNum] = Panel
	UIManager.AddUI(Panel)
	return Panel
end

function Harness.MoveBackMost(Element)
	UIManager.RemoveElement(Element)
	table.insert(Harness.UI, 1, Element)
end

--// ISUIElement
-- Enough of the base class for a panel to be built, positioned and drawn. Draws land
-- in Harness.Draws in the order they were issued, which is what lets a spec prove the
-- plate goes down before the icon.
ISUIElement = {}
ISUIElement.__index = ISUIElement

local function Record(Kind, Texture, X, Y, W, H, A, R, G, B)
	table.insert(Harness.Draws, {
		Kind = Kind,
		Texture = Texture,
		X = X, Y = Y,
		Width = W, Height = H,
		Alpha = A,
		R = R, G = G, B = B
	})
end

function ISUIElement:new(X, Y, Width, Height)
	local Element = Harness.NewUIElement(X, Y, Width, Height)

	function Element:drawTexture(Texture, DrawX, DrawY, Alpha, R, G, B)
		Record("texture", Texture, DrawX, DrawY, Texture and Texture.Size, Texture and Texture.Size, Alpha, R, G, B)
	end

	function Element:drawRect(DrawX, DrawY, W, H, Alpha, R, G, B)
		Record("rect", nil, DrawX, DrawY, W, H, Alpha, R, G, B)
	end

	function Element:drawTextRight(Text, DrawX, DrawY, R, G, B, Alpha)
		table.insert(Harness.Draws, {
			Kind = "text", Text = Text, X = DrawX, Y = DrawY, Alpha = Alpha, R = R, G = G, B = B
		})
	end

	function Element:backMost() Harness.MoveBackMost(self) end
	function Element:addToUIManager() UIManager.AddUI(self) end
	function Element:removeFromUIManager() UIManager.RemoveElement(self) end

	return Element
end

function ISUIElement:derive(Name)
	local Derived = {}
	Derived.__index = Derived
	Derived.Name = Name
	Derived.new = self.new
	Derived.derive = self.derive
	return Derived
end

--// Text
-- The shared stub measures six pixels a character; the moodle label only needs a
-- believable width and a line height.
Harness.FontHeight = 12

--- One frame of UIManager.render(): every element on the list, in list order. A spec
--- that calls a panel's render directly cannot see a second panel still on the list, so
--- anything about how many stacks reach the screen has to go through this.
function Harness.RenderUI()
	Harness.ClearDraws()
	for _, Element in ipairs(Harness.UI) do
		if type(Element.render) == "function" then Element:render() end
	end
end

--- Every draw whose texture path contains Fragment, oldest first.
function Harness.FindDraws(Fragment)
	local Found = {}
	for _, Draw in ipairs(Harness.Draws) do
		if Draw.Texture and Draw.Texture.Path and string.find(Draw.Texture.Path, Fragment, 1, true) then
			table.insert(Found, Draw)
		end
	end
	return Found
end
