# llama.cpp local provider

Provider ID `llama_cpp`, display llama.cpp. This is a named same-Mac provider, not a configurable OpenAI-compatible URL. Only literal loopback port8080 health/props/models/chat endpoints are compiled into the bridge. No model lifecycle controls are added.

Discovery inspects the unique loopback listener with fixed system lsof, resolves the process executable with proc_pidpath, and reads kernel argv/environment with KERN_PROCARGS2. Missing or ambiguous evidence stays unverified. Hostnames, wildcard listeners, unknown arguments, remote/RPC/download/SSH modes and LLAMA/DYLD environment overrides fail closed. A conservative allowlist supports the documented launch and basic numeric resource controls. Exactly one local GGUF is accepted; multimodal projectors are not loaded by this text-only provider.

Executable/model descriptors must resolve to regular files on MNT_LOCAL filesystems, with matching path/descriptor device and inode. Symlink target or file identity changes fail closed. Files changed after server startup require restarting the server and requalification so a running process cannot qualify replacement file bytes it did not load.

GGUF SHA256 is the model fingerprint. The protected qualification identity also stores executable path/hash, executable/model size and modification time, model path and PID. A process restart requires requalification. Private digest-cache keys cover canonical path, size, nanosecond modification/change timestamps, device and inode using sorted encoding. Atomic cache publication prevents interrupted writes from poisoning the final cache; warm calls avoid rehashing multi-GB models. This does not claim protection from a malicious same-user process rewriting the app and its receipts.

The version probe reuses the bounded suspended-process runner: pin executable code identity, verify loaded code before resuming, bound both output streams, handle cancellation/timeouts and clean up. llama discovery has a120-second ceiling for cold hashes; other providers retain existing budgets. Slow storage may still time out and is never treated as verified.

Health and metadata must identify one matching model; multimodal, proxy and sleeping modes fail closed. Worker slots are not model count. Generation rechecks identity and semantic metadata before/after, uses grounded prompts, zero temperature and strict schema JSON, and rejects tools, reasoning, images, multiple choices, extra fields, truncation and ungrounded output. No fallback provider.

Upstream shapes checked at https://github.com/ggml-org/llama.cpp/tree/a2878d30d/tools/server . Target-Mac acceptance remains: real model/server qualification, signed/notarized/stapled binaries, native/scanned PDF operations, stopped-server OCR and observed network evidence. Fixture tests do not establish that acceptance.
