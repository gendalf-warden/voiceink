# Third-party Licenses & Acknowledgements

VoiceInk bundles several third-party components. This document lists each component, its license, and any restrictions on redistribution.

> ⚠️ **CRITICAL — see Qwen2.5 entry below.** The bundled LLM model (`qwen2.5-3b.gguf`) is distributed under the **Qwen Research License**, which restricts commercial use. This affects how VoiceInk can be distributed.

---

## Bundled binaries

### whisper.cpp (whisper-server)
- **Source:** https://github.com/ggml-org/whisper.cpp
- **License:** MIT
- **Usage:** Speech-to-text inference server (port 8178)
- **Distribution:** ✅ Free for any purpose, including commercial. Attribution required.

### llama.cpp (llama-server)
- **Source:** https://github.com/ggml-org/llama.cpp
- **License:** MIT
- **Usage:** LLM inference server (port 8179)
- **Distribution:** ✅ Free for any purpose, including commercial. Attribution required.

### ggml
- **Source:** https://github.com/ggml-org/ggml
- **License:** MIT
- **Usage:** Tensor library, used by both whisper.cpp and llama.cpp
- **Distribution:** ✅ Free for any purpose. Includes `libggml*.dylib` and `.so` backend plugins.

---

## Bundled dynamic libraries

### OpenSSL 3
- **Source:** https://www.openssl.org
- **License:** Apache License 2.0
- **Usage:** TLS support for llama.cpp and whisper.cpp HTTP layers
- **Distribution:** ✅ Free for any purpose. Includes `libssl.3.dylib`, `libcrypto.3.dylib`.

### libomp (LLVM OpenMP runtime)
- **Source:** https://openmp.llvm.org
- **License:** Apache License 2.0 with LLVM Exceptions (or MIT, dual-licensed)
- **Usage:** Parallelism for ggml CPU backends
- **Distribution:** ✅ Free for any purpose.

---

## Bundled models

### Whisper large-v3-turbo (`ggml-large-v3-turbo-q5_0.bin` + CoreML encoder)
- **Source:** https://github.com/openai/whisper / Hugging Face: `openai/whisper-large-v3-turbo`
- **License:** **MIT**
- **Original copyright:** OpenAI
- **Usage:** Multilingual speech-to-text (547 MB GGML quantized + 1.2 GB CoreML encoder)
- **Distribution:** ✅ Free for any purpose, including commercial. Attribution to OpenAI required.

### Qwen2.5-3B-Instruct (`qwen2.5-3b.gguf`) — ⚠️ RESTRICTED
- **Source:** https://huggingface.co/Qwen/Qwen2.5-3B-Instruct
- **License:** **Qwen Research License** (a.k.a. `qwen-research`)
- **License URL:** https://huggingface.co/Qwen/Qwen2.5-3B-Instruct/blob/main/LICENSE
- **Original copyright:** Alibaba Cloud
- **Usage:** Punctuation post-processing (1.8 GB GGUF quantized)

**Restrictions:**
- ❌ **Commercial use requires a separate license from Alibaba Cloud.**
- ✅ Research, evaluation, personal non-commercial use is permitted.
- ✅ Redistribution is permitted with attribution and license inclusion (this NOTICE file).
- ✅ Modifications allowed under same terms.

**Implications for VoiceInk distribution:**
- Public free distribution of VoiceInk **as personal/research software** is allowed.
- Selling VoiceInk or bundling it with a commercial product **requires** either:
  - Replacing Qwen2.5-3B with a permissively-licensed alternative (see options below), OR
  - Obtaining a commercial license from Alibaba Cloud.

**Permissive alternatives** (if commercial distribution is needed):
- **Qwen2.5-1.5B-Instruct** — Apache 2.0 (smaller, may be sufficient for punctuation)
- **Qwen2.5-7B-Instruct** — Apache 2.0 (larger, slower)
- **Phi-3-mini-4k-instruct** (Microsoft) — MIT, ~3.8B params
- **Llama 3.2 3B** (Meta) — Llama license (own restrictions)
- **Gemma 2 2B** (Google) — Gemma terms (own restrictions)

---

## Source code (this app)

The VoiceInk Swift source code in this repository is currently **not yet licensed**. The author should choose a license before public distribution. Suggestions:
- **MIT** or **Apache 2.0** — permissive, compatible with all bundled MIT/Apache components
- **GPL 3.0** — copyleft, compatible if all bundled components allow

---

## Compliance checklist for distribution

When distributing VoiceInk binaries (DMG, app):

- [ ] Include this `NOTICE.md` file inside the .app bundle (e.g. `Contents/Resources/NOTICE.md`)
- [ ] OR display attribution in app's "About" / Help menu
- [ ] If distributing **commercially or for profit**: replace Qwen2.5-3B with permissive alternative OR obtain Alibaba license
- [ ] Make full Qwen Research License text available alongside redistributed model
- [ ] Make full MIT/Apache license texts available for whisper.cpp, llama.cpp, OpenSSL, libomp

---

## Update history

- 2026-04-30: Initial audit. Identified Qwen Research License restriction.
