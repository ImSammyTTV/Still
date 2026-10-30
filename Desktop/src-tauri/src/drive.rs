use base64::Engine;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::Path;
use std::time::{Duration, Instant};

/// Google Drive sharing. Still signs in through the browser (OAuth for desktop apps, with PKCE) and asks only
/// for drive.file, so it can see the files it creates and nothing else in the user's Drive.
const SCOPE: &str = "https://www.googleapis.com/auth/drive.file";
const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
const API: &str = "https://www.googleapis.com";

fn client_id() -> &'static str { option_env!("STILL_GOOGLE_CLIENT_ID").unwrap_or("") }
// Google's desktop flow requires this value but doesn't treat it as a secret.
fn client_secret() -> &'static str { option_env!("STILL_GOOGLE_CLIENT_SECRET").unwrap_or("") }
pub fn available() -> bool { !client_id().is_empty() }

/// PKCE: the S256 challenge for a verifier (RFC 7636).
pub fn challenge(verifier: &str) -> String {
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(Sha256::digest(verifier.as_bytes()))
}

/// Pulls the code out of the browser's redirect, checking it answers the sign-in this app started.
pub fn parse_callback(request_line: &str, state: &str) -> Result<Option<String>, String> {
    let target = request_line.split_whitespace().nth(1).unwrap_or("");
    let url = reqwest::Url::parse(&format!("http://127.0.0.1{target}")).map_err(|_| "Google sent an unreadable reply.".to_string())?;
    if url.path() != "/" { return Ok(None); } // the browser also asks for /favicon.ico
    let value = |key: &str| url.query_pairs().find(|(k, _)| k == key).map(|(_, v)| v.to_string());
    if value("state").as_deref() != Some(state) { return Err("The sign-in reply didn’t match. Try connecting again.".into()); }
    if let Some(error) = value("error") { return Err(if error == "access_denied" { "Google Drive access wasn’t allowed.".into() } else { format!("Google sign-in failed: {error}") }); }
    value("code").map(Some).ok_or_else(|| "Google didn’t send a sign-in code.".to_string())
}

fn form(pairs: &[(&str, &str)]) -> String {
    reqwest::Url::parse_with_params("http://x/", pairs).ok().and_then(|u| u.query().map(String::from)).unwrap_or_default()
}

fn open_browser(url: &str) {
    #[cfg(windows)] { let _ = std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn(); }
    #[cfg(target_os = "linux")] { let _ = std::process::Command::new("xdg-open").arg(url).spawn(); }
    #[cfg(target_os = "macos")] { let _ = std::process::Command::new("open").arg(url).spawn(); }
}

/// Waits for the browser to come back to this computer, for up to five minutes.
fn wait_for_code(listener: TcpListener, state: &str) -> Result<String, String> {
    listener.set_nonblocking(true).map_err(|e| e.to_string())?;
    let deadline = Instant::now() + Duration::from_secs(300);
    while Instant::now() < deadline {
        let Ok((mut stream, _)) = listener.accept() else { std::thread::sleep(Duration::from_millis(100)); continue };
        let _ = stream.set_nonblocking(false);
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let mut buffer = [0u8; 4096];
        let read = stream.read(&mut buffer).unwrap_or(0);
        let request = String::from_utf8_lossy(&buffer[..read]);
        let result = parse_callback(request.lines().next().unwrap_or(""), state);
        let body = match &result { Ok(Some(_)) => "Still is connected to Google Drive. You can close this tab.", Ok(None) => "", Err(e) => e.as_str() };
        let page = format!("<!doctype html><meta charset=utf-8><title>Still</title><body style=\"font:16px system-ui;text-align:center;padding-top:20vh\">{}</body>", body.replace('<', "&lt;"));
        let _ = write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", page.len(), page);
        match result { Ok(Some(code)) => return Ok(code), Ok(None) => continue, Err(e) => return Err(e) }
    }
    Err("Google sign-in timed out. Try connecting again.".into())
}

pub struct Connected { pub refresh_token: String, pub email: String }

fn http() -> Result<reqwest::Client, String> {
    if rustls::crypto::CryptoProvider::get_default().is_none() { let _ = rustls::crypto::ring::default_provider().install_default(); }
    reqwest::Client::builder().timeout(Duration::from_secs(7200)).build().map_err(|e| e.to_string())
}
async fn token_request(client: &reqwest::Client, pairs: &[(&str, &str)]) -> Result<Value, String> {
    let r = client.post(TOKEN_URL).header("Content-Type", "application/x-www-form-urlencoded").body(form(pairs)).send().await.map_err(friendly)?;
    let ok = r.status().is_success();
    let body: Value = r.json().await.unwrap_or(Value::Null);
    if ok { Ok(body) }
    else if body["error"] == "invalid_grant" { Err("Google Drive needs reconnecting. Open Settings → Cloud and connect again.".into()) }
    else { Err(body["error_description"].as_str().unwrap_or("Google didn’t accept the sign-in.").to_string()) }
}
async fn checked(response: reqwest::Response) -> Result<Value, String> {
    let status = response.status();
    let body: Value = response.json().await.unwrap_or(Value::Null);
    if status.is_success() { Ok(body) }
    else if status.as_u16() == 403 && body["error"]["errors"][0]["reason"] == "storageQuotaExceeded" { Err("Your Google Drive is full.".into()) }
    else { Err(body["error"]["message"].as_str().unwrap_or("Google Drive didn’t accept the request.").to_string()) }
}
fn friendly(error: reqwest::Error) -> String {
    if error.is_connect() || error.is_timeout() { "Couldn’t reach Google Drive. Check your connection.".into() } else { error.to_string() }
}

/// Runs the browser sign-in and returns the long-lived token to keep.
pub async fn connect() -> Result<Connected, String> {
    if !available() { return Err("This build of Still isn’t set up for Google Drive.".into()); }
    let listener = TcpListener::bind("127.0.0.1:0").map_err(|e| e.to_string())?;
    let redirect = format!("http://127.0.0.1:{}", listener.local_addr().map_err(|e| e.to_string())?.port());
    let (state, verifier) = (uuid::Uuid::new_v4().simple().to_string(), format!("{}{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple()));
    let url = reqwest::Url::parse_with_params(AUTH_URL, &[("client_id", client_id()), ("redirect_uri", redirect.as_str()), ("response_type", "code"), ("scope", SCOPE),
        ("state", state.as_str()), ("code_challenge", challenge(&verifier).as_str()), ("code_challenge_method", "S256"), ("access_type", "offline"), ("prompt", "consent")]).map_err(|e| e.to_string())?;
    open_browser(url.as_str());
    let code = tauri::async_runtime::spawn_blocking(move || wait_for_code(listener, &state)).await.map_err(|e| e.to_string())??;
    let client = http()?;
    let tokens = token_request(&client, &[("client_id", client_id()), ("client_secret", client_secret()), ("code", code.as_str()), ("code_verifier", verifier.as_str()), ("redirect_uri", redirect.as_str()), ("grant_type", "authorization_code")]).await?;
    let refresh_token = tokens["refresh_token"].as_str().ok_or("Google didn’t return a lasting sign-in. Try connecting again.")?.to_string();
    let access = tokens["access_token"].as_str().unwrap_or("");
    let about = client.get(format!("{API}/drive/v3/about?fields=user(emailAddress)")).bearer_auth(access).send().await.map_err(friendly)?;
    let email = checked(about).await?["user"]["emailAddress"].as_str().unwrap_or("your account").to_string();
    Ok(Connected { refresh_token, email })
}

/// Forgets the sign-in at Google too; failing to reach Google shouldn't stop the local disconnect.
pub async fn revoke(refresh_token: &str) {
    if let Ok(client) = http() { let _ = client.post("https://oauth2.googleapis.com/revoke").header("Content-Type", "application/x-www-form-urlencoded").body(form(&[("token", refresh_token)])).send().await; }
}

pub fn mime(file: &Path) -> &'static str {
    match file.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase().as_str() {
        "jpg" | "jpeg" => "image/jpeg", "mp4" => "video/mp4", "webm" => "video/webm", "gif" => "image/gif", _ => "image/png",
    }
}

async fn make_folder(client: &reqwest::Client, access: &str) -> Result<String, String> {
    let r = client.post(format!("{API}/drive/v3/files?fields=id")).bearer_auth(access).json(&json!({ "name": "Still", "mimeType": "application/vnd.google-apps.folder" })).send().await.map_err(friendly)?;
    checked(r).await?["id"].as_str().map(String::from).ok_or_else(|| "Google Drive didn’t create the Still folder.".to_string())
}

pub struct Uploaded { pub link: String, pub folder: String }

/// Puts the file in the Still folder in the user's Drive and returns its link. `folder` is the remembered folder id;
/// a new one is made if it's empty or was deleted.
pub async fn upload(refresh_token: &str, folder: &str, file: &Path, title: &str, public: bool) -> Result<Uploaded, String> {
    let client = http()?;
    let tokens = token_request(&client, &[("client_id", client_id()), ("client_secret", client_secret()), ("refresh_token", refresh_token), ("grant_type", "refresh_token")]).await?;
    let access = tokens["access_token"].as_str().ok_or("Google didn’t return an access token.")?.to_string();
    let bytes = std::fs::read(file).map_err(|e| e.to_string())?;
    let mime = mime(file);
    let extension = file.extension().and_then(|e| e.to_str()).unwrap_or("png");
    let name = format!("{title}.{extension}");
    let mut folder = if folder.is_empty() { make_folder(&client, &access).await? } else { folder.to_string() };
    let start = |parent: String| client.post(format!("{API}/upload/drive/v3/files?uploadType=resumable&fields=id,webViewLink")).bearer_auth(&access)
        .header("X-Upload-Content-Type", mime).header("X-Upload-Content-Length", bytes.len()).json(&json!({ "name": name, "parents": [parent] })).send();
    let mut session = start(folder.clone()).await.map_err(friendly)?;
    if session.status().as_u16() == 404 { folder = make_folder(&client, &access).await?; session = start(folder.clone()).await.map_err(friendly)?; }
    if !session.status().is_success() { checked(session).await?; return Err("Google Drive didn’t accept the upload.".into()); }
    let location = session.headers().get("location").and_then(|v| v.to_str().ok()).ok_or("Google Drive didn’t start the upload.")?.to_string();
    let sent = client.put(location).header("Content-Type", mime).body(bytes).send().await.map_err(friendly)?;
    let created = checked(sent).await?;
    let id = created["id"].as_str().ok_or("Google Drive didn’t return the file.")?;
    if public {
        let shared = client.post(format!("{API}/drive/v3/files/{id}/permissions")).bearer_auth(&access).json(&json!({ "role": "reader", "type": "anyone" })).send().await.map_err(friendly)?;
        checked(shared).await?;
    }
    Ok(Uploaded { link: created["webViewLink"].as_str().unwrap_or("").to_string(), folder })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn challenge_matches_the_pkce_spec() {
        assert_eq!(challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM");
    }
    #[test]
    fn callback_needs_the_right_state() {
        assert_eq!(parse_callback("GET /?state=abc&code=4%2F0A HTTP/1.1", "abc").unwrap(), Some("4/0A".to_string()));
        assert!(parse_callback("GET /?state=other&code=x HTTP/1.1", "abc").is_err());
        assert!(parse_callback("GET /?state=abc&error=access_denied HTTP/1.1", "abc").is_err());
        assert_eq!(parse_callback("GET /favicon.ico HTTP/1.1", "abc").unwrap(), None);
    }
    #[test]
    fn form_encodes_values() { assert_eq!(form(&[("a", "b c"), ("d", "e&f")]), "a=b+c&d=e%26f"); }
}
