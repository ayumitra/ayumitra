# Bundled default browser font

The browser preview includes the Roboto default font requested by Flutter
3.44.1's CanvasKit engine. The font is served locally at the same relative
path the engine expects under `fontFallbackBaseUrl`.

- Upstream file: https://fonts.gstatic.com/s/roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2
- SHA-256: `35b02ca266b79eb4996590f15817425a1ce9ebf48f84471843233ff614656bf2`
- License: Apache License 2.0, included in `ROBOTO-LICENSE.txt` from
  https://github.com/googlefonts/roboto-2/blob/main/LICENSE

No font download is needed while using the built preview. Unsupported scripts
may lack fallback glyphs; this preview targets English.
