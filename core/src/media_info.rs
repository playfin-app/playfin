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
    /// Server's profile: "Dolby TrueHD + Dolby Atmos", "DTS-HD MA", "LC"…
    #[uniffi(default = None)]
    pub profile: Option<String>,
    /// "5.1", "7.1", "stereo"…
    #[uniffi(default = None)]
    pub channel_layout: Option<String>,
}

/// Technical description of a file (to know whether it plays as it is, and in which languages).
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct MediaInfo {
    pub container: Option<String>,
    pub video_codec: Option<String>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    /// "SDR", "HDR10", "HDR10Plus", "HLG", "DOVI", "DOVIWithHDR10"…
    pub video_range: Option<String>,
    /// Dolby Vision profile (5, 7, 8…), if any.
    #[uniffi(default = None)]
    pub dolby_vision_profile: Option<i32>,
    /// 8, 10 or 12 bits per colour.
    #[uniffi(default = None)]
    pub video_bit_depth: Option<i32>,
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
    if is_dolby_vision_only(&info) {
        notes.push(
            "Dolby Vision profile 5 (no HDR10 base): the colours may look wrong with this player"
                .into(),
        );
    } else if info
        .video_range
        .as_deref()
        .is_some_and(|r| r.starts_with("DOVI"))
    {
        notes.push("Dolby Vision: played as its HDR10 / HLG / SDR base".into());
    }
    PlaybackSupport {
        direct_play: direct,
        hardware_decoding: hardware,
        notes,
    }
}

/// Dolby Vision with nothing else to fall back on (profile 5): its colours need a Dolby Vision renderer.
fn is_dolby_vision_only(info: &MediaInfo) -> bool {
    info.dolby_vision_profile == Some(5) || info.video_range.as_deref() == Some("DOVI")
}

/// Badge of the picture: "Dolby Vision", "HDR10+", "HDR10", "HLG", or nothing for SDR.
#[uniffi::export]
pub fn video_range_label(info: MediaInfo) -> Option<String> {
    let range = info.video_range.as_deref().unwrap_or("");
    let label = if range.starts_with("DOVI") {
        "Dolby Vision"
    } else if range.starts_with("HDR10Plus") || range == "HDR10+" {
        "HDR10+"
    } else if range == "HDR10" || range == "HDR" {
        "HDR10"
    } else if range == "HLG" {
        "HLG"
    } else {
        return None;
    };
    Some(label.into())
}

/// Name of the sound format: "Dolby Atmos", "DTS:X", "DTS-HD MA", "Dolby TrueHD", "Dolby Digital+", "Dolby Digital",
/// "DTS", or the codec in capitals.
#[uniffi::export]
pub fn audio_format_label(stream: StreamInfo) -> String {
    let codec = stream.codec.to_ascii_lowercase();
    let described = format!(
        "{} {}",
        stream.profile.as_deref().unwrap_or(""),
        stream.title.as_deref().unwrap_or("")
    )
    .to_ascii_lowercase();
    if described.contains("atmos") {
        return "Dolby Atmos".into();
    }
    if described.contains("dts:x") || described.contains("dts-x") {
        return "DTS:X".into();
    }
    match codec.as_str() {
        "truehd" | "mlp" => "Dolby TrueHD".into(),
        "eac3" => "Dolby Digital+".into(),
        "ac3" => "Dolby Digital".into(),
        "dts" | "dca" if described.contains("dts-hd ma") || described.contains("master audio") => {
            "DTS-HD MA".into()
        }
        "dts" | "dca" if described.contains("dts-hd") => "DTS-HD".into(),
        "dts" | "dca" => "DTS".into(),
        "flac" => "FLAC".into(),
        "alac" => "ALAC".into(),
        "opus" => "Opus".into(),
        c if c.starts_with("pcm") => "PCM".into(),
        c => c.to_ascii_uppercase(),
    }
}

/// "7.1", "5.1", "Stereo", "Mono" (from the layout, otherwise the number of channels).
#[uniffi::export]
pub fn audio_channels_label(stream: StreamInfo) -> Option<String> {
    let channels = stream.channels.unwrap_or(0);
    let label = match stream
        .channel_layout
        .as_deref()
        .map(str::to_ascii_lowercase)
    {
        Some(l) if l.starts_with("7.1") => "7.1",
        Some(l) if l.starts_with("5.1") => "5.1",
        Some(l) if l == "stereo" => "Stereo",
        Some(l) if l == "mono" => "Mono",
        _ => match channels {
            8 => "7.1",
            6 => "5.1",
            2 => "Stereo",
            1 => "Mono",
            0 => return None,
            n => return Some(format!("{n} ch")),
        },
    };
    Some(label.into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn audio(
        codec: &str,
        profile: Option<&str>,
        channels: i32,
        layout: Option<&str>,
    ) -> StreamInfo {
        StreamInfo {
            codec: codec.into(),
            language: None,
            channels: Some(channels),
            is_default: false,
            is_external: false,
            title: None,
            profile: profile.map(Into::into),
            channel_layout: layout.map(Into::into),
        }
    }

    fn video(range: &str, dv_profile: Option<i32>) -> MediaInfo {
        MediaInfo {
            container: Some("mkv".into()),
            video_codec: Some("hevc".into()),
            width: Some(3840),
            height: Some(2160),
            video_range: Some(range.into()),
            dolby_vision_profile: dv_profile,
            video_bit_depth: Some(10),
            audio: vec![audio("eac3", None, 6, None)],
            subtitles: vec![],
        }
    }

    #[test]
    fn audio_formats_are_named_like_on_the_box() {
        let atmos = audio("truehd", Some("Dolby TrueHD + Dolby Atmos"), 8, Some("7.1"));
        assert_eq!(audio_format_label(atmos.clone()), "Dolby Atmos");
        assert_eq!(audio_channels_label(atmos).as_deref(), Some("7.1"));
        assert_eq!(
            audio_format_label(audio("dts", Some("DTS-HD MA"), 6, None)),
            "DTS-HD MA"
        );
        assert_eq!(
            audio_format_label(audio("dts", Some("DTS:X"), 8, None)),
            "DTS:X"
        );
        assert_eq!(audio_format_label(audio("dts", None, 6, None)), "DTS");
        let mut commentary = audio("dts", None, 2, None);
        commentary.title = Some("Commentary - Max".into());
        assert_eq!(
            audio_format_label(commentary),
            "DTS",
            "not fooled by the track title"
        );
        assert_eq!(
            audio_format_label(audio("eac3", None, 6, None)),
            "Dolby Digital+"
        );
        assert_eq!(audio_format_label(audio("aac", Some("LC"), 2, None)), "AAC");
        assert_eq!(
            audio_channels_label(audio("aac", None, 2, None)).as_deref(),
            Some("Stereo")
        );
        assert_eq!(
            audio_channels_label(audio("ac3", None, 6, None)).as_deref(),
            Some("5.1")
        );
    }

    #[test]
    fn video_ranges_and_dolby_vision_profile_5() {
        assert_eq!(
            video_range_label(video("DOVIWithHDR10", Some(8))).as_deref(),
            Some("Dolby Vision")
        );
        assert_eq!(
            video_range_label(video("HDR10Plus", None)).as_deref(),
            Some("HDR10+")
        );
        assert_eq!(
            video_range_label(video("HLG", None)).as_deref(),
            Some("HLG")
        );
        assert_eq!(video_range_label(video("SDR", None)), None);

        let p5 = playback_support(video("DOVI", Some(5)));
        assert!(p5.notes.iter().any(|n| n.contains("profile 5")));
        let p8 = playback_support(video("DOVIWithHDR10", Some(8)));
        assert!(
            p8.notes
                .iter()
                .any(|n| n.contains("HDR10 / HLG / SDR base"))
        );
        assert!(p8.direct_play);
    }
}
