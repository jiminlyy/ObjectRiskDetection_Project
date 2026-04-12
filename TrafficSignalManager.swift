//회전 교차로 탐지느 성ㅇ but 신호 API 응답의 JSON파싱에서 실패한다. 

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
    
    /// CLLocation 변환 (거리 계산용)
    var location: CLLocation {
        CLLocation(latitude: mapCtptIntLat, longitude: mapCtptIntLot)
    }
}

/// 실시간 신호 정보 (Signal Phase Timing API에서 가져옴)
struct SignalPhaseData: Codable {
    let itstId: String
    
    // 북쪽 보행신호 잔여 센티초 (1/10초 단위)
    let ntPdsgRmdrCs: Double?
    // 동쪽
    let etPdsgRmdrCs: Double?
    // 남쪽
    let stPdsgRmdrCs: Double?
    // 서쪽
    let wtPdsgRmdrCs: Double?
    // 북동
    let nePdsgRmdrCs: Double?
    // 남동
    let sePdsgRmdrCs: Double?
    // 남서
    let swPdsgRmdrCs: Double?
    // 북서
    let nwPdsgRmdrCs: Double?
    
    // 직진신호도 가져와서 빨강/초록 판단에 활용
    let ntStsgRmdrCs: Double?
    let etStsgRmdrCs: Double?
    let stStsgRmdrCs: Double?
    let wtStsgRmdrCs: Double?
}

/// 사용자에게 전달할 최종 신호 정보
struct PedestrianSignalInfo {
    let crossroadName: String    // 교차로 이름
    let direction: String        // "북쪽", "동쪽", "남쪽", "서쪽"
    let remainingSeconds: Double // 남은 시간 (초)
    let distanceMeters: Double   // 교차로까지 거리 (m)
    let isAvailable: Bool        // 해당 방향에 보행신호가 있는지
}

// MARK: - TrafficSignalManager

class TrafficSignalManager: NSObject, ObservableObject {
    
    static let shared = TrafficSignalManager()
    
    // ============================
    // MARK: API 설정
    // ============================
    
    /// ⚠️ 여기에 너의 API 키를 넣어
    private let apiKey = "880e36ba-c66e-4d1e-aaa4-c31fbded3839"
    
    /// 교차로 Map API 엔드포인트
    private let crossroadMapURL = "https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/v2xCrossroadMapInformation/1.0"
    
    /// 신호 잔여시간 API 엔드포인트
    private let signalPhaseURL = "https://t-data.seoul.go.kr/apig/apiman-gateway/tapi/v2xSignalPhaseTimingInformation/1.0"
    
    // ============================
    // MARK: 상태 변수
    // ============================
    
    /// 캐싱된 전체 교차로 목록
    @Published var crossroads: [Crossroad] = []
    
    /// 현재 가장 가까운 교차로
    @Published var nearestCrossroad: Crossroad?
    
    /// 현재 신호 정보
    @Published var currentSignalInfo: PedestrianSignalInfo?
    
    /// 로딩 상태
    @Published var isLoading = false
    
    /// 에러 메시지
    @Published var errorMessage: String?
    
    /// 디버그 로그
    @Published var debugLog: String = ""
    
    /// TTS 엔진
    private let synthesizer = AVSpeechSynthesizer()
    
    /// 교차로 감지 반경 (미터) - 테스트용으로 200m, 실제 배포 시 50m로 줄이기
    private let detectionRadius: Double = 200.0
    
    /// 비정상 잔여시간 임계값 (3600초 = 60분, 이 이상이면 비정상)
    private let abnormalThreshold: Double = 3600.0
    
    /// 마지막 TTS 안내 시각 (중복 안내 방지)
    private var lastAnnouncementTime: Date?
    
    /// TTS 최소 간격 (초)
    private let announcementInterval: TimeInterval = 5.0
    
    // ============================
    // MARK: 1단계 - 교차로 목록 로딩
    // ============================
    
    /// 앱 시작 시 한 번 호출해서 전체 교차로 목록을 캐싱
    func loadCrossroads() {
        guard let url = URL(string: "\(crossroadMapURL)?apikey=\(apiKey)") else {
            log("❌ 교차로 Map API URL 생성 실패")
            return
        }
        
        isLoading = true
        log("📡 교차로 목록 로딩 시작...")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false
                
                if let error = error {
                    self?.log("❌ 네트워크 에러: \(error.localizedDescription)")
                    self?.errorMessage = "네트워크 에러: \(error.localizedDescription)"
                    return
                }
                
                guard let data = data else {
                    self?.log("❌ 데이터 없음")
                    self?.errorMessage = "데이터 없음"
                    return
                }
                
                do {
                    let allCrossroads = try JSONDecoder().decode([Crossroad].self, from: data)
                    
                    // 위도가 비정상인 데이터 필터링 (일부 교차로가 0.37xxx 같은 잘못된 좌표를 가짐)
                    let validCrossroads = allCrossroads.filter { crossroad in
                        crossroad.mapCtptIntLat > 33.0 && crossroad.mapCtptIntLat < 39.0 &&
                        crossroad.mapCtptIntLot > 124.0 && crossroad.mapCtptIntLot < 132.0
                    }
                    
                    self?.crossroads = validCrossroads
                    self?.log("✅ 교차로 \(validCrossroads.count)개 로딩 완료 (전체 \(allCrossroads.count)개 중 유효)")
                } catch {
                    self?.log("❌ JSON 파싱 에러: \(error.localizedDescription)")
                    self?.errorMessage = "데이터 파싱 에러"
                }
            }
        }.resume()
    }
    
    // ============================
    // MARK: 2단계 - 가장 가까운 교차로 찾기
    // ============================
    
    /// GPS 좌표로 가장 가까운 교차로를 찾음
    /// - Parameters:
    ///   - userLocation: 현재 사용자 위치
    /// - Returns: 가장 가까운 교차로와 거리 (반경 내에 없으면 nil)
    func findNearestCrossroad(from userLocation: CLLocation) -> (Crossroad, Double)? {
        guard !crossroads.isEmpty else {
            log("⚠️ 교차로 목록이 비어있음. loadCrossroads() 먼저 호출 필요")
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
            return nil
        }
        
        nearestCrossroad = found
        log("📍 가장 가까운 교차로: \(found.itstNm) (ID: \(found.itstId), \(String(format: "%.1f", minDistance))m)")
        return (found, minDistance)
    }
    
    // ============================
    // MARK: 3단계 - 방향 결정
    // ============================
    
    /// CLHeading에서 4방위 방향 문자열 반환
    /// - Parameter heading: 사용자가 바라보는 방향 (0° = 북, 90° = 동, 180° = 남, 270° = 서)
    /// - Returns: ("북쪽", "nt") 같은 튜플
    func determineDirection(heading: Double) -> (displayName: String, prefix: String) {
        // heading: 0~360도
        let normalizedHeading = heading.truncatingRemainder(dividingBy: 360.0)
        
        if normalizedHeading >= 315 || normalizedHeading < 45 {
            return ("북쪽", "nt")
        } else if normalizedHeading >= 45 && normalizedHeading < 135 {
            return ("동쪽", "et")
        } else if normalizedHeading >= 135 && normalizedHeading < 225 {
            return ("남쪽", "st")
        } else {
            return ("서쪽", "wt")
        }
    }
    
    // ============================
    // MARK: 4단계 - 실시간 신호 조회
    // ============================
    
    /// 특정 교차로의 실시간 보행신호를 조회
    /// - Parameters:
    ///   - itstId: 교차로 ID
    ///   - completion: 해당 교차로의 신호 데이터
    func fetchSignalPhase(for itstId: String, completion: @escaping (SignalPhaseData?) -> Void) {
        // itstId 파라미터로 필터링 시도
        var urlString = "\(signalPhaseURL)?apikey=\(apiKey)&itstId=\(itstId)&numOfRows=1"
        
        guard let url = URL(string: urlString) else {
            log("❌ 신호 API URL 생성 실패")
            completion(nil)
            return
        }
        
        log("📡 신호 조회 중... (교차로 ID: \(itstId))")
        
        URLSession.shared.dataTask(with: url) { [weak self] data, response, error in
            if let error = error {
                DispatchQueue.main.async {
                    self?.log("❌ 신호 API 에러: \(error.localizedDescription)")
                }
                completion(nil)
                return
            }
            
            guard let data = data else {
                completion(nil)
                return
            }
            
            do {
                let allSignals = try JSONDecoder().decode([SignalPhaseData].self, from: data)
                
                // itstId 파라미터 필터링이 안 되는 경우를 대비해 수동 필터링
                let matched = allSignals.first { $0.itstId == itstId }
                
                if let matched = matched {
                    DispatchQueue.main.async {
                        self?.log("✅ 신호 데이터 수신 (교차로: \(itstId))")
                    }
                    completion(matched)
                } else {
                    DispatchQueue.main.async {
                        self?.log("⚠️ 교차로 \(itstId)의 신호 데이터 없음 (수신 \(allSignals.count)건 중 매칭 실패)")
                    }
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.log("❌ 신호 JSON 파싱 에러: \(error.localizedDescription)")
                }
                completion(nil)
            }
        }.resume()
    }
    
    // ============================
    // MARK: 5단계 - 통합: 위치+방향 → 신호 안내
    // ============================
    
    /// 메인 함수: 현재 위치와 방향으로 보행신호 안내
    /// - Parameters:
    ///   - userLocation: 현재 GPS 위치
    ///   - heading: 사용자가 바라보는 방향 (CLHeading.magneticHeading)
    func checkSignal(userLocation: CLLocation, heading: Double) {
        // 1) 가장 가까운 교차로 찾기
        guard let (crossroad, distance) = findNearestCrossroad(from: userLocation) else {
            // 반경 내 교차로 없음 - 조용히 대기
            DispatchQueue.main.async {
                self.currentSignalInfo = nil
            }
            return
        }
        
        // 2) 방향 결정
        let (directionName, directionPrefix) = determineDirection(heading: heading)
        log("🧭 바라보는 방향: \(directionName) (heading: \(String(format: "%.1f", heading))°)")
        
        // 3) 신호 API 호출
        fetchSignalPhase(for: crossroad.itstId) { [weak self] signalData in
            guard let self = self, let signal = signalData else {
                DispatchQueue.main.async {
                    self?.currentSignalInfo = PedestrianSignalInfo(
                        crossroadName: crossroad.itstNm,
                        direction: directionName,
                        remainingSeconds: 0,
                        distanceMeters: distance,
                        isAvailable: false
                    )
                    self?.log("⚠️ \(crossroad.itstNm) \(directionName) 신호 데이터 없음")
                }
                return
            }
            
            // 4) 해당 방향의 보행신호 잔여시간 추출
            let remainingCentiSeconds: Double? = {
                switch directionPrefix {
                case "nt": return signal.ntPdsgRmdrCs
                case "et": return signal.etPdsgRmdrCs
                case "st": return signal.stPdsgRmdrCs
                case "wt": return signal.wtPdsgRmdrCs
                default: return nil
                }
            }()
            
            DispatchQueue.main.async {
                if let centiSeconds = remainingCentiSeconds {
                    let seconds = centiSeconds / 10.0
                    
                    // 비정상 값 필터링 (36001 등)
                    if seconds > self.abnormalThreshold {
                        self.currentSignalInfo = PedestrianSignalInfo(
                            crossroadName: crossroad.itstNm,
                            direction: directionName,
                            remainingSeconds: 0,
                            distanceMeters: distance,
                            isAvailable: false
                        )
                        self.log("⚠️ 비정상 잔여시간 감지: \(seconds)초 → 무시")
                        return
                    }
                    
                    let info = PedestrianSignalInfo(
                        crossroadName: crossroad.itstNm,
                        direction: directionName,
                        remainingSeconds: seconds,
                        distanceMeters: distance,
                        isAvailable: true
                    )
                    self.currentSignalInfo = info
                    
                    let logMsg = "🚦 \(crossroad.itstNm) \(directionName) 보행신호: \(String(format: "%.1f", seconds))초 남음 (거리: \(String(format: "%.0f", distance))m)"
                    self.log(logMsg)
                    
                    // TTS 안내
                    self.announceSignal(info: info)
                    
                } else {
                    self.currentSignalInfo = PedestrianSignalInfo(
                        crossroadName: crossroad.itstNm,
                        direction: directionName,
                        remainingSeconds: 0,
                        distanceMeters: distance,
                        isAvailable: false
                    )
                    self.log("ℹ️ \(crossroad.itstNm) \(directionName) 방향에 보행신호 없음")
                }
            }
        }
    }
    
    // ============================
    // MARK: TTS 음성 안내
    // ============================
    
    private func announceSignal(info: PedestrianSignalInfo) {
        // 중복 안내 방지
        if let lastTime = lastAnnouncementTime,
           Date().timeIntervalSince(lastTime) < announcementInterval {
            return
        }
        
        guard info.isAvailable else { return }
        
        let seconds = Int(info.remainingSeconds)
        let message: String
        
        if seconds <= 5 {
            message = "\(info.crossroadName), \(info.direction) 보행신호 곧 바뀝니다. 주의하세요."
        } else {
            message = "\(info.crossroadName), \(info.direction) 보행신호 \(seconds)초 남았습니다."
        }
        
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "ko-KR")
        utterance.rate = 0.5
        
        synthesizer.stopSpeaking(at: .immediate)
        synthesizer.speak(utterance)
        
        lastAnnouncementTime = Date()
        log("🔊 TTS: \(message)")
    }
    
    // ============================
    // MARK: 디버그 로그
    // ============================
    
    private func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let logLine = "[\(timestamp)] \(message)"
        print(logLine)
        DispatchQueue.main.async {
            self.debugLog = logLine + "\n" + self.debugLog
            // 로그 길이 제한 (최근 50줄)
            let lines = self.debugLog.split(separator: "\n", maxSplits: 50, omittingEmptySubsequences: false)
            if lines.count > 50 {
                self.debugLog = lines.prefix(50).joined(separator: "\n")
            }
        }
    }
}
