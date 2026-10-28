// Read-only preview of what Tdarr_Plugin_hl01_Keep_English_And_Original would
// remove from every movie Radarr knows about and/or every episode Sonarr
// knows about. Changes nothing.
//
// Run inside the tdarr container (it has node + ffprobe and the same /data
// paths as Radarr/Sonarr):
//   docker exec -e RADARR_API_KEY=... -e SONARR_API_KEY=... -e SCOPE=tv \
//     tdarr node /app/configs/preview-language-cleanup.js > preview.tsv
//
// SCOPE: movies|tv|all (default all; a scope without its API key is skipped).
// CLEAN_SUBTITLES / CLEAN_JUNK: with_audio|always|never (defaults match the plugin).
//
// Output: TSV, one line per file that would change (REMUX = full rewrite,
// INPLACE = mkvpropedit header edit) or is skipped, then a summary on stderr.
const { execFileSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const { decide, planChange, LANG_CODES } = require(path.join(__dirname, 'Tdarr_Plugin_hl01_Keep_English_And_Original.js'));

const radarr = { url: (process.env.RADARR_URL || 'http://192.168.1.10:7878').replace(/\/$/, ''), key: process.env.RADARR_API_KEY };
const sonarr = { url: (process.env.SONARR_URL || 'http://192.168.1.10:8989').replace(/\/$/, ''), key: process.env.SONARR_API_KEY };
const scope = process.env.SCOPE || 'all';
const subsMode = process.env.CLEAN_SUBTITLES || 'with_audio';
const junkMode = process.env.CLEAN_JUNK || 'always';

const lang = (s) => ((s.tags && s.tags.language) || '').toLowerCase();
const describe = (s) => (s.codec_type === 'attachment' || s.codec_type === 'video'
  ? (s.tags && (s.tags.filename || s.tags.mimetype)) || s.codec_name
  : `${lang(s) || 'none'}${s.tags && s.tags.title ? `:${s.tags.title}` : ''}`);
const get = async (app, p) => (await fetch(`${app.url}/api/v3/${p}`, { headers: { 'X-Api-Key': app.key } })).json();

// [{ title, original, file, size }]
const movieFiles = async () => (await get(radarr, 'movie')).filter((m) => m.hasFile).map((m) => ({
  title: m.title, original: m.originalLanguage.name, file: m.movieFile.path, size: m.movieFile.size,
}));
const episodeFiles = async () => {
  const out = [];
  for (const s of await get(sonarr, 'series')) {
    if (!s.statistics || !s.statistics.episodeFileCount) continue;
    for (const f of await get(sonarr, `episodefile?seriesId=${s.id}`)) {
      out.push({
        title: `${s.title} ${f.relativePath.split('/').pop()}`, original: s.originalLanguage.name, file: f.path, size: f.size,
      });
    }
  }
  return out;
};

(async () => {
  const items = [];
  if (scope !== 'tv' && radarr.key) items.push(...await movieFiles());
  if (scope !== 'movies' && sonarr.key) items.push(...await episodeFiles());
  if (!items.length) { console.error('Nothing to scan - set RADARR_API_KEY and/or SONARR_API_KEY.'); process.exit(1); }

  const stats = {
    files: 0, remux: 0, inplace: 0, seeding: 0, skipped: 0, audioDropped: 0, subsDropped: 0, junkDropped: 0, tagged: 0, bytes: 0,
  };
  console.log(['status', 'title', 'original', 'audio_kept', 'audio_removed', 'subs_removed', 'junk_removed', 'gb'].join('\t'));

  for (const it of items) {
    stats.files += 1;
    const row = (status, ...rest) => console.log([status, it.title, it.original, ...rest].join('\t'));
    let streams;
    try {
      streams = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-show_streams', '-of', 'json', it.file],
        { maxBuffer: 64 * 1024 * 1024 })).streams;
    } catch (e) { stats.skipped += 1; row('ERROR-probe'); continue; }

    if (!LANG_CODES[it.original]) { stats.skipped += 1; row('SKIP-lang-unmapped'); continue; }
    const decision = decide(streams, it.original, subsMode, junkMode);
    const {
      audio, dropAudio, dropSubs, dropJunk, tagAudio,
    } = decision;
    const plan = planChange(decision, path.extname(it.file).slice(1));
    if (!plan) continue;

    const gb = (it.size / 1e9).toFixed(1);
    const kept = audio.filter((s) => !dropAudio.includes(s)).map(describe).join(', ') + (tagAudio ? ` -> tag ${tagAudio}` : '');
    const fields = [kept || '-', dropAudio.map(describe).join(', ') || '-', dropSubs.map(describe).join(', ') || '-',
      dropJunk.map(describe).join(', ') || '-', gb];
    if (dropAudio.length && dropAudio.length === audio.length) { stats.skipped += 1; row('SKIP-would-remove-all-audio', ...fields); continue; }
    if (fs.statSync(it.file).nlink > 1) { stats.seeding += 1; row('LATER-seeding', ...fields); continue; }

    stats[plan.mode] += 1;
    if (plan.mode === 'remux') stats.bytes += it.size;
    stats.audioDropped += dropAudio.length; stats.subsDropped += dropSubs.length; stats.junkDropped += dropJunk.length;
    if (tagAudio) stats.tagged += 1;
    row(plan.mode === 'remux' ? 'REMUX' : 'INPLACE', ...fields);
  }
  console.error(`files ${stats.files} | remux ${stats.remux} (${(stats.bytes / 1e12).toFixed(2)} TB rewritten) `
    + `| in place ${stats.inplace} | seeding, later ${stats.seeding} | skipped ${stats.skipped} `
    + `| audio tracks removed ${stats.audioDropped} | subtitle tracks removed ${stats.subsDropped} `
    + `| junk streams removed ${stats.junkDropped} | untagged audio tagged ${stats.tagged}`);
})();
