# Running the model across several machines

This is how Quoder's model is served at home: **Qwen2.5 Coder 32B (Q4_K_M, about 20 GB)** split across a Windows PC with an NVIDIA and an AMD GPU and a Mac mini's Apple GPU, using [llama.cpp](https://github.com/ggml-org/llama.cpp) (build b12061 or later).

## The layout that won

| Layout | Reading (tok/s) | Writing (tok/s) |
|---|---|---|
| CUDA on the NVIDIA card, every other GPU through local RPC | 14.8 | 1.75 |
| All PC GPUs in one Vulkan process | 16.2 | 1.65 |
| Vulkan PC GPUs + the Mac over RPC | 21.6 | 2.37 |
| **Vulkan NVIDIA + AMD discrete, Mac over RPC, no integrated GPU** | **43.4** | **3.4** |

Lessons:

- **Run every GPU in one computer in a single Vulkan process.** llama.cpp's RPC bridge adds overhead to every step even on the same machine. The Vulkan build drives NVIDIA and AMD cards together.
- **Leave out integrated GPUs.** They borrow system RAM; even a small share slowed everything by about 30%.
- **No flash attention or quantized KV cache on older AMD cards** (RX 580 / Polaris). With `-fa on -ctk q8_0 -ctv q8_0` the model produced garbage (`??????`). Test that answers are *correct*, not just fast.
- **`--cache-ram 0` when a GPU is on another machine.** Otherwise llama-server copies the previous conversation's cache back over the network before every new one (minutes over Wi-Fi).
- **Wired Ethernet** for the machine across the network: every generated token makes a round trip to it.
- Qwen2.5 Coder often writes tool calls as bare JSON instead of `<tool_call>` tags. Quoder recognizes both.

## On the Mac lending its GPU

```bash
mkdir -p ~/Quoder && cd ~/Quoder
curl -LO https://github.com/ggml-org/llama.cpp/releases/download/b12061/llama-b12061-bin-macos-arm64.tar.gz
tar xzf llama-b12061-bin-macos-arm64.tar.gz
```

Run `ggml-rpc-server -H 0.0.0.0 -p 50052 -c` at login with a launch agent (`~/Library/LaunchAgents/…plist`, `RunAtLoad` and `KeepAlive` true). **The RPC server has no authentication**: only run it on a home network the internet can't reach, never forward its port.

## On the PC running the server

Unpack the Vulkan build (`llama-…-bin-win-vulkan-x64.zip`) and run, at boot (for example a Task Scheduler task as SYSTEM that restarts it if it exits):

```powershell
llama-server.exe -m qwen2.5-coder-32b.gguf --host 127.0.0.1 --port 8080 `
  --api-key-file api-key.txt `
  --rpc MAC_IP:50052 -dev Vulkan2,Vulkan1,RPC0 `
  --fit on -c 6144 -fa off --cache-ram 0 --jinja --threads 8
```

`llama-server.exe --list-devices` (add `--rpc MAC_IP:50052`) shows the device names to use with `-dev`. Check that the Mac answers first (`Test-NetConnection MAC_IP -Port 50052`) and leave it out when it doesn't, so the model still loads.

`--host 127.0.0.1` keeps the server off the network entirely; Quoder reaches it through its SSH tunnel.
