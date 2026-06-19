"""markitdown-svc — platform file→Markdown service for ปิ่น.

Converts uploaded files (PDF, Word, Excel, PowerPoint, HTML, CSV, audio…) to
Markdown text so ปิ่น can summarise + remember them. Runs as a separate service
(like news-reporter / lakkana); the proxy forwards uploads here.

Privacy note: file bytes are processed in-memory and NOT persisted. Audio
transcription may use an online recogniser depending on markitdown's backend.

Run:  uv run uvicorn main:app --host 0.0.0.0 --port 8093
"""

from __future__ import annotations

import io

from fastapi import FastAPI, File, UploadFile
from markitdown import MarkItDown

app = FastAPI(title="markitdown-svc")
_md = MarkItDown(enable_plugins=False)


@app.get("/health")
def health() -> dict:
    return {"ok": True}


@app.post("/convert")
async def convert(file: UploadFile = File(...)) -> dict:
    """File → Markdown. Returns {title, markdown} or {error}."""
    data = await file.read()
    name = file.filename or "file"
    try:
        res = _md.convert_stream(io.BytesIO(data), file_extension=_ext(name))
        text = (res.text_content or "").strip()
        if not text:
            return {"title": name, "markdown": "", "error": "อ่านเนื้อหาไม่ได้"}
        return {"title": res.title or name, "markdown": text}
    except Exception as e:  # noqa: BLE001
        return {"title": name, "markdown": "", "error": f"แปลงไฟล์ไม่ได้: {e}"}


def _ext(name: str) -> str | None:
    i = name.rfind(".")
    return name[i:].lower() if i >= 0 else None
