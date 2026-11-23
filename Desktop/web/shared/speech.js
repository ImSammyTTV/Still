// Transcribe Recording on Windows and Linux: the recording's sound is cut into pieces of a few minutes, each sent as
// a small mono WAV file to the AI service chosen in Settings → AI, and what comes back becomes text captions
// (marked `speech`, so transcribing again replaces them rather than adding a second set). Shared by the video editor
// and the tests.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.StillSpeech = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  // 16 kHz mono is all speech needs: five minutes come to under 10 MB, inside every service's upload limit.
  const RATE = 16000;
  const PIECE = 300;
  const LONGEST = 90; // characters in one caption before it is split

  // A 16-bit PCM WAV file holding `samples` (-1 to 1) at `rate`.
  const wav = (samples, rate = RATE) => {
    const out = new Uint8Array(44 + samples.length * 2), view = new DataView(out.buffer);
    const text = (at, s) => { for (let i = 0; i < s.length; i++) out[at + i] = s.charCodeAt(i); };
    text(0, 'RIFF'); view.setUint32(4, 36 + samples.length * 2, true); text(8, 'WAVE');
    text(12, 'fmt '); view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
    view.setUint32(24, rate, true); view.setUint32(28, rate * 2, true); view.setUint16(32, 2, true); view.setUint16(34, 16, true);
    text(36, 'data'); view.setUint32(40, samples.length * 2, true);
    for (let i = 0; i < samples.length; i++) { const s = Math.max(-1, Math.min(1, samples[i] || 0)); view.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true); }
    return out;
  };

  // The stretches of the clip to send, each at most `size` seconds.
  const pieces = (clip, size = PIECE) => {
    const out = [];
    for (let at = clip.start; at < clip.end - 0.05; at += size) out.push({ start: at, end: Math.min(clip.end, at + size) });
    return out;
  };

  // Long stretches of speech split at word boundaries into captions of at most LONGEST characters, each given a share
  // of the stretch's time in proportion to its length.
  const split = (segment) => {
    const words = segment.text.trim().split(/\s+/).filter(Boolean), lines = [];
    for (const word of words) {
      const last = lines[lines.length - 1];
      if (last && (last + ' ' + word).length <= LONGEST) lines[lines.length - 1] = last + ' ' + word; else lines.push(word.slice(0, LONGEST));
    }
    const total = lines.reduce((sum, l) => sum + l.length, 0) || 1, span = segment.end - segment.start;
    let at = segment.start;
    return lines.map((line) => { const start = at; at += (span * line.length) / total; return { start, end: at, text: line }; });
  };

  // Captions from the stretches each piece came back with (their times counted from the piece's start), kept inside
  // the clip, replacing any captions an earlier transcription made.
  const toCaptions = (captions, results, clip) => {
    const made = [];
    for (const { offset, segments } of results) {
      for (const s of segments || []) {
        for (const part of split({ start: offset + s.start, end: offset + s.end, text: String(s.text || '') })) {
          const start = Math.max(clip.start, part.start), end = Math.min(clip.end, part.end);
          if (part.text && end - start > 0.05) made.push({ start, end, text: part.text, position: 'bottom', size: 'medium', speech: true });
        }
      }
    }
    return [...(captions || []).filter((c) => !c.speech), ...made].sort((a, b) => a.start - b.start);
  };

  // The words of the transcription, as plain text to copy.
  const transcript = (captions) => (captions || []).filter((c) => c.speech).map((c) => c.text).join(' ').replace(/\s+/g, ' ').trim();

  return { RATE, PIECE, LONGEST, wav, pieces, split, toCaptions, transcript };
});
