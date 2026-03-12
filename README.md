# Torch Dev

A macOS app for connecting to the [NYU Torch HPC cluster](https://sites.google.com/nyu.edu/nyu-hpc/hpc-systems/torch). It handles authentication, job submission, tunnel setup, and IDE launch — all from a single window.

<img src="https://github.com/eric-d-knowles/TorchDev/blob/main/TorchDev/Assets.xcassets/AppIcon.appiconset/blowtorch_icon.png?raw=true" width="128" alt="Torch Dev icon">

---

## Features

- **One-click connection** — submits a Slurm job, waits for allocation, sets up an SSH tunnel, and launches VS Code or Positron automatically
- **Microsoft device auth** — detects when authentication is required and displays your PIN with a one-click browser button
- **Queue status** — check your position and job details while waiting for a node
- **SSH configuration** — built-in setup wizard for your `~/.ssh/config` torch host entry
- **SSH troubleshooter** — diagnoses and auto-fixes common issues (missing keys, stale known_hosts, agent problems)
- **Remote server setup** — creates `/scratch` symlinks for VS Code and Positron server installs to avoid home directory quota issues

---

## Requirements

- macOS 13 or later
- SSH access to the NYU Torch cluster (`torch.hpc.nyu.edu`)
- NYU NetID and HPC account
- [VS Code](https://code.visualstudio.com) or [Positron](https://github.com/posit-dev/positron) with the Remote SSH extension installed locally

---

## Installation

Download the latest release from the [Releases](../../releases) page, unzip, and move `TorchDev.app` to your Applications folder.

> **Note:** Because this app is not yet notarized, macOS may show a security warning on first launch. To open it, right-click the app and choose **Open**, then click **Open Anyway**. You only need to do this once.

---

## First-Time Setup

1. Launch the app — it will prompt you to configure SSH if not already set up
2. Enter your NYU NetID in the SSH Configuration sheet
3. The app writes the required `Host torch` block to your `~/.ssh/config`
4. Make sure your SSH key is authorized on the cluster (use the **Troubleshoot SSH** option if needed)

---

## Usage

| Setting | Description |
|---|---|
| **Account** | Your Slurm account (e.g. `torch_pr_217_general`) |
| **Hours** | Requested job duration (1–24) |
| **CPUs** | Number of CPU cores (1–100) |
| **RAM (GB)** | Memory in gigabytes (4–500, in steps of 4) |
| **GPU** | Request a GPU node |
| **Partition** | Slurm partition (leave blank for default) |
| **Project** | Root directory to open in the IDE |
| **IDE** | VS Code or Positron |

All settings are saved automatically between sessions.

Click **Connect** to start. The progress window shows each step in real time, with a live log output you can expand for details:

1. Authenticating with Microsoft
2. Submitting the Slurm job
3. Waiting for a compute node
4. Starting the SSH tunnel
5. Connecting to the node
6. Launching the IDE

If authentication is required, the app will display your device code PIN and open the browser for you. While waiting for a node to be allocated, a **Check Queue Status** button appears showing your job's position, priority, and estimated start time.

---

## Building from Source

```bash
git clone https://github.com/eric-d-knowles/TorchDev.git
cd TorchDev
open TorchDev.xcodeproj
```

Build and run with Xcode (⌘R). The bundled `torch-dev.sh` shell script must be included in the app target's **Copy Bundle Resources** build phase.

---

## Troubleshooting

Use the built-in **Troubleshoot SSH** tool (in the Setup section) to diagnose and auto-fix common connection issues. Each problem found has a **Fix** button that attempts an automatic repair, or opens Terminal for steps that require interaction.

---

## License

MIT
