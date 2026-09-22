import ConversionCore
import SwiftUI

extension ConversionOptionsView {
    @ViewBuilder var performanceOptionsSection: some View {
        if showPerformance && (category == nil || ["audio", "video"].contains(category ?? "")) {
            Section("Performance") {
                Picker("CPU use", selection: $settings.mediaOptions.cpuProfile) {
                    ForEach(CPUProfile.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.accessibilityLabel("CPU use")
                Text("Balances concurrent conversions and software encoding work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var mediaOptionsSections: some View {
        if category == nil || ["audio", "video"].contains(category ?? "") {
            Section("Audio and video") {
                if category == nil || ["mp3", "aac", "m4a", "ogg"].contains(targetID) {
                    Picker("Audio mode", selection: $settings.mediaOptions.audioMode) {
                        Text("Quality").tag(AudioEncodingMode.quality)
                        Text("Bitrate").tag(AudioEncodingMode.bitrate)
                    }.accessibilityLabel("Audio mode")
                    if settings.mediaOptions.audioMode == .quality {
                        LabeledContent("Audio quality") {
                            Slider(value: $settings.mediaOptions.audioQuality, in: 0...100)
                                .accessibilityLabel("Audio quality")
                            Text(settings.mediaOptions.audioQuality / 100, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 45)
                        }
                        Text("Higher quality can make larger files. Applies to MP3, AAC, M4A, and Ogg audio.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if category == nil || category == "video"
                    || ["opus", "wma", "ac3", "eac3"].contains(targetID)
                    || (["mp3", "aac", "m4a", "ogg"].contains(targetID) && settings.mediaOptions.audioMode == .bitrate) {
                    Stepper(value: $settings.mediaOptions.audioBitrateKbps, in: 8...1536, step: 8) {
                        TextField("Audio bitrate (kb/s)", value: $settings.mediaOptions.audioBitrateKbps, format: .number)
                            .accessibilityLabel("Audio bitrate")
                    }.accessibilityLabel("Audio bitrate")
                    if category == nil || ["opus", "wma", "ac3", "eac3"].contains(targetID) {
                        Text("Opus, WMA, AC3, and EAC3 use bitrate in both modes. Opus uses a variable bitrate target.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if category == nil || ["flac", "mka"].contains(targetID) {
                    Stepper("FLAC compression: \(settings.mediaOptions.flacCompressionLevel)",
                            value: $settings.mediaOptions.flacCompressionLevel, in: 0...12).accessibilityLabel("FLAC compression")
                    Text("Higher compression can take longer. FLAC audio stays lossless.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showsVideoOptions {
                    Picker("Video codec", selection: $settings.mediaOptions.videoCodec) {
                        ForEach(category == nil ? VideoCodec.allCases : VideoCodec.choices(for: targetID), id: \.self) {
                            Text($0.title).tag($0)
                        }
                        if category != nil, !VideoCodec.choices(for: targetID).contains(settings.mediaOptions.videoCodec) {
                            Text("\(settings.mediaOptions.videoCodec.title) (unavailable)").tag(settings.mediaOptions.videoCodec)
                        }
                    }.accessibilityLabel("Video codec")
                    if settings.mediaOptions.videoCodec == .ffv1 {
                        Text("FFV1 losslessly preserves the decoded pixel format. Quality and bitrate settings do not apply.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if [.mpeg2video, .msmpeg4].contains(settings.mediaOptions.videoCodec) {
                        Text("An older codec, kept for players that expect it. Quality sets a quantizer, so files are larger than H.264 at similar quality.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if settings.mediaOptions.videoCodec == .prores {
                        Picker("ProRes profile", selection: $settings.mediaOptions.proResProfile) {
                            ForEach(ProResProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.accessibilityLabel("ProRes profile")
                        Text("Higher profiles produce larger files. 4444 and 4444 XQ can retain transparency.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Picker("Video mode", selection: $settings.mediaOptions.videoMode) {
                            Text("Quality").tag(MediaEncodingMode.quality)
                            Text("Bitrate").tag(MediaEncodingMode.bitrate)
                        }.accessibilityLabel("Video mode")
                        if settings.mediaOptions.videoMode == .quality {
                            LabeledContent("Video quality") {
                                Slider(value: $settings.mediaOptions.videoQuality, in: 0...100)
                                    .accessibilityLabel("Video quality")
                                Text(settings.mediaOptions.videoQuality / 100, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit().frame(width: 45)
                            }
                            Text("Higher quality can make larger files. 100% does not guarantee a lossless conversion.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Stepper(value: $settings.mediaOptions.videoBitrateKbps, in: 32...200_000, step: 50) {
                                TextField("Video bitrate (kb/s)", value: $settings.mediaOptions.videoBitrateKbps, format: .number)
                                    .accessibilityLabel("Video bitrate")
                            }.accessibilityLabel("Video bitrate")
                        }
                    }
                    if category == nil || settings.mediaOptions.videoCodec == .vp9
                        || (settings.mediaOptions.videoCodec == .automatic && targetID == "webm") {
                        Stepper("VP9 speed: \(settings.mediaOptions.vp9Speed)", value: $settings.mediaOptions.vp9Speed, in: 0...8).accessibilityLabel("VP9 speed")
                    }
                    if category == nil || settings.mediaOptions.videoCodec == .av1 {
                        Stepper("AV1 speed: \(settings.mediaOptions.av1Speed)", value: $settings.mediaOptions.av1Speed, in: 0...13).accessibilityLabel("AV1 speed")
                    }
                    if category == nil || [.vp9, .av1].contains(settings.mediaOptions.videoCodec)
                        || (settings.mediaOptions.videoCodec == .automatic && targetID == "webm") {
                        Text("Lower speed settings take longer and can compress more efficiently.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Video frame rate", selection: $settings.mediaOptions.videoFrameRate) {
                        ForEach(VideoFrameRate.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityLabel("Video frame rate")
                    Text("Preserve source retains frame timing within the container's precision. A fixed rate can add or drop frames.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Sample rate", selection: $settings.mediaOptions.sampleRate) {
                    Text("Keep source").tag(Optional<Int>.none)
                    ForEach([8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000], id: \.self) {
                        Text("\($0) Hz").tag(Optional($0))
                    }
                }.accessibilityLabel("Sample rate")
                Picker("Audio channels", selection: $settings.mediaOptions.channels) {
                    Text("Keep source").tag(Optional<Int>.none)
                    Text("Mono").tag(Optional(1))
                    Text("Stereo").tag(Optional(2))
                }.accessibilityLabel("Audio channels")
                Toggle("Keep media metadata", isOn: $settings.mediaOptions.preserveMetadata).accessibilityLabel("Keep media metadata")
                Toggle("Keep embedded cover art", isOn: $settings.mediaOptions.preserveCoverArt).accessibilityLabel("Keep embedded cover art")
                Text("If the output cannot keep an embedded picture, conversion stops. Turn this off to omit it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
