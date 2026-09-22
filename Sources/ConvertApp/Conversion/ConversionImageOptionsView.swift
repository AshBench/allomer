import ConversionCore
import SwiftUI

extension ConversionOptionsView {
    @ViewBuilder var imageOptionsSections: some View {
        if category == nil || (category == "image" && !["svg", "svgz"].contains(targetID)
            && (sourceCategory != "video" || targetID == "webp"))
            || (targetID == "pdf" && sourceCategory == "image") {
            Section("Images") {
                if ["ico", "icns"].contains(targetID) {
                    Text("Creates standard icon sizes. Fits artwork inside a square with transparent padding.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if sourceFormatID == "icon" {
                    Text("Exports artwork layers on a transparent 1024-pixel canvas. Icon materials and background styling are not included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if category == nil || ["jpeg", "heic", "avif", "jxl", "webp", "pdf"].contains(targetID) {
                    LabeledContent("Quality") {
                        Slider(value: $settings.imageOptions.quality, in: 0...1).accessibilityLabel("Image quality")
                            .disabled(category != nil && targetID == "jxl" && settings.imageOptions.jpegXLMode == .lossless)
                        Text(settings.imageOptions.quality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit().frame(width: 45)
                    }
                    if targetID == "pdf" {
                        Text("100% requests maximum image quality. PDF images may still use lossy compression.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if category == nil || targetID == "png" {
                    Stepper("PNG compression: \(settings.imageOptions.pngCompressionLevel)", value: $settings.imageOptions.pngCompressionLevel, in: 0...9).accessibilityLabel("PNG compression")
                    Text("0 stores image data without compression. Higher levels can make smaller files and take longer. Pixels stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if (category == nil || targetID == "gif") && sourceCategory != "video" {
                    Stepper("GIF colors: \(settings.imageOptions.gifMaxColors)", value: $settings.imageOptions.gifMaxColors, in: 2...256).accessibilityLabel("GIF colors")
                    Toggle("Ordered GIF dithering", isOn: $settings.imageOptions.gifDither).accessibilityLabel("Ordered GIF dithering")
                    Text("A smaller palette can reduce file size. Dithering adds a fixed pattern to soften color bands. Transparency uses one palette entry.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if (category == nil || targetID == "gif" || targetID == "webp") && sourceCategory != "video" {
                    Picker("Animation frame rate", selection: $settings.imageOptions.animationFrameRate) {
                        Text("Preserve source").tag(Optional<Double>.none)
                        ForEach([10.0, 12.0, 15.0, 20.0, 25.0], id: \.self) {
                            Text("\(Int($0)) fps").tag(Optional($0))
                        }
                    }.accessibilityLabel("Animation frame rate")
                    Picker("Total plays", selection: $settings.imageOptions.animationPlays) {
                        Text("Preserve source").tag(Optional<Int>.none)
                        Text("Forever").tag(Optional(0))
                        ForEach([1, 2, 3, 5, 10], id: \.self) { Text("\($0)").tag(Optional($0)) }
                    }.accessibilityLabel("Total plays")
                    TextField("Animation maximum width (0 = original)", value: $settings.imageOptions.animationMaxWidth, format: .number).accessibilityLabel("Animation maximum width (0 = original)")
                    Text("Preserve source keeps each frame's own delay and the source repeat count. A fixed rate resamples the animation to equal delays, repeating or dropping frames as needed. A maximum width scales frames down without enlarging them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if category == nil || targetID == "tiff" {
                    Picker("TIFF compression", selection: $settings.imageOptions.tiffCompression) {
                        Text("Automatic").tag(TIFFCompression.automatic)
                        Text("None").tag(TIFFCompression.none)
                        Text("LZW").tag(TIFFCompression.lzw)
                        Text("Deflate").tag(TIFFCompression.deflate)
                        Text("JPEG").tag(TIFFCompression.jpeg)
                    }.accessibilityLabel("TIFF compression")
                    if settings.imageOptions.tiffCompression == .jpeg {
                        LabeledContent("TIFF JPEG quality") {
                            Slider(value: $settings.imageOptions.tiffJPEGQuality, in: 0...1).accessibilityLabel("TIFF JPEG quality")
                            Text(settings.imageOptions.tiffJPEGQuality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit().frame(width: 45)
                        }
                        Text("JPEG uses 8-bit samples and lossy compression, including alpha. Use LZW or Deflate to preserve samples exactly.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if sourceCategory != "video" {
                    Toggle("Keep image metadata", isOn: $settings.imageOptions.preserveMetadata).accessibilityLabel("Keep image metadata")
                    Toggle("Convert color to sRGB", isOn: $settings.imageOptions.convertToSRGB).accessibilityLabel("Convert color to sRGB")
                    if category == nil || targetID == "jpeg" {
                        Toggle("Progressive JPEG", isOn: $settings.imageOptions.progressiveJPEG).accessibilityLabel("Progressive JPEG")
                        Picker("Transparency", selection: $settings.imageOptions.alphaHandling) {
                            Text("Automatic").tag(ImageAlphaHandling.preserve)
                            Text("White background").tag(ImageAlphaHandling.white)
                            Text("Black background").tag(ImageAlphaHandling.black)
                            Text("Custom background").tag(ImageAlphaHandling.custom)
                        }.accessibilityLabel("Transparency")
                        if settings.imageOptions.alphaHandling == .custom {
                            TextField("Background color (hex)", text: $settings.imageOptions.alphaCustomColor).accessibilityLabel("Background color (hex)")
                        }
                        Text("JPEG fills transparent areas with this color. Automatic uses white. Other image formats keep supported transparency.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if category == nil || targetID == "webp" {
                    Picker("WebP compression", selection: $settings.imageOptions.webpMode) {
                        ForEach(ImageCompressionMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.accessibilityLabel("WebP compression")
                    Stepper("WebP effort: \(settings.imageOptions.webpEffort)", value: $settings.imageOptions.webpEffort, in: 0...6).accessibilityLabel("WebP effort")
                }
                if category == nil || targetID == "jxl" {
                    Picker("JPEG XL compression", selection: $settings.imageOptions.jpegXLMode) {
                        ForEach(ImageCompressionMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.accessibilityLabel("JPEG XL compression")
                    Stepper("JPEG XL effort: \(settings.imageOptions.jpegXLEffort)",
                            value: $settings.imageOptions.jpegXLEffort, in: 1...10).accessibilityLabel("JPEG XL effort")
                    Text("Lossless keeps the encoded pixels unchanged and ignores quality. Higher effort can make smaller files but takes longer.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder var videoAnimationOptionsSection: some View {
        if category == nil || (category == "image" && sourceCategory == "video") {
            Section("Video to animation") {
                Toggle("Preserve source frame timing", isOn: $settings.imageOptions.videoPreserveFrameRate).accessibilityLabel("Preserve source frame timing")
                if category == nil || !settings.imageOptions.videoPreserveFrameRate {
                    TextField("Frames per second (1–100)", value: $settings.imageOptions.videoFrameRate, format: .number).accessibilityLabel("Frames per second (1–100)")
                }
                TextField("Maximum width (0 = original)", value: $settings.imageOptions.videoMaxWidth, format: .number).accessibilityLabel("Maximum width (0 = original)")
                TextField("Total plays (0 = forever)", value: $settings.imageOptions.videoLoopCount, format: .number).accessibilityLabel("Total plays (0 = forever)")
                if category == nil || targetID == "gif" {
                    Stepper("GIF colors: \(settings.imageOptions.videoGIFColors)", value: $settings.imageOptions.videoGIFColors, in: 2...256).accessibilityLabel("GIF colors")
                    Toggle("Ordered GIF dithering", isOn: $settings.imageOptions.videoGIFDither).accessibilityLabel("Ordered GIF dithering")
                }
                Text("Uses the video track. Audio and subtitles are omitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder var vectorOptionsSections: some View {
        if showsSVGTracing {
            Section("SVG tracing") {
                Toggle("Advanced tracing", isOn: $settings.imageOptions.tracing.advanced).accessibilityLabel("Advanced tracing")
                if !settings.imageOptions.tracing.advanced {
                    Picker("Preset", selection: $settings.imageOptions.tracing.preset) {
                        Text("Photo").tag(SVGTracingOptions.Preset.photo)
                        Text("Poster").tag(SVGTracingOptions.Preset.poster)
                        Text("Line art").tag(SVGTracingOptions.Preset.lineArt)
                    }.accessibilityLabel("Preset")
                } else {
                    Picker("Colors", selection: $settings.imageOptions.tracing.colorMode) {
                        Text("Color").tag(SVGTracingOptions.ColorMode.color)
                        Text("Black and white").tag(SVGTracingOptions.ColorMode.binary)
                    }.accessibilityLabel("Colors")
                    Picker("Layers", selection: $settings.imageOptions.tracing.hierarchy) {
                        ForEach(SVGTracingOptions.Hierarchy.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.accessibilityLabel("Layers").disabled(settings.imageOptions.tracing.colorMode == .binary)
                    Picker("Paths", selection: $settings.imageOptions.tracing.pathMode) {
                        ForEach(SVGTracingOptions.PathMode.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                    }.accessibilityLabel("Paths")
                    Stepper("Speckle filter: \(settings.imageOptions.tracing.filterSpeckle)", value: $settings.imageOptions.tracing.filterSpeckle, in: 0...256).accessibilityLabel("Speckle filter")
                    Text("Remove color regions smaller than \(settings.imageOptions.tracing.filterSpeckle * settings.imageOptions.tracing.filterSpeckle) pixels.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Color precision: \(settings.imageOptions.tracing.colorPrecision)", value: $settings.imageOptions.tracing.colorPrecision, in: 1...12).accessibilityLabel("Color precision")
                        .disabled(settings.imageOptions.tracing.colorMode == .binary)
                    Text("8 gives full color precision. Higher values give the same result.")
                        .font(.caption).foregroundStyle(.secondary)
                    Stepper("Layer difference: \(settings.imageOptions.tracing.layerDifference)", value: $settings.imageOptions.tracing.layerDifference, in: 1...128).accessibilityLabel("Layer difference")
                        .disabled(settings.imageOptions.tracing.colorMode == .binary)
                    Stepper("Corner threshold: \(settings.imageOptions.tracing.cornerThreshold)°", value: $settings.imageOptions.tracing.cornerThreshold, in: 0...180).accessibilityLabel("Corner threshold")
                        .disabled(settings.imageOptions.tracing.pathMode != .spline)
                    Stepper(value: $settings.imageOptions.tracing.lengthThreshold, in: 0...100, step: 0.5) {
                        TextField("Segment length", value: $settings.imageOptions.tracing.lengthThreshold, format: .number)
                            .accessibilityLabel("Segment length")
                    }.accessibilityLabel("Segment length")
                        .disabled(settings.imageOptions.tracing.pathMode != .spline)
                    Stepper("Splice threshold: \(settings.imageOptions.tracing.spliceThreshold)°", value: $settings.imageOptions.tracing.spliceThreshold, in: 0...180).accessibilityLabel("Splice threshold")
                        .disabled(settings.imageOptions.tracing.pathMode != .spline)
                    Stepper("Iterations: \(settings.imageOptions.tracing.maxIterations)", value: $settings.imageOptions.tracing.maxIterations, in: 1...100).accessibilityLabel("Iterations")
                        .disabled(settings.imageOptions.tracing.pathMode != .spline)
                }
                Text("Tracing makes vector paths from one still image. Shapes and colors are approximate. Photos can create large files. Colors use sRGB; image metadata is omitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        if showsSVGSize {
            Section("SVG size") {
                TextField("Width in pixels", value: $settings.imageOptions.svgWidth, format: .number).accessibilityLabel("Width in pixels")
                TextField("Height in pixels", value: $settings.imageOptions.svgHeight, format: .number).accessibilityLabel("Height in pixels")
                TextField("Scale", value: $settings.imageOptions.svgScale, format: .number).accessibilityLabel("Scale")
                    .disabled(settings.imageOptions.svgWidth > 0 || settings.imageOptions.svgHeight > 0)
                Text("Zero uses the original size. Set one dimension to keep the aspect ratio. Explicit dimensions override scale.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
