import Flutter
import UIKit
import AVFoundation
import VisionKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var docScanner: DocScanner?

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Native camera channel — register here (rootViewController isn't ready in
    // didFinishLaunching with the implicit-engine pattern).
    if let messenger = engineBridge.pluginRegistry
      .registrar(forPlugin: "PinCamera")?.messenger() {
      let channel = FlutterMethodChannel(
        name: "io.tokens2.pin/camera", binaryMessenger: messenger)
      channel.setMethodCallHandler { [weak self] call, result in
        guard let top = self?.topViewController() else {
          result(nil)
          return
        }
        switch call.method {
        case "open":
          let cam = CameraViewController { result($0) }
          top.present(cam, animated: true)
        case "scan":
          guard VNDocumentCameraViewController.isSupported else {
            result(nil)
            return
          }
          let scanner = DocScanner { result($0) }
          self?.docScanner = scanner
          scanner.present(from: top)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  private func topViewController() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes
    let window = scenes.compactMap { ($0 as? UIWindowScene)?.windows.first { $0.isKeyWindow } }
      .first ?? (scenes.compactMap { ($0 as? UIWindowScene)?.windows.first }.first)
    var vc = window?.rootViewController
    while let presented = vc?.presentedViewController { vc = presented }
    return vc
  }
}

/// VisionKit document scanner ("Text scan"-style, auto edge detection). Returns
/// { "paths": [jpeg, ...] } — one per scanned page.
final class DocScanner: NSObject, VNDocumentCameraViewControllerDelegate {
  private let completion: ([String: Any]?) -> Void
  init(completion: @escaping ([String: Any]?) -> Void) {
    self.completion = completion
    super.init()
  }

  func present(from vc: UIViewController) {
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    scanner.modalPresentationStyle = .fullScreen
    vc.present(scanner, animated: true)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController,
    didFinishWith scan: VNDocumentCameraScan
  ) {
    controller.dismiss(animated: true)
    var paths: [String] = []
    for i in 0..<scan.pageCount {
      if let data = scan.imageOfPage(at: i).jpegData(compressionQuality: 0.85) {
        let path = NSTemporaryDirectory()
          + "pin_scan_\(Int(Date().timeIntervalSince1970))_\(i).jpg"
        try? data.write(to: URL(fileURLWithPath: path))
        paths.append(path)
      }
    }
    completion(paths.isEmpty ? nil : ["paths": paths])
  }

  func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) {
    c.dismiss(animated: true)
    completion(nil)
  }

  func documentCameraViewController(
    _ c: VNDocumentCameraViewController, didFailWithError error: Error
  ) {
    c.dismiss(animated: true)
    completion(nil)
  }
}

/// Custom full-screen camera with a Text scan · Photo · Video mode switcher,
/// mirroring modern AI-app cameras. Returns to Flutter:
///   photo  → ["path": jpeg, "isVideo": false]
///   video  → ["path": mov,  "isVideo": true]
///   scan   → ["paths": [jpeg, ...]]
final class CameraViewController: UIViewController,
  AVCapturePhotoCaptureDelegate, AVCaptureFileOutputRecordingDelegate,
  VNDocumentCameraViewControllerDelegate {

  enum Mode: Int { case scan = 0, photo = 1, video = 2 }

  private let completion: ([String: Any]?) -> Void
  private var finished = false

  private let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "pin.camera.session")
  private let photoOutput = AVCapturePhotoOutput()
  private let movieOutput = AVCaptureMovieFileOutput()
  private var previewLayer: AVCaptureVideoPreviewLayer!
  private var videoInput: AVCaptureDeviceInput?
  private var position: AVCaptureDevice.Position = .back
  private var flashOn = false
  private var mode: Mode = .photo
  private var recording = false

  private let captureButton = UIButton(type: .custom)
  private let innerDot = UIView()
  private var modeButtons: [UIButton] = []

  init(completion: @escaping ([String: Any]?) -> Void) {
    self.completion = completion
    super.init(nibName: nil, bundle: nil)
    modalPresentationStyle = .fullScreen
  }
  required init?(coder: NSCoder) { fatalError() }

  // MARK: lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .black
    configureSession()
    buildUI()
    queue.async { self.session.startRunning() }
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    previewLayer?.frame = view.bounds
  }

  private func finish(_ payload: [String: Any]?) {
    guard !finished else { return }
    finished = true
    queue.async { self.session.stopRunning() }
    dismiss(animated: true) { self.completion(payload) }
  }

  // MARK: session

  private func configureSession() {
    session.beginConfiguration()
    session.sessionPreset = .high
    if let device = camera(for: position),
       let input = try? AVCaptureDeviceInput(device: device),
       session.canAddInput(input) {
      session.addInput(input)
      videoInput = input
    }
    if let mic = AVCaptureDevice.default(for: .audio),
       let micInput = try? AVCaptureDeviceInput(device: mic),
       session.canAddInput(micInput) {
      session.addInput(micInput)
    }
    if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
    if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
    session.commitConfiguration()

    previewLayer = AVCaptureVideoPreviewLayer(session: session)
    previewLayer.videoGravity = .resizeAspectFill
    previewLayer.frame = view.bounds
    view.layer.insertSublayer(previewLayer, at: 0)
  }

  private func camera(for pos: AVCaptureDevice.Position) -> AVCaptureDevice? {
    AVCaptureDevice.DiscoverySession(
      deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: pos
    ).devices.first
  }

  // MARK: UI

  private func buildUI() {
    let close = roundButton("xmark")
    close.addTarget(self, action: #selector(onClose), for: .touchUpInside)
    place(close, top: 12, leading: 16)

    let flip = roundButton("arrow.triangle.2.circlepath")
    flip.addTarget(self, action: #selector(onFlip), for: .touchUpInside)
    place(flip, top: 12, trailing: 16)

    let flash = roundButton("bolt.slash.fill")
    flash.tag = 99
    flash.addTarget(self, action: #selector(onFlash), for: .touchUpInside)
    place(flash, top: 64, trailing: 16)

    // Capture button
    captureButton.translatesAutoresizingMaskIntoConstraints = false
    captureButton.layer.cornerRadius = 38
    captureButton.layer.borderWidth = 5
    captureButton.layer.borderColor = UIColor.white.cgColor
    captureButton.addTarget(self, action: #selector(onCapture), for: .touchUpInside)
    view.addSubview(captureButton)
    innerDot.translatesAutoresizingMaskIntoConstraints = false
    innerDot.backgroundColor = .white
    innerDot.layer.cornerRadius = 30
    innerDot.isUserInteractionEnabled = false
    captureButton.addSubview(innerDot)
    NSLayoutConstraint.activate([
      captureButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      captureButton.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -64),
      captureButton.widthAnchor.constraint(equalToConstant: 76),
      captureButton.heightAnchor.constraint(equalToConstant: 76),
      innerDot.centerXAnchor.constraint(equalTo: captureButton.centerXAnchor),
      innerDot.centerYAnchor.constraint(equalTo: captureButton.centerYAnchor),
      innerDot.widthAnchor.constraint(equalToConstant: 60),
      innerDot.heightAnchor.constraint(equalToConstant: 60),
    ])

    // Mode switcher
    let stack = UIStackView()
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.axis = .horizontal
    stack.distribution = .equalSpacing
    stack.spacing = 26
    for (i, title) in ["Text scan", "Photo", "Video"].enumerated() {
      let b = UIButton(type: .system)
      b.setTitle(title, for: .normal)
      b.tag = i
      b.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
      b.addTarget(self, action: #selector(onMode(_:)), for: .touchUpInside)
      modeButtons.append(b)
      stack.addArrangedSubview(b)
    }
    view.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      stack.bottomAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -18),
    ])
    refreshMode()
  }

  private func roundButton(_ symbol: String) -> UIButton {
    let b = UIButton(type: .system)
    b.translatesAutoresizingMaskIntoConstraints = false
    b.setImage(UIImage(systemName: symbol), for: .normal)
    b.tintColor = .white
    b.backgroundColor = UIColor.black.withAlphaComponent(0.35)
    b.layer.cornerRadius = 21
    b.widthAnchor.constraint(equalToConstant: 42).isActive = true
    b.heightAnchor.constraint(equalToConstant: 42).isActive = true
    return b
  }

  private func place(_ b: UIButton, top: CGFloat, leading: CGFloat? = nil,
                     trailing: CGFloat? = nil) {
    view.addSubview(b)
    b.topAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.topAnchor, constant: top).isActive = true
    if let l = leading {
      b.leadingAnchor.constraint(
        equalTo: view.leadingAnchor, constant: l).isActive = true
    }
    if let t = trailing {
      b.trailingAnchor.constraint(
        equalTo: view.trailingAnchor, constant: -t).isActive = true
    }
  }

  private func refreshMode() {
    for b in modeButtons {
      let on = b.tag == mode.rawValue
      b.setTitleColor(on ? .white : UIColor.white.withAlphaComponent(0.5), for: .normal)
    }
    // Red dot for video.
    innerDot.backgroundColor = (mode == .video) ? .systemRed : .white
  }

  // MARK: actions

  @objc private func onClose() { finish(nil) }

  @objc private func onMode(_ sender: UIButton) {
    guard !recording, let m = Mode(rawValue: sender.tag) else { return }
    mode = m
    refreshMode()
    if mode == .scan { presentScanner() }
  }

  @objc private func onFlip() {
    guard !recording else { return }
    position = (position == .back) ? .front : .back
    queue.async {
      self.session.beginConfiguration()
      if let old = self.videoInput { self.session.removeInput(old) }
      if let device = self.camera(for: self.position),
         let input = try? AVCaptureDeviceInput(device: device),
         self.session.canAddInput(input) {
        self.session.addInput(input)
        self.videoInput = input
      }
      self.session.commitConfiguration()
    }
  }

  @objc private func onFlash(_ sender: UIButton) {
    flashOn.toggle()
    sender.setImage(
      UIImage(systemName: flashOn ? "bolt.fill" : "bolt.slash.fill"), for: .normal)
  }

  @objc private func onCapture() {
    switch mode {
    case .scan:
      presentScanner()
    case .photo:
      let settings = AVCapturePhotoSettings()
      if videoInput?.device.hasFlash == true {
        settings.flashMode = flashOn ? .on : .off
      }
      photoOutput.capturePhoto(with: settings, delegate: self)
    case .video:
      if recording {
        movieOutput.stopRecording()
      } else {
        let path = NSTemporaryDirectory()
          + "pin_vid_\(Int(Date().timeIntervalSince1970)).mov"
        recording = true
        captureButton.layer.borderColor = UIColor.systemRed.cgColor
        movieOutput.startRecording(to: URL(fileURLWithPath: path), recordingDelegate: self)
      }
    }
  }

  // MARK: photo delegate

  func photoOutput(_ output: AVCapturePhotoOutput,
                   didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard let data = photo.fileDataRepresentation() else { finish(nil); return }
    let path = NSTemporaryDirectory()
      + "pin_cam_\(Int(Date().timeIntervalSince1970)).jpg"
    try? data.write(to: URL(fileURLWithPath: path))
    finish(["path": path, "isVideo": false])
  }

  // MARK: video delegate

  func fileOutput(_ output: AVCaptureFileOutput,
                  didFinishRecordingTo outputFileURL: URL,
                  from connections: [AVCaptureConnection], error: Error?) {
    recording = false
    if error != nil { finish(nil); return }
    finish(["path": outputFileURL.path, "isVideo": true])
  }

  // MARK: scan delegate

  private func presentScanner() {
    guard VNDocumentCameraViewController.isSupported else { return }
    let scanner = VNDocumentCameraViewController()
    scanner.delegate = self
    scanner.modalPresentationStyle = .fullScreen
    present(scanner, animated: true)
  }

  func documentCameraViewController(
    _ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan
  ) {
    controller.dismiss(animated: true)
    var paths: [String] = []
    for i in 0..<scan.pageCount {
      if let data = scan.imageOfPage(at: i).jpegData(compressionQuality: 0.85) {
        let path = NSTemporaryDirectory()
          + "pin_scan_\(Int(Date().timeIntervalSince1970))_\(i).jpg"
        try? data.write(to: URL(fileURLWithPath: path))
        paths.append(path)
      }
    }
    finish(paths.isEmpty ? nil : ["paths": paths])
  }

  func documentCameraViewControllerDidCancel(_ c: VNDocumentCameraViewController) {
    c.dismiss(animated: true)  // back to camera; don't finish
  }

  func documentCameraViewController(
    _ c: VNDocumentCameraViewController, didFailWithError error: Error
  ) {
    c.dismiss(animated: true)
  }
}
