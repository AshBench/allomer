#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include "jpeglib.h"
#include "jerror.h"
#include "jmemsys.h"
#include "../fitz/jmemcust.h"

static const size_t memory_limit = 256 * 1024 * 1024;

static void *allocate(j_common_ptr decoder, size_t size)
{
    size_t *used = GET_CUST_MEM_DATA(decoder)->priv;
    if (size > memory_limit - *used) return NULL;
    void *memory = calloc(1, size);
    if (memory) *used += size;
    return memory;
}

static void release(j_common_ptr decoder, void *memory, size_t size)
{
    size_t *used = GET_CUST_MEM_DATA(decoder)->priv;
    if (memory) { *used -= size; free(memory); }
}

static void failed(j_common_ptr decoder)
{
    // These processes need the other bundled decoder. They are not validation successes.
    if (decoder->err->msg_code == JERR_SOF_UNSUPPORTED || decoder->err->msg_code == JERR_BAD_PRECISION) {
        puts("unsupported");
        exit(0);
    }
    decoder->err->output_message(decoder);
    exit(1);
}

static void message(j_common_ptr decoder, int level)
{
    if (level < 0) failed(decoder);
}

int pdfjpegcheck_main(int argc, char **argv)
{
    if (argc != 2) { fputs("Expected: jpegcheck INPUT.jpg\n", stderr); return 1; }
    int descriptor = open(argv[1], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat before, after;
    if (descriptor < 0 || fstat(descriptor, &before) || !S_ISREG(before.st_mode)
        || before.st_size <= 0 || before.st_size > 512LL * 1024 * 1024) {
        if (descriptor >= 0) close(descriptor);
        fputs("JPEG input must be a regular file up to 512 MiB.\n", stderr);
        return 1;
    }
    FILE *input = fdopen(descriptor, "rb");
    if (!input) { close(descriptor); return 1; }
    struct jpeg_decompress_struct decoder = {0};
    struct jpeg_error_mgr errors;
    jpeg_cust_mem_data memory;
    size_t used = 0;
    jpeg_cust_mem_init(&memory, &used, NULL, NULL, NULL, allocate, release, allocate, release, NULL);
    decoder.client_data = &memory;
    decoder.err = jpeg_std_error(&errors);
    errors.error_exit = failed;
    errors.emit_message = message;
    jpeg_create_decompress(&decoder);
    jpeg_stdio_src(&decoder, input);
    jpeg_read_header(&decoder, TRUE);
    if (!decoder.image_width || !decoder.image_height || decoder.image_width > 100000
        || decoder.image_height > 100000 || decoder.image_width > 32000000 / decoder.image_height
        || decoder.num_components < 1 || decoder.num_components > 4) {
        fputs("JPEG dimensions or component count exceed the image limits.\n", stderr);
        jpeg_destroy_decompress(&decoder);
        fclose(input);
        return 1;
    }
    // Scaled output still reads the complete compressed stream and avoids a full-size pixel buffer.
    decoder.scale_num = 1;
    decoder.scale_denom = 8;
    decoder.out_color_space = decoder.jpeg_color_space;
    decoder.do_fancy_upsampling = FALSE;
    jpeg_calc_output_dimensions(&decoder);
    JSAMPARRAY row = decoder.mem->alloc_sarray((j_common_ptr)&decoder, JPOOL_IMAGE,
        decoder.output_width * decoder.output_components, 1);
    jpeg_start_decompress(&decoder);
    while (decoder.output_scanline < decoder.output_height)
        jpeg_read_scanlines(&decoder, row, 1);
    jpeg_finish_decompress(&decoder);
    jpeg_destroy_decompress(&decoder);
    int unchanged = !fstat(descriptor, &after) && before.st_size == after.st_size
        && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
        && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
        && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
        && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec;
    int readable = !ferror(input);
    fclose(input);
    if (!unchanged || !readable) { fputs("The JPEG changed or could not be read completely.\n", stderr); return 1; }
    puts("valid");
    return 0;
}
