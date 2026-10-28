//! What a file contains (tracks) and whether the app can play it directly.

/// An audio or subtitle track of a file, as the server describes it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct StreamInfo {
    pub codec: String,
    /// Language code (ISO 639-2 most often, e.g. "fre"), if known.
    pub language: Option<String>,
    pub channels: Option<i32>,
    pub is_default: bool,
    pub is_external: bool,
    pub title: Option<String>,
}

/// Technical description of a file (to know whether it plays as it is, and in which languages).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaInfo {
    pub container: Option<String>,
    pub video_codec: Option<String>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    /// "SDR", "HDR10", "HLG", "DOVI"…
    pub video_range: Option<String>,
    pub audio: Vec<StreamInfo>,
    pub subtitles: Vec<StreamInfo>,
}

/// Can the file be played as it is (direct play) with our player, and how?
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct PlaybackSupport {
    pub direct_play: bool,
    /// Video decoding by the chip (VideoToolbox): less heat and battery.
    pub hardware_decoding: bool,
    /// Reasons for a possible problem (unknown codec…), in English.
    pub notes: Vec<String>,
}

/// Codecs that our player (mpv + FFmpeg, LGPL build) can decode.
const VIDEO_CODECS: &[&str] = &[
    "h264",
    "hevc",
    "h265",
    "av1",
    "vp9",
    "vp8",
    "mpeg2video",
    "mpeg1video",
    "mpeg4",
    "msmpeg4v3",
    "vc1",
    "wmv3",
    "theora",
    "prores",
    "mjpeg",
    "dnxhd",
    "hap",
];

const AUDIO_CODECS: &[&str] = &[
    "aac",
    "ac3",
    "eac3",
    "truehd",
    "mlp",
    "dts",
    "dca",
    "flac",
    "opus",
    "vorbis",
    "mp3",
    "mp2",
    "alac",
    "wmav2",
    "wmapro",
    "pcm_s16le",
    "pcm_s24le",
    "pcm_s32le",
    "pcm_f32le",
    "pcm_bluray",
    "pcm_dvd",
    "amr_nb",
];

const SUBTITLE_CODECS: &[&str] = &[
    "srt",
    "subrip",
    "ass",
    "ssa",
    "webvtt",
    "vtt",
    "pgssub",
    "hdmv_pgs_subtitle",
    "pgs",
    "dvdsub",
    "dvd_subtitle",
    "vobsub",
    "dvbsub",
    "dvb_subtitle",
    "mov_text",
    "text",
    "microdvd",
    "sami",
];

/// Is direct play possible? Pure function: video, audio and subtitle codecs compared to what mpv can play.
#[uniffi::export]
pub fn playback_support(info: MediaInfo) -> PlaybackSupport {
    let lower = |c: &str| c.to_ascii_lowercase();
    let mut notes = Vec::new();
    let mut direct = true;
    let video = info.video_codec.as_deref().map(lower);
    if let Some(codec) = &video
        && !VIDEO_CODECS.contains(&codec.as_str())
    {
        direct = false;
        notes.push(format!("Unsupported video codec: {}", codec.to_uppercase()));
    }
    // Audio is playable if at least one track is (we will choose that one).
    if !info.audio.is_empty()
        && !info
            .audio
            .iter()
            .any(|a| AUDIO_CODECS.contains(&lower(&a.codec).as_str()))
    {
        direct = false;
        notes.push("No playable audio track".into());
    }
    let unreadable_subs = info
        .subtitles
        .iter()
        .filter(|s| !SUBTITLE_CODECS.contains(&lower(&s.codec).as_str()))
        .count();
    if unreadable_subs > 0 {
        notes.push(format!(
            "{unreadable_subs} subtitle(s) in an unsupported format"
        ));
    }
    let hardware = matches!(video.as_deref(), Some("h264" | "hevc" | "h265"));
    if matches!(video.as_deref(), Some("av1")) {
        notes.push("AV1: hardware decoding only on M3 chips and newer".into());
    }
    if info.video_range.as_deref() == Some("DOVI") {
        notes.push("Dolby Vision: shown as HDR10 or SDR depending on the display".into());
    }
    PlaybackSupport {
        direct_play: direct,
        hardware_decoding: hardware,
        notes,
    }
}
