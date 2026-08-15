# omarchy-monitors

> Draggable 2D layout editor for Hyprland monitor positions on Omarchy Linux.

`omarchy-monitors` is an overlay plugin for the Omarchy status bar / shell (`omarchy-shell` / Quickshell). It provides an intuitive, visual way to drag, snap, and arrange multiple displays in 2D space and save the layout directly to Hyprland.

```
+----------------------------------------------------------------+
|  [󰍹] Monitor Layout                             [2 DISPLAYS]   |
|  ------------------------------------------------------------  |
|  LAYOUT                                               in sync  |
|  +----------------------------------------------------------+  |
|  |     +------------------+        +------------------+     |  |
|  |     | 󰍹 DP-1           |        | 󰍹 HDMI-A-1       |     |  |
|  |     | 1920x1080 · 60Hz |        | 1920x1080 · 60Hz |     |  |
|  |     | 0x0              |        | 1920x0           |     |  |
|  |     +------------------+        +------------------+     |  |
|  +----------------------------------------------------------+  |
|  ------------------------------------------------------------  |
|  Esc · close                                   [Reset] [Apply] |
+----------------------------------------------------------------+
```

---

## Features

- **2D Visual Arrangement**: Drag display cards freely across the canvas to set logical positions.
- **Edge & Alignment Snapping**: Snaps adjacent display edges together and aligns top/bottom borders.
- **Live Hyprland IPC Application**: Instantly applies new monitor positions via `hyprctl` without restarting applications.
- **Atomic Configuration Persistence**: Safely saves the layout into `~/.config/hypr/monitors.lua` using an isolated managed block.
- **HiDPI & Scale Aware**: Correctly handles fractional scaling and transformed (rotated) monitors.
- **Native Omarchy Look & Feel**: Follows Omarchy theme colors, typography, borders, and animations.

---

## Installation

### One-line Installation

```bash
bash <(curl -sSL https://raw.githubusercontent.com/bernoussama/omarchy-monitors/main/install.sh)
```

### Manual Installation

1. Clone this repository into your Omarchy user plugins directory:
   ```bash
   git clone https://github.com/bernoussama/omarchy-monitors.git ~/.config/omarchy/plugins/oussama.monitors
   chmod +x ~/.config/omarchy/plugins/oussama.monitors/apply-monitors
   ```

2. Register the plugin in `~/.config/omarchy/shell.json`:
   ```json
   {
     "plugins": [
       { "id": "oussama.monitors" }
     ]
   }
   ```

3. Reload the Omarchy shell:
   ```bash
   omarchy-shell shell rescanPlugins
   ```

---

## Usage

### Open Overlay

Toggle the editor overlay at any time:

```bash
omarchy-shell shell toggle oussama.monitors
```

### Recommended Keybinding

Add a convenient keybinding in `~/.config/hypr/bindings.lua`:

```lua
-- Open Monitor Layout Editor with Super + Shift + M
o.bind("Super+Shift", "M", function()
  hl.exec("omarchy-shell shell toggle oussama.monitors")
end)
```

### Controls

| Action | Control |
|---|---|
| Move Display | Click and drag any display card |
| Snap to Edge | Drag near another display's border |
| Reset Changes | Click **Reset** button |
| Apply & Save | Click **Apply** button |
| Close Overlay | Press `Esc` or click **Close** / Scrim |

---

## Architecture & How It Works

1. **Overlay (`Monitors.qml`)**:
   Runs inside `omarchy-shell` (Quickshell). Reads live state from `hyprctl monitors -j` and renders the interactive canvas.
2. **Apply Script (`apply-monitors`)**:
   Receives the JSON array of monitor coordinates, executes `hyprctl eval` for live updates, and atomically rewrites the `-- oussama.monitors BEGIN` block in `~/.config/hypr/monitors.lua`.

---

## Requirements

- [Omarchy Linux](https://omarchy.org/)
- [Hyprland](https://hyprland.org/)
- [Quickshell](https://quickshell.outfoxxed.me/)
- `jq` and `bash`

---

## License

[MIT](LICENSE) © [Oussama Bernou](https://github.com/bernoussama)
