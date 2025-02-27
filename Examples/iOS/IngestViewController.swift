import AVFoundation
import HaishinKit
import Photos
import UIKit
import VideoToolbox

final class IngestViewController: UIViewController {
    @IBOutlet private weak var currentFPSLabel: UILabel!
    @IBOutlet private weak var publishButton: UIButton!
    @IBOutlet private weak var pauseButton: UIButton!
    @IBOutlet private weak var videoBitrateLabel: UILabel!
    @IBOutlet private weak var videoBitrateSlider: UISlider!
    @IBOutlet private weak var audioBitrateLabel: UILabel!
    @IBOutlet private weak var zoomSlider: UISlider!
    @IBOutlet private weak var audioBitrateSlider: UISlider!
    @IBOutlet private weak var fpsControl: UISegmentedControl!
    @IBOutlet private weak var effectSegmentControl: UISegmentedControl!
    @IBOutlet private weak var audioDevicePicker: UIPickerView!
    @IBOutlet private weak var audioMonoStereoSegmentCOntrol: UISegmentedControl!

    private var pipIntentView = UIView()
    private var currentEffect: VideoEffect?
    private var currentPosition: AVCaptureDevice.Position = .back
    private var retryCount: Int = 0
    private var preferedStereo = false
    private let netStreamSwitcher: NetStreamSwitcher = .init()
    private var stream: NetStream {
        return netStreamSwitcher.stream
    }
    private lazy var audioCapture: AudioCapture = {
        let audioCapture = AudioCapture()
        audioCapture.delegate = self
        return audioCapture
    }()

    override func viewDidLoad() {
        super.viewDidLoad()

        netStreamSwitcher.uri = Preference.defaultInstance.uri ?? ""

        pipIntentView.layer.borderWidth = 1.0
        pipIntentView.layer.borderColor = UIColor.white.cgColor
        pipIntentView.bounds = MultiCamCaptureSettings.default.regionOfInterest
        pipIntentView.isUserInteractionEnabled = true
        view.addSubview(pipIntentView)

        // If you want to use the multi-camera feature, please make sure stream.isMultiCamSessionEnabled = true. Before attachCamera or attachAudio.
        stream.isMultiCamSessionEnabled = true
        if let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) {
            stream.videoOrientation = orientation
        }
        stream.isMonitoringEnabled = DeviceUtil.isHeadphoneConnected()
        stream.audioSettings.bitRate = 64 * 1000
        stream.bitrateStrategy = VideoAdaptiveNetBitRateStrategy(mamimumVideoBitrate: VideoCodecSettings.default.bitRate)
        videoBitrateSlider?.value = Float(VideoCodecSettings.default.bitRate) / 1000
        audioBitrateSlider?.value = Float(AudioCodecSettings.default.bitRate) / 1000

        NotificationCenter.default.addObserver(self, selector: #selector(on(_:)), name: UIDevice.orientationDidChangeNotification, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        logger.info("viewWillAppear")
        super.viewWillAppear(animated)
        let back = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: currentPosition)
        stream.attachCamera(back, channel: 0) { _, error in
            if let error {
                logger.warn(error)
            }
        }
        stream.attachAudio(AVCaptureDevice.default(for: .audio), automaticallyConfiguresApplicationAudioSession: false) { error in
            logger.warn(error)
        }
        let front = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        stream.attachCamera(front, channel: 1) { videoUnit, error in
            videoUnit?.isVideoMirrored = true
            if let error {
                logger.error(error)
            }
        }
        stream.addObserver(self, forKeyPath: "currentFPS", options: .new, context: nil)
        (view as? (any NetStreamDrawable))?.attachStream(stream)
        NotificationCenter.default.addObserver(self, selector: #selector(didInterruptionNotification(_:)), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(didRouteChangeNotification(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
    }

    override func viewWillDisappear(_ animated: Bool) {
        logger.info("viewWillDisappear")
        super.viewWillDisappear(animated)
        stream.removeObserver(self, forKeyPath: "currentFPS")
        (stream as? RTMPStream)?.close()
        stream.attachAudio(nil)
        stream.attachCamera(nil, channel: 0)
        stream.attachCamera(nil, channel: 1)
        // swiftlint:disable:next notification_center_detachment
        NotificationCenter.default.removeObserver(self)
    }

    // swiftlint:disable:next block_based_kvo
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        if Thread.isMainThread {
            currentFPSLabel?.text = "\(stream.currentFPS)"
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else {
            return
        }
        if touch.view == pipIntentView {
            let destLocation = touch.location(in: view)
            let prevLocation = touch.previousLocation(in: view)
            var currentFrame = pipIntentView.frame
            let deltaX = destLocation.x - prevLocation.x
            let deltaY = destLocation.y - prevLocation.y
            currentFrame.origin.x += deltaX
            currentFrame.origin.y += deltaY
            pipIntentView.frame = currentFrame
            stream.multiCamCaptureSettings = MultiCamCaptureSettings(
                mode: stream.multiCamCaptureSettings.mode,
                cornerRadius: 16.0,
                regionOfInterest: currentFrame,
                direction: .east
            )
        }
    }

    @IBAction func rotateCamera(_ sender: UIButton) {
        logger.info("rotateCamera")
        if stream.isMultiCamSessionEnabled {
            if stream.multiCamCaptureSettings.channel == 0 {
                stream.multiCamCaptureSettings.channel = 1
            } else {
                stream.multiCamCaptureSettings.channel = 0
            }
        } else {
            let position: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
            stream.attachCamera(AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)) { videoUnit, _ in
                videoUnit?.isVideoMirrored = position == .front
            }
            currentPosition = position
        }
    }

    @IBAction func toggleTorch(_ sender: UIButton) {
        stream.torch.toggle()
    }

    @IBAction func on(slider: UISlider) {
        if slider == audioBitrateSlider {
            audioBitrateLabel?.text = "audio \(Int(slider.value))/kbps"
            stream.audioSettings.bitRate = Int(slider.value * 1000)
        }
        if slider == videoBitrateSlider {
            videoBitrateLabel?.text = "video \(Int(slider.value))/kbps"
            stream.bitrateStrategy = VideoAdaptiveNetBitRateStrategy(mamimumVideoBitrate: Int(slider.value * 1000))
        }
        if slider == zoomSlider {
            let zoomFactor = CGFloat(slider.value)
            guard let device = stream.videoCapture(for: 0)?.device, 1 <= zoomFactor && zoomFactor < device.activeFormat.videoMaxZoomFactor else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.ramp(toVideoZoomFactor: zoomFactor, withRate: 5.0)
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for ramp: \(error)")
            }
        }
    }

    @IBAction func on(pause: UIButton) {
        (stream as? RTMPStream)?.paused.toggle()
    }

    @IBAction func on(close: UIButton) {
        self.dismiss(animated: true, completion: nil)
    }

    @IBAction func on(publish: UIButton) {
        if publish.isSelected {
            UIApplication.shared.isIdleTimerDisabled = false
            netStreamSwitcher.close()
            publish.setTitle("●", for: [])
        } else {
            UIApplication.shared.isIdleTimerDisabled = true
            netStreamSwitcher.open(.ingest)
            publish.setTitle("■", for: [])
        }
        publish.isSelected.toggle()
    }

    func tapScreen(_ gesture: UIGestureRecognizer) {
        if let gestureView = gesture.view, gesture.state == .ended {
            let touchPoint: CGPoint = gesture.location(in: gestureView)
            let pointOfInterest = CGPoint(x: touchPoint.x / gestureView.bounds.size.width, y: touchPoint.y / gestureView.bounds.size.height)
            guard
                let device = stream.videoCapture(for: 0)?.device, device.isFocusPointOfInterestSupported else {
                return
            }
            do {
                try device.lockForConfiguration()
                device.focusPointOfInterest = pointOfInterest
                device.focusMode = .continuousAutoFocus
                device.unlockForConfiguration()
            } catch let error as NSError {
                logger.error("while locking device for focusPointOfInterest: \(error)")
            }
        }
    }

    private func setEnabledPreferredInputBuiltInMic(_ isEnabled: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if isEnabled {
                guard
                    let availableInputs = session.availableInputs,
                    let builtInMicInput = availableInputs.first(where: { $0.portType == .builtInMic }) else {
                    return
                }
                try session.setPreferredInput(builtInMicInput)
            } else {
                try session.setPreferredInput(nil)
            }
        } catch {
        }
    }

    @IBAction private func onFPSValueChanged(_ segment: UISegmentedControl) {
        switch segment.selectedSegmentIndex {
        case 0:
            stream.frameRate = 15
        case 1:
            stream.frameRate = 30
        case 2:
            stream.frameRate = 60
        default:
            break
        }
    }

    @IBAction private func onEffectValueChanged(_ segment: UISegmentedControl) {
        if let currentEffect: VideoEffect = currentEffect {
            _ = stream.unregisterVideoEffect(currentEffect)
        }
        switch segment.selectedSegmentIndex {
        case 1:
            currentEffect = MonochromeEffect()
            _ = stream.registerVideoEffect(currentEffect!)
        case 2:
            currentEffect = PronamaEffect()
            _ = stream.registerVideoEffect(currentEffect!)
        default:
            break
        }
    }

    @IBAction private func onStereoMonoChanged(_ segment: UISegmentedControl) {
        switch segment.selectedSegmentIndex {
        case 0:
            preferedStereo = false
        case 1:
            preferedStereo = true
            pickerView(audioDevicePicker, didSelectRow: audioDevicePicker.selectedRow(inComponent: 0), inComponent: 0)
        default:
            break
        }
    }

    @objc
    private func didInterruptionNotification(_ notification: Notification) {
        logger.info(notification)
    }

    @objc
    private func didRouteChangeNotification(_ notification: Notification) {
        logger.info(notification)
        if AVAudioSession.sharedInstance().inputDataSources?.isEmpty == true {
            setEnabledPreferredInputBuiltInMic(false)
            audioMonoStereoSegmentCOntrol.isHidden = true
            audioDevicePicker.isHidden = true
        } else {
            setEnabledPreferredInputBuiltInMic(true)
            audioMonoStereoSegmentCOntrol.isHidden = false
            audioDevicePicker.isHidden = false
        }
        audioDevicePicker.reloadAllComponents()
        if DeviceUtil.isHeadphoneDisconnected(notification) {
            stream.isMonitoringEnabled = false
        } else {
            stream.isMonitoringEnabled = DeviceUtil.isHeadphoneConnected()
        }
    }

    @objc
    private func on(_ notification: Notification) {
        guard let orientation = DeviceUtil.videoOrientation(by: UIApplication.shared.statusBarOrientation) else {
            return
        }
        stream.videoOrientation = orientation
    }
}

extension IngestViewController: IORecorderDelegate {
    // MARK: IORecorderDelegate
    func recorder(_ recorder: IORecorder, errorOccured error: IORecorder.Error) {
        logger.error(error)
    }

    func recorder(_ recorder: IORecorder, finishWriting writer: AVAssetWriter) {
        PHPhotoLibrary.shared().performChanges({() -> Void in
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: writer.outputURL)
        }, completionHandler: { _, error -> Void in
            do {
                try FileManager.default.removeItem(at: writer.outputURL)
            } catch {
                logger.warn(error)
            }
        })
    }
}

extension IngestViewController: AudioCaptureDelegate {
    // MARK: AudioCaptureDelegate
    func audioCapture(_ audioCapture: AudioCapture, buffer: AVAudioBuffer, time: AVAudioTime) {
        stream.append(buffer, when: time)
    }
}

extension IngestViewController: UIPickerViewDelegate {
    // MARK: UIPickerViewDelegate
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let session = AVAudioSession.sharedInstance()
        guard let preferredInput = session.preferredInput,
              let newDataSource = preferredInput.dataSources?[row],
              let supportedPolarPatterns = newDataSource.supportedPolarPatterns else {
            return
        }
        do {
            if #available(iOS 14.0, *) {
                if preferedStereo && supportedPolarPatterns.contains(.stereo) {
                    try newDataSource.setPreferredPolarPattern(.stereo)
                    logger.info("stereo")
                } else {
                    audioMonoStereoSegmentCOntrol.selectedSegmentIndex = 0
                    logger.info("mono")
                }
            }
            try preferredInput.setPreferredDataSource(newDataSource)
        } catch {
            logger.warn("can't set supported setPreferredDataSource")
        }
        stream.attachAudio(AVCaptureDevice.default(for: .audio), automaticallyConfiguresApplicationAudioSession: false) { error in
            logger.warn(error)
        }
    }
}

extension IngestViewController: UIPickerViewDataSource {
    // MARK: UIPickerViewDataSource
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        return 1
    }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        return AVAudioSession.sharedInstance().preferredInput?.dataSources?.count ?? 0
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        return AVAudioSession.sharedInstance().preferredInput?.dataSources?[row].dataSourceName ?? ""
    }
}
