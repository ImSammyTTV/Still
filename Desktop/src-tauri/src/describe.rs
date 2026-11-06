//! Describe Image: a short description of a screenshot, from Google's Gemini API with the user's own free key (from
//! Google AI Studio), or from Claude with the user's own Anthropic API key. Still sends the picture only when asked, and keeps the description with the capture so History's
//! search finds it. The Mac app's ImageDescriber follows the same rules and shares the test cases.
use serde_json::{json, Value};

const BASE: &str = "https://generativelanguage.googleapis.com/v1beta";
/// Google keeps this name pointing at its current Flash model, which the free tier includes.
pub const MODEL: &str = "gemini-flash-latest";
pub const PROMPT: &str = "Describe this screenshot in one or two plain sentences for someone who can't see it, as alt text: say what app or page it shows and what matters on it. Then, on a new line starting with \"Text: \", quote any short heading or button text that stands out. No preamble.";

fn http() -> Result<reqwest::Client, String> {
    reqwest::Client::builder().timeout(std::time::Duration::from_secs(60)).build().map_err(|e| e.to_string())
}

/// The request body for one picture (PNG or JPEG bytes, base64-encoded).
pub fn body(mime: &str, base64: &str) -> Value {
    json!({ "contents": [{ "parts": [{ "text": PROMPT }, { "inline_data": { "mime_type": mime, "data": base64 } }] }],
        "generationConfig": { "temperature": 0.2, "maxOutputTokens": 300 } })
}

/// The description in a response: its text parts joined, trimmed. Errors say what went wrong in plain words.
pub fn text_of(response: &Value) -> Result<String, String> {
    if let Some(e) = response.get("error") { return Err(explain(e["code"].as_u64().unwrap_or(0), e["message"].as_str().unwrap_or(""))); }
    let parts = response["candidates"][0]["content"]["parts"].as_array().cloned().unwrap_or_default();
    let text = parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join("").trim().to_string();
    if text.is_empty() {
        let why = response["promptFeedback"]["blockReason"].as_str().or(response["candidates"][0]["finishReason"].as_str()).unwrap_or("no text came back");
        return Err(format!("Gemini didn’t describe this picture ({why})."));
    }
    Ok(text)
}

pub fn explain(code: u64, message: &str) -> String {
    match code {
        400 if message.to_lowercase().contains("api key") => "That Gemini key isn’t valid. Copy it again from Google AI Studio.".into(),
        401 | 403 => "Gemini refused the key. Check it in Google AI Studio, or make a new one.".into(),
        429 => "Gemini’s free limit is used up for now. Try again in a minute (or later today).".into(),
        _ if message.is_empty() => format!("Gemini answered with an error ({code})."),
        _ => format!("Gemini: {message}"),
    }
}

/// A Flash model this key can use, from Google's list, for when the usual name isn't offered to it.
pub fn pick_model(list: &Value) -> Option<String> {
    let models = list["models"].as_array()?;
    let usable = |m: &&Value| m["supportedGenerationMethods"].as_array().map_or(false, |a| a.iter().any(|x| x == "generateContent"));
    let name = |m: &Value| m["name"].as_str().unwrap_or("").trim_start_matches("models/").to_string();
    models.iter().filter(usable).map(name).filter(|n| n.contains("flash") && !n.contains("image") && !n.contains("tts") && !n.contains("live")).max_by(|a, b| a.cmp(b))
}

async fn call(client: &reqwest::Client, key: &str, model: &str, body: &Value) -> Result<(u16, Value), String> {
    let res = client.post(format!("{BASE}/models/{model}:generateContent")).header("x-goog-api-key", key).json(body).send().await
        .map_err(|e| format!("Couldn’t reach Gemini: {e}"))?;
    let status = res.status().as_u16();
    Ok((status, res.json().await.unwrap_or(Value::Null)))
}

/// Describes a picture with the user's key.
pub async fn describe(key: &str, mime: &str, base64: &str) -> Result<String, String> {
    if key.trim().is_empty() { return Err("Add a Gemini key in Settings → AI first.".into()); }
    let client = http()?;
    let request = body(mime, base64);
    let (status, response) = call(&client, key, MODEL, &request).await?;
    if status == 404 {
        let list: Value = client.get(format!("{BASE}/models?pageSize=200")).header("x-goog-api-key", key).send().await
            .map_err(|e| format!("Couldn’t reach Gemini: {e}"))?.json().await.unwrap_or(Value::Null);
        let model = pick_model(&list).ok_or("This Gemini key has no Flash model to describe pictures with.")?;
        let (_, response) = call(&client, key, &model, &request).await?;
        return text_of(&response);
    }
    text_of(&response)
}

/// Checks a key by listing the models it can use, so Settings can say straight away whether it works.
pub async fn check(key: &str) -> Result<(), String> {
    let res = http()?.get(format!("{BASE}/models?pageSize=1")).header("x-goog-api-key", key.trim()).send().await.map_err(|e| format!("Couldn’t reach Gemini: {e}"))?;
    let status = res.status().as_u16();
    if status == 200 { return Ok(()); }
    let v: Value = res.json().await.unwrap_or(Value::Null);
    Err(explain(status as u64, v["error"]["message"].as_str().unwrap_or("")))
}

// ---- Claude ----------------------------------------------------------------------------------------

const CLAUDE_URL: &str = "https://api.anthropic.com/v1";
pub const CLAUDE_MODEL: &str = "claude-opus-5-5";
/// Lets the API hand a request it declines on safety grounds to another model in the same call.
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";

/// The Messages API request for one picture: the image first, then the prompt. A short task, so low effort.
pub fn claude_body(mime: &str, base64: &str) -> Value {
    json!({ "model": CLAUDE_MODEL, "max_tokens": 2048, "output_config": { "effort": "low" }, "fallbacks": "default",
        "messages": [{ "role": "user", "content": [
            { "type": "image", "source": { "type": "base64", "media_type": mime, "data": base64 } },
            { "type": "text", "text": PROMPT } ] }] })
}

/// The description in a Messages API response: its text blocks joined, or why there isn't one.
pub fn claude_text(status: u16, response: &Value) -> Result<String, String> {
    if response["type"] == "error" || status >= 400 {
        let message = response["error"]["message"].as_str().unwrap_or("");
        return Err(match status {
            401 => "That Anthropic API key isn’t valid. Copy it again from the Claude Console.".into(),
            403 => "Claude refused the key (it may not have access to this model).".into(),
            429 => "Claude’s rate limit is reached for now. Try again in a minute.".into(),
            529 => "Claude is busy right now. Try again in a minute.".into(),
            _ if message.is_empty() => format!("Claude answered with an error ({status})."),
            _ => format!("Claude: {message}"),
        });
    }
    if response["stop_reason"] == "refusal" { return Err("Claude declined to describe this picture.".into()); }
    let text = response["content"].as_array().map(|blocks| blocks.iter().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect::<Vec<_>>().join("")).unwrap_or_default();
    let text = text.trim().to_string();
    if text.is_empty() { Err("Claude didn’t describe this picture.".into()) } else { Ok(text) }
}

fn claude_request(client: &reqwest::Client, method: reqwest::Method, path: &str, key: &str) -> reqwest::RequestBuilder {
    client.request(method, format!("{CLAUDE_URL}/{path}")).header("x-api-key", key.trim()).header("anthropic-version", "2026-10-21")
}

pub async fn describe_with_claude(key: &str, mime: &str, base64: &str) -> Result<String, String> {
    if key.trim().is_empty() { return Err("Add an Anthropic API key in Settings → Cloud → Describe Image first.".into()); }
    let client = http()?;
    let res = claude_request(&client, reqwest::Method::POST, "messages", key).header("anthropic-beta", FALLBACK_BETA).json(&claude_body(mime, base64)).send().await
        .map_err(|e| format!("Couldn’t reach Claude: {e}"))?;
    let status = res.status().as_u16();
    let v: Value = res.json().await.unwrap_or(Value::Null);
    claude_text(status, &v)
}

/// Checks an Anthropic key by listing one model, so Settings can say straight away whether it works.
pub async fn check_claude(key: &str) -> Result<(), String> {
    let res = claude_request(&http()?, reqwest::Method::GET, "models?limit=1", key).send().await.map_err(|e| format!("Couldn’t reach Claude: {e}"))?;
    let status = res.status().as_u16();
    if status == 200 { return Ok(()); }
    let v: Value = res.json().await.unwrap_or(Value::Null);
    claude_text(status, &v).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    // The same cases are in the Mac app's ImageDescriberTests.
    #[test]
    fn the_text_comes_from_every_part_and_errors_are_plain() {
        let ok = json!({ "candidates": [{ "content": { "parts": [{ "text": "A settings page " }, { "text": "with a dark sidebar.\n" }] } }] });
        assert_eq!(text_of(&ok).unwrap(), "A settings page with a dark sidebar.");
        let limit = json!({ "error": { "code": 429, "message": "Resource exhausted" } });
        assert!(text_of(&limit).unwrap_err().contains("free limit"));
        let blocked = json!({ "promptFeedback": { "blockReason": "SAFETY" } });
        assert!(text_of(&blocked).unwrap_err().contains("SAFETY"));
        assert!(explain(400, "API key not valid. Please pass a valid API key.").contains("isn’t valid"));
    }
    #[test]
    fn a_flash_model_that_can_write_is_picked() {
        let list = json!({ "models": [
            { "name": "models/gemini-9-pro", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-9-flash-image", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-9-flash", "supportedGenerationMethods": ["generateContent", "countTokens"] },
            { "name": "models/gemini-8-flash", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/embedding-flash", "supportedGenerationMethods": ["embedContent"] } ] });
        assert_eq!(pick_model(&list).as_deref(), Some("gemini-9-flash"));
        assert_eq!(pick_model(&json!({})), None);
    }
    #[test]
    fn claude_answers_are_read_and_its_errors_are_plain() {
        let ok = json!({ "type": "message", "stop_reason": "end_turn", "content": [{ "type": "thinking", "thinking": "" }, { "type": "text", "text": " A dark settings window.\n" }] });
        assert_eq!(claude_text(200, &ok).unwrap(), "A dark settings window.");
        assert!(claude_text(200, &json!({ "stop_reason": "refusal", "content": [] })).unwrap_err().contains("declined"));
        assert!(claude_text(401, &json!({ "type": "error", "error": { "type": "authentication_error", "message": "invalid x-api-key" } })).unwrap_err().contains("isn’t valid"));
        assert!(claude_text(529, &json!({ "type": "error", "error": { "type": "overloaded_error", "message": "Overloaded" } })).unwrap_err().contains("busy"));
        let b = claude_body("image/png", "AAAA");
        assert_eq!(b["model"], CLAUDE_MODEL);
        assert_eq!(b["messages"][0]["content"][0]["source"]["media_type"], "image/png");
        assert_eq!(b["messages"][0]["content"][1]["text"], PROMPT);
    }
    #[test]
    fn the_request_carries_the_picture_and_the_prompt() {
        let b = body("image/png", "AAAA");
        assert_eq!(b["contents"][0]["parts"][1]["inline_data"]["mime_type"], "image/png");
        assert_eq!(b["contents"][0]["parts"][0]["text"], PROMPT);
    }
}
