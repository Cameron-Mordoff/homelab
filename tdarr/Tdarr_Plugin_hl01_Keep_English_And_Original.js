/* Tdarr classic plugin: keep English + the title's original language, drop the
 * rest, and strip junk streams. Remux only (-c copy), never re-encodes.
 *
 * Original language comes from Radarr for movies (the {tmdb-N} id in the
 * filename) and from Sonarr for everything else (the series whose folder
 * contains the file).
 *
 * Audio kept: English, the original language and untagged/"und" tracks.
 * Commentary in those languages stays.
 * Subtitles kept: English, untagged/"und", and forced tracks in the original
 * language. By default subtitles are only cleaned in files already being
 * rewritten for audio.
 * Junk removed: embedded cover art (attached_pic video streams) and
 * attachments - except fonts while an ASS/SSA subtitle that needs them stays.
 *
 * A file left with a single untagged audio track gets it tagged as the
 * original language, so players stop showing "Unknown".
 *
 * MKVs that only need a language tag and/or attachments removed are edited in
 * place with mkvpropedit (header-only, seconds); anything that drops audio,
 * subtitle or cover-art streams is remuxed. Other containers are only touched
 * when audio/subtitle tracks go (tag and junk cleanup ride along).
 *
 * Temporary problems throw, so the file lands in Tdarr's error table and is
 * retried by unraid/tdarr-requeue-errors.sh instead of being marked done:
 *  - more than one hardlink (still shared with a seeding torrent - rewriting
 *    would break the link and double the space)
 *  - Radarr/Sonarr unreachable or returning an error
 * Permanent ones just skip: original language unknown/unmapped, or the
 * change would leave no audio track.
 *
 * Streams are removed by absolute index (-map -0:N), so untagged tracks
 * can't shift what gets removed.
 */
const { execFileSync } = require('child_process');
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
  Name: 'Keep English + Original Language (Radarr/Sonarr)',
  Type: 'Audio',
  Operation: 'Transcode',
  Description: 'Removes audio tracks that are not English, the original language (looked up in Radarr or '
    + 'Sonarr) or untagged, subtitle tracks that are not English, forced or untagged, and cover art / '
    + 'unneeded attachments. Remux only. Hardlinked (seeding) files error out to be retried later.',
  Version: '2.0',
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
      tooltip: 'Radarr API key (files with a {tmdb-N} id).',
    },
    {
      name: 'sonarr_url',
      type: 'string',
      defaultValue: 'http://192.168.1.10:8989',
      inputUI: { type: 'text' },
      tooltip: 'Sonarr base URL as seen from the Tdarr node.',
    },
    {
      name: 'sonarr_api_key',
      type: 'string',
      defaultValue: '',
      inputUI: { type: 'text' },
      tooltip: 'Sonarr API key (files without a {tmdb-N} id).',
    },
    {
      name: 'clean_junk',
      type: 'string',
      defaultValue: 'always',
      inputUI: { type: 'dropdown', options: ['always', 'with_audio', 'never'] },
      tooltip: 'Remove embedded cover art and attachments (fonts are kept while an ASS/SSA subtitle stays). '
        + 'with_audio: only in files already being rewritten for audio.',
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

// GET an *arr API path. Throws on network/HTTP errors (temporary - retried).
const arrGet = async (app, url, key, apiPath) => {
  if (!key) throw new Error(`${app.toLowerCase()}_api_key not set`);
  const res = await fetch(`${url.replace(/\/$/, '')}/api/v3/${apiPath}`, { headers: { 'X-Api-Key': key } });
  if (!res.ok) throw new Error(`${app} returned HTTP ${res.status}`);
  return res.json();
};

// { name, source } or { err } when the title has no usable original language.
const originalLanguage = async (filePath, inputs) => {
  const m = filePath.match(/\{tmdb-(\d+)\}/);
  if (m) {
    const movies = await arrGet('Radarr', inputs.radarr_url, inputs.radarr_api_key, `movie?tmdbId=${m[1]}`);
    if (!movies.length) return { err: `tmdb ${m[1]} is not in Radarr` };
    return { name: movies[0].originalLanguage && movies[0].originalLanguage.name, source: 'Radarr' };
  }
  const series = (await arrGet('Sonarr', inputs.sonarr_url, inputs.sonarr_api_key, 'series'))
    .find((s) => filePath.startsWith(`${s.path.replace(/\/$/, '')}/`));
  if (!series) return { err: 'no {tmdb-N} id and no Sonarr series folder contains the file' };
  return { name: series.originalLanguage && series.originalLanguage.name, source: `Sonarr: ${series.title}` };
};

// Forced flag, or "forced" in the title (plenty of releases only do the latter).
const isForced = (s) => Boolean((s.disposition && s.disposition.forced)
  || /forced/i.test((s.tags && s.tags.title) || ''));

const isFont = (s) => /font|truetype|opentype/i.test((s.tags && s.tags.mimetype) || '')
  || /\.(ttf|otf|ttc|woff2?)$/i.test((s.tags && s.tags.filename) || '');

// Pure decision logic, exported for the preview script.
// subsMode / junkMode: with_audio|always|never.
const decide = (streams, originalName, subsMode, junkMode = 'never') => {
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
  // Cover art and attachments. Fonts stay while a styled (ASS/SSA) subtitle
  // that may render with them is kept.
  const cleanJunk = junkMode === 'always' || (junkMode === 'with_audio' && dropAudio.length > 0);
  const keepsAss = streams.some((s) => s.codec_type === 'subtitle' && !dropSubs.includes(s)
    && ['ass', 'ssa'].includes(s.codec_name));
  const dropJunk = !cleanJunk ? [] : streams.filter((s) => (s.codec_type === 'video' && s.disposition
    && s.disposition.attached_pic) || (s.codec_type === 'attachment' && !(keepsAss && isFont(s))));
  return {
    audio, dropAudio, dropSubs, dropJunk, tagAudio,
  };
};

// How to apply a decision. Deleting attachments and setting a track language
// are header edits mkvpropedit makes in place (seconds, no rewrite); removing
// audio/subtitle/cover-art streams needs a full remux. Returns null (nothing
// to do), { mode: 'inplace', args } (mkvpropedit args after the file name) or
// { mode: 'remux' }.
const planChange = ({
  dropAudio, dropSubs, dropJunk, tagAudio,
}, container) => {
  if (!dropAudio.length && !dropSubs.length && !dropJunk.length && !tagAudio) return null;
  // In an MKV every junk stream with a filename is an attachment - ffprobe
  // shows image attachments (cover.jpg) as attached_pic video streams.
  // Cover art without a filename (MP4 style) is a real stream.
  const attachments = dropJunk.filter((s) => s.tags && s.tags.filename);
  const isMkv = String(container).toLowerCase() === 'mkv';
  const tracksGo = dropAudio.length > 0 || dropSubs.length > 0;
  // Non-MKVs can't be edited in place, and a full rewrite just to tag audio or
  // drop an MP4 thumbnail isn't worth it - they only change with track removal.
  if (!isMkv && !tracksGo) return null;
  if (tracksGo || attachments.length !== dropJunk.length) return { mode: 'remux' };
  // Only one audio track is left when tagAudio is set, so it's always a1.
  const args = tagAudio ? ['--edit', 'track:a1', '--set', `language=${tagAudio}`] : [];
  // By name: duplicates all go, which is fine - every one of them is junk.
  [...new Set(attachments.map((s) => s.tags.filename))].forEach((n) => args.push('--delete-attachment', `name:${n}`));
  return { mode: 'inplace', args };
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

  // Thrown errors put the file in the error table for tdarr-requeue-errors.sh.
  const links = fs.statSync(file.file).nlink;
  if (links > 1) throw new Error(`File has ${links} hardlinks (still seeding?) - retry later`);

  const orig = await originalLanguage(file.file, inputs);
  if (orig.err) { response.infoLog += `${orig.err} - skipped.\n`; return response; }
  if (!LANG_CODES[orig.name]) {
    response.infoLog += `Original language "${orig.name}" not in the code map - skipped.\n`;
    return response;
  }
  response.infoLog += `Original language: ${orig.name} (${orig.source})\n`;

  const decision = decide(file.ffProbeData.streams, orig.name, String(inputs.clean_subtitles), String(inputs.clean_junk));
  const {
    audio, dropAudio, dropSubs, dropJunk, tagAudio,
  } = decision;

  if (dropAudio.length && dropAudio.length === audio.length) {
    response.infoLog += 'Would remove every audio track - skipped.\n';
    return response;
  }
  const plan = planChange(decision, file.container);
  if (!plan) { response.infoLog += 'Nothing to change.\n'; return response; }
  const drop = [...dropAudio, ...dropSubs, ...dropJunk];

  if (plan.mode === 'inplace') {
    // Header-only edit of the library file itself; the next scan picks up the
    // changed file and finds nothing left to do.
    execFileSync('mkvpropedit', [file.file, ...plan.args], { stdio: 'pipe' });
    response.infoLog += `Edited in place with mkvpropedit: ${plan.args.join(' ')}\n`;
    return response;
  }

  drop.forEach((s) => {
    const label = s.codec_type === 'attachment' || s.codec_type === 'video'
      ? (s.tags && (s.tags.filename || s.tags.mimetype)) || s.codec_name
      : `${lang(s) || 'none'}${s.tags && s.tags.title ? `, ${s.tags.title}` : ''}`;
    response.infoLog += `Removing ${s.codec_type} #${s.index} (${label})\n`;
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
module.exports.planChange = planChange;
module.exports.LANG_CODES = LANG_CODES;
