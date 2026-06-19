#!/usr/bin/env python3
"""ผูกดวงโหราศาสตร์ไทย ใช้ Swiss Ephemeris คำนวณตำแหน่งดาว 10 ดวง + ลัคนา + ภพ 12

Usage:
    python cast_chart.py --date 2535-01-15 --time 08:30 --place กรุงเทพ
    python cast_chart.py --date 2535-01-15 --time 08:30 --lat 13.7563 --lon 100.5018
    python cast_chart.py --date 1992-01-15 --time 08:30 --place bangkok --ayanamsa lahiri
"""
import argparse
import json
import sys

try:
    import swisseph as swe
except ImportError:
    print("ERROR: ต้องติดตั้ง pyswisseph ก่อน → pip install pyswisseph", file=sys.stderr)
    sys.exit(1)


# พิกัดเมืองหลักของไทย (ละติจูด, ลองจิจูด)
THAI_CITIES = {
    "กรุงเทพ": (13.7563, 100.5018),
    "bangkok": (13.7563, 100.5018),
    "เชียงใหม่": (18.7883, 98.9853),
    "เชียงราย": (19.9105, 99.8406),
    "ขอนแก่น": (16.4419, 102.8359),
    "นครราชสีมา": (14.9799, 102.0978),
    "อุดรธานี": (17.4138, 102.7872),
    "ภูเก็ต": (7.8804, 98.3923),
    "สงขลา": (7.1899, 100.5954),
    "ชลบุรี": (13.3611, 100.9847),
    "นนทบุรี": (13.8622, 100.5134),
    "ปทุมธานี": (14.0208, 100.5250),
    "พิษณุโลก": (16.8298, 100.2654),
    "นครสวรรค์": (15.7047, 100.1372),
    "อยุธยา": (14.3692, 100.5876),
    "กระบี่": (8.0863, 98.9063),
    "กาญจนบุรี": (14.0228, 99.5328),
    "กาฬสินธุ์": (16.4385, 103.5061),
    "กำแพงเพชร": (16.4828, 99.5227),
    "จันทบุรี": (12.6113, 102.1038),
    "ฉะเชิงเทรา": (13.6904, 101.0779),
    "ชัยนาท": (15.1852, 100.1251),
    "ชัยภูมิ": (15.8068, 102.0315),
    "ชุมพร": (10.4930, 99.1800),
    "ตรัง": (7.5594, 99.6114),
    "ตราด": (12.2428, 102.5175),
    "ตาก": (16.8839, 99.1258),
    "นครนายก": (14.2069, 101.2131),
    "นครปฐม": (13.8199, 100.0622),
    "นครพนม": (17.3920, 104.7696),
    "นครศรีธรรมราช": (8.4304, 99.9631),
    "นราธิวาส": (6.4255, 101.8253),
    "น่าน": (18.7883, 100.7760),
    "บึงกาฬ": (18.3609, 103.6464),
    "บุรีรัมย์": (14.9930, 103.1029),
    "ประจวบคีรีขันธ์": (11.8124, 99.7973),
    "ปราจีนบุรี": (14.0509, 101.3727),
    "ปัตตานี": (6.8695, 101.2505),
    "พะเยา": (19.1665, 99.9019),
    "พังงา": (8.4501, 98.5255),
    "พัทลุง": (7.6167, 100.0740),
    "พิจิตร": (16.4419, 100.3488),
    "เพชรบุรี": (13.1119, 99.9447),
    "เพชรบูรณ์": (16.4190, 101.1606),
    "แพร่": (18.1446, 100.1403),
    "มหาสารคาม": (16.1851, 103.3026),
    "มุกดาหาร": (16.5453, 104.7235),
    "แม่ฮ่องสอน": (19.3020, 97.9654),
    "ยโสธร": (15.7926, 104.1453),
    "ยะลา": (6.5411, 101.2804),
    "ร้อยเอ็ด": (16.0538, 103.6520),
    "ระนอง": (9.9529, 98.6085),
    "ระยอง": (12.6814, 101.2816),
    "ราชบุรี": (13.5283, 99.8134),
    "ลพบุรี": (14.7995, 100.6534),
    "ลำปาง": (18.2888, 99.4909),
    "ลำพูน": (18.5745, 99.0087),
    "เลย": (17.4860, 101.7223),
    "ศรีสะเกษ": (15.1186, 104.3220),
    "สกลนคร": (17.1546, 104.1348),
    "สตูล": (6.6238, 100.0674),
    "สมุทรปราการ": (13.5991, 100.5998),
    "สมุทรสงคราม": (13.4098, 100.0023),
    "สมุทรสาคร": (13.5475, 100.2744),
    "สระแก้ว": (13.8240, 102.0646),
    "สระบุรี": (14.5289, 100.9101),
    "สิงห์บุรี": (14.8936, 100.3967),
    "สุโขทัย": (17.0078, 99.8230),
    "สุพรรณบุรี": (14.4745, 100.1177),
    "สุราษฎร์ธานี": (9.1382, 99.3215),
    "สุรินทร์": (14.8829, 103.4937),
    "หนองคาย": (17.8783, 102.7413),
    "หนองบัวลำภู": (17.2218, 102.4260),
    "อ่างทอง": (14.5896, 100.4551),
    "อำนาจเจริญ": (15.8657, 104.6258),
    "อุตรดิตถ์": (17.6201, 100.0993),
    "อุทัยธานี": (15.3835, 100.0246),
    "อุบลราชธานี": (15.2287, 104.8564),
    "พระนครศรีอยุธยา": (14.3692, 100.5876),
}

# ดาวพระเคราะห์ในระบบไทย (เลขไทย: ดาว, swe_id)
PLANETS_THAI = [
    ("๑", "อาทิตย์", swe.SUN),
    ("๒", "จันทร์", swe.MOON),
    ("๓", "อังคาร", swe.MARS),
    ("๔", "พุธ", swe.MERCURY),
    ("๕", "พฤหัสบดี", swe.JUPITER),
    ("๖", "ศุกร์", swe.VENUS),
    ("๗", "เสาร์", swe.SATURN),
    ("๘", "ราหู", swe.MEAN_NODE),  # จุดโหนดเฉลี่ย
    ("๐", "มฤตยู", swe.URANUS),
]

# ราศี 12 ราศี (ตามลำดับ 0-11)
RASI_NAMES = ["เมษ", "พฤษภ", "เมถุน", "กรกฎ", "สิงห์", "กันย์",
              "ตุล", "พิจิก", "ธนู", "มังกร", "กุมภ์", "มีน"]

# ดาวเกษตรประจำราศี (index ของ PLANETS_THAI ที่ครองราศีนั้น)
RASI_LORDS = {
    "เมษ": "อังคาร", "พฤษภ": "ศุกร์", "เมถุน": "พุธ", "กรกฎ": "จันทร์",
    "สิงห์": "อาทิตย์", "กันย์": "พุธ", "ตุล": "ศุกร์", "พิจิก": "อังคาร",
    "ธนู": "พฤหัสบดี", "มังกร": "เสาร์", "กุมภ์": "เสาร์", "มีน": "พฤหัสบดี"
}

# ตารางมาตรฐานดาว: เกษตร, อุจ(ราศี, องศา), นิจ(ราศี, องศา)
PLANET_STANDARDS = {
    "อาทิตย์":  {"เกษตร": ["สิงห์"], "อุจ": ("เมษ", 10), "นิจ": ("ตุล", 10)},
    "จันทร์":   {"เกษตร": ["กรกฎ"], "อุจ": ("พฤษภ", 3), "นิจ": ("พิจิก", 3)},
    "อังคาร":   {"เกษตร": ["เมษ", "พิจิก"], "อุจ": ("มังกร", 28), "นิจ": ("กรกฎ", 28)},
    "พุธ":       {"เกษตร": ["เมถุน", "กันย์"], "อุจ": ("กันย์", 15), "นิจ": ("มีน", 15)},
    "พฤหัสบดี": {"เกษตร": ["ธนู", "มีน"], "อุจ": ("กรกฎ", 5), "นิจ": ("มังกร", 5)},
    "ศุกร์":     {"เกษตร": ["พฤษภ", "ตุล"], "อุจ": ("มีน", 27), "นิจ": ("กันย์", 27)},
    "เสาร์":     {"เกษตร": ["มังกร", "กุมภ์"], "อุจ": ("ตุล", 20), "นิจ": ("เมษ", 20)},
}

# ชื่อภพ 12 ภพ
BHAVA_NAMES = ["ตนุ", "กฎุมพะ", "สหัชชะ", "พันธุ", "ปุตตะ", "อริ",
               "ปัตนิ", "มรณะ", "ศุภะ", "กัมมะ", "ลาภะ", "วินาสนะ"]


def parse_date_thai_or_western(date_str: str):
    """รับวันที่ในรูป YYYY-MM-DD โดยถ้า YYYY > 2400 ถือว่าเป็น พ.ศ. แล้วแปลงเป็น ค.ศ."""
    year, month, day = map(int, date_str.split("-"))
    if year > 2400:
        year -= 543  # แปลง พ.ศ. → ค.ศ.
    return year, month, day


def degrees_to_rasi(longitude: float):
    """แปลงองศาสุริยปฏิทิน (0-360) เป็น (ราศี, องศาในราศี)"""
    longitude = longitude % 360
    rasi_index = int(longitude // 30)
    deg_in_rasi = longitude - (rasi_index * 30)
    return RASI_NAMES[rasi_index], deg_in_rasi, rasi_index


def evaluate_standard(planet_name: str, rasi: str, deg_in_rasi: float):
    """ประเมินว่าดาวอยู่ในมาตรฐานใด (เกษตร/อุจ/มหาอุจ/นิจ/ประ/ปกติ)"""
    if planet_name not in PLANET_STANDARDS:
        return "—"
    std = PLANET_STANDARDS[planet_name]
    if rasi in std["เกษตร"]:
        return "เกษตร"
    uj_rasi, uj_deg = std["อุจ"]
    if rasi == uj_rasi:
        return "มหาอุจ" if abs(deg_in_rasi - uj_deg) < 1 else "อุจ"
    nij_rasi, _nij_deg = std["นิจ"]
    if rasi == nij_rasi:
        return "นิจ"
    # ปรเกษตร = ราศีตรงข้ามกับเกษตร
    rasi_idx = RASI_NAMES.index(rasi)
    opp_idx = (rasi_idx + 6) % 12
    opposite = RASI_NAMES[opp_idx]
    if opposite in std["เกษตร"]:
        return "ประ"
    return "ปกติ"


def cast_chart(date_str: str, time_str: str, lat: float, lon: float,
               ayanamsa: str = "tropical", tz_offset: float = 7.0):
    """คำนวณดวงชะตา return dict พร้อมข้อมูลครบ"""
    year, month, day = parse_date_thai_or_western(date_str)
    hour, minute = map(int, time_str.split(":"))

    # คำนวณ Julian Day (UT)
    decimal_hour = hour + minute / 60.0 - tz_offset
    jd_ut = swe.julday(year, month, day, decimal_hour)

    # ตั้งค่า ayanamsa
    flags = swe.FLG_SPEED
    if ayanamsa.lower() == "lahiri":
        swe.set_sid_mode(swe.SIDM_LAHIRI)
        flags |= swe.FLG_SIDEREAL
    # ถ้า tropical ไม่ต้องตั้ง — เป็น default

    # คำนวณตำแหน่งดาว
    planets_out = []
    for thai_num, name, swe_id in PLANETS_THAI:
        result, _ = swe.calc_ut(jd_ut, swe_id, flags)
        lon_deg = result[0]
        rasi, deg_in_rasi, _ = degrees_to_rasi(lon_deg)
        standard = evaluate_standard(name, rasi, deg_in_rasi)
        planets_out.append({
            "เลข": thai_num,
            "ดาว": name,
            "ราศี": rasi,
            "องศา": round(deg_in_rasi, 2),
            "longitude": round(lon_deg, 4),
            "มาตรฐาน": standard,
        })

    # เกตุ = ตรงข้ามราหู
    rahu = planets_out[7]  # ราหู
    ketu_lon = (rahu["longitude"] + 180) % 360
    ketu_rasi, ketu_deg, _ = degrees_to_rasi(ketu_lon)
    planets_out.append({
        "เลข": "๙",
        "ดาว": "เกตุ",
        "ราศี": ketu_rasi,
        "องศา": round(ketu_deg, 2),
        "longitude": round(ketu_lon, 4),
        "มาตรฐาน": "—",
    })

    # คำนวณลัคนา (Ascendant)
    _houses, ascmc = swe.houses(jd_ut, lat, lon, b'P')  # Placidus
    lakkana_lon = ascmc[0]
    if ayanamsa.lower() == "lahiri":
        lakkana_lon = (lakkana_lon - swe.get_ayanamsa_ut(jd_ut)) % 360
    lakkana_rasi, lakkana_deg, lakkana_idx = degrees_to_rasi(lakkana_lon)
    lakkana_lord = RASI_LORDS[lakkana_rasi]

    # วางภพ 12 จากลัคนา
    bhava_map = {}
    for i in range(12):
        rasi_index = (lakkana_idx + i) % 12
        bhava_map[BHAVA_NAMES[i]] = {
            "ภพที่": i + 1,
            "ราศี": RASI_NAMES[rasi_index],
            "ดาวสถิต": [p["ดาว"] for p in planets_out if p["ราศี"] == RASI_NAMES[rasi_index]]
        }

    return {
        "ข้อมูลเกิด": {
            "วันเกิด_คศ": f"{year}-{month:02d}-{day:02d}",
            "เวลาเกิด": time_str,
            "ละติจูด": lat,
            "ลองจิจูด": lon,
            "ระบบ": "Sayana (Tropical)" if ayanamsa == "tropical" else "Nirayana (Lahiri)"
        },
        "ลัคนา": {
            "ราศี": lakkana_rasi,
            "องศา": round(lakkana_deg, 2),
            "ดาวเจ้าเรือน(ลัคนาธิปติ)": lakkana_lord
        },
        "ดาว": planets_out,
        "ภพ": bhava_map
    }


def main():
    p = argparse.ArgumentParser(description="ผูกดวงโหราศาสตร์ไทย")
    p.add_argument("--date", required=True, help="วันเกิด YYYY-MM-DD (พ.ศ. หรือ ค.ศ.)")
    p.add_argument("--time", required=True, help="เวลาเกิด HH:MM (24 ชม.)")
    p.add_argument("--place", help="จังหวัด (ภาษาไทยหรือ bangkok)")
    p.add_argument("--lat", type=float, help="ละติจูด (ถ้าไม่ระบุ --place)")
    p.add_argument("--lon", type=float, help="ลองจิจูด")
    p.add_argument("--ayanamsa", default="tropical", choices=["tropical", "lahiri"])
    p.add_argument("--tz", type=float, default=7.0, help="timezone offset (default 7.0 สำหรับไทย)")
    args = p.parse_args()

    if args.place:
        key = args.place.strip().lower() if args.place.encode().isascii() else args.place.strip()
        if key not in THAI_CITIES:
            print(f"ERROR: ไม่รู้จักเมือง '{args.place}' กรุณาใส่ --lat --lon เอง", file=sys.stderr)
            print(f"เมืองที่รองรับ: {list(THAI_CITIES.keys())}", file=sys.stderr)
            sys.exit(1)
        lat, lon = THAI_CITIES[key]
    elif args.lat is not None and args.lon is not None:
        lat, lon = args.lat, args.lon
    else:
        print("ERROR: ต้องระบุ --place หรือ --lat --lon", file=sys.stderr)
        sys.exit(1)

    result = cast_chart(args.date, args.time, lat, lon, args.ayanamsa, args.tz)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
