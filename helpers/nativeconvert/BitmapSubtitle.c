#include "BitmapSubtitle.h"

#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mem.h>
#include <libavutil/time.h>

#define BYTE_LIMIT (64 * 1024 * 1024)
#define PIXEL_LIMIT 32000000
#define STREAM_LIMIT 512
#define RECTANGLE_LIMIT 256
#define EVENT_LIMIT 200000

typedef struct {
    int count, width, height;
    struct { int x, y, width, height; } crop[2];
} PGSPresentation;

static char ffmpeg_error[1024];

static void capture_error(void *unused, int level, const char *format, va_list arguments)
{
    (void)unused;
    if (level <= AV_LOG_ERROR && !ffmpeg_error[0])
        vsnprintf(ffmpeg_error, sizeof(ffmpeg_error), format, arguments);
}

static int failure(char *error, size_t capacity, const char *message, int code)
{
    char detail[AV_ERROR_MAX_STRING_SIZE] = "";
    if (code < 0)
        av_strerror(code, detail, sizeof(detail));
    if (error && capacity)
        snprintf(error, capacity, "%s%s%s%s%s", message, code < 0 ? " " : "", detail,
                 ffmpeg_error[0] ? " " : "", ffmpeg_error);
    return -1;
}

static int interrupted(void *opaque)
{
    return av_gettime_relative() >= *(const int64_t *)opaque;
}

static int bitmap_codec(enum AVCodecID codec)
{
    return codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE || codec == AV_CODEC_ID_DVB_SUBTITLE ||
           codec == AV_CODEC_ID_DVD_SUBTITLE || codec == AV_CODEC_ID_XSUB;
}

/* The subtitle API uses microseconds. XSUB also reads packet PTS in that unit. */
static int packet_time(int64_t *value, AVRational time_base)
{
    if (*value == AV_NOPTS_VALUE)
        return 0;
    *value = av_rescale_q(*value, time_base, AV_TIME_BASE_Q);
    return *value == INT64_MIN || *value == INT64_MAX ? -1 : 0;
}

static int event_time(int64_t pts, int64_t origin, uint32_t offset, int64_t *result)
{
    if (pts == AV_NOPTS_VALUE)
        return -1;
    __int128 value = (__int128)pts - origin + (__int128)offset * 1000;
    if (value < 0 || (value + 500) / 1000 > INT64_MAX)
        return -1;
    *result = (int64_t)((value + 500) / 1000);
    return 0;
}

/* Some decoder paths accept a short final segment without reporting an error. */
static int check_segments(const AVPacket *packet, enum AVCodecID codec, int *pending,
                          PGSPresentation *presentation, PGSPresentation *display)
{
    if (codec != AV_CODEC_ID_HDMV_PGS_SUBTITLE && codec != AV_CODEC_ID_DVB_SUBTITLE)
        return 0;
    size_t position = 0, size = (size_t)packet->size;
    while (position < size) {
        const uint8_t *data = packet->data + position;
        if (codec == AV_CODEC_ID_DVB_SUBTITLE) {
            if (size - position == 1 && data[0] == 0xff)
                return 0;
            if (size - position < 6 || data[0] != 0x0f)
                return -1;
            size_t length = AV_RB16(data + 4);
            if (length > size - position - 6)
                return -1;
            *pending = data[1] != 0x80;
            position += 6 + length;
        } else {
            if (size - position < 3)
                return -1;
            unsigned type = data[0];
            size_t length = AV_RB16(data + 1);
            if (length > size - position - 3)
                return -1;
            const uint8_t *body = data + 3;
            if ((type == 0x14 && (length < 2 || (length - 2) % 5)) ||
                (type == 0x15 && (length < 4 || ((body[3] & 0x80) && length < 11))) ||
                (type == 0x17 && (length < 1 || length != 1 + (size_t)body[0] * 9)) ||
                (type == 0x80 && length != 0))
                return -1;
            if (type == 0x16) {
                if (length < 11 || body[10] > 2)
                    return -1;
                PGSPresentation next = {.count = body[10], .width = AV_RB16(body),
                                        .height = AV_RB16(body + 2)};
                if (!next.width || !next.height || (int64_t)next.width * next.height > PIXEL_LIMIT)
                    return -1;
                size_t entry = 11;
                for (int i = 0; i < next.count; i++) {
                    if (length - entry < 8)
                        return -1;
                    int cropped = body[entry + 3] & 0x80;
                    entry += 8;
                    if (cropped) {
                        if (length - entry < 8)
                            return -1;
                        next.crop[i].x = AV_RB16(body + entry);
                        next.crop[i].y = AV_RB16(body + entry + 2);
                        next.crop[i].width = AV_RB16(body + entry + 4);
                        next.crop[i].height = AV_RB16(body + entry + 6);
                        if (!next.crop[i].width || !next.crop[i].height)
                            return -1;
                        entry += 8;
                    }
                }
                if (entry != length)
                    return -1;
                *presentation = next;
            }
            if (type == 0x80) {
                if (presentation->count < 0 || display->count >= 0)
                    return -1;
                /* A later PCS in this packet belongs to the next display. */
                *display = *presentation;
            }
            *pending = type != 0x80;
            position += 3 + length;
        }
    }
    return 0;
}

static int composite(const AVSubtitle *subtitle, uint8_t **pixels, int *width, int *height)
{
    *pixels = NULL;
    *width = *height = 0;
    if (subtitle->num_rects == 0)
        return 0;
    if (subtitle->num_rects > RECTANGLE_LIMIT || !subtitle->rects || subtitle->format != 0)
        return -1;
    int left = INT_MAX, top = INT_MAX, right = 0, bottom = 0;
    int64_t total = 0;
    for (unsigned i = 0; i < subtitle->num_rects; i++) {
        const AVSubtitleRect *rect = subtitle->rects[i];
        if (!rect || rect->type != SUBTITLE_BITMAP || rect->x < 0 || rect->y < 0 ||
            rect->w <= 0 || rect->h <= 0 || rect->w > 100000 || rect->h > 100000 ||
            rect->x > 100000 - rect->w || rect->y > 100000 - rect->h ||
            !rect->data[0] || !rect->data[1] || rect->nb_colors < 1 || rect->nb_colors > 256 ||
            rect->linesize[0] < rect->w || (int64_t)rect->linesize[0] * rect->h > BYTE_LIMIT)
            return -1;
        total += (int64_t)rect->w * rect->h;
        if (total > PIXEL_LIMIT)
            return -1;
        if (rect->x < left) left = rect->x;
        if (rect->y < top) top = rect->y;
        if (rect->x + rect->w > right) right = rect->x + rect->w;
        if (rect->y + rect->h > bottom) bottom = rect->y + rect->h;
    }
    *width = right - left;
    *height = bottom - top;
    int64_t count = (int64_t)*width * *height;
    if (count > PIXEL_LIMIT || count > BYTE_LIMIT / 4)
        return -1;
    uint8_t *rgba = av_mallocz((size_t)count * 4);
    if (!rgba)
        return -1;
    int visible = 0;
    for (unsigned i = 0; i < subtitle->num_rects; i++) {
        const AVSubtitleRect *rect = subtitle->rects[i];
        for (int y = 0; y < rect->h; y++) {
            const uint8_t *row = rect->data[0] + (size_t)y * rect->linesize[0];
            uint8_t *out = rgba + ((size_t)(rect->y - top + y) * *width + rect->x - left) * 4;
            for (int x = 0; x < rect->w; x++, out += 4) {
                if (row[x] >= rect->nb_colors) {
                    av_free(rgba);
                    return -1;
                }
                uint32_t color;
                memcpy(&color, rect->data[1] + (size_t)row[x] * 4, sizeof(color));
                unsigned alpha = color >> 24;
                visible |= alpha != 0;
                for (int channel = 0; channel < 3; channel++) {
                    unsigned value = (color >> (16 - 8 * channel)) & 255;
                    out[channel] = (value * alpha + out[channel] * (255 - alpha) + 127) / 255;
                }
                out[3] = alpha + (out[3] * (255 - alpha) + 127) / 255;
            }
        }
    }
    if (!visible) {
        av_free(rgba);
        *width = *height = 0;
    } else {
        uint64_t light = 0, opacity = 0;
        for (int64_t i = 0; i < count; i++) {
            const uint8_t *pixel = rgba + i * 4;
            light += 299 * pixel[0] + 587 * pixel[1] + 114 * pixel[2];
            opacity += pixel[3];
        }
        /* Dark letters need a light backdrop. Only visible pixels select it. */
        int white = light * 255 < opacity * 128000;
        for (int64_t i = 0; i < count; i++) {
            uint8_t *pixel = rgba + i * 4;
            if (white)
                for (int channel = 0; channel < 3; channel++) pixel[channel] += 255 - pixel[3];
            pixel[3] = 255;
        }
        *pixels = rgba;
    }
    return 0;
}

/* The decoder returns full objects in PCS order. Crop source pixels, not placement. */
static int composite_pgs(const AVSubtitle *subtitle, const PGSPresentation *display,
                         uint8_t **pixels, int *width, int *height)
{
    if (display->count < 0 || display->count > 2 || subtitle->num_rects != (unsigned)display->count ||
        (subtitle->num_rects && !subtitle->rects))
        return -1;
    AVSubtitleRect copies[2], *rectangles[2];
    AVSubtitle view = *subtitle;
    view.rects = rectangles;
    int64_t total = 0;
    for (int i = 0; i < display->count; i++) {
        const AVSubtitleRect *original = subtitle->rects[i];
        if (!original || !original->data[0] || original->w <= 0 || original->h <= 0 ||
            original->linesize[0] < original->w ||
            (int64_t)original->linesize[0] * original->h > BYTE_LIMIT)
            return -1;
        total += (int64_t)original->w * original->h;
        if (total > PIXEL_LIMIT)
            return -1;
        AVSubtitleRect *rect = rectangles[i] = &copies[i];
        *rect = *original;
        if (display->crop[i].width) {
            int x = display->crop[i].x, y = display->crop[i].y;
            int w = display->crop[i].width, h = display->crop[i].height;
            if (x < 0 || y < 0 || w <= 0 || h <= 0 || x > original->w - w || y > original->h - h)
                return -1;
            rect->data[0] += (size_t)y * rect->linesize[0] + x;
            rect->w = w;
            rect->h = h;
        }
        if (rect->x < 0 || rect->y < 0 || rect->x > display->width - rect->w ||
            rect->y > display->height - rect->h)
            return -1;
    }
    /* Only these stack views borrow shifted pointers. Free the original subtitle. */
    return composite(&view, pixels, width, height);
}

int decode_bitmap_subtitles(const char *input, int one_based_subtitle_track,
                            BitmapSubtitleCallback callback, void *context,
                            char *error, size_t error_capacity)
{
    AVFormatContext *format = NULL;
    AVCodecContext *decoder = NULL;
    AVPacket *packet = NULL;
    AVDictionary *options = NULL;
    AVDictionary *probe_options[STREAM_LIMIT] = {0};
    int result = -1, code = 0, stream_index = -1, track_count = 0;
    int pending = 0, dvd_pending = 0, events = 0, pictures = 0, flushing = 0;
    int64_t deadline = av_gettime_relative() + 120 * AV_TIME_BASE;
    int64_t last_start = -1, dvd_pts = AV_NOPTS_VALUE, last_sup_end = -1;
    PGSPresentation pgs_presentation = {.count = -1}, pgs_display = {.count = -1};
    const char *message = "The bitmap subtitles could not be decoded.";
    ffmpeg_error[0] = 0;
    if (error && error_capacity) error[0] = 0;
    if (!input || !*input || !callback || one_based_subtitle_track < 1 || one_based_subtitle_track > 256)
        return failure(error, error_capacity, "The bitmap subtitle arguments are invalid.", 0);
    av_max_alloc(BYTE_LIMIT);
    av_log_set_callback(capture_error);
    format = avformat_alloc_context();
    if (!format) goto done;
    format->interrupt_callback = (AVIOInterruptCB){interrupted, &deadline};
    format->max_streams = STREAM_LIMIT;
    format->probesize = 5 * 1024 * 1024;
    format->max_analyze_duration = 7 * AV_TIME_BASE;
    format->error_recognition = AV_EF_CRCCHECK | AV_EF_BITSTREAM | AV_EF_BUFFER | AV_EF_EXPLODE;
    if ((code = av_dict_set(&options, "protocol_whitelist", "file,pipe", 0)) < 0) goto done;
    if ((code = avformat_open_input(&format, input, NULL, &options)) < 0 || ffmpeg_error[0]) goto done;
    if (format->nb_streams > STREAM_LIMIT) goto done;
    for (unsigned i = 0; i < format->nb_streams; i++) {
        if ((code = av_dict_set(&probe_options[i], "threads", "1", 0)) < 0 ||
            (code = av_dict_set(&probe_options[i], "max_pixels", "32000000", 0)) < 0 ||
            (code = av_dict_set(&probe_options[i], "err_detect", "explode", 0)) < 0) goto done;
    }
    /* Only probing may inspect initial audio/video frames. The loop below decodes one subtitle track. */
    if ((code = avformat_find_stream_info(format, probe_options)) < 0 || ffmpeg_error[0]) goto done;
    for (unsigned i = 0; i < format->nb_streams; i++) {
        AVStream *stream = format->streams[i];
        if (stream->codecpar->codec_type == AVMEDIA_TYPE_SUBTITLE && ++track_count == one_based_subtitle_track)
            stream_index = (int)i;
    }
    if (track_count > 256 || stream_index < 0) {
        message = "The selected bitmap subtitle track is unavailable, or there are more than 256 tracks.";
        goto done;
    }
    AVStream *stream = format->streams[stream_index];
    enum AVCodecID codec = stream->codecpar->codec_id;
    if (!bitmap_codec(codec)) {
        message = "The selected track is not a supported picture subtitle codec.";
        goto done;
    }
    if (stream->time_base.num <= 0 || stream->time_base.den <= 0) goto done;
    const AVCodec *implementation = avcodec_find_decoder(codec);
    if (!implementation || !(decoder = avcodec_alloc_context3(implementation))) goto done;
    if ((code = avcodec_parameters_to_context(decoder, stream->codecpar)) < 0) goto done;
    decoder->pkt_timebase = AV_TIME_BASE_Q;
    decoder->thread_count = 1;
    decoder->max_pixels = PIXEL_LIMIT;
    decoder->err_recognition = format->error_recognition;
    if ((code = avcodec_open2(decoder, implementation, NULL)) < 0 || ffmpeg_error[0]) goto done;
    if (!(packet = av_packet_alloc())) goto done;
    int64_t origin = format->start_time == AV_NOPTS_VALUE ? 0 : format->start_time;
    for (;;) {
        pgs_display.count = -1;
        if (interrupted(&deadline)) {
            message = "Bitmap subtitle decoding exceeded its time limit.";
            goto done;
        }
        if (!flushing) {
            code = av_read_frame(format, packet);
            if (ffmpeg_error[0]) goto done;
            if (code == AVERROR_EOF) {
                if ((format->pb && format->pb->error) || pending || dvd_pending) {
                    message = "The bitmap subtitle stream ended with an incomplete display.";
                    goto done;
                }
                if (!strcmp(format->iformat->name, "sup") && format->pb &&
                    last_sup_end >= 0 && avio_size(format->pb) != last_sup_end) {
                    message = "The PGS file has an incomplete final packet.";
                    goto done;
                }
                av_packet_unref(packet);
                flushing = 1;
                code = 0;
            } else if (code < 0) {
                goto done;
            } else if (packet->stream_index != stream_index) {
                av_packet_unref(packet);
                continue;
            } else {
                if (packet->flags & AV_PKT_FLAG_CORRUPT || packet->size <= 0 || packet->size > BYTE_LIMIT ||
                    !packet->data || packet->duration < 0) goto done;
                int checked = check_segments(packet, codec, &pending, &pgs_presentation, &pgs_display);
                if (checked < 0) {
                    message = "The bitmap subtitle packet has an incomplete or invalid segment.";
                    goto done;
                }
                if (!strcmp(format->iformat->name, "sup")) {
                    if (packet->pos < 0 || packet->pos > INT64_MAX - packet->size - 10) goto done;
                    last_sup_end = packet->pos + packet->size + 10;
                }
                if (packet_time(&packet->pts, stream->time_base) || packet_time(&packet->dts, stream->time_base) ||
                    packet_time(&packet->duration, stream->time_base) ||
                    packet->duration > (int64_t)(UINT32_MAX - 1) * 1000) {
                    message = "A bitmap subtitle packet has an invalid timestamp.";
                    goto done;
                }
                if (codec == AV_CODEC_ID_XSUB && packet->pts == AV_NOPTS_VALUE)
                    packet->pts = 0; /* XSUB supplies absolute times in the payload. */
                if (codec == AV_CODEC_ID_DVD_SUBTITLE && dvd_pts != AV_NOPTS_VALUE)
                    packet->pts = dvd_pts;
            }
        }
        AVSubtitle subtitle = {0};
        int got = 0;
        code = avcodec_decode_subtitle2(decoder, &subtitle, &got, packet);
        if (code < 0 || ffmpeg_error[0] ||
            (codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE && !!got != (pgs_display.count >= 0))) {
            avsubtitle_free(&subtitle);
            goto done;
        }
        if (codec == AV_CODEC_ID_DVD_SUBTITLE && !flushing) {
            dvd_pending = !got && code == 0;
            dvd_pts = dvd_pending ? packet->pts : AV_NOPTS_VALUE;
            if ((!got && !dvd_pending) || (dvd_pending && dvd_pts == AV_NOPTS_VALUE)) {
                avsubtitle_free(&subtitle);
                message = "A DVD subtitle display is incomplete, invisible, or has no usable timestamp.";
                goto done;
            }
        }
        if (codec == AV_CODEC_ID_DVB_SUBTITLE && got) pending = 0;
        av_packet_unref(packet);
        if (!got) {
            avsubtitle_free(&subtitle);
            if (flushing) break;
            continue;
        }
        uint8_t *rgba = NULL;
        int width = 0, height = 0;
        int64_t start = -1, end = -1;
        int invalid_time = event_time(subtitle.pts, origin, subtitle.start_display_time, &start);
        if (subtitle.end_display_time != 0 && subtitle.end_display_time != UINT32_MAX)
            invalid_time |= event_time(subtitle.pts, origin, subtitle.end_display_time, &end);
        if (++events > EVENT_LIMIT || invalid_time || start < last_start ||
            (end != -1 && (end < start || (subtitle.num_rects && end == start))) ||
            decoder->width < 0 || decoder->height < 0 ||
            (int64_t)decoder->width * decoder->height > PIXEL_LIMIT ||
            (codec == AV_CODEC_ID_HDMV_PGS_SUBTITLE
                ? composite_pgs(&subtitle, &pgs_display, &rgba, &width, &height)
                : composite(&subtitle, &rgba, &width, &height)) < 0) {
            avsubtitle_free(&subtitle);
            message = "A bitmap subtitle display has invalid timing, pixels, or size.";
            goto done;
        }
        avsubtitle_free(&subtitle);
        last_start = start;
        pictures += rgba != NULL;
        if (pictures > 100000) {
            av_free(rgba);
            message = "The track exceeds 100,000 bitmap subtitle pictures.";
            goto done;
        }
        int stopped = callback(context, start, end, rgba, width, height);
        av_free(rgba);
        if (stopped) {
            message = "Bitmap subtitle processing stopped in the callback.";
            goto done;
        }
    }
    if (!pictures) {
        message = "The selected track contains no visible bitmap subtitles.";
        goto done;
    }
    result = 0;
done:
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    av_dict_free(&options);
    for (unsigned i = 0; i < STREAM_LIMIT; i++) av_dict_free(&probe_options[i]);
    av_log_set_callback(av_log_default_callback);
    if (ffmpeg_error[0]) result = -1;
    return result == 0 ? 0 : failure(error, error_capacity, message, code < 0 ? code : 0);
}

#ifdef BITMAP_SUBTITLE_SELFTEST
#include <assert.h>
#include <stdlib.h>

static void check_pgs_crop(void)
{
    uint8_t cropped_pcs[] = {0x16, 0, 27, 0, 16, 0, 16, 0x10, 0, 1, 0x80, 0, 0, 1,
                            0, 37, 0, 0x80, 0, 3, 0, 4, 0, 1, 0, 1, 0, 2, 0, 1};
    uint8_t next[] = {0x80, 0, 0, 0x16, 0, 19, 0, 16, 0, 16, 0x10, 0, 2, 0, 0x80, 0, 1,
                      0, 37, 0, 0, 0, 3, 0, 4};
    PGSPresentation active = {.count = -1}, shown = {.count = -1};
    int pending = 0;
    AVPacket packet = {.data = cropped_pcs, .size = sizeof(cropped_pcs)};
    assert(check_segments(&packet, AV_CODEC_ID_HDMV_PGS_SUBTITLE, &pending, &active, &shown) == 0);
    assert(pending && shown.count == -1 && active.crop[0].x == 1 && active.crop[0].height == 1);
    packet = (AVPacket){.data = next, .size = sizeof(next)};
    assert(check_segments(&packet, AV_CODEC_ID_HDMV_PGS_SUBTITLE, &pending, &active, &shown) == 0);
    assert(pending && shown.crop[0].width == 2 && active.crop[0].width == 0);
    uint8_t palette_end[] = {0x14, 0, 2, 0, 0, 0x80, 0, 0};
    packet = (AVPacket){.data = palette_end, .size = sizeof(palette_end)};
    active = shown;
    shown.count = -1;
    assert(check_segments(&packet, AV_CODEC_ID_HDMV_PGS_SUBTITLE, &pending, &active, &shown) == 0);
    assert(!pending && shown.crop[0].width == 2);
    uint8_t duplicate_end[] = {0x80, 0, 0, 0x80, 0, 0};
    packet = (AVPacket){.data = duplicate_end, .size = sizeof(duplicate_end)};
    shown.count = -1;
    assert(check_segments(&packet, AV_CODEC_ID_HDMV_PGS_SUBTITLE, &pending, &active, &shown) == -1);
    packet = (AVPacket){.data = cropped_pcs, .size = sizeof(cropped_pcs) - 1};
    cropped_pcs[2]--;
    assert(check_segments(&packet, AV_CODEC_ID_HDMV_PGS_SUBTITLE, &pending, &active, &shown) == -1);
    cropped_pcs[2]++;
    packet.size++;
    cropped_pcs[27] = 0;
    assert(check_segments(&packet, AV_CODEC_ID_HDMV_PGS_SUBTITLE, &pending, &active, &shown) == -1);
    uint8_t clear[] = {0x16, 0, 11, 0, 16, 0, 16, 0x10, 0, 3, 0, 0, 0, 0, 0x80, 0, 0};
    packet = (AVPacket){.data = clear, .size = sizeof(clear)};
    shown.count = -1;
    assert(check_segments(&packet, AV_CODEC_ID_HDMV_PGS_SUBTITLE, &pending, &active, &shown) == 0);
    assert(!pending && shown.count == 0);

    uint8_t indices[] = {3, 3, 3, 3, 3, 1, 2, 3, 3, 3, 3, 3};
    uint32_t palette[] = {0, 0xffffffff, 0xff00ff00, 0xffff0000};
    AVSubtitleRect first = {.x = 3, .y = 4, .w = 4, .h = 3, .nb_colors = 4,
        .type = SUBTITLE_BITMAP, .data = {indices, (uint8_t *)palette}, .linesize = {4}};
    AVSubtitleRect anchor = {.x = 1, .y = 4, .w = 1, .h = 1, .nb_colors = 4,
        .type = SUBTITLE_BITMAP, .data = {indices + 5, (uint8_t *)palette}, .linesize = {1}};
    AVSubtitleRect *rectangles[] = {&first, &anchor};
    AVSubtitle subtitle = {.num_rects = 2, .rects = rectangles};
    PGSPresentation crop = {.count = 2, .width = 16, .height = 16, .crop = {{1, 1, 2, 1}, {0}}};
    uint8_t *rgba = NULL;
    int width, height;
    assert(composite_pgs(&subtitle, &crop, &rgba, &width, &height) == 0 && width == 4 && height == 1);
    assert(memcmp(rgba, (uint8_t[]){255, 255, 255, 255, 0, 0, 0, 255,
                                   255, 255, 255, 255, 0, 255, 0, 255}, 16) == 0);
    assert(first.data[0] == indices && first.w == 4 && first.h == 3);
    av_free(rgba);
    crop.crop[0].width = 4;
    assert(composite_pgs(&subtitle, &crop, &rgba, &width, &height) == -1);
    crop.crop[0].width = 2;
    crop.crop[0].y = 3;
    assert(composite_pgs(&subtitle, &crop, &rgba, &width, &height) == -1);
    crop.crop[0].y = 1;
    crop.width = 4;
    assert(composite_pgs(&subtitle, &crop, &rgba, &width, &height) == -1);
    crop.count = 1;
    assert(composite_pgs(&subtitle, &crop, &rgba, &width, &height) == -1);
}

static int check_event(void *opaque, int64_t start, int64_t end,
                       const uint8_t *rgba, int width, int height)
{
    int64_t *state = opaque;
    const int64_t authored[] = {1000, 2000, 3250, 5500};
    assert(state[0] < 4 && start == authored[state[0]] + state[1] && end == -1);
    assert((state[0] % 2 == 0) == (rgba != NULL));
    assert(rgba ? width > 0 && height > 0 : width == 0 && height == 0);
    if (rgba) {
        int visible = 0;
        for (int i = 0; i < width * height; i++) {
            assert(rgba[i * 4 + 3] == 255);
            visible |= rgba[i * 4] || rgba[i * 4 + 1] || rgba[i * 4 + 2];
        }
        assert(visible);
    }
    state[0]++;
    return 0;
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    check_pgs_crop();
    uint8_t indices[] = {1, 2}, overlay[] = {1};
    uint32_t palette[] = {0, 0xffff0000, 0x8000ff00}, blue[] = {0, 0x800000ff};
    AVSubtitleRect first = {.x = 1, .y = 2, .w = 2, .h = 1, .nb_colors = 3,
        .type = SUBTITLE_BITMAP, .data = {indices, (uint8_t *)palette}, .linesize = {2}};
    AVSubtitleRect second = {.x = 2, .y = 2, .w = 1, .h = 1, .nb_colors = 2,
        .type = SUBTITLE_BITMAP, .data = {overlay, (uint8_t *)blue}, .linesize = {1}};
    AVSubtitleRect *rectangles[] = {&first, &second};
    AVSubtitle subtitle = {.num_rects = 2, .rects = rectangles};
    uint8_t *rgba = NULL;
    int width, height;
    assert(composite(&subtitle, &rgba, &width, &height) == 0 && width == 2 && height == 1);
    assert(memcmp(rgba, (uint8_t[]){255, 0, 0, 255, 63, 127, 191, 255}, 8) == 0);
    av_free(rgba);
    indices[1] = 0;
    palette[1] = 0xff000000;
    palette[2] = 0xffffffff; /* An unused bright palette entry must not hide black letters. */
    blue[1] = 0;
    assert(composite(&subtitle, &rgba, &width, &height) == 0 && width == 2 && height == 1);
    assert(memcmp(rgba, (uint8_t[]){0, 0, 0, 255, 255, 255, 255, 255}, 8) == 0);
    av_free(rgba);
    palette[1] = palette[2] = blue[1] = 0;
    assert(composite(&subtitle, &rgba, &width, &height) == 0 && !rgba && !width && !height);
    indices[0] = 255;
    assert(composite(&subtitle, &rgba, &width, &height) == -1);
    int64_t time;
    assert(event_time(5000000, 5000000, 125, &time) == 0 && time == 125);
    assert(event_time(1000, 2000, 0, &time) == -1);
    assert(event_time(AV_NOPTS_VALUE, 0, 0, &time) == -1);
    int64_t state[] = {0, strtoll(argv[2], NULL, 10)};
    char error[2048];
    int result = decode_bitmap_subtitles(argv[1], 1, check_event, state, error, sizeof(error));
    if (result) fprintf(stderr, "%s\n", error);
    assert(result == 0 && state[0] == 4);
    puts("Bitmap subtitle decoder checks passed.");
    return 0;
}
#endif
