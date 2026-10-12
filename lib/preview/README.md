# Browser UX preview

This is the same Flutter interface used by the mobile app, backed by an
in-memory `DemoController`. It uses synthetic English records and explicitly
labelled scripted responses. It does not upload files, persist a health vault,
load AI models, fetch web results, or measure mobile model performance.

Use invented onboarding details. Add one synthetic report with the attachment
button, or use **Try a synthetic example** to add the complete sample history.
Explore source links, older and undated records, age/category filters, and fact
correction. Reloading the page clears the session.

Build the preview with self-hosted renderer resources:

```sh
flutter build web --target lib/preview/main_preview.dart --no-web-resources-cdn
```

Serve `build/web` from a local HTTP server; opening `index.html` directly is not
supported. For example:

```sh
python3 -m http.server 8080 --bind 127.0.0.1 --directory build/web
```

Open `http://127.0.0.1:8080` in your browser. This does not publish the preview.
The bootstrap serves CanvasKit locally and routes fallback-font requests to
local assets. No external renderer, font, or analytics service is required.

The preview exercises interaction design. Real document reading, encrypted
storage, EmbeddingGemma 2 search, local inference, camera handling, reminders,
and device performance still require native-app testing.
