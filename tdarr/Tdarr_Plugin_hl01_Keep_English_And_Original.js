/* Tdarr classic plugin: keep English + the movie's original language, drop the
 * rest. Remux only (-c copy), never re-encodes.
 *
 * Audio kept: English, the original language (from Radarr, via the {tmdb-N}
 * id in the filename), and untagged/"und" tracks. Commentary in those
 * languages stays.
 * Subtitles kept: English, untagged/"und", and forced tracks in the original
 * language. By default
 * subtitles are only cleaned in files already being rewritten for audio.
 *
 * A file left with a single untagged audio track gets it tagged as the
 * original language, so players stop showing "Unknown".
 *
 * Skipped entirely:
 *  - files with more than one hardlink (still shared with a torrent that's
 *    seeding - rewriting would break the link and double the space)
 *  - files whose original language can't be determined
 *  - anything that would leave no audio track
 *
 * Streams are removed by absolute index (-map -0:N), so untagged tracks
 * can't shift what gets removed.
 */
const fs = require('fs');

// Radarr language name -> every code a muxer might have written for it
// (ISO 639-2/B, 639-2/T, 639-1, plus common variants).
const LANG_CODES = {
  English: ['eng', 'en'],
  French: ['fre', 'fra', 'fr'],
  German: ['ger', 'deu', 'de'],
  Italian: ['ita', 'it'],
  Spanish: ['spa', 'es'],
  'Spanish (Latino)': ['spa', 'es'],
  Portuguese: ['por', 'pt'],
  'Portuguese (Brazil)': ['por', 'pt'],
  Japanese: ['jpn', 'ja'],
  Korean: ['kor', 'ko'],
  Chinese: ['chi', 'zho', 'zh', 'cmn', 'yue'],
  Cantonese: ['chi', 'zho', 'zh', 'yue'],
  Mandarin: ['chi', 'zho', 'zh', 'cmn'],
  Swedish: ['swe', 'sv'],
  Norwegian: ['nor', 'nob', 'nno', 'no', 'nb', 'nn'],
  Danish: ['dan', 'da'],
  Finnish: ['fin', 'fi'],
  Icelandic: ['ice', 'isl', 'is'],
  Dutch: ['dut', 'nld', 'nl'],
  Flemish: ['dut', 'nld', 'nl'],
  Russian: ['rus', 'ru'],
  Ukrainian: ['ukr', 'uk'],
  Polish: ['pol', 'pl'],
  Czech: ['cze', 'ces', 'cs'],
  Hungarian: ['hun', 'hu'],
  Greek: ['gre', 'ell', 'el'],
  Turkish: ['tur', 'tr'],
  Arabic: ['ara', 'ar'],
  Hebrew: ['heb', 'he'],
  Persian: ['per', 'fas', 'fa'],
  Hindi: ['hin', 'hi'],
  Tamil: ['tam', 'ta'],
  Telugu: ['tel', 'te'],
  Thai: ['tha', 'th'],
  Vietnamese: ['vie', 'vi'],
  Indonesian: ['ind', 'id'],
  Romanian: ['rum', 'ron', 'ro'],
};
// Untagged, undetermined, multiple languages, no linguistic content.
const UNDEFINED = ['und', '', 'mul', 'zxx'];

const details = () => ({
  id: 'Tdarr_Plugin_hl01_Keep_English_And_Original',
  Stage: 'Pre-processing',
  Name: 'Keep English + Original Language (Radarr)',
  Type: 'Audio',
  Operation: 'Transcode',
  Description: 'Removes audio tracks that are not English, the original language (looked up in Radarr) '
    + 'or untagged, and subtitle tracks that are not English, forced or untagged. Remux only. '
    + 'Skips hardlinked (seeding) files.',
  Version: '1.0',
  Tags: 'pre-processing,ffmpeg,audio only,subtitle only,configurable',
  Inputs: [
    {
      name: 'radarr_url',
      type: 'string',
      defaultValue: 'http://192.168.1.10:7878',
      inputUI: { type: 'text' },
      tooltip: 'Radarr base URL as seen from the Tdarr node.',
    },
    {
      name: 'radarr_api_key',
      type: 'string',
      defaultValue: '',
      inputUI: { type: 'text' },
      tooltip: 'Radarr API key.',
    },
    {
      name: 'clean_subtitles',
      type: 'string',
      defaultValue: 'with_audio',
      inputUI: { type: 'dropdown', options: ['with_audio', 'always', 'never'] },
      tooltip: 'Remove subtitle tracks that are not English, forced or untagged. with_audio: only in files '
        + 'already being rewritten for audio (subtitles alone save almost no space, and a rewrite is a full '
        + 'file of parity writes).',
    },
  ],
});

const lang = (s) => ((s.tags && s.tags.language) || '').toLowerCase();

const originalLanguage = async (fileName, url, key) => {
  const m = fileName.match(/\{tmdb-(\d+)\}/);
  if (!m) return { err: 'no {tmdb-N} id in filename' };
  const res = await fetch(`${url.replace(/\/$/, '')}/api/v3/movie?tmdbId=${m[1]}`, {
    headers: { 'X-Api-Key': key },
  });
  if (!res.ok) return { err: `Radarr returned HTTP ${res.status}` };
  const movies = await res.json();
  if (!movies.length) return { err: `tmdb ${m[1]} is not in Radarr` };
  return { name: movies[0].originalLanguage && movies[0].originalLanguage.name };
};

// Forced flag, or "forced" in the title (plenty of releases only do the latter).
const isForced = (s) => Boolean((s.disposition && s.disposition.forced)
  || /forced/i.test((s.tags && s.tags.title) || ''));

// Pure decision logic, exported for the preview script. subsMode: with_audio|always|never.
const decide = (streams, originalName, subsMode) => {
  const keepAudio = new Set([...LANG_CODES.English, ...UNDEFINED, ...(LANG_CODES[originalName] || [])]);
  const audio = streams.filter((s) => s.codec_type === 'audio');
  const dropAudio = audio.filter((s) => !keepAudio.has(lang(s)));
  const cleanSubs = subsMode === 'always' || (subsMode === 'with_audio' && dropAudio.length > 0);
  // Forced subs only matter for audio that stays, so they're kept in the
  // original language too; other subs only in English or untagged.
  const dropSubs = !cleanSubs ? [] : streams.filter((s) => s.codec_type === 'subtitle'
    && !LANG_CODES.English.includes(lang(s)) && !UNDEFINED.includes(lang(s))
    && !(isForced(s) && keepAudio.has(lang(s))));
  // A lone untagged audio track can only be the original language (Radarr
  // grabbed it as such) - tag it so players stop showing "Unknown". Several
  // untagged tracks are left alone: no way to tell which is which.
  const keptAudio = audio.filter((s) => !dropAudio.includes(s));
  const tagAudio = keptAudio.length === 1 && ['und', ''].includes(lang(keptAudio[0])) && LANG_CODES[originalName]
    ? LANG_CODES[originalName][0] : null;
  return { audio, dropAudio, dropSubs, tagAudio };
};

const plugin = async (file, librarySettings, inputs, otherArguments) => {
  const lib = require('../methods/lib')();
  // eslint-disable-next-line no-param-reassign
  inputs = lib.loadDefaultValues(inputs, details);
  const response = {
    processFile: false,
    preset: '',
    container: `.${file.container}`,
    handBrakeMode: false,
    FFmpegMode: true,
    reQueueAfter: false,
    infoLog: '',
  };

  if (file.fileMedium !== 'video') { response.infoLog += 'Not a video - skipped.\n'; return response; }
  if (!inputs.radarr_api_key) { response.infoLog += 'radarr_api_key not set - skipped.\n'; return response; }

  const links = fs.statSync(file.file).nlink;
  if (links > 1) {
    response.infoLog += `File has ${links} hardlinks (still seeding?) - skipped, will retry on a later scan.\n`;
    return response;
  }

  let orig;
  try {
    orig = await originalLanguage(file.meta.FileName || file.file, inputs.radarr_url, inputs.radarr_api_key);
  } catch (e) {
    response.infoLog += `Radarr lookup failed (${e.message}) - skipped.\n`;
    return response;
  }
  if (orig.err) { response.infoLog += `${orig.err} - skipped.\n`; return response; }
  if (!LANG_CODES[orig.name]) {
    response.infoLog += `Original language "${orig.name}" not in the code map - skipped.\n`;
    return response;
  }
  response.infoLog += `Original language: ${orig.name}\n`;

  const {
    audio, dropAudio, dropSubs, tagAudio,
  } = decide(file.ffProbeData.streams, orig.name, String(inputs.clean_subtitles));

  if (dropAudio.length && dropAudio.length === audio.length) {
    response.infoLog += 'Would remove every audio track - skipped.\n';
    return response;
  }
  const drop = [...dropAudio, ...dropSubs];
  if (!drop.length && !tagAudio) { response.infoLog += 'Nothing to change.\n'; return response; }

  drop.forEach((s) => {
    response.infoLog += `Removing ${s.codec_type} #${s.index} (${lang(s) || 'none'}${s.tags && s.tags.title ? `, ${s.tags.title}` : ''})\n`;
  });
  // Only one audio track is left when tagAudio is set, so it's always a:0.
  const tag = tagAudio ? ` -metadata:s:a:0 language=${tagAudio}` : '';
  if (tagAudio) response.infoLog += `Tagging the untagged audio track as ${tagAudio}\n`;
  response.preset = `, -map 0 ${drop.map((s) => `-map -0:${s.index}`).join(' ')}${tag} -c copy -max_muxing_queue_size 9999`;
  response.processFile = true;
  return response;
};

module.exports.details = details;
module.exports.plugin = plugin;
module.exports.decide = decide;
module.exports.LANG_CODES = LANG_CODES;
