// Declaring the app's commands lets each window's capability allow only the commands that page uses
// (see capabilities/), instead of every window being able to call all of them.
fn main() {
    // Set when building releases; without them Settings says Google Drive isn't available in this build.
    println!("cargo:rerun-if-env-changed=STILL_GOOGLE_CLIENT_ID");
    println!("cargo:rerun-if-env-changed=STILL_GOOGLE_CLIENT_SECRET");
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
        "settings_get", "settings_set", "settings_reset", "settings_choose_folder", "shortcuts_pause", "overlay_done",
        "overlay_cancel", "overlay_fullscreen", "overlay_timer", "overlay_purpose", "overlay_window_mode", "overlay_pointer",
        "library_list", "library_get", "library_rename", "library_delete", "library_copy", "library_save",
        "library_save_as", "library_reveal", "library_open", "library_play", "library_pin", "library_drag", "editor_save",
        "editor_copy", "editor_export", "editor_drag", "editor_pin", "editor_open_image", "preview_edit",
        "open_settings_cmd", "open_history_cmd", "open_demo", "capture_action", "ocr_result", "recording_started",
        "recording_cancel", "recording_error", "recording_save", "recording_tick", "video_export_target", "video_export_save",
        "video_export_copy", "update_status", "update_check", "update_install",
        "cloud_get", "cloud_connect", "cloud_disconnect", "cloud_upload", "cloud_upload_data", "drive_get", "drive_connect", "drive_disconnect",
    ]))).expect("failed to run tauri-build");
}
