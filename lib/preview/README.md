# Browser client (in-memory replica of prod)

This is the same Flutter interface used by the mobile app, backed by an
in-memory `DemoController` that mirrors the production pipeline (organize →
extract → index → retrieve → answer) with the same prompts and validators.
No sample data is bundled: the vault starts empty, you import your own
documents, and everything stays in this tab's memory, clearing on reload.

Intelligence comes only from your own localhost model server
(Ollama-compatible). Nothing is uploaded, no cloud service is called.

## Connect a local model server

1. Install and run Ollama on this machine (default `http://127.0.0.1:11434`).
   Pull a chat model, e.g. `ollama pull gemma3:1b`. Optional: a vision model
   for scans/photos and an embedding model (e.g. `ollama pull embeddinggemma`)
   for semantic search — keyword search works without it.
2. If the browser blocks the connection, restart Ollama with `OLLAMA_ORIGINS`
   set to this page's origin (e.g. `http://127.0.0.1:7124`).
3. In the client, open settings (tune icon) → **Local AI setup** and enter the
   server URL plus model names. The status line confirms what is connected.

Without a chat model, imports are still saved and keyword search still works;
answers explain that no local model is connected.

## Use it

Create a profile with your own details, attach PDF/PNG/JPG/TXT reports with
the + button, and ask questions. Tap any `[source]` link to open the original
row. Correct a fact to see the summary invalidate; reprocess to refresh it.
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

Encrypted storage, EmbeddingGemma 2 on-device search, camera handling,
reminders, and device performance still require native-app testing.
