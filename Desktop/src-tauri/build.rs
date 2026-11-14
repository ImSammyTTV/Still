// Declaring the app's commands lets each window's capability allow only the commands that page uses
// (see capabilities/), instead of every window being able to call all of them.
fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
        "settings_get", "settings_set", "settings_reset", "settings_choose_folder", "shortcuts_pause", "overlay_done",
        "overlay_cancel", "overlay_fullscreen", "overlay_timer", "overlay_purpose", "overlay_window_mode", "overlay_pointer", "overlay_color", "overlay_ready",
        "library_list", "library_get", "library_rename", "library_delete", "library_copy", "library_save",
        "library_save_as", "library_reveal", "library_open", "library_play", "library_pin", "library_drag", "editor_save",
        "editor_copy", "editor_export", "watermark_choose_image", "editor_save_file", "library_save_for_size", "editor_drag", "editor_pin", "editor_open_image", "preview_edit",
        "open_settings_cmd", "open_history_cmd", "open_demo", "capture_action", "ocr_result", "recording_prepared", "recording_started",
        "recording_listen", "recording_finished", "camera_failed", "recording_cancel", "recording_error", "recording_chunk", "recording_reset", "recording_save", "recording_begin", "recording_stop", "recording_pause", "recording_restart", "recording_tick", "video_export_target", "video_export_save", "video_export_part",
        "video_export_copy", "video_project_save", "update_status", "update_check", "update_install",
        "library_combine", "library_star", "video_music_choose", "video_image_save", "countdown_cancel", "library_similar", "library_similar_in_folder", "library_folder_match", "library_search_web", "library_describe", "library_send_to_claude", "connector_info", "connector_add_to_claude", "ai_get", "ai_set_key", "scroll_stop", "scroll_auto",
    ]))).expect("failed to run tauri-build");
}
