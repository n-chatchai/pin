"""Waitlist early-access email — warm ปิ่น voice, concise, one personalised
use-case block + a painpoint question + an iOS/Android question. Recipients
reply (captured into the admin mail thread).

`classify()` maps a signup's free-text `use` to a persona; `build()` returns
(subject, text, html) ready to send.
"""
from __future__ import annotations

LOGO_URL = "https://pin.tokens2.io/assets/pin-icon.png"

# persona → (subject, use-case block, insight question)
PERSONAS: dict[str, dict] = {
    "study": {
        "subject": "ปิ่นพร้อมช่วยคุณติวแล้วค่ะ",
        "block": "คุณบอกว่าอยากให้ปิ่นช่วยเรื่องเรียน — ถามปิ่นว่า “อธิบายเรื่องนี้"
                 "ให้เข้าใจง่าย” แล้วปิ่นย่อยให้ทีละขั้น สรุปโน้ต และเตือนวันส่งงานค่ะ",
        "q": "เรื่องเรียนอะไรที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงคะ?",
    },
    "home": {
        "subject": "ให้ปิ่นช่วยจำเรื่องเล็ก ๆ ในบ้านนะคะ",
        "block": "คุณบอกว่าอยากให้ปิ่นช่วยดูแลเรื่องในบ้าน — ปิ่นคอยเตือนกินยา "
                 "จดของที่ต้องซื้อ เช็กอากาศ และจำเรื่องที่คุณไม่อยากลืมให้ค่ะ",
        "q": "เรื่องในแต่ละวันอะไรที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงคะ?",
    },
    "creative": {
        "subject": "ปิ่นอยากเป็นเพื่อนงานครีเอทีฟของคุณค่ะ",
        "block": "คุณบอกว่าอยากให้ปิ่นช่วยงานครีเอทีฟ — บอกปิ่นว่าอยากได้แบบไหน "
                 "ปิ่นวาดให้ ร่างแคปชันให้ คิดไอเดียเป็นเพื่อนคุณ ทุกชิ้นเป็นของคุณค่ะ",
        "q": "ขั้นตอนไหนในงานครีเอทีฟที่กินเวลาหรือกวนใจที่สุด แล้วอยากให้ปิ่นช่วยยังไงคะ?",
    },
    "sme": {
        "subject": "ปิ่นกำลังเตรียมมาช่วยร้านคุณค่ะ",
        "block": "คุณบอกว่าอยากให้ปิ่นช่วยดูแลร้าน — ส่วนนี้ (สรุปยอดขาย + ตอบแชต"
                 "ลูกค้าผ่าน LINE) เรากำลังตั้งใจทำอยู่ จะตามมาให้เร็วที่สุด "
                 "ระหว่างนี้ปิ่นช่วยเรื่องอื่นในชีวิตได้เลยค่ะ",
        "q": "เรื่องไหนในการดูแลร้านที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงคะ?",
    },
    "work": {
        "subject": "ปิ่นกำลังเตรียมมาช่วยงานคุณค่ะ",
        "block": "คุณบอกว่าอยากให้ปิ่นช่วยจัดการงาน — ส่วนนี้ (สรุปอีเมล นัดประชุม "
                 "ทวงงาน) เรากำลังตั้งใจทำอยู่ จะตามมาให้เร็วที่สุด ระหว่างนี้ปิ่น"
                 "ช่วยเรื่องอื่นในชีวิตได้เลยค่ะ",
        "q": "เรื่องไหนในการทำงานที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงคะ?",
    },
    "default": {
        "subject": "ปิ่นใกล้พร้อมดูแลคุณแล้วค่ะ",
        "block": "ปิ่นช่วยคุณคิด วางแผน และดูแลเรื่องเล็ก ๆ ในแต่ละวัน ถามได้ทุกเรื่อง "
                 "คุยได้ทั้งวันค่ะ",
        "q": "เรื่องในแต่ละวันอะไรที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงคะ?",
    },
}

_RULES = [
    ("study", ("ติว", "เรียน", "ทบทวน", "บทเรียน")),
    ("home", ("บ้าน", "เตือนความจำ", "เตือน")),
    ("creative", ("ครีเอ", "วาด", "แคปชัน", "ไอเดีย")),
    ("sme", ("ร้าน", "ยอดขาย", "ขาย", "ลูกค้า")),
    ("work", ("จัดการงาน", "อีเมล", "ประชุม", "งาน")),
]


def classify(use: str) -> str:
    u = use or ""
    for persona, kws in _RULES:
        if any(k in u for k in kws):
            return persona
    return "default"


_INTRO = ("สวัสดีค่ะ ขอบคุณที่ลงชื่อไว้กับปิ่นนะคะ เราใกล้เปิดให้ใช้แล้ว "
          "เลยอยากบอกคุณก่อนใคร")
_PRIVACY = ("ปิ่นทำงานอยู่บนเครื่องของคุณ ทุกข้อความเข้ารหัสลับ มีแค่คุณที่อ่านได้ "
            "แม้แต่เราก็เปิดดูไม่ได้ ความเป็นส่วนตัวคือเรื่องแรกที่เราดูแล ไม่ใช่ของแถม")
_PLATFORM = ("แล้วตอนนี้คุณใช้ iPhone (iOS) หรือ Android คะ? จะได้ส่งลิงก์ที่ใช่"
             "ให้คุณก่อน")
_TAIL = ("ตอบกลับอีเมลนี้ได้เลยค่ะ แค่ประโยคเดียวก็มีค่ากับเรามาก ทุกคำตอบช่วยให้"
         "ปิ่นเป็นของคุณจริง ๆ")
_CLOSE = "พอพร้อม เราจะส่งลิงก์ให้คุณก่อนใครทันที"
_SIGN = "แล้วเจอกันเร็ว ๆ นี้นะคะ\n— ปิ่น"


def build(use: str) -> tuple[str, str, str]:
    """Return (subject, text_body, html_body) for a signup's `use` text."""
    p = PERSONAS.get(classify(use), PERSONAS["default"])
    paras = [_INTRO, _PRIVACY, p["block"], f"ก่อนเปิดตัว ขอถามสั้น ๆ ค่ะ:\n{p['q']}",
             _PLATFORM, _TAIL, _CLOSE, _SIGN]
    text = "\n\n".join(paras)
    body_html = "".join(
        f'<p style="margin:0 0 15px;line-height:1.75">{para.replace(chr(10), "<br>")}</p>'
        for para in paras)
    html = (
        '<div style="font-family:\'Sarabun\',\'Leelawadee UI\',sans-serif;'
        'color:#2E2A24;max-width:560px;margin:0 auto;padding:28px 24px;'
        'background:#FAF8F2">'
        f'<img src="{LOGO_URL}" width="46" height="46" alt="ปิ่น" '
        'style="border-radius:12px;display:block;margin:0 0 20px">'
        + body_html +
        '<p style="font-size:12px;color:#9A8F7E;margin-top:22px;'
        'border-top:1px solid #E7DCCB;padding-top:14px">'
        'ไม่อยากรับอีเมลจากเรา ตอบกลับว่า “เลิกรับ” ได้เลยค่ะ</p></div>')
    return p["subject"], text, html
