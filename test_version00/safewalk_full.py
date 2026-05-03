# safewalk_full.py
# SafeWalk PC 프로토타입 — 전체 기능 통합
# 기능: ByteTrack 트래킹 + 거리 추정 + TTC 충돌 예측 + 주차 판별 + 음성 안내 + 3단계 경고
#
# 실행: python3 safewalk_full.py
# 종료: q 키

from ultralytics import YOLO
import cv2
import numpy as np
import time
import threading

# ===== TTS 설정 =====
# gTTS(온라인) 또는 pyttsx3(오프라인) 자동 선택
TTS_AVAILABLE = False
try:
    import pyttsx3
    tts_engine = pyttsx3.init()
    tts_engine.setProperty('rate', 180)
    TTS_AVAILABLE = True
    TTS_TYPE = "pyttsx3"
except:
    try:
        from gtts import gTTS
        import os
        TTS_AVAILABLE = True
        TTS_TYPE = "gtts"
    except:
        TTS_TYPE = "none"

# ===== 설정 =====
MODEL_PATH = "yolov8n.pt"
CONFIDENCE_THRESHOLD = 0.5

# 타겟 클래스
TARGET_CLASSES = {
    0: "사람", 1: "자전거", 2: "자동차", 3: "오토바이",
    5: "버스", 7: "트럭", 9: "신호등"
}

# 차량 클래스 (주차 판별 대상)
VEHICLE_CLASS_IDS = {2, 3, 5, 7}

# 물체별 실제 높이 (미터) — 거리 역산용
REAL_HEIGHTS = {
    0: 1.7,   # 사람
    1: 1.0,   # 자전거 (탑승)
    2: 1.5,   # 승용차
    3: 1.1,   # 오토바이 (탑승)
    5: 3.2,   # 버스
    7: 3.5,   # 트럭
}

# TTC 경고 임계값
TTC_DANGER = 1.5    # 초: 긴급 경고
TTC_WARNING = 3.0   # 초: 주의 경고
TTC_INFO = 5.0      # 초: 정보 안내

# 주차 판별 임계값
CENTER_MOVE_THRESHOLD = 0.04   # 프레임당 중심 이동 4% 이상이면 지나가는 중
SIZE_CHANGE_THRESHOLD = 0.03   # 면적 변화율 3% 이상이면 접근/이탈

# 음성 쿨다운
SPEECH_COOLDOWN = 2.5  # 초


# ===== 트래킹 데이터 =====
class TrackedObjectData:
    def __init__(self):
        self.size_history = []       # 바운딩 박스 면적 히스토리
        self.center_x_history = []   # 중심 X 히스토리
        self.center_y_history = []   # 중심 Y 히스토리
        self.distance_history = []   # 거리 히스토리
        self.approach_count = 0      # 연속 접근 카운트
        self.receding_count = 0      # 연속 이탈 카운트
        self.last_seen_frame = 0
    
    def update(self, size, cx, cy, distance, frame_num):
        self.size_history.append(size)
        self.center_x_history.append(cx)
        self.center_y_history.append(cy)
        if distance > 0:
            self.distance_history.append(distance)
        self.last_seen_frame = frame_num
        
        # 히스토리 제한
        if len(self.size_history) > 20:
            self.size_history = self.size_history[-20:]
        if len(self.center_x_history) > 20:
            self.center_x_history = self.center_x_history[-20:]
        if len(self.center_y_history) > 20:
            self.center_y_history = self.center_y_history[-20:]
        if len(self.distance_history) > 15:
            self.distance_history = self.distance_history[-15:]
    
    @property
    def size_change_rate(self):
        """면적 변화율 (최근 8프레임 기준)"""
        if len(self.size_history) < 5:
            return 0
        recent = self.size_history[-8:]
        first = recent[0]
        last = recent[-1]
        if first < 0.0001:
            return 0
        return (last - first) / first / len(recent)
    
    @property
    def center_x_movement(self):
        """프레임당 평균 중심 X 이동량"""
        if len(self.center_x_history) < 3:
            return 0
        recent = self.center_x_history[-8:]
        total = sum(abs(recent[i] - recent[i-1]) for i in range(1, len(recent)))
        return total / (len(recent) - 1)
    
    @property
    def is_likely_parked(self):
        """주차 차량 여부 판별"""
        size_growing = self.size_change_rate > 0.02
        center_moving = self.center_x_movement > CENTER_MOVE_THRESHOLD
        
        # 면적 커지는데 중심이 크게 이동 → 내가 옆을 지나가는 중
        if size_growing and center_moving:
            return True
        
        # 화면 가장자리에 있으면서 중심 이동 큼
        if len(self.center_x_history) > 0:
            last_cx = self.center_x_history[-1]
            if (last_cx < 0.15 or last_cx > 0.85) and center_moving:
                return True
        
        # 거리 변화가 거의 없으면서 중심 이동 큼
        if len(self.distance_history) >= 4:
            recent_dist = self.distance_history[-4:]
            dist_change = abs(recent_dist[-1] - recent_dist[0])
            if dist_change < 0.5 and center_moving:
                return True
        
        return False


# ===== 음성 안내 =====
last_speech_time = 0
is_speaking = False

def speak(text, level="info"):
    global last_speech_time, is_speaking
    
    if not TTS_AVAILABLE:
        return
    
    now = time.time()
    cooldown = 1.0 if level == "danger" else SPEECH_COOLDOWN
    if now - last_speech_time < cooldown:
        return
    if is_speaking and level != "danger":
        return
    
    last_speech_time = now
    
    def _speak():
        global is_speaking
        is_speaking = True
        try:
            if TTS_TYPE == "pyttsx3":
                tts_engine.say(text)
                tts_engine.runAndWait()
            elif TTS_TYPE == "gtts":
                tts = gTTS(text=text, lang='ko')
                tts.save("/tmp/safewalk_alert.mp3")
                os.system("afplay /tmp/safewalk_alert.mp3")  # macOS
        except:
            pass
        is_speaking = False
    
    thread = threading.Thread(target=_speak, daemon=True)
    thread.start()


# ===== 거리 추정 =====
def estimate_distance(cls_id, box_height, frame_height):
    """바운딩 박스 높이와 실제 높이로 거리 역산"""
    if cls_id not in REAL_HEIGHTS:
        return -1
    if box_height < 10:  # 너무 작은 박스는 무시
        return -1
    
    real_height = REAL_HEIGHTS[cls_id]
    box_ratio = box_height / frame_height
    
    if box_ratio < 0.02:
        return -1
    
    # 간이 역산: 카메라 FOV와 초점거리에 따라 보정 필요
    distance = real_height / box_ratio * 0.55
    return min(distance, 50)  # 50m 이상은 신뢰도 낮음


# ===== TTC 계산 =====
def calculate_ttc(current_size, change_rate, fps):
    """충돌까지 남은 시간 계산"""
    DANGER_SIZE = 0.25  # 화면의 25% 이상이면 매우 가까움
    
    if change_rate <= 0 or current_size >= DANGER_SIZE:
        return 999  # 접근 안 하고 있거나 이미 위험 범위
    
    frames_to_danger = (DANGER_SIZE - current_size) / (change_rate * max(current_size, 0.001))
    ttc = frames_to_danger / max(fps, 1)
    return max(0, min(ttc, 30))


# ===== 방향 판단 =====
def get_direction(center_x, frame_width):
    ratio = center_x / frame_width
    if ratio < 0.33:
        return "왼쪽", "오른쪽"
    elif ratio < 0.66:
        return "정면", "오른쪽"
    else:
        return "오른쪽", "왼쪽"


# ===== 색상 설정 =====
COLOR_DANGER = (0, 0, 255)      # 빨강
COLOR_WARNING = (0, 165, 255)   # 주황
COLOR_INFO = (255, 200, 0)      # 노랑
COLOR_SAFE = (0, 255, 0)        # 초록
COLOR_PARKED = (150, 150, 150)  # 회색
COLOR_TEXT_BG = (0, 0, 0)       # 검정 배경


# ===== 메인 =====
def main():
    model = YOLO(MODEL_PATH)
    cap = cv2.VideoCapture(0)
    
    if not cap.isOpened():
        print("카메라를 열 수 없습니다")
        return
    
    # 트래킹 데이터 저장
    tracked_data = {}  # track_id → TrackedObjectData
    frame_count = 0
    prev_time = time.time()
    
    print("="*50)
    print(" SafeWalk PC 프로토타입")
    print(" 종료: q키")
    print(f" TTS: {TTS_TYPE}")
    print("="*50)
    
    while cap.isOpened():
        ret, frame = cap.read()
        if not ret:
            break
        
        frame_count += 1
        frame_height, frame_width = frame.shape[:2]
        
        # FPS 계산
        current_time = time.time()
        fps = 1 / max(current_time - prev_time, 0.001)
        prev_time = current_time
        
        # ===== YOLO 추론 + ByteTrack 트래킹 =====
        results = model.track(
            frame, 
            tracker="bytetrack.yaml", 
            conf=CONFIDENCE_THRESHOLD, 
            persist=True,
            verbose=False
        )
        
        # 위험 정보 수집
        dangers = []  # (이름, 방향, 레벨, TTC, 회피방향, 거리)
        display_info = []  # 화면 표시용
        
        if results[0].boxes.id is not None:
            for box in results[0].boxes:
                cls_id = int(box.cls[0])
                
                # 타겟 클래스만 처리
                if cls_id not in TARGET_CLASSES:
                    continue
                
                track_id = int(box.id[0])
                confidence = float(box.conf[0])
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                
                # 기본 계산
                center_x = (x1 + x2) / 2
                center_y = (y1 + y2) / 2
                box_w = x2 - x1
                box_h = y2 - y1
                box_area = (box_w * box_h) / (frame_width * frame_height)  # 정규화 면적
                
                # 방향
                direction, avoid_dir = get_direction(center_x, frame_width)
                
                # 거리 추정
                distance = estimate_distance(cls_id, box_h, frame_height)
                
                # ===== 트래킹 데이터 업데이트 =====
                if track_id not in tracked_data:
                    tracked_data[track_id] = TrackedObjectData()
                
                td = tracked_data[track_id]
                td.update(
                    size=box_area,
                    cx=center_x / frame_width,
                    cy=center_y / frame_height,
                    distance=distance,
                    frame_num=frame_count
                )
                
                # ===== 주차 차량 판별 =====
                is_parked = False
                if cls_id in VEHICLE_CLASS_IDS:
                    is_parked = td.is_likely_parked
                
                # ===== 접근/이탈 판단 =====
                change_rate = td.size_change_rate
                status = ""
                ttc = 999
                
                if is_parked:
                    status = "[주차]"
                    color = COLOR_PARKED
                elif len(td.size_history) >= 5:
                    if change_rate > SIZE_CHANGE_THRESHOLD:
                        td.approach_count += 1
                        td.receding_count = 0
                    elif change_rate < -SIZE_CHANGE_THRESHOLD:
                        td.receding_count += 1
                        td.approach_count = 0
                    else:
                        td.approach_count = max(0, td.approach_count - 1)
                        td.receding_count = max(0, td.receding_count - 1)
                    
                    # 3프레임 연속이어야 확정
                    if td.approach_count >= 3:
                        status = "접근중"
                        ttc = calculate_ttc(box_area, change_rate, fps)
                        
                        if ttc < TTC_DANGER:
                            color = COLOR_DANGER
                        elif ttc < TTC_WARNING:
                            color = COLOR_WARNING
                        else:
                            color = COLOR_INFO
                    elif td.receding_count >= 3:
                        status = "이탈중"
                        color = COLOR_SAFE
                    else:
                        color = COLOR_SAFE
                else:
                    color = COLOR_SAFE
                
                # ===== 화면 표시 =====
                obj_name = TARGET_CLASSES[cls_id]
                
                # 바운딩 박스
                cv2.rectangle(frame, (int(x1), int(y1)), (int(x2), int(y2)), color, 2)
                
                # 라벨 텍스트
                label_parts = [f"ID:{track_id} {obj_name}"]
                if status:
                    label_parts.append(status)
                if distance > 0:
                    label_parts.append(f"{distance:.1f}m")
                if ttc < 30:
                    label_parts.append(f"TTC:{ttc:.1f}s")
                label_text = " ".join(label_parts)
                
                # 라벨 배경 + 텍스트
                text_size = cv2.getTextSize(label_text, cv2.FONT_HERSHEY_SIMPLEX, 0.5, 1)[0]
                cv2.rectangle(frame, 
                    (int(x1), int(y1) - text_size[1] - 10),
                    (int(x1) + text_size[0] + 5, int(y1)),
                    color, -1)
                cv2.putText(frame, label_text,
                    (int(x1) + 2, int(y1) - 5),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
                
                # ===== 위험 수집 (주차 차량 제외) =====
                if status == "접근중" and not is_parked:
                    if ttc < TTC_DANGER:
                        level = "danger"
                    elif ttc < TTC_WARNING:
                        level = "warning"
                    else:
                        level = "info"
                    dangers.append((obj_name, direction, level, ttc, avoid_dir, distance))
        
        # ===== 오래된 트래킹 제거 =====
        expired = [tid for tid, td in tracked_data.items() 
                   if frame_count - td.last_seen_frame > 30]
        for tid in expired:
            del tracked_data[tid]
        
        # ===== 가장 위험한 객체 경고 =====
        if dangers:
            # TTC가 가장 작은 것 우선
            dangers.sort(key=lambda x: x[3])
            top = dangers[0]
            obj_name, direction, level, ttc, avoid_dir, dist = top
            
            dist_text = f" {dist:.1f}m" if dist > 0 else ""
            
            if level == "danger":
                alert_text = f"{direction}{dist_text} {obj_name} 급접근! {avoid_dir}으로 피하세요!"
                alert_color = COLOR_DANGER
            elif level == "warning":
                alert_text = f"{direction}{dist_text} {obj_name} 접근중, 주의"
                alert_color = COLOR_WARNING
            else:
                alert_text = f"{direction}에서 {obj_name} 접근중"
                alert_color = COLOR_INFO
            
            # 경고 배너 표시
            cv2.rectangle(frame, (0, 0), (frame_width, 50), alert_color, -1)
            cv2.putText(frame, alert_text, (10, 35),
                cv2.FONT_HERSHEY_SIMPLEX, 0.8, (255, 255, 255), 2)
            
            # 음성 안내
            speak(alert_text, level)
        
        # ===== 하단 정보 표시 =====
        total_tracked = len([td for td in tracked_data.values() 
                           if frame_count - td.last_seen_frame < 5])
        parked_count = sum(1 for box in (results[0].boxes if results[0].boxes.id is not None else [])
                         if int(box.cls[0]) in VEHICLE_CLASS_IDS 
                         and int(box.id[0]) in tracked_data 
                         and tracked_data[int(box.id[0])].is_likely_parked)
        
        info_text = f"FPS: {fps:.0f} | Tracked: {total_tracked} | Parked: {parked_count} | TTS: {TTS_TYPE}"
        cv2.rectangle(frame, (0, frame_height - 30), (frame_width, frame_height), (0, 0, 0), -1)
        cv2.putText(frame, info_text, (10, frame_height - 10),
            cv2.FONT_HERSHEY_SIMPLEX, 0.5, (255, 255, 255), 1)
        
        # ===== 화면 출력 =====
        cv2.imshow("SafeWalk", frame)
        
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break
    
    cap.release()
    cv2.destroyAllWindows()
    print("SafeWalk 종료")


if __name__ == "__main__":
    main()