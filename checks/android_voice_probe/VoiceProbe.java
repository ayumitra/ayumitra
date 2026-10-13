package app.ayumitra.voiceprobe;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Intent;
import android.os.Bundle;
import android.speech.RecognizerIntent;
import java.lang.reflect.*;
import java.util.*;

/** Native regression checks, without microphone capture or model downloads. */
public class VoiceProbe extends Instrumentation {
  @Override public void onCreate(Bundle args) { super.onCreate(args); start(); }
  private static void require(boolean value, String label) {
    if (!value) throw new AssertionError(label);
  }
  @Override public void onStart() {
    Bundle result = new Bundle();
    runOnMainSync(() -> {
      Locale original = Locale.getDefault();
      try {
        ClassLoader loader = getTargetContext().getClassLoader();
        Class<?> bridge = Class.forName("app.ayumitra.ayumitra.LocalVoiceBridge", true, loader);
        Object instance = bridge.getField("INSTANCE").get(null);
        Class<?> callClass = Class.forName("io.flutter.plugin.common.MethodCall", true, loader);
        Constructor<?> constructor = callClass.getConstructor(String.class, Object.class);
        Method decode = bridge.getDeclaredMethod("sessionArg", callClass);
        decode.setAccessible(true);
        Map<String,Object> args = new HashMap<>();
        long session = 1L << 52;
        args.put("sessionId", session);
        require(Long.valueOf(session).equals(decode.invoke(instance, constructor.newInstance("start",args))), "64-bit session narrowed");
        args.put("sessionId", 42);
        require(Long.valueOf(42).equals(decode.invoke(instance, constructor.newInstance("start",args))), "32-bit codec input rejected");
        args.put("sessionId", 42.0);
        require(decode.invoke(instance, constructor.newInstance("start",args)) == null, "floating session accepted");
        result.putString("session_codec", "PASS");
        Method select = bridge.getDeclaredMethod("selectInstalledEnglish", List.class);
        select.setAccessible(true);
        Locale.setDefault(new Locale("en","IN"));
        require("en-IN".equals(select.invoke(instance,Arrays.asList("en_US","en_IN"))), "installed device English ignored");
        require("en-US".equals(select.invoke(instance,Arrays.asList("en_GB","en_US"))), "US fallback priority lost");
        require("en-GB".equals(select.invoke(instance,Arrays.asList("fr_FR","en_GB"))), "installed other English ignored");
        require(select.invoke(instance,Arrays.asList("english","enochian","fr-FR","en-")) == null, "non-English accepted");
        require(select.invoke(instance,Collections.emptyList()) == null, "empty installed list accepted");
        result.putString("installed_english", "PASS");
        Method listen = bridge.getDeclaredMethod("listenIntent",String.class);
        listen.setAccessible(true);
        Intent intent = (Intent)listen.invoke(instance,"en-IN");
        require("en-IN".equals(intent.getStringExtra(RecognizerIntent.EXTRA_LANGUAGE)), "uninstalled US locale substituted");
        require(intent.getBooleanExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE,false), "offline preference lost");
        List<String> hints = intent.getStringArrayListExtra(RecognizerIntent.EXTRA_BIASING_STRINGS);
        require(hints != null && hints.contains("Hey Ayumitra") && hints.contains("Hey Aayu Mitra"), "wake bias hints lost");
        result.putString("recognition_intent", "PASS");
        result.putString("result", "ALL_PASS");
      } catch (Throwable error) {
        // Assertion labels contain only test metadata; no patient data is read.
        result.putString("result", "FAIL");
        result.putString("failure", error instanceof AssertionError ? error.getMessage() : error.getClass().getSimpleName());
      } finally { Locale.setDefault(original); }
    });
    finish("ALL_PASS".equals(result.getString("result")) ? Activity.RESULT_OK : Activity.RESULT_CANCELED,result);
  }
}
