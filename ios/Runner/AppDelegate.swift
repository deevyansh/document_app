import Flutter
import UIKit
import Speech
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  // MARK: - Speech recognition state
  //
  // Kept as instance properties (not locals) so a second tap on the mic
  // button — or the app backgrounding mid-listen — can always find and
  // tear down whatever session is currently running via stopListening().

  private let audioEngine = AVAudioEngine()
  private var speechRecognizer: SFSpeechRecognizer?
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var recognitionTask: SFSpeechRecognitionTask?
  private var silenceTimer: Timer?

  /// How long to wait after the transcription last changed before treating
  /// speech as finished. Tune this if it feels like it cuts people off too
  /// early/late once you test on a device.
  private let silenceTimeout: TimeInterval = 1.5

  /// Hard ceiling regardless of pauses, so background noise that keeps
  /// resetting the silence timer can't leave the mic open indefinitely.
  private let maxListenDuration: TimeInterval = 15

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  // Plugin registration AND app-level method channels both have to live
  // here now (not in didFinishLaunchingWithOptions) — under the new
  // UIScene lifecycle, the storyboard's FlutterViewController/engine isn't
  // created yet at didFinishLaunchingWithOptions time, so
  // engineBridge.applicationRegistrar.messenger() wouldn't exist yet if we
  // tried to set this up any earlier.
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Must match constants.dart's `MethodChannel('document_app/widget')`
    // exactly — this is the same channel main.dart/search_page.dart/
    // profile_page.dart already call into on Android.
    let widgetChannel = FlutterMethodChannel(
      name: "document_app/widget",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )

    widgetChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {

      case "startSpeechRecognition":
        self.startSpeechRecognition(result: result)

      case "getLaunchAction":
        // iOS has no home-screen-widget quick-launch equivalent to
        // Android's app widget (see the `if (Platform.isAndroid)` guard
        // around the widget promo in profile_page.dart) — there is never
        // a pending launch action to report, so nil is the correct
        // "normal launch" answer every time.
        result(nil)

      case "isPinWidgetSupported":
        result(false)

      case "requestPinWidget":
        result(FlutterError(
          code: "UNSUPPORTED",
          message: "Home-screen widgets aren't available on iOS.",
          details: nil
        ))

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  // MARK: - Speech recognition
  //
  // Mirrors what the Android side already does for "startSpeechRecognition"
  // — request permissions, listen, and resolve the Dart `invokeMethod` call
  // with the transcribed text (or a FlutterError the Dart side's
  // `on PlatformException catch` in _startListening() can actually catch,
  // unlike the MissingPluginException that was happening before).

  private func startSpeechRecognition(result: @escaping FlutterResult) {
    SFSpeechRecognizer.requestAuthorization { [weak self] authStatus in
      DispatchQueue.main.async {
        guard let self = self else { return }
        switch authStatus {
        case .authorized:
          self.requestMicPermissionAndListen(result: result)
        case .denied, .restricted, .notDetermined:
          result(FlutterError(
            code: "SPEECH_AUTH_DENIED",
            message: "Speech recognition permission was denied.",
            details: nil
          ))
        @unknown default:
          result(FlutterError(
            code: "SPEECH_AUTH_UNKNOWN",
            message: "Speech recognition permission could not be determined.",
            details: nil
          ))
        }
      }
    }
  }

  private func requestMicPermissionAndListen(result: @escaping FlutterResult) {
    AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        guard let self = self else { return }
        guard granted else {
          result(FlutterError(
            code: "MIC_PERMISSION_DENIED",
            message: "Microphone permission was denied.",
            details: nil
          ))
          return
        }
        self.beginListening(result: result)
      }
    }
  }

  private func beginListening(result: @escaping FlutterResult) {
    // Clean slate — a stray previous session (e.g. the user backgrounded
    // the app mid-listen last time) would otherwise crash on
    // audioEngine.start() below.
    stopListening()

    guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
      result(FlutterError(
        code: "SPEECH_UNAVAILABLE",
        message: "Speech recognizer is unavailable on this device right now.",
        details: nil
      ))
      return
    }
    speechRecognizer = recognizer

    let audioSession = AVAudioSession.sharedInstance()
    do {
      try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
      try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
    } catch {
      result(FlutterError(
        code: "AUDIO_SESSION_ERROR",
        message: "Couldn't configure the audio session: \(error.localizedDescription)",
        details: nil
      ))
      return
    }

    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    recognitionRequest = request

    var didFinish = false
    let finish: (String?, FlutterError?) -> Void = { [weak self] text, err in
      guard let self = self, !didFinish else { return }
      didFinish = true
      self.stopListening()
      if let err = err {
        result(err)
      } else {
        result(text)
      }
    }

    let inputNode = audioEngine.inputNode

    recognitionTask = recognizer.recognitionTask(with: request) { [weak self] speechResult, error in
      DispatchQueue.main.async {
        guard let self = self else { return }

        if let error = error {
          finish(nil, FlutterError(
            code: "SPEECH_RECOGNITION_ERROR",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        guard let speechResult = speechResult else { return }

        if speechResult.isFinal {
          finish(speechResult.bestTranscription.formattedString, nil)
          return
        }

        // Not final yet — restart the "user has gone quiet" timer every
        // time the transcription updates, and only actually finish once
        // it's been silenceTimeout seconds since the last update.
        self.resetSilenceTimer {
          finish(speechResult.bestTranscription.formattedString, nil)
        }
      }
    }

    let recordingFormat = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
      request.append(buffer)
    }

    audioEngine.prepare()
    do {
      try audioEngine.start()
    } catch {
      finish(nil, FlutterError(
        code: "AUDIO_ENGINE_ERROR",
        message: "Couldn't start the audio engine: \(error.localizedDescription)",
        details: nil
      ))
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + maxListenDuration) {
      // Treat a full timeout as "nothing captured" (nil), not an error —
      // matches how _startListening() on the Dart side already no-ops
      // silently when spokenText is null.
      finish(nil, nil)
    }
  }

  private func resetSilenceTimer(onSilence: @escaping () -> Void) {
    silenceTimer?.invalidate()
    silenceTimer = Timer.scheduledTimer(withTimeInterval: silenceTimeout, repeats: false) { _ in
      onSilence()
    }
  }

  private func stopListening() {
    silenceTimer?.invalidate()
    silenceTimer = nil

    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }

    recognitionRequest?.endAudio()
    recognitionTask?.cancel()
    recognitionRequest = nil
    recognitionTask = nil

    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}