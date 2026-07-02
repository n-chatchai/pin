use std::collections::HashMap;

const LOGO_URL: &str = "https://pin.tokens2.io/assets/pin-icon.png";

struct Persona {
    subject: &'static str,
    block: &'static str,
    q: &'static str,
}

fn get_personas() -> HashMap<&'static str, Persona> {
    let mut m = HashMap::new();
    m.insert("study", Persona {
        subject: "ปิ่นพร้อมช่วยคุณติวแล้ว",
        block: "คุณบอกว่าอยากให้ปิ่นช่วยเรื่องเรียน — ถามปิ่นว่า “อธิบายเรื่องนี้ให้เข้าใจง่าย” แล้วปิ่นย่อยให้ทีละขั้น สรุปโน้ต และเตือนวันส่งงานให้",
        q: "เรื่องเรียนอะไรที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงดี?",
    });
    m.insert("home", Persona {
        subject: "ให้ปิ่นช่วยจำเรื่องเล็ก ๆ ในบ้านนะ",
        block: "คุณบอกว่าอยากให้ปิ่นช่วยดูแลเรื่องในบ้าน — ปิ่นคอยเตือนกินยา จดของที่ต้องซื้อ เช็กอากาศ และจำเรื่องที่คุณไม่อยากลืมให้",
        q: "เรื่องในแต่ละวันอะไรที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงดี?",
    });
    m.insert("creative", Persona {
        subject: "ปิ่นอยากเป็นเพื่อนงานครีเอทีฟของคุณ",
        block: "คุณบอกว่าอยากให้ปิ่นช่วยงานครีเอทีฟ — บอกปิ่นว่าอยากได้แบบไหน ปิ่นวาดให้ ร่างแคปชันให้ คิดไอเดียเป็นเพื่อนคุณ ทุกชิ้นเป็นของคุณ",
        q: "ขั้นตอนไหนในงานครีเอทีฟที่กินเวลาหรือกวนใจที่สุด แล้วอยากให้ปิ่นช่วยยังไงดี?",
    });
    m.insert("sme", Persona {
        subject: "ปิ่นกำลังเตรียมมาช่วยร้านคุณ",
        block: "คุณบอกว่าอยากให้ปิ่นช่วยดูแลร้าน — ส่วนนี้ (สรุปยอดขาย + ตอบแชตลูกค้าผ่าน LINE) เรากำลังตั้งใจทำอยู่ จะตามมาให้เร็วที่สุด ระหว่างนี้ปิ่นช่วยเรื่องอื่นในชีวิตได้เลย",
        q: "เรื่องไหนในการดูแลร้านที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงดี?",
    });
    m.insert("work", Persona {
        subject: "ปิ่นกำลังเตรียมมาช่วยงานคุณ",
        block: "คุณบอกว่าอยากให้ปิ่นช่วยจัดการงาน — ส่วนนี้ (สรุปอีเมล นัดประชุม ทวงงาน) เรากำลังตั้งใจทำอยู่ จะตามมาให้เร็วที่สุด ระหว่างนี้ปิ่นช่วยเรื่องอื่นในชีวิตได้เลย",
        q: "เรื่องไหนในการทำงานที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงดี?",
    });
    m.insert(
        "default",
        Persona {
            subject: "ปิ่นใกล้พร้อมดูแลคุณแล้ว",
            block: "ปิ่นช่วยคุณคิด วางแผน และดูแลเรื่องเล็ก ๆ ในแต่ละวัน ถามได้ทุกเรื่อง คุยได้ทั้งวัน",
            q: "เรื่องในแต่ละวันอะไรที่กินเวลาหรือกวนใจคุณที่สุด แล้วอยากให้ปิ่นช่วยยังไงดี?",
        },
    );
    m
}

pub fn classify(use_text: &str) -> &'static str {
    let rules = [
        ("study", vec!["ติว", "เรียน", "ทบทวน", "บทเรียน"]),
        ("home", vec!["บ้าน", "เตือนความจำ", "เตือน"]),
        ("creative", vec!["ครีเอ", "วาด", "แคปชัน", "ไอเดีย"]),
        ("sme", vec!["ร้าน", "ยอดขาย", "ขาย", "ลูกค้า"]),
        ("work", vec!["จัดการงาน", "อีเมล", "ประชุม", "งาน"]),
    ];
    for (persona, kws) in rules {
        if kws.iter().any(|k| use_text.contains(k)) {
            return persona;
        }
    }
    "default"
}

pub fn build(use_text: &str) -> (String, String, String) {
    let personas = get_personas();
    let cls = classify(use_text);
    let p = personas
        .get(cls)
        .unwrap_or(personas.get("default").unwrap());

    let intro = "สวัสดี ขอบคุณที่ลงชื่อไว้กับปิ่นนะ เราใกล้เปิดให้ใช้แล้ว เลยอยากบอกคุณก่อนใคร";
    let privacy = "ปิ่นทำงานอยู่บนเครื่องของคุณ ทุกข้อความเข้ารหัสลับ มีแค่คุณที่อ่านได้ แม้แต่เราก็เปิดดูไม่ได้ ความเป็นส่วนตัวคือเรื่องแรกที่เราดูแล ไม่ใช่ของแถม";
    let q_block = format!("ก่อนเปิดตัว ขอถามสั้น ๆ:\n{}", p.q);
    let platform = "แล้วตอนนี้คุณใช้ iPhone (iOS) หรือ Android? จะได้ส่งลิงก์ที่ใช่ให้คุณก่อน";
    let tail = "ตอบกลับอีเมลนี้ได้เลย แค่ประโยคเดียวก็มีค่ากับเรามาก ทุกคำตอบช่วยให้ปิ่นเป็นของคุณจริง ๆ";
    let close = "พอพร้อม เราจะส่งลิงก์ให้คุณก่อนใครทันที";
    let sign = "แล้วเจอกันเร็ว ๆ นี้นะ\n— ปิ่น";

    let paras = vec![
        intro, privacy, p.block, &q_block, platform, tail, close, sign,
    ];

    let text = paras.join("\n\n");

    let mut body_html = String::new();
    for para in &paras {
        body_html.push_str(&format!(
            "<p style=\"margin:0 0 15px;line-height:1.75\">{}</p>",
            para.replace('\n', "<br>")
        ));
    }

    let html = format!(
        "<div style=\"font-family:'Sarabun','Leelawadee UI',sans-serif;\
         color:#2E2A24;max-width:560px;margin:0 auto;padding:28px 24px;\
         background:#FAF8F2\">\
         <img src=\"{}\" width=\"46\" height=\"46\" alt=\"ปิ่น\" \
         style=\"border-radius:12px;display:block;margin:0 0 20px\">{}</div>",
        LOGO_URL, body_html
    );

    (p.subject.to_string(), text, html)
}
