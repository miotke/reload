# dmgbuild settings for the Reload disk image (docs/app/releases.md). scripts/release.sh
# passes the app path as -D app=... and runs dmgbuild from a throwaway virtualenv.
#
# Icon positions must match App/Design/render-dmg-background.swift.

app = defines["app"]  # noqa: F821, dmgbuild injects `defines`

format = "UDZO"
filesystem = "APFS"
files = [app]
symlinks = {"Applications": "/Applications"}
hide_extension = ["Reload.app"]

background = defines["background"]  # noqa: F821
window_rect = ((200, 200), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
arrange_by = None
icon_locations = {
    "Reload.app": (170, 190),
    "Applications": (490, 190),
}
