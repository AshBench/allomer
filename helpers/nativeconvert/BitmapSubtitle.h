#ifndef BITMAP_SUBTITLE_H
#define BITMAP_SUBTITLE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Return zero to continue. The pixels are valid only during the call.
 * Rows are tightly packed RGBA on an opaque light or dark background.
 * Visible pixel brightness selects the background for text recognition.
 * A clear has NULL pixels and zero dimensions. An unknown end is -1.
 * Times are milliseconds from the container start. A later event can cut
 * short an earlier end, including the timeout supplied by DVB subtitles. */
typedef int (*BitmapSubtitleCallback)(void *context, int64_t start_ms, int64_t end_ms,
                                      const uint8_t *rgba, int width, int height);

/* Returns zero on success, or -1 with a bounded error message.
 * Call once in an isolated helper process. This sets FFmpeg's global log
 * callback and allocation limit. Calls and callbacks must not re-enter it.
 * Callers must discard all emitted events if the final result is a failure. */
int decode_bitmap_subtitles(const char *input, int one_based_subtitle_track,
                            BitmapSubtitleCallback callback, void *context,
                            char *error, size_t error_capacity);

#ifdef __cplusplus
}
#endif
#endif
