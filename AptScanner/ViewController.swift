import UIKit
import AVFoundation
import MLKit

class ViewController: UIViewController {
  private var isProcessingFrame = false
  private var lastProcessingTime: TimeInterval = 0
  private let processingInterval: TimeInterval = 0.333
  private var captureSession: AVCaptureSession?
  private var previewLayer: AVCaptureVideoPreviewLayer?
  private let textRecognizer = TextRecognizer.textRecognizer(options: TextRecognizerOptions())
  
  private lazy var resultLabel: UILabel = {
    let label = UILabel()
    label.textColor = .white
    label.font = .boldSystemFont(ofSize: 72)
    label.textAlignment = .center
    label.isHidden = true
    label.backgroundColor = .black
    return label
  }()
  
  override func viewDidLoad() {
    super.viewDidLoad()
    setupCamera()
    setupResultLabel()
    setupGestureRecognizer()
  }
  
  override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
    return UIInterfaceOrientationMask.portrait
  }
  
  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    self.previewLayer?.frame = self.view.bounds
  }
  
  deinit {
    NotificationCenter.default.removeObserver(self)
  }
  
  private func setupResultLabel() {
    self.view.addSubview(resultLabel)
    self.resultLabel.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.resultLabel.topAnchor.constraint(equalTo: self.view.topAnchor),
      self.resultLabel.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
      self.resultLabel.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
      self.resultLabel.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
    ])
  }
  
  private func setupGestureRecognizer() {
    let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
    doubleTap.numberOfTapsRequired = 2
    self.view.addGestureRecognizer(doubleTap)
  }
  
  private func setupCamera() {
    self.captureSession = AVCaptureSession()
    
    guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
          let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
          self.captureSession?.canAddInput(videoInput) == true else {
      return
    }
    
    self.captureSession?.addInput(videoInput)
    
    let videoOutput = AVCaptureVideoDataOutput()
    videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "videoQueue"))
    
    if self.captureSession?.canAddOutput(videoOutput) == true {
      self.captureSession?.addOutput(videoOutput)
    }
    
    self.previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession!)
    self.previewLayer?.videoGravity = .resizeAspectFill
    self.previewLayer?.frame = self.view.layer.bounds
    self.view.layer.addSublayer(self.previewLayer!)
    
    // Start capture session on background thread
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      self?.captureSession?.startRunning()
    }
  }
  
  @objc private func handleDoubleTap() {
    if self.resultLabel.isHidden {
      return
    }
    
    UIView.animate(withDuration: 0.3) {
      self.resultLabel.isHidden = true
      self.self.previewLayer?.isHidden = false
    }
  }
  
  func extractAddress(from rawText:String) -> String? {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue) else {
      return nil
    }
    
    let matches = detector.matches(in: rawText, options: [], range: NSRange(rawText.startIndex..., in: rawText))
    for match in matches {
      guard let components = match.addressComponents else {
        continue
      }
      
      // Safely extract city, ZIP, and street. (Keys can be nil.)
      let street = components[NSTextCheckingKey.street] ?? ""
      let city = components[NSTextCheckingKey.city] ?? ""
      let state = components[NSTextCheckingKey.state] ?? ""
      let zip = components[NSTextCheckingKey.zip] ?? ""
      
      // Check city or ZIP
      let cityMatches = city.range(of: "lauderdale", options: .caseInsensitive) != nil
      let zipMatches = (zip.contains("33301"))
      let cityOrZipOK = cityMatches || zipMatches
      
      // Check street number
      let streetHas419 = street.range(of: "419") != nil
      let is2ndStreet = street.range(of: "2nd") != nil || street.range(of: "2ND") != nil
      let streetOrBuildingOK = streetHas419 || is2ndStreet
      
      // If both conditions pass, return true
      if !cityOrZipOK || !streetOrBuildingOK {
        return nil
      }
      
      let lines = [street, city, state, zip].filter { !$0.isEmpty }
      return lines.joined(separator: ", ")
    }
    
    return nil
  }
  
  private func extractApartmentNumber(from text: String) -> String? {
    let patterns = [
      "(?i)(?:APT|UNIT|#)\\s*([0-9A-Z-]+)",
      "(?i)\\b\\d+[A-Z]?\\s*(?:APT|UNIT|#)",
      "(?i)(?<=\\n|^)\\s*#?\\d+[A-Z]?\\s*(?=\\n|$)"
    ]
    
    for line in text.components(separatedBy: .newlines) {
      for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: line) else {
          
          continue
        }
        
        return String(line[matchRange])
      }
    }
    
    return nil
  }
  
  private func processImageWithMultipleOrientations(_ image: VisionImage, completion: @escaping (String?, String?) -> Void) {
    let orientations: [UIImage.Orientation] = [.up, .right, .down, .left]
    
    // Try one orientation at a time
    func tryNextOrientation(_ index: Int) {
      // If we've tried all orientations, call completion with nil
      guard index < orientations.count else {
        completion(nil, nil)
        return
      }
      
      // Create a copy of the image with new orientation
      let rotatedImage = image
      rotatedImage.orientation = orientations[index]
      
      self.textRecognizer.process(rotatedImage) { result, error in
        guard let result = result, error == nil else {
          // Try next orientation if this one failed
          tryNextOrientation(index + 1)
          return
        }
        
        if let address = self.extractAddress(from: result.text),
         let apartment = self.extractApartmentNumber(from: address) {
          // Found a valid result, return it
          completion(address, apartment)
        } else {
          // No valid result in this orientation, try next
          tryNextOrientation(index + 1)
        }
      }
    }
    
    // Start with the first orientation
    tryNextOrientation(0)
  }
  
  private func showResult(_ apartmentNumber: String) {
    self.resultLabel.text = apartmentNumber
    
    UIView.animate(withDuration: 0.3) {
      self.previewLayer?.isHidden = true
      self.resultLabel.isHidden = false
    }
  }
  
  private func imageOrientation(
    deviceOrientation: UIDeviceOrientation,
    cameraPosition: AVCaptureDevice.Position
  ) -> UIImage.Orientation {
    switch deviceOrientation {
    case .portrait:
      return cameraPosition == .front ? .leftMirrored : .right
    case .landscapeLeft:
      return cameraPosition == .front ? .downMirrored : .up
    case .landscapeRight:
      return cameraPosition == .front ? .upMirrored : .down
    case .portraitUpsideDown:
      return cameraPosition == .front ? .rightMirrored : .left
    default:
      return cameraPosition == .front ? .leftMirrored : .right
    }
  }
}

extension ViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    let currentTime = CACurrentMediaTime()
    guard !self.isProcessingFrame, currentTime - self.lastProcessingTime >= self.processingInterval else {
      return
    }
    
    self.isProcessingFrame = true
    self.lastProcessingTime = currentTime
    
    let image = VisionImage(buffer: sampleBuffer)
    
    self.processImageWithMultipleOrientations(image) { [weak self] address, apartment in
      guard let self = self else { return }
      
      if let address = address, let apartment = apartment {
        NSLog("----------------------------------")
        NSLog("address: \(address)\n")
        NSLog("apt: \(apartment)\n")
        NSLog("----------------------------------")
        
        self.showResult(apartment)
      }
      
      self.isProcessingFrame = false
    }
  }
}
