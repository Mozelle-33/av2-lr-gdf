# Render the routed layout of a run to a PNG (OpenROAD GUI, offscreen).
# Environment: OUT (run directory), IMG (output png)
read_db $::env(OUT)/route.odb
gui::set_display_controls "*" visible false
gui::set_display_controls "Layers/*" visible true
gui::set_display_controls "Instances/*" visible true
gui::set_display_controls "Nets/*" visible true
gui::set_display_controls "Misc/Instances/Pin Names" visible false
save_image -resolution 1.0 $::env(IMG)
puts "IMG_DONE"
