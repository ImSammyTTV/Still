// Works out how loud a recording is over time (for Tighten Pauses, Speed Up Waits and music) away from the page.
// On a long recording, mixing every sample down to one channel on the page stalled the video editor.
importScripts('shared/trim.js');
self.onmessage = ({ data }) => {
  const { channels, rate } = data, mono = new Float32Array(channels[0]?.length || 0);
  for (const channel of channels) for (let i = 0; i < mono.length; i++) mono[i] += channel[i] / channels.length;
  self.postMessage(StillTrim.levelsOf(mono, rate));
};
