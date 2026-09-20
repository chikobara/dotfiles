--!nonstrict

local active = noctalia.state.get("is_active") ~= false

local function render()
  shortcut.setLabel(active and "Keyviz On" or "Keyviz Off")
  shortcut.setIcon(active and "keyboard" or "keyboard-off")
  shortcut.setActive(active)
end

noctalia.state.watch("is_active", function(value)
  active = value == true
  render()
end)

function onClick()
  active = not active
  noctalia.state.set("is_active", active)
  if active and type(noctalia.togglePanel) == "function" then
    noctalia.togglePanel("h-jangra/keyviz:overlay")
  end
  render()
end

function onRightClick()
  onClick()
end

render()
