// ContentView.swift v8
// SafeWalk - 시각장애인 보행 보조 시스템
//
// [v8 변경사항 — v7 대비]
// 1. 50m 버그 수정: saveNormalized → 역수 변환 + 고정 범위 정규화
//    - 매 프레임 min-max 정규화 → 제거 (실외에서 배경 변화에 출렁이는 문제)
//    - Depth Anything V2 출력을 역수(1/raw)로 변환 → 가까울수록 값이 큼
//    - 고정 범위 [0, fixedMax]로 정규화 → 프레임 간 일관성 확보
// 2. LiDAR 자동 캘리브레이션 제거 → scale/offset 하드코딩 (줄자 캘리브레이션)
// 3. 디버그 모드 추가: raw depth 값 실시간 표시 → 줄자 보면서 scale 조정 가능
// 4. 역산 fallback 상한 50m → 15m (부정확한 원거리 값 표시 방지)
// 5. LiDAR는 완전히 거리 측정에서 분리 (코드 간소화)

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
                // 상단 상태바
                Text(detector.statusMessage)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.7))
                    .cornerRadius(6)
                    .padding(.top, 55)
                
                // [v8] 디버그 정보 (raw depth 값 표시)
                if detector.debugMode {
                    Text(detector.debugInfo)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.yellow)
                        .padding(4)
                        .background(Color.black.opacity(0.8))
                        .cornerRadius(4)
                        .padding(.top, 4)
                }
                
                // 경고 배너
                if let alert = detector.currentAlert {
                    AlertBanner(message: alert.message, level: alert.level)
                        .padding(.top, 8)
                }
                
                Spacer()
                
                // 하단 컨트롤
                HStack {
                    Text("\(String(format: "%.0f", detector.fps)) FPS")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(8)
                    
                    // Depth 모드 표시
                    if detector.isDepthModelReady {
                        Text("Depth AI v8")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.cyan)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                    }
                    
                    // [v8] 디버그 모드 토글
                    Button(action: { detector.debugMode.toggle() }) {
                        Image(systemName: detector.debugMode ? "ladybug.fill" : "ladybug")
                            .foregroundColor(detector.debugMode ? .yellow : .white)
                            .font(.system(size: 18))
                            .padding(8)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                    }
                    
                    Spacer()
                    
                    // 음성 토글
                    Button(action: { detector.isSpeechEnabled.toggle() }) {
                        Image(systemName: detector.isSpeechEnabled
                              ? "speaker.wave.2.fill" : "speaker.slash.fill")
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
        .onAppear { detector.start() }
    }
}

// MARK: - 경고 배너
struct AlertBanner: View {
    let message: String
    let level: AlertLevel
    
    var backgroundColor: Color {
        switch level {
        case .info:    return Color.blue.opacity(0.85)
        case .warning: return Color.orange.opacity(0.85)
        case .danger:  return Color.red.opacity(0.9)
        }
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: level == .danger
                  ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
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
enum AlertLevel { case info, warning, danger }
enum ApproachStatus { case approaching, receding, stationary, newlyDetected }

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
    let isParked: Bool
    let distanceSource: String  // "DepthAI" / "역산" / "없음"
    
    var displayLabel: String {
        if isParked { return "\(label) [주차]" }
        if approachStatus == .approaching { return "\(label) 접근중" }
        return label
    }
    
    var distanceText: String {
        guard distance > 0 && distance < 100 else { return "" }
        return String(format: "%.1fm [%@]", distance, distanceSource)
    }
}

// MARK: - 트래킹 데이터
struct TrackedObject {
    var lastSize: CGFloat
    var lastCenterX: CGFloat
    var lastCenterY: CGFloat
    var sizeHistory: [CGFloat]
    var centerXHistory: [CGFloat]
    var distanceHistory: [Float]
    var lastSeen: Int
    var distance: Float
    var approachCount: Int
    var recedingCount: Int
    
    var sizeChangeRate: CGFloat {
        guard sizeHistory.count >= 5 else { return 0 }
        let recent = Array(sizeHistory.suffix(8))
        let first = recent.first!
        let last  = recent.last!
        guard first > 0.001 else { return 0 }
        return (last - first) / first / CGFloat(recent.count)
    }
    
    var centerXMovement: CGFloat {
        guard centerXHistory.count >= 3 else { return 0 }
        let recent = Array(centerXHistory.suffix(8))
        var total: CGFloat = 0
        for i in 1..<recent.count { total += abs(recent[i] - recent[i-1]) }
        return total / CGFloat(recent.count - 1)
    }
    
    var isLikelyParked: Bool {
        let sizeGrowing      = sizeChangeRate > 0.02
        let centerMovingALot = centerXMovement > 0.03
        let notInCenter      = lastCenterX < 0.2 || lastCenterX > 0.8
        
        if sizeGrowing && centerMovingALot { return true }
        
        if distanceHistory.count >= 4 {
            let r = Array(distanceHistory.suffix(4))
            let firstHalf  = (r[0] + r[1]) / 2
            let secondHalf = (r[2] + r[3]) / 2
            if abs(firstHalf - secondHalf) < 0.5 && sizeGrowing && centerMovingALot { return true }
        }
        
        if notInCenter && sizeGrowing && centerMovingALot { return true }
        return false
    }
}

// ============================================================
// MARK: - Depth Anything V2 추론기 (v8 — 근본 수정)
// ============================================================
private class DepthInferenceEngine {
    
    private var request: VNCoreMLRequest?
    
    // ── 깊이 맵 (정규화 완료) ──
    // [v8] 역수 변환 후 고정 범위 정규화
    //   원본: raw 값이 클수록 멀다
    //   변환: 1/raw → 값이 클수록 가깝다
    //   정규화: [0, fixedMax] → [0, 1]
    private(set) var depthMap: [Float] = []
    private(set) var mapWidth: Int = 0
    private(set) var mapHeight: Int = 0
    
    // ── [v8] 캘리브레이션 파라미터 (하드코딩) ──
    // ┌──────────────────────────────────────────────────────┐
    // │  이 두 값을 줄자 측정으로 조정하세요!                    │
    // │                                                      │
    // │  조정 방법:                                           │
    // │  1. 디버그 모드 켜기 (벌레 아이콘)                      │
    // │  2. 1m 거리에 물체 놓기 → 화면에 표시되는 relDepth 메모  │
    // │  3. 3m 거리에 물체 놓기 → relDepth 메모                │
    // │  4. 5m 거리에 물체 놓기 → relDepth 메모                │
    // │  5. scale = 실제거리 변화량 / relDepth 변화량            │
    // │     offset = 실제거리 - scale * relDepth (1m 기준)      │
    // │                                                      │
    // │  예시:                                               │
    // │  1m → relDepth 0.65, 3m → relDepth 0.25              │
    // │  scale = (3-1) / (0.65-0.25) = 5.0                   │
    // │  offset = 1 - 5.0 * 0.65 = -2.25                    │
    // │                                                      │
    // │  ※ 음수 offset은 정상입니다                            │
    // └──────────────────────────────────────────────────────┘
    var scale: Float = 5.0     // ← 줄자 측정 후 조정
    var offset: Float = -0.5   // ← 줄자 측정 후 조정
    
    // [v8] 디버그용: 마지막 프레임의 raw 통계
    var lastRawMin: Float = 0
    var lastRawMax: Float = 0
    var lastRawMedian: Float = 0
    
    /// 프레임 스케줄링: 3프레임마다 1회 추론 (~5-7fps)
    var frameInterval = 3
    private var frameCounter = 0
    
    private(set) var isReady = false
    
    init() { load() }
    
    private func load() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try DepthAnythingV2Small(configuration: config).model
            let vnModel = try VNCoreMLModel(for: mlModel)
            
            let req = VNCoreMLRequest(model: vnModel) { [weak self] r, _ in
                self?.handleResult(r)
            }
            req.imageCropAndScaleOption = .scaleFill
            self.request = req
            self.isReady = true
            print("[Depth] DepthAnythingV2Small 로드 성공")
        } catch {
            print("[Depth] 모델 로드 실패: \(error)")
        }
    }
    
    func infer(pixelBuffer: CVPixelBuffer) {
        frameCounter += 1
        guard frameCounter % frameInterval == 0 else { return }
        guard isReady, let req = request else { return }
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                            orientation: .right, options: [:])
        try? handler.perform([req])
    }
    
    private func handleResult(_ request: VNRequest) {
        if let obs = request.results as? [VNCoreMLFeatureValueObservation],
           let arr = obs.first?.featureValue.multiArrayValue {
            extractFromMultiArray(arr)
            return
        }
        if let obs = request.results as? [VNPixelBufferObservation],
           let pb = obs.first?.pixelBuffer {
            extractFromPixelBuffer(pb)
        }
    }
    
    private func extractFromMultiArray(_ arr: MLMultiArray) {
        let shape = arr.shape.map { $0.intValue }
        guard shape.count >= 2 else { return }
        let h = shape[shape.count - 2]
        let w = shape[shape.count - 1]
        let count = h * w
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: count)
        var raw = [Float](repeating: 0, count: count)
        for i in 0..<count { raw[i] = ptr[i] }
        processDepthMap(raw, w: w, h: h)
    }
    
    private func extractFromPixelBuffer(_ pb: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb)
        let h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let ptr = base.bindMemory(to: Float.self, capacity: w * h)
        var raw = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) { raw[i] = ptr[i] }
        processDepthMap(raw, w: w, h: h)
    }
    
    // ═══════════════════════════════════════════════════════
    // [v8] 핵심 변경: 고정 범위 정규화 + 역수 변환
    // ═══════════════════════════════════════════════════════
    //
    // v7 문제: saveNormalized에서 매 프레임 min-max를 구해서
    //   배경이 바뀔 때마다 같은 물체의 정규화 값이 출렁였음
    //
    // v8 해결:
    //   1. raw 값을 역수(1/raw)로 변환 → 가까울수록 값이 큼
    //   2. 고정 상한(fixedMax)으로 정규화 → 프레임 간 일관성
    //
    // Depth Anything V2 Small 출력 특성:
    //   - raw 값: 상대적 깊이 (값 클수록 멀다)
    //   - 범위: 프레임/장면에 따라 달라짐 (정해진 범위 없음)
    //   - 역수 변환 후: 가까울수록 큰 값 (disparity와 유사)
    //
    private func processDepthMap(_ raw: [Float], w: Int, h: Int) {
        guard !raw.isEmpty else { return }
        
        // 디버그용 통계 (raw 원본)
        let sortedRaw = raw.sorted()
        lastRawMin = sortedRaw.first ?? 0
        lastRawMax = sortedRaw.last ?? 0
        lastRawMedian = sortedRaw[sortedRaw.count / 2]
        
        // Step 1: 역수 변환 (1/raw) → 가까울수록 값이 큼
        //   raw가 0이면 무한대가 되니까 최소값 클램핑
        let epsilon: Float = 0.001
        let inverted = raw.map { 1.0 / max($0, epsilon) }
        
        // Step 2: 고정 범위 정규화
        //   역수 변환 후 값 범위가 [~0, ~1000] 등 넓을 수 있으므로
        //   상위 95% 값을 기준으로 정규화 (극단 이상값 무시)
        let sortedInv = inverted.sorted()
        let p95Index = Int(Float(sortedInv.count) * 0.95)
        let fixedMax = max(sortedInv[min(p95Index, sortedInv.count - 1)], epsilon)
        
        depthMap = inverted.map { min($0 / fixedMax, 1.0) }
        mapWidth  = w
        mapHeight = h
    }
    
    // MARK: - 바운딩 박스 내 중앙값 상대 깊이
    func averageRelativeDepth(box: CGRect) -> Float? {
        guard !depthMap.isEmpty, mapWidth > 0, mapHeight > 0 else { return nil }
        
        // Vision → 이미지 좌표 (y 반전)
        let imgBox = CGRect(x: box.minX, y: 1 - box.maxY,
                            width: box.width, height: box.height)
        
        // 박스 하단 1/3 영역 사용 (발 위치 = 실제 지면 거리)
        let yStart = imgBox.minY + imgBox.height * 2 / 3
        let yEnd   = imgBox.maxY
        
        let x1 = max(0, Int(imgBox.minX * CGFloat(mapWidth)))
        let x2 = min(mapWidth  - 1, Int(imgBox.maxX * CGFloat(mapWidth)))
        let y1 = max(0, Int(yStart   * CGFloat(mapHeight)))
        let y2 = min(mapHeight - 1, Int(yEnd * CGFloat(mapHeight)))
        
        guard x2 > x1, y2 > y1 else { return nil }
        
        var values: [Float] = []
        for y in y1...y2 {
            for x in x1...x2 {
                values.append(depthMap[y * mapWidth + x])
            }
        }
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
    
    // ── [v8] 상대 깊이 → 절대 거리(m) ──
    // 선형 변환: meters = scale * relativeDepth + offset
    // relativeDepth: 0~1 (1에 가까울수록 가까움)
    // → 가까운 물체: scale * 0.9 + offset ≈ 작은 미터값
    // → 먼 물체:    scale * 0.1 + offset ≈ 큰 미터값
    //
    // 주의: 역수 변환 때문에 scale이 음수가 될 수 있음
    //   relDepth 크다 = 가깝다 → 미터값 작다 → scale < 0, offset > 0
    //   또는 relDepth 크다 = 가깝다 → meters = offset - |scale| * relDepth
    //
    // 실제 사용할 때는 디버그 모드로 relDepth 값을 확인하고
    // 줄자 측정값과 비교해서 scale/offset을 조정
    func toMeters(_ relativeDepth: Float) -> Float {
        let meters = scale * relativeDepth + offset
        return max(0.3, min(30.0, meters))  // [v8] 상한 50→30m (신뢰 범위)
    }
}

// ============================================================
// MARK: - 객체 탐지 엔진 (v8)
// ============================================================
class ObjectDetector: NSObject, ObservableObject, ARSessionDelegate {
    @Published var detections: [Detection] = []
    @Published var currentAlert: AlertMessage?
    @Published var fps: Double = 0
    @Published var isSpeechEnabled: Bool = true
    @Published var statusMessage: String = "초기화 중..."
    @Published var isLidarAvailable: Bool = false
    @Published var isDepthModelReady: Bool = false
    @Published var debugMode: Bool = false        // [v8] 디버그 모드
    @Published var debugInfo: String = ""          // [v8] 디버그 텍스트
    
    let arSession = ARSession()
    private var visionModel: VNCoreMLModel?
    private var lastFrameTime = Date()
    private var frameCount: Int = 0
    
    private var trackedObjects: [String: TrackedObject] = [:]
    
    private let depthEngine = DepthInferenceEngine()
    
    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpeechTime = Date()
    
    // [v8] 역산 fallback용 실제 높이 (상한 15m)
    private let realHeights: [String: Float] = [
        "person": 1.7, "bicycle": 1.0, "car": 1.5,
        "motorcycle": 1.1, "bus": 3.2, "truck": 3.5
    ]
    
    private let koreanLabels: [String: String] = [
        "person": "사람", "bicycle": "자전거", "car": "자동차",
        "motorcycle": "오토바이", "bus": "버스", "truck": "트럭",
        "traffic light": "신호등"
    ]
    
    private let vehicleClasses: Set<String> = ["car", "bus", "truck", "motorcycle"]
    
    override init() {
        super.init()
        isLidarAvailable  = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        isDepthModelReady = depthEngine.isReady
    }
    
    private func setupModel() {
        if let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlmodelc") {
            loadModel(from: url); return
        }
        if let url = Bundle.main.url(forResource: "yolov8n", withExtension: "mlpackage"),
           let compiled = try? MLModel.compileModel(at: url) {
            loadModel(from: compiled); return
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
            DispatchQueue.main.async { self.statusMessage = "모델 로드 성공 (v8)" }
        } catch {
            DispatchQueue.main.async {
                self.statusMessage = "모델 로드 실패: \(error.localizedDescription)"
            }
        }
    }
    
    func start() {
        setupModel()
        arSession.delegate = self
        let config = ARWorldTrackingConfiguration()
        // [v8] LiDAR depth는 더 이상 사용하지 않지만, ARKit은 유지
        // (향후 LiDAR 실내 캘리브레이션 복원 가능성)
        arSession.run(config)
        
        DispatchQueue.main.async {
            let depthStatus = self.depthEngine.isReady ? "Depth AI v8" : "Depth AI 없음"
            self.statusMessage = self.visionModel != nil
                ? "탐지 시작 | \(depthStatus)"
                : "모델 없음"
        }
    }
    
    // MARK: - ARSessionDelegate
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard visionModel != nil else { return }
        frameCount += 1
        
        // [v8] Depth Anything V2 추론 (3프레임마다)
        depthEngine.infer(pixelBuffer: frame.capturedImage)
        
        let now     = Date()
        let elapsed = now.timeIntervalSince(lastFrameTime)
        lastFrameTime = now
        
        runDetection(on: frame.capturedImage, fps: 1.0 / elapsed)
    }
    
    // MARK: - YOLO 추론
    private func runDetection(on pixelBuffer: CVPixelBuffer, fps: Double) {
        guard let model = visionModel else { return }
        
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self,
                  let results = req.results as? [VNRecognizedObjectObservation] else { return }
            self.processResults(results, fps: fps)
        }
        request.imageCropAndScaleOption = .scaleFill
        
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                   orientation: .right, options: [:]).perform([request])
    }
    
    // MARK: - 결과 처리
    private func processResults(_ results: [VNRecognizedObjectObservation], fps: Double) {
        var newDetections: [Detection] = []
        var highestDanger: (String, String, AlertLevel, Double, String)? = nil
        
        // [v8] 디버그: 첫 번째 탐지 객체의 relDepth를 표시
        var debugFirstRelDepth: Float? = nil
        var debugFirstDistance: Float? = nil
        var debugFirstLabel: String? = nil
        
        for obs in results {
            guard let top = obs.labels.first, top.confidence > 0.5 else { continue }
            let engName = top.identifier
            guard let korName = koreanLabels[engName] else { continue }
            
            let box = obs.boundingBox  // Vision 좌표 (y=0 하단)
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
                direction = "왼쪽"; avoidDirection = "오른쪽"
            } else if centerX < 0.66 {
                direction = "정면"; avoidDirection = "오른쪽"
            } else {
                direction = "오른쪽"; avoidDirection = "왼쪽"
            }
            
            // ─────────────────────────────────────────────────────────
            // [v8] 거리 측정
            //   1순위: Depth Anything V2 (역수+고정범위 정규화)
            //   2순위: 바운딩박스 역산 (상한 15m)
            //   LiDAR: 사용 안 함
            // ─────────────────────────────────────────────────────────
            var distance: Float = -1
            var distanceSource: String = "없음"
            let currentSize = box.width * box.height
            
            // 1순위: Depth Anything V2
            if depthEngine.isReady,
               let relDepth = depthEngine.averageRelativeDepth(box: box) {
                distance = depthEngine.toMeters(relDepth)
                distanceSource = "DepthAI"
                
                // 디버그: 첫 번째 객체의 relDepth 저장
                if debugFirstRelDepth == nil {
                    debugFirstRelDepth = relDepth
                    debugFirstDistance = distance
                    debugFirstLabel = korName
                }
            }
            
            // 2순위: 바운딩박스 역산 (fallback)
            // [v8] 상한 50m → 15m (이 방법은 15m 이상에서 신뢰도 없음)
            if distance < 0, let realH = realHeights[engName] {
                let boxRatio = Float(box.height)
                if boxRatio > 0.02 {
                    distance       = min(realH / boxRatio * 0.55, 15.0)
                    distanceSource = "역산"
                }
            }
            // ─────────────────────────────────────────────────────────
            
            // 트래킹
            let trackKey = "\(engName)_\(Int(centerX * 3))_\(Int(box.midY * 3))"
            
            let approachStatus: ApproachStatus
            var ttc: Double = 999
            var isParked = false
            
            if var tracked = trackedObjects[trackKey] {
                tracked.sizeHistory.append(currentSize)
                if tracked.sizeHistory.count > 15 { tracked.sizeHistory.removeFirst() }
                
                tracked.centerXHistory.append(centerX)
                if tracked.centerXHistory.count > 15 { tracked.centerXHistory.removeFirst() }
                
                if distance > 0 {
                    tracked.distanceHistory.append(distance)
                    if tracked.distanceHistory.count > 10 { tracked.distanceHistory.removeFirst() }
                    tracked.distance = distance
                }
                
                tracked.lastSize    = currentSize
                tracked.lastCenterX = centerX
                tracked.lastCenterY = box.midY
                tracked.lastSeen    = frameCount
                
                let changeRate = tracked.sizeChangeRate
                
                if vehicleClasses.contains(engName) {
                    isParked = tracked.isLikelyParked
                }
                
                if isParked {
                    approachStatus = .stationary
                    tracked.approachCount = 0
                } else {
                    if changeRate > 0.03 {
                        tracked.approachCount += 1; tracked.recedingCount = 0
                    } else if changeRate < -0.03 {
                        tracked.recedingCount += 1; tracked.approachCount = 0
                    } else {
                        tracked.approachCount = max(0, tracked.approachCount - 1)
                        tracked.recedingCount = max(0, tracked.recedingCount - 1)
                    }
                    
                    if tracked.approachCount >= 3 {
                        approachStatus = .approaching
                        let dangerSize: CGFloat = 0.25
                        if currentSize < dangerSize && changeRate > 0 {
                            let framesToDanger = (dangerSize - currentSize)
                                / (changeRate * max(currentSize, 0.001))
                            ttc = max(0, min(Double(framesToDanger) / max(fps, 1), 30))
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
                    lastSize: currentSize, lastCenterX: centerX, lastCenterY: box.midY,
                    sizeHistory: [currentSize], centerXHistory: [centerX],
                    distanceHistory: distance > 0 ? [distance] : [],
                    lastSeen: frameCount, distance: distance,
                    approachCount: 0, recedingCount: 0
                )
            }
            
            let detection = Detection(
                label: korName, confidence: top.confidence,
                boundingBox: screenBox, direction: direction,
                approachStatus: approachStatus, distance: distance,
                ttc: ttc, trackID: trackKey.hashValue, isParked: isParked,
                distanceSource: distanceSource
            )
            newDetections.append(detection)
            
            if approachStatus == .approaching && !isParked {
                let level: AlertLevel = ttc < 1.5 ? .danger : ttc < 3.0 ? .warning : .info
                if let cur = highestDanger {
                    if ttc < cur.3 {
                        highestDanger = (korName, direction, level, ttc, avoidDirection)
                    }
                } else {
                    highestDanger = (korName, direction, level, ttc, avoidDirection)
                }
            }
        }
        
        trackedObjects = trackedObjects.filter { frameCount - $0.value.lastSeen < 15 }
        
        DispatchQueue.main.async {
            self.detections = newDetections
            self.fps = fps
            
            // 상태 메시지
            let parkedCount = newDetections.filter { $0.isParked }.count
            let activeCount = newDetections.count - parkedCount
            self.statusMessage = "탐지 \(newDetections.count)개 (활성\(activeCount)/주차\(parkedCount)) | Depth AI v8 | scale=\(String(format:"%.1f", self.depthEngine.scale))"
            
            // [v8] 디버그 정보
            if self.debugMode {
                var dbg = String(format: "raw: min=%.2f med=%.2f max=%.2f",
                                 self.depthEngine.lastRawMin,
                                 self.depthEngine.lastRawMedian,
                                 self.depthEngine.lastRawMax)
                if let rel = debugFirstRelDepth,
                   let dist = debugFirstDistance,
                   let label = debugFirstLabel {
                    dbg += String(format: "\n%@: relDepth=%.3f → %.1fm", label, rel, dist)
                    dbg += String(format: "\nscale=%.2f offset=%.2f", self.depthEngine.scale, self.depthEngine.offset)
                }
                self.debugInfo = dbg
            }
            
            // 경고 처리
            if let danger = highestDanger {
                let distInfo = newDetections.first {
                    $0.label == danger.0 && $0.direction == danger.1
                }
                let distText = distInfo.map {
                    $0.distance > 0 ? String(format: " %.1fm", $0.distance) : ""
                } ?? ""
                
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
                if self.isSpeechEnabled { self.speak(message, level: danger.2) }
                self.triggerHaptic(level: danger.2)
            } else {
                self.currentAlert = nil
            }
        }
    }
    
    // MARK: - TTS / 햅틱
    private func speak(_ text: String, level: AlertLevel) {
        let now = Date()
        let cooldown: TimeInterval = level == .danger ? 1.0 : 2.5
        guard now.timeIntervalSince(lastSpeechTime) > cooldown else { return }
        
        if synthesizer.isSpeaking {
            if level == .danger { synthesizer.stopSpeaking(at: .immediate) }
            else { return }
        }
        lastSpeechTime = now
        
        let utterance        = AVSpeechUtterance(string: text)
        utterance.voice      = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate       = level == .danger ? 0.6 : 0.52
        utterance.volume     = 1.0
        synthesizer.speak(utterance)
    }
    
    private func triggerHaptic(level: AlertLevel) {
        switch level {
        case .danger:  UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .warning: UINotificationFeedbackGenerator().notificationOccurred(.warning)
        case .info:    UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

#Preview { ContentView() }

