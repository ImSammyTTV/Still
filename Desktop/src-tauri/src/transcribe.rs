//! Transcribe Recording on Windows and Linux: the video editor sends the recording's sound, a few minutes at a time
//! as small mono WAV files, and this asks the AI service chosen in Settings → AI to write down what was said, with
//! timings. It uses the user's own key and sends the sound only when asked. The Mac app transcribes on the Mac
//! itself instead.
use serde::Serialize;
use serde_json::{json, Value};

/// One stretch of speech, in seconds from the start of the piece of sound it came from.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Segment { pub start: f64, pub end: f64, pub text: String }

fn http() -> Result<reqwest::Client, String> {
    if rustls::crypto::CryptoProvider::get_default().is_none() { let _ = rustls::crypto::ring::default_provider().install_default(); }
    reqwest::Client::builder().timeout(std::time::Duration::from_secs(180)).build().map_err(|e| e.to_string())
}

/// Stretches with words in them, in order, each at least a moment long. Anything without a usable time is dropped.
fn tidy(mut segments: Vec<Segment>) -> Vec<Segment> {
    segments.retain(|s| !s.text.trim().is_empty() && s.start.is_finite() && s.end.is_finite() && s.start >= 0.0);
    for s in segments.iter_mut() { s.text = s.text.trim().to_string(); if s.end < s.start + 0.3 { s.end = s.start + 0.3; } }
    segments.sort_by(|a, b| a.start.total_cmp(&b.start));
    segments
}

// ---- OpenAI ----------------------------------------------------------------------------------------

const OPENAI_URL: &str = "https://api.openai.com/v1/audio/transcriptions";
pub const OPENAI_MODEL: &str = "whisper-1";

/// The form OpenAI's transcription endpoint takes: the model, timed segments as the answer, and the WAV file.
pub fn multipart(boundary: &str, wav: &[u8]) -> Vec<u8> {
    let mut body = Vec::with_capacity(wav.len() + 512);
    for (name, value) in [("model", OPENAI_MODEL), ("response_format", "verbose_json")] {
        body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n").as_bytes());
    }
    body.extend_from_slice(format!("--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sound.wav\"\r\nContent-Type: audio/wav\r\n\r\n").as_bytes());
    body.extend_from_slice(wav);
    body.extend_from_slice(format!("\r\n--{boundary}--\r\n").as_bytes());
    body
}

/// The timed stretches in a verbose_json answer, or its whole text as one stretch if it came without them.
pub fn openai_segments(status: u16, response: &Value, length: f64) -> Result<Vec<Segment>, String> {
    if let Some(error) = crate::describe::openai_error(status, response) { return Err(error); }
    let mut segments: Vec<Segment> = response["segments"].as_array().map(|list| list.iter().map(|s| Segment {
        start: s["start"].as_f64().unwrap_or(f64::NAN), end: s["end"].as_f64().unwrap_or(f64::NAN), text: s["text"].as_str().unwrap_or("").to_string(),
    }).collect()).unwrap_or_default();
    if segments.is_empty() {
        if let Some(text) = response["text"].as_str().filter(|t| !t.trim().is_empty()) { segments.push(Segment { start: 0.0, end: length.max(0.3), text: text.into() }); }
    }
    Ok(tidy(segments))
}

async fn with_openai(key: &str, wav: Vec<u8>, length: f64) -> Result<Vec<Segment>, String> {
    let boundary = format!("still-{}", uuid::Uuid::new_v4().simple());
    let body = multipart(&boundary, &wav);
    let client = http()?;
    let send = || client.post(OPENAI_URL).bearer_auth(key.trim()).header("content-type", format!("multipart/form-data; boundary={boundary}")).body(body.clone()).send();
    let mut res = send().await.map_err(|e| format!("Couldn’t reach ChatGPT: {e}"))?;
    let mut status = res.status().as_u16();
    let mut response: Value = res.json().await.unwrap_or(Value::Null);
    if crate::describe::openai_busy(status, &response) {
        tokio::time::sleep(std::time::Duration::from_millis(1500)).await;
        res = send().await.map_err(|e| format!("Couldn’t reach ChatGPT: {e}"))?;
        status = res.status().as_u16();
        response = res.json().await.unwrap_or(Value::Null);
    }
    openai_segments(status, &response, length)
}

// ---- Gemini ----------------------------------------------------------------------------------------

const GEMINI_URL: &str = "https://generativelanguage.googleapis.com/v1beta/models";
pub const GEMINI_PROMPT: &str = "Transcribe the speech in this recording word for word, in the language spoken. Answer only with a JSON array of objects {\"start\": seconds, \"end\": seconds, \"text\": \"…\"}, one per sentence or short phrase, in order, with times measured from the start of the audio. If nobody speaks, answer [].";

pub fn gemini_body(base64: &str) -> Value {
    json!({ "contents": [{ "parts": [{ "text": GEMINI_PROMPT }, { "inline_data": { "mime_type": "audio/wav", "data": base64 } }] }],
        "generationConfig": { "temperature": 0.0, "responseMimeType": "application/json" } })
}

/// The stretches in Gemini's answer. Its text is a JSON array, sometimes wrapped in a code fence; times can come as
/// numbers or as "m:ss" strings.
pub fn gemini_segments(response: &Value) -> Result<Vec<Segment>, String> {
    if let Some(e) = response.get("error") { return Err(crate::describe::explain(e["code"].as_u64().unwrap_or(0), e["message"].as_str().unwrap_or(""))); }
    let parts = response["candidates"][0]["content"]["parts"].as_array().cloned().unwrap_or_default();
    let text = parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("");
    let text = text.trim().trim_start_matches("```json").trim_start_matches("```").trim_end_matches("```").trim();
    let list: Value = serde_json::from_str(text).map_err(|_| "The transcript came back in a form Still couldn’t read. Try again.".to_string())?;
    let seconds = |v: &Value| -> f64 {
        if let Some(n) = v.as_f64() { return n; }
        let s = v.as_str().unwrap_or("");
        s.split(':').try_fold(0.0, |total, part| part.trim().parse::<f64>().map(|p| total * 60.0 + p)).unwrap_or(f64::NAN)
    };
    let segments = list.as_array().map(|list| list.iter().map(|s| Segment { start: seconds(&s["start"]), end: seconds(&s["end"]), text: s["text"].as_str().unwrap_or("").to_string() }).collect()).unwrap_or_default();
    Ok(tidy(segments))
}

async fn with_gemini(key: &str, wav: Vec<u8>) -> Result<Vec<Segment>, String> {
    use base64::Engine;
    let body = gemini_body(&base64::engine::general_purpose::STANDARD.encode(wav));
    let client = http()?;
    let mut last = Value::Null;
    for (attempt, model) in [crate::describe::MODEL, crate::describe::MODEL, crate::describe::LITE_MODEL].iter().enumerate() {
        if attempt == 1 { tokio::time::sleep(std::time::Duration::from_millis(1500)).await; }
        let res = client.post(format!("{GEMINI_URL}/{model}:generateContent")).header("x-goog-api-key", key.trim()).json(&body).send().await
            .map_err(|e| format!("Couldn’t reach Gemini: {e}"))?;
        let status = res.status().as_u16();
        last = res.json().await.unwrap_or(Value::Null);
        if !crate::describe::busy(status) { break; }
    }
    gemini_segments(&last)
}

/// Writes down what was said in one piece of sound (a WAV file `length` seconds long), with the service and key
/// chosen in Settings → AI. Claude can't listen to sound, so with it chosen another saved key is used if there is one.
pub async fn transcribe(provider: &str, openai_key: &str, gemini_key: &str, wav: Vec<u8>, length: f64) -> Result<Vec<Segment>, String> {
    let use_openai = !openai_key.is_empty() && (provider == "openai" || gemini_key.is_empty());
    if use_openai { return with_openai(openai_key, wav, length).await; }
    if !gemini_key.is_empty() { return with_gemini(gemini_key, wav).await; }
    Err("Transcribing needs an AI key that can listen to sound. Add one in Settings → AI.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_form_carries_the_model_the_format_and_the_sound() {
        let body = String::from_utf8_lossy(&multipart("B", b"RIFFdata")).to_string();
        assert!(body.starts_with("--B\r\n"));
        assert!(body.contains("name=\"model\"\r\n\r\nwhisper-1\r\n"));
        assert!(body.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"));
        assert!(body.contains("filename=\"sound.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFFdata\r\n--B--\r\n"));
    }
    #[test]
    fn openai_segments_are_read_tidied_and_errors_are_plain() {
        let answer = json!({ "text": "Hi there. Click save.", "segments": [
            { "start": 2.0, "end": 3.5, "text": " Click save." }, { "start": 0.0, "end": 1.2, "text": " Hi there." }, { "start": 4.0, "end": 4.0, "text": "  " } ] });
        let s = openai_segments(200, &answer, 10.0).unwrap();
        assert_eq!(s, vec![Segment { start: 0.0, end: 1.2, text: "Hi there.".into() }, Segment { start: 2.0, end: 3.5, text: "Click save.".into() }]);
        let whole = openai_segments(200, &json!({ "text": "Hello" }), 4.0).unwrap();
        assert_eq!(whole, vec![Segment { start: 0.0, end: 4.0, text: "Hello".into() }]);
        assert!(openai_segments(200, &json!({ "text": "" }), 4.0).unwrap().is_empty());
        assert!(openai_segments(401, &json!({ "error": { "message": "bad" } }), 4.0).unwrap_err().contains("isn’t valid"));
    }
    #[test]
    fn gemini_segments_accept_fences_and_clock_times() {
        let answer = json!({ "candidates": [{ "content": { "parts": [{ "text": "```json\n[{\"start\": \"0:01.5\", \"end\": \"0:03\", \"text\": \"Open the menu\"}, {\"start\": 4, \"end\": 4.1, \"text\": \"Done\"}]\n```" }] } }] });
        let s = gemini_segments(&answer).unwrap();
        assert_eq!(s[0], Segment { start: 1.5, end: 3.0, text: "Open the menu".into() });
        assert_eq!(s[1].end, 4.3, "a stretch is at least a moment long");
        let silent = json!({ "candidates": [{ "content": { "parts": [{ "text": "[]" }] } }] });
        assert!(gemini_segments(&silent).unwrap().is_empty());
        let garbled = json!({ "candidates": [{ "content": { "parts": [{ "text": "Sorry" }] } }] });
        assert!(gemini_segments(&garbled).is_err());
        assert!(gemini_segments(&json!({ "error": { "code": 429, "message": "" } })).unwrap_err().contains("limit"));
    }
    #[test]
    fn the_gemini_request_asks_for_json_and_carries_the_sound() {
        let b = gemini_body("AAAA");
        assert_eq!(b["contents"][0]["parts"][1]["inline_data"]["mime_type"], "audio/wav");
        assert_eq!(b["generationConfig"]["responseMimeType"], "application/json");
    }
}
