# Browser client (in-memory replica of prod)

This is the same Flutter interface used by the mobile app, backed by an
in-memory `DemoController` that mirrors the production pipeline (organize →
extract → index → retrieve → answer) with the same prompts and validators.
No sample data is bundled: the vault starts empty, you import your own
documents, and everything stays in this tab's memory, clearing on reload.

Intelligence comes only from your own localhost model server
(Ollama-compatible). Nothing is uploaded, no cloud service is called — and
localhost alone is not trusted blindly: every configured model is verified
against live server metadata before it may receive report content.

## Connect a local model server

1. Install and run Ollama on this machine (default `http://127.0.0.1:11434`).
   Pull chat + embedding weights yourself, e.g. `ollama pull qwen3:8b` and
   `ollama pull embeddinggemma-2`. Optional: a model with both completion and vision capabilities for
   scans/photos; image-embedding models cannot transcribe reports. The client never downloads or pulls anything.
2. If the browser blocks the connection, restart Ollama with `OLLAMA_ORIGINS`
   set to this page's origin (e.g. `http://127.0.0.1:7124`).
3. In the client, open settings (tune icon) → **Local AI setup** and enter the
   server URL plus model names, then connect. The client checks the server is
   plain `http://localhost`, confirms each model is installed locally (name +
   digest), rejects anything served from a remote host or with the wrong
   capabilities, and pins embeddings to the verified model digest — so stale
   vectors from different weights can never match. Redirects are refused
   everywhere, including metadata calls.
4. Status meanings: **not configured** (empty fields), **unverified**
   (edited since the last check — treated as not connected), **verified**
   (name + digest shown). Only verified models receive content. Verification
   is refreshed against live server metadata before every call, so a model
   that goes remote, changes weights, or disappears mid-session is refused
   and disconnected rather than trusted on a stale check. Clearing all
   fields disconnects cleanly for keyword-only use.

Without a verified chat model, imports are still saved and keyword search
still works; answers explain that no local model is connected.

## Use it

For testing, create a profile with synthetic details, attach PDF/PNG/JPG/TXT reports with
the + button, and ask questions. Tap any `[source]` link to open the original
row. Digital PDFs are parsed locally with bundled PDFium resources. Sparse
PDF pages are rendered locally before optional local-model transcription;
scans remain marked for review when no suitable vision model is connected.
Correct a fact to see the summary invalidate; reprocess to refresh it.
Export a conversation to ChatGPT/Claude only via the explicit reviewed export.

Build the client with self-hosted renderer resources:

```sh
flutter build web --target lib/preview/main_preview.dart --no-web-resources-cdn
```

Serve `build/web` from a local HTTP server; opening `index.html` directly is not
supported. For example:

```sh
python3 -m http.server 7124 --bind 127.0.0.1 --directory build/web
```

Open `http://127.0.0.1:7124` in your browser. This does not publish anything.
The bootstrap serves CanvasKit locally and routes fallback-font requests to
local assets. No external renderer, font, or analytics service is required.

The browser keeps profiles, reports, sessions, and vectors only in RAM. Public
web search is unavailable in this browser client; it never substitutes cloud
inference. Encrypted storage, EmbeddingGemma 2 on-device search, camera handling,
reminders, and device performance still require native-app testing.
