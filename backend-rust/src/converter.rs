use pyo3::prelude::*;
use pyo3::types::PyDict;
use serde_json::Value;

pub fn convert_file(data: &[u8], filename: &str) -> Result<Value, String> {
    // Extract file extension
    let ext = match filename.rfind('.') {
        Some(idx) => Some(filename[idx..].to_lowercase()),
        None => None,
    };
    let ext_str = ext.as_deref().unwrap_or("");

    Python::with_gil(|py| {
        let code = r#"
import io
from markitdown import MarkItDown

def convert_bytes_py(data, file_extension):
    ext = file_extension if file_extension else None
    try:
        md = MarkItDown(enable_plugins=False)
        res = md.convert_stream(io.BytesIO(data), file_extension=ext)
        text = (res.text_content or "").strip()
        title = res.title or "file"
        return {"title": title, "markdown": text}
    except Exception as e:
        return {"title": "file", "markdown": "", "error": str(e)}
"#;
        let locals = PyDict::new_bound(py);
        py.run_bound(code, None, Some(&locals))
            .map_err(|e| format!("Python run failed: {:?}", e))?;
        
        let func = locals.get_item("convert_bytes_py")
            .map_err(|e| format!("Get item failed: {:?}", e))?
            .ok_or_else(|| "Failed to find convert_bytes_py function".to_string())?;

        let res_py = func.call1((data, ext_str))
            .map_err(|e| format!("Python call failed: {:?}", e))?;
            
        let json_mod = py.import_bound("json")
            .map_err(|e| format!("Import json failed: {:?}", e))?;
            
        let list_str: String = json_mod.call_method1("dumps", (res_py,))
            .map_err(|e| format!("JSON dump failed: {:?}", e))?
            .extract()
            .map_err(|e| format!("JSON string extract failed: {:?}", e))?;
            
        let val: Value = serde_json::from_str(&list_str)
            .map_err(|e| format!("Serde parse failed: {:?}", e))?;
            
        Ok(val)
    })
}
pub fn test_markitdown_import() -> Result<(), String> {
    Python::with_gil(|py| {
        py.import_bound("markitdown")
            .map(|_| ())
            .map_err(|e| e.to_string())
    })
}
