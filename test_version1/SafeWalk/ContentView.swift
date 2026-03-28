// ContentView.swift v5
// SafeWalk - 시각장애인 보행 보조 시스템
// 추가: 주차 차량 vs 주행 차량 판별 (중심 이동량 + LiDAR 거리 패턴 + 화면 위치)

import SwiftUI
import AVFoundation
import Vision
import CoreML
import Combine
import ARKit

// MARK: - 메인 화면
struct ContentView: View {
    @StateObject private var detector = ObjectDetector()
    
    var body: some View {
        ZStack {
            ARCameraPreview(session: detector.arSession)
                .ignoresSafeArea()
            
            ForEach(detector.detections) { detection in
                BoundingBoxView(detection: detection)
            }
            
            VStack(spacing: 0) {
                Text(detector.statusMessage)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .padding(.top, 55)
                
                if let alert = detector.currentAlert {
                    AlertBanner(message: alert.message, level: alert.level)
                        .padding(.top, 8)
                }
                
                Spacer()
                
                HStack {
                    Text("\(String(format: "%.0f", detector.fps)) FPS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                    
                    if detector.isLidarAvailable {
                        Text("LiDAR ON")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    Button(action: { detector.isSpeechEnabled.toggle() }) {
                        Image(systemName: detector.isSpeechEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 20))
                            .padding(10)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            detector.start()
        }
    }
}

// MARK: - 경고 배너
struct AlertBanner: View {
    let message: String
    let level: AlertLevel
    
    var backgroundColor: Color {
        switch level {
        case .info: return Color.blue.opacity(0.85)
        case .warning: return Color.orange.opacity(0.85)
        case .danger: return Color.red.opacity(0.9)
        }
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: level == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 22))
            Text(message)
                .font(.system(size: 17, weight: .bold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(backgroundColor)
        .cornerRadius(12)
        .padding(.horizontal, 12)
    }
}

// MARK: - 바운딩 박스
struct BoundingBoxView: View {
    let detection: Detection
    
    var boxColor: Color {
        if detection.isParked { return .gray }
        if detection.ttc < 1.5 { return .red }
        if detection.ttc < 3.0 { return .orange }
        if detection.approachStatus == .approaching { return .yellow }
        return .green
    }
    
    var body: some View {
        GeometryReader { geo in
            let r = CGRect(
                x: detection.boundingBox.minX * geo.size.width,
                y: detection.boundingBox.minY * geo.size.height,
                width: detection.boundingBox.width * geo.size.width,
                height: detection.boundingBox.height * geo.size.height
            )
            
            Rectangle()
                .stroke(boxColor, lineWidth: 3)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
            
            VStack(spacing: 2) {
                Text(detection.displayLabel)
                    .font(.system(size: 13, weight: .bold))
                if detection.distanceText != "" {
                    Text(detection.distanceText)
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(boxColor.opacity(0.85))
            .cornerRadius(6)
            .position(x: r.midX, y: max(r.minY - 20, 20))
        }
    }
}

// MARK: - AR 카메라 프리뷰
struct ARCameraPreview: UIViewRepresentable {
    let session: ARSession
    
    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = session
        arView.automaticallyUpdatesLighting = false
        arView.scene = SCNScene()
        return arView
    }
    
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - 데이터 모델
enum AlertLevel {
    case info, warning, danger
}

enum ApproachStatus {
    case approaching, receding, stationary, newlyDetected
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let message: String
    let level: AlertLevel
}

struct Detection: Identifiable {
    let id = UUID()
    let label: String
    let confidence: Float
    let boundingBox: CGRect
    let direction: String
    let approachStatus: ApproachStatus
    let distance: Float
    let ttc: Double
    let trackID: Int
    let isParked: Bool          // 주차 차량 여부
    
    var displayLabel: String {
        if isParked { return "\(label) [주차]" }
        if approachStatus == .approaching { return "\(label) 접근중" }
        return label
    }
    
    var distanceText: String {
        if distance > 0 && distance < 100 {
            return String(format: "%.1fm", distance)
        }
        return ""
    }
}

// MARK: - 트래킹 데이터
struct TrackedObject {
    var lastSize: CGFloat
    var lastCenterX: CGFloat
    var lastCenterY: CGFloat
    var sizeHistory: [CGFloat]
    var centerXHistory: [CGFloat]       // 중심 X 이동 기록
    var distanceHistory: [Float]        // LiDAR 거리 기록
    var lastSeen: Int
    var distance: Float
    var approachCount: Int
    var recedingCount: Int
    
    // 면적 변화율
    var sizeChangeRate: CGFloat {
        guard sizeHistory.count >= 5 else { return 0 }
        let recent = Array(sizeHistory.suffix(8))
        let first = recent.first!
        let last = recent.last!
        guard first > 0.001 else { return 0 }
        return (last - first) / first / CGFloat(recent.count)
    }
    
    // 중심 X 이동량 (프레임당 평균)
    var centerXMovement: CGFloat {
        guard centerXHistory.count >= 3 else { return 0 }
        let recent = Array(centerXHistory.suffix(8))
        var totalMovement: CGFloat = 0
        for i in 1..<recent.count {
            totalMovement += abs(recent[i] - recent[i-1])
        }
        return totalMovement / CGFloat(recent.count - 1)
    }
    
    // LiDAR 거리 패턴: 계속 감소 중인지 확인
    var isDistanceDecreasing: Bool {
        guard distanceHistory.count >= 3 else { return false }
        let recent = Array(distanceHistory.suffix(5))
        // 모든 연속 쌍에서 감소하는지 확인
        var decreasingCount = 0
        for i in 1..<recent.count {
            if recent[i] < recent[i-1] {
                decreasingCount += 1
            }
        }
        // 80% 이상이 감소 추세면 true
        return Float(decreasingCount) / Float(recent.count - 1) > 0.7
    }
    
    // 주차 차량 판별
    var isLikelyParked: Bool {
        let sizeGrowing = sizeChangeRate > 0.02
        let centerMovingALot = centerXMovement > 0.03  // 프레임당 3% 이상 이동
        let notInCenter = lastCenterX < 0.2 || lastCenterX > 0.8  // 화면 가장자리
        
        // 면적은 커지지만 중심이 크게 이동 → 주차 차량
        if sizeGrowing && centerMovingALot {
            return true
        }
        
        // LiDAR 거리가 감소 후 증가 패턴 → 주차 차량
        if distanceHistory.count >= 4 {
            let recent = Array(distanceHistory.suffix(4))
            let firstHalf = (recent[0] + recent[1]) / 2
            let secondHalf = (recent[2] + recent[3]) / 2
            // 거리 변화가 아주 작으면 (1m 이내) 주차 차량일 가능성
            if abs(firstHalf - secondHalf) < 0.5 && sizeGrowing && centerMovingALot {
                return true
            }
        }
        
        // 화면 가장자리에 있으면서 면적 커짐 → 옆을 지나가는 중
        if notInCenter && sizeGrowing && centerMovingALot {
            return true
        }
        
        return false
    }
}

// MARK: - 객체 탐지 엔진
class ObjectDetector: NSObject, ObservableObject, ARSessionDelegate {
    @Published var detections: [Detection] = []
    @Published var currentAlert: AlertMessage?
    @Published var fps: Double = 0
    @Published var isSpeechEnabled: Bool = true
    @Published var statusMessage: String = "초기화 중..."
    @Published var isLidarAvailable: Bool = false
    
    let arSession = ARSession()
    private var visionModel: VNCoreMLModel?
    private var lastFrameTime = Date()
    private var frameCount: Int = 0
    
    private var trackedObjects: [String: TrackedObject] = [:]
    
    private var currentDepthMap: CVPixelBuffer?
    private var depthWidth: Int = 0
    private var depthHeight: Int = 0
    
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpeechTime = Date()
    
    private let realHeights: [String: Float] = [
        "person": 1.7, "bicycle": 1.0, "car": 1.5,
        "motorcycle": 1.1, "bus": 3.2, "truck": 3.5
    ]
    
    private let koreanLabels: [String: String] = [
        "person": "사람", "bicycle": "자전거", "car": "자동차",
        "motorcycle": "오토바이", "bus": "버스", "truck": "트럭",
        "traffic light": "신호등"
    ]
    
    // 차량 클래스 목록 (주차 판별 대상)
    private let vehicleClasses: Set<String> = ["car", "bus", "truck", "motorcycle"]
    
    override init() {
        super.init()
        isLidarAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        setupModel()
    }
    
    private func setupModel() {
        if let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") {
            loadModel(from: url)
            return
        }
        if let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage") {
            if let compiled = try? MLModel.compileModel(at: url) {
                loadModel(from: compiled)
                return
            }
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let m = try yolov8n(configuration: config).model
            visionModel = try VNCoreMLModel(for: m)
            DispatchQueue.main.async { self.statusMessage = "모델 로드 성공" }
        } catch {
            DispatchQueue.main.async { self.statusMessage = "모델 로드 실패" }
        }
    }
    
    private func loadModel(from url: URL) {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let m = try MLModel(contentsOf: url, configuration: config)
            visionModel = try VNCoreMLModel(for: m)
            DispatchQueue.main.async { self.statusMessage = "모델 로드 성공" }
        } catch {
            DispatchQueue.main.async { self.statusMessage = "모델 로드 실패: \(error.localizedDescription)" }
        }
    }
    
    func start() {
        arSession.delegate = self
        let config = ARWorldTrackingConfiguration()
        if isLidarAvailable {
            config.frameSemantics.insert(.sceneDepth)
        }
        arSession.run(config)
        DispatchQueue.main.async {
            self.statusMessage = self.visionModel != nil
                ? "탐지 시작 (LiDAR: \(self.isLidarAvailable ? "ON" : "OFF"))"
                : "모델 없음"
        }
    }
    
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard visionModel != nil else { return }
        
        frameCount += 1
        
        if let depth = frame.sceneDepth?.depthMap {
            currentDepthMap = depth
            depthWidth = CVPixelBufferGetWidth(depth)
            depthHeight = CVPixelBufferGetHeight(depth)
        }
        
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        
        runDetection(on: frame.capturedImage, fps: 1.0 / elapsed)
    }
    
    private func runDetection(on pixelBuffer: CVPixelBuffer, fps: Double) {
        guard let model = visionModel else { return }
        
        let request = VNCoreMLRequest(model: model) { [weak self] req, err in
            guard let self = self,
                  let results = req.results as? [VNRecognizedObjectObservation] else { return }
            self.processResults(results, fps: fps)
        }
        request.imageCropAndScaleOption = .scaleFill
        
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:]).perform([request])
    }
    
    private func processResults(_ results: [VNRecognizedObjectObservation], fps: Double) {
        var newDetections: [Detection] = []
        var highestDanger: (String, String, AlertLevel, Double, String)? = nil
        
        for obs in results {
            guard let top = obs.labels.first, top.confidence > 0.5 else { continue }
            let engName = top.identifier
            guard let korName = koreanLabels[engName] else { continue }
            
            let box = obs.boundingBox
            let screenBox = CGRect(
                x: box.minX,
                y: 1 - box.maxY,
                width: box.width,
                height: box.height
            )
            
            let centerX = box.midX
            let direction: String
            let avoidDirection: String
            if centerX < 0.33 {
                direction = "왼쪽"
                avoidDirection = "오른쪽"
            } else if centerX < 0.66 {
                direction = "정면"
                avoidDirection = "오른쪽"
            } else {
                direction = "오른쪽"
                avoidDirection = "왼쪽"
            }
            
            // --- 거리 측정 ---
            var distance: Float = -1
            let currentSize = box.width * box.height
            
            // LiDAR
            if let depth = currentDepthMap, depthWidth > 0 {
                let dx = Int(box.midX * CGFloat(depthWidth))
                let dy = Int(box.midY * CGFloat(depthHeight))
                let cx = min(max(dx, 0), depthWidth - 1)
                let cy = min(max(dy, 0), depthHeight - 1)
                
                CVPixelBufferLockBaseAddress(depth, .readOnly)
                if let base = CVPixelBufferGetBaseAddress(depth) {
                    let bpr = CVPixelBufferGetBytesPerRow(depth)
                    let ptr = base.advanced(by: cy * bpr + cx * MemoryLayout<Float32>.size)
                    let val = ptr.assumingMemoryBound(to: Float32.self).pointee
                    if val > 0.1 && val < 20.0 {
                        distance = val
                    }
                }
                CVPixelBufferUnlockBaseAddress(depth, .readOnly)
            }
            
            // 역산 추정
            if distance < 0, let realH = realHeights[engName] {
                let boxRatio = Float(box.height)
                if boxRatio > 0.02 {
                    distance = realH / boxRatio * 0.55
                    distance = min(distance, 50)
                }
            }
            
            // --- 트래킹 ---
            let trackKey = "\(engName)_\(Int(centerX * 3))_\(Int(box.midY * 3))"
            
            let approachStatus: ApproachStatus
            var ttc: Double = 999
            var isParked = false
            
            if var tracked = trackedObjects[trackKey] {
                // 히스토리 업데이트
                tracked.sizeHistory.append(currentSize)
                if tracked.sizeHistory.count > 15 { tracked.sizeHistory.removeFirst() }
                
                tracked.centerXHistory.append(centerX)
                if tracked.centerXHistory.count > 15 { tracked.centerXHistory.removeFirst() }
                
                if distance > 0 {
                    tracked.distanceHistory.append(distance)
                    if tracked.distanceHistory.count > 10 { tracked.distanceHistory.removeFirst() }
                    tracked.distance = distance
                }
                
                tracked.lastSize = currentSize
                tracked.lastCenterX = centerX
                tracked.lastCenterY = box.midY
                tracked.lastSeen = frameCount
                
                let changeRate = tracked.sizeChangeRate
                
                // --- 주차 차량 판별 (차량 클래스만) ---
                if vehicleClasses.contains(engName) {
                    isParked = tracked.isLikelyParked
                }
                
                // 주차 차량이면 접근 판정 하지 않음
                if isParked {
                    approachStatus = .stationary
                    tracked.approachCount = 0
                } else {
                    if changeRate > 0.03 {
                        tracked.approachCount += 1
                        tracked.recedingCount = 0
                    } else if changeRate < -0.03 {
                        tracked.recedingCount += 1
                        tracked.approachCount = 0
                    } else {
                        tracked.approachCount = max(0, tracked.approachCount - 1)
                        tracked.recedingCount = max(0, tracked.recedingCount - 1)
                    }
                    
                    if tracked.approachCount >= 3 {
                        approachStatus = .approaching
                        
                        // TTC 계산
                        let dangerSize: CGFloat = 0.25
                        if currentSize < dangerSize && changeRate > 0 {
                            let framesToDanger = (dangerSize - currentSize) / (changeRate * max(currentSize, 0.001))
                            ttc = Double(framesToDanger) / max(fps, 1)
                            ttc = max(0, min(ttc, 30))
                        }
                    } else if tracked.recedingCount >= 3 {
                        approachStatus = .receding
                    } else {
                        approachStatus = .stationary
                    }
                }
                
                trackedObjects[trackKey] = tracked
            } else {
                approachStatus = .newlyDetected
                trackedObjects[trackKey] = TrackedObject(
                    lastSize: currentSize,
                    lastCenterX: centerX,
                    lastCenterY: box.midY,
                    sizeHistory: [currentSize],
                    centerXHistory: [centerX],
                    distanceHistory: distance > 0 ? [distance] : [],
                    lastSeen: frameCount,
                    distance: distance,
                    approachCount: 0,
                    recedingCount: 0
                )
            }
            
            let detection = Detection(
                label: korName,
                confidence: top.confidence,
                boundingBox: screenBox,
                direction: direction,
                approachStatus: approachStatus,
                distance: distance,
                ttc: ttc,
                trackID: trackKey.hashValue,
                isParked: isParked
            )
            newDetections.append(detection)
            
            // --- 위험도 판단 (주차 차량은 제외) ---
            if approachStatus == .approaching && !isParked {
                let level: AlertLevel
                if ttc < 1.5 {
                    level = .danger
                } else if ttc < 3.0 {
                    level = .warning
                } else {
                    level = .info
                }
                
                if let current = highestDanger {
                    if ttc < current.3 {
                        highestDanger = (korName, direction, level, ttc, avoidDirection)
                    }
                } else {
                    highestDanger = (korName, direction, level, ttc, avoidDirection)
                }
            }
        }
        
        // 오래된 트래킹 제거
        trackedObjects = trackedObjects.filter { frameCount - $0.value.lastSeen < 15 }
        
        DispatchQueue.main.async {
            self.detections = newDetections
            self.fps = fps
            
            let parkedCount = newDetections.filter { $0.isParked }.count
            let activeCount = newDetections.count - parkedCount
            self.statusMessage = "탐지 \(newDetections.count)개 (활성 \(activeCount) / 주차 \(parkedCount)) LiDAR:\(self.isLidarAvailable ? "ON" : "OFF")"
            
            if let danger = highestDanger {
                let distInfo = newDetections.first { $0.label == danger.0 && $0.direction == danger.1 }
                let distText = distInfo != nil && distInfo!.distance > 0
                    ? String(format: " %.1fm", distInfo!.distance) : ""
                
                let message: String
                switch danger.2 {
                case .danger:
                    message = "\(danger.1)\(distText) \(danger.0) 급접근! \(danger.4)으로 피하세요!"
                case .warning:
                    message = "\(danger.1)\(distText) \(danger.0) 접근중, 주의"
                case .info:
                    message = "\(danger.1)에서 \(danger.0) 접근중"
                }
                
                self.currentAlert = AlertMessage(message: message, level: danger.2)
                
                if self.isSpeechEnabled {
                    self.speak(message, level: danger.2)
                }
                self.triggerHaptic(level: danger.2)
            } else {
                self.currentAlert = nil
            }
        }
    }
    
    private func speak(_ text: String, level: AlertLevel) {
        let now = Date()
        let cooldown: TimeInterval = level == .danger ? 1.0 : 2.5
        guard now.timeIntervalSince(lastSpeechTime) > cooldown else { return }
        
        if synthesizer.isSpeaking {
            if level == .danger {
                synthesizer.stopSpeaking(at: .immediate)
            } else {
                return
            }
        }
        
        lastSpeechTime = now
        
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = level == .danger ? 0.6 : 0.52
        utterance.volume = 1.0
        
        synthesizer.speak(utterance)
    }
    
    private func triggerHaptic(level: AlertLevel) {
        switch level {
        case .danger:
            let g = UINotificationFeedbackGenerator()
            g.notificationOccurred(.error)
        case .warning:
            let g = UINotificationFeedbackGenerator()
            g.notificationOccurred(.warning)
        case .info:
            let g = UIImpactFeedbackGenerator(style: .light)
            g.impactOccurred()
        }
    }
}

#Preview {
    ContentView()
}
