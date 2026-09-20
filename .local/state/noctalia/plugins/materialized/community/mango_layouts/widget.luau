local layouts = {
	T  = { name = "tile",             glyph = "layout-sidebar" },
	S  = { name = "scroller",         glyph = "carousel-horizontal" },
	M  = { name = "monocle",          glyph = "square" },
	G  = { name = "grid",             glyph = "layout-grid" },
	F  = { name = "fair",             glyph = "layout-board-split" },
	D  = { name = "deck",             glyph = "layers-difference" },
	DW = { name = "dwindle",          glyph = "layout-2" },
	CT = { name = "center_tile",      glyph = "layout-distribute-vertical" },
	VT = { name = "vertical_tile",    glyph = "layout-rows" },
	RT = { name = "right_tile",       glyph = "layout-sidebar-right" },
	VS = { name = "vertical_scroller",glyph = "carousel-vertical" },
	VG = { name = "vertical_grid",    glyph = "grid-dots" },
	VD = { name = "vertical_deck",    glyph = "chart-funnel" },
	VF = { name = "vertical_fair",    glyph = "layout-board" },
}

local show_glyph_raw = noctalia.getConfig("show_glyph")
local show_glyph = (show_glyph_raw == true) or (show_glyph_raw == "true") or (show_glyph_raw == nil)

local show_text_raw = noctalia.getConfig("show_text")
local show_text = (show_text_raw == true) or (show_text_raw == "true")

local custom_color = noctalia.getConfig("custom_color")

function update()
  noctalia.setUpdateInterval(1000)
  noctalia.runAsync(
    "mmsg get all-monitors | jq -r '.monitors[] | select(.active == true) | .layout_symbol'",
    function(result)
      if result and result.exitCode == 0 then
        local sym = result.stdout:gsub("%s+", "")
        local current = layouts[sym]
        
        if current then
            if show_glyph then 
                barWidget.setGlyph(current.glyph)
            end
            
            if show_text then 
                barWidget.setText(noctalia.tr("name_" .. current.name)) 
            else 
                barWidget.setText("") 
            end
            
            if custom_color and custom_color ~= "" then 
                barWidget.setColor(custom_color)
                barWidget.setGlyphColor(custom_color)
            end
        else
            if show_glyph then 
                barWidget.setGlyph("layout") 
            end
            
            if show_text then 
                barWidget.setText("Layout") 
            else 
                barWidget.setText("") 
            end
        end
      end
    end
  )
end

function onClick()
  noctalia.togglePanel("ezequiel/mango_layouts:panel")
end
