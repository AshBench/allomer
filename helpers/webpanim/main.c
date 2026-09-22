#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "webp/encode.h"
#include "imageio/pngdec.h"
#include "imageio/metadata.h"

#define FILE_LIMIT (512ULL * 1024 * 1024)
#define METADATA_LIMIT (16ULL * 1024 * 1024)
static const char *created_output;

static void fail(const char *message) {
    fprintf(stderr, "%s\n", message);
    if (created_output) unlink(created_output);
    exit(1);
}

static FILE *open_regular(const char *path, off_t limit) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > limit)
        fail("An animation input is not a regular file within its size limit.");
    FILE *file = fdopen(fd, "rb");
    if (!file) fail("An animation input could not be opened.");
    return file;
}

static double number(FILE *file, double maximum, int integer) {
    char line[64], *end;
    if (!fgets(line, sizeof(line), file) || !strchr(line, '\n')) fail("The animation manifest is incomplete.");
    errno = 0;
    double value = strtod(line, &end);
    if (end == line || *end != '\n' || end[1] || errno || !isfinite(value)
        || value < 0 || value > maximum || (integer && value != floor(value)))
        fail("An animation manifest value is invalid.");
    return value;
}

static void little(uint8_t *bytes, uint32_t value, unsigned count) {
    for (unsigned i = 0; i < count; i++) bytes[i] = (uint8_t)(value >> (i * 8));
}

static uint32_t read_little(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

static uint32_t read_big(const uint8_t *bytes) {
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | bytes[3];
}

static void write_bytes(FILE *file, const void *bytes, size_t count) {
    off_t position = ftello(file);
    if (position < 0 || (uint64_t)position > FILE_LIMIT || count > FILE_LIMIT - (uint64_t)position)
        fail("The animation exceeds the output size limit.");
    if (count && fwrite(bytes, 1, count, file) != count) fail("The animation output could not be written.");
}

static void chunk(FILE *file, const char name[4], const uint8_t *bytes, size_t count) {
    if (count > FILE_LIMIT) fail("An animation chunk exceeds its size limit.");
    uint8_t header[8];
    memcpy(header, name, 4);
    little(header + 4, (uint32_t)count, 4);
    write_bytes(file, header, sizeof(header));
    write_bytes(file, bytes, count);
    if (count & 1) write_bytes(file, "", 1);
}

static void read_frame(unsigned index, unsigned width, unsigned height, WebPPicture *picture, Metadata *metadata) {
    char name[32];
    snprintf(name, sizeof(name), "frame-%06u.png", index + 1);
    FILE *file = open_regular(name, FILE_LIMIT);
    struct stat info;
    if (fstat(fileno(file), &info)) fail("A frame size could not be checked.");
    size_t size = (size_t)info.st_size;
    const uint8_t *bytes = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fileno(file), 0);
    if (bytes == MAP_FAILED) fail("A frame could not be mapped.");
    if (size < 33 || memcmp(bytes, "\x89PNG\r\n\x1a\n\0\0\0\rIHDR", 16)
        || read_big(bytes + 16) != width || read_big(bytes + 20) != height)
        fail("A PNG frame has unexpected dimensions.");
    if (!ReadPNG(bytes, size, picture, 1, metadata) || picture->width != (int)width || picture->height != (int)height)
        fail("A PNG frame could not be decoded.");
    munmap((void *)bytes, size);
    fclose(file);
}

// Copy only the codec chunks from a frame encoded by libwebp.
static void write_frame(FILE *output, const WebPMemoryWriter *encoded, unsigned width, unsigned height, unsigned duration) {
    if (encoded->size < 12 || encoded->size > FILE_LIMIT || memcmp(encoded->mem, "RIFF", 4)
        || memcmp(encoded->mem + 8, "WEBP", 4) || (uint64_t)read_little(encoded->mem + 4) + 8 != encoded->size)
        fail("The encoded frame has an invalid WebP header.");
    uint32_t data_size = 0;
    unsigned images = 0, alphas = 0;
    int lossless = 0;
    for (size_t cursor = 12; cursor < encoded->size;) {
        if (encoded->size - cursor < 8) fail("The encoded frame has an incomplete chunk.");
        const uint8_t *part = encoded->mem + cursor;
        uint64_t size = (uint64_t)read_little(part + 4) + 8;
        size += size & 1;
        if (size > encoded->size - cursor) fail("The encoded frame has an invalid chunk size.");
        if (!memcmp(part, "VP8 ", 4) || !memcmp(part, "VP8L", 4)) {
            images++;
            lossless = !memcmp(part, "VP8L", 4);
            data_size += (uint32_t)size;
        } else if (!memcmp(part, "ALPH", 4)) {
            if (images) fail("The encoded alpha chunk is out of order.");
            alphas++;
            data_size += (uint32_t)size;
        } else if (memcmp(part, "VP8X", 4)) {
            fail("The encoder returned an unexpected frame chunk.");
        }
        cursor += (size_t)size;
    }
    if (images != 1 || alphas > 1 || (lossless && alphas)) fail("The encoded frame has invalid image chunks.");
    uint8_t header[24] = {0};
    memcpy(header, "ANMF", 4);
    little(header + 4, data_size + 16, 4);
    little(header + 14, width - 1, 3);
    little(header + 17, height - 1, 3);
    little(header + 20, duration, 3);
    header[23] = 2; // Replace the full canvas without blending with the previous frame.
    write_bytes(output, header, sizeof(header));
    for (size_t cursor = 12; cursor < encoded->size;) {
        const uint8_t *part = encoded->mem + cursor;
        size_t size = (size_t)read_little(part + 4) + 8;
        size += size & 1;
        if (memcmp(part, "VP8X", 4)) write_bytes(output, part, size);
        cursor += size;
    }
}

int main(int argc, char **argv) {
    if (argc != 3) fail("Expected an animation manifest and output filename.");
    FILE *manifest = open_regular(argv[1], 128 * 1024);
    if (number(manifest, 1, 1) != 1) fail("The animation manifest version is unsupported.");
    unsigned width = (unsigned)number(manifest, 16383, 1), height = (unsigned)number(manifest, 16383, 1);
    unsigned count = (unsigned)number(manifest, 10000, 1), loops = (unsigned)number(manifest, 65535, 1);
    WebPConfig config;
    if (!WebPConfigInit(&config)) fail("The WebP encoder version is incompatible.");
    config.lossless = (int)number(manifest, 1, 1);
    config.quality = (float)number(manifest, 100, 0);
    config.method = (int)number(manifest, 6, 1);
    int preserve = (int)number(manifest, 1, 1);
    config.low_memory = 1;
    config.exact = 1;
    config.thread_level = 0;
    uint64_t pixels = (uint64_t)width * height;
    if (!pixels || !count || pixels > 32000000 || pixels * count > 256000000 || !WebPValidateConfig(&config))
        fail("The animation dimensions or encoder settings exceed their limits.");
    int fd = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) fail("The animation output already exists or could not be opened.");
    created_output = argv[2];
    FILE *output = fdopen(fd, "wb");
    if (!output) fail("The animation output could not be opened.");
    write_bytes(output, "RIFF\0\0\0\0WEBP", 12);
    uint8_t extended[10] = {2}, animation[6] = {0};
    little(extended + 4, width - 1, 3);
    little(extended + 7, height - 1, 3);
    little(animation + 4, loops, 2);
    Metadata metadata;
    MetadataInit(&metadata);
    for (unsigned index = 0; index < count; index++) {
        unsigned duration = (unsigned)number(manifest, 0xffffff, 1);
        WebPPicture picture;
        if (!WebPPictureInit(&picture)) fail("The WebP picture version is incompatible.");
        picture.use_argb = 1;
        read_frame(index, width, height, &picture, index == 0 ? &metadata : NULL);
        if (index == 0) {
            if (metadata.iccp.size > METADATA_LIMIT || metadata.exif.size > METADATA_LIMIT || metadata.xmp.size > METADATA_LIMIT)
                fail("The animation metadata exceeds its size limit.");
            if (metadata.iccp.size) extended[0] |= 0x20;
            if (preserve && metadata.exif.size) extended[0] |= 0x08;
            if (preserve && metadata.xmp.size) extended[0] |= 0x04;
            chunk(output, "VP8X", extended, sizeof(extended));
            if (metadata.iccp.size) chunk(output, "ICCP", metadata.iccp.bytes, metadata.iccp.size);
            chunk(output, "ANIM", animation, sizeof(animation));
        }
        if (WebPPictureHasTransparency(&picture)) extended[0] |= 0x10;
        WebPMemoryWriter encoded;
        WebPMemoryWriterInit(&encoded);
        picture.writer = WebPMemoryWrite;
        picture.custom_ptr = &encoded;
        if (!WebPEncode(&config, &picture)) fail("A WebP animation frame could not be encoded.");
        write_frame(output, &encoded, width, height, duration);
        WebPMemoryWriterClear(&encoded);
        WebPPictureFree(&picture);
    }
    if (fgetc(manifest) != EOF || ferror(manifest)) fail("The animation manifest has extra or unreadable data.");
    fclose(manifest);
    if (preserve && metadata.exif.size) chunk(output, "EXIF", metadata.exif.bytes, metadata.exif.size);
    if (preserve && metadata.xmp.size) chunk(output, "XMP ", metadata.xmp.bytes, metadata.xmp.size);
    MetadataFree(&metadata);
    off_t length = ftello(output);
    if (length < 0 || fseeko(output, 4, SEEK_SET)) fail("The animation size could not be stored.");
    uint8_t size[4];
    little(size, (uint32_t)(length - 8), 4);
    write_bytes(output, size, sizeof(size));
    if (fseeko(output, 20, SEEK_SET)) fail("The animation features could not be stored.");
    write_bytes(output, extended, 1);
    if (fclose(output)) fail("The animation output could not be finished.");
    created_output = NULL;
    return 0;
}
