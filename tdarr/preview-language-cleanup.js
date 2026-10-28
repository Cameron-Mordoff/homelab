// Read-only preview of what Tdarr_Plugin_hl01_Keep_English_And_Original would
// remove from every movie Radarr knows about. Changes nothing.
//
// Run inside the tdarr container (it has node + ffprobe and the same /data
// paths as Radarr):
//   docker exec -e RADARR_URL=http://192.168.1.10:7878 -e RADARR_API_KEY=... \
//     tdarr node /app/configs/preview-language-cleanup.js > preview.tsv
//
// Output: TSV, one line per movie that would change (or is skipped), then a
// summary on stderr.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { decide, LANG_CODES } = require(path.join(__dirname, 'Tdarr_Plugin_hl01_Keep_English_And_Original.js'));

const url = (process.env.RADARR_URL || 'http://192.168.1.10:7878').replace(/\/$/, '');
const key = process.env.RADARR_API_KEY;
if (!key) { console.error('Set RADARR_API_KEY.'); process.exit(1); }
const subsMode = process.env.CLEAN_SUBTITLES || 'with_audio';   // with_audio|always|never

const lang = (s) => ((s.tags && s.tags.language) || '').toLowerCase();
const describe = (s) => `${lang(s) || 'none'}${s.tags && s.tags.title ? `:${s.tags.title}` : ''}`;

(async () => {
  const movies = (await (await fetch(`${url}/api/v3/movie`, { headers: { 'X-Api-Key': key } })).json())
    .filter((m) => m.hasFile);
  const stats = {
    files: 0, change: 0, seeding: 0, skipped: 0, audioDropped: 0, subsDropped: 0, tagged: 0, bytes: 0,
  };
  console.log(['status', 'title', 'original', 'audio_kept', 'audio_removed', 'subs_removed', 'gb'].join('\t'));

  for (const m of movies) {
    stats.files += 1;
    const file = m.movieFile.path;
    const row = (status, ...rest) => console.log([status, m.title, m.originalLanguage.name, ...rest].join('\t'));
    let streams;
    try {
      streams = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-of', 'json', file],
        { maxBuffer: 64 * 1024 * 1024 })).streams;
    } catch (e) { stats.skipped += 1; row('ERROR-probe'); continue; }

    if (!LANG_CODES[m.originalLanguage.name]) { stats.skipped += 1; row('SKIP-lang-unmapped'); continue; }
    const {
      audio, dropAudio, dropSubs, tagAudio,
    } = decide(streams, m.originalLanguage.name, subsMode);
    if (!dropAudio.length && !dropSubs.length && !tagAudio) continue;
    if (tagAudio) stats.tagged += 1;

    const gb = (m.movieFile.size / 1e9).toFixed(1);
    const kept = audio.filter((s) => !dropAudio.includes(s)).map(describe).join(', ') + (tagAudio ? ` -> tag ${tagAudio}` : '');
    const fields = [kept || '-', dropAudio.map(describe).join(', ') || '-', dropSubs.map(describe).join(', ') || '-', gb];
    if (dropAudio.length && dropAudio.length === audio.length) { stats.skipped += 1; row('SKIP-would-remove-all-audio', ...fields); continue; }
    if (fs.statSync(file).nlink > 1) { stats.seeding += 1; row('LATER-seeding', ...fields); continue; }

    stats.change += 1; stats.audioDropped += dropAudio.length; stats.subsDropped += dropSubs.length;
    stats.bytes += m.movieFile.size;
    row('CHANGE', ...fields);
  }
  console.error(`files ${stats.files} | would change ${stats.change} (${(stats.bytes / 1e12).toFixed(2)} TB rewritten) `
    + `| seeding, later ${stats.seeding} | skipped ${stats.skipped} `
    + `| audio tracks removed ${stats.audioDropped} | subtitle tracks removed ${stats.subsDropped} `
    + `| untagged audio tagged ${stats.tagged}`);
})();
