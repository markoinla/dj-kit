# dmgbuild settings for DJ-Kit.dmg — used by scripts/release.sh:
#   dmgbuild -s settings.py -D app="/path/DJ Kit.app" "DJ Kit" out.dmg
# Writes the Finder layout (.DS_Store) directly, so it needs no Finder/GUI.
import os.path

app = defines["app"]  # noqa: F821 (dmgbuild injects `defines` from -D)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app_name]
icon = os.path.join(app, "Contents/Resources/AppIcon.icns")  # volume icon

window_rect = ((200, 140), (560, 340))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
arrange_by = None
icon_size = 112
text_size = 13
icon_locations = {app_name: (140, 150), "Applications": (420, 150)}
