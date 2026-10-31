// Gives every page the same small `still` API, backed by Tauri commands and events.
(function () {
  const T = window.__TAURI__;
  const win = T.webviewWindow.getCurrentWebviewWindow();
  const platform = window.__STILL_PLATFORM__ || 'win32';

  // channel → [command, ...argument names]
  const commands = {
    'settings:get': ['settings_get'], 'settings:set': ['settings_set', 'patch'], 'settings:reset': ['settings_reset', 'key'],
    'settings:chooseFolder': ['settings_choose_folder'], 'shortcuts:pause': ['shortcuts_pause', 'paused'],
    'overlay:done': ['overlay_done', 'payload'], 'overlay:cancel': ['overlay_cancel'], 'overlay:fullscreen': ['overlay_fullscreen', 'displayId'],
    'overlay:timer': ['overlay_timer', 'delay'], 'overlay:purpose': ['overlay_purpose', 'purpose'], 'overlay:windowMode': ['overlay_window_mode', 'on'],
    'overlay:pointer': ['overlay_pointer'], 'overlay:color': ['overlay_color', 'hex'], 'overlay:ready': ['overlay_ready'],
    'library:list': ['library_list', 'query'], 'library:get': ['library_get', 'id'], 'library:rename': ['library_rename', 'id', 'title'],
    'library:delete': ['library_delete', 'id'], 'library:copy': ['library_copy', 'id'], 'library:save': ['library_save', 'id'],
    'library:saveAs': ['library_save_as', 'id'], 'library:reveal': ['library_reveal', 'id'], 'library:open': ['library_open', 'id'],
    'library:pin': ['library_pin', 'id'], 'library:drag': ['library_drag', 'id'], 'library:play': ['library_play', 'id'],
    'editor:save': ['editor_save', 'id', 'dataUrl', 'project'], 'editor:copy': ['editor_copy', 'dataUrl'],
    'editor:export': ['editor_export', 'dataUrl', 'name', 'saveAs'], 'editor:drag': ['editor_drag', 'dataUrl'],
    'editor:pin': ['editor_pin', 'dataUrl'], 'editor:openImage': ['editor_open_image'],
    'preview:edit': ['preview_edit', 'id'], 'open:settings': ['open_settings_cmd', 'page'], 'open:history': ['open_history_cmd'],
    'open:demo': ['open_demo'], 'capture': ['capture_action', 'action'],
    'ocr:result': ['ocr_result', 'text', 'error'],
    'recording:prepared': ['recording_prepared'], 'recording:started': ['recording_started'], 'recording:listen': ['recording_listen', 'on'], 'recording:finished': ['recording_finished'],
    'recording:cancel': ['recording_cancel'], 'recording:error': ['recording_error', 'message', 'stage'], 'camera:failed': ['camera_failed', 'message'],
    'recording:chunk': ['recording_chunk', 'data', 'ext'], 'recording:reset': ['recording_reset'], 'recording:save': ['recording_save', 'ext', 'duration'],
    'recording:begin': ['recording_begin'], 'recording:stop': ['recording_stop'], 'recording:pause': ['recording_pause', 'on'], 'recording:restart': ['recording_restart'],
    'recording:tick': ['recording_tick', 'seconds', 'paused'], 'video:target': ['video_export_target', 'ext'], 'video:copy': ['video_export_copy'], 'video:project': ['video_project_save', 'project'],
    'cloud:get': ['cloud_get'], 'cloud:connect': ['cloud_connect', 'endpoint', 'token'], 'cloud:disconnect': ['cloud_disconnect'],
    'drive:get': ['drive_get'], 'drive:connect': ['drive_connect'], 'drive:disconnect': ['drive_disconnect'],
    'cloud:upload': ['cloud_upload', 'id'], 'library:qr': ['library_qr', 'id'], 'qr:svg': ['qr_svg', 'link'], 'cloud:uploadData': ['cloud_upload_data', 'dataUrl', 'title'],
    'scroll:stop': ['scroll_stop', 'save'], 'scroll:auto': ['scroll_auto', 'on'],
    'update:status': ['update_status'], 'update:check': ['update_check'], 'update:install': ['update_install']
  };

  let scale = 1;
  win.scaleFactor().then((s) => { scale = s; });
  const local = {
    'window:close': () => win.close(),
    'window:minimize': () => win.minimize(),
    'window:toggleMaximize': () => win.toggleMaximize(),
    'window:setTitle': (title) => win.setTitle(title),
    'preview:close': () => win.close(),
    'shortcut:label': (accelerator) => StillGeometry.shortcutLabel(accelerator, platform),
    'editor:ocr': (dataUrl) => StillOCR.recognize(dataUrl),
    'editor:ocrLines': (dataUrl) => StillOCR.lines(dataUrl),
    'pin:move': async (dx, dy) => { const p = await win.outerPosition(); await win.setPosition(new T.dpi.PhysicalPosition(Math.round(p.x + dx * scale), Math.round(p.y + dy * scale))); },
    'pin:resize': async (delta) => { const s = await win.innerSize(); const w = Math.max(80, Math.round(s.width * (1 + delta))); await win.setSize(new T.dpi.PhysicalSize(w, Math.round(w * s.height / s.width))); },
    'pin:opacity': (value) => { document.body.style.opacity = value; },
    'pin:lock': (locked) => win.setIgnoreCursorEvents(locked)
  };

  function call(channel, args) {
    if (local[channel]) return Promise.resolve().then(() => local[channel](...args));
    const spec = commands[channel];
    if (!spec) return Promise.reject(new Error(`Unknown action ${channel}`));
    const [command, ...names] = spec;
    const payload = {};
    names.forEach((name, i) => { payload[name] = args[i] === undefined ? null : args[i]; });
    return T.core.invoke(command, payload);
  }

  window.still = {
    platform,
    invoke: (channel, ...args) => call(channel, args),
    send: (channel, ...args) => { call(channel, args).catch((error) => console.error(channel, error)); },
    on: (channel, callback, listening) => { let stop; win.listen(channel, (event) => callback(event.payload)).then((fn) => { stop = fn; if (listening) listening(); }); return () => stop && stop(); },
    fileUrl: (path) => T.core.convertFileSrc(path),
    raw: (command, bytes, headers) => T.core.invoke(command, bytes, { headers })
  };

  // Frameless windows: let the title bar areas move the window.
  addEventListener('DOMContentLoaded', () => {
    document.querySelectorAll('.titlebar, nav, header').forEach((el) => el.setAttribute('data-tauri-drag-region', ''));
  });
})();
