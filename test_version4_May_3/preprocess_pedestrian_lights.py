"""
SafeWalk: 서울시 보행등 데이터 전처리 스크립트

입력: A057_L.xlsx (서울시 신호등 부착대 원본 데이터)
출력: seoul_pedestrian_lights.json (앱 번들용 보행등 데이터)

처리 단계:
1. 보행등(SNLP_KND_CDE=007) + 양호 + 표시 + 지상 필터링
2. EPSG:2097 (중부원점 TM) → WGS84 (위경도) 좌표 변환
3. 부착대방향 정규화
4. JSON 출력
"""

import pandas as pd
from pyproj import Transformer
import json
import os

# ============================================================
# 1. 데이터 로드
# ============================================================
INPUT_PATH = '/mnt/user-data/uploads/A057_L.xlsx'
OUTPUT_PATH = '/home/claude/seoul_pedestrian_lights.json'

print("=" * 60)
print("SafeWalk 보행등 데이터 전처리")
print("=" * 60)

df = pd.read_excel(INPUT_PATH, dtype=str)
print(f"\n[1/5] 원본 데이터 로드: {len(df):,}개 부착대")

# ============================================================
# 2. 보행등 필터링
# ============================================================
# 정의서 기준:
#   SNLP_KND_CDE = '007'  ->  보행등
#   STAT_CDE     = '001'  ->  양호 상태
#   VIEW_CDE     = '002'  ->  지도 표시 대상
#   EVE_CDE      = '001'  ->  지상 시설물

ped = df[
    (df['SNLP_KND_CDE'] == '007') &
    (df['STAT_CDE'] == '001') &
    (df['VIEW_CDE'] == '002') &
    (df['EVE_CDE'] == '001')
].copy()

print(f"[2/5] 보행등(007) + 양호 + 표시 + 지상 필터링: {len(ped):,}개")

# ============================================================
# 3. 좌표/방향 누락 데이터 제거
# ============================================================
before = len(ped)
ped = ped.dropna(subset=['XCE', 'YCE', 'ASN_DRN'])
print(f"[3/5] 좌표/방향 누락 제거: {before:,} -> {len(ped):,}개 ({before-len(ped)}개 제외)")

# ============================================================
# 4. 좌표 변환: EPSG:5186 (Korea 2000 / Central Belt 2010) -> WGS84 (위경도)
# ============================================================
# 주의: 데이터 내 SDO_GEOMETRY의 2093은 Oracle 내부 SRID이며,
# 실제 좌표계는 EPSG:5186 (현재 한국 측량 표준)임을 검증으로 확인.
ped['XCE'] = ped['XCE'].astype(float)
ped['YCE'] = ped['YCE'].astype(float)
ped['ASN_DRN'] = ped['ASN_DRN'].astype(float)

# always_xy=True : 입출력을 (경도, 위도) 순서로 통일
transformer = Transformer.from_crs("EPSG:5186", "EPSG:4326", always_xy=True)
lng, lat = transformer.transform(ped['XCE'].values, ped['YCE'].values)
ped['lat'] = lat
ped['lng'] = lng

print(f"[4/5] EPSG:5186 -> WGS84 좌표 변환 완료")

# 변환 검증: 위경도가 서울 범위 안에 있는지 확인
in_seoul = (
    (ped['lat'] >= 37.3) & (ped['lat'] <= 37.8) &
    (ped['lng'] >= 126.6) & (ped['lng'] <= 127.3)
)
out_count = (~in_seoul).sum()
print(f"      서울 범위 밖 좌표: {out_count}개 " +
      ("[변환 확인 필요]" if out_count > 0 else "[OK]"))

# ============================================================
# 5. JSON 생성
# ============================================================
result = []
for _, row in ped.iterrows():
    result.append({
        "id": row['MGRNU'],
        "lat": round(row['lat'], 7),    # 약 1cm 정밀도
        "lng": round(row['lng'], 7),
        "heading": round(row['ASN_DRN'], 2),  # 부착대 방위각 0~360
        "count": int(row['SNLP_QUA']) if pd.notna(row['SNLP_QUA']) else 1,
    })

with open(OUTPUT_PATH, 'w', encoding='utf-8') as f:
    json.dump(result, f, ensure_ascii=False, separators=(',', ':'))

file_size_kb = os.path.getsize(OUTPUT_PATH) / 1024
print(f"[5/5] JSON 저장 완료: {OUTPUT_PATH}")
print(f"      파일 크기: {file_size_kb:,.1f} KB")

# ============================================================
# 결과 검증 샘플
# ============================================================
print("\n" + "=" * 60)
print("검증용 샘플 (구글맵에서 좌표 확인 권장)")
print("=" * 60)
for sample in result[:5]:
    print(f"  ID: {sample['id']}")
    print(f"    위치: ({sample['lat']}, {sample['lng']})")
    print(f"    방향: {sample['heading']}도")
    print(f"    구글맵: https://www.google.com/maps?q={sample['lat']},{sample['lng']}")
    print()

print(f"[최종] 보행등 수: {len(result):,}개")
