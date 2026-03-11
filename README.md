# Torch Dev

A native macOS app for connecting to NYU's Torch HPC cluster.

## Building

1. Open `TorchDev.xcodeproj` in Xcode
2. Select **Product → Build** (⌘B)
3. To create a release build: **Product → Archive**

## First Run

On first launch, macOS will ask for permission to control Terminal. Click **OK** to allow the app to open Terminal and run the connection script.

## Distribution

### For Personal Use
After building, find `TorchDev.app` in Xcode's Products folder (right-click → Show in Finder) and copy it to `/Applications`.

### For Others (No Apple Developer Account)
1. Build the app
2. Zip it: `zip -r TorchDev.zip TorchDev.app`
3. Share the zip file

Users will need to:
- Right-click → Open (first time only, to bypass Gatekeeper)
- Or: System Settings → Privacy & Security → "Open Anyway"

### For Others (With Apple Developer Account)
1. In Xcode, go to **Product → Archive**
2. Click **Distribute App**
3. Choose **Developer ID** for direct distribution
4. This will notarize the app so users don't see Gatekeeper warnings

## Prerequisites for Users

The app assumes users have:

1. **SSH config** – An entry for `Host torch` in `~/.ssh/config`
2. **SSH key** – `~/.ssh/id_ed25519` registered with the cluster  
3. **VS Code or Positron** – With CLI tools installed (`code` or `positron` command)

## Project Structure

```
TorchDev/
├── TorchDev.xcodeproj/
├── TorchDev/
│   ├── TorchDevApp.swift      # App entry point
│   ├── ContentView.swift       # Main UI with settings form
│   ├── TorchDev.entitlements   # Permissions for Terminal control
│   ├── Resources/
│   │   └── torch-dev.sh        # The connection script
│   └── Assets.xcassets/        # App icon and colors
└── README.md
```

## Customization

- Edit `ContentView.swift` to change default values or add fields
- Edit `torch-dev.sh` to modify the connection behavior
- The script checks for `TORCH_SKIP_PROMPTS=1` to know settings came from the GUI
