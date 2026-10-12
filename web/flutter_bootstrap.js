{{flutter_js}}
{{flutter_build_config}}

// Renderer files are served beside the app. This preview does not require a
// renderer CDN, remote fonts, analytics, or any inference service.
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: "canvaskit/",
    fontFallbackBaseUrl: "assets/fonts/"
  },
  onEntrypointLoaded: async function(engineInitializer) {
    const appRunner = await engineInitializer.initializeEngine();
    document.getElementById("loading")?.remove();
    await appRunner.runApp();
  }
});
