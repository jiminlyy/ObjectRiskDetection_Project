import Foundation
import CoreLocation
import AVFoundation
import Combine

// MARK: - 데이터 모델

/// 교차로 기본 정보 (교차로 Map API에서 가져옴)
struct Crossroad: Codable {
    let itstId: String       // 교차로 고유 ID
    let itstNm: String       // 교차로 이름 (예: "난곡우체국앞")
    let mapCtptIntLat: Double // 위도
    let mapCtptIntLot: Double // 경도
    
    var location: CLLocation {
        CLLocation(latitude: mapCtptIntLat, longitude: mapCtptIntLot)
    }
}

/// 실시간 신호 정보
struct SignalPhaseData: Codable {
    let itstId: String
    let ntPdsgRmdrCs: Double?
    let etPdsgRmdrCs: Double?
    let stPdsgRmdrCs: Double?
    let wtPdsgRmdrCs: Double?
    let nePdsgRmdrCs: Double?
    let sePdsgRmdrCs: Double?
    let swPdsgRmdrCs: Double?
    let nwPdsgRmdrCs: Double?
    let ntStsgRmdrCs: Double?
    let etStsgRmdrCs: Double?
    let stStsgRmdrCs: Double?
    let wtStsgRmdrCs: Double?
}

/// 사용자에게 전달할 최종 신호 정보
struct PedestrianSignalInfo {
    let crossroadName: String
    let direction: String
    let remainingSeconds: Double
    let distanceMeters: Double
    let isAvailable: Bool
}

// MARK: - TrafficSignalManager

class TrafficSignalManager: NSObject, ObservableObject {
    
    static let shared = TrafficSignalManager()
    
    // MARK: API 설정
    
    private let apiKey = "880e36ba-c66e-4d1e-aaa4-c31fbded3839"
    
    /// API URL (https 사용)
    private let crossroadMapURL = "https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/v2xCrossroadMapInformation/1.0"
    private let signalPhaseURL = "https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/v2xSignalPhaseTimingInformation/1.0"
    
    // MARK: 상태 변수
    
    @Published var crossroads: [Crossroad] = []
    @Published var nearestCrossroad: Crossroad?
    @Published var currentSignalInfo: PedestrianSignalInfo?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var debugLog: String = ""
    
    private let synthesizer = AVSpeechSynthesizer()
    
    /// 교차로 감지 반경 — 테스트용 2km, 실배포 시 50m로 변경
    private let detectionRadius: Double = 2000.0
    private let abnormalThreshold: Double = 3600.0
    private var lastAnnouncementTime: Date?
    private let announcementInterval: TimeInterval = 5.0
    
    // MARK: 1단계 - 교차로 목록 로딩
    
    func loadCrossroads(retryCount: Int = 0) {
        let urlString = "\(crossroadMapURL)?apikey=\(apiKey)"
        guard let url = URL(string: urlString) else {
            log("❌ URL 생성 실패")
            return
        }
        
        isLoading = true
        let maxRetries = 3
        log("📡 교차로 로딩 시작 (시도 \(retryCount + 1)/\(maxRetries))")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    let msg = error.localizedDescription
                    self?.log("❌ 에러: \(msg)")
                    
                    if msg.contains("App Transport Security") || msg.contains("cleartext") {
                        self?.errorMessage = "Info.plist에 ATS 예외 설정 필요"
                        self?.log("💡 Info.plist → App Transport Security Settings → Allow Arbitrary Loads → YES")
                    } else if retryCount < maxRetries - 1 {
                        self?.errorMessage = "네트워크 오류, 10초 후 재시도..."
                        self?.log("🔄 10초 후 재시도...")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                            self?.loadCrossroads(retryCount: retryCount + 1)
                        }
                    } else {
                        self?.errorMessage = "교차로 로딩 실패"
                    }
                    return
                }
                
                if let httpResponse = response as? HTTPURLResponse {
                    self?.log("📊 HTTP \(httpResponse.statusCode)")
                    if httpResponse.statusCode != 200 {
                        if retryCount < maxRetries - 1 {
                            self?.errorMessage = "서버 오류(\(httpResponse.statusCode)), 10초 후 재시도..."
                            self?.log("🔄 10초 후 재시도...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                                self?.loadCrossroads(retryCount: retryCount + 1)
                            }
                        } else {
                            self?.errorMessage = "API 서버 오류 (\(httpResponse.statusCode))"
                        }
                        return
                    }
                }
                
                guard let data = data else {
                    self?.log("❌ 데이터 없음")
                    return
                }
                
                do {
                    let allCrossroads = try JSONDecoder().decode([Crossroad].self, from: data)
                    let validCrossroads = allCrossroads.filter { c in
                        c.mapCtptIntLat > 33.0 && c.mapCtptIntLat < 39.0 &&
                        c.mapCtptIntLot > 124.0 && c.mapCtptIntLot < 132.0
                    }
                    self?.crossroads = validCrossroads
                    self?.errorMessage = nil
                    self?.log("✅ 교차로 \(validCrossroads.count)개 로딩 완료 (전체 \(allCrossroads.count)개)")
                } catch {
                    self?.log("❌ JSON 파싱 에러: \(error.localizedDescription)")
                    self?.errorMessage = "데이터 파싱 에러"
                }
            }
        }.resume()
    }
    
    // MARK: 2단계 - 가장 가까운 교차로 찾기
    
    func findNearestCrossroad(from userLocation: CLLocation) -> (Crossroad, Double)? {
        guard !crossroads.isEmpty else {
            log("⚠️ 교차로 목록이 비어있음")
            return nil
        }
        
        var nearest: Crossroad?
        var minDistance: Double = Double.greatestFiniteMagnitude
        
        for crossroad in crossroads {
            let distance = userLocation.distance(from: crossroad.location)
            if distance < minDistance {
                minDistance = distance
                nearest = crossroad
            }
        }
        
        guard let found = nearest, minDistance <= detectionRadius else {
            log("📍 가장 가까운 교차로: \(String(format: "%.0f", minDistance))m (반경 \(String(format: "%.0f", detectionRadius))m 초과)")
            return nil
        }
        
        nearestCrossroad = found
        log("📍 \(found.itstNm) (ID:\(found.itstId)) — \(String(format: "%.0f", minDistance))m")
        return (found, minDistance)
    }
    
    // MARK: 3단계 - 방향 결정
    
    func determineDirection(heading: Double) -> (displayName: String, prefix: String) {
        let h = heading.truncatingRemainder(dividingBy: 360.0)
        if h >= 315 || h < 45 { return ("북쪽", "nt") }
        else if h >= 45 && h < 135 { return ("동쪽", "et") }
        else if h >= 135 && h < 225 { return ("남쪽", "st") }
        else { return ("서쪽", "wt") }
    }
    
    // MARK: 4단계 - 실시간 신호 조회
    
    func fetchSignalPhase(for itstId: String, completion: @escaping (SignalPhaseData?) -> Void) {
        let urlString = "\(signalPhaseURL)?apikey=\(apiKey)&itstId=\(itstId)&numOfRows=1"
        guard let url = URL(string: urlString) else {
            completion(nil)
            return
        
        }
        
        log("📡 신호 조회 (ID: \(itstId))")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async { self?.log("❌ 신호 API 에러: \(error.localizedDescription)") }
                completion(nil)
                return
            }
            guard let data = data else { completion(nil); return }
            
            do {
                let allSignals = try JSONDecoder().decode([SignalPhaseData].self, from: data)
                let matched = allSignals.first { $0.itstId == itstId }
                
                DispatchQueue.main.async {
                    if matched != nil {
                        self?.log("✅ 신호 데이터 수신 (ID: \(itstId))")
                    } else {
                        self?.log("⚠️ ID \(itstId) 매칭 실패 (수신 \(allSignals.count)건)")
                    }
                }
                completion(matched)
            } catch {
                DispatchQueue.main.async { self?.log("❌ 신호 파싱 에러: \(error.localizedDescription)") }
                completion(nil)
            }
        }.resume()
    }
    
    // MARK: 5단계 - 통합
    
    func checkSignal(userLocation: CLLocation, heading: Double) {
        guard let (crossroad, distance) = findNearestCrossroad(from: userLocation) else {
            DispatchQueue.main.async { self.currentSignalInfo = nil }
            return
        }
        
        let (directionName, directionPrefix) = determineDirection(heading: heading)
        log("🧭 방향: \(directionName) (\(String(format: "%.1f", heading))°)")
        
        fetchSignalPhase(for: crossroad.itstId) { [weak self] signalData in
            guard let self = self, let signal = signalData else {
                DispatchQueue.main.async {
                    self?.currentSignalInfo = PedestrianSignalInfo(
                        crossroadName: crossroad.itstNm, direction: directionName,
                        remainingSeconds: 0, distanceMeters: distance, isAvailable: false
                    )
                }
                return
            }
            
            let centiSeconds: Double? = {
                switch directionPrefix {
                case "nt": return signal.ntPdsgRmdrCs
                case "et": return signal.etPdsgRmdrCs
                case "st": return signal.stPdsgRmdrCs
                case "wt": return signal.wtPdsgRmdrCs
                default: return nil
                }
            }()
            
            DispatchQueue.main.async {
                if let cs = centiSeconds {
                    let seconds = cs / 10.0
                    
                    if seconds > self.abnormalThreshold {
                        self.currentSignalInfo = PedestrianSignalInfo(
                            crossroadName: crossroad.itstNm, direction: directionName,
                            remainingSeconds: 0, distanceMeters: distance, isAvailable: false
                        )
                        self.log("⚠️ 비정상 값: \(seconds)초")
                        return
                    }
                    
                    let info = PedestrianSignalInfo(
                        crossroadName: crossroad.itstNm, direction: directionName,
                        remainingSeconds: seconds, distanceMeters: distance, isAvailable: true
                    )
                    self.currentSignalInfo = info
                    self.log("🚦 \(crossroad.itstNm) \(directionName): \(String(format: "%.1f", seconds))초 (\(String(format: "%.0f", distance))m)")
                    self.announceSignal(info: info)
                } else {
                    self.currentSignalInfo = PedestrianSignalInfo(
                        crossroadName: crossroad.itstNm, direction: directionName,
                        remainingSeconds: 0, distanceMeters: distance, isAvailable: false
                    )
                    self.log("ℹ️ \(crossroad.itstNm) \(directionName) 보행신호 없음")
                }
            }
        }
    }
    
    // MARK: TTS
    
    private func announceSignal(info: PedestrianSignalInfo) {
        if let lastTime = lastAnnouncementTime,
           Date().timeIntervalSince(lastTime) < announcementInterval { return }
        guard info.isAvailable else { return }
        
        let seconds = Int(info.remainingSeconds)
        let message = seconds <= 5
            ? "\(info.crossroadName), \(info.direction) 보행신호 곧 바뀝니다."
            : "\(info.crossroadName), \(info.direction) 보행신호 \(seconds)초 남았습니다."
        
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = 0.5
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
        lastAnnouncementTime = Date()
        log("🔊 \(message)")
    }
    
    // MARK: 로그
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)"
        print(logLine)
        DispatchQueue.main.async {
            self.debugLog = logLine + "\n" + self.debugLog
            let lines = self.debugLog.split(separator: "\n", maxSplits: 50, omittingEmptySubsequences: false)
            if lines.count > 50 {
                self.debugLog = lines.prefix(50).joined(separator: "\n")
            }
        }
    }
}
