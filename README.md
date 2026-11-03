# Quoder

**A native macOS app that lets a model running on your own computers use your Mac**: the terminal, your files, and the screen (reading it, clicking, typing). No cloud, no account.

Quoder talks to any OpenAI-compatible server such as [llama.cpp](https://github.com/ggml-org/llama.cpp)'s `llama-server`. It was built for **Qwen2.5 Coder 32B** split across several GPUs on different machines with llama.cpp's RPC backend, and works with smaller models on a single machine too.

## What it can do

| Tool | What it does |
|---|---|
| `run_command` | Runs any zsh command and returns its output |
| `read_file`, `write_file`, `edit_file`, `list_directory` | Works with your files |
| `screen_text` | Reads every piece of text on screen with its position (Apple Vision OCR), for models that can't see images |
| `ui_elements` | Lists the frontmost app's buttons, fields and menus with positions (Accessibility) |
| `click`, `type_text`, `press_keys`, `scroll`, `open` | Uses the Mac like a person would |

## Safety

You give Quoder full use of your Mac, so it has three layers of protection:

- **Self-check.** Before any action that changes something (a command that isn't read-only, a file write, a click, typing), the model gets a second look at exactly what it's about to do and either confirms it or corrects it. Read-only actions run straight away. You can turn this off in Settings.
- **A hard stop for disasters.** A short list of commands that could wipe the Mac (erasing disks, `rm -rf /` or `~`, `mkfs`, `dd` to a disk, disabling SIP) always asks you first, whatever the model decided.
- **A Stop button**, and every action is shown as a card you can open to see exactly what ran and what came back.

Text the model reads (web pages, files) can try to steer it. Keep the self-check on, and be careful what you point it at.

## Connecting to the model

By default Quoder opens an **SSH tunnel** to the computer running the model and keeps it open, so the model server only ever listens on `127.0.0.1` and nothing on your network can use it without your SSH key. Set the SSH address (`user@host`) and the server's API key in **Settings**. You can instead give a direct URL, for example a Cloudflare Tunnel behind Cloudflare Access.

See **[docs/SERVER.md](docs/SERVER.md)** for running Qwen2.5 Coder 32B across a Windows PC's GPUs and a Mac's GPU, including the settings that matter and what didn't work.

## Install

Requires macOS 15 or later on Apple Silicon and Xcode (or the Swift toolchain).

```bash
git clone https://github.com/A-Hackers-Guide/Quoder.git
cd Quoder
packaging/build-app.sh
```

That builds and signs `~/Applications/Quoder.app`. On first launch, use the two buttons on the start screen to allow **Accessibility** (click and type) and **Screen Recording** (read the screen).

## Headless use

```bash
~/Applications/Quoder.app/Contents/MacOS/Quoder --run "How many files are in my Downloads folder?"
```

runs one task without a window and prints every step, which is handy for testing a server setup.

## License

[MIT](LICENSE)
