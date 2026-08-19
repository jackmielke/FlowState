//! Vibe Voice — Tauri backend.
//!
//! Responsibilities that MUST stay on this side of the process boundary:
//!   * reading ~/.config/vibe-voice/config.json (the sk-proj key)
//!   * minting the short-lived ek_ ephemeral token
//!   * screen capture + downscale (WKWebView getDisplayMedia is unreliable)
//!   * settings persistence
//!
//! The webview only ever receives the ek_ token, never the sk-proj key.

use base64::Engine;
use serde::{Deserialize, Serialize};
use std::io::Cursor;
use std::path::PathBuf;
use tauri::{Emitter, Manager};

const CLIENT_SECRETS_URL: &str = "https://api.openai.com/v1/realtime/client_secrets";

// ---------------------------------------------------------------------------
// key + settings storage
// ---------------------------------------------------------------------------

fn config_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_default()
        .join(".config/vibe-voice/config.json")
}

fn read_api_key() -> Result<String, String> {
    let p = config_path();
    let raw = std::fs::read_to_string(&p).map_err(|e| {
        format!(
            "Could not read {}: {}. Create it with {{\"OPENAI_API_KEY\": \"sk-proj-...\"}} and chmod 600.",
            p.display(),
            e
        )
    })?;
    let v: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| format!("{} is not valid JSON: {}", p.display(), e))?;
    v.get("OPENAI_API_KEY")
        .and_then(|k| k.as_str())
        .filter(|k| !k.is_empty())
        .map(|k| k.to_string())
        .ok_or_else(|| format!("No OPENAI_API_KEY field in {}", p.display()))
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct Settings {
    pub voice: String,
    pub model: String,
    pub instructions: String,
    pub speed: f32,
    pub continuous: bool,
    pub interval_s: u32,
    pub vad_threshold: f32,
    pub silence_ms: u32,
    pub transcribe: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            voice: "marin".into(),
            model: "gpt-realtime-2.1".into(),
            instructions: "You are Vibe Voice, a warm, quick, genuinely useful voice companion \
                           running locally on the user's Mac. Keep replies short and conversational \
                           unless asked for depth. When you are shown a screenshot, describe what \
                           actually matters on it rather than narrating every pixel."
                .into(),
            speed: 1.0,
            continuous: false,
            interval_s: 5,
            vad_threshold: 0.5,
            silence_ms: 500,
            transcribe: true,
        }
    }
}

fn settings_file(app: &tauri::AppHandle) -> PathBuf {
    let dir = app
        .path()
        .app_config_dir()
        .unwrap_or_else(|_| dirs::home_dir().unwrap_or_default().join(".vibe-voice"));
    let _ = std::fs::create_dir_all(&dir);
    dir.join("settings.json")
}

#[tauri::command]
fn load_settings(app: tauri::AppHandle) -> Settings {
    std::fs::read_to_string(settings_file(&app))
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

#[tauri::command]
fn save_settings(app: tauri::AppHandle, settings: Settings) -> Result<(), String> {
    let path = settings_file(&app);
    let body = serde_json::to_string_pretty(&settings).map_err(|e| e.to_string())?;
    std::fs::write(&path, body).map_err(|e| format!("write {}: {}", path.display(), e))
}

// ---------------------------------------------------------------------------
// ephemeral token
// ---------------------------------------------------------------------------

#[derive(Serialize)]
pub struct Ephemeral {
    value: String,
    expires_at: i64,
    model: String,
}

/// Mints an ek_ token. The sk-proj key never leaves this function.
#[tauri::command]
async fn mint_ephemeral_token(model: String) -> Result<Ephemeral, String> {
    let key = read_api_key()?;
    let client = reqwest::Client::new();
    let body = serde_json::json!({ "session": { "type": "realtime", "model": model } });

    let resp = client
        .post(CLIENT_SECRETS_URL)
        .bearer_auth(&key)
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("Network error reaching OpenAI: {e}"))?;

    let status = resp.status();
    let text = resp
        .text()
        .await
        .map_err(|e| format!("Could not read OpenAI response: {e}"))?;

    if !status.is_success() {
        // Surface the REAL API message, per spec.
        let detail = serde_json::from_str::<serde_json::Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(|m| m.as_str())
                    .map(str::to_string)
            })
            .unwrap_or_else(|| text.chars().take(400).collect());
        return Err(format!("OpenAI {status}: {detail}"));
    }

    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|e| format!("Bad JSON from OpenAI: {e}"))?;
    let value = v
        .get("value")
        .and_then(|x| x.as_str())
        .ok_or("No `value` in client_secrets response")?
        .to_string();
    let expires_at = v.get("expires_at").and_then(|x| x.as_i64()).unwrap_or(0);

    Ok(Ephemeral {
        value,
        expires_at,
        model,
    })
}

// ---------------------------------------------------------------------------
// screen capture (Rust side — WKWebView getDisplayMedia is not dependable)
// ---------------------------------------------------------------------------

#[derive(Serialize)]
pub struct Shot {
    data_url: String,
    width: u32,
    height: u32,
    bytes: usize,
}

fn encode_jpeg(img: image::RgbaImage, target_w: u32) -> Result<Shot, String> {
    let (w, h) = img.dimensions();
    let (nw, nh) = if w > target_w {
        let scale = target_w as f32 / w as f32;
        (target_w, ((h as f32) * scale).round().max(1.0) as u32)
    } else {
        (w, h)
    };

    let dynimg = image::DynamicImage::ImageRgba8(img);
    let resized = if (nw, nh) != (w, h) {
        dynimg.resize_exact(nw, nh, image::imageops::FilterType::Triangle)
    } else {
        dynimg
    };
    let rgb = resized.to_rgb8();

    let mut buf: Vec<u8> = Vec::new();
    {
        let mut cursor = Cursor::new(&mut buf);
        let mut enc = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut cursor, 70);
        enc.encode(rgb.as_raw(), nw, nh, image::ExtendedColorType::Rgb8)
            .map_err(|e| format!("jpeg encode: {e}"))?;
    }

    let b64 = base64::engine::general_purpose::STANDARD.encode(&buf);
    Ok(Shot {
        data_url: format!("data:image/jpeg;base64,{b64}"),
        width: nw,
        height: nh,
        bytes: buf.len(),
    })
}

/// Fallback path: the system `screencapture` binary. Used when xcap fails
/// (it fails loudly and unhelpfully when Screen Recording is not granted).
fn capture_via_screencapture(target_w: u32) -> Result<Shot, String> {
    let tmp = std::env::temp_dir().join(format!("vibe-voice-{}.png", std::process::id()));
    let out = std::process::Command::new("/usr/sbin/screencapture")
        .args(["-x", "-C", "-t", "png", tmp.to_str().unwrap_or("/tmp/vv.png")])
        .output()
        .map_err(|e| format!("screencapture failed to launch: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "screencapture exited {}: {}",
            out.status,
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    let bytes = std::fs::read(&tmp).map_err(|e| format!("read capture: {e}"))?;
    let _ = std::fs::remove_file(&tmp);
    let img = image::load_from_memory(&bytes)
        .map_err(|e| format!("decode capture: {e}"))?
        .to_rgba8();
    encode_jpeg(img, target_w)
}

#[tauri::command]
async fn capture_screen(max_width: Option<u32>) -> Result<Shot, String> {
    let target_w = max_width.unwrap_or(1280);
    let via_xcap = (|| -> Result<Shot, String> {
        let monitors = xcap::Monitor::all().map_err(|e| format!("xcap monitors: {e}"))?;
        let m = monitors
            .into_iter()
            .find(|m| m.is_primary().unwrap_or(false))
            .ok_or("no primary monitor")?;
        let img = m.capture_image().map_err(|e| format!("xcap capture: {e}"))?;
        encode_jpeg(img, target_w)
    })();

    match via_xcap {
        Ok(shot) => Ok(shot),
        Err(primary_err) => capture_via_screencapture(target_w).map_err(|fallback_err| {
            format!(
                "Screen capture failed. Grant Screen Recording to Vibe Voice in System Settings \
                 > Privacy & Security > Screen Recording, then relaunch. ({primary_err} / {fallback_err})"
            )
        }),
    }
}

/// Cheap probe: has this process actually got Screen Recording?
#[tauri::command]
fn screen_permission_ok() -> bool {
    match xcap::Monitor::all() {
        Ok(ms) => !ms.is_empty(),
        Err(_) => false,
    }
}

#[tauri::command]
fn open_privacy_pane(which: String) -> Result<(), String> {
    let url = match which.as_str() {
        "mic" => "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        _ => "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
    };
    std::process::Command::new("/usr/bin/open")
        .arg(url)
        .spawn()
        .map(|_| ())
        .map_err(|e| e.to_string())
}

/// Pipe webview console output to the Rust stdout so `tauri dev` shows it.
#[tauri::command]
fn js_log(level: String, message: String) {
    println!("[webview:{level}] {message}");
}

/// Diagnostics from the Rust side, echoed into the in-app debug log.
#[tauri::command]
fn backend_info() -> serde_json::Value {
    serde_json::json!({
        "config_path": config_path().display().to_string(),
        "config_exists": config_path().exists(),
        "screen_permission": screen_permission_ok(),
        "selftest": std::env::var("VIBE_SELFTEST").is_ok(),
    })
}

// ---------------------------------------------------------------------------

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            #[cfg(desktop)]
            {
                use tauri_plugin_global_shortcut::{Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState};
                // ⌘⇧2
                let shot = Shortcut::new(Some(Modifiers::SUPER | Modifiers::SHIFT), Code::Digit2);
                let handle = app.handle().clone();
                app.handle().plugin(
                    tauri_plugin_global_shortcut::Builder::new()
                        .with_handler(move |_app, sc, event| {
                            if event.state() == ShortcutState::Pressed && sc == &shot {
                                let _ = handle.emit("hotkey-screenshot", ());
                            }
                        })
                        .build(),
                )?;
                if let Err(e) = app.global_shortcut().register(shot) {
                    eprintln!("[vibe-voice] could not register CmdShift2: {e}");
                }
            }
            println!(
                "[vibe-voice] backend up. config={} exists={}",
                config_path().display(),
                config_path().exists()
            );
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            mint_ephemeral_token,
            capture_screen,
            screen_permission_ok,
            open_privacy_pane,
            load_settings,
            save_settings,
            backend_info,
            js_log
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
