-- ScreenHost  -  lazy singleton ScreenGui for ImageLabel emitters without an EmitParent.

local GuiHost = require(script.Parent.GuiHost)

local ScreenHost = {}
local _gui = nil

function ScreenHost.get()
	if _gui and _gui.Parent then return _gui end
	local host = GuiHost.resolveContainer()
	if not host then return nil end  -- server context: caller skips
	_gui = Instance.new("ScreenGui")
	_gui.Name = "PartIclesScreenHost"
	_gui.Archivable = false
	_gui.DisplayOrder = -10 -- below plugin UI (default 0)
	_gui.ResetOnSpawn = false
	_gui.IgnoreGuiInset = true
	_gui.Parent = host
	return _gui
end

function ScreenHost.destroy()
	if _gui then pcall(_gui.Destroy, _gui); _gui = nil end
end

function ScreenHost.exists() return _gui and _gui.Parent ~= nil end

return ScreenHost
