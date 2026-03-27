# test_tracking.py
from ultralytics import YOLO
import cv2

model = YOLO("yolov8n.pt")

# 각 물체의 이전 프레임 바운딩 박스 크기 저장
prev_sizes = {}

TARGET_CLASSES = {0: "사람", 1: "자전거", 2: "자동차", 3: "오토바이", 5: "버스", 7: "트럭"}

cap = cv2.VideoCapture(0)

while cap.isOpened():
    ret, frame = cap.read()
    if not ret:
        break
    
    # track()으로 변경 — 이것만으로 트래킹 활성화
    results = model.track(frame, tracker="bytetrack.yaml", conf=0.5, persist=True)
    
    if results[0].boxes.id is not None:
        for box in results[0].boxes:
            cls_id = int(box.cls[0])
            
            if cls_id not in TARGET_CLASSES:
                continue
            
            # 트래킹 ID (같은 물체는 같은 ID 유지)
            track_id = int(box.id[0])
            
            # 바운딩 박스 면적 계산
            x1, y1, x2, y2 = box.xyxy[0].tolist()
            current_size = (x2 - x1) * (y2 - y1)
            
            # 방향 판단
            frame_width = frame.shape[1]
            center_x = (x1 + x2) / 2
            if center_x < frame_width / 3:
                direction = "왼쪽"
            elif center_x < frame_width * 2 / 3:
                direction = "정면"
            else:
                direction = "오른쪽"
            
            obj_name = TARGET_CLASSES[cls_id]
            
            # 이전 프레임과 크기 비교 → 접근/이탈 판단
            if track_id in prev_sizes:
                size_change = current_size - prev_sizes[track_id]
                ratio = size_change / prev_sizes[track_id]
                
                if ratio > 0.05:      # 5% 이상 커짐
                    status = "접근 중"
                    print(f"⚠️ {direction}에서 {obj_name} {status}! (ID:{track_id})")
                elif ratio < -0.05:   # 5% 이상 작아짐
                    status = "멀어지는 중"
                else:
                    status = "정지"
            else:
                status = "감지됨"
                print(f"📍 {direction}에 {obj_name} {status} (ID:{track_id})")
            
            # 현재 크기 저장
            prev_sizes[track_id] = current_size
    
    annotated = results[0].plot()
    cv2.imshow("YOLO Tracking", annotated)
    
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()