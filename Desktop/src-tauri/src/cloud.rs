use serde_json::{json, Value};
use std::path::Path;

/// Talks to a self-hosted Still Cloud server (Cloud/server.py), the same API the Mac app uses.
pub struct Cloud { endpoint: String, token: String, client: reqwest::Client }

pub struct Options { pub title: String, pub expiry_days: i64, pub visibility: String, pub password: String, pub text: String }

impl Cloud {
    pub fn new(endpoint: &str, token: &str) -> Result<Self, String> {
        if rustls::crypto::CryptoProvider::get_default().is_none() { let _ = rustls::crypto::ring::default_provider().install_default(); }
        let endpoint = endpoint.trim().trim_end_matches('/').to_string();
        // Parse the address rather than compare prefixes: http://localhost.example.com is not this computer.
        let url = reqwest::Url::parse(&endpoint).map_err(|_| "That server address isn’t valid.".to_string())?;
        let local = matches!(url.host_str(), Some("127.0.0.1") | Some("localhost") | Some("[::1]"));
        if !(url.scheme() == "https" || (url.scheme() == "http" && local)) {
            return Err("Use an https:// server address (http is only allowed for this computer).".into());
        }
        if token.trim().is_empty() { return Err("Add your personal access token first.".into()); }
        let client = reqwest::Client::builder().timeout(std::time::Duration::from_secs(7200)).build().map_err(|e| e.to_string())?;
        Ok(Cloud { endpoint, token: token.trim().to_string(), client })
    }

    fn url(&self, path: &str) -> String { format!("{}/{}", self.endpoint, path) }

    async fn checked(response: reqwest::Response) -> Result<Value, String> {
        let status = response.status();
        let body: Value = response.json().await.unwrap_or(Value::Null);
        if status.is_success() { Ok(body) } else { Err(body["error"].as_str().unwrap_or("The cloud server didn’t accept the request.").to_string()) }
    }

    /// Returns the account name the token belongs to.
    pub async fn test(&self) -> Result<String, String> {
        let r = self.client.get(self.url("api/me")).bearer_auth(&self.token).send().await.map_err(friendly)?;
        let body = Self::checked(r).await?;
        Ok(body["user"]["name"].as_str().unwrap_or("you").to_string())
    }

    /// Creates the upload, sends the file and returns the share link.
    pub async fn upload(&self, file: &Path, options: &Options) -> Result<String, String> {
        let bytes = std::fs::read(file).map_err(|e| e.to_string())?;
        let mime = match file.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase().as_str() {
            "jpg" | "jpeg" => "image/jpeg", "mp4" => "video/mp4", "webm" => "video/webm", "gif" => "image/gif", _ => "image/png",
        };
        let payload = json!({ "title": options.title, "mime": mime, "size": bytes.len(), "tags": [], "expiryDays": options.expiry_days,
            "password": options.password, "visibility": options.visibility, "maxViews": 0, "ocr": options.text, "transcript": "", "captions": "" });
        let r = self.client.post(self.url("api/uploads")).bearer_auth(&self.token).json(&payload).send().await.map_err(friendly)?;
        let ticket = Self::checked(r).await?;
        let id = ticket["id"].as_str().unwrap_or("").to_string();
        if id.len() != 32 || !id.chars().all(|c| c.is_ascii_hexdigit()) { return Err("The server returned an invalid upload identifier.".into()); }
        let link = ticket["url"].as_str().unwrap_or("").to_string();
        let sent = self.client.put(self.url(&format!("api/uploads/{id}/content"))).bearer_auth(&self.token).header("Content-Type", mime).body(bytes).send().await;
        match sent {
            Ok(r) if r.status().is_success() => Ok(link),
            other => {
                let _ = self.client.delete(self.url(&format!("api/uploads/{id}"))).bearer_auth(&self.token).send().await;
                match other { Ok(r) => Self::checked(r).await.map(|_| link), Err(e) => Err(friendly(e)) }
            }
        }
    }
}

/// The iCloud Drive folder from iCloud for Windows, if it's installed. Apple offers no iCloud client for Linux,
/// and the Mac app has its own native version of this.
pub fn icloud_folder() -> Option<std::path::PathBuf> {
    if !cfg!(windows) { return None; }
    let folder = std::path::PathBuf::from(std::env::var_os("USERPROFILE")?).join("iCloudDrive");
    folder.is_dir().then_some(folder)
}

fn friendly(error: reqwest::Error) -> String {
    if error.is_connect() || error.is_timeout() { "Couldn’t reach the cloud server. Check the address and your connection.".into() } else { error.to_string() }
}
