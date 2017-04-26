//
//  ScanViewController.swift
//  YLQRCode
//
//  Created by yolo on 2017/1/1.
//  Copyright © 2017年 Qiuncheng. All rights reserved.
//
//  仅仅是视图和扫描的作用
//

import UIKit
import AVFoundation

enum YLScanSetupResult {
    case successed
    case failed
    case unknown
}

class YLQRScanBaseViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    
    fileprivate var captureSession = AVCaptureSession()

    fileprivate var capturePreviewLayer: AVCaptureVideoPreviewLayer?
    fileprivate var deviceInput: AVCaptureDeviceInput?
    fileprivate var metadataOutput: AVCaptureMetadataOutput?
    var dimmingView: YLDimmingView!
    
    fileprivate var rectOfInteres = CGRect.zero
    
    fileprivate var sessionQueue = DispatchQueue(label: "tv.yoloyolo.qrcode.session.queue", attributes: [], target: nil)
    
    fileprivate var setupResult = YLScanSetupResult.successed
    
    /// 用于区分用户 **第一次push进来和present进入相册后进来**
    var isFirstPush = false
    
    fileprivate var activityView: UIActivityIndicatorView?
    
    var scanConfig: YLScanViewConfig!
    
    /// 扫码获取的结果，用String表示，需要重写，**监听didSet即可**
    var resultString: YLQRScanResult?

    override func viewDidLoad() {
        super.viewDidLoad()

        isFirstPush = true
        view.backgroundColor = UIColor.black
        
        func authorizationStatus() -> YLScanSetupResult {
            var setupResult = YLScanSetupResult.successed
            let authorizationStatus = AVCaptureDevice.authorizationStatus(forMediaType: AVMediaTypeVideo)
            switch authorizationStatus {
            case .authorized:
                setupResult = YLScanSetupResult.successed
            case .notDetermined:
                sessionQueue.suspend()
                AVCaptureDevice.requestAccess(forMediaType: AVMediaTypeVideo, completionHandler: { [weak self] (granted) in
                    if !granted {
                        setupResult = YLScanSetupResult.failed
                    }
                    self?.sessionQueue.resume()
                })
                break
            case .denied:
                setupResult = YLScanSetupResult.failed
                break
            default:
                setupResult = YLScanSetupResult.unknown
                break
            }
            return setupResult
        }
        
        setupResult = authorizationStatus()
        
        dimmingView = YLDimmingView(frame: view.bounds)
        scanConfig = dimmingView.config
        
        let viewWidth = view.frame.width
        let viewHeight = view.frame.height
        
        rectOfInteres = CGRect(x: ((viewHeight - scanConfig.scanRectWidthHeight) * 0.5 - scanConfig.contentOffsetUp + 64.0) / viewHeight,
                               y: (viewWidth - scanConfig.scanRectWidthHeight) * 0.5 / viewWidth,
                               width: scanConfig.scanRectWidthHeight / viewHeight,
                               height: scanConfig.scanRectWidthHeight / viewWidth)
        
        activityView = UIActivityIndicatorView(activityIndicatorStyle: .whiteLarge)
        activityView?.tintColor = UIColor.black
        activityView?.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        activityView?.center = CGPoint(x: UIScreen.main.bounds.width * 0.5, y: scanConfig.scanRectWidthHeight * 0.5 + scanConfig.contentOffsetUp)
        activityView?.hidesWhenStopped = true
        view.addSubview(activityView!)
        activityView?.startAnimating()
        
        /// 在一个新的队列里进行初始化工作，还是**主线程**
        sessionQueue.sync { [weak self] in
            self?.configSession()
        }
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        dimmingView.removeFromSuperview()
        view.addSubview(dimmingView)
        startSesssion()
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSessionRunning()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if setupResult == .successed {
            captureSession.stopRunning()
        }
    }
    
    func startSesssion() {
        
        guard !captureSession.isRunning else  {
            return
        }
        sessionQueue.sync { [weak self] in
            guard let strongSelf = self else { return }
            switch strongSelf.setupResult {
            case .successed:
                if strongSelf.isFirstPush {
                    strongSelf.captureSession.startRunning()
                    strongSelf.dimmingView?.beginAnimation()
                }
                DispatchQueue.main.async {
                    strongSelf.activityView?.stopAnimating()
                    strongSelf.dimmingView?.beginAnimation()
                }
            default:
                strongSelf.activityView?.stopAnimating()
                let message = "没有权限获取相机"
                let	alertController = UIAlertController(title: "YLQRCode", message: message, preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: "好", style: .cancel, handler: nil))
                alertController.addAction(UIAlertAction(title: "设置", style: .`default`, handler: { action in
                    UIApplication.shared.openURL(URL(string: UIApplicationOpenSettingsURLString)!)
                }))
                strongSelf.present(alertController, animated: true, completion: nil)
            }
        }
    }
    
    func stopSessionRunning() {
        captureSession.stopRunning()
        dimmingView?.removeAnimations()
    }
    
    private func configSession() {
        
        if setupResult != .successed {
            return
        }
        
        /// setup session
        captureSession.beginConfiguration()
        
        do {
            var defaultVedioDevice: AVCaptureDevice?
            
            if #available(iOS 10.0, *) {
                if let backCameraDevice = AVCaptureDevice.defaultDevice(withDeviceType: AVCaptureDeviceType.builtInWideAngleCamera, mediaType: AVMediaTypeVideo, position: .back) {
                    defaultVedioDevice = backCameraDevice
                }
                else if let frontCameraDevice = AVCaptureDevice.defaultDevice(withDeviceType: AVCaptureDeviceType.builtInWideAngleCamera, mediaType: AVMediaTypeVideo, position: .front) {
                    defaultVedioDevice = frontCameraDevice
                }
            }
            else {
                if let cameraDevice = AVCaptureDevice.defaultDevice(withMediaType: AVMediaTypeVideo) {
                    defaultVedioDevice = cameraDevice
                }
            }
            let videoDeviceInput = try AVCaptureDeviceInput(device: defaultVedioDevice)
            
            /// 添加自动对焦功能，否则不容易读取二维码
            /// **添加了自动对焦，反而增大了模糊误差**
//            if videoDeviceInput.device.isAutoFocusRangeRestrictionSupported
//                && videoDeviceInput.device.isSmoothAutoFocusSupported {
//                try videoDeviceInput.device.lockForConfiguration()
//                videoDeviceInput.device.focusMode = .autoFocus
//                videoDeviceInput.device.unlockForConfiguration()
//            }
            
            if captureSession.canAddInput(videoDeviceInput) {
                captureSession.addInput(videoDeviceInput)
            }
            self.deviceInput = videoDeviceInput
        }
        catch {
            print("无法添加input.")
            setupResult = .failed
        }
        metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
        }
        else {
            setupResult = .failed
            return
        }
        metadataOutput?.setMetadataObjectsDelegate(self, queue: self.sessionQueue)
        metadataOutput?.metadataObjectTypes = metadataOutput?.availableMetadataObjectTypes
        metadataOutput?.rectOfInterest = self.rectOfInteres
        
        captureSession.commitConfiguration()
        
        capturePreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        capturePreviewLayer?.frame = view.bounds
        view.layer.insertSublayer(capturePreviewLayer!, at: 0)
    }
    
    func captureOutput(_ captureOutput: AVCaptureOutput!, didOutputMetadataObjects metadataObjects: [Any]!, from connection: AVCaptureConnection!) {
        
        for _supportedBarcode in metadataObjects {
           
            guard let supportedBarcode = _supportedBarcode as? AVMetadataObject else { return }
            
            if supportedBarcode.type == AVMetadataObjectTypeQRCode {
                guard let barcodeObject = self.capturePreviewLayer?.transformedMetadataObject(for: supportedBarcode) as? AVMetadataMachineReadableCodeObject else { return }
                DispatchQueue.safeMainQueue { [weak self] in
                    self?.resultString = barcodeObject.stringValue
                    self?.stopSessionRunning()
                    YLQRScanCommon.playSound()
                    self?.dimmingView?.removeAnimations()
                }
            }
        }
    }
}